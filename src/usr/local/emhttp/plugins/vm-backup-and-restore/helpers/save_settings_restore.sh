#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
TMP="${CONFIG}.tmp"

mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
LOCATION_OF_BACKUPS="${1:-}"
VMS_TO_RESTORE="${2:-}"
VERSIONS="${3:-}"
RESTORE_DESTINATION="${4:-/mnt/user/domains}"
DRY_RUN_RESTORE="${5:-false}"
NOTIFICATIONS_RESTORE="${6:-false}"

# ==========================================================
#  Write all settings
# ==========================================================
{
  echo "LOCATION_OF_BACKUPS=\"$LOCATION_OF_BACKUPS\""
  echo "VMS_TO_RESTORE=\"$VMS_TO_RESTORE\""
  echo "VERSIONS=\"$VERSIONS\""
  echo "RESTORE_DESTINATION=\"$RESTORE_DESTINATION\""
  echo "DRY_RUN_RESTORE=\"$DRY_RUN_RESTORE\""
  echo "NOTIFICATIONS_RESTORE=\"$NOTIFICATIONS_RESTORE\""
} > "$TMP"

mv "$TMP" "$CONFIG"
echo '{"status":"ok"}'
exit 0
