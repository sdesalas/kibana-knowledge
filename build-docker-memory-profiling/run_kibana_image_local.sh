#!/usr/bin/env bash
#
# Run the locally-built Kibana Wolfi Docker image with the Node.js inspector
# enabled, so you can attach Chrome DevTools / clinic.js / take heap snapshots
# for memory profiling.
#
# Usage:
#   ./run_kibana_image_local.sh
#   ./run_kibana_image_local.sh -e SOME_VAR=foo            # extra env vars
#   ELASTICSEARCH_HOSTS=http://es:9200 ./run_kibana_image_local.sh
#
# Any extra args are passed straight through to `docker run`, so you can append
# more `-e KEY=value` flags, `-v` mounts, etc. on the command line.
#
# Profiling
# ─────────
# Node inspector is bound to 0.0.0.0:9229 inside the container and exposed on
# host port 9229. To attach:
#   1. Open Chrome -> chrome://inspect
#   2. Click "Configure..." and ensure "localhost:9229" is listed
#   3. Kibana will appear under "Remote Target" — click "inspect"
#   4. Use the Memory tab to take heap snapshots / allocation timelines
#
# Heap dump on demand:
#   docker exec -it kibana-local kill -USR2 1     # writes a .heapsnapshot file
#   docker cp kibana-local:/usr/share/kibana/Heap-*.heapsnapshot ./
#
# Increase heap if profiling under load:
#   NODE_OPTIONS_EXTRA="--max-old-space-size=4096" ./run_kibana_image_local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

VERSION="$(jq -r '.version' package.json)-SNAPSHOT"
GIT_COMMIT="$(git rev-parse --short HEAD)"
KIBANA_IMAGE="${KIBANA_IMAGE:-docker.elastic.co/kibana/kibana-wolfi:$VERSION-$GIT_COMMIT}"
CONTAINER_NAME="${CONTAINER_NAME:-kibana-local-memory-profiling}"

# ── Ports ─────────────────────────────────────────────────────────────────────
# KIBANA_DEV_PORT  - host port that maps to Kibana's 5601 inside the container
# ES_DEV_PORT      - port used in the default ELASTICSEARCH_HOSTS URL below
# INSPECTOR_PORT   - host port for the Node.js inspector

KIBANA_DEV_PORT="${KIBANA_DEV_PORT:-5601}"
ES_DEV_PORT="${ES_DEV_PORT:-9200}"
INSPECTOR_PORT="${INSPECTOR_PORT:-9229}"

# ── Elasticsearch connection ──────────────────────────────────────────────────
# Kibana needs an Elasticsearch to talk to. By default we point at the host
# machine on $ES_DEV_PORT (works if you run ES on your laptop). Override with
# the ELASTICSEARCH_HOSTS env var when invoking this script.
#
# Common setups:
#   - ES on host (mac/linux):  http://host.docker.internal:$ES_DEV_PORT
#   - ES in another container: http://<container-name>:9200 (use --network)
#   - Elastic Cloud:           https://<deployment-id>.es.<region>.gcp.cloud.es.io:443

ELASTICSEARCH_HOSTS="${ELASTICSEARCH_HOSTS:-http://host.docker.internal:${ES_DEV_PORT}}"

# ── Elasticsearch credentials ─────────────────────────────────────────────────
# Kibana must authenticate to ES. Defaults to the kibana_system user with the
# `yarn es snapshot` default password. Reset with:
#   bin/elasticsearch-reset-password -u kibana_system
#
# If your ES is HTTPS with a self-signed cert, leave verification mode as none.

ELASTICSEARCH_USERNAME="${ELASTICSEARCH_USERNAME:-kibana_system}"
ELASTICSEARCH_PASSWORD="${ELASTICSEARCH_PASSWORD:-changeme}"
ELASTICSEARCH_SSL_VERIFICATIONMODE="${ELASTICSEARCH_SSL_VERIFICATIONMODE:-none}"

# ── Encrypted Saved Objects keys ──────────────────────────────────────────────
# Fleet, Actions, Reporting, Alerting and others persist sensitive fields as
# encrypted saved objects. Without a stable key, Kibana generates an ephemeral
# one each boot, which causes Fleet to refuse to bootstrap and logs warnings.
#
# Resolution order for each key (first non-empty wins):
#   1. The plugin-specific env var (XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY,
#      XPACK_SECURITY_ENCRYPTIONKEY, XPACK_REPORTING_ENCRYPTIONKEY)
#   2. KBN_ENCRYPTION_KEY — a single override that seeds ALL three keys
#   3. A freshly generated random 32-char hex key (default)
#
# Examples:
#   KBN_ENCRYPTION_KEY=$(openssl rand -hex 16) ./run_kibana_image_local.sh
#   XPACK_REPORTING_ENCRYPTIONKEY=mycustomkey... ./run_kibana_image_local.sh

gen_key() { openssl rand -hex 16; }

XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY="${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY:-${KBN_ENCRYPTION_KEY:-$(gen_key)}}"
XPACK_SECURITY_ENCRYPTIONKEY="${XPACK_SECURITY_ENCRYPTIONKEY:-${KBN_ENCRYPTION_KEY:-$(gen_key)}}"
XPACK_REPORTING_ENCRYPTIONKEY="${XPACK_REPORTING_ENCRYPTIONKEY:-${KBN_ENCRYPTION_KEY:-$(gen_key)}}"

# ── Node.js options for memory profiling ──────────────────────────────────────
# --inspect=0.0.0.0:9229 enables the inspector on all interfaces inside the
# container so it's reachable from the host on localhost:$INSPECTOR_PORT.
# Append your own flags via NODE_OPTIONS_EXTRA.

NODE_OPTIONS="--inspect=0.0.0.0:9229 --max-old-space-size=800 ${NODE_OPTIONS_EXTRA:-}"

# ── Environment variables ─────────────────────────────────────────────────────

ENV_VARS=(
  -e "NODE_OPTIONS=$NODE_OPTIONS"
  -e "ELASTICSEARCH_HOSTS=$ELASTICSEARCH_HOSTS"
  -e "ELASTICSEARCH_USERNAME=$ELASTICSEARCH_USERNAME"
  -e "ELASTICSEARCH_PASSWORD=$ELASTICSEARCH_PASSWORD"
  -e "ELASTICSEARCH_SSL_VERIFICATIONMODE=$ELASTICSEARCH_SSL_VERIFICATIONMODE"
  -e "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=$XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY"
  -e "XPACK_SECURITY_ENCRYPTIONKEY=$XPACK_SECURITY_ENCRYPTIONKEY"
  -e "XPACK_REPORTING_ENCRYPTIONKEY=$XPACK_REPORTING_ENCRYPTIONKEY"
  -e SERVER_HOST=0.0.0.0
  -e KBN_MEM_PROFILE=1
)

# ── Run ───────────────────────────────────────────────────────────────────────

# Names of vars whose values should be redacted in the printed banner.
SENSITIVE_VAR_PATTERN='(PASSWORD|ENCRYPTIONKEY|TOKEN|SECRET|APIKEY)'

echo "==> Image          : $KIBANA_IMAGE"
echo "==> Container name : $CONTAINER_NAME"
echo "==> Kibana UI      : http://localhost:$KIBANA_DEV_PORT"
echo "==> Node inspector : ws://localhost:$INSPECTOR_PORT  (chrome://inspect)"
echo "==> Env vars:"
# ENV_VARS alternates "-e" and "KEY=VALUE"; iterate the value entries only.
for ((i = 1; i < ${#ENV_VARS[@]}; i += 2)); do
  entry="${ENV_VARS[$i]}"
  key="${entry%%=*}"
  value="${entry#*=}"
  if [[ "$key" =~ $SENSITIVE_VAR_PATTERN ]]; then
    # Show first 8 chars then mask the rest, so you can still tell two runs apart.
    masked="${value:0:8}$(printf '%*s' $((${#value} - 8)) '' | tr ' ' '*')"
    printf '      %-45s = %s\n' "$key" "$masked"
  else
    printf '      %-45s = %s\n' "$key" "$value"
  fi
done
echo ""

# Remove any previous run with the same name so re-runs are idempotent.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

exec docker run --rm -it \
  --name "$CONTAINER_NAME" \
  -p "$KIBANA_DEV_PORT:5601" \
  -p "$INSPECTOR_PORT:9229" \
  --add-host=host.docker.internal:host-gateway \
  "${ENV_VARS[@]}" \
  "$@" \
  "$KIBANA_IMAGE"
