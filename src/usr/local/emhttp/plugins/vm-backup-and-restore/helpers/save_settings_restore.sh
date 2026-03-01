#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings_restore.cfg"
TMP="${CONFIG}.tmp"

mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
LOCATION_OF_BACKUPS="${1:-}"
VMS_TO_RESTORE="${2:-}"
VERSIONS="${3:-}"
RESTORE_DESTINATION="${4:-/mnt/user/domains}"
DRY_RUN_RESTORE="${5:-no}"
NOTIFICATIONS_RESTORE="${6:-}"
NOTIFICATION_SERVICE_RESTORE="${7:-}"
WEBHOOK_DISCORD_RESTORE="${8:-}"
WEBHOOK_GOTIFY_RESTORE="${9:-}"
WEBHOOK_NTFY_RESTORE="${10:-}"
WEBHOOK_PUSHOVER_RESTORE="${11:-}"
WEBHOOK_SLACK_RESTORE="${12:-}"
PUSHOVER_USER_KEY_RESTORE="${13:-}"

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
  echo "NOTIFICATION_SERVICE_RESTORE=\"$NOTIFICATION_SERVICE_RESTORE\""
  echo "WEBHOOK_DISCORD_RESTORE=\"$WEBHOOK_DISCORD_RESTORE\""
  echo "WEBHOOK_GOTIFY_RESTORE=\"$WEBHOOK_GOTIFY_RESTORE\""
  echo "WEBHOOK_NTFY_RESTORE=\"$WEBHOOK_NTFY_RESTORE\""
  echo "WEBHOOK_PUSHOVER_RESTORE=\"$WEBHOOK_PUSHOVER_RESTORE\""
  echo "WEBHOOK_SLACK_RESTORE=\"$WEBHOOK_SLACK_RESTORE\""
  echo "PUSHOVER_USER_KEY_RESTORE=\"$PUSHOVER_USER_KEY_RESTORE\""
} > "$TMP"

mv "$TMP" "$CONFIG"
echo '{"status":"ok"}'
exit 0