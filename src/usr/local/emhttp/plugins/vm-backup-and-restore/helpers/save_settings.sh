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
DISCORD_WEBHOOK_URL="${7:-}"
PUSHOVER_USER_KEY="${8:-}"

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
  echo "DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\""
  echo "PUSHOVER_USER_KEY=\"$PUSHOVER_USER_KEY\""
} > "$TMP"

mv "$TMP" "$CONFIG"
echo '{"status":"ok"}'
exit 0
