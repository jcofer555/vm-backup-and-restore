#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
TMP="${CONFIG}.tmp"

mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
RESTORE_LOCATION="${1:-}"
VM_NAME_RESTORE="${2:-}"
RESTORE_VERSIONS="${3:-}"
RESTORE_DESTINATION="${4:-/mnt/user/domains}"
DRY_RUN_RESTORE="${5:-false}"
ENABLE_NOTIFICATIONS_RESTORE="${6:-false}"

# ==========================================================
#  Write all settings cleanly and atomically
# ==========================================================
{
  echo "RESTORE_LOCATION=\"$RESTORE_LOCATION\""
  echo "VM_NAME_RESTORE=\"$VM_NAME_RESTORE\""
  echo "RESTORE_VERSIONS=\"$RESTORE_VERSIONS\""
  echo "RESTORE_DESTINATION=\"$RESTORE_DESTINATION\""
  echo "DRY_RUN_RESTORE=\"$DRY_RUN_RESTORE\""
  echo "ENABLE_NOTIFICATIONS_RESTORE=\"$ENABLE_NOTIFICATIONS_RESTORE\""
} > "$TMP"

# Atomic replace
mv "$TMP" "$CONFIG"

echo '{"status":"ok"}'
exit 0
