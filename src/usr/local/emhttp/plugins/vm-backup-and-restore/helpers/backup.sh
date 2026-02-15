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

if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

touch "$LOCK_FILE"

LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm_backup_and_restore_last_run.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
mkdir -p "$ROTATE_DIR"

# --- STATUS FILE ADDED ---
STATUS_FILE="$LOG_DIR/backup_status.txt"
set_status() {
    echo "$1" > "$STATUS_FILE"
}
set_status "Starting backup session"
# --------------------------

if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes=$((10 * 1024 * 1024))

    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        rotated="$ROTATE_DIR/last_run_$ts.log"
        mv "$LAST_RUN_FILE" "$rotated"
    fi
fi

mapfile -t rotated_logs < <(ls -1t "$ROTATE_DIR"/last_run_*.log 2>/dev/null)

if (( ${#rotated_logs[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs[@]}; i++ )); do
        rm -f "${rotated_logs[$i]}"
    done
fi

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

echo "--------------------------------------------------------------------------------------------------"
echo "Backup session started - $(date '+%Y-%m-%d %H:%M:%S')"

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
source "$CONFIG" || exit 1

# ------------------------------------------------------------------------------
# DRY RUN SUPPORT
# ------------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-1}"

is_dry_run() {
    [[ "$DRY_RUN" == "0" ]]
}

run_cmd() {
    if is_dry_run; then
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

# ------------------------------------------------------------------------------
# Notifications
# ------------------------------------------------------------------------------

notify_unraid() {
    local title="$1"
    local message="$2"

    if [[ "${NOTIFICATIONS:-0}" == "1" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -e "unRAID Status" \
            -s "$title" \
            -d "$message" \
            -i "normal"
    fi
}

timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_unraid "unRAID VM Backup script" "Backup starting"

sleep 5

# ------------------------------------------------------------------------------
# Config-derived variables
# ------------------------------------------------------------------------------

BACKUPS_TO_KEEP="${BACKUPS_TO_KEEP:-0}"
backup_owner="${BACKUP_OWNER:-root}"
backup_location="${BACKUP_DESTINATION:-/mnt/user/vm_backups}"
export backup_location

# ------------------------------------------------------------------------------
# Space-safe VM parsing (ROBUST - no global IFS modification)
# ------------------------------------------------------------------------------

readarray -td ',' VM_ARRAY <<< "${VMS_TO_BACKUP:-},"

CLEAN_VMS=()
for vm in "${VM_ARRAY[@]}"; do
    vm="${vm#"${vm%%[![:space:]]*}"}"
    vm="${vm%"${vm##*[![:space:]]}"}"
    [[ -n "$vm" ]] && CLEAN_VMS+=("$vm")
done

if ((${#CLEAN_VMS[@]} > 0)); then
    comma_list=$(IFS=', '; printf '%s' "${CLEAN_VMS[*]}")
    echo "Backing up VM(s) $comma_list"
else
    echo "No VMs configured for backup"
fi

declare -a vms_stopped_by_script=()

# ------------------------------------------------------------------------------
# Cleanup trap
# ------------------------------------------------------------------------------

cleanup() {
    rm -f "$LOCK_FILE"

    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    # --- STATUS UPDATE ---
    set_status "Backup complete – Duration: $SCRIPT_DURATION_HUMAN"
    # ---------------------

    if is_dry_run; then
        echo "Skipping VM restarts"
        echo "Backup duration: $SCRIPT_DURATION_HUMAN"
        echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

        notify_unraid "unRAID VM Backup script" \
        "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"

        set_status "Not Running"
        return
    fi

    if ((${#vms_stopped_by_script[@]} > 0)); then
        :
        for vm in "${vms_stopped_by_script[@]}"; do
            echo "Starting VM $vm"
            virsh start "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm"
        done
    else
        echo "No VMs were stopped by this script"
    fi

    echo "Backup duration: $SCRIPT_DURATION_HUMAN"
    echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    notify_unraid "unRAID VM Backup script" \
    "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"

    set_status "Not Running"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

# ------------------------------------------------------------------------------
# Backup loop
# ------------------------------------------------------------------------------

RUN_TS="$(date +%Y%m%d_%H%M)"
run_cmd mkdir -p "$backup_location"

for vm in "${CLEAN_VMS[@]}"; do
    [[ -z "$vm" ]] && continue

    echo "Starting backup for $vm"
    set_status "Backing up VM: $vm"

    vm_xml_path="/etc/libvirt/qemu/$vm.xml"

    if [[ ! -f "$vm_xml_path" ]]; then
        echo "ERROR: XML not found for VM $vm"
        continue
    fi

    vm_state_before="$(virsh domstate "$vm" 2>/dev/null || echo "unknown")"

    if [[ "$vm_state_before" == "running" ]]; then
        echo "Stopping $vm"
        set_status "Stopping VM: $vm"
        vms_stopped_by_script+=("$vm")

        run_cmd virsh shutdown "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to send shutdown to $vm"

        if ! is_dry_run; then
            timeout=60
            while [[ "$(virsh domstate "$vm" 2>/dev/null)" != "shut off" && $timeout -gt 0 ]]; do
                sleep 2
                ((timeout-=2))
            done

            if [[ $timeout -le 0 ]]; then
                run_cmd virsh destroy "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to force power off $vm"
            else
                echo "$vm is now stopped"
            fi
        fi
    fi

    vm_backup_folder="$backup_location/$vm"
    run_cmd mkdir -p "$vm_backup_folder"

    mapfile -t vdisks < <(
        xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path" 2>/dev/null \
            | sed -E 's/ file=\"/\n/g' \
            | sed -E 's/\"//g' \
            | sed '/^$/d'
    )

    if ((${#vdisks[@]} == 0)); then
        echo "No vdisk entries found in XML for $vm"
    else
        echo "Backing up vdisks"
        set_status "Backing up vdisks for $vm"
        for vdisk in "${vdisks[@]}"; do
            if [[ ! -f "$vdisk" ]]; then
                echo "  WARNING: vdisk path does not exist $vdisk"
                continue
            fi
            base="$(basename "$vdisk")"
            dest="$vm_backup_folder/${RUN_TS}_$base"
            if ! is_dry_run; then
                echo "$vdisk -> $dest"
            fi
            run_cmd rsync -aHAX --sparse "$vdisk" "$dest"
        done
    fi

    xml_dest="$vm_backup_folder/${RUN_TS}_${vm}.xml"
    echo "Backing up XML $vm_xml_path -> $xml_dest"
    set_status "Backing up XML for $vm"
    run_cmd rsync -a "$vm_xml_path" "$xml_dest"

    nvram_path="$(xmllint --xpath 'string(/domain/os/nvram)' "$vm_xml_path" 2>/dev/null || echo "")"

    if [[ -n "$nvram_path" && -f "$nvram_path" ]]; then
        nvram_base="$(basename "$nvram_path")"
        nvram_dest="$vm_backup_folder/${RUN_TS}_$nvram_base"
        echo "Backing up NVRAM $nvram_path -> $nvram_dest"
        set_status "Backing up NVRAM for $vm"
        run_cmd rsync -a "$nvram_path" "$nvram_dest"
    else
        echo "No valid NVRAM found for $vm"
    fi

    echo "Changing owner of $vm_backup_folder for $vm to $backup_owner:users"
    run_cmd chown -R "$backup_owner:users" "$vm_backup_folder" || echo "WARNING: Changing owner failed for $vm_backup_folder"

    echo "Finished backup for $vm"
    set_status "Finished backup for $vm"

# ------------------------------------------------------------------------------
# Retention cleanup per VM
# ------------------------------------------------------------------------------

if [[ "$BACKUPS_TO_KEEP" =~ ^[0-9]+$ ]]; then

    if (( BACKUPS_TO_KEEP == 0 )); then
    :
    else
    :
        mapfile -t backup_sets < <(
            ls -1 "$vm_backup_folder" 2>/dev/null \
            | sed -E 's/^([0-9]{8}_[0-9]{4}).*/\1/' \
            | sort -u -r
        )

        total_sets=${#backup_sets[@]}

        if (( total_sets > BACKUPS_TO_KEEP )); then
            echo "Removing old backups keeping $BACKUPS_TO_KEEP"
            set_status "Retention cleanup for $vm"

            for (( i=BACKUPS_TO_KEEP; i<total_sets; i++ )); do
                old_ts="${backup_sets[$i]}"

                if is_dry_run; then
                    echo "[DRY-RUN] Would remove files with timestamp $old_ts"
                else
                    rm -f "$vm_backup_folder"/"${old_ts}"_*
                fi
            done
        else
            echo "No old backups need removed"
        fi
    fi

else
    echo "WARNING: BACKUPS_TO_KEEP is invalid, skipping retention"
fi

done

exit 0
