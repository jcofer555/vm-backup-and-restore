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

# --- RESTORE STATUS FILE ADDED ---
RESTORE_STATUS_FILE="/tmp/vm-backup-and-restore/restore_status.txt"
set_restore_status() {
    echo "$1" > "$RESTORE_STATUS_FILE"
}
set_restore_status "Started restore session"
# ---------------------------------

# Prevent double-run
if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

touch "$LOCK_FILE"

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
    rm -f "$LOCK_FILE"

    if [[ "$DRY_RUN" != "true" ]]; then
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
    set_restore_status "Restore complete – Duration: $SCRIPT_DURATION_HUMAN"
    # ---------------------------

    timestamp="$(date +"%d-%m-%Y %H:%M")"
    notify_unraid "unRAID VM Restore script" \
    "Restore finished - Duration: $SCRIPT_DURATION_HUMAN"

    set_restore_status "Not Running"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
source "$CONFIG" || exit 1

notify_unraid() {
    local title="$1"
    local message="$2"

    if [[ "$NOTIFICATIONS_RESTORE" == "1" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -e "unRAID Status" \
            -s "$title" \
            -d "$message" \
            -i "normal"
    fi
}

timestamp="$(date +"%d-%m-%Y %H:%M")"
notify_unraid "unRAID VM Restore script" \
"Restore started"

sleep 5

IFS=',' read -r -a vm_names <<< "$VMS_TO_RESTORE"
backup_path="$LOCATION_OF_BACKUPS"
vm_domains="$RESTORE_DESTINATION"
DRY_RUN="$DRY_RUN_RESTORE"

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
}

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
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

    run_cmd rm -f "$dest_xml"
    run_cmd rsync -a --sparse --no-perms --no-owner --no-group "$xml_file" "$dest_xml"
    run_cmd chmod 644 "$dest_xml"
    log "Restored XML $xml_file → $dest_xml"

    # Restore NVRAM
    set_restore_status "Restoring NVRAM for $vm"
    nvram_filename=$(basename "$nvram_file")
    nvram_filename="${nvram_filename#$prefix}"
    dest_nvram="$nvram_base/$nvram_filename"

    run_cmd rm -f "$dest_nvram"
    run_cmd rsync -a --sparse --no-perms --no-owner --no-group "$nvram_file" "$dest_nvram"
    run_cmd chmod 644 "$dest_nvram"
    log "Restored NVRAM $nvram_file → $dest_nvram"

    # Restore vdisks
    set_restore_status "Restoring vdisks for $vm"
    dest_domain="$vm_domains/$vm"
    run_cmd mkdir -p "$dest_domain"

    for d in "${disks[@]}"; do
        file=$(basename "$d")
        file="${file#$prefix}"
        run_cmd rsync -a --sparse --no-perms --no-owner --no-group "$d" "$dest_domain/$file"
        run_cmd chmod 644 "$dest_domain/$file"
        log "Copied VDISK $d → $dest_domain/$file"
    done

    # Redefine VM
    set_restore_status "Redefining $vm"
    run_cmd virsh define "$dest_xml"
    log "Redefined $vm from $dest_xml"

    log "Finished restore for $vm"
    set_restore_status "Finished restore for $vm"

done
