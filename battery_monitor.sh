#!/bin/bash
# Battery monitoring script (external config version)

# ===== Load Private Config =====
CONFIG_FILE="$(dirname "$0")/.battery_monitor.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file $CONFIG_FILE not found."
    exit 1
fi


# ===== Vega Logging Setup =====
JUL25_DIR="/tmp/jul25"
mkdir -p "$JUL25_DIR"
CURRENT_HOUR=$(date +"%H")
MONITOR_FILE="${JUL25_DIR}/${CURRENT_HOUR}-battery-monitor.txt"
STATUS_FILE="${JUL25_DIR}/${CURRENT_HOUR}-status.txt"

# ===== Battery Functions =====
get_battery_info() {
    upower -i "$(upower -e | grep BAT)" 2>/dev/null
}

is_plugged_in() {
    get_battery_info | grep -q "state:\s*charging"
}

get_battery_percent() {
    get_battery_info | grep -oP 'percentage:\s*\K[0-9]+'
}

# ===== Logging =====
log_power_consumers()
{
        # Vega battery monitor writes
        echo "yes" > "$MONITOR_FILE"
        ps -eo pid,cmd,%cpu --sort=-%cpu | head -n 10 > "$STATUS_FILE"
    echo "Top power-consuming apps at $(date):" >> "$POWER_LOG"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 15 >> "$POWER_LOG"
    echo "----------------------------------------" >> "$POWER_LOG"
}

log_turn_off_candidates() {
    echo "Apps still running at $(date):" >> "$TURN_OFF_LOG"
    ps -eo pid,cmd,%cpu --sort=-%cpu | head -n 10 >> "$TURN_OFF_LOG"
    echo "----------------------------------------" >> "$TURN_OFF_LOG"
}

# ===== App Killers =====
try_ask_apps_to_close() {
    pkill -INT -f "$1"
}

force_close_apps() {
    pkill -9 -f "$1"
}

log_apps() {
    echo "Logging resource usage at $(date):" >> "$POWER_LOG"
    apps=(/usr/local/bin/ollama nessusd /usr/libexec/tracker-miner- /usr/bin/syncthing python3)
    for app in "${apps[@]}"; do
        pids=$(pgrep -f "$app")
        for pid in $pids; do
            ps -p "$pid" -o pid,cmd,%cpu,%mem >> "$POWER_LOG"
        done
    done
}

kill_apps_nicely() {
    apps=(/usr/local/bin/ollama nessusd /usr/libexec/tracker-miner- /usr/bin/syncthing python3)
    for app in "${apps[@]}"; do
        pkill -INT -f "$app"
    done
}

force_kill_apps() {
    apps=(/usr/local/bin/ollama nessusd /usr/libexec/tracker-miner- /usr/bin/syncthing python3)
    for app in "${apps[@]}"; do
        pkill -9 -f "$app"
    done
}

# ===== Main Logic =====
echo "Computer up at $(date):" >> "$UPTIME_SCH"
echo "Running..." >> /tmp/battery_monitor_runtime.log
battery=$(get_battery_percent)
plugged=$(is_plugged_in && echo "yes" || echo "no")

if [[ -z "$battery" || "$plugged" == "no" || "$battery" -lt 90 ]]; then
    logger -t battery_monitor "Battery check failed: plugged=$plugged, percent=$battery"
    confirm_with_user || {
        log_power_consumers
        # Vega battery monitor writes
        echo "yes" > "$MONITOR_FILE"
        ps -eo pid,cmd,%cpu --sort=-%cpu | head -n 10 > "$STATUS_FILE"
        while true; do
            battery=$(get_battery_percent)
            [[ -z "$battery" ]] && break
            [[ "$battery" -lt 80 ]] && break
            sleep 60
        done
        for app in $(ps -eo cmd --sort=-%cpu | head -n 15 | awk '{print $1}' | sort | uniq); do
            try_ask_apps_to_close "$app"
        done
        sleep 30
        log_turn_off_candidates
        while true; do
            battery=$(get_battery_percent)
            echo "Computer still up at $(date):" >> "$UPTIME_SCH"
            if [[ -z "$battery" ]]; then
                echo "Could not read battery. Apps still consuming power:" > "$ERROR_LOG"
                cat "$TURN_OFF_LOG" >> "$ERROR_LOG"
                logger -t battery_monitor "ERROR: Could not read battery level"
                exit 1
            fi
            if [[ "$battery" -lt 30 ]]; then
                echo "Computer up but battery low at $(date):" >> "$UPTIME_SCH"
                logger -t battery_monitor "Battery below 30%. Forcing high-CPU apps to close."
                for app in $(ps -eo cmd --sort=-%cpu | head -n 15 | awk '{print $1}' | sort | uniq); do
                    force_close_apps "$app"
                done
                break
            fi
            sleep 60
        done
    }
else
    logger -t battery_monitor "Battery OK: $battery% and plugged in"
fi

