#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${ROOT_DIR}/local-lab"
SCRIPTS_DIR="${ROOT_DIR}/tooling/scripts"
KEY_DIR="${LAB_DIR}/keys"
KEY_FILE="${KEY_DIR}/id_ed25519"
PUB_FILE="${KEY_FILE}.pub"
AUTH_KEYS="${KEY_DIR}/authorized_keys"

mkdir -p "$KEY_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" >/dev/null
fi
cp "$PUB_FILE" "$AUTH_KEYS"
chmod 600 "$KEY_FILE" "$AUTH_KEYS"

# Docker credential helper workaround for this environment.
FAKE_HELPER_DIR="/tmp/fakebin"
mkdir -p "$FAKE_HELPER_DIR"
cat > "${FAKE_HELPER_DIR}/docker-credential-desktop" <<'HELPER'
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
chmod +x "${FAKE_HELPER_DIR}/docker-credential-desktop"

DOCKER_PATH="PATH=${FAKE_HELPER_DIR}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "[1/5] Building and starting lab containers..."
env ${DOCKER_PATH} docker compose -f "${LAB_DIR}/docker-compose.yml" up -d --build

echo "[2/5] Waiting for SSH services..."
for port in 2221 2222 2223; do
  n=0
  until nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do
    n=$((n+1))
    if (( n > 30 )); then
      echo "Timeout waiting for port $port" >&2
      exit 1
    fi
    sleep 1
  done
done

echo "[3/5] Running orchestration smoke test..."
"${SCRIPTS_DIR}/orchestrate_migration_over_ssh.sh" \
  --mode both \
  --kamailio-host 127.0.0.1 \
  --kamailio-user root \
  --kamailio-ssh-port 2221 \
  --old-pbx-ip old-pbx.local \
  --new-pbx-ip new-pbx.local \
  --old-pbx-host 127.0.0.1 \
  --old-pbx-user root \
  --old-pbx-ssh-port 2222 \
  --new-pbx-host 127.0.0.1 \
  --new-pbx-user root \
  --new-pbx-ssh-port 2223 \
  --ssh-key "${KEY_FILE}" \
  --capture-snapshots \
  --confirm \
  --local-artifacts-dir "${LAB_DIR}/artifacts"

echo "[4/5] Verifying dispatcher file in kamailio..."
env ${DOCKER_PATH} docker compose -f "${LAB_DIR}/docker-compose.yml" exec -T kamailio cat /etc/kamailio/dispatcher.list

echo "[5/5] Smoke test complete."
echo "Artifacts: ${LAB_DIR}/artifacts"
echo "To stop lab: env ${DOCKER_PATH} docker compose -f ${LAB_DIR}/docker-compose.yml down -v"
