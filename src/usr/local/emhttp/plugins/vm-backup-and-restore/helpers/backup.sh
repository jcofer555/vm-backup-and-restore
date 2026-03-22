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

LOCK_FD=200
exec 200>"$LOCK_FILE"
if ! flock -n $LOCK_FD; then
    echo "Another backup is already running. Exiting." >&2
    exit 1
fi
printf "PID=%s\nMODE=manual\nSTART=%s\n" "$$" "$(date +%s)" > "$LOCK_FILE"

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

# physical_mount_path <path>
# Returns the actual mount point path that owns <path>, resolved past any symlinks
# in the path components themselves (but not through shfs virtual filesystem).
# Uses df to find the real mount point rather than readlink -f which can land
# on /mnt/user even for paths that physically live on /mnt/cache or /mnt/diskN.
physical_mount_path() {
    local path_str="$1"
    local mount_str
    # df --output=target gives the mount point that owns the path.
    # If the path doesn't exist yet (destination not created), walk up until we find a parent that does.
    local check_str="$path_str"
    while [[ -n "$check_str" && "$check_str" != "/" ]]; do
        if [[ -e "$check_str" ]]; then
            mount_str=$(df --output=target "$check_str" 2>/dev/null | tail -n1)
            [[ -n "$mount_str" ]] && { echo "$mount_str"; return; }
        fi
        check_str="$(dirname "$check_str")"
    done
    # Fallback: resolve symlinks in the path prefix only
    echo "$(readlink -f "$path_str" 2>/dev/null || echo "$path_str")"
}

classify_path() {
    local path_str="$1"

    # Check the original path string first.
    # /mnt/user and /mnt/user0 are shfs virtual mounts — any path under them
    # is a user/user0 share path regardless of where shfs physically stores it.
    # Using df on these paths would return the underlying physical mount
    # (/mnt/cache, /mnt/diskN) rather than /mnt/user, causing false mismatches
    # when both src and dst are under /mnt/user but on different physical shares.
    if [[ "$path_str" == /mnt/user  || "$path_str" == /mnt/user/*  ]];    then echo "USER";   return; fi
    if [[ "$path_str" == /mnt/user0 || "$path_str" == /mnt/user0/* ]];    then echo "USER0";  return; fi
    if [[ "$path_str" == /mnt/remotes || "$path_str" == /mnt/remotes/* ]]; then echo "EXEMPT"; return; fi
    if [[ "$path_str" == /mnt/addons  || "$path_str" == /mnt/addons/*  ]]; then echo "EXEMPT"; return; fi

    # For other /mnt/* paths (e.g. /mnt/backup/..., /mnt/cache/..., /mnt/disk1/...)
    # use df to find the real mount point, which correctly classifies symlinks
    # like /mnt/backup -> /mnt/disk1/backup as DISK rather than following the
    # symlink string and misclassifying.
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

    # Resolve both to physical paths for classification only.
    # Original paths are kept for display in error messages.
    local src_resolved_str dst_resolved_str
    src_resolved_str=$(readlink -f "$src_str" 2>/dev/null || echo "$src_str")
    dst_resolved_str=$(readlink -f "$dst_str" 2>/dev/null || echo "$dst_str")

    src_class_str=$(classify_path "$src_resolved_str")
    dst_class_str=$(classify_path "$dst_resolved_str")
    debug_log "validate_mount_compatibility: src=$src_str -> $src_resolved_str ($src_class_str) dst=$dst_str -> $dst_resolved_str ($dst_class_str)"
    local allowed_int=0
    case "$src_class_str" in
        USER)   [[ "$dst_class_str" == "USER"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        USER0)  [[ "$dst_class_str" == "USER0" || "$dst_class_str" == "DISK"  || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        DISK)   [[ "$dst_class_str" == "DISK"  || "$dst_class_str" == "USER0" || "$dst_class_str" == "EXEMPT" ]] && allowed_int=1 ;;
        EXEMPT) allowed_int=1 ;;
    esac
    if [[ "$allowed_int" -eq 0 ]]; then
        echo "[ERROR] Vdisk $src_str ($src_class_str) is incompatible with destination $dst_str ($dst_class_str)"
        echo "[ERROR] USER->USER/EXEMPT  USER0->USER0/DISK/EXEMPT  DISK->DISK/USER0/EXEMPT"
        debug_log "ERROR: mount mismatch src=$src_str ($src_class_str) dst=$dst_str ($dst_class_str)"
        set_status "Mount type mismatch for $src_str"
        return 1
    fi
    return 0
}

cleanup_partial_backup() {
    local folder_str="$1" ts_str="$2"
    [[ ! -d "$folder_str" ]] && return
    shopt -s nullglob
    local run_files_arr=( "$folder_str/${ts_str}_"* )
    shopt -u nullglob
    debug_log "cleanup_partial: folder=$folder_str ts=$ts_str files=${#run_files_arr[@]}"
    for f_str in "${run_files_arr[@]}"; do rm -f "$f_str"; debug_log "Removed: $f_str"; done
    [[ -z "$(ls -A "$folder_str")" ]] && rmdir "$folder_str" && debug_log "Removed empty folder: $folder_str"
}

run_rsync() {
    if is_dry_run; then printf '[DRY-RUN] '; printf '%q ' rsync "$@"; echo; return 0; fi
    debug_log "run_rsync: rsync ${*}"
    rsync "$@" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "$LOG_DIR/rsync.pid"
    wait $RSYNC_PID
    local exit_code_int=$?
    RSYNC_PID=""; rm -f "$LOG_DIR/rsync.pid"
    if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
        debug_log "run_rsync interrupted (exit=$exit_code_int)"; exit 1
    fi
    debug_log "rsync finished exit=$exit_code_int"
    return $exit_code_int
}

# copy_vdisk <src> <dest> [fmt]
# fmt: qcow2 or raw (detected from file if not passed, defaults to qcow2)
#
# Strategy by format and filesystem:
#   qcow2, same-fs  → cp --reflink=auto (instant CoW, no data copied)
#   qcow2, diff-fs  → qemu-img convert  (copies only allocated clusters, skips empty space)
#   raw,   same-fs  → cp --reflink=auto (instant CoW)
#   raw,   diff-fs  → qemu-img convert  (skips unallocated extents) → rsync --sparse fallback
#
# Note: --sparse is intentionally NOT used for raw restores (restore_vdisk in restore.sh)
# because overwriting an existing file with sparse data leaves stale non-zero bytes.
# Here we write to a fresh destination so --sparse is safe.
copy_vdisk() {
    local src_str="$1"
    local dest_str="$2"
    local fmt_str="${3:-}"

    if is_dry_run; then
        printf '[DRY-RUN] copy_vdisk %q -> %q\n' "$src_str" "$dest_str"
        return 0
    fi

    debug_log "copy_vdisk: $src_str -> $dest_str (fmt=${fmt_str:-auto})"

    # Detect format from file header if not provided
    if [[ -z "$fmt_str" ]]; then
        if command -v qemu-img >/dev/null 2>&1; then
            fmt_str=$(qemu-img info --output=json "$src_str" 2>/dev/null \
                      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null)
        fi
        [[ -z "$fmt_str" ]] && fmt_str="raw"
    fi

    # Try CoW reflink first — instant on same-filesystem Btrfs/XFS regardless of format
    if cp --reflink=always "$src_str" "$dest_str" 2>/dev/null; then
        debug_log "copy_vdisk: reflink OK (instant CoW)"
        return 0
    fi

    # Reflink not supported — use format-aware copy
    if [[ "$fmt_str" == "qcow2" ]]; then
        # qemu-img convert: reads only allocated clusters, writes a clean qcow2.
        # Much faster than full copy for sparsely-used disks.
        # -p: progress to stderr, -W: skip zero clusters, -c: compress (optional but slower)
        debug_log "copy_vdisk: qemu-img convert (qcow2, allocated clusters only)"
        qemu-img convert -f qcow2 -O qcow2 -W -p "$src_str" "$dest_str" 2>/dev/null &
        local qimg_pid_int=$!
        wait $qimg_pid_int
        local exit_code_int=$?
        if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
            debug_log "copy_vdisk: qemu-img interrupted (exit=$exit_code_int)"; exit 1
        fi
        if [[ $exit_code_int -eq 0 ]]; then
            debug_log "copy_vdisk: qemu-img convert OK"
            return 0
        fi
        # qemu-img failed — fall through to rsync
        debug_log "copy_vdisk: qemu-img convert failed (exit=$exit_code_int), falling back to rsync"
        rm -f "$dest_str"
    fi

    # raw disk (or qemu-img qcow2 fallback):
    # Try qemu-img convert -f raw -O raw first — uses QEMU's block layer to skip
    # unallocated extents, which rsync --sparse cannot detect (it only skips file-level
    # zero runs, not block-layer unallocated regions).
    if command -v qemu-img >/dev/null 2>&1 && [[ "$fmt_str" == "raw" ]]; then
        debug_log "copy_vdisk: qemu-img convert (raw, unallocated extents skipped)"
        qemu-img convert -f raw -O raw -W -p "$src_str" "$dest_str" 2>/dev/null &
        local qimg_pid_int=$!
        wait $qimg_pid_int
        local exit_code_int=$?
        if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
            debug_log "copy_vdisk: qemu-img interrupted (exit=$exit_code_int)"; exit 1
        fi
        if [[ $exit_code_int -eq 0 ]]; then
            debug_log "copy_vdisk: qemu-img convert raw OK"
            return 0
        fi
        debug_log "copy_vdisk: qemu-img raw failed (exit=$exit_code_int), falling back to rsync"
        rm -f "$dest_str"
    fi

    # Final fallback: rsync --sparse skips zero byte runs.
    # Safe because dest is always a fresh file here.
    debug_log "copy_vdisk: rsync --sparse (fallback)"
    rsync -aHAX --sparse "$src_str" "$dest_str" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "$LOG_DIR/rsync.pid"
    wait $RSYNC_PID
    local exit_code_int=$?
    RSYNC_PID=""; rm -f "$LOG_DIR/rsync.pid"
    if [[ -f "$STOP_FLAG" ]] || (( exit_code_int > 128 )); then
        debug_log "copy_vdisk: rsync interrupted (exit=$exit_code_int)"; exit 1
    fi
    debug_log "copy_vdisk: rsync finished exit=$exit_code_int"
    return $exit_code_int
}

set_status() { echo "$1" > "$STATUS_FILE"; }
debug_log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup debug - $*" >> "$DEBUG_LOG"; }

log_path_resolution() {
    local label_str="$1" raw_str="$2" resolved_str="$3"
    if [[ -n "$raw_str" && "$raw_str" != "$resolved_str" ]]; then
        echo "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str (symlink followed)"
        debug_log "[PATH RESOLVED] $label_str: $raw_str -> $resolved_str"
    else
        debug_log "$label_str: $resolved_str (no resolution needed)"
    fi
}

is_dry_run()  { [[ "$DRY_RUN"     == "yes" ]]; }
run_cmd() {
    if is_dry_run; then printf '[DRY-RUN] '; printf '%q ' "$@"; echo; else "$@"; fi
}

# Shared retention logic
_do_retention() {
    local vm_str="$1" folder_str="$2" keep_int="$3"
    if ! [[ "$keep_int" =~ ^[0-9]+$ ]]; then
        echo "WARNING: retention count is invalid, skipping"; return
    fi
    (( keep_int == 0 )) && { debug_log "retention=0 (unlimited) for $vm_str"; return; }
    mapfile -t sets_arr < <(
        ls -1 "$folder_str" 2>/dev/null \
        | sed -E 's/^([0-9]{8}_[0-9]{6}).*/\1/' | sort -u -r
    )
    local total_int=${#sets_arr[@]}
    debug_log "retention: $vm_str found=$total_int keep=$keep_int folder=$folder_str"
    if (( total_int > keep_int )); then
        echo "Removing old backups, keeping $keep_int"
        set_status "Removing old backups for $vm_str"
        for (( i=keep_int; i<total_int; i++ )); do
            local old_ts_str="${sets_arr[$i]}"
            if is_dry_run; then
                echo "[DRY-RUN] Would remove files with timestamp $old_ts_str"
            else
                rm -f "$folder_str"/"${old_ts_str}"_*
                debug_log "Removed set: $old_ts_str from $folder_str"
            fi
        done
    else
        echo "No old backups need removed"
        debug_log "No old sets to remove for $vm_str"
    fi
}

set_status "Started backup session"

# Log rotation
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes_int=$(stat -c%s "$LAST_RUN_FILE")
    if (( size_bytes_int >= 10 * 1024 * 1024 )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        mv "$LAST_RUN_FILE" "$ROTATE_DIR/vm-backup-and-restore_${rotate_ts_str}.log"
        debug_log "Rotated main log"
    fi
fi
mapfile -t rl_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null | sort)
(( ${#rl_arr[@]} > 10 )) && for (( i=10; i<${#rl_arr[@]}; i++ )); do rm -f "${rl_arr[$i]}"; done

if [[ -f "$DEBUG_LOG" ]]; then
    size_bytes_int=$(stat -c%s "$DEBUG_LOG")
    if (( size_bytes_int >= 10 * 1024 * 1024 )); then
        rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
        mv "$DEBUG_LOG" "$ROTATE_DIR/vm-backup-and-restore-debug_${rotate_ts_str}.log"
    fi
fi
mapfile -t rdl_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore-debug_*.log 2>/dev/null | sort)
(( ${#rdl_arr[@]} > 10 )) && for (( i=10; i<${#rdl_arr[@]}; i++ )); do rm -f "${rdl_arr[$i]}"; done

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

PLG_FILE="/boot/config/plugins/vm-backup-and-restore.plg"
[[ -f "$PLG_FILE" ]] && version_str=$(grep -oP 'version="\K[^"]+' "$PLG_FILE" | head -n1) || version_str="unknown"
echo "--------------------------------------------------------------------------------------------------"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session started - Plugin version: $version_str"

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
debug_log "Loading config: $CONFIG"
source "$CONFIG" || { debug_log "ERROR: Failed to source config"; exit 1; }

DRY_RUN="${DRY_RUN:-no}"

# Webhook cleanup
WEBHOOK_DISCORD="${WEBHOOK_DISCORD//\"/}"
WEBHOOK_GOTIFY="${WEBHOOK_GOTIFY//\"/}"
WEBHOOK_NTFY="${WEBHOOK_NTFY//\"/}"
WEBHOOK_PUSHOVER="${WEBHOOK_PUSHOVER//\"/}"
WEBHOOK_SLACK="${WEBHOOK_SLACK//\"/}"
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY//\"/}"

notify_vm() {
    local level_str="$1" title_str="$2" message_str="$3"
    debug_log "notify_vm: level=$level_str title=$title_str"
    [[ "${NOTIFICATIONS:-no}" != "yes" ]] && return 0
    local color_int
    case "$level_str" in alert) color_int=15158332;; warning) color_int=16776960;; *) color_int=3066993;; esac
    IFS=',' read -ra services_arr <<< "$NOTIFICATION_SERVICE"
    for service_str in "${services_arr[@]}"; do
        service_str="${service_str// /}"
        case "$service_str" in
            Discord)  [[ -n "$WEBHOOK_DISCORD" ]]  && curl -sf -X POST "$WEBHOOK_DISCORD"  -H "Content-Type: application/json" -d "{\"embeds\":[{\"title\":\"$title_str\",\"description\":\"$message_str\",\"color\":$color_int}]}" || true ;;
            Gotify)   [[ -n "$WEBHOOK_GOTIFY" ]]   && curl -sf -X POST "$WEBHOOK_GOTIFY"   -H "Content-Type: application/json" -d "{\"title\":\"$title_str\",\"message\":\"$message_str\",\"priority\":5}" || true ;;
            Ntfy)     [[ -n "$WEBHOOK_NTFY" ]]     && curl -sf -X POST "$WEBHOOK_NTFY"     -H "Title: $title_str" -d "$message_str" > /dev/null || true ;;
            Pushover) [[ -n "$WEBHOOK_PUSHOVER" && -n "$PUSHOVER_USER_KEY" ]] && curl -sf -X POST "https://api.pushover.net/1/messages.json" -d "token=${WEBHOOK_PUSHOVER##*/}" -d "user=${PUSHOVER_USER_KEY}" -d "title=${title_str}" -d "message=${message_str}" > /dev/null || true ;;
            Slack)    [[ -n "$WEBHOOK_SLACK" ]]    && curl -sf -X POST "$WEBHOOK_SLACK"    -H "Content-Type: application/json" -d "{\"text\":\"*$title_str*\n$message_str\"}" || true ;;
            Unraid)   [[ -x /usr/local/emhttp/webGui/scripts/notify ]] && /usr/local/emhttp/webGui/scripts/notify -e "VM Backup & Restore" -s "$title_str" -d "$message_str" -i "$level_str" ;;
            *) debug_log "Unknown notification service: $service_str" ;;
        esac
    done
}

error_count_int=0
notify_vm "normal" "VM Backup & Restore" "Backup started"
sleep 5

BACKUPS_TO_KEEP="${BACKUPS_TO_KEEP:-0}"
backup_owner_str="${BACKUP_OWNER:-nobody}"

# Destination paths are kept exactly as entered — do not resolve symlinks.
# readlink -f on /mnt/backup/... can return /mnt/user/... which breaks mount
# classification. The copy tools (cp, rsync, qemu-img) handle VFS paths fine.
backup_location_str="${BACKUP_DESTINATION:-}"
export backup_location_str
# Resolve and log if the destination path is a symlink to a different physical path.
# The original path is kept for all operations — this is informational only.
if [[ -n "$backup_location_str" ]]; then
    _resolved_backup_str=$(readlink -f "$backup_location_str" 2>/dev/null || echo "$backup_location_str")
    log_path_resolution "Backup Destination" "$backup_location_str" "$_resolved_backup_str"
    unset _resolved_backup_str
fi
debug_log "BACKUP_DESTINATION=$backup_location_str"


debug_log "===== Session started ====="
debug_log "DRY_RUN=$DRY_RUN"
debug_log "BACKUPS_TO_KEEP=$BACKUPS_TO_KEEP backup_location=$backup_location_str"


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

cleanup() {
    kill "$WATCHER_PID" 2>/dev/null
    flock -u $LOCK_FD 2>/dev/null
    rm -f "$LOCK_FILE"
    debug_log "Lock file removed"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        local end_epoch_int duration_int
        end_epoch_int=$(date +%s)
        duration_int=$(( end_epoch_int - SCRIPT_START_EPOCH ))
        SCRIPT_DURATION_HUMAN="$(format_duration "$duration_int")"
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "Backup was stopped early"
        else
            for vm_str in "${CLEAN_VMS_arr[@]}"; do
                [[ -z "$vm_str" ]] && continue
                # Clean up both standard and live partial files
                cleanup_partial_backup "$backup_location_str/$vm_str" "$RUN_TS"
            done
            echo "Backup was stopped early. Cleaned up files created this run"
        fi
        if [[ "$DRY_RUN" != "yes" ]]; then
            for vm_str in "${vms_stopped_by_script_arr[@]}"; do
                [[ -z "$vm_str" ]] && continue
                echo "Starting VM $vm_str"
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
        rm -f "$STATUS_FILE"; debug_log "===== Session ended (dry run) ====="; return
    fi

    for vm_str in "${vms_stopped_by_script_arr[@]}"; do
        [[ -z "$vm_str" ]] && continue
        virsh start "$vm_str" >/dev/null 2>&1 || echo "WARNING: Failed to start VM $vm_str"
    done
    ((${#vms_all_stopped_arr[@]} == 0)) && echo "No VMs were stopped this session"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
    debug_log "Session finished duration=$SCRIPT_DURATION_HUMAN errors=$error_count_int"
    if (( error_count_int > 0 )); then
        notify_vm "warning" "VM Backup & Restore" "Backup finished with errors - Duration: $SCRIPT_DURATION_HUMAN"
    else
        notify_vm "normal" "VM Backup & Restore" "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi
    rm -f "$STATUS_FILE"
    debug_log "===== Session ended ====="
}

_STOPPING_int=0
handle_signal() { [[ "$_STOPPING_int" == "0" ]] && { _STOPPING_int=1; exit 1; }; }
trap cleanup EXIT
trap handle_signal SIGTERM SIGINT SIGHUP SIGQUIT

( trap '' SIGTERM; while true; do
    sleep 1
    [[ -f "$STOP_FLAG" ]] && { kill -TERM $$ 2>/dev/null; break; }
done ) &>/dev/null &
WATCHER_PID=$!

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
    if [[ ! -f "$vm_xml_path_str" ]]; then
        echo "ERROR: XML not located for $vm_str"
        debug_log "ERROR: XML not found: $vm_xml_path_str"
        (( error_count_int++ )); continue
    fi

    vm_state_before_str="$(virsh domstate "$vm_str" 2>/dev/null || echo "unknown")"
    debug_log "VM state: $vm_state_before_str"

    mapfile -t vdisks_arr < <(
        xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path_str" 2>/dev/null \
        | sed -E 's/ file=\"/\n/g' | sed -E 's/\"//g' | sed '/^$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )
    debug_log "vdisks for $vm_str: ${vdisks_arr[*]:-none}"

    # ══════════════════════════════════════════════════════════════════════
    # BACKUP
    # ══════════════════════════════════════════════════════════════════════
    vm_backup_folder_str="$backup_location_str/$vm_str"
    run_cmd mkdir -p "$vm_backup_folder_str"

    # Mount compat check
    for vdisk_str in "${vdisks_arr[@]}"; do
        if ! validate_mount_compatibility "$vdisk_str" "$backup_location_str"; then
            echo "[ERROR] Skipping $vm_str due to incompatible mount types"
            (( error_count_int++ ))
            shopt -s nullglob
            run_files_arr=( "$vm_backup_folder_str/${RUN_TS}_"* )
            shopt -u nullglob
            for f_str in "${run_files_arr[@]}"; do rm -f "$f_str"; done
            [[ -z "$(ls -A "$vm_backup_folder_str")" ]] && rmdir "$vm_backup_folder_str"
            continue 2
        fi
    done

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
                sleep 2; (( timeout_int -= 2 ))
            done
            if [[ $timeout_int -le 0 ]]; then
                if virsh destroy "$vm_str" >/dev/null 2>&1; then
                    echo "Force stopped $vm_str"; vm_stop_method_arr[$vm_str]="forced"
                else
                    echo "ERROR: Unable to stop $vm_str - skipping backup"
                    (( error_count_int++ ))
                    new_arr=()
                    for item_str in "${vms_stopped_by_script_arr[@]}"; do [[ "$item_str" != "$vm_str" ]] && new_arr+=("$item_str"); done
                    vms_stopped_by_script_arr=("${new_arr[@]}")
                    new_arr=()
                    for item_str in "${vms_all_stopped_arr[@]}"; do [[ "$item_str" != "$vm_str" ]] && new_arr+=("$item_str"); done
                    vms_all_stopped_arr=("${new_arr[@]}")
                    unset new_arr; continue
                fi
            else
                echo "Stopped $vm_str"; vm_stop_method_arr[$vm_str]="normal"
            fi
        fi
    else
        debug_log "VM $vm_str not running (state=$vm_state_before_str)"
    fi

    [[ -f "$STOP_FLAG" ]] && exit 1

    if ((${#vdisks_arr[@]} == 0)); then
        echo "No vdisk entries located in XML for $vm_str"
    else
        echo "Backing up vdisks"
        set_status "Backing up vdisks for $vm_str"
        for vdisk_str in "${vdisks_arr[@]}"; do
            if [[ ! -f "$vdisk_str" ]]; then
                echo "[ERROR] $vm_str vdisk $vdisk_str not found — skipping $vm_str"
                (( error_count_int++ ))
                cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
                continue 2
            fi
            base_str="$(basename "$vdisk_str")"
            resolved_vdisk_str="$(readlink -f "$vdisk_str" 2>/dev/null || echo "$vdisk_str")"
            log_path_resolution "Vdisk" "$vdisk_str" "$resolved_vdisk_str"
            dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
            is_dry_run || echo "$vdisk_str -> $dest_str"
            copy_vdisk "$resolved_vdisk_str" "$dest_str"
            [[ -f "$STOP_FLAG" ]] && { cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"; exit 1; }
        done

        declare -A vdisk_dirs_arr
        for vdisk_str in "${vdisks_arr[@]}"; do
            resolved_vdisk_str="$(readlink -f "$vdisk_str" 2>/dev/null || echo "$vdisk_str")"
            vdisk_dirs_arr["$(dirname "$resolved_vdisk_str")"]=1
        done
        for dir_str in "${!vdisk_dirs_arr[@]}"; do
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
                copy_vdisk "$extra_file_str" "$dest_str"
                [[ -f "$STOP_FLAG" ]] && { cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"; exit 1; }
            done
        done
        unset vdisk_dirs_arr
    fi

    xml_dest_str="$vm_backup_folder_str/${RUN_TS}_${vm_str}.xml"
    set_status "Backing up XML for $vm_str"
    run_rsync -a "$vm_xml_path_str" "$xml_dest_str"
    echo "Backed up XML $vm_xml_path_str -> $xml_dest_str"

    nvram_path_str="$(xmllint --xpath 'string(/domain/os/nvram)' "$vm_xml_path_str" 2>/dev/null || echo "")"
    if [[ -n "$nvram_path_str" && -f "$nvram_path_str" ]]; then
        nvram_base_str="$(basename "$nvram_path_str")"
        nvram_dest_str="$vm_backup_folder_str/${RUN_TS}_$nvram_base_str"
        set_status "Backing up NVRAM for $vm_str"
        run_rsync -a "$nvram_path_str" "$nvram_dest_str"
        echo "Backed up NVRAM $nvram_path_str -> $nvram_dest_str"
    else
        echo "No valid NVRAM located for $vm_str"
    fi

    run_cmd chown -R "$backup_owner_str:users" "$vm_backup_folder_str" || \
        echo "WARNING: chown failed for $vm_backup_folder_str"
    echo "Changed owner of $vm_backup_folder_str to $backup_owner_str:users"

    if [[ "$vm_state_before_str" == "running" ]]; then
        set_status "Starting $vm_str"
        if run_cmd virsh start "$vm_str" >/dev/null 2>&1; then
            echo "Started $vm_str"
        else
            echo "WARNING: Failed to start $vm_str"
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
    debug_log "--- Finished standard backup for VM: $vm_str ---"
    _do_retention "$vm_str" "$vm_backup_folder_str" "$BACKUPS_TO_KEEP"
done

debug_log "All VMs processed"
exit 0