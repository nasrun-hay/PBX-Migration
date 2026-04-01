#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_DIR="${ROOT_DIR}/local-lab/real-services"
SIM_SCRIPT="${LAB_DIR}/run_call_cutover_sim.sh"

DASH_INTERVAL_SECONDS="${DASH_INTERVAL_SECONDS:-1}"
DASH_NO_CLEAR="${DASH_NO_CLEAR:-0}"
ART_DIR="${ART_DIR_OVERRIDE:-${LAB_DIR}/artifacts/call-cutover-$(date +%Y%m%d_%H%M%S)}"
CSV_FILE="${ART_DIR}/live-metrics.csv"
SIM_LOG_FILE="${ART_DIR}/simulation.stdout.log"
PHASE_FILE="${ART_DIR}/current_phase.txt"
STATUS_FILE="${ART_DIR}/status.txt"

DOCKER_PATH="PATH=/tmp/fakebin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p /tmp/fakebin
cat > /tmp/fakebin/docker-credential-desktop <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  get)
    echo '{"Username":"","Secret":""}'
    ;;
  list)
    echo '{}'
    ;;
  store|erase)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
HELPER
chmod +x /tmp/fakebin/docker-credential-desktop

mkdir -p "$ART_DIR"

safe_int() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo 0
  fi
}

count_invites() {
  local container="$1"
  local logfile="$2"
  local n
  n="$(env ${DOCKER_PATH} docker exec "$container" /bin/sh -c "grep -c '^INVITE ' '$logfile' 2>/dev/null || true" 2>/dev/null || true)"
  safe_int "$n"
}

infer_dispatcher_mode() {
  env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c '
    if [ ! -f /etc/kamailio/dispatcher.list ]; then
      echo unknown
      exit 0
    fi
    old=0
    new=0
    grep -q "sipp-uas-old:5060" /etc/kamailio/dispatcher.list && old=1
    grep -q "sipp-uas-new:5060" /etc/kamailio/dispatcher.list && new=1
    if [ "$old" -eq 1 ] && [ "$new" -eq 1 ]; then
      echo both
    elif [ "$old" -eq 1 ]; then
      echo old
    elif [ "$new" -eq 1 ]; then
      echo new
    else
      echo empty
    fi
  ' 2>/dev/null || echo n/a
}

bar() {
  local val="$1"
  local scaled=$((val / 2))
  local max=40
  local width=0
  local i
  local out=""

  if (( val > 0 && scaled == 0 )); then
    scaled=1
  fi
  if (( scaled > max )); then
    width=$max
  else
    width=$scaled
  fi

  for ((i=0; i<width; i++)); do
    out+="#"
  done

  printf '%s' "$out"
}

render() {
  local phase="$1"
  local status="$2"
  local disp="$3"
  local old_total="$4"
  local new_total="$5"
  local old_delta="$6"
  local new_delta="$7"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  if [[ "$DASH_NO_CLEAR" != "1" ]]; then
    clear
  fi

  printf 'PBX Migration Call Cutover Live Dashboard\n'
  printf 'Time: %s\n' "$ts"
  printf 'Run Dir: %s\n' "$ART_DIR"
  printf 'Phase: %s\n' "$phase"
  printf 'Status: %s\n' "$status"
  printf 'Dispatcher Mode: %s\n\n' "$disp"

  printf 'Backend INVITE Totals\n'
  printf 'OLD: %6s | %-40s\n' "$old_total" "$(bar "$old_total")"
  printf 'NEW: %6s | %-40s\n\n' "$new_total" "$(bar "$new_total")"

  printf 'Delta (last %ss): OLD +%s | NEW +%s\n\n' "$DASH_INTERVAL_SECONDS" "$old_delta" "$new_delta"
  printf 'Simulation Log: %s\n' "$SIM_LOG_FILE"
  printf 'Timeline CSV:   %s\n' "$CSV_FILE"
}

echo 'timestamp,phase,status,dispatcher_mode,old_total,new_total,old_delta,new_delta' > "$CSV_FILE"

ART_DIR_OVERRIDE="$ART_DIR" "$SIM_SCRIPT" > "$SIM_LOG_FILE" 2>&1 &
SIM_PID=$!

prev_old=0
prev_new=0

while kill -0 "$SIM_PID" 2>/dev/null; do
  phase="$(cat "$PHASE_FILE" 2>/dev/null || echo starting)"
  status="$(cat "$STATUS_FILE" 2>/dev/null || echo running)"

  old_total="$(count_invites real-sipp-uas-old /tmp/old_messages.log)"
  new_total="$(count_invites real-sipp-uas-new /tmp/new_messages.log)"
  dispatcher_mode="$(infer_dispatcher_mode)"

  old_delta=$((old_total - prev_old))
  new_delta=$((new_total - prev_new))

  render "$phase" "$status" "$dispatcher_mode" "$old_total" "$new_total" "$old_delta" "$new_delta"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$phase" "$status" "$dispatcher_mode" "$old_total" "$new_total" "$old_delta" "$new_delta" >> "$CSV_FILE"

  prev_old="$old_total"
  prev_new="$new_total"

  sleep "$DASH_INTERVAL_SECONDS"
done

set +e
wait "$SIM_PID"
SIM_RC=$?
set -e

phase="$(cat "$PHASE_FILE" 2>/dev/null || echo done)"
status="$(cat "$STATUS_FILE" 2>/dev/null || echo finished)"
old_total="$(count_invites real-sipp-uas-old /tmp/old_messages.log)"
new_total="$(count_invites real-sipp-uas-new /tmp/new_messages.log)"
dispatcher_mode="$(infer_dispatcher_mode)"

old_delta=$((old_total - prev_old))
new_delta=$((new_total - prev_new))
render "$phase" "$status" "$dispatcher_mode" "$old_total" "$new_total" "$old_delta" "$new_delta"
printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$phase" "$status" "$dispatcher_mode" "$old_total" "$new_total" "$old_delta" "$new_delta" >> "$CSV_FILE"

if (( SIM_RC != 0 )); then
  echo
  echo "Simulation failed (exit ${SIM_RC}). Recent log output:"
  tail -n 40 "$SIM_LOG_FILE" || true
  exit "$SIM_RC"
fi

echo
echo "Simulation completed successfully."
echo "Artifacts: ${ART_DIR}"
