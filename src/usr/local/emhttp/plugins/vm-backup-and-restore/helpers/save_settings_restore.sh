#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
VM_NAME_RESTORE="${1:-}"
RESTORE_LOCATION="${2:-}"
DRY_RUN_RESTORE="${3:-1}"
ENABLE_NOTIFICATIONS_RESTORE="${4:-0}"
RESTORE_VERSIONS="${5:-}"
RESTORE_DESTINATION="${6:-/mnt/user/domains}"

# ==========================================================
#  Write all settings cleanly and atomically
# ==========================================================
{

  echo "VM_NAME_RESTORE=\"$VM_NAME_RESTORE\""
  echo "RESTORE_LOCATION=\"$RESTORE_LOCATION\""
  echo "DRY_RUN_RESTORE=\"$DRY_RUN_RESTORE\""
  echo "ENABLE_NOTIFICATIONS_RESTORE=\"$ENABLE_NOTIFICATIONS_RESTORE\""
  echo "RESTORE_VERSIONS=\"$RESTORE_VERSIONS\""
  echo "RESTORE_DESTINATION=\"$RESTORE_DESTINATION\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0
