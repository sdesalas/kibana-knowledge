# Handoff: PR #300213 QAF redeploy + wall bench (b758fc7)

## Context

Steven (`sdesalas`) on repo `kibana-6th` (`/Users/sdesalas/Code/sdesalas/kibana-6th`). Goal: ECH wall-clock bench of detection-rule import/bulk scenarios for PR [#300213](https://github.com/elastic/kibana/pull/300213) (APM spans for import/enable/disable/delete), with APM transaction links in `SUMMARY.md` pointing at monitoring cluster `d7b1ce`. A prior successful run used image SHA `bb0663f2`; user added more spans and wants a **fresh** deploy + full 14-scenario redo on `b758fc7`.

## Original dialog

- `/qaf` deploy image from PR **300213** → used Buildkite image `kibana-cloud-pr:9.7.0-SNAPSHOT-bb0663f2…` (not `kibana-cloud` + PR head; head lagged Buildkite SHA).
  - *Insight:* PR images are **`docker.elastic.co/kibana-ci/kibana-cloud-pr:<stack>-<sha>`**. Constructing `kibana-cloud` + `gh pulls/.head.sha` 404s. Prefer Buildkite image string. Skill gap fixed in `.knowledge/skills/qaf/SKILL.md`.
- Run full 14-scenario bench per `@.knowledge/guides/detection_rule_wall_bench.md` + `@.knowledge/demos/benchmark-scenarios.md`; confirm plan before start; **`INITIALIZE=1`** to preload Elastic rules.
  - *Insight:* Follow wall-bench runbook exactly; keep-alive `./run_bench.sh` (`block_until_ms: 0`); no `nohup`/disown.
- SUMMARY must include **APM transactions table with monitoring links for all 14** (like prior main SUMMARY § APM), not a deep APM investigation.
  - *Insight:* Table only — find longest matching HTTP txn per `windows.tsv` window; link to monitoring Kibana waterfall. No hierarchical dig unless asked.
- First deploy had **wrong `elastic.apm.serverUrl`** (dead `00f6f1`); plan fixed to **`d7b1ce`**. User: tear down, redeploy, redo bench.
  - *Insight:* Always confirm plan APM URL before create. Current plan: `~/.qaf/config/cloud_plans/sdesalas3_security_oom_testing.yml` → `…-d7b1ce.apm.us-west2.gcp.elastic-cloud.com`, `transactionMaxSpans: 15000`.
- Use **d7b1ce** for links; no deep investigation — just APM section+table.
- “Copy summary to published dir” then `/handoff` for next agent to **`/qaf` deploy latest PR build at `b758fc7`** and rerun same bench.
  - Image (user-provided, do not re-resolve):  
    `docker.elastic.co/kibana-ci/kibana-cloud-pr:9.7.0-SNAPSHOT-b758fc7023fb1ca6337fa41082581d2c68c5b461`
  - *Insight:* User said do not investigate further — execute redeploy + bench + SUMMARY with APM links. Notify on deploy ready / bench done via `notify-when-done`.

## Conclusions

- QAF skill updated for `kibana-cloud-pr` vs `kibana-cloud` and Buildkite SHA lag.
- Deploy name pattern used: `sdesalas.pr.300213.import-apm`; plan `sdesalas3_security_oom_testing`; `gcp-us-west2`; production; `--no-autoscaling --no-sso --no-snapshot-repo`.
- First bench (bad APM) stamp: `2026-11-05T1325…` — discard for APM; wall numbers only incidental.
- Successful redo (good APM → d7b1ce) stamp: **`2026-11-05T1444.full-bench-pr-300213-bb0663f2`** — all 14 HTTP 200; SUMMARY written with wall + APM table; `apm/trace-ids.json` present.
- SUMMARY copied to **`published/2026-11-05T1444.full-bench-pr-300213-bb0663f2/SUMMARY.md`** (SUMMARY only; no secrets/logs).
- Live ECH deploy still named `sdesalas.pr.300213.import-apm` on **old** image `bb0663f2` — **must remove and recreate** for `b758fc7`.
- Auth: user owns Vault + `~/.elastic/cloud.json`; do not invent keys. APM query: `~/config/apm.creds` → `d7b1ce` ES. Monitoring Kibana UI: `https://monitoring-cluster-for-local-kibana-develop-d7b1ce.kb.us-west2.gcp.elastic-cloud.com`.
- `find_transactions.py` ES|QL fails on `transaction.span_count.dropped` on this cluster — query without that field; put `—` in dropped column if needed.

## Current state

- **Done:** bb0663f2 redeploy+bench+SUMMARY+published copy; QAF skill PR-image notes; plan APM → d7b1ce.
- **Pending (next agent):** Remove current `sdesalas.pr.300213.import-apm`; create with **b758fc7** image; `INITIALIZE=1`; new stamp under `.knowledge/benchmarks/`; full `run_bench.sh`; SUMMARY with wall + 14 APM monitoring links; optional copy to `published/`.
- **Still registered (leave alone unless asked):** `kibana-9.5.4`, `main-at-c4c560f2`.
- Secrets: `.env.sh` / `env.main.sh` hold elastic password — never commit.

## Next session focus

1. Confirm plan still has `d7b1ce` APM URL + `maxRuleImportPayloadBytes` + `transactionMaxSpans: 15000`.
2. `docker manifest inspect` the user image; then  
   `printf 'y\n' | qaf elastic-cloud deployments remove sdesalas.pr.300213.import-apm`  
   (no `-y` flag).
3. Recreate same name/plan/region with  
   `KIBANA_DOCKER_IMAGE=docker.elastic.co/kibana-ci/kibana-cloud-pr:9.7.0-SNAPSHOT-b758fc7023fb1ca6337fa41082581d2c68c5b461`  
   `STACK_VERSION=9.7.0-SNAPSHOT`. Notify when up.
4. `describe --show-credentials` → `.knowledge/scripts/bulk-primitives/.env.sh` one TARGET; `INITIALIZE=1 ./check_instances.sh`.
5. New stamp e.g. `<UTC>.full-bench-pr-300213-b758fc70/`; copy/`sed` prior `run_bench.sh` (STAMP/BENCH_LABEL); keep-alive launch.
6. On `DONE.txt`: wall SUMMARY + APM table (env `sdesalas.pr.300213.import-apm`, monitoring `d7b1ce`); copy SUMMARY to `published/<same-stamp>/` if user wants publish.
7. Do **not** deep APM investigate unless asked.

## Suggested skills

- `/qaf` — create/remove/describe ECH deploy, image flags, plan APM.
- `notify-when-done` — audible ping when deploy/bench finishes.
- Wall-bench is a **guide** not a slash skill: `.knowledge/guides/detection_rule_wall_bench.md`.

## Artifacts

- Image: `docker.elastic.co/kibana-ci/kibana-cloud-pr:9.7.0-SNAPSHOT-b758fc7023fb1ca6337fa41082581d2c68c5b461`
- Prior good run: `.knowledge/benchmarks/2026-11-05T1444.full-bench-pr-300213-bb0663f2/` (`SUMMARY.md`, `timings.tsv`, `windows.tsv`, `run_bench.sh`, `apm/trace-ids.json`)
- Published: `.knowledge/benchmarks/published/2026-11-05T1444.full-bench-pr-300213-bb0663f2/SUMMARY.md`
- Runbook: `.knowledge/guides/detection_rule_wall_bench.md`
- Scenarios: `.knowledge/demos/benchmark-scenarios.md`
- QAF skill: `.knowledge/skills/qaf/SKILL.md`
- Plan: `~/.qaf/config/cloud_plans/sdesalas3_security_oom_testing.yml`
- APM creds: `~/config/apm.creds` (ES `d7b1ce`)
- PR: https://github.com/elastic/kibana/pull/300213
- Ref main SUMMARY style: `.knowledge/benchmarks/published/2026-10-27T1043.full-bench-main-c4c560f2/SUMMARY.md`
