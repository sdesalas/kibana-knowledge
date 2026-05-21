#!/usr/bin/env bash
#
# Capture Kibana <-> Elasticsearch traffic during an FTR run.
#
# What this script does:
#   1. Clears the FTR Elasticsearch logs dir (.es/cluster-ftr/logs).
#   2. Starts mitmproxy as a child reverse-proxy on :9221 -> https://localhost:9220,
#      dumping every flow to a HAR file.
#   3. Starts the FTR server (functional_tests_server) with --config $1,
#      redirecting all stdout/stderr to fts.log.
#   4. On Ctrl+C (or when the FTR server exits), shuts both children down cleanly,
#      then copies HAR + ES logs + FTR log into ./captures/<timestamp>/.
#
# Assumes:
#   - Run from the root of a Kibana checkout.
#   - mitmproxy installed (>= 10): `brew install mitmproxy`.
#   - The FTR config under $1 sets `--elasticsearch.hosts=http://localhost:9221`
#     so Kibana routes through the proxy. (See
#     .knowledge/operations/capture_ftr_es_traffic_har.md.)
#
# Usage:
#   .knowledge/scripts/capture-ftr-es-har.sh <path/to/ftr.config.ts>

set -u
set -o pipefail

CONFIG="${1:-}"
if [[ -z "$CONFIG" ]]; then
  echo "Usage: $0 <path/to/ftr.config.ts>" >&2
  exit 2
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "FTR config not found: $CONFIG" >&2
  exit 2
fi

if ! command -v mitmdump >/dev/null 2>&1; then
  echo "mitmdump not found. Install with: brew install mitmproxy" >&2
  exit 2
fi

ES_LOGS_DIR=".es/cluster-ftr/logs"
PROXY_PORT="${PROXY_PORT:-9221}"
ES_PORT="${ES_PORT:-9220}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CAPTURE_DIR="captures/${TIMESTAMP}"
HAR_FILE="${CAPTURE_DIR}/es-traffic.har"
FTS_LOG="${CAPTURE_DIR}/fts.log"
MITM_LOG="${CAPTURE_DIR}/mitmdump.log"

mkdir -p "$CAPTURE_DIR"
echo "[capture] Output will be archived in: $CAPTURE_DIR"

MITM_PID=""
FTS_PID=""
IDLE_PID=""
CLEANED_UP=0

cleanup() {
  # Guard against running twice (trap + normal exit path).
  if [[ "$CLEANED_UP" -eq 1 ]]; then
    return
  fi
  CLEANED_UP=1

  echo
  echo "[capture] Shutting down…"

  if [[ -n "$IDLE_PID" ]] && kill -0 "$IDLE_PID" 2>/dev/null; then
    kill -TERM "$IDLE_PID" 2>/dev/null || true
  fi

  if [[ -n "$FTS_PID" ]] && kill -0 "$FTS_PID" 2>/dev/null; then
    echo "[capture] Stopping FTR server (pid $FTS_PID)…"
    kill -INT "$FTS_PID" 2>/dev/null || true
    # Give it time to clean up Kibana + ES gracefully.
    for _ in $(seq 1 60); do
      kill -0 "$FTS_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$FTS_PID" 2>/dev/null; then
      echo "[capture] FTR server still alive, sending SIGTERM…"
      kill -TERM "$FTS_PID" 2>/dev/null || true
      sleep 5
    fi
    if kill -0 "$FTS_PID" 2>/dev/null; then
      echo "[capture] Force killing FTR server…"
      kill -KILL "$FTS_PID" 2>/dev/null || true
    fi
  fi

  if [[ -n "$MITM_PID" ]] && kill -0 "$MITM_PID" 2>/dev/null; then
    # SIGINT lets mitmdump flush the HAR cleanly. SIGKILL would lose it.
    echo "[capture] Stopping mitmdump (pid $MITM_PID)…"
    kill -INT "$MITM_PID" 2>/dev/null || true
    for _ in $(seq 1 15); do
      kill -0 "$MITM_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$MITM_PID" 2>/dev/null; then
      echo "[capture] mitmdump still alive, sending SIGTERM…"
      kill -TERM "$MITM_PID" 2>/dev/null || true
    fi
  fi

  # Copy logs into the timestamped directory.
  if [[ -d "$ES_LOGS_DIR" ]]; then
    echo "[capture] Archiving ES logs from $ES_LOGS_DIR …"
    mkdir -p "$CAPTURE_DIR/es-logs"
    cp -R "$ES_LOGS_DIR/." "$CAPTURE_DIR/es-logs/" 2>/dev/null || true
  fi

  echo "[capture] Done. Files in $CAPTURE_DIR:"
  ls -lh "$CAPTURE_DIR" 2>/dev/null || true
  if [[ -d "$CAPTURE_DIR/es-logs" ]]; then
    echo "[capture] ES logs:"
    ls -lh "$CAPTURE_DIR/es-logs" 2>/dev/null || true
  fi
}

trap cleanup INT TERM EXIT

# 1. Clear previous ES logs so the capture is clean.
if [[ -d "$ES_LOGS_DIR" ]]; then
  echo "[capture] Clearing existing ES logs in $ES_LOGS_DIR …"
  rm -f "$ES_LOGS_DIR"/* 2>/dev/null || true
else
  echo "[capture] $ES_LOGS_DIR does not exist yet — it will be created when ES starts."
fi

# 2. Start mitmproxy reverse proxy with HAR dump. ES is HTTPS with a self-signed
#    cert, so we need --ssl-insecure on the upstream leg.
echo "[capture] Starting mitmdump on :$PROXY_PORT -> https://localhost:$ES_PORT …"
mitmdump \
  --mode "reverse:https://localhost:${ES_PORT}" \
  --listen-port "$PROXY_PORT" \
  --ssl-insecure \
  --set hardump="$HAR_FILE" \
  --set flow_detail=1 \
  >"$MITM_LOG" 2>&1 &
MITM_PID=$!
echo "[capture] mitmdump pid=$MITM_PID (log: $MITM_LOG, har: $HAR_FILE)"

# Wait for mitmproxy to actually be listening before bringing Kibana up.
for _ in $(seq 1 30); do
  if lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$MITM_PID" 2>/dev/null; then
    echo "[capture] mitmdump exited before binding to :$PROXY_PORT. See $MITM_LOG" >&2
    exit 1
  fi
  sleep 1
done

# 3. Start the FTR server. All Kibana/ES stdout goes to FTS_LOG.
#    Note: the FTR CLI does not accept --allow-root, so the container must
#    run as a non-root user (see .knowledge/scripts/ci-runner.Dockerfile).
if [[ "$(id -u)" -eq 0 ]]; then
  echo "[capture] WARNING: running as uid 0 (root). The FTR server will refuse" >&2
  echo "[capture] to start. Rebuild ci-runner.Dockerfile and run as the 'kibana'" >&2
  echo "[capture] user (USER kibana is baked into the image)." >&2
fi
echo "[capture] Starting functional_tests_server with config: $CONFIG"
echo "[capture] FTR output -> $FTS_LOG"
node scripts/functional_tests_server --config "$CONFIG" >"$FTS_LOG" 2>&1 &
FTS_PID=$!
echo "[capture] functional_tests_server pid=$FTS_PID"

echo
echo "[capture] Ready. Run your tests in another terminal, e.g.:"
echo "  node scripts/functional_test_runner --config $CONFIG"
echo
echo "[capture] Press Ctrl+C to stop and archive everything to $CAPTURE_DIR."

# 4. Wait until the FTR server exits or we are interrupted.
#    `wait` is interruptible by the INT/TERM traps above, so Ctrl+C still
#    triggers cleanup and a clean mitmproxy shutdown.
wait "$FTS_PID"
EXIT_CODE=$?

echo "[capture] FTR server exited with code $EXIT_CODE."

if [[ $EXIT_CODE -ne 0 ]]; then
  echo "[capture] ---- last 60 lines of $FTS_LOG ----"
  tail -n 60 "$FTS_LOG" 2>/dev/null || true
  echo "[capture] ------------------------------------"
  echo "[capture] mitmproxy is still running so the HAR captures any in-flight"
  echo "[capture] requests. Inspect $FTS_LOG / $MITM_LOG, then press Ctrl+C to"
  echo "[capture] shut down cleanly and archive everything to $CAPTURE_DIR."
  # Idle indefinitely. `tail -f /dev/null` is portable across GNU and BSD;
  # `wait $!` is interruptible by the INT/TERM traps.
  tail -f /dev/null &
  IDLE_PID=$!
  wait "$IDLE_PID"
  EXIT_CODE=$?
fi

exit "$EXIT_CODE"
