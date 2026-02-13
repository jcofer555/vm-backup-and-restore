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
echo "Restore session started - $(date '+%Y-%m-%d %H:%M:%S')"

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

    echo "Duration: $SCRIPT_DURATION_HUMAN"
    echo "Restore session finished - $(date '+%Y-%m-%d %H:%M:%S')"

    timestamp="$(date +"%d-%m-%Y %H:%M")"
    notify_unraid "unRAID VM Restore script" \
    "script finished - Duration: $SCRIPT_DURATION_HUMAN"
}

trap cleanup EXIT SIGTERM SIGINT SIGHUP SIGQUIT

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
source "$CONFIG" || exit 1

notify_unraid() {
    local title="$1"
    local message="$2"

    # Only send if enabled
    if [[ "$ENABLE_NOTIFICATIONS_RESTORE" == "1" ]]; then
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
"script starting"

LOG_DIR="/tmp/vm-backup-and-restore"
ARCHIVE_DIR="$LOG_DIR/restore_logs"

mkdir -p "$ARCHIVE_DIR"

# Rotate logs: keep only the 20 most recent restore_*.txt files
log_files=( "$ARCHIVE_DIR"/restore_*.txt )

if (( ${#log_files[@]} > 20 )); then
    mapfile -t sorted < <(ls -1t "$ARCHIVE_DIR"/restore_*.txt)
    for (( i=20; i<${#sorted[@]}; i++ )); do
        rm -f "${sorted[$i]}"
    done
fi

LOG_FILE="$ARCHIVE_DIR/restore_$(date +%Y%m%d_%H%M%S).txt"

exec > >(tee -a "$LOG_FILE") 2>&1
sleep 5

# ============================================================
# Variables to change
# ============================================================

# VM names
IFS=',' read -r -a vm_names <<< "$VM_NAME_RESTORE"

# Backup base path
backup_path="$RESTORE_LOCATION"

# VM storage location
vm_domains="$RESTORE_DESTINATION"

# Dry run option. Set to true to do a test run
DRY_RUN="$DRY_RUN_RESTORE"

#### DON'T CHANGE ANYTHING BELOW HERE UNLESS YOU KNOW WHAT YOU'RE DOING ####

# ============================================================
# System paths
# ============================================================
xml_base="/etc/libvirt/qemu"
nvram_base="$xml_base/nvram"

mkdir -p "$nvram_base"

# ============================================================
# Log output helpers
# ============================================================
log()  { echo -e "[INFO]  $1"; }
warn() { echo -e "[WARN]  $1"; }
err()  { echo -e "[ERROR] $1"; }

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
        printf '[DRY RUN] %q ' "$@"
        echo
        return
    fi

    # Special case: virsh define is noisy on stdout
    if [[ "$1" == "virsh" && "$2" == "define" ]]; then
        # Suppress stdout, keep stderr
        "$@" >/dev/null
    else
        "$@"
    fi
}

# ============================================================
# Parse RESTORE_VERSIONS into associative array
# Format: dd=20260210-1238,Ubuntu=20260210-1238
# ============================================================
declare -A version_map

IFS=',' read -ra pairs <<< "$RESTORE_VERSIONS"
for p in "${pairs[@]}"; do
    vm_name="${p%%=*}"
    ts="${p#*=}"
    ts="${ts//-/_}"   # Convert 20260210-1238 → 20260210_1238
    version_map["$vm_name"]="$ts"
done

# ============================================================
# Process each VM
# ============================================================
for vm in "${vm_names[@]}"; do
    echo ""
    echo "===================================="
    echo " Restoring VM: $vm"
    echo "===================================="

    backup_dir="$backup_path/$vm"

    # ============================================================
    # Determine version prefix for this VM
    # ============================================================
    version="${version_map[$vm]}"

    if [[ -z "$version" ]]; then
        validation_fail "No restore version specified for VM '$vm'"
        continue
    fi

    prefix="${version}_"

    # ============================================================
    # Versioned file paths
    # ============================================================
    xml_file=$(ls "$backup_dir"/"${prefix}"*.xml 2>/dev/null | head -n1)
    nvram_file=$(ls "$backup_dir"/"${prefix}"*VARS*.fd 2>/dev/null | head -n1)
    disks=( "$backup_dir"/"${prefix}"vdisk*.img )

    # ============================================================
    # Validate backup contents
    # ============================================================
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
    # Shutdown VM cleanly
    # ============================================================
    if virsh list --state-running | grep -q " $vm "; then
        log "Shutting down VM gracefully..."

        run_cmd virsh shutdown "$vm"
        sleep 10

        if virsh list --state-running | grep -q " $vm "; then
            warn "VM still running — forcing stop."
            run_cmd virsh destroy "$vm"
        fi
    else
        log "VM is not running."
    fi

    # ============================================================
    # Restore XML (strip prefix)
    # ============================================================
    dest_xml="$xml_base/$vm.xml"
    log "Restored XML → $dest_xml"

    run_cmd rm -f "$dest_xml"
    run_cmd cp "$xml_file" "$dest_xml"
    run_cmd chmod 644 "$dest_xml"

    # ============================================================
    # Restore NVRAM (strip prefix)
    # ============================================================
    nvram_filename=$(basename "$nvram_file")
    nvram_filename="${nvram_filename#$prefix}"
    dest_nvram="$nvram_base/$nvram_filename"

    log "Restored NVRAM → $dest_nvram"

    run_cmd rm -f "$dest_nvram"
    run_cmd cp "$nvram_file" "$dest_nvram"
    run_cmd chmod 644 "$dest_nvram"

    # ============================================================
    # Restore vdisks (strip prefix)
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

$DRY_RUN && echo "[DRY RUN] No changes were made."
