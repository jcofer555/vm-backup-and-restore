#!/usr/bin/env bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_START_EPOCH=$(date +%s)
STOP_FLAG="/tmp/vm-backup-and-restore/stop_requested.txt"
RSYNC_PID=""
WATCHER_PID=""
SNAPSHOT_CLEANUP_arr=()   # "vm_str:disk_path:snapshot_name" entries for cleanup on abort
STOPPED_FOR_BACKUP_arr=() # VMs that were stopped for backup (stop/copy/start fallback)

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
printf "PID=%s\nMODE=schedule\nSCHEDULE_ID=%s\nSTART=%s\n" "$$" "${SCHEDULE_ID:-}" "$(date +%s)" >"$LOCK_FILE"

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

cleanup_partial_backup() {
	local folder_str="$1" ts_str="$2"
	[[ ! -d "$folder_str" ]] && return
	shopt -s nullglob
	local run_files_arr=("$folder_str/${ts_str}_"*)
	shopt -u nullglob
	debug_log "cleanup_partial: folder=$folder_str ts=$ts_str files=${#run_files_arr[@]}"
	for f_str in "${run_files_arr[@]}"; do
		rm -f "$f_str"
		debug_log "Removed: $f_str"
	done
	[[ -z "$(ls -A "$folder_str")" ]] && rmdir "$folder_str" && debug_log "Removed empty folder: $folder_str"
}

# cleanup_snapshots — abort any live snapshots that were not yet committed
cleanup_snapshots() {
	for entry_str in "${SNAPSHOT_CLEANUP_arr[@]}"; do
		local vm_str="${entry_str%%:*}"
		local _r1_str="${entry_str#*:}"
		local disk_path_str="${_r1_str%%:*}"
		local _r2_str="${_r1_str#*:}"
		local target_dev_str="${_r2_str%%:*}"
		local snap_name_str="${_r2_str#*:}"
		debug_log "cleanup_snapshot: vm=$vm_str disk=$disk_path_str dev=$target_dev_str snap=$snap_name_str"
		if virsh snapshot-info "$vm_str" "$snap_name_str" >/dev/null 2>&1; then
			virsh snapshot-delete "$vm_str" "$snap_name_str" --metadata >/dev/null 2>&1 || true
			debug_log "Deleted snapshot metadata: $snap_name_str"
		fi
		# Commit any leftover overlay back into the base to restore the disk chain
		if [[ -f "${disk_path_str}.snap_${snap_name_str}" ]]; then
			virsh blockcommit "$vm_str" "$target_dev_str" --active --pivot --wait >/dev/null 2>&1 || true
			rm -f "${disk_path_str}.snap_${snap_name_str}" 2>/dev/null || true
			debug_log "Committed leftover overlay for $disk_path_str (dev=$target_dev_str)"
		fi
	done
	SNAPSHOT_CLEANUP_arr=()
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
	echo "$RSYNC_PID" >"$LOG_DIR/rsync.pid"
	wait $RSYNC_PID
	local exit_code_int=$?
	RSYNC_PID=""
	rm -f "$LOG_DIR/rsync.pid"
	if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
		debug_log "run_rsync interrupted (exit=$exit_code_int)"
		exit 1
	fi
	debug_log "rsync finished exit=$exit_code_int"
	return $exit_code_int
}

# copy_vdisk <src> <dest>
#
# Strategy:
#   same-fs  → cp --reflink=always (instant CoW on Btrfs/XFS, no data copied)
#   diff-fs  → cp --sparse=always  (copies file, skips zero runs)
#   fallback → rsync --sparse      (if cp fails for any other reason)
#
# If dest already exists, delta sync is used instead (rsync --inplace --no-whole-file)
# which only writes changed blocks — much faster for large vdisks with small changes.
copy_vdisk() {
	local src_str="$1"
	local dest_str="$2"

	if is_dry_run; then
		printf '[DRY-RUN] copy_vdisk %q -> %q\n' "$src_str" "$dest_str"
		return 0
	fi

	debug_log "copy_vdisk: $src_str -> $dest_str"

	# Delta sync — if a previous backup exists, only write changed blocks
	if [[ -f "$dest_str" ]]; then
		debug_log "copy_vdisk: dest exists — using delta sync (rsync --inplace)"
		rsync -aHAX --inplace --no-whole-file "$src_str" "$dest_str" &
		RSYNC_PID=$!
		echo "$RSYNC_PID" >"$LOG_DIR/rsync.pid"
		wait $RSYNC_PID
		local exit_code_int=$?
		RSYNC_PID=""
		rm -f "$LOG_DIR/rsync.pid"
		if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
			debug_log "copy_vdisk: delta sync interrupted (exit=$exit_code_int)"
			exit 1
		fi
		debug_log "copy_vdisk: delta sync finished exit=$exit_code_int"
		return $exit_code_int
	fi

	# Fresh copy — try reflink first (instant CoW on same Btrfs/XFS filesystem)
	if cp --reflink=always "$src_str" "$dest_str" 2>/dev/null; then
		debug_log "copy_vdisk: reflink OK (instant CoW)"
		return 0
	fi

	# Cross-filesystem or no reflink support — cp --sparse=always
	debug_log "copy_vdisk: cp --sparse=always"
	cp --sparse=always "$src_str" "$dest_str" &
	local cp_pid_int=$!
	wait $cp_pid_int
	local exit_code_int=$?
	if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
		debug_log "copy_vdisk: cp interrupted (exit=$exit_code_int)"
		exit 1
	fi
	if [[ $exit_code_int -eq 0 ]]; then
		debug_log "copy_vdisk: cp --sparse=always OK"
		return 0
	fi

	# Fallback: rsync --sparse
	debug_log "copy_vdisk: cp failed (exit=$exit_code_int), falling back to rsync --sparse"
	rm -f "$dest_str"
	rsync -aHAX --sparse "$src_str" "$dest_str" &
	RSYNC_PID=$!
	echo "$RSYNC_PID" >"$LOG_DIR/rsync.pid"
	wait $RSYNC_PID
	local exit_code_int=$?
	RSYNC_PID=""
	rm -f "$LOG_DIR/rsync.pid"
	if [[ -f "$STOP_FLAG" ]] || ((exit_code_int > 128)); then
		debug_log "copy_vdisk: rsync interrupted (exit=$exit_code_int)"
		exit 1
	fi
	debug_log "copy_vdisk: rsync finished exit=$exit_code_int"
	return $exit_code_int
}


# _commit_snapshot <vm> <disk_path> <target_dev> <snap_name> <overlay_path>
# virsh blockcommit must identify the disk by target device name (e.g. hdc),
# NOT by source file path — hence the separate target_dev parameter.
_commit_snapshot() {
	local vm_str="$1" disk_path_str="$2" target_dev_str="$3" snap_name_str="$4" overlay_str="$5"
	debug_log "_commit_snapshot: vm=$vm_str disk=$disk_path_str dev=$target_dev_str snap=$snap_name_str"

	# blockcommit merges the overlay back into base and pivots the active disk.
	# Capture stderr so we can log the real libvirt error on failure.
	local bc_err_tmp_str
	bc_err_tmp_str="$(mktemp /tmp/vmbr_bc_err.XXXXXX)"
	if virsh blockcommit "$vm_str" "$target_dev_str" \
		--active --pivot --wait >/dev/null 2>"$bc_err_tmp_str"; then
		rm -f "$bc_err_tmp_str"
		debug_log "_commit_snapshot: blockcommit OK for $target_dev_str"
		rm -f "$overlay_str"
		debug_log "_commit_snapshot: overlay removed $overlay_str"
	else
		local bc_err_str
		bc_err_str="$(cat "$bc_err_tmp_str" 2>/dev/null | tr '\n' ' ')"
		rm -f "$bc_err_tmp_str"
		echo "WARNING: blockcommit failed for $target_dev_str — overlay left at $overlay_str"
		echo "         Libvirt error: ${bc_err_str:-<no output captured>}"
		debug_log "_commit_snapshot: blockcommit FAILED for $target_dev_str — ${bc_err_str:-<none>}"
		((error_count_int++))
	fi

	# Clean up snapshot metadata from libvirt
	if virsh snapshot-info "$vm_str" "$snap_name_str" >/dev/null 2>&1; then
		virsh snapshot-delete "$vm_str" "$snap_name_str" --metadata >/dev/null 2>&1 || true
		debug_log "_commit_snapshot: snapshot metadata deleted"
	fi
}

# ══════════════════════════════════════════════════════════════════════════════
# BACKUP
#
# Always uses the live snapshot method — VM stays running throughout:
#
#   1. virsh snapshot-create-as --disk-only --atomic [--quiesce]
#      libvirt momentarily freezes guest I/O, redirects all future writes to a
#      new QCOW2 overlay, and resumes.  The base disk is now frozen.
#
#   2. Copy the FROZEN BASE DISK to the backup folder.
#      The overlay absorbs all live writes so the base is stable and consistent.
#
#   3. blockcommit --active --pivot
#      Merges the overlay back into the base and pivots the VM.  VM continues
#      normally with no data loss.  The overlay is removed.
#
#   4. XML and NVRAM backed up as usual.
#
# If the VM is not running, falls back to a direct copy (no snapshot needed
# since the disk is already quiesced by being offline).
# ══════════════════════════════════════════════════════════════════════════════
do_backup() {
	local vm_str="$1"
	local vm_xml_path_str="$2"
	local vm_backup_folder_str="$3"
	local vdisks_arr=("${@:4}")

	local vm_state_str
	vm_state_str="$(virsh domstate "$vm_str" 2>/dev/null || echo "unknown")"

	if [[ "$vm_state_str" != "running" ]]; then
		# VM is offline — disk is already quiesced, copy directly
		debug_log "do_backup: $vm_str not running (state=$vm_state_str), direct copy"
		if is_dry_run; then
			for vdisk_str in "${vdisks_arr[@]}"; do
				local base_str dest_str
				base_str="$(basename "$vdisk_str")"
				dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
				printf '[DRY-RUN] copy_vdisk %q -> %q\n' "$vdisk_str" "$dest_str"
			done
			return 0
		fi
		_do_direct_copy "$vm_str" "$vm_backup_folder_str" "${vdisks_arr[@]}"
		return $?
	fi

	if is_dry_run; then
		echo "[DRY-RUN] Would backup $vm_str"
		for vdisk_str in "${vdisks_arr[@]}"; do
			local base_str dest_str
			base_str="$(basename "$vdisk_str")"
			dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
			printf '[DRY-RUN] copy_vdisk %q -> %q\n' "$vdisk_str" "$dest_str"
		done
		return 0
	fi

	local snap_name_str="vmbr_snap_${RUN_TS}"
	debug_log "do_backup: creating snapshot $snap_name_str for $vm_str"
	set_status "Creating snapshot for $vm_str"

	# Build --diskspec args — target device name required, not source path
	local diskspec_args_arr=()
	local overlay_map_arr=()   # "vdisk_path:overlay_path:target_dev"
	for vdisk_str in "${vdisks_arr[@]}"; do
		local overlay_str="${vdisk_str}.snap_${snap_name_str}"

		local target_dev_str
		target_dev_str=$(xmllint --xpath \
			"string(//domain/devices/disk[@device='disk'][source/@file='${vdisk_str}']/target/@dev)" \
			"$vm_xml_path_str" 2>/dev/null)

		if [[ -z "$target_dev_str" ]]; then
			debug_log "do_backup: could not find target dev for $vdisk_str"
			echo "WARNING: could not resolve target device for $vdisk_str — snapshot may fail"
			target_dev_str="$vdisk_str"
		fi

		debug_log "do_backup: diskspec $target_dev_str -> $overlay_str"
		diskspec_args_arr+=(--diskspec "$target_dev_str,snapshot=external,file=$overlay_str")
		overlay_map_arr+=("$vdisk_str:$overlay_str:$target_dev_str")
		SNAPSHOT_CLEANUP_arr+=("$vm_str:$vdisk_str:$target_dev_str:$snap_name_str")
	done

	# Attempt quiesced snapshot first, fall back to non-quiesced
	local snap_ok_bool=false
	local snap_err_tmp_str
	snap_err_tmp_str="$(mktemp /tmp/vmbr_snap_err.XXXXXX)"

	if virsh snapshot-create-as "$vm_str" "$snap_name_str" \
		--disk-only --atomic --quiesce \
		"${diskspec_args_arr[@]}" >/dev/null 2>"$snap_err_tmp_str"; then
		snap_ok_bool=true
		echo "Created snapshot for $vm_str (guest agent installed)"
		debug_log "do_backup: quiesced snapshot OK (filesystem-consistent)"
	elif virsh snapshot-create-as "$vm_str" "$snap_name_str" \
		--disk-only --atomic \
		"${diskspec_args_arr[@]}" >/dev/null 2>"$snap_err_tmp_str"; then
		snap_ok_bool=true
		echo "Created snapshot for $vm_str (no guest agent installed)"
		debug_log "do_backup: non-quiesced snapshot OK (crash-consistent)"
	fi

	if [[ "$snap_ok_bool" == false ]]; then
		local snap_err_str
		snap_err_str="$(cat "$snap_err_tmp_str" 2>/dev/null | tr '\n' ' ')"
		rm -f "$snap_err_tmp_str"
		echo "WARNING: Snapshot creation failed for $vm_str — falling back to direct copy (VM will be stopped)"
		echo "         Libvirt error: ${snap_err_str:-<no output captured>}"
		debug_log "do_backup: snapshot failed — ${snap_err_str:-<none>} — falling back to stop/copy/start"
		SNAPSHOT_CLEANUP_arr=()
		_do_stop_copy_start "$vm_str" "$vm_xml_path_str" "$vm_backup_folder_str" "${vdisks_arr[@]}"
		return $?
	fi
	rm -f "$snap_err_tmp_str"

	[[ -f "$STOP_FLAG" ]] && { cleanup_snapshots; exit 1; }

	# Copy the frozen base disk to backup
	set_status "Backing up vdisk(s) for $vm_str"
	echo "Backing up vdisk(s)"
	for entry_str in "${overlay_map_arr[@]}"; do
		local vdisk_str="${entry_str%%:*}"
		local _omap_rest_str="${entry_str#*:}"
		local overlay_str="${_omap_rest_str%%:*}"
		local base_str dest_str
		base_str="$(basename "$vdisk_str")"
		dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"

		if [[ ! -f "$overlay_str" ]]; then
			echo "ERROR: Snapshot overlay not found for $vdisk_str — base disk may not be frozen"
			debug_log "do_backup: overlay missing: $overlay_str"
			((error_count_int++))
			local _err_dev_str="${_omap_rest_str#*:}"
			_commit_snapshot "$vm_str" "$vdisk_str" "$_err_dev_str" "$snap_name_str" "$overlay_str"
			cleanup_snapshots
			return 1
		fi

		echo "$vdisk_str -> $dest_str"
		debug_log "do_backup: copying $vdisk_str -> $dest_str"
		copy_vdisk "$vdisk_str" "$dest_str"

		[[ -f "$STOP_FLAG" ]] && {
			cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
			cleanup_snapshots
			exit 1
		}
	done

	# Commit overlays back into base disks, pivot VM
	set_status "Committing snapshots for $vm_str"
	
	for entry_str in "${overlay_map_arr[@]}"; do
		local vdisk_str="${entry_str%%:*}"
		local _cmap_rest_str="${entry_str#*:}"
		local overlay_str="${_cmap_rest_str%%:*}"
		local commit_dev_str="${_cmap_rest_str#*:}"
		local snap_name_str_local="$snap_name_str"
		_commit_snapshot "$vm_str" "$vdisk_str" "$commit_dev_str" "$snap_name_str_local" "$overlay_str"
	done

	SNAPSHOT_CLEANUP_arr=()
	debug_log "do_backup: all overlays committed for $vm_str"
}

# _do_direct_copy — copy vdisks directly (VM is already offline)
_do_direct_copy() {
	local vm_str="$1"
	local vm_backup_folder_str="$2"
	local vdisks_arr=("${@:3}")

	if ((${#vdisks_arr[@]} == 0)); then
		echo "No vdisk entries located in XML for $vm_str"
		return 0
	fi

	echo "Backing up vdisks"
	set_status "Backing up vdisks for $vm_str"
	for vdisk_str in "${vdisks_arr[@]}"; do
		if [[ ! -f "$vdisk_str" ]]; then
			echo "[ERROR] $vm_str vdisk $vdisk_str not found — skipping"
			((error_count_int++))
			cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
			return 1
		fi
		local base_str dest_str
		base_str="$(basename "$vdisk_str")"
		dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
		echo "$vdisk_str -> $dest_str"
		copy_vdisk "$vdisk_str" "$dest_str"
		[[ -f "$STOP_FLAG" ]] && {
			cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
			exit 1
		}
	done

	# Extra files in the same directories
	declare -A vdisk_dirs_arr
	for vdisk_str in "${vdisks_arr[@]}"; do
		vdisk_dirs_arr["$(dirname "$vdisk_str")"]=1
	done
	for dir_str in "${!vdisk_dirs_arr[@]}"; do
		for extra_file_str in "$dir_str"/*; do
			[[ -f "$extra_file_str" ]] || continue
			local already_bool=false
			for vdisk_str in "${vdisks_arr[@]}"; do
				[[ "$extra_file_str" == "$vdisk_str" ]] && already_bool=true && break
			done
			$already_bool && continue
			local base_str dest_str
			base_str="$(basename "$extra_file_str")"
			dest_str="$vm_backup_folder_str/${RUN_TS}_$base_str"
			echo "Backing up extra file $extra_file_str -> $dest_str"
			copy_vdisk "$extra_file_str" "$dest_str"
			[[ -f "$STOP_FLAG" ]] && {
				cleanup_partial_backup "$vm_backup_folder_str" "$RUN_TS"
				exit 1
			}
		done
	done
	unset vdisk_dirs_arr
	return 0
}

# _do_stop_copy_start — fallback when snapshot creation fails: stop VM, copy, start
_do_stop_copy_start() {
	local vm_str="$1"
	local vm_xml_path_str="$2"
	local vm_backup_folder_str="$3"
	local vdisks_arr=("${@:4}")

	local vm_state_before_str
	vm_state_before_str="$(virsh domstate "$vm_str" 2>/dev/null || echo "unknown")"

	if [[ "$vm_state_before_str" == "running" ]]; then
		set_status "Stopping $vm_str"
		debug_log "_do_stop_copy_start: stopping $vm_str"
		run_cmd virsh shutdown "$vm_str" >/dev/null 2>&1 || echo "WARNING: Failed to send shutdown to $vm_str"
		if ! is_dry_run; then
			timeout_int=60
			while [[ "$(virsh domstate "$vm_str" 2>/dev/null)" != "shut off" && $timeout_int -gt 0 ]]; do
				[[ -f "$STOP_FLAG" ]] && exit 1
				sleep 2
				((timeout_int -= 2))
			done
			if [[ $timeout_int -le 0 ]]; then
				if virsh destroy "$vm_str" >/dev/null 2>&1; then
					echo "Force stopped $vm_str"
					STOPPED_FOR_BACKUP_arr+=("$vm_str")
				else
					echo "ERROR: Unable to stop $vm_str - skipping backup"
					((error_count_int++))
					return 1
				fi
			else
				echo "Stopped $vm_str"
				STOPPED_FOR_BACKUP_arr+=("$vm_str")
			fi
		fi
	fi

	[[ -f "$STOP_FLAG" ]] && exit 1
	_do_direct_copy "$vm_str" "$vm_backup_folder_str" "${vdisks_arr[@]}"
	local copy_exit_int=$?

	if [[ "$vm_state_before_str" == "running" ]]; then
		set_status "Starting $vm_str"
		if run_cmd virsh start "$vm_str" >/dev/null 2>&1; then
			echo "Started $vm_str"
		else
			echo "WARNING: Failed to start $vm_str"
		fi
	fi
	return $copy_exit_int
}

set_status() { echo "$1" >"$STATUS_FILE"; }
debug_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup debug - $*" >>"$DEBUG_LOG"; }

is_dry_run() { [[ "$DRY_RUN" == "yes" ]]; }
run_cmd() {
	if is_dry_run; then
		printf '[DRY-RUN] '
		printf '%q ' "$@"
		echo
	else "$@"; fi
}

# Shared retention logic
_do_retention() {
	local vm_str="$1" folder_str="$2" keep_int="$3"
	if ! [[ "$keep_int" =~ ^[0-9]+$ ]]; then
		echo "WARNING: retention count is invalid, skipping"
		return
	fi
	((keep_int == 0)) && {
		debug_log "retention=0 (unlimited) for $vm_str"
		return
	}
	mapfile -t sets_arr < <(
		ls -1 "$folder_str" 2>/dev/null |
			sed -E 's/^([0-9]{8}_[0-9]{6}).*/\1/' | sort -u -r
	)
	local total_int=${#sets_arr[@]}
	debug_log "retention: $vm_str found=$total_int keep=$keep_int folder=$folder_str"
	if ((total_int > keep_int)); then
		echo "Removing old backups, keeping $keep_int"
		set_status "Removing old backups for $vm_str"
		for ((i = keep_int; i < total_int; i++)); do
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
	if ((size_bytes_int >= 10 * 1024 * 1024)); then
		rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
		mv "$LAST_RUN_FILE" "$ROTATE_DIR/vm-backup-and-restore_${rotate_ts_str}.log"
		debug_log "Rotated main log"
	fi
fi
mapfile -t rl_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore_*.log 2>/dev/null | sort)
((${#rl_arr[@]} > 10)) && for ((i = 10; i < ${#rl_arr[@]}; i++)); do rm -f "${rl_arr[$i]}"; done

if [[ -f "$DEBUG_LOG" ]]; then
	size_bytes_int=$(stat -c%s "$DEBUG_LOG")
	if ((size_bytes_int >= 10 * 1024 * 1024)); then
		rotate_ts_str="$(date +%Y%m%d_%H%M%S)"
		mv "$DEBUG_LOG" "$ROTATE_DIR/vm-backup-and-restore-debug_${rotate_ts_str}.log"
	fi
fi
mapfile -t rdl_arr < <(ls -1t "$ROTATE_DIR"/vm-backup-and-restore-debug_*.log 2>/dev/null | sort)
((${#rdl_arr[@]} > 10)) && for ((i = 10; i < ${#rdl_arr[@]}; i++)); do rm -f "${rdl_arr[$i]}"; done

exec > >(tee -a "$LAST_RUN_FILE") 2>&1

PLG_FILE="/boot/config/plugins/vm-backup-and-restore.plg"
[[ -f "$PLG_FILE" ]] && version_str=$(grep -oP 'version="\K[^"]+' "$PLG_FILE" | head -n1) || version_str="unknown"
echo "--------------------------------------------------------------------------------------------------"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session started - Plugin version: $version_str"

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
debug_log "Loading config: $CONFIG"
source "$CONFIG" || {
	debug_log "ERROR: Failed to source config"
	exit 1
}

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
	case "$level_str" in alert) color_int=15158332 ;; warning) color_int=16776960 ;; *) color_int=3066993 ;; esac
	IFS=',' read -ra services_arr <<<"$NOTIFICATION_SERVICE"
	for service_str in "${services_arr[@]}"; do
		service_str="${service_str// /}"
		case "$service_str" in
		Discord) [[ -n "$WEBHOOK_DISCORD" ]] && curl -sf -X POST "$WEBHOOK_DISCORD" -H "Content-Type: application/json" -d "{\"embeds\":[{\"title\":\"$title_str\",\"description\":\"$message_str\",\"color\":$color_int}]}" || true ;;
		Gotify) [[ -n "$WEBHOOK_GOTIFY" ]] && curl -sf -X POST "$WEBHOOK_GOTIFY" -H "Content-Type: application/json" -d "{\"title\":\"$title_str\",\"message\":\"$message_str\",\"priority\":5}" || true ;;
		Ntfy) [[ -n "$WEBHOOK_NTFY" ]] && curl -sf -X POST "$WEBHOOK_NTFY" -H "Title: $title_str" -d "$message_str" >/dev/null || true ;;
		Pushover) [[ -n "$WEBHOOK_PUSHOVER" && -n "$PUSHOVER_USER_KEY" ]] && curl -sf -X POST "https://api.pushover.net/1/messages.json" -d "token=${WEBHOOK_PUSHOVER##*/}" -d "user=${PUSHOVER_USER_KEY}" -d "title=${title_str}" -d "message=${message_str}" >/dev/null || true ;;
		Slack) [[ -n "$WEBHOOK_SLACK" ]] && curl -sf -X POST "$WEBHOOK_SLACK" -H "Content-Type: application/json" -d "{\"text\":\"*$title_str*\n$message_str\"}" || true ;;
		Unraid) [[ -x /usr/local/emhttp/webGui/scripts/notify ]] && /usr/local/emhttp/webGui/scripts/notify -e "VM Backup & Restore" -s "$title_str" -d "$message_str" -i "$level_str" ;;
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
backup_location_str="${BACKUP_DESTINATION:-}"
export backup_location_str
debug_log "BACKUP_DESTINATION=$backup_location_str"
debug_log "===== Session started ====="
debug_log "DRY_RUN=$DRY_RUN"
debug_log "BACKUPS_TO_KEEP=$BACKUPS_TO_KEEP backup_location=$backup_location_str"

readarray -td ',' VM_ARRAY_arr <<<"${VMS_TO_BACKUP:-},"
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

cleanup() {
	kill "$WATCHER_PID" 2>/dev/null
	flock -u $LOCK_FD 2>/dev/null
	rm -f "$LOCK_FILE"
	debug_log "Lock file removed"

	if [[ -f "$STOP_FLAG" ]]; then
		rm -f "$STOP_FLAG"
		# Clean up any open snapshots
		cleanup_snapshots
		local end_epoch_int duration_int
		end_epoch_int=$(date +%s)
		duration_int=$((end_epoch_int - SCRIPT_START_EPOCH))
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
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
		notify_vm "warning" "VM Backup & Restore" "Backup was stopped early - Duration: $SCRIPT_DURATION_HUMAN"
		set_status "Backup stopped and cleaned up"
		rm -f "$STATUS_FILE"
		debug_log "===== Session ended (stopped early) ====="
		return
	fi

	local end_epoch_int duration_int
	end_epoch_int=$(date +%s)
	duration_int=$((end_epoch_int - SCRIPT_START_EPOCH))
	SCRIPT_DURATION_HUMAN="$(format_duration "$duration_int")"
	set_status "Backup complete - Duration: $SCRIPT_DURATION_HUMAN"

	if is_dry_run; then
		((${#STOPPED_FOR_BACKUP_arr[@]} > 0)) && echo "Skipping VM restarts because dry run is enabled"
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
		notify_vm "normal" "VM Backup & Restore" "Backup finished - Duration: $SCRIPT_DURATION_HUMAN"
		rm -f "$STATUS_FILE"
		debug_log "===== Session ended (dry run) ====="
		return
	fi

	echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup session finished - Duration: $SCRIPT_DURATION_HUMAN"
	debug_log "Session finished duration=$SCRIPT_DURATION_HUMAN errors=$error_count_int"
	if ((error_count_int > 0)); then
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

(
	trap '' SIGTERM
	while true; do
		sleep 1
		[[ -f "$STOP_FLAG" ]] && { kill -TERM $$ 2>/dev/null; break; }
	done
) &>/dev/null &
WATCHER_PID=$!

RUN_TS="$(date +%Y%m%d_%H%M%S)"
debug_log "RUN_TS=$RUN_TS"

run_cmd mkdir -p "$backup_location_str"

# Handle FORCE_STOP_VMS — stop selected VMs before backup for full consistency
# This list is set by the WebUI "Force Stop" toggle via the config or env var.
FORCE_STOP_VMS="${FORCE_STOP_VMS:-no}"
FORCE_STOPPED_arr=()

if [[ "$FORCE_STOP_VMS" == "yes" ]] && ! is_dry_run; then
	debug_log "FORCE_STOP_VMS enabled — stopping VMs before backup"
	for vm_str in "${CLEAN_VMS_arr[@]}"; do
		[[ -z "$vm_str" ]] && continue
		vm_state_str="$(virsh domstate "$vm_str" 2>/dev/null || echo "unknown")"
		if [[ "$vm_state_str" == "running" ]]; then
			echo "Force stopping $vm_str before backup"
			set_status "Force stopping $vm_str"
			virsh shutdown "$vm_str" >/dev/null 2>&1 || true
			timeout_int=60
			while [[ "$(virsh domstate "$vm_str" 2>/dev/null)" != "shut off" && $timeout_int -gt 0 ]]; do
				[[ -f "$STOP_FLAG" ]] && exit 1
				sleep 2
				((timeout_int -= 2))
			done
			if [[ $timeout_int -le 0 ]]; then
				virsh destroy "$vm_str" >/dev/null 2>&1 && echo "Force killed $vm_str" || echo "WARNING: Could not stop $vm_str"
			fi
			FORCE_STOPPED_arr+=("$vm_str")
			debug_log "Force stopped: $vm_str"
		fi
	done
fi

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
		((error_count_int++))
		continue
	fi

	mapfile -t vdisks_arr < <(
		xmllint --xpath "//domain/devices/disk[@device='disk']/source/@file" "$vm_xml_path_str" 2>/dev/null |
			sed -E 's/ file=\"/\n/g' | sed -E 's/\"//g' | sed '/^$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
	)
	debug_log "vdisks for $vm_str: ${vdisks_arr[*]:-none}"

	vm_backup_folder_str="$backup_location_str/$vm_str"
	run_cmd mkdir -p "$vm_backup_folder_str"

	do_backup "$vm_str" "$vm_xml_path_str" "$vm_backup_folder_str" "${vdisks_arr[@]}"
	backup_exit_int=$?
	[[ $backup_exit_int -ne 0 ]] && { debug_log "backup failed for $vm_str exit=$backup_exit_int"; continue; }
	[[ -f "$STOP_FLAG" ]] && exit 1

	# ── XML backup (both types) ────────────────────────────────────────────
	xml_dest_str="$vm_backup_folder_str/${RUN_TS}_${vm_str}.xml"
	set_status "Backing up XML for $vm_str"
	run_rsync -a "$vm_xml_path_str" "$xml_dest_str"
	echo "Backed up XML $vm_xml_path_str -> $xml_dest_str"

	# ── NVRAM backup (both types) ──────────────────────────────────────────
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

	run_cmd chown -R "$backup_owner_str:users" "$vm_backup_folder_str" ||
		echo "WARNING: chown failed for $vm_backup_folder_str"
	echo "Changed owner of $vm_backup_folder_str to $backup_owner_str:users"

	echo "Finished backup for $vm_str"
	set_status "Finished backup for $vm_str"
	debug_log "--- Finished backup for VM: $vm_str ---"
	_do_retention "$vm_str" "$vm_backup_folder_str" "$BACKUPS_TO_KEEP"
done

# Restart any VMs that were force-stopped before backup
if ((${#FORCE_STOPPED_arr[@]} > 0)) && ! is_dry_run; then
	debug_log "Restarting force-stopped VMs"
	for vm_str in "${FORCE_STOPPED_arr[@]}"; do
		[[ -z "$vm_str" ]] && continue
		set_status "Starting $vm_str"
		if virsh start "$vm_str" >/dev/null 2>&1; then
			echo "Started $vm_str"
			debug_log "Restarted force-stopped VM: $vm_str"
		else
			echo "WARNING: Failed to start $vm_str"
			debug_log "Failed to restart force-stopped VM: $vm_str"
		fi
	done
fi

debug_log "All VMs processed"
exit 0