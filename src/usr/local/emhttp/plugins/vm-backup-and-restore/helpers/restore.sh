#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_START_EPOCH=$(date +%s)
STOP_FLAG="/tmp/vm-backup-and-restore/restore_stop_requested.txt"
RSYNC_PID=""
RESTORED_FILES=()
TEMP_FILES=()

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

# --- RESTORE STATUS FILE ---
RESTORE_STATUS_FILE="/tmp/vm-backup-and-restore/restore_status.txt"
set_restore_status() {
    echo "$1" > "$RESTORE_STATUS_FILE"
}
set_restore_status "Started restore session"
# ---------------------------

# Logging
LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
DEBUG_LOG="$LOG_DIR/vm-restore-debug.log"
mkdir -p "$ROTATE_DIR"

debug_log() {
    echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DEBUG_LOG"
}

# Rotate main log if >= 10MB
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes=$((10 * 1024 * 1024))

    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        rotated="$ROTATE_DIR/vm-backup-and-restore_$ts.log"
        mv "$LAST_RUN_FILE" "$rotated"
        debug_log "Rotated main log to $rotated (was >= 10MB)"
    fi
fi

mapfile -t rotated_logs < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null)

if (( ${#rotated_logs[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs[@]}; i++ )); do
        rm -f "${rotated_logs[$i]}"
        debug_log "Purged old rotated log: ${rotated_logs[$i]}"
    done
fi

# Rotate debug log if >= 10MB
if [[ -f "$DEBUG_LOG" ]]; then
    size_bytes=$(stat -c%s "$DEBUG_LOG")
    max_bytes=$((10 * 1024 * 1024))

    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        mv "$DEBUG_LOG" "$ROTATE_DIR/vm-restore-debug_$ts.log"
        debug_log "Rotated debug log to $ROTATE_DIR/vm-restore-debug_$ts.log (was >= 10MB)"
    fi
fi

mapfile -t rotated_debug_logs < <(ls -1t "$ROTATE_DIR"/vm-restore-debug_*.log 2>/dev/null)

if (( ${#rotated_debug_logs[@]} > 10 )); then
    for (( i=10; i<${#rotated_debug_logs[@]}; i++ )); do
        rm -f "${rotated_debug_logs[$i]}"
        debug_log "Purged old rotated debug log: ${rotated_debug_logs[$i]}"
    done
fi

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

echo "--------------------------------------------------------------------------------------------------"
echo "Restore session started - $(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------------------------
# Cleanup trap
# ------------------------------------------------------------------------------

cleanup() {
    LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"
    rm -f "$LOCK_FILE"
    debug_log "Lock file removed"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        debug_log "Stop flag detected in cleanup — rolling back restored files"
        set_restore_status "Restore stopped and cleaned up"
        for f in "${RESTORED_FILES[@]}"; do
            rm -f "$f"
            debug_log "Removed restored file: $f"
        done
        for tmp in "${TEMP_FILES[@]}"; do
            original="${tmp%.pre_restore_tmp}"
            mv "$tmp" "$original"
            debug_log "Restored temp file: $tmp -> $original"
        done
        for vm in "${vm_names[@]}"; do
            [[ -z "$vm" ]] && continue
            vm_folder="$vm_domains/$vm"
            if [[ -d "$vm_folder" && -z "$(ls -A "$vm_folder")" ]]; then
                rmdir "$vm_folder"
                debug_log "Removed empty folder: $vm_folder"
            fi
        done
        echo "Restore was stopped early. Cleaned up files created this run"
        debug_log "===== Session ended (stopped early) ====="
        rm -f "$RESTORE_STATUS_FILE"
        return
    fi

    # Normal completion — remove temp files
    for tmp in "${TEMP_FILES[@]}"; do
        rm -f "$tmp"
        debug_log "Removed temp file: $tmp"
    done

    if [[ "$DRY_RUN" != "yes" ]]; then
        if (( ${#STOPPED_VMS[@]} > 0 )); then
            for vm in "${STOPPED_VMS[@]}"; do
                echo "Starting $vm"
                debug_log "Restarting VM: $vm"
                run_cmd virsh start "$vm"
            done
        fi
    else
        echo "Skipping VM restarts because dry run is enabled"
        debug_log "Skipping VM restarts (dry run)"
    fi

    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    echo "Restore duration: $SCRIPT_DURATION_HUMAN"
    echo "Restore session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    debug_log "Session finished - duration=$SCRIPT_DURATION_HUMAN error_count=$error_count"

    set_restore_status "Restore complete - Duration: $SCRIPT_DURATION_HUMAN"

    if (( error_count > 0 )); then
        notify_restore "warning" "VM Backup & Restore" \
            "Restore finished with errors - Duration: $SCRIPT_DURATION_HUMAN - Check logs for details"
    else
        notify_restore "normal" "VM Backup & Restore" \
            "Restore finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi

    rm -f "$RESTORE_STATUS_FILE"
    debug_log "===== Session ended ====="
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
debug_log "Loading config: $CONFIG"
source "$CONFIG" || { debug_log "ERROR: Failed to source config: $CONFIG"; exit 1; }

DISCORD_WEBHOOK_URL_RESTORE="${DISCORD_WEBHOOK_URL_RESTORE//\"/}"
PUSHOVER_USER_KEY_RESTORE="${PUSHOVER_USER_KEY_RESTORE//\"/}"

classify_path() {
    local p="$1"

    if [[ "$p" == /mnt/user || "$p" == /mnt/user/* ]]; then
        echo "USER"
        return
    fi

    if [[ "$p" == /mnt/user0 || "$p" == /mnt/user0/* ]]; then
        echo "USER0"
        return
    fi

    if [[ "$p" == /mnt/remotes || "$p" == /mnt/remotes/* ]]; then
        echo "EXEMPT"
        return
    fi

    if [[ "$p" == /mnt/addons || "$p" == /mnt/addons/* ]]; then
        echo "EXEMPT"
        return
    fi

    echo "OTHER"
}

notify_restore() {
    local level="$1"
    local title="$2"
    local message="$3"

    debug_log "notify_restore called: level=$level title=$title message=$message"

    [[ "$NOTIFICATIONS_RESTORE" != "yes" ]] && { debug_log "Notifications disabled, skipping"; return 0; }

    if [[ -n "$DISCORD_WEBHOOK_URL_RESTORE" ]]; then
        local color
        case "$level" in
            alert)   color=15158332 ;;
            warning) color=16776960 ;;
            *)       color=3066993  ;;
        esac

        if [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"discord.com/api/webhooks"* ]]; then
            debug_log "Sending Discord webhook notification"
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"embeds\":[{\"title\":\"$title\",\"description\":\"$message\",\"color\":$color}]}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"hooks.slack.com"* ]]; then
            debug_log "Sending Slack webhook notification"
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"text\":\"*$title*\n$message\"}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"outlook.office.com/webhook"* ]]; then
            debug_log "Sending Teams webhook notification"
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"$title\",\"text\":\"$message\"}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"/message"* ]]; then
            debug_log "Sending Gotify notification"
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"$title\",\"message\":\"$message\",\"priority\":5}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"ntfy.sh"* || "$DISCORD_WEBHOOK_URL_RESTORE" == *"/ntfy/"* ]]; then
            debug_log "Sending ntfy notification"
            curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
                -H "Title: $title" \
                -d "$message" > /dev/null || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"api.pushover.net"* ]]; then
            debug_log "Sending Pushover notification"
            local token="${DISCORD_WEBHOOK_URL_RESTORE##*/}"
            curl -sf -X POST "https://api.pushover.net/1/messages.json" \
                -d "token=${token}" \
                -d "user=${PUSHOVER_USER_KEY_RESTORE}" \
                -d "title=${title}" \
                -d "message=${message}" > /dev/null || true
        fi
    else
        if [[ -x /usr/local/emhttp/webGui/scripts/notify ]]; then
            debug_log "Sending Unraid native notification"
            /usr/local/emhttp/webGui/scripts/notify \
                -e "VM Backup & Restore" \
                -s "$title" \
                -d "$message" \
                -i "$level"
        else
            debug_log "No notification method available (notify script not found)"
        fi
    fi
}

error_count=0

timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_restore "normal" "VM Backup & Restore" "Restore started"

sleep 5

IFS=',' read -r -a vm_names <<< "$VMS_TO_RESTORE"
backup_path="$LOCATION_OF_BACKUPS"
vm_domains="$RESTORE_DESTINATION"
DRY_RUN="$DRY_RUN_RESTORE"

debug_log "===== Session started ====="
debug_log "VMS_TO_RESTORE=$VMS_TO_RESTORE"
debug_log "backup_path=$backup_path"
debug_log "vm_domains=$vm_domains"
debug_log "DRY_RUN=$DRY_RUN"
debug_log "NOTIFICATIONS_RESTORE=$NOTIFICATIONS_RESTORE"
debug_log "DISCORD_WEBHOOK_URL_RESTORE=${DISCORD_WEBHOOK_URL_RESTORE:+(set)}"
debug_log "PUSHOVER_USER_KEY_RESTORE=${PUSHOVER_USER_KEY_RESTORE:+(set)}"
debug_log "VERSIONS=$VERSIONS"
debug_log "SCRIPT_START_EPOCH=$SCRIPT_START_EPOCH"

src_class=$(classify_path "$backup_path")
dst_class=$(classify_path "$vm_domains")

debug_log "Mount compatibility check: backup_path=$backup_path ($src_class) vm_domains=$vm_domains ($dst_class)"

if [[ "$src_class" != "$dst_class" && "$src_class" != "EXEMPT" && "$dst_class" != "EXEMPT" ]]; then
    echo "[ERROR] Location of backups is using mount type ($src_class) and restore destination ($dst_class)."
    echo "[ERROR] They must be on the same mount type i.e both fields using user or both user0 or none using either user or user0"
    echo "Restore aborted due to mount type mismatch"
    debug_log "ERROR: Mount type mismatch — aborting. src=$src_class dst=$dst_class"
    set_restore_status "Restore aborted – mount-type mismatch"
    notify_restore "alert" "VM Backup & Restore Error" "Restore aborted due to mount type mismatch"
    exit 1
fi

mapfile -t RUNNING_BEFORE < <(virsh list --state-running --name | grep -Fxv "")
debug_log "VMs running before restore: ${RUNNING_BEFORE[*]:-none}"
STOPPED_VMS=()

xml_base="/etc/libvirt/qemu"
nvram_base="$xml_base/nvram"

mkdir -p "$nvram_base"
debug_log "nvram_base=$nvram_base"

log()  { echo -e "$1"; }
warn() { echo -e "$1"; }
err() { echo -e "[ERROR] $1"; }

validation_fail() {
    err "$1"
    warn "Skipping $vm"
    debug_log "Validation failed for $vm: $1"
    ((error_count++))
}

run_cmd() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '[DRY RUN] '
        printf '%q ' "$@"
        echo
        return
    fi

    if [[ "$1" == "virsh" && "$2" == "define" ]]; then
        "$@" >/dev/null
        return
    fi

    if [[ "$1" == "virsh" && ( "$2" == "shutdown" || "$2" == "destroy" || "$2" == "start" ) ]]; then
        shift
        virsh --quiet "$@" >/dev/null
        return
    fi

    "$@"
}

run_rsync() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '[DRY RUN] '
        printf '%q ' rsync "$@"
        echo
        return 0
    fi

    debug_log "run_rsync: rsync ${*}"
    rsync "$@" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "/tmp/vm-backup-and-restore/restore_rsync.pid"
    wait $RSYNC_PID
    local exit_code=$?
    RSYNC_PID=""
    rm -f "/tmp/vm-backup-and-restore/restore_rsync.pid"
    debug_log "rsync finished with exit_code=$exit_code"
    return $exit_code
}

declare -A version_map

IFS=',' read -ra pairs <<< "$VERSIONS"
for p in "${pairs[@]}"; do
    vm_name="${p%%=*}"
    ts="${p#*=}"
    ts="${ts//-/_}"
    version_map["$vm_name"]="$ts"
    debug_log "version_map: $vm_name -> $ts"
done

for vm in "${vm_names[@]}"; do

    set_restore_status "Starting restore for $vm"
    debug_log "--- Starting restore for VM: $vm ---"

    backup_dir="$backup_path/$vm"
    version="${version_map[$vm]}"

    debug_log "backup_dir=$backup_dir"
    debug_log "version=$version"

    if [[ -z "$version" ]]; then
        validation_fail "No restore version specified for VM $vm"
        continue
    fi

    prefix="${version}_"
    debug_log "prefix=$prefix"

    xml_file=$(ls "$backup_dir"/"${prefix}"*.xml 2>/dev/null | head -n1)
    nvram_file=$(ls "$backup_dir"/"${prefix}"*VARS*.fd 2>/dev/null | head -n1)
    disks=( "$backup_dir"/"${prefix}"vdisk*.img "$backup_dir"/"${prefix}"*.qcow2 )

    debug_log "xml_file=${xml_file:-not found}"
    debug_log "nvram_file=${nvram_file:-not found}"
    debug_log "disks: ${disks[*]}"

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
        validation_fail "No versioned vdisk*.img or *.qcow2 files found for prefix: $prefix"
        continue
    fi

    WAS_RUNNING=false
    if printf '%s\n' "${RUNNING_BEFORE[@]}" | grep -Fxq "$vm"; then
        WAS_RUNNING=true
    fi
    debug_log "WAS_RUNNING=$WAS_RUNNING"

    log "Starting restore for $vm"

    # Shutdown
    set_restore_status "Stopping $vm"
    if virsh list --state-running --name | grep -Fxq "$vm"; then
        log "Stopping $vm"
        debug_log "Sending shutdown to $vm"

        run_cmd virsh shutdown "$vm"
        sleep 10

        if virsh list --state-running --name | grep -Fxq "$vm"; then
            warn "$vm still running — forcing stop"
            debug_log "$vm still running after shutdown — forcing destroy"
            run_cmd virsh destroy "$vm"
        else
            debug_log "$vm stopped cleanly"
        fi

        if [[ "$WAS_RUNNING" == true ]]; then
            STOPPED_VMS+=("$vm")
            debug_log "Added $vm to STOPPED_VMS for restart after restore"
        fi
    else
        log "$vm is not running"
        debug_log "$vm was not running, no shutdown needed"
    fi

    # Restore XML
    set_restore_status "Restoring XML for $vm"
    dest_xml="$xml_base/$vm.xml"
    debug_log "Restoring XML: $xml_file -> $dest_xml"

    if [[ -f "$dest_xml" ]]; then
        cp "$dest_xml" "${dest_xml}.pre_restore_tmp"
        TEMP_FILES+=("${dest_xml}.pre_restore_tmp")
        debug_log "Saved existing XML as temp: ${dest_xml}.pre_restore_tmp"
    fi
    run_cmd rm -f "$dest_xml"
    run_rsync -a --sparse --no-perms --no-owner --no-group "$xml_file" "$dest_xml"
    RESTORED_FILES+=("$dest_xml")
    run_cmd chmod 644 "$dest_xml"
    log "Restored XML $xml_file → $dest_xml"

    if [[ -f "$STOP_FLAG" ]]; then
        debug_log "Stop flag detected after XML restore for $vm"
        exit 1
    fi

    # Restore NVRAM
    set_restore_status "Restoring NVRAM for $vm"
    nvram_filename=$(basename "$nvram_file")
    nvram_filename="${nvram_filename#$prefix}"
    dest_nvram="$nvram_base/$nvram_filename"
    debug_log "Restoring NVRAM: $nvram_file -> $dest_nvram"

    if [[ -f "$dest_nvram" ]]; then
        cp "$dest_nvram" "${dest_nvram}.pre_restore_tmp"
        TEMP_FILES+=("${dest_nvram}.pre_restore_tmp")
        debug_log "Saved existing NVRAM as temp: ${dest_nvram}.pre_restore_tmp"
    fi
    run_cmd rm -f "$dest_nvram"
    run_rsync -a --sparse --no-perms --no-owner --no-group "$nvram_file" "$dest_nvram"
    RESTORED_FILES+=("$dest_nvram")
    run_cmd chmod 644 "$dest_nvram"
    log "Restored NVRAM $nvram_file → $dest_nvram"

    if [[ -f "$STOP_FLAG" ]]; then
        debug_log "Stop flag detected after NVRAM restore for $vm"
        exit 1
    fi

    # Restore vdisks
    set_restore_status "Restoring vdisks for $vm"
    dest_domain="$vm_domains/$vm"
    debug_log "dest_domain=$dest_domain"

    parent_dataset=$(zfs list -H -o name "$(dirname "$dest_domain")" 2>/dev/null)
    if [[ -n "$parent_dataset" ]]; then
        debug_log "ZFS parent dataset found: $parent_dataset — creating dataset for $dest_domain"
        run_cmd zfs create "$parent_dataset/$(basename "$dest_domain")" 2>/dev/null || true
    else
        debug_log "No ZFS dataset found, using mkdir for $dest_domain"
        run_cmd mkdir -p "$dest_domain"
    fi

    for d in "${disks[@]}"; do
        [[ -f "$d" ]] || continue
        file=$(basename "$d")
        file="${file#$prefix}"
        debug_log "Restoring vdisk: $d -> $dest_domain/$file"
        run_rsync -a --sparse --no-perms --no-owner --no-group "$d" "$dest_domain/$file"
        RESTORED_FILES+=("$dest_domain/$file")
        run_cmd chmod 644 "$dest_domain/$file"
        log "Copied VDISK $d → $dest_domain/$file"

        if [[ -f "$STOP_FLAG" ]]; then
            debug_log "Stop flag detected during vdisk restore for $vm"
            exit 1
        fi
    done

    # Restore any extra files that were backed up alongside vdisks
    set_restore_status "Restoring extra files for $vm"
    debug_log "Scanning for extra files with prefix $prefix in $backup_dir"
    for extra_file in "$backup_dir"/"${prefix}"*; do
        [[ -f "$extra_file" ]] || continue

        case "$(basename "$extra_file")" in
            *.xml) continue ;;
            *VARS*.fd) continue ;;
            vdisk*.img) continue ;;
            *.qcow2) continue ;;
        esac

        file=$(basename "$extra_file")
        file="${file#$prefix}"
        debug_log "Restoring extra file: $extra_file -> $dest_domain/$file"
        run_rsync -a --sparse --no-perms --no-owner --no-group "$extra_file" "$dest_domain/$file"
        RESTORED_FILES+=("$dest_domain/$file")
        run_cmd chmod 644 "$dest_domain/$file"
        log "Restored extra file $extra_file → $dest_domain/$file"

        if [[ -f "$STOP_FLAG" ]]; then
            debug_log "Stop flag detected during extra file restore for $vm"
            exit 1
        fi
    done

    # Redefine VM
    set_restore_status "Redefining $vm"
    debug_log "Redefining VM from: $dest_xml"
    run_cmd virsh define "$dest_xml"
    log "Redefined $vm from $dest_xml"

    log "Finished restore for $vm"
    set_restore_status "Finished restore for $vm"
    debug_log "--- Finished restore for VM: $vm ---"

done

debug_log "All VMs processed"