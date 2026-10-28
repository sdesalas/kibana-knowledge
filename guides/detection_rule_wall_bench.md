# Agent runbook: full detection-rule wall bench (main-only ECH)

Self-contained. An agent with this file under `.knowledge/guides/` can **deploy (or reuse) an ECH Kibana, run all 14 scenarios, and write `SUMMARY.md`** without chat history or other docs.

Do **not** invent credentials. Do **not** commit `.env.sh`, passwords, or `env.*.sh`.

Shell against ECH / QAF / monitoring ES: request Cursor tool permission **`all`** (sandbox blocks cloud).

---

## Goal

1. Live ECH Kibana on plan `sdesalas3_security_oom_testing` at a known `kibana-cloud` SHA.
2. Point `.env.sh` at that host; sanity-check UP.
3. Create a stamp dir; write `run_bench.sh` (template below); launch **keep-alive**.
4. Driver: wipe → Branch **A → B → wipe → C**; emit `timings.tsv`, `windows.tsv`, `logs/`, `DONE.txt`.
5. Write self-contained `SUMMARY.md` (wall clock required; APM only if asked).

Expect ~15–25+ minutes wall for main-only.

---

## Layout (paths relative to this guide)

This file lives at `.knowledge/guides/detection_rule_wall_bench.md`. Everything else hangs off `.knowledge/` via `../…`:

```bash
# Resolve from this guide's directory
GUIDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"   # …/.knowledge/guides
# Or when pasting by hand:
# GUIDE_DIR="$(cd /path/to/.knowledge/guides && pwd)"

SCRIPTS="$GUIDE_DIR/../scripts/bulk-primitives"
DATA="$GUIDE_DIR/../data/rules-import"
NOTIFY="$GUIDE_DIR/../skills/notify-when-done/scripts/notify.sh"
APM_SCRIPTS="$GUIDE_DIR/../skills/apm-investigation/scripts"
QAF_SKILL="$GUIDE_DIR/../skills/qaf/SKILL.md"
BENCH_ROOT="$GUIDE_DIR/../benchmarks"
```

| What | Relative to this guide |
|---|---|
| Targets (secret) | `../scripts/bulk-primitives/.env.sh` |
| Sample (no secrets) | `../scripts/bulk-primitives/sample.env.sh` |
| Drivers | `../scripts/bulk-primitives/parallel_*.sh`, `check_instances.sh` |
| Fixtures | `../data/rules-import/*.ndjson` |
| Notify | `../skills/notify-when-done/scripts/notify.sh` |
| APM scripts | `../skills/apm-investigation/scripts/` |
| QAF skill (create/list/describe/image pick) | `../skills/qaf/SKILL.md` |
| Stamp dirs (local only — **not** git) | `../benchmarks/<UTC>.full-bench-main-<shortsha>/` |
| Publish (git — only this tree is tracked) | `../benchmarks/published/<same-stamp>/` |
| APM ES creds | `~/config/apm.creds` (**`*.es.*`**, not `*.apm.*` intake) |
| QAF plan | `~/.qaf/config/cloud_plans/sdesalas3_security_oom_testing.yml` |

`.gitignore`: `benchmarks/*` with `!benchmarks/published/` — raw stamp dirs (`timings`, `logs`, `env.*.sh`, driver) stay local; copy SUMMARY/images into `published/` when the user asks to check them in.

Requires on PATH: `bash`, `curl`, `jq`, `uuidgen`, `qaf` (for create/list/describe), `docker` (manifest inspect), optional `gh`.

---

## Scenarios (ids) — what we measure

| # | Scenario | Related PRs |
|---|---|---|
| 1 | Import → Create 1,000 disabled rules. | 🔴 #275695 |
| 2 | Import → Create 1,000 enabled rules. | 🔴 #275695, 🟠 #290306 |
| 3 | Enable 1,000 existing disabled rules. | 🟤 #291560, 🟠 #290306 |
| 4 | Edit 1,000 enabled rules (add tag). | 🟤 #291560, 🟠 #290306 |
| 5 | Import → Fully update 1,000 enabled rules. | 🟤 #291560, 🟠 #290306 |
| 6 | Import → Update 1 of 1,000 (999 unchanged). | 🟤 #291560, 🟠 #290306, 🟡 #293948 |
| 7 | Disable 1,000 enabled rules. | 🟤 #291560, 🟠 #290306 |
| 8 | Delete 1,000 rules (no gaps). | 🔵 #287065 |
| 9 | Import → Create 1,000 enabled + 1 connector. | 🔴 #275695, 🟠 #290306 |
| 10 | Import → Create 1,000 + 20 shared exception lists (50 items each). | 🔴 #275695, 🟠 #290306 |
| 11 | Import → Update +1 shared list (to 21; 50 items each). | 🟤 #291560, 🟠 #290306 |
| 12 | Import → Update +1 connector (actions only). | 🟤 #291560, 🟠 #290306 |
| 13 | Delete 1,000 rules with gaps. | 🔵 #287065 |
| 14 | Delete 21 shared exception lists (`TYPE=detection`). | 🟢 #285608 |

### PRs (short)

| Color | PR | Endpoint / effect |
|---|---|---|
| 🔴 | #275695 | `_import` create → `bulkCreateRules()` |
| 🟤 | #291560 | overwrite → `bulkUpdateRules()`; batches enable/disable |
| 🟠 | #290306 | `refresh=false` on bulk API-key grants |
| 🟡 | #293948 | skip unchanged rules on overwrite |
| 🔵 | #287065 | gap cleanup via `_update_by_query` on delete |
| 🟢 | #285608 | `POST /internal/api/exception_lists/_bulk_action` |

### Endpoints

| Endpoint | Scenarios |
|---|---|
| `POST /api/detection_engine/rules/_import` | 1–2, 5–6, 9–12 |
| `POST /api/detection_engine/rules/_bulk_action` | 3–4, 7–8, 13 |
| `POST /internal/api/exception_lists/_bulk_action` | 14 |

Every import uses query flags (baked into `parallel_import_rules.sh`):
`overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true`.

**Fixtures used (must exist under `../data/rules-import/`):**

- `1000disabled-rules.ndjson`
- `1000enabled-rules.ndjson`
- `1000enabled-rules.all-updated.ndjson`
- `1000enabled-rules.1-updated.ndjson`
- `1000enabled.rules+connector-email-smtp.ndjson`
- `1000enabled.rules+2connectors-email-smtp-cases.ndjson`
- `1000enabled.rules+20exceptionlists.ndjson` ← **20**, not 30
- `1000enabled.rules+21exceptionlists.ndjson` ← **21**, not 31

C1/C2: each shared list has **50 items** (IPs `10.{list}.0.{item}`). C2 is a strict list-superset of C1.

---

## Prerequisites — tell the user

Wall clock works without APM. **But any later APM investigation does not.** Before creating (or reusing) a deploy, **say this out loud to the user** and wait if anything is missing — same spirit as `../skills/apm-investigation/SKILL.md` (it will stop and ask for `~/config/apm.creds` when you dig).

### 1. Monitoring cluster

- A live **monitoring** Elastic Cloud deployment must exist (APM server + ES that stores traces).
- The agent does **not** create or rotate that cluster. If the user has never set one up, stop and ask them to.
- Query creds for digs: `~/config/apm.creds` → monitoring **ES** URL (`*.es.*`), user, password. Missing / still `change-me` → tell them to fill it in (APM skill does the same). Never invent passwords.

### 2. Bench ECH plan must ship APM → that cluster

New Kibana instances only emit traces if the **QAF plan** injects `elastic.apm.*` in Kibana `user_settings_yaml`. Reference plan: `sdesalas3_security_oom_testing` → `~/.qaf/config/cloud_plans/sdesalas3_security_oom_testing.yml` (see `../skills/qaf/SKILL.md` § Cloud plans and APM).

Before `qaf … create`, tell the user to confirm (or confirm with them):

- Plan on disk still points `elastic.apm.serverUrl` + `secretToken` at the **current** monitoring APM (host/token can go stale).
- `elastic.apm.environment: {{ deployment_name }}` so digs filter by deploy name.
- Prefer `elastic.apm.transactionMaxSpans: 10000` (or higher) for import-heavy benches.
- Also required for this bench: `xpack.siem.maxRuleImportPayloadBytes: 26214400` (25 MiB).

Without a wired plan you still get a healthy ECH Kibana — you just get **no traces**, and APM digs will come up empty.

### 3. Cloud / Vault auth (user)

Vault OIDC + `~/.elastic/cloud.json` are the user’s job. Do not invent Cloud API keys.

Suggested one-liner to the user before first create:

> Need your monitoring cluster still up, `~/config/apm.creds` filled for its ES, and plan `sdesalas3_security_oom_testing` APM block still pointing at that cluster — OK to proceed, or want to fix those first?

---

## 0. Deploy Kibana (or reuse)

### Plan knobs (required)

Plan: `sdesalas3_security_oom_testing` (`gcp-us-west2`, production, no SSO, no autoscaling). Kibana `user_settings_yaml` must include the APM + import knobs from **Prerequisites** above.

Full create/list/describe/image-pick recipe: `../skills/qaf/SKILL.md` (optional extra notes: `qaf_ech_deployments.md` in this folder).

### Pick a published `kibana-cloud` image (latest unified SNAPSHOT)

```bash
SNAP=$(curl -sS https://artifacts-api.elastic.co/v1/versions \
  | jq -r '.versions[] | select(endswith("-SNAPSHOT"))' | tail -1)
BUILD=$(curl -sS "https://artifacts-api.elastic.co/v1/versions/${SNAP}/builds" \
  | jq -r '.builds[0]')
SHA=$(curl -sS "https://artifacts-api.elastic.co/v1/versions/${SNAP}/builds/${BUILD}" \
  | jq -r '.build.projects.kibana.commit_hash')
SHORT="${SHA:0:8}"
IMAGE="docker.elastic.co/kibana-ci/kibana-cloud:${SNAP}-${SHA}"
docker manifest inspect "$IMAGE" >/dev/null
echo "SNAP=$SNAP SHA=$SHA IMAGE=$IMAGE"
```

Ask the user before creating if they wanted a specific PR SHA instead.

### Create

```bash
qaf elastic-cloud deployments create \
  --stack-version "$SNAP" \
  --deployment-name "main-at-${SHORT}" \
  --environment production \
  --region gcp-us-west2 \
  --plan sdesalas3_security_oom_testing \
  --no-autoscaling \
  --no-sso \
  --no-snapshot-repo \
  --kb-docker-image "$IMAGE"
```

`--no-snapshot-repo`: skip if Vault is not logged in; create can fail *after* the cluster is already healthy while attaching GCS snapshot SA. APM does not need the snapshot repo.

### Credentials → `.env.sh`

```bash
qaf elastic-cloud deployments describe "main-at-${SHORT}" --show-credentials
# Kibana URL + elastic password from the panel
```

Write `$SCRIPTS/.env.sh` (main-only = **one** TARGET):

```bash
TARGETS=(
  "elastic:<password>|https://main-at-<short>-<hosthash>.kb.us-west2.gcp.elastic-cloud.com"
)
```

Never commit this file. Host hash changes on every recreate.

### Sanity

```bash
cd "$SCRIPTS"
./check_instances.sh
# Expect: UP / available
```

Optional: `INITIALIZE=1 ./check_instances.sh` on a brand-new deploy if Security Solution isn’t ready.

---

## 1. Stamp directory

```bash
STAMP_UTC=$(date -u +%Y-%m-%dT%H%M)          # e.g. 2026-10-27T1043
SHORTSHA="<8-char kibana sha>"                 # e.g. c4c560f2
RESULTS="$BENCH_ROOT/${STAMP_UTC}.full-bench-main-${SHORTSHA}"
mkdir -p "$RESULTS/logs" "$RESULTS/apm"
cp "$SCRIPTS/.env.sh" "$RESULTS/env.main.sh"
```

Write `$RESULTS/run_bench.sh` using the template in §3 (edit `STAMP` + notify label). `chmod +x "$RESULTS/run_bench.sh"`.

The template resolves `../scripts`, `../data`, `../skills` from `.knowledge/` via the stamp path (`RESULTS/../..`).

---

## 2. Launch (keep-alive — required)

**Do not** `nohup ./run_bench.sh &` / `disown` from a short agent shell — the parent exits and the driver dies mid-step.

**Do** run as the agent’s long-lived background command (`block_until_ms: 0`):

```bash
cd "$RESULTS" && ./run_bench.sh 2>&1 | tee ./nohup.out
```

Watch `driver.log` / terminal. Notify fires between branches if `$NOTIFY` exists.

Hang ≫ ~5 minutes: driver already notifies and **continues** (does not kill the step).

Done when `$RESULTS/DONE.txt` exists and the process exits 0.

---

## 3. Driver — full `run_bench.sh` template

Copy into `$RESULTS/run_bench.sh`. Set `STAMP` and `BENCH_LABEL` only — paths derive from the stamp location under `../benchmarks/`.

Time only **Action** steps via `run_timed`. Seeds/wipes use `run_seed` (not in wall table).

**Scenario # ≠ step letter order.** Mapping is fixed below (A2=#3, A3=#2, B2=#12, C1=#10, C2=#11).

```bash
#!/usr/bin/env bash
set -u
RESULTS="$(cd "$(dirname "$0")" && pwd)"
# Stamp is …/.knowledge/benchmarks/<stamp>/ → knowledge root is ../..
KNOWLEDGE="$(cd "$RESULTS/../.." && pwd)"
SCRIPTS="$KNOWLEDGE/scripts/bulk-primitives"
DATA="$KNOWLEDGE/data/rules-import"
NOTIFY="$KNOWLEDGE/skills/notify-when-done/scripts/notify.sh"
STAMP="YYYY-MM-DDTHHMM"          # e.g. 2026-10-27T1043
BENCH_LABEL="full bench main-<shortsha>"
STEP_LIMIT_SECS=300
export PARALLEL_ENV_FILE="${RESULTS}/env.main.sh"
cd "$SCRIPTS"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$RESULTS/driver.log"; }

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  [[ -x "$NOTIFY" ]] && "$NOTIFY" "$msg" || true
}

record_timings() {
  local step="$1" scenario="$2" logfile="$3" marker="$4"
  [[ -f "$logfile" ]] || return 0
  awk -v step="$step" -v sc="$scenario" -v marker="$marker" '
    $0 ~ marker { grab=1; next }
    grab && /^---/ { exit }
    grab && NF>=3 && $0 !~ /^target/ {
      gsub(/s$/,"",$3)
      rs = (NF>=4 ? $4 : "")
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", step, sc, $1, $2, $3, rs
    }
  ' "$logfile" >> "$RESULTS/timings.tsv"
}

check_step_limit() {
  local step="$1"
  local bad
  bad="$(awk -F'\t' -v step="$step" -v lim="$STEP_LIMIT_SECS" '
    $1==step {
      s=$5; sub(/\..*/,"",s)
      if (s+0 > lim+0) { printf "%s %ss", $3, $5; exit }
    }
  ' "$RESULTS/timings.tsv")"
  if [[ -n "${bad:-}" ]]; then
    log "WARN: $step exceeded ${STEP_LIMIT_SECS}s ($bad). Notifying; continuing."
    notify "Bench step $step took over 5 minutes ($bad). Continuing. Check ${STAMP} ${BENCH_LABEL} on kibana-main."
  fi
}

run_timed() {
  local step="$1" scenario="$2" notes="$3" marker="$4"
  shift 4
  local logfile="$RESULTS/logs/${step}.log"
  local from to rc
  from="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "START $step (#$scenario) $notes  [limit=${STEP_LIMIT_SECS}s]"
  set +e
  (
    sleep "$STEP_LIMIT_SECS"
    if [[ ! -f "${logfile}.done" ]]; then
      log "WARN: $step still running after ${STEP_LIMIT_SECS}s. Notifying; letting it finish."
      notify "Bench step $step still running after ${STEP_LIMIT_SECS} seconds. Not stopping. Check ${STAMP} ${BENCH_LABEL} on kibana-main."
    fi
  ) &
  local watch_pid=$!
  "$@" >"$logfile" 2>&1
  rc=$?
  : >"${logfile}.done"
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  set +e
  to="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$step" "$scenario" "$from" "$to" "$notes" >> "$RESULTS/windows.tsv"
  record_timings "$step" "$scenario" "$logfile" "$marker"
  log "END $step rc=$rc  window $from → $to"
  tail -n 25 "$logfile" | tee -a "$RESULTS/driver.log"
  check_step_limit "$step"
  return "$rc"
}

run_seed() {
  local step="$1" notes="$2"
  shift 2
  local logfile="$RESULTS/logs/${step}.log"
  log "SEED $step $notes"
  set +e
  "$@" >"$logfile" 2>&1
  local rc=$?
  set +e
  log "SEED END $step rc=$rc"
  tail -n 15 "$logfile" | tee -a "$RESULTS/driver.log"
  return "$rc"
}

set +e
mkdir -p "$RESULTS/logs" "$RESULTS/apm"
: > "$RESULTS/driver.log"
printf 'step\tscenario\tlabel\thttp\tseconds\trules_summary\n' > "$RESULTS/timings.tsv"
printf 'step\tscenario\tfrom_utc\tto_utc\tnotes\n' > "$RESULTS/windows.tsv"

log "RESULTS=$RESULTS"
log "KNOWLEDGE=$KNOWLEDGE"
log "PARALLEL_ENV_FILE=$PARALLEL_ENV_FILE"
log "=== check instances ==="
./check_instances.sh 2>&1 | tee "$RESULTS/logs/check.log" | tee -a "$RESULTS/driver.log"

log "=== pre-wipe: delete all rules ==="
run_seed pre-wipe-rules "ACTION=delete all rules" \
  env ACTION=delete ./parallel_bulk_action.sh

log "=== pre-wipe: delete exception lists ==="
run_seed pre-wipe-lists "delete exception lists" \
  ./parallel_delete_exception_lists.sh

log "=== Branch A ==="
notify "Starting Branch A on ${STAMP} ${BENCH_LABEL} on kibana-main."
run_timed A1 1 "Import 1000disabled-rules.ndjson" "--- import timings ---" \
  env DELETE=1 IMPORT_FILE="$DATA/1000disabled-rules.ndjson" ./parallel_import_rules.sh
run_timed A2 3 "bulk_action enable" "--- enable timings ---" \
  env ACTION=enable ./parallel_bulk_action.sh
run_timed A3 2 "Import 1000enabled-rules.ndjson" "--- import timings ---" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled-rules.ndjson" ./parallel_import_rules.sh
run_timed A4 4 'bulk_action edit add_tags=["bench"]' "--- edit timings ---" \
  env ACTION=edit EDIT_BODY='[{"type":"add_tags","value":["bench"]}]' ./parallel_bulk_action.sh
run_seed A5-seed "reseed 1000enabled" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled-rules.ndjson" ./parallel_import_rules.sh
run_timed A5 5 "Import overwrite 1000enabled-rules.all-updated.ndjson" "--- import timings ---" \
  env DELETE=0 IMPORT_FILE="$DATA/1000enabled-rules.all-updated.ndjson" ./parallel_import_rules.sh
run_seed A6-seed "reseed 1000enabled" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled-rules.ndjson" ./parallel_import_rules.sh
run_timed A6 6 "Import overwrite 1000enabled-rules.1-updated.ndjson" "--- import timings ---" \
  env DELETE=0 IMPORT_FILE="$DATA/1000enabled-rules.1-updated.ndjson" ./parallel_import_rules.sh
run_seed A7-seed "reseed 1000enabled" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled-rules.ndjson" ./parallel_import_rules.sh
run_timed A7 7 "bulk_action disable" "--- disable timings ---" \
  env ACTION=disable ./parallel_bulk_action.sh
run_timed A8 8 "bulk_action delete (no gaps)" "--- delete timings ---" \
  env ACTION=delete ./parallel_bulk_action.sh

notify "Branch A finished. Starting Branch B on ${STAMP} ${BENCH_LABEL} on kibana-main."

log "=== Branch B ==="
run_timed B1 9 "Import 1000enabled.rules+connector-email-smtp.ndjson" "--- import timings ---" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled.rules+connector-email-smtp.ndjson" ./parallel_import_rules.sh
run_timed B2 12 "Import overwrite +2connectors-email-smtp-cases" "--- import timings ---" \
  env DELETE=0 IMPORT_FILE="$DATA/1000enabled.rules+2connectors-email-smtp-cases.ndjson" ./parallel_import_rules.sh
run_seed C-wipe "delete before Branch C" \
  env ACTION=delete ./parallel_bulk_action.sh
run_seed C-wipe-lists "exception lists before Branch C" \
  ./parallel_delete_exception_lists.sh

notify "Branch B finished. Starting Branch C on ${STAMP} ${BENCH_LABEL} on kibana-main."

log "=== Branch C ==="
run_timed C1 10 "Import 1000enabled.rules+20exceptionlists.ndjson (20 lists × 50 items)" "--- import timings ---" \
  env DELETE=1 IMPORT_FILE="$DATA/1000enabled.rules+20exceptionlists.ndjson" ./parallel_import_rules.sh
run_timed C2 11 "Import overwrite +21exceptionlists (21 lists × 50 items)" "--- import timings ---" \
  env DELETE=0 IMPORT_FILE="$DATA/1000enabled.rules+21exceptionlists.ndjson" ./parallel_import_rules.sh
run_seed C3-gaps "GAPS_PER_RULE=3 parallel_seed_gaps" \
  env GAPS_PER_RULE=3 ./parallel_seed_gaps.sh
run_timed C3 13 "bulk_action delete (with gaps)" "--- delete timings ---" \
  env ACTION=delete ./parallel_bulk_action.sh
run_timed C4 14 "Bulk delete 21 shared exception lists (TYPE=detection)" "--- exception-list delete timings ---" \
  env TYPE=detection ./parallel_delete_exception_lists.sh

log "=== DONE wall-clock bench ==="
notify "Wall-clock bench finished. Results in ${STAMP} ${BENCH_LABEL} on kibana-main."
echo done > "$RESULTS/DONE.txt"
```

### Execution map (same as driver)

| Step | # | Seed | Action (timed) | Env / fixture |
|---|---|---|---|---|
| A1 | 1 | clean | Import | `DELETE=1` `1000disabled-rules.ndjson` |
| A2 | 3 | after A1 | `_bulk_action` enable | `ACTION=enable` |
| A3 | 2 | clean (`DELETE=1` import) | Import | `1000enabled-rules.ndjson` |
| A4 | 4 | after A3 | edit `add_tags: ["bench"]` | `ACTION=edit` + `EDIT_BODY` |
| A5 | 5 | reseed #2 (`DELETE=1` enabled) | Import overwrite | `DELETE=0` `…all-updated.ndjson` |
| A6 | 6 | reseed #2 | Import overwrite | `DELETE=0` `…1-updated.ndjson` |
| A7 | 7 | reseed #2 | disable | `ACTION=disable` |
| A8 | 8 | after A7 | delete (no gaps) | `ACTION=delete` |
| B1 | 9 | clean | Import | `…+connector-email-smtp.ndjson` |
| B2 | 12 | after B1 | Import overwrite | `DELETE=0` `…+2connectors-email-smtp-cases.ndjson` |
| — | — | wipe rules + all lists | (seed) | before C |
| C1 | 10 | clean | Import | `…+20exceptionlists.ndjson` |
| C2 | 11 | after C1 | Import overwrite | `DELETE=0` `…+21exceptionlists.ndjson` |
| C3 | 13 | C2 + `GAPS_PER_RULE=3` | delete | gaps seed not timed |
| C4 | 14 | after C3 | delete lists | `TYPE=detection` |

`DELETE=1` on import = delete-all-rules then import (clean create).
`DELETE=0` = overwrite-only (no pre-delete).
`parallel_import_rules.sh` waits ~10s after a delete phase before import.

Driver markers for timings parsing: `--- import timings ---`, `--- enable timings ---`, `--- edit timings ---`, `--- disable timings ---`, `--- delete timings ---`, `--- exception-list delete timings ---`.

---

## 4. After the run — `SUMMARY.md`

Write `$RESULTS/SUMMARY.md`. Must stand alone (no “see methodology doc”).

Required sections:

1. **Title** + one-line scope (main-only vs dual-stack).
2. **Targets** — deploy name, Kibana host, build hash, plan knobs, wall window from first/last `windows.tsv` rows.
3. **Scenarios** + **PRs** + **Endpoints** (copy tables from this runbook).
4. **Methodology** — Branch A/B/C tables (execution order).
5. **Wall-clock results** — curl `time_total` from `timings.tsv` (1 decimal). Optional reference column to a prior published main run.
6. **Notes** — `rules_summary` (`created=` / `updated=` / `skipped=`), slowest steps, drop-cap warnings if APM later.
7. Optional **APM transactions** (only if asked): scenario #, name, APM dur, spans, dropped, `trace.id`, 🔍 `./images/…`.

Raw stamps under `$BENCH_ROOT/<stamp>/` are **not** in git. To check results in, copy **only what the user asks** (usually `SUMMARY.md` + `images/`) into `$BENCH_ROOT/published/<same-stamp>/`.
Do **not** publish `env.*.sh`, passwords, or full `logs/`.

### Pull wall seconds from `timings.tsv`

```bash
# columns: step scenario label http seconds rules_summary
awk -F'\t' 'NR>1 { printf "%s\t#%s\t%ss\t%s\n", $1, $2, $5, $6 }' "$RESULTS/timings.tsv"
```

---

## 5. Optional: APM (only if asked)

1. Creds: `~/config/apm.creds` → monitoring **ES** (`*.es.*`). Health: `GET /_cluster/health`.
2. Filter `service.environment` / deployment name = `main-at-<shortsha>`.
3. Exclusive windows from `windows.tsv` (adjacent B1/B2, C1/C2 can share a second — shrink one side by 1s).
4. `"$APM_SCRIPTS"/find_transactions.py --path _import|_bulk_action --from … --to … --environment <name>`
5. `"$APM_SCRIPTS"/analyze_transaction.py --trace-id …`
6. Warn if `dropped` ≫ 0 — rankings incomplete (span cap). Prefer **hierarchical** call trees; flat pies double-count nested spans.

---

## 6. Checklist

- [ ] Told user: monitoring cluster + plan APM → that cluster + `~/config/apm.creds` (or they confirmed still good)
- [ ] User confirmed image SHA (main tip vs PR)
- [ ] Deploy up; `describe` build hash matches image
- [ ] Plan has 25 MiB import + APM `serverUrl`/`secretToken`/`environment` = deployment name
- [ ] `$SCRIPTS/.env.sh` → live host + password; `./check_instances.sh` UP
- [ ] Stamp dir + `env.main.sh` + `run_bench.sh` (**20/21** exception fixtures)
- [ ] Launch via **keep-alive** Cursor terminal (`block_until_ms: 0`)
- [ ] A → B → C completes; `DONE.txt`
- [ ] `SUMMARY.md` written; publish only if asked

---

## Anti-patterns

| Don’t | Do instead |
|---|---|
| `nohup … &` / `disown` from a one-shot agent shell | Keep-alive `./run_bench.sh` (`block_until_ms: 0`) |
| Branch C `+30` / `+31` exception fixtures | `+20` / `+21` |
| Commit `.env.sh` / paste passwords into SUMMARY | Secrets stay local |
| Cite failed/partial prior runs in SUMMARY | Only successful comparable numbers |
| Point `APM_ES_URL` at `*.apm.*` intake | Monitoring `*.es.*` |
| Dual-stack SUMMARY with one TARGET | One `TARGETS` entry per stack; dual needs two env files / driver edits |
| Kill a hung step | Notify and let it finish; record window anyway |
| Flat pie charts of nested APM spans | Hierarchical / union-wall rankings |
| Hardcode `/Users/…` or `~/.claude/skills` | Use `../scripts`, `../data`, `../skills` from this guide / stamp |

---

## Dual-stack variant (brief)

Same methodology; two ECH hosts. Put both in `TARGETS` **or** use two env files (`env.main.sh` / `env.954.sh`) and a driver that runs each step against both (see `../benchmarks/published/2026-10-21T0833.full-bench-954-vs-main/run_bench.sh`). SUMMARY gets two wall columns. Not required for main-only.
