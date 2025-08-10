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

