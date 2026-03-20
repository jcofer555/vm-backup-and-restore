#!/usr/bin/env bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_START_EPOCH=$(date +%s)
STOP_FLAG="/tmp/vm-backup-and-restore/stop_requested.txt"
RSYNC_PID=""
WATCHER_PID=""

LOG_DIR="/tmp/vm-backup-and-restore"
LOCK_FILE="$LOG_DIR/lock.txt"
LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
DEBUG_LOG="$LOG_DIR/vm-backup-and-restore-debug.log"
STATUS_FILE="$LOG_DIR/backup_status.txt"

mkdir -p "$LOG_DIR"
mkdir -p "$ROTATE_DIR"

# ------------------------------------------------------------------------------
# SHELL-SIDE LOCK — authoritative lock; PHP placeholder written before launch.
# FD 200 stays open for the life of the process; EXIT trap removes the file.
# ------------------------------------------------------------------------------
LOCK_FD=200
exec 200>"$LOCK_FILE"
if ! flock -n $LOCK_FD; then
    echo "Another backup is already running. Exiting." >&2
    exit 1
fi
printf "PID=%s\nMODE=manual\nSTART=%s\n" "$$" "$(date +%s)" > "$LOCK_FILE"
# ------------------------------------------------------------------------------

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

classify_path() {
    local path_str="$1"
    local resolved_str
    resolved_str=$(readlink -f "$path_str" 2>/dev/null || echo "$path_str")

    if [[ "$resolved_str" == /mnt/user  || "$resolved_str" == /mnt/user/*  ]];    then echo "USER";   return; fi
    if [[ "$resolved_str" == /mnt/user0 || "$resolved_str" == /mnt/user0/* ]];    then echo "USER0";  return; fi
    if [[ "$resolved_str" == /mnt/remotes || "$resolved_str" == /mnt/remotes/* ]]; then echo "EXEMPT"; return; fi
    if [[ "$resolved_str" == /mnt/addons  || "$resolved_str" == /mnt/addons/*  ]]; then echo "EXEMPT"; return; fi
    if [[ "$resolved_str" == /mnt/* ]]; then echo "DISK"; return; fi
    echo "OTHER"
}

# Allowlist matrix:
#   USER  -> USER, EXEMPT
#   USER0 -> USER0, DISK, EXEMPT
#   DISK  -> DISK, EXEMPT
#   EXEMPT-> USER, USER0, DISK, EXEMPT  (always allowed)
validate_mount_compatibility() {
    local src_str="$1"
    local dst_str="$2"
    local resolved_src_str resolved_dst_str src_class_str dst_class_str

    resolved_src_str=$(readlink -f "$(dirname "$src_str")" 2>/dev/null)/$(basename "$src_str")
    resolved_dst_str=$(readlink -f "$dst_str" 2>/dev/null)
    src_class_str=$(classify_path "$resolved_src_str")
    dst_class_str=$(classify_path "$resolved_dst_str")

    debug_log "validate_mount_compatibility: src=$src_str ($src_class_str) dst=$dst_str ($dst_class_str)"

    local allowed_int=0
    case "$src_class_str" in
        USER)   [[ "$dst_class_str" == "USER"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        USER0)  [[ "$dst_class_str" == "USER0" || "$dst_class_str" == "DISK" || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        DISK)   [[ "$dst_class_str" == "DISK"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        EXEMPT) allowed_int=1 ;;
    esac

    if [[ "$allowed_int" -eq 0 ]]; then
        echo "[ERROR] Vdisk $src_str is on mount type ($src_class_str) and backup destination ($dst_class_str) — incompatible combination"
        echo "[ERROR] USER can only back up to USER or EXEMPT (remotes/addons). USER0 can go to USER0, DISK, or EXEMPT. DISK can go to DISK or EXEMPT."
        debug_log "ERROR: Mount type mismatch - src=$src_str ($src_class_str) dst=$dst_str ($dst_class_str)"
        set_status "Mount type mismatch for $src_str"
        return 1
    fi
    return 0
}

cleanup_partial_backup() {
    local folder_str="$1"
    local ts_str="$2"

    [[ ! -d "$folder_str" ]] && return

    shopt -s nullglob
    local run_files_arr=( "$folder_str/${ts_str}_"* )
    shopt -u nullglob

    debug_log "cleanup_partial_backup: folder=$folder_str ts=$ts_str files=${#run_files_arr[@]}"

    for f_str in "${run_files_arr[@]}"; do
        rm -f "$f_str"
        debug_log "Removed partial file: $f_str"
    done

    if [[ -z "$(ls -A "$folder_str")" ]]; then
        rmdir "$folder_str"
        debug_log "Removed empty folder: $folder_str"
    fi
}

run_rsync() {
    if is_dry_run; then
        printf '[DRY-RUN] '
        printf '%q ' rsync "$@"
        echo
        return 0
    fi

    debug_log "run_rsync: rsync ${*}"
    rsync "$@" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "$LOG_DIR/rsync.pid"
    wait $RSYNC_PID
    local exit_code_int=$?
    RSYNC_PID=""
    rm -f "$LOG_DIR/rsync.pid"
    if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
        debug_log "run_rsync: interrupted (exit_code=$exit_code_int stop_flag=$([ -f "$STOP_FLAG" ] && echo yes || echo no))"
        exit 1
    fi
    debug_log "rsync finished with exit_code=$exit_code_int"
    return $exit_code_int
}

set_status() { echo "$1" > "$STATUS_FILE"; }

debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session started debug - $*" >> "$DEBUG_LOG"
}

log_path_resolution() {
    local label_str="$1"
    local raw_str="$2"
    local resolved_str="$3"
    if [[ -n "$raw_str" && "$raw_str" != "$resolved_str" ]]; then
        echo "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str (symlink followed)"
        debug_log "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str (symlink followed)"
    else
        debug_log "$label_str: $resolved_str (no symlink resolution needed)"
    fi
}

set_status "Started backup session"

# --- Log rotation: main log ---
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes_int=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes_int=$((10 * 1024 * 1024))
    if (( size_bytes_int >= max_bytes_int )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        rotated_log_str="$ROTATE_DIR/vm-backup-and-restore_${rotate_ts_str}.log"
        mv "$LAST_RUN_FILE" "$rotated_log_str"
        debug_log "Rotated main log to $rotated_log_str"
    fi
fi

mapfile -t rotated_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null | sort)
if (( ${#rotated_logs_arr[@]} > 10 )); then
    for (( i=10; i<${#rotated_logs_arr[@]}; i++ )); do
        rm -f "${rotated_logs_arr[$i]}"
        debug_log "Purged old rotated log: ${rotated_logs_arr[$i]}"
    done
fi

# --- Log rotation: debug log ---
if [[ -f "$DEBUG_LOG" ]]; then
    size_bytes_int=$(stat -c%s "$DEBUG_LOG")
    max_bytes_int=$((10 * 1024 * 1024))
    if (( size_bytes_int >= max_bytes_int )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        mv "$DEBUG_LOG" "$ROTATE_DIR/vm-backup-and-restore-debug_${rotate_ts_str}.log"
        debug_log "Rotated debug log"
    fi
fi

mapfile -t rotated_debug_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore-debug_*.log 2>/dev/null | sort)
if (( ${#rotated_debug_logs_arr[@]} > 10 )); then
    for (( i=10; i<${#rotated_debug_logs_arr[@]}; i++ )); do
        rm -f "${rotated_debug_logs_arr[$i]}"
        debug_log "Purged old rotated debug log: ${rotated_debug_logs_arr[$i]}"
    done
fi

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

# --- Plugin version ---
PLG_FILE="/boot/config/plugins/vm-backup-and-restore.plg"
if [[ -f "$PLG_FILE" ]]; then
    version_str=$(grep -oP 'version="\K[^"]+' "$PLG_FILE" | head -n1)
else
    version_str="unknown"
fi

echo "--------------------------------------------------------------------------------------------------"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session started - Plugin version: $version_str"

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
debug_log "Loading config: $CONFIG"
source "$CONFIG" || { debug_log "ERROR: Failed to source config: $CONFIG"; exit 1; }

# --- Dry run support ---
DRY_RUN="${DRY_RUN:-no}"
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

# --- Notification webhook cleanup ---
WEBHOOK_DISCORD="${WEBHOOK_DISCORD//\"/}"
WEBHOOK_GOTIFY="${WEBHOOK_GOTIFY//\"/}"
WEBHOOK_NTFY="${WEBHOOK_NTFY//\"/}"
WEBHOOK_PUSHOVER="${WEBHOOK_PUSHOVER//\"/}"
WEBHOOK_SLACK="${WEBHOOK_SLACK//\"/}"
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY//\"/}"

notify_vm() {
    local level_str="$1"
    local title_str="$2"
    local message_str="$3"

    debug_log "notify_vm: level=$level_str title=$title_str"
    [[ "${NOTIFICATIONS:-no}" != "yes" ]] && { debug_log "Notifications disabled"; return 0; }

    local color_int
    case "$level_str" in
        alert)   color_int=15158332 ;;
        warning) color_int=16776960 ;;
        *)       color_int=3066993  ;;
    esac

    IFS=',' read -ra services_arr <<< "$NOTIFICATION_SERVICE"

    for service_str in "${services_arr[@]}"; do
        service_str="${service_str// /}"
        case "$service_str" in
            Discord)
                [[ -n "$WEBHOOK_DISCORD" ]] && curl -sf -X POST "$WEBHOOK_DISCORD" \
                    -H "Content-Type: application/json" \
                    -d "{\"embeds\":[{\"title\":\"$title_str\",\"description\":\"$message_str\",\"color\":$color_int}]}" || true
                ;;
            Gotify)
                [[ -n "$WEBHOOK_GOTIFY" ]] && curl -sf -X POST "$WEBHOOK_GOTIFY" \
                    -H "Content-Type: application/json" \
                    -d "{\"title\":\"$title_str\",\"message\":\"$message_str\",\"priority\":5}" || true
                ;;
            Ntfy)
                [[ -n "$WEBHOOK_NTFY" ]] && curl -sf -X POST "$WEBHOOK_NTFY" \
                    -H "Title: $title_str" \
                    -d "$message_str" > /dev/null || true
                ;;
            Pushover)
                if [[ -n "$WEBHOOK_PUSHOVER" && -n "$PUSHOVER_USER_KEY" ]]; then
                    local token_str="${WEBHOOK_PUSHOVER##*/}"
                    curl -sf -X POST "https://api.pushover.net/1/messages.json" \
                        -d "token=${token_str}" \
                        -d "user=${PUSHOVER_USER_KEY}" \
                        -d "title=${title_str}" \
                        -d "message=${message_str}" > /dev/null || true
                fi
                ;;
            Slack)
                [[ -n "$WEBHOOK_SLACK" ]] && curl -sf -X POST "$WEBHOOK_SLACK" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"*$title_str*\n$message_str\"}" || true
                ;;
            Unraid)
                if [[ -x /usr/local/emhttp/webGui/scripts/notify ]]; then
                    /usr/local/emhttp/webGui/scripts/notify \
                        -e "VM Backup & Restore" \
                        -s "$title_str" \
                        -d "$message_str" \
                        -i "$level_str"
                fi
                ;;
            *) debug_log "Unknown notification service: $service_str" ;;
        esac
    done
}

error_count_int=0
notify_vm "normal" "VM Backup & Restore" "Backup started"
sleep 5

# --- Config-derived variables ---
BACKUPS_TO_KEEP="${BACKUPS_TO_KEEP:-0}"
backup_owner_str="${BACKUP_OWNER:-nobody}"

# --- Resolve backup destination to its real path at runtime ---
# This ensures symlinks (e.g. /mnt/user -> /mnt/user0) are followed correctly
# without writing the resolved path back to settings.cfg or the UI.
_raw_backup_location_str="${BACKUP_DESTINATION:-}"
if [[ -n "$_raw_backup_location_str" ]]; then
    backup_location_str=$(readlink -f "$_raw_backup_location_str" 2>/dev/null || echo "$_raw_backup_location_str")
else
    backup_location_str=""
fi
export backup_location_str
log_path_resolution "BACKUP_DESTINATION" "$_raw_backup_location_str" "$backup_location_str"

debug_log "===== Session started ====="
debug_log "DRY_RUN=$DRY_RUN BACKUPS_TO_KEEP=$BACKUPS_TO_KEEP backup_owner=$backup_owner_str backup_location=$backup_location_str"

# --- Space-safe VM parsing ---
readarray -td ',' VM_ARRAY_arr <<< "${VMS_TO_BACKUP:-},"
CLEAN_VMS_arr=()
for vm_raw_str in "${VM_ARRAY_arr[@]}"; do
    vm_raw_str="${vm_raw_str#"${vm_raw_str%%[![:space:]]*}"}"
    vm_raw_str="${vm_raw_str%"${vm_raw_str##*[![:space:]]}"}"
    [[ -n "$vm_raw_str" ]] && CLEAN_VMS_arr+=("$vm_raw_str")
done

debug_log "VMs to backup: ${CLEAN_VMS_arr[*]:-none}"

if ((${#CLEAN_VMS_arr[@]} > 0)); then
    comma_list_str=$(IFS=', '; printf '%s' "${CLEAN_VMS_arr[*]}")
    echo "VM(s) to be backed up - $comma_list_str"
else
    echo "No VMs configured for backup"
fi

declare -a vms_stopped_by_script_arr=()
declare -a vms_all_stopped_arr=()
declare -A vm_stop_method_arr=()

# --- Cleanup trap ---
cleanup() {
    kill "$WATCHER_PID" 2>/dev/null

    flock -u $LOCK_FD 2>/dev/null
    rm -f "$LOCK_FILE"
    debug_log "Lock file removed"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        debug_log "Stop flag detected in cleanup"

        local end_epoch_int duration_int
        end_epoch_int=$(date +%s)
        duration_int=$(( end_epoch_int - SCRIPT_START_EPOCH ))
        SCRIPT_DURATION_HUMAN="$(format_duration "$duration_int")"

        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "Backup was stopped early"
        else
            for vm_str in "${CLEAN_VMS_arr[@]}"; do
                [[ -z "$vm_str" ]] && continue
                cleanup_partial_backup "$backup_location_str/$vm_str" "$RUN_TS"
            done
            echo "Backup was stopped early. Cleaned up files created this run"
        fi

        if [[ "$DRY_RUN" != "yes" ]]; then
            for vm_str in "${vms_stopped_by_script_arr[@]}"; do
                [[ -z "$vm_str" ]] && continue
                echo "Starting VM $vm_str"
                debug_log "Restarting VM after stop: $vm_str"
                virsh start "$vm_str" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm_str"
            done
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
        notify_vm "warning" "VM Backup & Restore" "Backup was stopped early - Duration: $SCRIPT_DURATION_HUMAN"
        set_status "Backup stopped and cleaned up"
        rm -f "$STATUS_FILE"
        debug_log "===== Session ended (stopped early) ====="
        return
    fi

    local end_epoch_int duration_int
    end_epoch_int=$(date +%s)
    duration_int=$(( end_epoch_int - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$duration_int")"

    set_status "Backup complete - Duration: $SCRIPT_DURATION_HUMAN"

    if is_dry_run; then
        echo "Skipping VM restarts because dry run is enabled"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
        notify_vm "normal" "VM Backup & Restore" "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"
        rm -f "$STATUS_FILE"
        debug_log "===== Session ended (dry run) ====="
        return
    fi

    for vm_str in "${vms_stopped_by_script_arr[@]}"; do
        [[ -z "$vm_str" ]] && continue
        debug_log "Safety-net restart for VM: $vm_str"
        virsh start "$vm_str" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm_str"
    done

    if ((${#vms_all_stopped_arr[@]} == 0)); then
        echo "No VMs were stopped this session"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
    debug_log "Session finished - duration=$SCRIPT_DURATION_HUMAN error_count=$error_count_int"

    if (( error_count_int > 0 )); then
        notify_vm "warning" "VM Backup & Restore" "Backup finished with errors - Duration: $SCRIPT_DURATION_HUMAN - Check logs for details"
    else
        notify_vm "normal" "VM Backup & Restore" "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi

    rm -f "$STATUS_FILE"
    debug_log "===== Session ended ====="
}

_STOPPING_int=0
handle_signal() {
    if [[ "$_STOPPING_int" == "0" ]]; then
        _STOPPING_int=1
        exit 1
    fi
}

trap cleanup EXIT
trap handle_signal SIGTERM SIGINT SIGHUP SIGQUIT

# Background stop flag watcher
( trap '' SIGTERM; while true; do
    sleep 1
    if [[ -f "$STOP_FLAG" ]]; then
        kill -TERM $$ 2>/dev/null
        break
    fi
done ) &>/dev/null &
WATCHER_PID=$!

# --- Backup loop ---
RUN_TS="$(date +%Y%m%d_%H%M%S)"
debug_log "RUN_TS=$RUN_TS"
run_cmd mkdir -p "$backup_location_str"

for vm_str in "${CLEAN_VMS_arr[@]}"; do
    [[ -z "$vm_str" ]] && continue
    [[ -f "$STOP_FLAG" ]] && exit 1

    echo "Started backup for $vm_str"
    set_status "Backing up $vm_str"
    debug_log "--- Starting backup for VM: $vm_str ---"

    vm_xml_path_str="/etc/libvirt/qemu/$vm_str.xml"
    debug_log "XML path: $vm_xml_path_str"

    if [[ ! -f "$vm_xml_path_str" ]]; then
        echo "ERROR: XML not located for $vm_str"
        debug_log "ERROR: XML not found: $vm_xml_path_str"
        (( error_count_int++ ))
        continue
    fi

    vm_state_before_str="$(virsh domstate "$vm_str" 2>/dev/null || echo "unknown")"
    debug_log "VM state before backup: $vm_state_before_str"

    if [[ "$vm_state_before_str" == "running" ]]; then
        set_status "Stopping $vm_str"
        vms_stopped_by_script_arr+=("$vm_str")
        vms_all_stopped_arr+=("$vm_str")
        debug_log "Sending shutdown to $vm_str"
        run_cmd virsh shutdown "$vm_str" >/dev/null 2>&1 || echo "WARNING: Failed to send shutdown to $vm_str"

        if ! is_dry_run; then
            timeout_int=60
            while [[ "$(virsh domstate "$vm_str" 2>/dev/null)" != "shut off" && $timeout_int -gt 0 ]]; do
                [[ -f "$STOP_FLAG" ]] && exit 1
                sleep 2
                (( timeout_int -= 2 ))
            done

            if [[ $timeout_int -le 0 ]]; then
                debug_log "Shutdown timed out for $vm_str, attempting force power off"
                if virsh destroy "$vm_str" >/dev/null 2>&1; then
                    echo "Force stopped $vm_str"
                    vm_stop_method_arr[$vm_str]="forced"
                    debug_log "$vm_str force stopped successfully"
                else
                    echo "ERROR: Unable to stop $vm_str - skipping backup"
                    debug_log "ERROR: Failed to force stop $vm_str, skipping backup"
                    (( error_count_int++ ))
                    new_arr=()
                    for item_str in "${vms_stopped_by_script_arr[@]}"; do
                        [[ "$item_str" != "$vm_str" ]] && new_arr+=("$item_str")
                    done
                    vms_stopped_by_script_arr=("${new_arr[@]}")
                    new_arr=()
                    for item_str in "${vms_all_stopped_arr[@]}"; do
                        [[ "$item_str" != "$vm_str" ]] && new_arr+=("$item_str")
                    done
                    vms_all_stopped_arr=("${new_arr[@]}")
                    unset new_arr
                    continue
                fi
            else
                echo "Stopped $vm_str"
                vm_stop_method_arr[$vm_str]="normal"
                debug_log "$vm_str stopped cleanly"
            fi
        fi
    else
        debug_log "VM $vm_str was not running (state=$vm_state_before_str), no shutdown needed"
    fi

    [[ -f "$STOP_FLAG" ]] && exit 1

    vm_backup_folder_str="$backup_location_str/$vm_str"
    debug_log "vm_backup_folder=$vm_backup_folder_str"
    run_cmd mkdir -p "$vm_backup_folder_str"

    mapfile -t vdisks_arr < <(
        xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path_str" 2>/dev/null \
            | sed -E 's/ file=\"/\n/g' \
            | sed -E 's/\"//g' \
            | sed '/^$/d'
    )

    debug_log "vdisks found for $vm_str: ${vdisks_arr[*]:-none}"

    for vdisk_str in "${vdisks_arr[@]}"; do
        if ! validate_mount_compatibility "$vdisk_str" "$backup_location_str"; then
            echo "[ERROR] Skipping $vm_str due to incompatible mount types"
            debug_log "ERROR: Skipping $vm_str due to mount type incompatibility on vdisk: $vdisk_str"
            (( error_count_int++ ))
            if [[ -d "$vm_backup_folder_str" ]]; then
                shopt -s nullglob
                run_files_arr=( "$vm_backup_folder_str/${RUN_TS}_"* )
                shopt -u nullglob
                for f_str in "${run_files_arr[@]}"; do
                    rm -f "$f_str"
                    debug_log "Removed partial file: $f_str"
                done
                [[ -z "$(ls -A "$vm_backup_folder_str")" ]] && rmdir "$vm_backup_folder_str"
            fi
            continue 2
        fi
    done

    if ((${#vdisks_arr[@]} == 0)); then
        echo "No vdisk entries located in XML for $vm_str"
        debug_log "No vdisks found in XML for $vm_str"
    else
        echo "Backing up vdisks"
        set_status "Backing up vdisks for $vm_str"
        for vdisk_str in "${vdisks_arr[@]}"; do
            if [[ ! -f "$vdisk_str" ]]; then
                echo "[ERROR] $vm_str's vdisk $vdisk_str not located"
                echo "[ERROR] Skipping $vm_str"
                debug_log "ERROR: vdisk not found: $vdisk_str — skipping $vm_str"
                (( error_count_int++ ))
                cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
                continue 2
            fi
            base_str="$(basename "$vdisk_str")"
            resolved_vdisk_str="$(readlink -f "$vdisk_str" 2>/dev/null || echo "$vdisk_str")"
            dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
            is_dry_run || echo "$resolved_vdisk_str -> $dest_str"
            debug_log "Copying vdisk: $resolved_vdisk_str -> $dest_str"
            run_rsync -aHAX --sparse "$resolved_vdisk_str" "$dest_str"

            if [[ -f "$STOP_FLAG" ]]; then
                debug_log "Stop flag detected during vdisk copy for $vm_str"
                cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
                exit 1
            fi
        done

        declare -A vdisk_dirs_arr
        for vdisk_str in "${vdisks_arr[@]}"; do
            resolved_vdisk_str="$(readlink -f "$vdisk_str" 2>/dev/null || echo "$vdisk_str")"
            vdisk_dirs_arr["$(dirname "$resolved_vdisk_str")"]=1
        done

        for dir_str in "${!vdisk_dirs_arr[@]}"; do
            debug_log "Scanning for extra files in: $dir_str"
            for extra_file_str in "$dir_str"/*; do
                [[ -f "$extra_file_str" ]] || continue
                already_bool=false
                for vdisk_str in "${vdisks_arr[@]}"; do
                    resolved_vdisk_str="$(readlink -f "$vdisk_str" 2>/dev/null || echo "$vdisk_str")"
                    [[ "$extra_file_str" == "$resolved_vdisk_str" ]] && already_bool=true && break
                done
                $already_bool && continue
                base_str="$(basename "$extra_file_str")"
                dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
                echo "Backing up extra file $extra_file_str -> $dest_str"
                debug_log "Copying extra file: $extra_file_str -> $dest_str"
                run_rsync -aHAX --sparse "$extra_file_str" "$dest_str"
                if [[ -f "$STOP_FLAG" ]]; then
                    debug_log "Stop flag detected during extra file copy for $vm_str"
                    cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
                    exit 1
                fi
            done
        done
        unset vdisk_dirs_arr
    fi

    xml_dest_str="$vm_backup_folder_str/${RUN_TS}_${vm_str}.xml"
    set_status "Backing up XML for $vm_str"
    debug_log "Copying XML: $vm_xml_path_str -> $xml_dest_str"
    run_rsync -a "$vm_xml_path_str" "$xml_dest_str"
    echo "Backed up XML $vm_xml_path_str -> $xml_dest_str"

    nvram_path_str="$(xmllint --xpath 'string(/domain/os/nvram)' "$vm_xml_path_str" 2>/dev/null || echo "")"
    debug_log "NVRAM path from XML: ${nvram_path_str:-none}"

    if [[ -n "$nvram_path_str" && -f "$nvram_path_str" ]]; then
        nvram_base_str="$(basename "$nvram_path_str")"
        nvram_dest_str="$vm_backup_folder_str/${RUN_TS}_$nvram_base_str"
        set_status "Backing up NVRAM for $vm_str"
        debug_log "Copying NVRAM: $nvram_path_str -> $nvram_dest_str"
        run_rsync -a "$nvram_path_str" "$nvram_dest_str"
        echo "Backed up NVRAM $nvram_path_str -> $nvram_dest_str"
    else
        echo "No valid NVRAM located for $vm_str"
        debug_log "No valid NVRAM for $vm_str"
    fi

    run_cmd chown -R "$backup_owner_str:users" "$vm_backup_folder_str" || echo "WARNING: Changing owner failed for $vm_backup_folder_str"
    echo "Changed owner of $vm_backup_folder_str for $vm_str to $backup_owner_str:users"

    if [[ "$vm_state_before_str" == "running" ]]; then
        set_status "Starting $vm_str"
        debug_log "Restarting after backup: $vm_str"
        if run_cmd virsh start "$vm_str" >/dev/null 2>&1; then
            echo "Started $vm_str"
            debug_log "Started $vm_str successfully"
        else
            echo "WARNING: Failed to start $vm_str"
            debug_log "WARNING: Failed to start $vm_str"
        fi
        new_arr=()
        for item_str in "${vms_stopped_by_script_arr[@]}"; do
            [[ "$item_str" != "$vm_str" ]] && new_arr+=("$item_str")
        done
        vms_stopped_by_script_arr=("${new_arr[@]}")
        unset new_arr
    fi

    echo "Finished backup for $vm_str"
    set_status "Finished backup for $vm_str"
    debug_log "--- Finished backup for VM: $vm_str ---"

    # --- Retention cleanup ---
    if [[ "$BACKUPS_TO_KEEP" =~ ^[0-9]+$ ]]; then
        if (( BACKUPS_TO_KEEP == 0 )); then
            debug_log "BACKUPS_TO_KEEP=0, skipping retention for $vm_str"
        else
            mapfile -t backup_sets_arr < <(
                ls -1 "$vm_backup_folder_str" 2>/dev/null \
                | sed -E 's/^([0-9]{8}_[0-9]{6}).*/\1/' \
                | sort -u -r
            )
            total_sets_int=${#backup_sets_arr[@]}
            debug_log "Retention: $vm_str found=$total_sets_int keeping=$BACKUPS_TO_KEEP"

            if (( total_sets_int > BACKUPS_TO_KEEP )); then
                echo "Removing old backups keeping $BACKUPS_TO_KEEP"
                set_status "Removing old backups for $vm_str"
                for (( i=BACKUPS_TO_KEEP; i<total_sets_int; i++ )); do
                    old_ts_str="${backup_sets_arr[$i]}"
                    if is_dry_run; then
                        echo "[DRY-RUN] Would remove files with timestamp $old_ts_str"
                    else
                        debug_log "Removing old backup set: $old_ts_str from $vm_backup_folder_str"
                        rm -f "$vm_backup_folder_str"/"${old_ts_str}"_*
                        debug_log "Removed backup set: $old_ts_str"
                    fi
                done
            else
                echo "No old backups need removed"
                debug_log "No old backups to remove for $vm_str"
            fi
        fi
    else
        echo "WARNING: BACKUPS_TO_KEEP is invalid skipping retention"
        debug_log "WARNING: BACKUPS_TO_KEEP is invalid ($BACKUPS_TO_KEEP)"
    fi

done

debug_log "All VMs processed"
exit 0