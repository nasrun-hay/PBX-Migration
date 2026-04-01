#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_DIR="${ROOT_DIR}/local-lab/real-services"
COMPOSE_FILE="${LAB_DIR}/docker-compose.real.yml"
SCRIPTS_DIR="${ROOT_DIR}/tooling/scripts"
ART_DIR="${LAB_DIR}/artifacts/run-$(date +%Y%m%d_%H%M%S)"

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

echo "[1/8] Starting real-services lab..."
env ${DOCKER_PATH} docker compose -f "$COMPOSE_FILE" up -d --build

echo "[2/8] Waiting for kamcmd readiness..."
for i in {1..30}; do
  if env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c 'kamcmd -s unix:/run/kamailio/kamailio_ctl core.uptime >/dev/null 2>&1'; then
    break
  fi
  if (( i == 30 )); then
    echo "Kamailio control socket not ready" >&2
    exit 1
  fi
  sleep 1
done

echo "[3/8] Confirming old/new versions differ..."
FS_OLD_VER="$(env ${DOCKER_PATH} docker exec real-fs-old /bin/sh -lc 'freeswitch -version 2>/dev/null | head -n 1' || true)"
FS_NEW_VER="$(env ${DOCKER_PATH} docker exec real-fs-new /bin/sh -lc 'freeswitch -version 2>/dev/null | head -n 1' || true)"
FPBX_OLD_TAG="$(env ${DOCKER_PATH} docker exec real-fusionpbx-old cat /opt/fusionpbx-tag)"
FPBX_NEW_TAG="$(env ${DOCKER_PATH} docker exec real-fusionpbx-new cat /opt/fusionpbx-tag)"

if [[ -z "$FS_OLD_VER" || -z "$FS_NEW_VER" ]]; then
  echo "FreeSWITCH version detection failed" >&2
  exit 1
fi
if [[ "$FS_OLD_VER" == "$FS_NEW_VER" ]]; then
  echo "FreeSWITCH versions are identical" >&2
  exit 1
fi
if [[ "$FPBX_OLD_TAG" == "$FPBX_NEW_TAG" ]]; then
  echo "FusionPBX tags are identical" >&2
  exit 1
fi

echo "FreeSWITCH old: $FS_OLD_VER"
echo "FreeSWITCH new: $FS_NEW_VER"
echo "FusionPBX old: $FPBX_OLD_TAG"
echo "FusionPBX new: $FPBX_NEW_TAG"

echo "[4/8] Building dispatcher profiles (old, both, new)..."
"${SCRIPTS_DIR}/build_dispatcher_list.sh" --mode old  --old "sip:freeswitch-old:5060" --new "sip:freeswitch-new:5060" --output "${ART_DIR}/dispatcher.old.list"
"${SCRIPTS_DIR}/build_dispatcher_list.sh" --mode both --old "sip:freeswitch-old:5060" --new "sip:freeswitch-new:5060" --output "${ART_DIR}/dispatcher.both.list"
"${SCRIPTS_DIR}/build_dispatcher_list.sh" --mode new  --old "sip:freeswitch-old:5060" --new "sip:freeswitch-new:5060" --output "${ART_DIR}/dispatcher.new.list"

apply_profile() {
  local profile_file="$1"
  local phase="$2"

  echo "[5/8-${phase}] Applying profile ${profile_file}..."
  env ${DOCKER_PATH} docker cp "$profile_file" real-kamailio:/tmp/pbx-migration/profile.list
  env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -c '\
    mkdir -p /var/backups/kamailio-dispatcher && \
    if [ -f /etc/kamailio/dispatcher.list ]; then \
      cp -a /etc/kamailio/dispatcher.list /var/backups/kamailio-dispatcher/dispatcher.list.$(date +%Y%m%d_%H%M%S).bak; \
    fi && \
    cp -f /tmp/pbx-migration/profile.list /etc/kamailio/dispatcher.list && \
    kamcmd -s unix:/run/kamailio/kamailio_ctl dispatcher.reload \
  '

  env ${DOCKER_PATH} docker exec real-kamailio /bin/sh -lc 'cat /etc/kamailio/dispatcher.list' > "${ART_DIR}/applied-${phase}.list"
}

apply_profile "${ART_DIR}/dispatcher.old.list" "old"
apply_profile "${ART_DIR}/dispatcher.both.list" "both"
apply_profile "${ART_DIR}/dispatcher.new.list" "new"

echo "[6/8] Verifying final dispatcher state..."
if ! grep -q 'freeswitch-new:5060' "${ART_DIR}/applied-new.list"; then
  echo "Final dispatcher does not include new PBX" >&2
  exit 1
fi
if grep -q 'freeswitch-old:5060' "${ART_DIR}/applied-new.list"; then
  echo "Final dispatcher still includes old PBX (expected new-only mode)" >&2
  exit 1
fi

echo "[7/8] Capturing kamcmd dispatcher output..."
env ${DOCKER_PATH} docker exec real-kamailio kamcmd dispatcher.list > "${ART_DIR}/kamcmd-dispatcher.list.txt" 2>&1 || true

echo "[8/8] Migration smoke complete."
echo "Artifacts: ${ART_DIR}"
echo "Lab still running for inspection."
echo "Stop with: env ${DOCKER_PATH} docker compose -f ${COMPOSE_FILE} down -v"
