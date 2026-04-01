#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${ROOT_DIR}/real-services"
COMPOSE_FILE="${LAB_DIR}/docker-compose.real.yml"
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

echo "[1/4] Starting real-services lab..."
env ${DOCKER_PATH} docker compose -f "$COMPOSE_FILE" up -d --build

echo "[2/4] Capturing version information..."
FS_OLD_VER="$(env ${DOCKER_PATH} docker exec real-fs-old /bin/sh -lc 'freeswitch -version 2>/dev/null | head -n 1' || true)"
FS_NEW_VER="$(env ${DOCKER_PATH} docker exec real-fs-new /bin/sh -lc 'freeswitch -version 2>/dev/null | head -n 1' || true)"
FPBX_OLD_TAG="$(env ${DOCKER_PATH} docker exec real-fusionpbx-old cat /opt/fusionpbx-tag)"
FPBX_NEW_TAG="$(env ${DOCKER_PATH} docker exec real-fusionpbx-new cat /opt/fusionpbx-tag)"
FPBX_OLD_COMMIT="$(env ${DOCKER_PATH} docker exec real-fusionpbx-old cat /opt/fusionpbx-commit | cut -c1-12)"
FPBX_NEW_COMMIT="$(env ${DOCKER_PATH} docker exec real-fusionpbx-new cat /opt/fusionpbx-commit | cut -c1-12)"

echo "FreeSWITCH old: ${FS_OLD_VER}"
echo "FreeSWITCH new: ${FS_NEW_VER}"
echo "FusionPBX old tag: ${FPBX_OLD_TAG} (commit ${FPBX_OLD_COMMIT})"
echo "FusionPBX new tag: ${FPBX_NEW_TAG} (commit ${FPBX_NEW_COMMIT})"

echo "[3/4] Validating version differences..."
if [[ -z "$FS_OLD_VER" || -z "$FS_NEW_VER" ]]; then
  echo "Failed to detect one or both FreeSWITCH versions." >&2
  exit 1
fi
if [[ "$FS_OLD_VER" == "$FS_NEW_VER" ]]; then
  echo "FreeSWITCH versions are identical; expected different old/new versions." >&2
  exit 1
fi
if [[ "$FPBX_OLD_TAG" == "$FPBX_NEW_TAG" ]]; then
  echo "FusionPBX tags are identical; expected different old/new versions." >&2
  exit 1
fi
if [[ "$FPBX_OLD_COMMIT" == "$FPBX_NEW_COMMIT" ]]; then
  echo "FusionPBX commits are identical; expected different old/new versions." >&2
  exit 1
fi

echo "[4/4] Basic HTTP checks..."
OLD_HTTP="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080 || true)"
NEW_HTTP="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18081 || true)"
echo "FusionPBX old HTTP status: ${OLD_HTTP}"
echo "FusionPBX new HTTP status: ${NEW_HTTP}"

echo "SUCCESS: real-services lab is running with different old/new FusionPBX and FreeSWITCH versions."
echo "To stop: env ${DOCKER_PATH} docker compose -f ${COMPOSE_FILE} down -v"
