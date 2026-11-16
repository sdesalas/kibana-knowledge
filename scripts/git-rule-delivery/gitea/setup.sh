#!/usr/bin/env bash
# Runs a local Gitea with HTTPS (self-signed cert) on 3443 and SSH on 2222, and registers an
# ed25519 key for its admin user. The detection-rules copy is added separately (see the README).
# Needs docker, openssl, ssh-keygen and curl. Safe to re-run: existing pieces are kept.
set -euo pipefail

CERT_DIR="${CERT_DIR:-$HOME/.ssh/gitea-poc}"
NAME=gitea-poc
PORT=3443
SSH_PORT=2222
OWNER=poc
SOURCE_REPO=https://github.com/elastic/detection-rules.git
BASE="https://localhost:$PORT"

if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
  echo "Missing $CERT_DIR/cert.pem or key.pem" >&2
  exit 1
fi

[ -f "$CERT_DIR/admin_password" ] || (umask 077 && openssl rand -hex 16 > "$CERT_DIR/admin_password")
PASSWORD="$(cat "$CERT_DIR/admin_password")"

[ -f "$CERT_DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C gitea-poc -f "$CERT_DIR/id_ed25519"

# Recreated on every run so setting changes apply; repos and users live in the data volume.
docker rm -f "$NAME" > /dev/null 2>&1 || true

docker run -d --name "$NAME" \
    -p "127.0.0.1:$PORT:$PORT" \
    -p "127.0.0.1:$SSH_PORT:22" \
    -v "$NAME-data:/data" \
    -v "$CERT_DIR:/certs:ro" \
    -e GITEA__security__INSTALL_LOCK=true \
    -e GITEA__server__PROTOCOL=https \
    -e GITEA__server__DOMAIN=localhost \
    -e GITEA__server__HTTP_PORT="$PORT" \
    -e GITEA__server__ROOT_URL="$BASE/" \
    -e GITEA__server__CERT_FILE=/certs/cert.pem \
    -e GITEA__server__KEY_FILE=/certs/key.pem \
    -e GITEA__server__DISABLE_SSH=false \
    -e GITEA__server__SSH_DOMAIN=localhost \
    -e GITEA__server__SSH_PORT="$SSH_PORT" \
    gitea/gitea:latest > /dev/null

echo "Waiting for Gitea..."
for _ in $(seq 1 60); do
  curl -sf --cacert "$CERT_DIR/cert.pem" "$BASE/api/healthz" > /dev/null && break
  sleep 2
done
curl -sf --cacert "$CERT_DIR/cert.pem" "$BASE/api/healthz" > /dev/null || { docker logs --tail 30 "$NAME"; exit 1; }

docker exec -u git "$NAME" gitea admin user create --admin --username "$OWNER" \
  --password "$PASSWORD" --email "$OWNER@example.com" --must-change-password=false 2>&1 \
  | grep -v 'already exists' || true

curl -s -o /dev/null --cacert "$CERT_DIR/cert.pem" -u "$OWNER:$PASSWORD" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"gitea-poc\",\"key\":\"$(cat "$CERT_DIR/id_ed25519.pub")\"}" \
  "$BASE/api/v1/user/keys" || true

if curl -sf --cacert "$CERT_DIR/cert.pem" "$BASE/api/v1/repos/$OWNER/detection-rules" > /dev/null; then
  echo "Repo $OWNER/detection-rules exists."
else
  echo "No $OWNER/detection-rules repo yet. Either copy it from GitHub:"
  echo "  curl --cacert $CERT_DIR/cert.pem -u $OWNER:\$(cat $CERT_DIR/admin_password) -H 'Content-Type: application/json' \\"
  echo "    -d '{\"clone_addr\":\"$SOURCE_REPO\",\"service\":\"git\",\"repo_name\":\"detection-rules\",\"repo_owner\":\"$OWNER\"}' $BASE/api/v1/repos/migrate"
  echo "or create an empty one and push main from a local clone (see the README)."
fi

echo "HTTPS: --repo $BASE/$OWNER/detection-rules --ca $CERT_DIR/cert.pem"
echo "SSH:   --repo ssh://git@localhost:$SSH_PORT/$OWNER/detection-rules.git --ssh-key $CERT_DIR/id_ed25519 --known-hosts $CERT_DIR/known_hosts --accept-new-host"
