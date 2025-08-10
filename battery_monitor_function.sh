#!/bin/bash
# battery_monitor_function.sh
# Minimal, adaptive battery saver that preserves your existing env + tools.

set -u
set -o pipefail

# ===== Load Private Config =====
CONFIG_FILE="$(dirname "$0")/.battery_monitor.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "ERROR: Config file $CONFIG_FILE not found." >&2
  exit 1
fi

# ===== Defaults (overridable in .battery_monitor.env) =====
LOGGER_TAG="${LOGGER_TAG:-battery_monitor}"
CHATGPT_FILE="${CHATGPT_FILE:-/home/we6jbo/Learn-Ivrit-Recordings/battery_reports/chatgpt.txt}"
STATUS_FILE="${STATUS_FILE:-/tmp/battery_status.txt}"
UPTIME_SCH="${UPTIME_SCH:-/tmp/uptime_scheduled.log}"
METRICS_CSV="${METRICS_CSV:-/home/we6jbo/Learn-Ivrit-Recordings/battery_reports/metrics.csv}"
VEGA_DIR="${VEGA_DIR:-/tmp/jul25}"

# Thresholds & cadence
LOW_BATT_THRESHOLD="${LOW_BATT_THRESHOLD:-30}"     # legacy behavior trigger
T90="${T90:-90}"   # start *very* light nudges below this when discharging
T70="${T70:-70}"
T50="${T50:-50}"
T30="${T30:-30}"   # heavy-handed begins below here

SAMPLE_SLEEP="${SAMPLE_SLEEP:-5}"      # how often battery_monitor.sh calls us
BACKOFF_SHORT="${BACKOFF_SHORT:-60}"   # cooldown after any intervention
BACKOFF_HEAVY="${BACKOFF_HEAVY:-300}"  # cooldown after aggressive interventions

# Kill policy knobs
TOP_N_MILD="${TOP_N_MILD:-5}"
TOP_N_MODERATE="${TOP_N_MODERATE:-10}"
TOP_N_AGGRESSIVE="${TOP_N_AGGRESSIVE:-15}"

# Safety: never kill these (prefix match on command)
SAFE_CMD_ALLOWLIST="${SAFE_CMD_ALLOWLIST:-/usr/bin/ssh /bin/login /sbin/init /usr/sbin/NetworkManager /usr/bin/Xorg /usr/bin/wayland /usr/bin/gnome-shell /usr/bin/kwin_x11 /usr/bin/kwin_wayland /usr/bin/sddm /usr/bin/lightdm /usr/bin/systemd /usr/bin/journalctl /usr/bin/loginctl /usr/bin/sudo /bin/bash /usr/bin/bash /usr/bin/zsh /usr/bin/fish}"

mkdir -p "$(dirname "$CHATGPT_FILE")" "$(dirname "$STATUS_FILE")" "$(dirname "$UPTIME_SCH")" "$(dirname "$METRICS_CSV")" "$VEGA_DIR"
touch "$CHATGPT_FILE" "$STATUS_FILE" "$UPTIME_SCH" "$METRICS_CSV"

log() { logger -t "$LOGGER_TAG" -- "$*"; }

append_today_once() {
  local today; today="$(date +%F)"
  grep -q "$today" "$CHATGPT_FILE" || echo "$today" >> "$CHATGPT_FILE"
}

# ---- Battery readers (use your existing stack: upower/acpi/sysfs) ----
detect_battery_sysfs() {
  local psdir="/sys/class/power_supply"
  local batdir; batdir="$(ls -d "$psdir"/BAT* 2>/dev/null | head -n1 || true)"
  local acdir;  acdir="$(ls -d "$psdir"/AC* "$psdir"/ADP* 2>/dev/null | head -n1 || true)"
  [[ -z "$batdir" ]] && { echo "" ""; return 1; }
  local cap state; cap="$(tr -d '%' < "$batdir/capacity" 2>/dev/null || echo 0)"
  state="$(cat "$batdir/status" 2>/dev/null || echo "")"
  if [[ -n "$acdir" && -f "$acdir/online" && "$(cat "$acdir/online" 2>/dev/null)" == "1" ]]; then
    state="Charging"
  fi
  echo "$cap" "$state"
}

read_battery() {
  if command -v upower >/dev/null 2>&1; then
    local dev; dev="$(upower -e 2>/dev/null | grep -E 'BAT|battery' | head -n1)"
    if [[ -n "$dev" ]]; then
      local pct state
      pct="$(upower -i "$dev" | awk -F: '/percentage/{gsub(/[% ]/,"",$2);print $2;exit}')"
      state="$(upower -i "$dev" | awk -F: '/state/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
      [[ -n "$pct" && -n "$state" ]] && { echo "$pct" "$state"; return 0; }
    fi
  fi
  if command -v acpi >/dev/null 2>&1; then
    local line pct state
    line="$(acpi -b 2>/dev/null | head -n1)"
    pct="$(echo "$line" | grep -oE '[0-9]+%' | tr -d '%')"
    state="$(echo "$line" | awk -F'[,: ]+' '{print $3}')"
    [[ -n "$pct" && -n "$state" ]] && { echo "$pct" "$state"; return 0; }
  fi
  detect_battery_sysfs
}

# ---- Process selection & kill logic ----
is_safe_cmd() {
  local cmd="$1"
  for safe in $SAFE_CMD_ALLOWLIST; do
    [[ "$cmd" == "$safe"* ]] && return 0
  done
  return 1
}

list_top_cmds() {
  local limit="$1"
  # unique command path list by CPU
  ps -eo cmd,%cpu --sort=-%cpu | awk 'NR<=50{print $1}' | sort | uniq | head -n "$limit"
}

graceful_then_bruteforce() {
  local cmd="$1" killed=0
  [[ -z "$cmd" ]] && return 0
  is_safe_cmd "$cmd" && return 0

  # Graceful TERM
  pkill -f -- "$cmd" 2>/dev/null && killed=1
  sleep 2
  # Escalate only if still present
  pgrep -f -- "$cmd" >/dev/null 2>&1 && pkill -9 -f -- "$cmd" 2>/dev/null && killed=2
  echo "$killed"
}

write_status_file() {
  local pct="$1" state="$2"
  {
    echo "=== Battery Status $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Battery: ${pct}%"
    echo "State:   ${state}"
    echo
    echo "Top power-consuming commands:"
    ps -eo cmd,%cpu --sort=-%cpu | awk 'NR<=25{printf("%-50s %s%%\n",$1,$2)}'
  } > "$STATUS_FILE"
}

# ---- Metrics logging ----
ensure_metrics_header() {
  if [[ ! -s "$METRICS_CSV" ]]; then
    echo "timestamp,battery_percent,state,policy_level,topN,killed_count,backoff_seconds" >> "$METRICS_CSV"
  fi
}

log_metrics() {
  local pct="$1" state="$2" level="$3" topn="$4" killed="$5" backoff="$6"
  ensure_metrics_header
  printf "%s,%s,%s,%s,%s,%s,%s\n" "$(date '+%F %T')" "$pct" "$state" "$level" "$topn" "$killed" "$backoff" >> "$METRICS_CSV"
}

# ---- Intervention policies (adaptive) ----
policy_nudge_mild() {
  # Close a few heavy hitters (gentle)
  local pct="$1" state="$2" killed=0
  mapfile -t cmds < <(list_top_cmds "$TOP_N_MILD")
  for c in "${cmds[@]}"; do
    r="$(graceful_then_bruteforce "$c")"
    (( killed += r ))
  done
  log "MILD intervention: killed=$killed (units 1=TERM,2=KILL)"
  log_metrics "$pct" "$state" "mild" "$TOP_N_MILD" "$killed" "$BACKOFF_SHORT"
  sleep "$BACKOFF_SHORT"
}

policy_nudge_moderate() {
  local pct="$1" state="$2" killed=0
  mapfile -t cmds < <(list_top_cmds "$TOP_N_MODERATE")
  for c in "${cmds[@]}"; do
    r="$(graceful_then_bruteforce "$c")"
    (( killed += r ))
  done
  log "MODERATE intervention: killed=$killed"
  log_metrics "$pct" "$state" "moderate" "$TOP_N_MODERATE" "$killed" "$BACKOFF_SHORT"
  sleep "$BACKOFF_SHORT"
}

policy_aggressive() {
  local pct="$1" state="$2" killed=0
  mapfile -t cmds < <(list_top_cmds "$TOP_N_AGGRESSIVE")
  for c in "${cmds[@]}"; do
    r="$(graceful_then_bruteforce "$c")"
    (( killed += r ))
  done
  echo "Computer up but battery low at $(date):" >> "$UPTIME_SCH"
  log "AGGRESSIVE intervention: killed=$killed"
  log_metrics "$pct" "$state" "aggressive" "$TOP_N_AGGRESSIVE" "$killed" "$BACKOFF_HEAVY"
  sleep "$BACKOFF_HEAVY"
}

# ---- Main control ----
main() {
  append_today_once

  local pct state
  read -r pct state < <(read_battery)
  [[ -z "${pct:-}" || -z "${state:-}" ]] && { log "WARN: Unable to read battery status."; write_status_file "N/A" "unknown"; return 0; }

  write_status_file "$pct" "$state"

  # Only act if discharging
  if [[ "$state" == "discharging" || "$state" == "Discharging" ]]; then
    if   (( pct < T30 )); then
      policy_aggressive "$pct" "$state"
    elif (( pct < T50 )); then
      policy_nudge_moderate "$pct" "$state"
    elif (( pct < T70 )); then
      policy_nudge_mild "$pct" "$state"
    elif (( pct < T90 )); then
      # Very light nudge or do nothing; choose mild with very small TOP_N if desired
      policy_nudge_mild "$pct" "$state"
    else
      # >= T90: no action; just observe
      :
    fi

    # Legacy behavior: ensure we still honor your original "below threshold" block
    if (( pct < LOW_BATT_THRESHOLD )); then
      log "Battery below ${LOW_BATT_THRESHOLD}% (legacy trigger)."
      # already handled by policies above; message kept for continuity
    fi
  else
    log "Battery OK: ${pct}% and state=${state}"
  fi
}

main "$@"

