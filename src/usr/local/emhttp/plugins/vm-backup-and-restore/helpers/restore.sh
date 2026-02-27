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

# --- RESTORE STATUS FILE ADDED ---
RESTORE_STATUS_FILE="/tmp/vm-backup-and-restore/restore_status.txt"
set_restore_status() {
    echo "$1" > "$RESTORE_STATUS_FILE"
}
set_restore_status "Started restore session"
# ---------------------------------

# Logging
LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
mkdir -p "$ROTATE_DIR"

# Rotate last_run.log if >= 10MB
if [[ -f "$LAST_RUN_FILE" ]]; then
    size_bytes=$(stat -c%s "$LAST_RUN_FILE")
    max_bytes=$((10 * 1024 * 1024))  # 10MB

    if (( size_bytes >= max_bytes )); then
        ts="$(date +%Y%m%d_%H%M%S)"
        rotated="$ROTATE_DIR/vm-backup-and-restore_$ts.log"
        mv "$LAST_RUN_FILE" "$rotated"
    fi
fi

# Cleanup: keep only 10 most recent rotated logs
mapfile -t rotated_logs < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null)

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
    LOCK_FILE="/tmp/vm-backup-and-restore/lock.txt"
    rm -f "$LOCK_FILE"

    if [[ -f "$STOP_FLAG" ]]; then
        rm -f "$STOP_FLAG"
        set_restore_status "Restore stopped and cleaned up"
        for f in "${RESTORED_FILES[@]}"; do
            rm -f "$f"
        done
        # Restore prior XML and NVRAM from temp files
        for tmp in "${TEMP_FILES[@]}"; do
            original="${tmp%.pre_restore_tmp}"
            mv "$tmp" "$original"
        done
        # Remove VM folders if empty
        for vm in "${vm_names[@]}"; do
            [[ -z "$vm" ]] && continue
            vm_folder="$vm_domains/$vm"
            if [[ -d "$vm_folder" && -z "$(ls -A "$vm_folder")" ]]; then
                rmdir "$vm_folder"
            fi
        done
        echo "Restore was stopped early. Cleaned up files created this run"
        rm -f "$RESTORE_STATUS_FILE"
        return
    fi

    # Normal completion — remove temp files
    for tmp in "${TEMP_FILES[@]}"; do
        rm -f "$tmp"
    done

    if [[ "$DRY_RUN" != "yes" ]]; then
        if (( ${#STOPPED_VMS[@]} > 0 )); then
            :
            for vm in "${STOPPED_VMS[@]}"; do
                echo "Starting $vm"
                run_cmd virsh start "$vm"
            done
        else
            :
        fi
    else
        echo "Skipping VM restarts because dry run is enabled"
    fi

    SCRIPT_END_EPOCH=$(date +%s)
    SCRIPT_DURATION=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
    SCRIPT_DURATION_HUMAN="$(format_duration "$SCRIPT_DURATION")"

    echo "Restore duration: $SCRIPT_DURATION_HUMAN"
    echo "Restore session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    # --- FINAL STATUS UPDATE ---
    set_restore_status "Restore complete - Duration: $SCRIPT_DURATION_HUMAN"
    # ---------------------------

    if (( error_count > 0 )); then
        notify_restore "warning" "VM Backup & Restore" \
            "Restore finished with errors - Duration: $SCRIPT_DURATION_HUMAN - Check logs for details"
    else
        notify_restore "normal" "VM Backup & Restore" \
            "Restore finished - Duration: $SCRIPT_DURATION_HUMAN"
    fi

    rm -f "$RESTORE_STATUS_FILE"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
source "$CONFIG" || exit 1

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

    [[ "$NOTIFICATIONS_RESTORE" != "yes" ]] && return 0

    if [[ -n "$DISCORD_WEBHOOK_URL_RESTORE" ]]; then
        local color
        case "$level" in
            alert)   color=15158332 ;;
            warning) color=16776960 ;;
            *)       color=3066993  ;;
        esac

        if [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"discord.com/api/webhooks"* ]]; then
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"embeds\":[{\"title\":\"$title\",\"description\":\"$message\",\"color\":$color}]}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"hooks.slack.com"* ]]; then
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"text\":\"*$title*\n$message\"}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"outlook.office.com/webhook"* ]]; then
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"$title\",\"text\":\"$message\"}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"/message"* ]]; then
            # Gotify
            curl -sf -X POST "$DISCORD_WEBHOOK_URL_RESTORE" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"$title\",\"message\":\"$message\",\"priority\":5}" || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"ntfy.sh"* || "$DISCORD_WEBHOOK_URL_RESTORE" == *"/ntfy/"* ]]; then
            curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
                -H "Title: $title" \
                -d "$message" > /dev/null || true

        elif [[ "$DISCORD_WEBHOOK_URL_RESTORE" == *"api.pushover.net"* ]]; then
            local token="${DISCORD_WEBHOOK_URL_RESTORE##*/}"
            curl -sf -X POST "https://api.pushover.net/1/messages.json" \
                -d "token=${token}" \
                -d "user=${PUSHOVER_USER_KEY_RESTORE}" \
                -d "title=${title}" \
                -d "message=${message}" > /dev/null || true
        fi
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
notify_restore "normal" "VM Backup & Restore" "Restore started"

sleep 5

IFS=',' read -r -a vm_names <<< "$VMS_TO_RESTORE"
backup_path="$LOCATION_OF_BACKUPS"
vm_domains="$RESTORE_DESTINATION"
DRY_RUN="$DRY_RUN_RESTORE"

src_class=$(classify_path "$backup_path")
dst_class=$(classify_path "$vm_domains")

if [[ "$src_class" != "$dst_class" && "$src_class" != "EXEMPT" && "$dst_class" != "EXEMPT" ]]; then
    echo "[ERROR] Location of backups is using mount type ($src_class) and restore destination ($dst_class)."
    echo "[ERROR] They must be on the same mount type i.e both fields using user or both user0 or none using either user or user0"
    echo "Restore aborted due to mount type mismatch"
    set_restore_status "Restore aborted – mount-type mismatch"
    notify_restore "alert" "VM Backup & Restore Error" "Restore aborted due to mount type mismatch"
    exit 1
fi

mapfile -t RUNNING_BEFORE < <(virsh list --state-running --name | grep -Fxv "")
STOPPED_VMS=()

xml_base="/etc/libvirt/qemu"
nvram_base="$xml_base/nvram"

mkdir -p "$nvram_base"

log()  { echo -e "$1"; }
warn() { echo -e "$1"; }
err() { echo -e "[ERROR] $1"; }

validation_fail() {
    err "$1"
    warn "Skipping $vm"
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

    rsync "$@" &
    RSYNC_PID=$!
    echo "$RSYNC_PID" > "/tmp/vm-backup-and-restore/restore_rsync.pid"
    wait $RSYNC_PID
    local exit_code=$?
    RSYNC_PID=""
    rm -f "/tmp/vm-backup-and-restore/restore_rsync.pid"
    return $exit_code
}

declare -A version_map

IFS=',' read -ra pairs <<< "$VERSIONS"
for p in "${pairs[@]}"; do
    vm_name="${p%%=*}"
    ts="${p#*=}"
    ts="${ts//-/_}"
    version_map["$vm_name"]="$ts"
done

for vm in "${vm_names[@]}"; do
    :

    set_restore_status "Starting restore for $vm"

    backup_dir="$backup_path/$vm"
    version="${version_map[$vm]}"

    if [[ -z "$version" ]]; then
        validation_fail "No restore version specified for VM $vm"
        continue
    fi

    prefix="${version}_"

    xml_file=$(ls "$backup_dir"/"${prefix}"*.xml 2>/dev/null | head -n1)
    nvram_file=$(ls "$backup_dir"/"${prefix}"*VARS*.fd 2>/dev/null | head -n1)
    disks=( "$backup_dir"/"${prefix}"vdisk*.img "$backup_dir"/"${prefix}"*.qcow2 )

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

    log "Starting restore for $vm"

    # Shutdown
    set_restore_status "Stopping $vm"
    if virsh list --state-running --name | grep -Fxq "$vm"; then
        log "Stopping $vm"

        run_cmd virsh shutdown "$vm"
        sleep 10

        if virsh list --state-running --name | grep -Fxq "$vm"; then
            warn "$vm still running — forcing stop"
            run_cmd virsh destroy "$vm"
        fi

        if [[ "$WAS_RUNNING" == true ]]; then
            STOPPED_VMS+=("$vm")
        fi
    else
        log "$vm is not running"
    fi

    # Restore XML
    set_restore_status "Restoring XML for $vm"
    dest_xml="$xml_base/$vm.xml"

    if [[ -f "$dest_xml" ]]; then
        cp "$dest_xml" "${dest_xml}.pre_restore_tmp"
        TEMP_FILES+=("${dest_xml}.pre_restore_tmp")
    fi
    run_cmd rm -f "$dest_xml"
    run_rsync -a --sparse --no-perms --no-owner --no-group "$xml_file" "$dest_xml"
    RESTORED_FILES+=("$dest_xml")
    run_cmd chmod 644 "$dest_xml"
    log "Restored XML $xml_file → $dest_xml"

    if [[ -f "$STOP_FLAG" ]]; then
        exit 1
    fi

    # Restore NVRAM
    set_restore_status "Restoring NVRAM for $vm"
    nvram_filename=$(basename "$nvram_file")
    nvram_filename="${nvram_filename#$prefix}"
    dest_nvram="$nvram_base/$nvram_filename"

    if [[ -f "$dest_nvram" ]]; then
        cp "$dest_nvram" "${dest_nvram}.pre_restore_tmp"
        TEMP_FILES+=("${dest_nvram}.pre_restore_tmp")
    fi
    run_cmd rm -f "$dest_nvram"
    run_rsync -a --sparse --no-perms --no-owner --no-group "$nvram_file" "$dest_nvram"
    RESTORED_FILES+=("$dest_nvram")
    run_cmd chmod 644 "$dest_nvram"
    log "Restored NVRAM $nvram_file → $dest_nvram"

    if [[ -f "$STOP_FLAG" ]]; then
        exit 1
    fi

    # Restore vdisks
    set_restore_status "Restoring vdisks for $vm"
    dest_domain="$vm_domains/$vm"
    parent_dataset=$(zfs list -H -o name "$(dirname "$dest_domain")" 2>/dev/null)
    if [[ -n "$parent_dataset" ]]; then
        run_cmd zfs create "$parent_dataset/$(basename "$dest_domain")" 2>/dev/null || true
    else
        run_cmd mkdir -p "$dest_domain"
    fi

    for d in "${disks[@]}"; do
        [[ -f "$d" ]] || continue
        file=$(basename "$d")
        file="${file#$prefix}"
        run_rsync -a --sparse --no-perms --no-owner --no-group "$d" "$dest_domain/$file"
        RESTORED_FILES+=("$dest_domain/$file")
        run_cmd chmod 644 "$dest_domain/$file"
        log "Copied VDISK $d → $dest_domain/$file"

        if [[ -f "$STOP_FLAG" ]]; then
            exit 1
        fi
    done

    # Restore any extra files that were backed up alongside vdisks
    set_restore_status "Restoring extra files for $vm"
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
        run_rsync -a --sparse --no-perms --no-owner --no-group "$extra_file" "$dest_domain/$file"
        RESTORED_FILES+=("$dest_domain/$file")
        run_cmd chmod 644 "$dest_domain/$file"
        log "Restored extra file $extra_file → $dest_domain/$file"

        if [[ -f "$STOP_FLAG" ]]; then
            exit 1
        fi
    done

    # Redefine VM
    set_restore_status "Redefining $vm"
    run_cmd virsh define "$dest_xml"
    log "Redefined $vm from $dest_xml"

    log "Finished restore for $vm"
    set_restore_status "Finished restore for $vm"

done