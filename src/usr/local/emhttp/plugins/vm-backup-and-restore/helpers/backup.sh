#!/bin/bash
set -u

SCRIPT_START_EPOCH=$(date +%s)

format_duration() {
    local total=$1
    local h=$(( total / 3600 ))
    local m=$(( (total % 3600) / 60 ))
    local s=$(( total % 60 ))

    local out=""
    (( h > 0 )) && out+="${h}h "
    (( m > 0 )) && out+="${m}m "
    out+="${s}s"

    echo "$out"
}

# ------------------------------------------------------------------------------
# Lock + working directory
# ------------------------------------------------------------------------------

mkdir -p /tmp/vm-backup-and-restore
LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"

# Prevent double-run
if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

touch "$LOCK_FILE"

# Logging
LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/last_run.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
mkdir -p "$ROTATE_DIR"
# Rotate last_run.log if >= 10MB
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes=$((10 * 1024 * 1024))  # 10MB

    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        rotated="$ROTATE_DIR/last_run_$ts.log"
        mv "$LAST_RUN_FILE" "$rotated"
    fi
fi

# Cleanup: keep only 10 most recent rotated logs
mapfile -t rotated_logs < <(ls -1t "$ROTATE_DIR"/last_run_*.log 2>/dev/null)

if (( ${#rotated_logs[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs[@]}; i++ )); do
        rm -f "${rotated_logs[$i]}"
    done
fi
exec > >(tee -a "$LAST_RUN_FILE") 2>&1

echo "--------------------------------------------"
echo "Backup session started - $(date '+%Y-%m-%d %H:%M:%S')"

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
source "$CONFIG" || exit 1

# DRY RUN SUPPORT --------------------------------------------------------------
DRY_RUN="${DRY_RUN:-1}"   # 0 = dry-run active, 1 = normal mode

is_dry_run() {
    [[ "$DRY_RUN" == "0" ]]
}

run_cmd() {
    if is_dry_run; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# ------------------------------------------------------------------------------
# Notifications
# ------------------------------------------------------------------------------

notify_unraid() {
    local title="$1"
    local message="$2"

    # Only send if enabled
    if [[ "$ENABLE_NOTIFICATIONS" == "1" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -e "unRAID Status" \
            -s "$title" \
            -d "$message" \
            -i "normal"
    fi
}

# Send startup notification
timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_unraid "unRAID VM Backup script" \
"script starting"

sleep 5

# ------------------------------------------------------------------------------
# Config-derived variables
# ------------------------------------------------------------------------------

backup_owner="${BACKUP_OWNER:-root}"
backup_location="${BACKUP_DESTINATION:-/mnt/user/vm_backups}"
export backup_location

# Build newline-separated VM list
IFS=',' read -ra VM_ARRAY <<< "${VM_NAME:-}"

vms_to_backup=""
for vm in "${VM_ARRAY[@]}"; do
    vm="$(echo "$vm" | xargs)"
    [[ -n "$vm" ]] && vms_to_backup+="$vm"$'\n'
done

export vms_to_backup

echo "Backing up VMs:"
printf '%s\n' "$vms_to_backup"

# Track VMs we stop
declare -a vms_stopped_by_script=()

# ------------------------------------------------------------------------------
# Cleanup trap
# ------------------------------------------------------------------------------

cleanup() {
    echo "Cleaning up…"

    # Remove lock file even in dry-run
    rm -f "$LOCK_FILE"

    # Compute duration
    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    if is_dry_run; then
        echo "[DRY-RUN] Skipping VM restarts"
        echo "Duration: $SCRIPT_DURATION_HUMAN"
        echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

        timestamp="$(date +"%d-%m-%Y %H:%M")"
        notify_unraid "unRAID VM Backup script" \
        "script finished - Duration: $SCRIPT_DURATION_HUMAN"
        return
    fi

    # Normal mode VM restart logic
    if ((${#vms_stopped_by_script[@]} > 0)); then
        echo "Starting VMs that were stopped by this script..."
        for vm in "${vms_stopped_by_script[@]}"; do
            echo "Starting VM: $vm"
            virsh start "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to start VM: $vm"
        done
        echo "VM restart phase complete."
    else
        echo "No VMs were stopped by this script."
    fi

    echo "Duration: $SCRIPT_DURATION_HUMAN"
    echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    timestamp="$(date +"%d-%m-%Y %H:%M")"
    notify_unraid "unRAID VM Backup script" \
    "script finished - Duration: $SCRIPT_DURATION_HUMAN"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

# ------------------------------------------------------------------------------
# Backup loop
# ------------------------------------------------------------------------------

RUN_TS="$(date +%Y%m%d_%H%M)"
run_cmd mkdir -p "$backup_location"

while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue

    echo "------------------------------------------------------------"
    echo "Processing VM: $vm"

    vm_xml_path="/etc/libvirt/qemu/$vm.xml"

    if [[ ! -f "$vm_xml_path" ]]; then
        echo "ERROR: XML not found for VM: $vm"
        continue
    fi

    # ------------------------------
    # Stop VM if running
    # ------------------------------
    vm_state_before="$(virsh domstate "$vm" 2>/dev/null || echo "unknown")"
    echo "Current state of '$vm': $vm_state_before"

    if [[ "$vm_state_before" == "running" ]]; then
        echo "Stopping VM: $vm"
        vms_stopped_by_script+=("$vm")

        run_cmd virsh shutdown "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to send shutdown to $vm"

        if ! is_dry_run; then
            echo -n "Waiting for $vm to stop"
            timeout=60
            while [[ "$(virsh domstate "$vm" 2>/dev/null)" != "shut off" && $timeout -gt 0 ]]; do
                echo -n "."
                sleep 2
                ((timeout-=2))
            done
            echo ""

            if [[ $timeout -le 0 ]]; then
                echo "Graceful shutdown timed out — forcing power off for $vm"
                run_cmd virsh destroy "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to force power off $vm"
            else
                echo "VM $vm is now stopped."
            fi
        else
            echo "[DRY-RUN] Would wait for VM to stop"
        fi
    else
        echo "Not stopping VM '$vm' (VM not running)."
    fi

    # ------------------------------
    # Backup folder
    # ------------------------------
    vm_backup_folder="$backup_location/$vm"
    run_cmd mkdir -p "$vm_backup_folder"

    # ------------------------------
    # Extract vdisk paths from XML (clean, no warnings)
    # ------------------------------
mapfile -t vdisks < <(
    xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path" 2>/dev/null \
        | sed -E 's/ file=\"/\n/g' \
        | sed -E 's/\"//g' \
        | sed '/^$/d'
)

    if ((${#vdisks[@]} == 0)); then
        echo "No vdisk entries found in XML for $vm"
    else
        echo "Backing up vdisks (sparse-aware):"
        for vdisk in "${vdisks[@]}"; do
            if [[ ! -f "$vdisk" ]]; then
                echo "  WARNING: vdisk path does not exist: $vdisk"
                continue
            fi
            base="$(basename "$vdisk")"
            dest="$vm_backup_folder/${RUN_TS}_$base"
            echo "  rsync (sparse): $vdisk -> $dest"
            run_cmd rsync -aSv --progress "$vdisk" "$dest"
        done
    fi

    # ------------------------------
    # Backup XML
    # ------------------------------
    xml_dest="$vm_backup_folder/${RUN_TS}_${vm}.xml"
    echo "Backing up XML: $vm_xml_path -> $xml_dest"
    run_cmd rsync -aSv --progress "$vm_xml_path" "$xml_dest"

    # ------------------------------
    # Extract + backup NVRAM
    # ------------------------------
    nvram_path="$(xmllint --xpath 'string(/domain/os/nvram)' "$vm_xml_path" 2>/dev/null || echo "")"

    if [[ -n "$nvram_path" && -f "$nvram_path" ]]; then
        nvram_base="$(basename "$nvram_path")"
        nvram_dest="$vm_backup_folder/${RUN_TS}_$nvram_base"
        echo "Backing up NVRAM: $nvram_path -> $nvram_dest"
        run_cmd rsync -aSv --progress "$nvram_path" "$nvram_dest"
    else
        echo "No valid NVRAM found for $vm"
    fi

    # ------------------------------
    # Ownership fix
    # ------------------------------
    echo "Changing owner of backup folder for '$vm' to $backup_owner:users"
    run_cmd chown -R "$backup_owner:users" "$vm_backup_folder" || echo "WARNING: chown failed for $vm_backup_folder"

    echo "Finished backup for VM: $vm"
    echo "------------------------------------------------------------"

done <<< "$vms_to_backup"

exit 0
