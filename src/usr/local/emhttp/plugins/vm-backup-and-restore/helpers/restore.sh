#!/bin/bash

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

mkdir -p /tmp/vm-backup-and-restore
LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"

# Prevent double-run
if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

touch "$LOCK_FILE"

# Logging
LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm_backup_and_restore_last_run.log"
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

echo "--------------------------------------------------------------------------------------------------"
echo "Restore session started - $(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------------------------
# Cleanup trap
# ------------------------------------------------------------------------------

cleanup() {
    echo "Cleaning up…"

    # Remove lock file even in dry-run
    rm -f "$LOCK_FILE"

    ### Restart VMs that were running before restore ###
    if [[ "$DRY_RUN" != "true" ]]; then
        if (( ${#STOPPED_VMS[@]} > 0 )); then
            echo "Restarting VMs that were previously running…"
            for vm in "${STOPPED_VMS[@]}"; do
                echo "Starting VM: $vm"
                virsh start "$vm"
            done
        else
            echo "No VMs needed to be restarted."
        fi
    else
        echo "[DRY RUN] Skipping VM restarts."
    fi

    # Compute duration
    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    echo "Restore duration: $SCRIPT_DURATION_HUMAN"
    echo "Restore session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    timestamp="$(date +"%d-%m-%Y %H:%M")"
    notify_unraid "unRAID VM Restore script" \
    "Restore finished - Duration: $SCRIPT_DURATION_HUMAN"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
source "$CONFIG" || exit 1

notify_unraid() {
    local title="$1"
    local message="$2"

    # Only send if enabled
    if [[ "$NOTIFICATIONS_RESTORE" == "1" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -e "unRAID Status" \
            -s "$title" \
            -d "$message" \
            -i "normal"
    fi
}

# Send startup notification
timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_unraid "unRAID VM Restore script" \
"Restore starting"

sleep 5

# ============================================================
# Variables to change
# ============================================================

IFS=',' read -r -a vm_names <<< "$VMS_TO_RESTORE"
backup_path="$LOCATION_OF_BACKUPS"
vm_domains="$RESTORE_DESTINATION"
DRY_RUN="$DRY_RUN_RESTORE"

# ============================================================
# Track VMs running before restore
# ============================================================
mapfile -t RUNNING_BEFORE < <(virsh list --state-running --name | grep -Fxv "")
STOPPED_VMS=()

# ============================================================
# System paths
# ============================================================
xml_base="/etc/libvirt/qemu"
nvram_base="$xml_base/nvram"

mkdir -p "$nvram_base"

# ============================================================
# Log output helpers
# ============================================================
log()  { echo -e "$1"; }
warn() { echo -e "$1"; }
err() { echo -e "[ERROR] $1"; }

# ============================================================
# Validation failure helper
# ============================================================
validation_fail() {
    err "$1"
    warn "Skipping VM: $vm"
}

# ============================================================
# Dry run wrapper
# ============================================================
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY RUN] '
        printf '%q ' "$@"
        echo
        return
    fi

    if [[ "$1" == "virsh" && "$2" == "define" ]]; then
        "$@" >/dev/null
    else
        "$@"
    fi
}

# ============================================================
# Parse VERSIONS into associative array
# ============================================================
declare -A version_map

IFS=',' read -ra pairs <<< "$VERSIONS"
for p in "${pairs[@]}"; do
    vm_name="${p%%=*}"
    ts="${p#*=}"
    ts="${ts//-/_}"
    version_map["$vm_name"]="$ts"
done

# ============================================================
# Process each VM
# ============================================================
for vm in "${vm_names[@]}"; do
    echo "===================================="
    echo " Restoring VM: $vm"
    echo "===================================="

    backup_dir="$backup_path/$vm"

    version="${version_map[$vm]}"

    if [[ -z "$version" ]]; then
        validation_fail "No restore version specified for VM '$vm'"
        continue
    fi

    prefix="${version}_"

    xml_file=$(ls "$backup_dir"/"${prefix}"*.xml 2>/dev/null | head -n1)
    nvram_file=$(ls "$backup_dir"/"${prefix}"*VARS*.fd 2>/dev/null | head -n1)
    disks=( "$backup_dir"/"${prefix}"vdisk*.img )

    if [[ ! -d "$backup_dir" ]]; then
        validation_fail "Backup folder missing: $backup_dir"
        continue
    fi
    if [[ ! -f "$xml_file" ]]; then
        validation_fail "XML file missing for version prefix: $prefix"
        continue
    fi
    if [[ ! -f "$nvram_file" ]]; then
        validation_fail "NVRAM file missing for version prefix: $prefix"
        continue
    fi
    if [[ ! -f "${disks[0]}" ]]; then
        validation_fail "No versioned vdisk*.img files found for prefix: $prefix"
        continue
    fi

    log "Backup validated for version $version."

    # ============================================================
    # Determine if VM was running before restore
    # ============================================================
    WAS_RUNNING=false
    if printf '%s\n' "${RUNNING_BEFORE[@]}" | grep -Fxq "$vm"; then
        WAS_RUNNING=true
    fi

    # ============================================================
    # Shutdown VM cleanly
    # ============================================================
    if virsh list --state-running --name | grep -Fxq "$vm"; then
        log "Shutting down VM gracefully..."

        run_cmd virsh shutdown "$vm"
        sleep 10

        if virsh list --state-running --name | grep -Fxq "$vm"; then
            warn "VM still running — forcing stop."
            run_cmd virsh destroy "$vm"
        fi

        if [[ "$WAS_RUNNING" == true ]]; then
            STOPPED_VMS+=("$vm")
        fi

    else
        log "VM is not running."
    fi

    # ============================================================
    # Restore XML
    # ============================================================
    dest_xml="$xml_base/$vm.xml"
    log "Restored XML → $dest_xml"

    run_cmd rm -f "$dest_xml"
    run_cmd cp "$xml_file" "$dest_xml"
    run_cmd chmod 644 "$dest_xml"

    # ============================================================
    # Restore NVRAM
    # ============================================================
    nvram_filename=$(basename "$nvram_file")
    nvram_filename="${nvram_filename#$prefix}"
    dest_nvram="$nvram_base/$nvram_filename"

    log "Restored NVRAM → $dest_nvram"

    run_cmd rm -f "$dest_nvram"
    run_cmd cp "$nvram_file" "$dest_nvram"
    run_cmd chmod 644 "$dest_nvram"

    # ============================================================
    # Restore vdisks
    # ============================================================
    dest_domain="$vm_domains/$vm"
    run_cmd mkdir -p "$dest_domain"

    for d in "${disks[@]}"; do
        file=$(basename "$d")
        file="${file#$prefix}"
        log "Copying disk: $file → $dest_domain/"
        run_cmd cp "$d" "$dest_domain/$file"
        run_cmd chmod 644 "$dest_domain/$file"
    done

    # ============================================================
    # Redefine VM
    # ============================================================
    log "Redefined VM via libvirt…"
    run_cmd virsh define "$dest_xml"

    log "VM $vm restore completed."
    restored_vms+=("$vm")

done

[[ "$DRY_RUN" == "true" ]] && echo "[DRY RUN] No changes were made."
