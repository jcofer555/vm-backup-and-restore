#!/bin/bash

CONFIG="/boot/config/plugins/automover/settings.cfg"
mkdir -p "$(dirname "$CONFIG")"

# Safely assign defaults if missing
POOL_NAME="${1:-cache}"
DRY_RUN="${2:-no}"
ALLOW_DURING_PARITY="${3:-no}"
AUTOSTART="${4:-no}"
CRON_MODE="${5:-minutes}"
MINUTES_FREQUENCY="${6:-2}"
HOURLY_FREQUENCY="${7:-}"
DAILY_TIME="${8:-}"
WEEKLY_DAY="${9:-}"
WEEKLY_TIME="${10:-}"
MONTHLY_DAY="${11:-}"
MONTHLY_TIME="${12:-}"
CUSTOM_CRON="${13:-}"
CRON_EXPRESSION="${14:-}"
ENABLE_NOTIFICATIONS="${15:-no}"
WEBHOOK_URL="${16:-}"

# ==========================================================
#  Normalize and sanitize CONTAINER_NAMES
# ==========================================================
if [[ -n "$CONTAINER_NAMES_RAW" ]]; then
  CONTAINER_NAMES=$(echo "$CONTAINER_NAMES_RAW" | sed 's/, */,/g' | xargs)
else
  CONTAINER_NAMES=""
fi

# ==========================================================
#  Write all settings cleanly and atomically
# ==========================================================
{
  echo "POOL_NAME=\"$POOL_NAME\""
  echo "DRY_RUN=\"$DRY_RUN\""
  echo "ALLOW_DURING_PARITY=\"$ALLOW_DURING_PARITY\""
  echo "AUTOSTART=\"$AUTOSTART\""
  echo "CRON_MODE=\"$CRON_MODE\""
  echo "MINUTES_FREQUENCY=\"$MINUTES_FREQUENCY\""
  echo "HOURLY_FREQUENCY=\"$HOURLY_FREQUENCY\""
  echo "DAILY_TIME=\"$DAILY_TIME\""
  echo "WEEKLY_DAY=\"$WEEKLY_DAY\""
  echo "WEEKLY_TIME=\"$WEEKLY_TIME\""
  echo "MONTHLY_DAY=\"$MONTHLY_DAY\""
  echo "MONTHLY_TIME=\"$MONTHLY_TIME\""
  echo "CUSTOM_CRON=\"$CUSTOM_CRON\""
  echo "CRON_EXPRESSION=\"$CRON_EXPRESSION\""
  echo "ENABLE_NOTIFICATIONS=\"$ENABLE_NOTIFICATIONS\""
  echo "WEBHOOK_URL=\"$WEBHOOK_URL\""
} > "$CONFIG"

echo '{"status":"ok"}'
exit 0