#!/bin/bash
# Minimal monitor loop: append today's date once per day to chatgpt.txt
# and continuously run battery_monitor_function.sh

set -u  # treat unset vars as errors

FILE="/home/we6jbo/Learn-Ivrit-Recordings/battery_reports/chatgpt.txt"
FUNC="/home/we6jbo/battery_monitor/battery_monitor_function.sh"
SLEEP_SECS=5

# Make sure the target file exists
mkdir -p "$(dirname "$FILE")"
touch "$FILE"

# Function: append today's date if not present
check_and_append_date() {
    local today
    today="$(date +%F)"  # YYYY-MM-DD
    if ! grep -q "$today" "$FILE"; then
        echo "$today" >> "$FILE"
    fi
}
# ---- Health breadcrumb (Aug 19–24, 2025 only) ----
CHATGPT_FILE="/home/we6jbo/Learn-Ivrit-Recordings/battery_reports/chatgpt.txt"
_status_gate_ok() {
  local now_ts start_ts end_ts
  now_ts="$(date +%s)"
  start_ts="$(date -d '2025-08-19 00:00:00' +%s)"
  end_ts="$(date -d '2025-08-25 00:00:00' +%s)"
  [ "$now_ts" -ge "$start_ts" ] && [ "$now_ts" -lt "$end_ts" ]
}
status_note_runner() {
  local stamp="/tmp/j03_health_runner_last.ts" now
  now="$(date +%s)"
  if [ -f "$stamp" ] && [ $(( now - $(cat "$stamp" 2>/dev/null || echo 0) )) -lt 60 ]; then return 0; fi
  echo "$now" > "$stamp" 2>/dev/null || true
  printf '%s\tbattery_runner\tpid=%s loop_ok sleep=%ss func=%s\n' \
    "$(date '+%F %T')" "$$" "$SLEEP_SECS" "$FUNC" >> "$CHATGPT_FILE"
}

# Main loop
while true; do
    check_and_append_date

    if [[ -x "$FUNC" ]]; then
        "$FUNC"
    else
        echo "WARN: $FUNC not found or not executable; retrying..." >&2
        # optional: try to set executable bit if file exists
        [[ -f "$FUNC" ]] && chmod +x "$FUNC" 2>/dev/null || true
        sleep 30
        continue
    fi

    sleep "$SLEEP_SECS"
done

