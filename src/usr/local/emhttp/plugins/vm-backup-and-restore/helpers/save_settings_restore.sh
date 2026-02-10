#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-&-restore/settings_restore.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
RESTORE_LOCATION="${1:-}"
DRY_RUN_RESTORE="${2:-1}"
ENABLE_NOTIFICATIONS_RESTORE="${3:-0}"
RESTORE_VERSIONS="${4:-}"

# ==========================================================
#  Write all settings cleanly and atomically
# ==========================================================
{

  echo "RESTORE_LOCATION=\"$RESTORE_LOCATION\""
  echo "DRY_RUN_RESTORE=\"$DRY_RUN_RESTORE\""
  echo "ENABLE_NOTIFICATIONS_RESTORE=\"$ENABLE_NOTIFICATIONS_RESTORE\""
  echo "RESTORE_VERSIONS=\"$RESTORE_VERSIONS\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0