#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
TMP="${CONFIG}.tmp"

mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
VMS_TO_BACKUP="${1:-}"
BACKUP_DESTINATION="${2:-}"
BACKUPS_TO_KEEP="${3:-0}"
BACKUP_OWNER="${4:-nobody}"
DRY_RUN="${5:-no}"
NOTIFICATIONS="${6:-no}"
NOTIFICATION_SERVICE="${7:-}"
WEBHOOK_DISCORD="${8:-}"
WEBHOOK_GOTIFY="${9:-}"
WEBHOOK_NTFY="${10:-}"
WEBHOOK_PUSHOVER="${11:-}"
WEBHOOK_SLACK="${12:-}"
PUSHOVER_USER_KEY="${13:-}"

# ==========================================================
#  Write all settings
# ==========================================================
{
  echo "VMS_TO_BACKUP=\"$VMS_TO_BACKUP\""
  echo "BACKUP_DESTINATION=\"$BACKUP_DESTINATION\""
  echo "BACKUPS_TO_KEEP=\"$BACKUPS_TO_KEEP\""
  echo "BACKUP_OWNER=\"$BACKUP_OWNER\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "NOTIFICATIONS=\"$NOTIFICATIONS\""
  echo "NOTIFICATION_SERVICE=\"$NOTIFICATION_SERVICE\""
  echo "WEBHOOK_DISCORD=\"$WEBHOOK_DISCORD\""
  echo "WEBHOOK_GOTIFY=\"$WEBHOOK_GOTIFY\""
  echo "WEBHOOK_NTFY=\"$WEBHOOK_NTFY\""
  echo "WEBHOOK_PUSHOVER=\"$WEBHOOK_PUSHOVER\""
  echo "WEBHOOK_SLACK=\"$WEBHOOK_SLACK\""
  echo "PUSHOVER_USER_KEY=\"$PUSHOVER_USER_KEY\""
} > "$TMP"

mv "$TMP" "$CONFIG"
echo '{"status":"ok"}'
exit 0