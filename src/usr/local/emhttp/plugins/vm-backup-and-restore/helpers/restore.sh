#!/usr/bin/env bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_START_EPOCH=$(date +%s)
STOP_FLAG="/tmp/vm-backup-and-restore/restore_stop_requested.txt"
RSYNC_PID=""
WATCHER_PID=""
RESTORED_FILES_arr=()
TEMP_FILES_arr=()

format_duration() {
    local total_int=$1
    local h_int=$(( total_int / 3600 ))
    local m_int=$(( (total_int % 3600) / 60 ))
    local s_int=$(( total_int % 60 ))
    local out_str=""
    (( h_int > 0 )) && out_str+="${h_int}h "
    (( m_int > 0 )) && out_str+="${m_int}m "
    out_str+="${s_int}s"
    echo "$out_str"
}

RESTORE_STATUS_FILE="/tmp/vm-backup-and-restore/restore_status.txt"
set_restore_status() { echo "$1" > "$RESTORE_STATUS_FILE"; }
set_restore_status "Started restore session"

LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
DEBUG_LOG="$LOG_DIR/vm-backup-and-restore-debug.log"
mkdir -p "$ROTATE_DIR"

debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore session started debug - $*" >> "$DEBUG_LOG"
}

log_path_resolution() {
    local label_str="$1" raw_str="$2" resolved_str="$3"
    if [[ -n "$raw_str" && "$raw_str" != "$resolved_str" ]]; then
        echo "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str (symlink followed)"
        debug_log "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str"
    else
        debug_log "$label_str: $resolved_str (no resolution needed)"
    fi
}

# Log rotation: main log
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes_int=$(stat -c%s "$LAST_RUN_FILE")
    if (( size_bytes_int >= 10 * 1024 * 1024 )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        mv "$LAST_RUN_FILE" "$ROTATE_DIR/vm-backup-and-restore_${rotate_ts_str}.log"
        debug_log "Rotated main log"
    fi
fi
mapfile -t rotated_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null | sort)
if (( ${#rotated_logs_arr[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs_arr[@]}; i++ )); do rm -f "${rotated_logs_arr[$i]}"; done
fi

# Log rotation: debug log
if [[ -f "$DEBUG_LOG" ]]; then
    size_bytes_int=$(stat -c%s "$DEBUG_LOG")
    if (( size_bytes_int >= 10 * 1024 * 1024 )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        mv "$DEBUG_LOG" "$ROTATE_DIR/vm-restore-debug_${rotate_ts_str}.log"
    fi
fi
mapfile -t rotated_debug_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-restore-debug_*.log 2>/dev/null | sort)
if (( ${#rotated_debug_logs_arr[@]} > 10 )); then
    for (( i=10; i<${#rotated_debug_logs_arr[@]}; i++ )); do rm -f "${rotated_debug_logs_arr[$i]}"; done
fi

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

PLG_FILE="/boot/config/plugins/vm-backup-and-restore.plg"
[[ -f "$PLG_FILE" ]] && version_str=$(grep -oP 'version="\K[^"]+' "$PLG_FILE" | head -n1) || version_str="unknown"

echo "--------------------------------------------------------------------------------------------------"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore session started - Plugin version: $version_str"

# Cleanup trap
cleanup() {
    local end_epoch_int duration_int
    end_epoch_int=$(date +%s)
    duration_int=$(( end_epoch_int - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$duration_int")"
    LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"
    rm -f "$LOCK_FILE"
    debug_log "Lock file removed"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        debug_log "Stop flag detected in cleanup — rolling back restored files"
        set_restore_status "Restore stopped and cleaned up"

        for f_str in "${RESTORED_FILES_arr[@]}"; do
            rm -f "$f_str"
            debug_log "Removed restored file: $f_str"
        done
        for tmp_str in "${TEMP_FILES_arr[@]}"; do
            original_str="${tmp_str%.pre_restore_tmp}"
            mv "$tmp_str" "$original_str"
            debug_log "Restored temp file: $tmp_str -> $original_str"
        done
        for vm_str in "${vm_names_arr[@]}"; do
            [[ -z "$vm_str" ]] && continue
            vm_folder_str="$vm_domains_str/$vm_str"
            if [[ -d "$vm_folder_str" && -z "$(ls -A "$vm_folder_str")" ]]; then
                rmdir "$vm_folder_str"
                debug_log "Removed empty folder: $vm_folder_str"
            fi
        done

        echo "Restore was stopped early. Cleaned up files created this run"
        debug_log "===== Session ended (stopped early) ====="
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore session finished - Duration: $SCRIPT_DURATION_HUMAN"
        notify_restore "warning" "VM Backup & Restore" "Restore was stopped early - Duration: $SCRIPT_DURATION_HUMAN"
        set_restore_status "Restore stopped and cleaned up"
        rm -f "$RESTORE_STATUS_FILE"
        return
    fi

    for tmp_str in "${TEMP_FILES_arr[@]}"; do
        rm -f "$tmp_str"
        debug_log "Removed temp file: $tmp_str"
    done

    if [[ "$DRY_RUN" != "yes" ]]; then
        for vm_str in "${STOPPED_VMS_arr[@]}"; do
            echo "Starting $vm_str"
            debug_log "Restarting VM: $vm_str"
            run_cmd virsh start "$vm_str"
        done
    else
        echo "Skipping VM restarts because dry run is enabled"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore session finished - Duration: $SCRIPT_DURATION_HUMAN"
    debug_log "Session finished - duration=$SCRIPT_DURATION_HUMAN error_count=$error_count_int"
    set_restore_status "Restore complete - Duration: $SCRIPT_DURATION_HUMAN"

    if (( error_count_int > 0 )); then
        notify_restore "warning" "VM Backup & Restore" "Restore finished with errors - Duration: $SCRIPT_DURATION_HUMAN - Check logs for details"
    else
        notify_restore "normal" "VM Backup & Restore" "Restore finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi

    rm -f "$RESTORE_STATUS_FILE"
    debug_log "===== Session ended ====="
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
debug_log "Loading config: $CONFIG"
source "$CONFIG" || { debug_log "ERROR: Failed to source config: $CONFIG"; exit 1; }

# physical_mount_path <path>
# Returns the mount point that owns <path> using df, walking up the path if needed.
physical_mount_path() {
    local path_str="$1"
    local check_str="$path_str"
    while [[ -n "$check_str" && "$check_str" != "/" ]]; do
        if [[ -e "$check_str" ]]; then
            local mount_str
            mount_str=$(df --output=target "$check_str" 2>/dev/null | tail -n1)
            [[ -n "$mount_str" ]] && { echo "$mount_str"; return; }
        fi
        check_str="$(dirname "$check_str")"
    done
    echo "$(readlink -f "$path_str" 2>/dev/null || echo "$path_str")"
}

classify_path() {
    local path_str="$1"
    local mount_str
    mount_str=$(physical_mount_path "$path_str")
    if [[ "$mount_str" == /mnt/user  || "$mount_str" == /mnt/user/*  ]];    then echo "USER";   return; fi
    if [[ "$mount_str" == /mnt/user0 || "$mount_str" == /mnt/user0/* ]];    then echo "USER0";  return; fi
    if [[ "$mount_str" == /mnt/remotes || "$mount_str" == /mnt/remotes/* ]]; then echo "EXEMPT"; return; fi
    if [[ "$mount_str" == /mnt/addons  || "$mount_str" == /mnt/addons/*  ]]; then echo "EXEMPT"; return; fi
    if [[ "$mount_str" == /mnt/* ]]; then echo "DISK"; return; fi
    echo "OTHER"
}

validate_mount_compatibility() {
    local src_str="$1" dst_str="$2"
    local src_class_str dst_class_str
    src_class_str=$(classify_path "$src_str")
    dst_class_str=$(classify_path "$dst_str")
    debug_log "validate_mount_compatibility: src=$src_str ($src_class_str) dst=$dst_str ($dst_class_str)"
    local allowed_int=0
    case "$src_class_str" in
        USER)   [[ "$dst_class_str" == "USER"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        USER0)  [[ "$dst_class_str" == "USER0" || "$dst_class_str" == "DISK"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        DISK)   [[ "$dst_class_str" == "DISK"  || "$dst_class_str" == "USER0" || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        EXEMPT) allowed_int=1 ;;
    esac
    if [[ "$allowed_int" -eq 0 ]]; then
        echo "[ERROR] Backup source ($src_str, class: $src_class_str) is incompatible with restore destination ($dst_str, class: $dst_class_str)"
        debug_log "ERROR: Mount type mismatch src=$src_str ($src_class_str) dst=$dst_str ($dst_class_str)"
        return 1
    fi
    return 0
}

# Webhook cleanup
WEBHOOK_DISCORD_RESTORE="${WEBHOOK_DISCORD_RESTORE//\"/}"
WEBHOOK_GOTIFY_RESTORE="${WEBHOOK_GOTIFY_RESTORE//\"/}"
WEBHOOK_NTFY_RESTORE="${WEBHOOK_NTFY_RESTORE//\"/}"
WEBHOOK_PUSHOVER_RESTORE="${WEBHOOK_PUSHOVER_RESTORE//\"/}"
WEBHOOK_SLACK_RESTORE="${WEBHOOK_SLACK_RESTORE//\"/}"
PUSHOVER_USER_KEY_RESTORE="${PUSHOVER_USER_KEY_RESTORE//\"/}"

notify_restore() {
    local level_str="$1" title_str="$2" message_str="$3"
    debug_log "notify_restore: level=$level_str title=$title_str"
    [[ "$NOTIFICATIONS_RESTORE" != "yes" ]] && return 0
    local color_int
    case "$level_str" in alert) color_int=15158332;; warning) color_int=16776960;; *) color_int=3066993;; esac
    IFS=',' read -ra services_arr <<< "$NOTIFICATION_SERVICE_RESTORE"
    for service_str in "${services_arr[@]}"; do
        service_str="${service_str// /}"
        case "$service_str" in
            Discord)  [[ -n "$WEBHOOK_DISCORD_RESTORE" ]]  && curl -sf -X POST "$WEBHOOK_DISCORD_RESTORE"  -H "Content-Type: application/json" -d "{\"embeds\":[{\"title\":\"$title_str\",\"description\":\"$message_str\",\"color\":$color_int}]}" || true ;;
            Gotify)   [[ -n "$WEBHOOK_GOTIFY_RESTORE" ]]   && curl -sf -X POST "$WEBHOOK_GOTIFY_RESTORE"   -H "Content-Type: application/json" -d "{\"title\":\"$title_str\",\"message\":\"$message_str\",\"priority\":5}" || true ;;
            Ntfy)     [[ -n "$WEBHOOK_NTFY_RESTORE" ]]     && curl -sf -X POST "$WEBHOOK_NTFY_RESTORE"     -H "Title: $title_str" -d "$message_str" > /dev/null || true ;;
            Pushover) [[ -n "$WEBHOOK_PUSHOVER_RESTORE" && -n "$PUSHOVER_USER_KEY_RESTORE" ]] && curl -sf -X POST "https://api.pushover.net/1/messages.json" -d "token=${WEBHOOK_PUSHOVER_RESTORE##*/}" -d "user=${PUSHOVER_USER_KEY_RESTORE}" -d "title=${title_str}" -d "message=${message_str}" > /dev/null || true ;;
            Slack)    [[ -n "$WEBHOOK_SLACK_RESTORE" ]]    && curl -sf -X POST "$WEBHOOK_SLACK_RESTORE"    -H "Content-Type: application/json" -d "{\"text\":\"*$title_str*\n$message_str\"}" || true ;;
            Unraid)   [[ -x /usr/local/emhttp/webGui/scripts/notify ]] && /usr/local/emhttp/webGui/scripts/notify -e "VM Backup & Restore" -s "$title_str" -d "$message_str" -i "$level_str" ;;
            *) debug_log "Unknown notification service: $service_str" ;;
        esac
    done
}

error_count_int=0
notify_restore "normal" "VM Backup & Restore" "Restore started"
sleep 5

IFS=',' read -r -a vm_names_arr <<< "$VMS_TO_RESTORE"
DRY_RUN="$DRY_RUN_RESTORE"

# Keep paths exactly as entered — do not resolve symlinks at startup.
backup_path_str="${LOCATION_OF_BACKUPS:-}"
vm_domains_str="${RESTORE_DESTINATION:-}"
if [[ -n "$backup_path_str" ]]; then
    _resolved_str=$(readlink -f "$backup_path_str" 2>/dev/null || echo "$backup_path_str")
    log_path_resolution "Backups Location" "$backup_path_str" "$_resolved_str"
    unset _resolved_str
fi
if [[ -n "$vm_domains_str" ]]; then
    _resolved_str=$(readlink -f "$vm_domains_str" 2>/dev/null || echo "$vm_domains_str")
    log_path_resolution "Restore Destination" "$vm_domains_str" "$_resolved_str"
    unset _resolved_str
fi
debug_log "LOCATION_OF_BACKUPS=$backup_path_str"
debug_log "RESTORE_DESTINATION=$vm_domains_str"

debug_log "===== Session started ====="
debug_log "VMS_TO_RESTORE=$VMS_TO_RESTORE DRY_RUN=$DRY_RUN"
debug_log "backup_path=$backup_path_str vm_domains=$vm_domains_str"

if [[ -n "$backup_path_str" && -n "$vm_domains_str" ]]; then
    if ! validate_mount_compatibility "$backup_path_str" "$vm_domains_str"; then
        set_restore_status "Aborted — mount type mismatch between backup source and restore destination"
        exit 1
    fi
fi

mapfile -t RUNNING_BEFORE_arr < <(virsh list --state-running --name | grep -Fxv "")
debug_log "VMs running before restore: ${RUNNING_BEFORE_arr[*]:-none}"
STOPPED_VMS_arr=()

xml_base_str="/etc/libvirt/qemu"
nvram_base_dir_str="$xml_base_str/nvram"
mkdir -p "$nvram_base_dir_str"

run_cmd() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '[DRY RUN] '; printf '%q ' "$@"; echo; return
    fi
    if [[ "$1" == "virsh" && "$2" == "define" ]]; then "$@" >/dev/null; return; fi
    if [[ "$1" == "virsh" && ( "$2" == "shutdown" || "$2" == "destroy" || "$2" == "start" ) ]]; then
        shift; virsh --quiet "$@" >/dev/null; return
    fi
    "$@"
}

# run_rsync_meta: for small metadata files (XML, NVRAM) — --sparse is safe
run_rsync_meta() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '[DRY RUN] '; printf '%q ' rsync "$@"; echo; return 0
    fi
    debug_log "run_rsync_meta: rsync ${*}"
    rsync "$@" &
    RSYNC_PID=$!
    wait $RSYNC_PID
    local exit_code_int=$?
    RSYNC_PID=""
    debug_log "rsync_meta finished exit=$exit_code_int"
    return $exit_code_int
}

# restore_vdisk <src> <dest>
# Format-aware restore matching the same strategy as copy_vdisk in backup.sh:
#
#   qcow2, same-fs  → cp --reflink=always (instant CoW)
#   qcow2, diff-fs  → qemu-img convert   (allocated clusters only)
#   raw,   same-fs  → cp --reflink=always (instant CoW)
#   raw,   diff-fs  → rsync --sparse      (safe: dest is always rm'd first so it's a fresh file)
#
# --sparse is safe here because restore.sh always removes the destination before
# writing (rm -f "$dest"), so there is no pre-existing data that sparse holes
# could expose.
restore_vdisk() {
    local src_str="$1"
    local dest_str="$2"

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '[DRY RUN] restore_vdisk %q -> %q
' "$src_str" "$dest_str"
        return 0
    fi

    debug_log "restore_vdisk: $src_str -> $dest_str"

    # Detect format from source file header
    local fmt_str="raw"
    if command -v qemu-img >/dev/null 2>&1; then
        fmt_str=$(qemu-img info --output=json "$src_str" 2>/dev/null                   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null)
        [[ -z "$fmt_str" ]] && fmt_str="raw"
    fi
    debug_log "restore_vdisk: format=$fmt_str"

    # Try reflink first — instant on same-filesystem Btrfs/XFS
    if cp --reflink=always "$src_str" "$dest_str" 2>/dev/null; then
        debug_log "restore_vdisk: reflink OK (instant CoW)"
        return 0
    fi

    # Cross-filesystem or no reflink support
    if [[ "$fmt_str" == "qcow2" ]]; then
        debug_log "restore_vdisk: qemu-img convert (qcow2, allocated clusters only)"
        qemu-img convert -f qcow2 -O qcow2 -W -p "$src_str" "$dest_str" 2>/dev/null &
        local qimg_pid_int=$!
        wait $qimg_pid_int
        local exit_code_int=$?
        if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
            debug_log "restore_vdisk: qemu-img interrupted (exit=$exit_code_int)"; exit 1
        fi
        if [[ $exit_code_int -eq 0 ]]; then
            debug_log "restore_vdisk: qemu-img convert OK"
            return 0
        fi
        debug_log "restore_vdisk: qemu-img failed (exit=$exit_code_int), falling back to rsync"
        rm -f "$dest_str"
    fi

    # raw disk: qemu-img convert skips unallocated extents via block layer.
    # Better than rsync --sparse which only skips zero byte runs.
    if command -v qemu-img >/dev/null 2>&1 && [[ "$fmt_str" == "raw" ]]; then
        debug_log "restore_vdisk: qemu-img convert (raw, unallocated extents skipped)"
        qemu-img convert -f raw -O raw -W -p "$src_str" "$dest_str" 2>/dev/null &
        local qimg_pid_int=$!
        wait $qimg_pid_int
        local exit_code_int=$?
        if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
            debug_log "restore_vdisk: qemu-img interrupted (exit=$exit_code_int)"; exit 1
        fi
        if [[ $exit_code_int -eq 0 ]]; then
            debug_log "restore_vdisk: qemu-img convert raw OK"
            return 0
        fi
        debug_log "restore_vdisk: qemu-img raw failed (exit=$exit_code_int), falling back to rsync"
        rm -f "$dest_str"
    fi

    # Final fallback: rsync --sparse. Safe because dest is always rm'd before this call.
    rsync -aHAX --sparse --no-perms --no-owner --no-group "$src_str" "$dest_str" &
    RSYNC_PID=$!
    wait $RSYNC_PID
    local exit_code_int=$?
    RSYNC_PID=""
    if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
        debug_log "restore_vdisk: rsync interrupted (exit=$exit_code_int)"; exit 1
    fi
    debug_log "restore_vdisk: rsync finished exit=$exit_code_int"
    return $exit_code_int
}

declare -A version_map_arr
IFS=',' read -ra pairs_arr <<< "$VERSIONS"
for p_str in "${pairs_arr[@]}"; do
    vm_name_str="${p_str%%=*}"
    ts_str="${p_str#*=}"
    ts_str="${ts_str//-/_}"
    version_map_arr["$vm_name_str"]="$ts_str"
    debug_log "version_map: $vm_name_str -> $ts_str"
done

for vm_str in "${vm_names_arr[@]}"; do
    set_restore_status "Starting restore for $vm_str"
    debug_log "--- Starting restore for VM: $vm_str ---"

    backup_dir_str="$backup_path_str/$vm_str"
    log_backup_dir_str="${_raw_backup_path_str:-$backup_path_str}/$vm_str"
    version_str="${version_map_arr[$vm_str]}"
    debug_log "backup_dir=$backup_dir_str version=$version_str"

    if [[ -z "$version_str" ]]; then
        echo "[ERROR] No restore version specified for VM $vm_str — skipping"
        debug_log "Validation failed: no version for $vm_str"
        (( error_count_int++ )); continue
    fi

    prefix_str="${version_str}_"
    debug_log "prefix=$prefix_str"

    xml_file_str=$(ls "$backup_dir_str"/"${prefix_str}"*.xml 2>/dev/null | head -n1)
    nvram_file_str=$(ls "$backup_dir_str"/"${prefix_str}"*VARS*.fd 2>/dev/null | head -n1)
    disks_arr=( "$backup_dir_str"/"${prefix_str}"vdisk*.img "$backup_dir_str"/"${prefix_str}"*.qcow2 )

    debug_log "xml=${xml_file_str:-not found} nvram=${nvram_file_str:-not found}"
    debug_log "disks: ${disks_arr[*]}"

    # Pre-flight validation
    missing_files_arr=()
    if [[ ! -d "$backup_dir_str" ]]; then
        echo "[ERROR] Backup folder missing: $backup_dir_str — skipping $vm_str"
        (( error_count_int++ )); continue
    fi
    [[ ! -f "$xml_file_str" ]]   && missing_files_arr+=("XML (.xml)")
    [[ ! -f "$nvram_file_str" ]] && missing_files_arr+=("NVRAM (*VARS*.fd)")
    has_vdisk_bool=false
    for d_str in "${disks_arr[@]}"; do [[ -f "$d_str" ]] && { has_vdisk_bool=true; break; }; done
    [[ "$has_vdisk_bool" == false ]] && missing_files_arr+=("vdisk (vdisk*.img or *.qcow2)")

    if (( ${#missing_files_arr[@]} > 0 )); then
        echo "[ERROR] Backup for $vm_str (version: $version_str) is incomplete — missing:"
        for mf_str in "${missing_files_arr[@]}"; do echo "[ERROR]   - $mf_str"; done
        echo "[ERROR] Skipping $vm_str — no files modified"
        debug_log "Validation failed for $vm_str: missing ${missing_files_arr[*]}"
        (( error_count_int++ )); continue
    fi

    WAS_RUNNING_bool=false
    printf '%s\n' "${RUNNING_BEFORE_arr[@]}" | grep -Fxq "$vm_str" && WAS_RUNNING_bool=true
    debug_log "WAS_RUNNING=$WAS_RUNNING_bool"

    echo "Starting restore for $vm_str"

    # Shutdown
    set_restore_status "Stopping $vm_str"
    if virsh list --state-running --name | grep -Fxq "$vm_str"; then
        echo "Stopping $vm_str"
        run_cmd virsh shutdown "$vm_str"
        sleep 10
        if virsh list --state-running --name | grep -Fxq "$vm_str"; then
            echo "$vm_str still running — forcing stop"
            run_cmd virsh destroy "$vm_str"
        fi
        [[ "$WAS_RUNNING_bool" == true ]] && STOPPED_VMS_arr+=("$vm_str")
    else
        echo "$vm_str is not running"
    fi

    # Restore XML
    set_restore_status "Restoring XML for $vm_str"
    dest_xml_str="$xml_base_str/$vm_str.xml"
    debug_log "Restoring XML: $xml_file_str -> $dest_xml_str"
    if [[ -f "$dest_xml_str" ]]; then
        cp "$dest_xml_str" "${dest_xml_str}.pre_restore_tmp"
        TEMP_FILES_arr+=("${dest_xml_str}.pre_restore_tmp")
    fi
    run_cmd rm -f "$dest_xml_str"
    run_rsync_meta -a --sparse --no-perms --no-owner --no-group "$xml_file_str" "$dest_xml_str"
    RESTORED_FILES_arr+=("$dest_xml_str")
    run_cmd chmod 644 "$dest_xml_str"
    echo "Restored XML $xml_file_str → $dest_xml_str"
    [[ -f "$STOP_FLAG" ]] && exit 1

    # Restore NVRAM
    set_restore_status "Restoring NVRAM for $vm_str"
    nvram_filename_str=$(basename "$nvram_file_str")
    nvram_filename_str="${nvram_filename_str#$prefix_str}"
    dest_nvram_str="$nvram_base_dir_str/$nvram_filename_str"
    debug_log "Restoring NVRAM: $nvram_file_str -> $dest_nvram_str"
    if [[ -f "$dest_nvram_str" ]]; then
        cp "$dest_nvram_str" "${dest_nvram_str}.pre_restore_tmp"
        TEMP_FILES_arr+=("${dest_nvram_str}.pre_restore_tmp")
    fi
    run_cmd rm -f "$dest_nvram_str"
    run_rsync_meta -a --sparse --no-perms --no-owner --no-group "$nvram_file_str" "$dest_nvram_str"
    RESTORED_FILES_arr+=("$dest_nvram_str")
    run_cmd chmod 644 "$dest_nvram_str"
    echo "Restored NVRAM $nvram_file_str → $dest_nvram_str"
    [[ -f "$STOP_FLAG" ]] && exit 1

    # Restore vdisks — NO --sparse to prevent zero-hole corruption
    set_restore_status "Restoring vdisks for $vm_str"
    dest_domain_str="$vm_domains_str/$vm_str"
    log_dest_domain_str="$vm_domains_str/$vm_str"
    debug_log "dest_domain=$dest_domain_str"

    parent_dataset_str=$(zfs list -H -o name "$(dirname "$dest_domain_str")" 2>/dev/null)
    if [[ -n "$parent_dataset_str" ]]; then
        run_cmd zfs create "$parent_dataset_str/$(basename "$dest_domain_str")" 2>/dev/null || true
    else
        run_cmd mkdir -p "$dest_domain_str"
    fi

    for d_str in "${disks_arr[@]}"; do
        [[ -f "$d_str" ]] || continue
        file_str=$(basename "$d_str")
        file_str="${file_str#$prefix_str}"
        debug_log "Restoring vdisk: $d_str -> $dest_domain_str/$file_str"
        run_cmd rm -f "$dest_domain_str/$file_str"
        restore_vdisk "$d_str" "$dest_domain_str/$file_str"
        RESTORED_FILES_arr+=("$dest_domain_str/$file_str")
        run_cmd chmod 644 "$dest_domain_str/$file_str"
        echo "Restored vdisk $d_str → $log_dest_domain_str/$file_str"
        [[ -f "$STOP_FLAG" ]] && exit 1
    done

    # Restore extra files (non-vdisk, non-xml, non-nvram files in backup)
    set_restore_status "Restoring extra files for $vm_str"
    for extra_file_str in "$backup_dir_str"/"${prefix_str}"*; do
        [[ -f "$extra_file_str" ]] || continue
        already_copied_bool=false
        for d_str in "${disks_arr[@]}"; do
            [[ "$extra_file_str" == "$d_str" ]] && { already_copied_bool=true; break; }
        done
        [[ "$already_copied_bool" == true ]] && continue
        case "$(basename "$extra_file_str")" in
            *.xml) continue ;;
            *VARS*.fd) continue ;;
        esac
        file_str=$(basename "$extra_file_str")
        file_str="${file_str#$prefix_str}"
        debug_log "Restoring extra file: $extra_file_str -> $dest_domain_str/$file_str"
        run_cmd rm -f "$dest_domain_str/$file_str"
        restore_vdisk "$extra_file_str" "$dest_domain_str/$file_str"
        RESTORED_FILES_arr+=("$dest_domain_str/$file_str")
        run_cmd chmod 644 "$dest_domain_str/$file_str"
        echo "Restored extra file $extra_file_str → $log_dest_domain_str/$file_str"
        [[ -f "$STOP_FLAG" ]] && exit 1
    done

    # Redefine VM
    set_restore_status "Redefining $vm_str"
    debug_log "Redefining VM from: $dest_xml_str"
    run_cmd virsh define "$dest_xml_str"
    echo "Redefined $vm_str from $dest_xml_str"

    echo "Finished restore for $vm_str"
    set_restore_status "Finished restore for $vm_str"
    debug_log "--- Finished restore for VM: $vm_str ---"
done

debug_log "All VMs processed"