#!/bin/bash

CONFIG="/boot/config/plugins/vm-backup-and-restore/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
VM_NAME="${1:-}"
BACKUP_DESTINATION="${2:-}"
NUMBER_OF_BACKUPS="${3:-0}"
STOP_VMS="${4:-1}"
DRY_RUN="${5:-1}"
ENABLE_NOTIFICATIONS="${6:-0}"
BACKUP_OWNER="${7:-nobody}"

# ==========================================================
#  Write all settings cleanly and atomically
# ==========================================================
{
  echo "VM_NAME=\"$VM_NAME\""
  echo "BACKUP_DESTINATION=\"$BACKUP_DESTINATION\""
  echo "NUMBER_OF_BACKUPS=\"$NUMBER_OF_BACKUPS\""
  echo "STOP_VMS=\"$STOP_VMS\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "ENABLE_NOTIFICATIONS=\"$ENABLE_NOTIFICATIONS\""
  echo "BACKUP_OWNER=\"$BACKUP_OWNER\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0
