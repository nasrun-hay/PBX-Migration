#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_DIR="${ROOT_DIR}/local-lab/real-services"
COMPOSE_BASE="${LAB_DIR}/docker-compose.real.yml"
COMPOSE_CALLS="${LAB_DIR}/docker-compose.calls.yml"
SCRIPTS_DIR="${ROOT_DIR}/tooling/scripts"
ART_DIR="${ART_DIR_OVERRIDE:-${LAB_DIR}/artifacts/call-cutover-$(date +%Y%m%d_%H%M%S)}"
PHASE_FILE=""
STATUS_FILE=""

CALLS_PER_PHASE="${CALLS_PER_PHASE:-10}"
CALL_RATE="${CALL_RATE:-5}"
CALL_DURATION_MS="${CALL_DURATION_MS:-1200}"
LONG_CALL_MS="${LONG_CALL_MS:-25000}"
POST_CUTOVER_CALLS="${POST_CUTOVER_CALLS:-8}"
PHASE_GAP_SECONDS="${PHASE_GAP_SECONDS:-35}"

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
PHASE_FILE="${ART_DIR}/current_phase.txt"
STATUS_FILE="${ART_DIR}/status.txt"

set_phase() {
  printf '%s\n' "$1" > "$PHASE_FILE"
}

set_status() {
  printf '%s\n' "$1" > "$STATUS_FILE"
}

set_status "running"
set_phase "init"
trap 'set_status "failed"' ERR

dc() {
  env ${DOCKER_PATH} docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_CALLS" "$@"
}

wait_for_kamailio() {
  for i in {1..45}; do
    if env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c 'kamcmd -s unix:/run/kamailio/kamailio_ctl core.uptime >/dev/null 2>&1'; then
      return 0
    fi
    sleep 1
  done
  echo "Kamailio control socket not ready" >&2
  return 1
}

wait_for_uas() {
  for svc in real-sipp-uas-old real-sipp-uas-new; do
    for i in {1..30}; do
      if [[ "$(env ${DOCKER_PATH} docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null || echo false)" == "true" ]]; then
        break
      fi
      if (( i == 30 )); then
        echo "SIPp UAS not ready: ${svc}" >&2
        env ${DOCKER_PATH} docker logs "$svc" 2>&1 | tail -n 40 >&2 || true
        return 1
      fi
      sleep 1
    done
  done
}

apply_profile() {
  local mode="$1"
  local profile="${ART_DIR}/dispatcher.${mode}.list"

  "${SCRIPTS_DIR}/build_dispatcher_list.sh" \
    --mode "$mode" \
    --old "sip:sipp-uas-old:5060" \
    --new "sip:sipp-uas-new:5060" \
    --output "$profile"

  env ${DOCKER_PATH} docker cp "$profile" "real-kamailio:/tmp/pbx-migration/dispatcher.${mode}.list"
  env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c "cp -f /tmp/pbx-migration/dispatcher.${mode}.list /etc/kamailio/dispatcher.list"

  local reloaded=0
  for _ in {1..8}; do
    if env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c "kamcmd -s unix:/run/kamailio/kamailio_ctl dispatcher.reload >/dev/null 2>&1"; then
      reloaded=1
      break
    fi
    sleep 1
  done

  if (( reloaded == 0 )); then
    echo "Failed to reload dispatcher for mode=${mode}" >&2
    return 1
  fi

  env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c 'cat /etc/kamailio/dispatcher.list' > "${ART_DIR}/applied-${mode}.list"
}

run_short_calls() {
  local label="$1"
  local count="$2"
  local called_user="$3"

  if ! dc run --rm --no-deps sipp-uac "sipp -sn uac real-kamailio:5060 -s ${called_user} -m ${count} -r ${CALL_RATE} -d ${CALL_DURATION_MS} -trace_err" \
    > "${ART_DIR}/${label}.uac.log" 2>&1; then
    # SIPp can return non-zero for partial call failures; assertions still validate backend routing.
    echo "Warning: SIPp returned non-zero for phase '${label}'. Continuing; inspect ${ART_DIR}/${label}.uac.log" >&2
  fi
}

capture_kam_logs_since() {
  local label="$1"
  local since_ts="$2"
  env ${DOCKER_PATH} docker logs --since "$since_ts" real-kamailio > "${ART_DIR}/${label}.kamailio.log" 2>&1 || true
}

capture_uas_invite_totals() {
  local label="$1"
  local old_log="${ART_DIR}/${label}.uas-old.messages.log"
  local new_log="${ART_DIR}/${label}.uas-new.messages.log"

  env ${DOCKER_PATH} docker exec real-sipp-uas-old /bin/sh -c 'cat /tmp/old_messages.log 2>/dev/null || true' > "$old_log"
  env ${DOCKER_PATH} docker exec real-sipp-uas-new /bin/sh -c 'cat /tmp/new_messages.log 2>/dev/null || true' > "$new_log"

  local old_total new_total
  old_total="$(grep -c '^INVITE ' "$old_log" || true)"
  new_total="$(grep -c '^INVITE ' "$new_log" || true)"

  echo "${old_total:-0} ${new_total:-0}"
}

assert_phase_deltas() {
  local phase="$1"
  local expected_calls="$2"
  local prev_old="$3"
  local prev_new="$4"
  local curr_old="$5"
  local curr_new="$6"

  local delta_old=$((curr_old - prev_old))
  local delta_new=$((curr_new - prev_new))

  {
    echo "phase=${phase}"
    echo "expected_calls=${expected_calls}"
    echo "prev_old_total=${prev_old}"
    echo "prev_new_total=${prev_new}"
    echo "curr_old_total=${curr_old}"
    echo "curr_new_total=${curr_new}"
    echo "delta_old=${delta_old}"
    echo "delta_new=${delta_new}"
  } > "${ART_DIR}/${phase}.assertions.txt"

  case "$phase" in
    old)
      if (( delta_old < expected_calls )); then
        echo "Phase old failed: expected at least ${expected_calls} old backend INVITEs, got ${delta_old}" >&2
        return 1
      fi
      if (( delta_new != 0 )); then
        echo "Phase old failed: expected 0 new backend INVITEs, got ${delta_new}" >&2
        return 1
      fi
      ;;
    both)
      if (( delta_old < 1 || delta_new < 1 )); then
        echo "Phase both failed: expected INVITEs on both backends, got old=${delta_old} new=${delta_new}" >&2
        return 1
      fi
      ;;
    new)
      if (( delta_new < expected_calls )); then
        echo "Phase new failed: expected at least ${expected_calls} new backend INVITEs, got ${delta_new}" >&2
        return 1
      fi
      if (( delta_old != 0 )); then
        echo "Phase new failed: expected 0 old backend INVITEs, got ${delta_old}" >&2
        return 1
      fi
      ;;
    *)
      echo "Unknown phase: ${phase}" >&2
      return 1
      ;;
  esac
}

echo "[1/7] Starting real-services lab + SIP call simulators..."
set_phase "stack-start"
dc up -d --build

echo "[2/7] Waiting for Kamailio and SIP endpoints..."
set_phase "wait-ready"
wait_for_kamailio
wait_for_uas

read old_total new_total < <(capture_uas_invite_totals baseline)

echo "[3/7] Old-phase call routing check..."
set_phase "old"
apply_profile old
phase_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_short_calls old "$CALLS_PER_PHASE" "1000"
capture_kam_logs_since old "$phase_start"
read next_old next_new < <(capture_uas_invite_totals old)
assert_phase_deltas old "$CALLS_PER_PHASE" "$old_total" "$new_total" "$next_old" "$next_new"
old_total="$next_old"
new_total="$next_new"

echo "Cooling down ${PHASE_GAP_SECONDS}s before both-phase to avoid transaction-id reuse artifacts..."
set_phase "cooldown-before-both"
sleep "$PHASE_GAP_SECONDS"

echo "[4/7] Both-phase call routing check..."
set_phase "both"
apply_profile both
phase_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_short_calls both "$CALLS_PER_PHASE" "2000"
capture_kam_logs_since both "$phase_start"
read next_old next_new < <(capture_uas_invite_totals both)
assert_phase_deltas both "$CALLS_PER_PHASE" "$old_total" "$new_total" "$next_old" "$next_new"
old_total="$next_old"
new_total="$next_new"

echo "Cooling down ${PHASE_GAP_SECONDS}s before new-phase to avoid transaction-id reuse artifacts..."
set_phase "cooldown-before-new"
sleep "$PHASE_GAP_SECONDS"

echo "[5/7] New-phase call routing check..."
set_phase "new"
apply_profile new
phase_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_short_calls new "$CALLS_PER_PHASE" "3000"
capture_kam_logs_since new "$phase_start"
read next_old next_new < <(capture_uas_invite_totals new)
assert_phase_deltas new "$CALLS_PER_PHASE" "$old_total" "$new_total" "$next_old" "$next_new"
old_total="$next_old"
new_total="$next_new"

echo "Cooling down ${PHASE_GAP_SECONDS}s before in-flight check to avoid transaction-id reuse artifacts..."
set_phase "cooldown-before-inflight"
sleep "$PHASE_GAP_SECONDS"

echo "[6/7] In-flight cutover behavior check (long call survives cutover)..."
set_phase "inflight"
apply_profile old
sleep 2
inflight_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
read inflight_old_base inflight_new_base < <(capture_uas_invite_totals inflight-pre)

run_short_calls inflight-precutover 1 "4100"
read inflight_old_ready inflight_new_ready < <(capture_uas_invite_totals inflight-ready)

if (( inflight_old_ready - inflight_old_base < 1 )); then
  echo "In-flight test failed: old-mode precheck did not reach old backend" >&2
  exit 1
fi
if (( inflight_new_ready - inflight_new_base != 0 )); then
  echo "In-flight test failed: old-mode precheck unexpectedly reached new backend" >&2
  exit 1
fi

dc run --rm --no-deps sipp-uac "sipp -sn uac real-kamailio:5060 -s 4000 -m 1 -r 1 -d ${LONG_CALL_MS} -trace_err" > "${ART_DIR}/inflight-long.uac.log" 2>&1 &
long_pid=$!

sleep 2
inflight_old_mid="$inflight_old_ready"
inflight_new_mid="$inflight_new_ready"

cutover_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
apply_profile new
run_short_calls inflight-post-cutover "$POST_CUTOVER_CALLS" "5000"

if ! wait "$long_pid"; then
  echo "In-flight test failed: long call did not complete successfully" >&2
  exit 1
fi

capture_kam_logs_since inflight-total "$inflight_start"
capture_kam_logs_since inflight-post-cutover "$cutover_ts"
read inflight_old_final inflight_new_final < <(capture_uas_invite_totals inflight-final)

post_old_delta=$((inflight_old_final - inflight_old_mid))
post_new_delta=$((inflight_new_final - inflight_new_mid))

{
  echo "inflight_old_base=${inflight_old_base}"
  echo "inflight_new_base=${inflight_new_base}"
  echo "inflight_old_mid=${inflight_old_mid}"
  echo "inflight_new_mid=${inflight_new_mid}"
  echo "inflight_old_final=${inflight_old_final}"
  echo "inflight_new_final=${inflight_new_final}"
  echo "post_cutover_old_delta=${post_old_delta}"
  echo "post_cutover_new_delta=${post_new_delta}"
} > "${ART_DIR}/inflight.assertions.txt"

if (( post_new_delta < POST_CUTOVER_CALLS )); then
  echo "In-flight test failed: expected at least ${POST_CUTOVER_CALLS} new-backend INVITEs after cutover, got ${post_new_delta}" >&2
  exit 1
fi
if (( post_old_delta != 0 )); then
  echo "In-flight test failed: observed old-backend INVITEs after cutover (${post_old_delta})" >&2
  exit 1
fi

echo "[7/7] Call cutover simulation succeeded."
set_phase "done"
set_status "success"
echo "Artifacts: ${ART_DIR}"
echo "Lab still running for inspection."
echo "Stop with: env ${DOCKER_PATH} docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_CALLS} down -v"
