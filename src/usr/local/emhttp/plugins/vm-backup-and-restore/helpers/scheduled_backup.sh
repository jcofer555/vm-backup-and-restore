#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_DIR="/tmp/vm-backup-and-restore"
LOCK_FILE="$LOG_DIR/lock.txt"
STOP_FLAG="$LOG_DIR/stop_requested.txt"
STATUS_FILE="$LOG_DIR/backup_status.txt"
ROTATE_DIR="$LOG_DIR/archived_logs"

mkdir -p "$LOG_DIR"
mkdir -p "$ROTATE_DIR"

DRY_RUN="${DRY_RUN:-no}"
SCRIPT_START_EPOCH=$(date +%s)
RSYNC_PID=""

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

classify_path() {
    local p="$1"
    local resolved
    resolved=$(readlink -f "$p" 2>/dev/null || echo "$p")

    if [[ "$resolved" == /mnt/user || "$resolved" == /mnt/user/* ]]; then
        echo "USER"
        return
    fi

    if [[ "$resolved" == /mnt/user0 || "$resolved" == /mnt/user0/* ]]; then
        echo "USER0"
        return
    fi

    if [[ "$resolved" == /mnt/remotes || "$resolved" == /mnt/remotes/* ]]; then
        echo "EXEMPT"
        return
    fi

    if [[ "$resolved" == /mnt/addons || "$resolved" == /mnt/addons/* ]]; then
        echo "EXEMPT"
        return
    fi

    # Resolved pool path (e.g. /mnt/cache, /mnt/disk1) — treat as equivalent to USER
    if [[ "$resolved" == /mnt/* ]]; then
        echo "USER"
        return
    fi

    echo "OTHER"
}

validate_mount_compatibility() {
    local src="$1"
    local dst="$2"

    local resolved_src resolved_dst
    resolved_src=$(readlink -f "$(dirname "$src")" 2>/dev/null)/$(basename "$src")
    resolved_dst=$(readlink -f "$dst" 2>/dev/null)

    local src_class dst_class
    src_class=$(classify_path "$resolved_src")
    dst_class=$(classify_path "$resolved_dst")

    if [[ "$src_class" != "$dst_class" && "$src_class" != "EXEMPT" && "$dst_class" != "EXEMPT" ]]; then
        echo "[ERROR] Vdisk $src is using mount type ($src_class) and backup destination ($dst_class)"
        echo "[ERROR] They must be on the same mount type i.e both fields using user or both user0 or none using either user or user0"
        set_status "Mount type mismatch for $src"
        return 1
    fi

    return 0
}

cleanup_partial_backup() {
    local folder="$1"
    local ts="$2"

    if [[ ! -d "$folder" ]]; then
        return
    fi

    # Remove only files created during this run
    shopt -s nullglob
    local run_files=( "$folder/${ts}_"* )
    shopt -u nullglob

    for f in "${run_files[@]}"; do
        :
        rm -f "$f"
    done

    # Remove folder only if empty
    if [[ -z "$(ls -A "$folder")" ]]; then
        :
        rmdir "$folder"
    else
        :
    fi
}

run_rsync() {
    if is_dry_run; then
        printf '[DRY-RUN] '
        printf '%q ' rsync "$@"
        echo
        return 0
    fi

    rsync "$@" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "/tmp/vm-backup-and-restore/rsync.pid"
    wait $RSYNC_PID
    local exit_code=$?
    RSYNC_PID=""
    rm -f "/tmp/vm-backup-and-restore/rsync.pid"
    return $exit_code
}

set_status() {
    echo "$1" > "$STATUS_FILE"
}

# ------------------------------------------------------------------------------
# Cleanup trap
# ------------------------------------------------------------------------------
cleanup() {
    LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"
    rm -f "$LOCK_FILE"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "Backup was stopped early"
        else
            :
            for vm in "${CLEAN_VMS[@]}"; do
                [[ -z "$vm" ]] && continue
                vm_backup_folder="$backup_location/$vm"
                cleanup_partial_backup "$vm_backup_folder" "$RUN_TS"
            done
            echo "Backup was stopped early. Cleaned up files created this run"
        fi

        if [[ "$DRY_RUN" != "yes" ]]; then
            if ((${#vms_stopped_by_script[@]} > 0)); then
                for vm in "${vms_stopped_by_script[@]}"; do
                    echo "Starting VM $vm"
                    virsh start "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm"
                done
            fi
        fi

        local h=$(( SCRIPT_DURATION / 3600 ))
        local m=$(( (SCRIPT_DURATION % 3600) / 60 ))
        local s=$(( SCRIPT_DURATION % 60 ))
        SCRIPT_DURATION_HUMAN=""
        (( h > 0 )) && SCRIPT_DURATION_HUMAN+="${h}h "
        (( m > 0 )) && SCRIPT_DURATION_HUMAN+="${m}m "
        SCRIPT_DURATION_HUMAN+="${s}s"
        echo "Backup duration: $SCRIPT_DURATION_HUMAN"
        echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

        set_status "Backup stopped and cleaned up"
        rm -f "$STATUS_FILE"
        rm -f "$STOP_FLAG"
        return
    fi

    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    # --- STATUS UPDATE ---
    set_status "Backup complete - Duration: $SCRIPT_DURATION_HUMAN"
    # ---------------------

    if is_dry_run; then
        echo "Skipping VM restarts because dry run is enabled"
        echo "Backup duration: $SCRIPT_DURATION_HUMAN"
        echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

        notify_vm "normal" "VM Backup & Restore" \
            "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"

        rm -f "$STATUS_FILE"
        return
    fi

    if ((${#vms_stopped_by_script[@]} > 0)); then
        :
        for vm in "${vms_stopped_by_script[@]}"; do
            echo "Starting VM $vm"
            virsh start "$vm" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm"
        done
    else
        echo "No VMs were stopped this session"
    fi

    echo "Backup duration: $SCRIPT_DURATION_HUMAN"
    echo "Backup session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    if (( error_count > 0 )); then
        notify_vm "warning" "VM Backup & Restore" \
            "Backup finished with errors - Duration: $SCRIPT_DURATION_HUMAN - Check logs for details"
    else
        notify_vm "normal" "VM Backup & Restore" \
            "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi

    rm -f "$STATUS_FILE"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

# ------------------------------------------------------------------------------
# KEEP YOUR ORIGINAL LOCK UPDATE
# ------------------------------------------------------------------------------

sed -i "s/PID=.*/PID=$$/" "$LOCK_FILE"

# ------------------------------------------------------------------------------
# Everything else remains unchanged below
# ------------------------------------------------------------------------------

# Load schedule-specific variables
if [[ -n "${SCHEDULE_ID:-}" ]]; then
    echo "Running scheduled backup: $SCHEDULE_ID"
    DRY_RUN="${DRY_RUN:-1}"
    VMS_TO_BACKUP="${VMS_TO_BACKUP:-}"
    BACKUPS_TO_KEEP="${BACKUPS_TO_KEEP:-0}"
    BACKUP_DESTINATION="${BACKUP_DESTINATION:-/mnt/user/vm_backups}"
    BACKUP_OWNER="${BACKUP_OWNER:-root}"
    NOTIFICATIONS="${NOTIFICATIONS:-no}"
fi

LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"

# log rotation
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes=$((10 * 1024 * 1024))
    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        mv "$LAST_RUN_FILE" "$ROTATE_DIR/vm-backup-and-restore_$ts.log"
    fi
fi

mapfile -t rotated_logs < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null)
if (( ${#rotated_logs[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs[@]}; i++ )); do
        rm -f "${rotated_logs[$i]}"
    done
fi

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

echo "--------------------------------------------------------------------------------------------------"
echo "Backup session started - $(date '+%Y-%m-%d %H:%M:%S')"

# DRY RUN
is_dry_run() { [[ "$DRY_RUN" == "yes" ]]; }
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

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL//\"/}"

notify_vm() {
    local level="$1"
    local title="$2"
    local message="$3"

    [[ "${NOTIFICATIONS:-no}" != "yes" ]] && return 0

    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        local color
        case "$level" in
            alert)   color=15158332 ;;  # red
            warning) color=16776960 ;;  # yellow
            *)       color=3066993  ;;  # green
        esac
        curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"embeds\":[{\"title\":\"$title\",\"description\":\"$message\",\"color\":$color}]}" || true
    else
        if [[ -x /usr/local/emhttp/webGui/scripts/notify ]]; then
            /usr/local/emhttp/webGui/scripts/notify \
                -e "VM Backup & Restore" \
                -s "$title" \
                -d "$message" \
                -i "$level"
        fi
    fi
}

error_count=0

timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_vm "normal" "VM Backup & Restore" "Backup started"

sleep 5

if [[ -f "$STOP_FLAG" ]]; then
    exit 1
fi

# ------------------------------------------------------------------------------
# Config-derived variables
# ------------------------------------------------------------------------------
BACKUPS_TO_KEEP="${BACKUPS_TO_KEEP:-0}"
backup_owner="${BACKUP_OWNER:-nobody}"
backup_location="${BACKUP_DESTINATION:-/mnt/user/vm_backups}"
export backup_location

# ------------------------------------------------------------------------------
# Space-safe VM parsing
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
    echo "Backing up VM(s) - $comma_list"
else
    echo "No VMs configured for backup"
fi

declare -a vms_stopped_by_script=()

# ------------------------------------------------------------------------------
# Backup loop
# ------------------------------------------------------------------------------
RUN_TS="$(date +%Y%m%d_%H%M)"
run_cmd mkdir -p "$backup_location"

for vm in "${CLEAN_VMS[@]}"; do
    [[ -z "$vm" ]] && continue

    if [[ -f "$STOP_FLAG" ]]; then
        exit 1
    fi

    echo "Started backup for $vm"
    set_status "Backing up $vm"

    vm_xml_path="/etc/libvirt/qemu/$vm.xml"

    if [[ ! -f "$vm_xml_path" ]]; then
        echo "ERROR: XML not found for $vm"
        ((error_count++))
        continue
    fi

    vm_state_before="$(virsh domstate "$vm" 2>/dev/null || echo "unknown")"

    if [[ "$vm_state_before" == "running" ]]; then
        echo "Stopping $vm"
        set_status "Stopping $vm"
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

    if [[ -f "$STOP_FLAG" ]]; then
        exit 1
    fi

    vm_backup_folder="$backup_location/$vm"
    run_cmd mkdir -p "$vm_backup_folder"

    mapfile -t vdisks < <(
        xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path" 2>/dev/null \
            | sed -E 's/ file=\"/\n/g' \
            | sed -E 's/\"//g' \
            | sed '/^$/d'
    )

    # Validate each vdisk path against backup destination
    for vdisk in "${vdisks[@]}"; do
        if ! validate_mount_compatibility "$vdisk" "$backup_location"; then
            echo "[ERROR] Skipping $vm due to incompatible mount types"
            ((error_count++))

            if [[ -d "$vm_backup_folder" ]]; then

                shopt -s nullglob
                run_files=( "$vm_backup_folder/${RUN_TS}_"* )
                shopt -u nullglob

                if (( ${#run_files[@]} > 0 )); then
                    :
                    for f in "${run_files[@]}"; do
                        :
                        rm -f "$f"
                    done
                else
                    :
                fi

                if [[ -z "$(ls -A "$vm_backup_folder")" ]]; then
                    :
                    rmdir "$vm_backup_folder"
                else
                    :
                fi
            fi
            continue 2
        fi
    done

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
            resolved_vdisk="$(readlink -f "$vdisk" 2>/dev/null || echo "$vdisk")"
            dest="$vm_backup_folder/${RUN_TS}_$base"
            if ! is_dry_run; then
                echo "$resolved_vdisk -> $dest"
            fi
            run_rsync -aHAX --sparse "$resolved_vdisk" "$dest"

            if [[ -f "$STOP_FLAG" ]]; then
                cleanup_partial_backup "$vm_backup_folder" "$RUN_TS"
                exit 1
            fi
        done

        # Backup any extra files in the same folder as the vdisks
        declare -A vdisk_dirs
        for vdisk in "${vdisks[@]}"; do
            resolved_vdisk="$(readlink -f "$vdisk" 2>/dev/null || echo "$vdisk")"
            vdisk_dirs["$(dirname "$resolved_vdisk")"]=1
        done

        for dir in "${!vdisk_dirs[@]}"; do
            for extra_file in "$dir"/*; do
                [[ -f "$extra_file" ]] || continue

                already=false
                for vdisk in "${vdisks[@]}"; do
                    resolved_vdisk="$(readlink -f "$vdisk" 2>/dev/null || echo "$vdisk")"
                    [[ "$extra_file" == "$resolved_vdisk" ]] && already=true && break
                done
                $already && continue

                base="$(basename "$extra_file")"
                dest="$vm_backup_folder/${RUN_TS}_$base"
                echo "Backing up extra file $extra_file -> $dest"
                run_rsync -aHAX --sparse "$extra_file" "$dest"

                if [[ -f "$STOP_FLAG" ]]; then
                    cleanup_partial_backup "$vm_backup_folder" "$RUN_TS"
                    exit 1
                fi
            done
        done
        unset vdisk_dirs
    fi

    xml_dest="$vm_backup_folder/${RUN_TS}_${vm}.xml"
    set_status "Backing up XML for $vm"
    run_rsync -a "$vm_xml_path" "$xml_dest"
    echo "Backed up XML $vm_xml_path -> $xml_dest"

    nvram_path="$(xmllint --xpath 'string(/domain/os/nvram)' "$vm_xml_path" 2>/dev/null || echo "")"

    if [[ -n "$nvram_path" && -f "$nvram_path" ]]; then
        nvram_base="$(basename "$nvram_path")"
        nvram_dest="$vm_backup_folder/${RUN_TS}_$nvram_base"
        set_status "Backing up NVRAM for $vm"
        run_rsync -a "$nvram_path" "$nvram_dest"
        echo "Backed up NVRAM $nvram_path -> $nvram_dest"
    else
        echo "No valid NVRAM found for $vm"
    fi

    run_cmd chown -R "$backup_owner:users" "$vm_backup_folder" || echo "WARNING: Changing owner failed for $vm_backup_folder"
    echo "Changed owner of $vm_backup_folder for $vm to $backup_owner:users"

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
            set_status "Removing old backups for $vm"

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
    echo "WARNING: BACKUPS_TO_KEEP is invalid skipping retention"
fi

done

exit 0