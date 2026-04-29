#!/usr/bin/env bash
# Runs a Jest integration test N times and tracks pass/fail rate.
# Progress is persisted to /tmp/flaky-runs/summary.txt after every run,
# so partial results survive if the script (or your shell) dies.

N=${N:-100}
TEST_PATH=${TEST_PATH:-x-pack/platform/packages/shared/kbn-change-history/integration_tests/client.test.ts}
OUT_DIR=${OUT_DIR:-/tmp/flaky-runs}

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: > "$SUMMARY"

PASS=0
FAIL=0
FAILED_RUNS=()
START_TS=$(date +%s)

printf "Running %s\n  test:   %s\n  iters:  %d\n  output: %s\n\n" \
  "$(date)" "$TEST_PATH" "$N" "$OUT_DIR" | tee -a "$SUMMARY"

for i in $(seq 1 "$N"); do
  RUN_START=$(date +%s)
  if node scripts/jest_integration "$TEST_PATH" \
       > "$OUT_DIR/run-$i.log" 2>&1; then
    PASS=$((PASS + 1))
    STATUS="PASS"
  else
    FAIL=$((FAIL + 1))
    FAILED_RUNS+=("$i")
    STATUS="FAIL"
  fi

  DONE=$((PASS + FAIL))
  NOW=$(date +%s)
  RUN_SECS=$((NOW - RUN_START))
  ELAPSED=$((NOW - START_TS))
  AVG=$((ELAPSED / DONE))
  REMAINING=$(( (N - DONE) * AVG ))
  PASS_PCT=$(awk "BEGIN{printf \"%.1f\", $PASS*100/$DONE}")
  FAIL_PCT=$(awk "BEGIN{printf \"%.1f\", $FAIL*100/$DONE}")
  ETA=$(date -v+"${REMAINING}"S +"%H:%M:%S" 2>/dev/null || date -d "+${REMAINING} seconds" +"%H:%M:%S")

  LINE=$(printf "[%3d/%d] %s in %3ds | pass=%d (%s%%) fail=%d (%s%%) | elapsed=%ds eta=%s" \
    "$i" "$N" "$STATUS" "$RUN_SECS" "$PASS" "$PASS_PCT" "$FAIL" "$FAIL_PCT" "$ELAPSED" "$ETA")
  echo "$LINE" | tee -a "$SUMMARY"
done

echo | tee -a "$SUMMARY"
echo "Pass: $PASS / $N" | tee -a "$SUMMARY"
echo "Fail: $FAIL / $N  ($(awk "BEGIN{printf \"%.1f\", $FAIL*100/$N}")% flaky)" | tee -a "$SUMMARY"
echo "Failed runs: ${FAILED_RUNS[*]}" | tee -a "$SUMMARY"
