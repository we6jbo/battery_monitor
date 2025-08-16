#!/bin/bash
# battery_monitor_function.sh — v1.0.0
# - NEVER kills Chrome.
# - Detects real drain (smoothed %/min OR high watts) when battery <= threshold.
# - Signals a local relay (http://127.0.0.1:8165) used by the Chrome extension.
# - Logs CSV + journald.
# - Between 2025-08-19 and 2025-08-24 (inclusive start, exclusive end), writes
#   a health breadcrumb to chatgpt.txt so you can paste it to ChatGPT.

set -Eeuo pipefail

VERSION="1.0.0"

# -------- Paths --------
BASE_DIR="/home/we6jbo/Learn-Ivrit-Recordings/battery_reports"
METRICS="${BASE_DIR}/metrics.csv"
CHATGPT_FILE="${BASE_DIR}/chatgpt.txt"

# Local relay for the extension
RELAY_HOST="127.0.0.1"
RELAY_PORT="8165"

# -------- Tunables --------
LOW_TRIM_PCT=15           # (optional; disabled below) trim non-browser hogs when idle
MIN_PCT_FOR_SIGNAL=25     # only signal the extension at/under this %
DRAIN_SEVERE=3            # smoothed %/min threshold to signal
MIN_WINDOW_SECS=90        # smoothing window for %/min calculation
BIG_WATTS=12              # >= watts also considered "big drain"
IDLE_LIMIT_MS=60000       # "active" if input < 60s ago
COOLDOWN_SECS=180         # min gap between identical signals

# State files
STATE_DIR="/tmp"
DROP_ANCHOR="${STATE_DIR}/j03_batt_anchor.json"   # {"pct":X,"ts":epoch}
COOLDOWN_FILE="${STATE_DIR}/j03_signal_cooldown.ts"

# -------- Time-window gate for chatgpt.txt breadcrumbs --------
_status_gate_ok() {
  local now_ts start_ts end_ts
  now_ts="$(date +%s)"
  start_ts="$(date -d '2025-08-19 00:00:00' +%s)"
  end_ts="$(date -d '2025-08-25 00:00:00' +%s)"   # exclusive
  [ "$now_ts" -ge "$start_ts" ] && [ "$now_ts" -lt "$end_ts" ]
}

# -------- Idle detection (service-safe) --------
is_user_active() {
  if command -v xprintidle >/dev/null 2>&1 && env | grep -q '^DISPLAY='; then
    local ms; ms="$(xprintidle 2>/dev/null || echo 999999)"
    [ "$ms" -lt "$IDLE_LIMIT_MS" ] && return 0 || return 1
  fi
  if command -v loginctl >/dev/null 2>&1; then
    local hint
    hint="$(loginctl show-user "${SUDO_USER:-$USER}" 2>/dev/null | awk -F= '/^IdleHint=/{print $2}')"
    [ "$hint" = "no" ] && return 0 || return 1
  fi
  # Unknown => treat as idle (safer for battery conservation)
  return 1
}

# -------- Battery / power helpers --------
battery_pct() {
  upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null \
    | awk '/percentage/ {gsub("%",""); print $2; exit}'
}

battery_state() {
  upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null \
    | awk '/state/ {print $2; exit}'
}

battery_watts() {
  # Returns integer watts (floor). If unavailable, 0.
  local w
  w="$(upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null | awk '/energy-rate/ {print $2; exit}')"
  printf '%s\n' "${w%.*:-0}"
}

smoothed_drop_rate() {
  # Compute %/min using an anchor at least MIN_WINDOW_SECS old
  local pct_now ts_now pct_prev ts_prev dt dp rate
  pct_now="$1"; ts_now="$(date +%s)"

  if [ -s "$DROP_ANCHOR" ]; then
    pct_prev="$(awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"pct"/){print $(i+1)}}}' "$DROP_ANCHOR" | tr -d ' ')"
    ts_prev="$(awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"ts"/){print $(i+1)}}}' "$DROP_ANCHOR" | tr -d ' ')"
    if [[ "$pct_prev" =~ ^[0-9]+$ ]] && [[ "$ts_prev" =~ ^[0-9]+$ ]]; then
      dt=$(( ts_now - ts_prev ))
      if [ "$dt" -ge "$MIN_WINDOW_SECS" ]; then
        dp=$(( pct_prev - pct_now ))
        rate=$(( dp > 0 ? dp * 60 / dt : 0 ))
        printf '{"pct":%s,"ts":%s}\n' "$pct_now" "$ts_now" > "$DROP_ANCHOR" 2>/dev/null || true
        echo "$rate"; return 0
      fi
      echo "0"; return 0
    fi
  fi
  printf '{"pct":%s,"ts":%s}\n' "$pct_now" "$(date +%s)" > "$DROP_ANCHOR" 2>/dev/null || true
  echo "0"
}

# -------- Optional: light hygiene at very low battery (non-browser only) --------
kill_noncritical() {
  # Disabled by default; comment-in the call in "Main" to enable.
  # Avoid browsers; TERM top 5 CPU hogs >35%
  local p pid cmd
  while read -r p; do
    pid="${p%%:*}"; cmd="${p#*:}"
    [[ "$cmd" =~ chrome|chromium|firefox ]] && continue
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
  done < <(ps -eo pid,comm,%cpu --sort=-%cpu | awk '$3>35 {print $1":"$2}' | head -n 5)
}

# -------- Cooldown --------
cooldown_active() {
  local now ts
  now="$(date +%s)"
  if [ -s "$COOLDOWN_FILE" ]; then
    ts="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
    [ $(( now - ts )) -lt "$COOLDOWN_SECS" ] && return 0
  fi
  return 1
}
start_cooldown() { date +%s > "$COOLDOWN_FILE" 2>/dev/null || true; }

# -------- Signaling (to relay) --------
emit_signal() {
  # Best-effort POST to relay; extension will pick this up and prompt the user.
  command -v curl >/dev/null 2>&1 && \
    curl -m 0.8 -s -o /dev/null -X POST -H "Content-Type: application/json" \
      --data "{\"ts\":\"$(date '+%F %T')\",\"action\":\"terminate-chrome\",\"reason\":\"$1\",\"battery_pct\":$2,\"drop_per_min\":$3,\"watts\":$4,\"idle\":$5,\"function_version\":\"$VERSION\"}" \
      "http://${RELAY_HOST}:${RELAY_PORT}/signal" || true
}

clear_signal() {
  command -v curl >/dev/null 2>&1 && \
    curl -m 0.8 -s -o /dev/null -X POST "http://${RELAY_HOST}:${RELAY_PORT}/clear" || true
}

# -------- CSV/Journald logging --------
log_metrics() {
  local tier="$1" pct="$2" drop="$3" watts="$4" reason="$5" idle_ms="$6" action="$7"
  mkdir -p "$BASE_DIR"
  if [ ! -f "$METRICS" ]; then
    printf 'timestamp,tier,pct,drop_per_min,watts,reason,idle_ms,action,version\n' > "$METRICS"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%F %T')" "$tier" "$pct" "$drop" "$watts" "$reason" "$idle_ms" "$action" "$VERSION" >> "$METRICS"
  logger -t battery_monitor "tier=${tier} pct=${pct} drop=${drop}/min watts=${watts} reason=${reason} idle_ms=${idle_ms} action=${action} version=${VERSION}" || true
}

# -------- Health breadcrumb to chatgpt.txt (time-boxed) --------
status_note_function() {
  local stamp="/tmp/j03_health_fn_last.ts" now
  now="$(date +%s)"
  if [ -f "$stamp" ] && [ $(( now - $(cat "$stamp" 2>/dev/null || echo 0) )) -lt 60 ]; then return 0; fi
  echo "$now" > "$stamp" 2>/dev/null || true
  printf '%s\tbattery_function v%s\tstate=%s pct=%s drop=%s/min watts=%s idle=%s action=%s reason=%s\n' \
    "$(date '+%F %T')" "$VERSION" "$state" "$pct" "$drop_rate" "$watts" "$idle" "$action" "$reason" >> "$CHATGPT_FILE"
}

# ===========================
# Main decision logic
# ===========================
pct="$(battery_pct || echo 100)"
state="$(battery_state || echo unknown)"
watts="$(battery_watts || echo 0)"
drop_rate="$(smoothed_drop_rate "$pct")"   # %/min over >=90s window

idle=1; is_user_active && idle=0
idle_ms="-1"
if command -v xprintidle >/dev/null 2>&1 && env | grep -q '^DISPLAY='; then
  idle_ms="$(xprintidle 2>/dev/null || echo -1)"
fi

tier="OK"; reason="normal"; action="none"

if [ "$state" = "discharging" ]; then
  # Optional low-battery hygiene (keeps Chrome safe)
  # if [ "$pct" -le "$LOW_TRIM_PCT" ] && [ "$idle" -eq 1 ]; then
  #   kill_noncritical
  #   tier="LOW_TRIM"; reason="pct<=${LOW_TRIM_PCT}% trimmed non-browsers"; action="TERM_noncritical"
  # fi

  # Only consider signaling the extension when battery is actually low
  if [ "$pct" -le "$MIN_PCT_FOR_SIGNAL" ]; then
    # "Real" big drain if smoothed %/min OR watts exceed thresholds
    if [ "$drop_rate" -ge "$DRAIN_SEVERE" ] || [ "$watts" -ge "$BIG_WATTS" ]; then
      if cooldown_active; then
        tier="COOLDOWN"; reason="cooldown_active skip_signal"; action="none"
      else
        tier="DRAIN_SEVERE"
        reason="smoothed>=${DRAIN_SEVERE}%/min OR watts>=${BIG_WATTS}"
        emit_signal "$reason" "$pct" "$drop_rate" "$watts" "$idle"
        action="SIGNAL_extension"
        start_cooldown
      fi
    else
      # Drain below threshold at low pct -> clear any prior signal
      clear_signal
      tier="LOW_OK"; reason="low_pct_but_normal_drain"
    fi
  else
    # Battery above threshold -> clear any prior signal
    clear_signal
  fi
else
  # Charging/unknown -> clear signals
  clear_signal
  tier="CHARGING_OR_UNKNOWN"; reason="$state"
fi

log_metrics "$tier" "$pct" "$drop_rate" "$watts" "$reason" "$idle_ms" "$action"

# Time-boxed breadcrumb for ChatGPT (Aug 19–24, 2025)
if _status_gate_ok; then status_note_function; fi

