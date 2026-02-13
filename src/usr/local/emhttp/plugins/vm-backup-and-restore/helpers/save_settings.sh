#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
TMP="${CONFIG}.tmp"

mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
VM_NAME="${1:-}"
BACKUP_DESTINATION="${2:-}"
NUMBER_OF_BACKUPS="${3:-0}"
DRY_RUN="${4:-1}"
ENABLE_NOTIFICATIONS="${5:-0}"
BACKUP_OWNER="${6:-nobody}"

# ==========================================================
#  Write all settings
# ==========================================================
{
  echo "VM_NAME=\"$VM_NAME\""
  echo "BACKUP_DESTINATION=\"$BACKUP_DESTINATION\""
  echo "NUMBER_OF_BACKUPS=\"$NUMBER_OF_BACKUPS\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "ENABLE_NOTIFICATIONS=\"$ENABLE_NOTIFICATIONS\""
  echo "BACKUP_OWNER=\"$BACKUP_OWNER\""
} > "$TMP"

mv "$TMP" "$CONFIG"
echo '{"status":"ok"}'
exit 0
