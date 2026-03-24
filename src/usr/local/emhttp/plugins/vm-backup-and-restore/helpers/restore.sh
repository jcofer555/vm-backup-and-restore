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
	local h_int=$((total_int / 3600))
	local m_int=$(((total_int % 3600) / 60))
	local s_int=$((total_int % 60))
	local out_str=""
	((h_int > 0)) && out_str+="${h_int}h "
	((m_int > 0)) && out_str+="${m_int}m "
	out_str+="${s_int}s"
	echo "$out_str"
}

RESTORE_STATUS_FILE="/tmp/vm-backup-and-restore/restore_status.txt"
set_restore_status() { echo "$1" >"$RESTORE_STATUS_FILE"; }
set_restore_status "Started restore session"

LOG_DIR="/tmp/vm-backup-and-restore"
LAST_RUN_FILE="$LOG_DIR/vm-backup-and-restore.log"
ROTATE_DIR="$LOG_DIR/archived_logs"
DEBUG_LOG="$LOG_DIR/vm-backup-and-restore-debug.log"
mkdir -p "$ROTATE_DIR"

debug_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore session started debug - $*" >>"$DEBUG_LOG"
}

# Log rotation: main log
if [[ -f "$LAST_RUN_FILE" ]]; then
	size_bytes_int=$(stat -c%s "$LAST_RUN_FILE")
	if ((size_bytes_int >= 10 * 1024 * 1024)); then
		rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
		mv "$LAST_RUN_FILE" "$ROTATE_DIR/vm-backup-and-restore_${rotate_ts_str}.log"
		debug_log "Rotated main log"
	fi
fi
mapfile -t rotated_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null | sort)
if ((${#rotated_logs_arr[@]} > 10)); then
	for ((i = 10; i < ${#rotated_logs_arr[@]}; i++)); do rm -f "${rotated_logs_arr[$i]}"; done
fi

# Log rotation: debug log
if [[ -f "$DEBUG_LOG" ]]; then
	size_bytes_int=$(stat -c%s "$DEBUG_LOG")
	if ((size_bytes_int >= 10 * 1024 * 1024)); then
		rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
		mv "$DEBUG_LOG" "$ROTATE_DIR/vm-restore-debug_${rotate_ts_str}.log"
	fi
fi
mapfile -t rotated_debug_logs_arr < <(ls -1t "$ROTATE_DIR"/vm-restore-debug_*.log 2>/dev/null | sort)
if ((${#rotated_debug_logs_arr[@]} > 10)); then
	for ((i = 10; i < ${#rotated_debug_logs_arr[@]}; i++)); do rm -f "${rotated_debug_logs_arr[$i]}"; done
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
	duration_int=$((end_epoch_int - SCRIPT_START_EPOCH))
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

	if ((error_count_int > 0)); then
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
source "$CONFIG" || {
	debug_log "ERROR: Failed to source config: $CONFIG"
	exit 1
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
	case "$level_str" in alert) color_int=15158332 ;; warning) color_int=16776960 ;; *) color_int=3066993 ;; esac
	IFS=',' read -ra services_arr <<<"$NOTIFICATION_SERVICE_RESTORE"
	for service_str in "${services_arr[@]}"; do
		service_str="${service_str// /}"
		case "$service_str" in
		Discord) [[ -n "$WEBHOOK_DISCORD_RESTORE" ]] && curl -sf -X POST "$WEBHOOK_DISCORD_RESTORE" -H "Content-Type: application/json" -d "{\"embeds\":[{\"title\":\"$title_str\",\"description\":\"$message_str\",\"color\":$color_int}]}" || true ;;
		Gotify) [[ -n "$WEBHOOK_GOTIFY_RESTORE" ]] && curl -sf -X POST "$WEBHOOK_GOTIFY_RESTORE" -H "Content-Type: application/json" -d "{\"title\":\"$title_str\",\"message\":\"$message_str\",\"priority\":5}" || true ;;
		Ntfy) [[ -n "$WEBHOOK_NTFY_RESTORE" ]] && curl -sf -X POST "$WEBHOOK_NTFY_RESTORE" -H "Title: $title_str" -d "$message_str" >/dev/null || true ;;
		Pushover) [[ -n "$WEBHOOK_PUSHOVER_RESTORE" && -n "$PUSHOVER_USER_KEY_RESTORE" ]] && curl -sf -X POST "https://api.pushover.net/1/messages.json" -d "token=${WEBHOOK_PUSHOVER_RESTORE##*/}" -d "user=${PUSHOVER_USER_KEY_RESTORE}" -d "title=${title_str}" -d "message=${message_str}" >/dev/null || true ;;
		Slack) [[ -n "$WEBHOOK_SLACK_RESTORE" ]] && curl -sf -X POST "$WEBHOOK_SLACK_RESTORE" -H "Content-Type: application/json" -d "{\"text\":\"*$title_str*\n$message_str\"}" || true ;;
		Unraid) [[ -x /usr/local/emhttp/webGui/scripts/notify ]] && /usr/local/emhttp/webGui/scripts/notify -e "VM Backup & Restore" -s "$title_str" -d "$message_str" -i "$level_str" ;;
		*) debug_log "Unknown notification service: $service_str" ;;
		esac
	done
}

error_count_int=0
notify_restore "normal" "VM Backup & Restore" "Restore started"
sleep 5

IFS=',' read -r -a vm_names_arr <<<"$VMS_TO_RESTORE"
DRY_RUN="$DRY_RUN_RESTORE"

# Keep paths exactly as entered — do not resolve symlinks at startup.
backup_path_str="${LOCATION_OF_BACKUPS:-}"
vm_domains_str="${RESTORE_DESTINATION:-}"

debug_log "LOCATION_OF_BACKUPS=$backup_path_str"
debug_log "RESTORE_DESTINATION=$vm_domains_str"

debug_log "===== Session started ====="
debug_log "VMS_TO_RESTORE=$VMS_TO_RESTORE DRY_RUN=$DRY_RUN"
debug_log "backup_path=$backup_path_str vm_domains=$vm_domains_str"

mapfile -t RUNNING_BEFORE_arr < <(virsh list --state-running --name | grep -Fxv "")
debug_log "VMs running before restore: ${RUNNING_BEFORE_arr[*]:-none}"
STOPPED_VMS_arr=()

xml_base_str="/etc/libvirt/qemu"
nvram_base_dir_str="$xml_base_str/nvram"
mkdir -p "$nvram_base_dir_str"

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
	if [[ "$1" == "virsh" && ("$2" == "shutdown" || "$2" == "destroy" || "$2" == "start") ]]; then
		shift
		virsh --quiet "$@" >/dev/null
		return
	fi
	"$@"
}

# run_rsync_meta: for small metadata files (XML, NVRAM) — --sparse is safe
run_rsync_meta() {
	if [[ "$DRY_RUN" == "yes" ]]; then
		printf '[DRY RUN] '
		printf '%q ' rsync "$@"
		echo
		return 0
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
#
# Strategy mirrors copy_vdisk:
#   same-fs  → cp --reflink=always (instant CoW)
#   diff-fs  → cp --sparse=always
#   fallback → rsync --sparse
#
# Caller always rm -f the dest before calling so delta sync is not used here —
# restore always writes a clean copy.
restore_vdisk() {
	local src_str="$1"
	local dest_str="$2"

	if [[ "$DRY_RUN" == "yes" ]]; then
		printf '[DRY RUN] restore_vdisk %q -> %q\n' "$src_str" "$dest_str"
		return 0
	fi

	debug_log "restore_vdisk: $src_str -> $dest_str"

	# Try reflink first — instant on same-filesystem Btrfs/XFS
	if cp --reflink=always "$src_str" "$dest_str" 2>/dev/null; then
		debug_log "restore_vdisk: reflink OK (instant CoW)"
		return 0
	fi

	# Cross-filesystem or no reflink support — cp --sparse=always
	debug_log "restore_vdisk: cp --sparse=always"
	cp --sparse=always "$src_str" "$dest_str" &
	local cp_pid_int=$!
	wait $cp_pid_int
	local exit_code_int=$?
	if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
		debug_log "restore_vdisk: cp interrupted (exit=$exit_code_int)"
		exit 1
	fi
	if [[ $exit_code_int -eq 0 ]]; then
		debug_log "restore_vdisk: cp --sparse=always OK"
		return 0
	fi

	# Fallback: rsync --sparse. Dest is always rm'd before this call so safe.
	debug_log "restore_vdisk: cp failed (exit=$exit_code_int), falling back to rsync --sparse"
	rm -f "$dest_str"
	rsync -aHAX --sparse --no-perms --no-owner --no-group "$src_str" "$dest_str" &
	RSYNC_PID=$!
	wait $RSYNC_PID
	local exit_code_int=$?
	RSYNC_PID=""
	if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
		debug_log "restore_vdisk: rsync interrupted (exit=$exit_code_int)"
		exit 1
	fi
	debug_log "restore_vdisk: rsync finished exit=$exit_code_int"
	return $exit_code_int
}

declare -A version_map_arr
IFS=',' read -ra pairs_arr <<<"$VERSIONS"
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
	version_str="${version_map_arr[$vm_str]}"
	debug_log "backup_dir=$backup_dir_str version=$version_str"

	if [[ -z "$version_str" ]]; then
		echo "[ERROR] No restore version specified for VM $vm_str — skipping"
		debug_log "Validation failed: no version for $vm_str"
		((error_count_int++))
		continue
	fi

	prefix_str="${version_str}_"
	debug_log "prefix=$prefix_str"

	xml_file_str=$(ls "$backup_dir_str"/"${prefix_str}"*.xml 2>/dev/null | head -n1)
	nvram_file_str=$(ls "$backup_dir_str"/"${prefix_str}"*VARS*.fd 2>/dev/null | head -n1)

	# Collect all vdisk files for this version.
	# Snapshot backups produce a full base disk copy (same filename as the
	# original vdisk) — restore is a straight file copy just like a full backup.
	disks_arr=()
	for f_str in "$backup_dir_str"/"${prefix_str}"*; do
		[[ -f "$f_str" ]] || continue
		case "$f_str" in
		*.xml | *VARS*.fd) continue ;;
		*) disks_arr+=("$f_str") ;;
		esac
	done

	debug_log "xml=${xml_file_str:-not found} nvram=${nvram_file_str:-not found}"
	debug_log "disks: ${disks_arr[*]:-none}"

	# ── Pre-flight validation ──────────────────────────────────────────────
	missing_files_arr=()
	if [[ ! -d "$backup_dir_str" ]]; then
		echo "[ERROR] Backup folder missing: $backup_dir_str — skipping $vm_str"
		((error_count_int++))
		continue
	fi
	[[ ! -f "$xml_file_str" ]] && missing_files_arr+=("XML (.xml)")
	[[ ! -f "$nvram_file_str" ]] && missing_files_arr+=("NVRAM (*VARS*.fd)")
	((${#disks_arr[@]} == 0)) && missing_files_arr+=("vdisk (.img or .qcow2)")

	if ((${#missing_files_arr[@]} > 0)); then
		echo "[ERROR] Backup for $vm_str (version: $version_str) is incomplete — missing:"
		for mf_str in "${missing_files_arr[@]}"; do echo "[ERROR]   - $mf_str"; done
		echo "[ERROR] Skipping $vm_str — no files modified"
		debug_log "Validation failed for $vm_str: missing ${missing_files_arr[*]}"
		((error_count_int++))
		continue
	fi

	WAS_RUNNING_bool=false
	printf '%s\n' "${RUNNING_BEFORE_arr[@]}" | grep -Fxq "$vm_str" && WAS_RUNNING_bool=true
	debug_log "WAS_RUNNING=$WAS_RUNNING_bool"

	echo "Starting restore for $vm_str"

	# ── Shutdown ───────────────────────────────────────────────────────────
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

	# ── Restore XML ────────────────────────────────────────────────────────
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

	# ── Restore NVRAM ──────────────────────────────────────────────────────
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

	# ── Restore vdisks ────────────────────────────────────────────────────
	# Both Full and Snapshot backups store a complete point-in-time copy of
	# each base disk — restore is a straight file copy in both cases.
	dest_domain_str="$vm_domains_str/$vm_str"
	debug_log "dest_domain=$dest_domain_str"

	set_restore_status "Restoring vdisks for $vm_str"

	parent_dataset_str=$(zfs list -H -o name "$(dirname "$dest_domain_str")" 2>/dev/null)
	if [[ -n "$parent_dataset_str" ]]; then
		run_cmd zfs create "$parent_dataset_str/$(basename "$dest_domain_str")" 2>/dev/null || true
	else
		run_cmd mkdir -p "$dest_domain_str"
	fi

	for d_str in "${disks_arr[@]}"; do
		[[ -f "$d_str" ]] || continue
		[[ -f "$STOP_FLAG" ]] && exit 1
		file_str=$(basename "$d_str")
		file_str="${file_str#$prefix_str}"
		debug_log "Restoring vdisk: $d_str -> $dest_domain_str/$file_str"
		run_cmd rm -f "$dest_domain_str/$file_str"
		restore_vdisk "$d_str" "$dest_domain_str/$file_str"
		RESTORED_FILES_arr+=("$dest_domain_str/$file_str")
		run_cmd chmod 644 "$dest_domain_str/$file_str"
		echo "Restored vdisk $d_str → $dest_domain_str/$file_str"
	done

	[[ -f "$STOP_FLAG" ]] && exit 1

	# ── Redefine VM ────────────────────────────────────────────────────────
	set_restore_status "Redefining $vm_str"
	debug_log "Redefining VM from: $dest_xml_str"
	run_cmd virsh define "$dest_xml_str"
	echo "Redefined $vm_str from $dest_xml_str"

	echo "Finished restore for $vm_str"
	set_restore_status "Finished restore for $vm_str"
	debug_log "--- Finished restore for VM: $vm_str ---"
done

debug_log "All VMs processed"
