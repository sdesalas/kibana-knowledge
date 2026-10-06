# Diagnostic sources for common detection-rule queries

Companion to [detection-rules-architecture.md](./detection-rules-architecture.md)
§14 (persistence) and [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md).

This doc answers: *when a detection-rule support issue lands, which logs / indices / SOs
can actually help, and which cannot?*

Investigation context: support questions like "this rule missed a document",
"it alerted a week late", "the Gaps table is empty but scheduling delay is huge".

---

## Do not conflate these

| People say | What they usually mean | What it actually is |
|---|---|---|
| **Events log / event log** | "the execution history" | `.kibana-event-log-*`. This *is* the rule execution log. |
| **Rule execution log** | A separate product log | Same event log, shown as Rule Details → Execution log. Three providers in one index (see below). |
| **Kibana stdout** | The execution log | Process logs. At default (info) level you only see non-user failures. Status changes, warnings and partial failures are **debug**; the ES\|QL request dump is **trace**. |
| **Audit log** | "did this document match?" | User actions (edit, enable, manual run, fill_gaps). Not per-document detection. Not system-initiated backfills (auto gap fill). |
| **Elastic stdout** | Kibana logs | Elasticsearch node logs. Shard failures, slow logs, circuit breakers. |

**One-liner:** the event log tells you *that a run happened and how it ended*;
the alerts index tells you *what it created*. Nothing records *which `_id`s
it saw* — not stdout, not extended logging, at any level. The only
per-document trace is `kibana.alert.ancestors` on an alert that was written.

---

## Map

Always-on means "on a typical Elastic Cloud / hosted cluster, without extra
flags." Retention is the usual gotcha: event log is a data stream with
data stream lifecycle retention of **90d** (not ILM), stdout rotates, audit
may never have been enabled, backfill SOs are deleted on completion.

| Source | Where it lives / always on? | What it tells you | Doesn't tell you |
|---|---|---|---|
| **Event log** (`alerting`) | `.kibana-event-log-*`, `event.provider: alerting`<br><br>**Always on.** | Per-run `execute` / `execute-start` / `execute-timeout`. Duration, schedule delay, search time, new-alert count, `alerts_candidate_count` (ES\|QL: last page only, see cheat sheet). `execute-backfill` with `kibana.alert.rule.execution.backfill.{id,start,interval}` (no `execute-start` for backfills). `gap` events when remaining gap was stored. `gap-auto-fill-schedule` for system-initiated gap fills. | Which source `_id`s matched. The raw query. Why one doc in a window was skipped. |
| **Event log** (`securitySolution.ruleExecution`) | same index, `event.provider: securitySolution.ruleExecution`<br><br>**Status + metrics always on. Messages off.** | `status-change`, `execution-metrics` (search/index duration, gap range / reason). Every event carries `rule.revision`, so this is the per-run record of which revision ran. | Per-run `message` events. These need **both** the experimental flag `extendedRuleExecutionLoggingEnabled` (`kibana.yml`, default off, not customer-settable on serverless) **and** the advanced setting for extended logging min level lowered from its default `info`: `ES\|QL query to execute` is trace, "alerts created: N" is debug. |
| **Event log** (`actions`) | same index, `event.provider: actions`<br><br>**Always on.** | Whether webhook / index actions fired or failed for that execution uuid. | Whether the *alert document* was written. A failed action can still leave an alert. |
| **Alerts index** | `.alerts-security.alerts-<space>` (legacy alias `.siem-signals-<space>`)<br><br>**Always on.** | The alert itself: `ancestors.id` (source `_id`), `original_time`, `rule.execution.uuid`, `rule.execution.type` (`manual` = backfill), `intended_timestamp`, `revision`, uuid used for dedup. | Why an alert was *not* created. Missing from here is not proof the executor never saw the doc. |
| **Kibana audit** | Kibana security audit log<br><br>**Off** by default (`xpack.security.audit.enabled: false`; subscription feature). | That a user did an action on a rule: `rule_update` / `rule_enable` / `rule_disable` / `rule_run_soon` / `rule_schedule_backfill` / `rule_fill_gaps` / `ad_hoc_run_*` / `gap_auto_fill_scheduler_*`. Fields are thin: `user.name`, `event.action`, saved-object id/name. | The edit itself (new query, revision, backfill window). Detection outcomes. Backfills created by the auto gap fill scheduler (`initiator: system`) — only the scheduler config change is audited. `rule_run_soon` is “run the next tick now”, not a historical re-run. |
| **`ad_hoc_run_params` SOs** | `.kibana_alerting_cases`<br><br>**Only while a backfill is pending / running.** | In-flight backfills: window, `initiator` (`user` / `system`). | Anything historical: the SO is **deleted when the backfill completes**. For past backfills use `execute-backfill` events + alert `execution.type: manual`. |
| **Rule change history** | `.kibana_change_history` data stream (alerting-rules dataset), read via `rule_get_history`<br><br>**On by default from 9.5** (`xpack.alerting.ruleChangeTracking`, scope `security`). | Full rule snapshot per change, who made it, when. Infinite retention by default. | Changes made before the feature shipped on that cluster. |
| **Task Manager index** | `.kibana_task_manager` (`task` SO; id = rule's `scheduledTaskId`)<br><br>**Always on** (current state only). | Current `schedule.interval`, `runAt`, `scheduledAt`, `startedAt`, `retryAt`, `status`, `attempts`, `ownerId`. Rule task `state.previousStartedAt` (what the next run's gap calc starts from). | History: every run overwrites the doc. Backfill tasks (`ad_hoc_run-backfill`) are deleted when done. Per-run schedule delay history lives in the event log (`event.provider: taskManager`, `task-run` → `kibana.task.schedule_delay`, 9.4+). A delay ≠ a missed document; lookback + catch-up may still have covered it. See [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md). |
| **Task Manager stdout** | `plugins.taskManager` logger<br><br>**Always on, at info level.** | At error/warn: task failures (`Task … failed`), event loop blocked over `event_loop_delay.warn_threshold` (5000ms), retryAt conflicts on long-running tasks. | Per-run claim / schedule delay. Health degradation ("Task Manager detected a degradation…", "Detected delay task start of Ns") — both **debug** unless `monitored_stats_health_verbose_log.enabled` (default `false`). Anything after log rotation. |
| **Kibana stdout** | `plugins.securitySolution.ruleExecution` logger<br><br>**Always on, at info level.** | At info: only `failed` status for non-user errors (logged at error). Status changes, warnings, partial failures: **debug** (`info()` / `warn()` / `error()` default to debug on the console). Query body, iteration, "alerts created: N": **debug/trace**. | Historical detail after log rotation. Hit `_id`s at any level. Useless at default level for a silent miss or partial failure. |
| **ES stdout / slow log** | Elasticsearch node logs<br><br>**Stdout always on. Slow log off.** | Shard failures, timeouts, circuit breakers, rejected bulk writes. Explains a *failed* or partial search. | A clean success that skipped one `_id`. Slow log is not on by default. |
| **Rule SO / export** | `.kibana_alerting_cases` (`alert` SO) / rules export ndjson<br><br>**Always on.** | Query, `interval`, `from`/`to`, `max_signals`, exceptions, revision, actions. Latest status lives on the same SO (`lastRun` + `monitoring.run.last_run`) — that replaced the old `siem-detection-engine-rule-execution-info` sidecar, which is a removed type, not an index. | What a past revision looked like (use rule change history, or an export of that revision). Any execution except the last one. |
| **Source index** | Whatever the rule queries<br><br>**Always on.** | The document exists, `_id` / `_index` / `_version` / `@timestamp` / `event.ingested`. Lets you test the query by hand. | Whether the rule saw it at run time. `_version` *today* is not `_version` on the day. |
| **Diagnostics bundle** | Support zip<br><br>**Only if the customer attached it.** | Snapshot of some of the above, often **default space only** (anecdotal, not verified against the support-diagnostics tool). | Other spaces. Anything already past event log retention. |
| **APM** | Elastic APM<br><br>**Off** unless the customer runs it. | Executor spans, alert-count labels, outcome. | Per-document identity. |

---

## Cheat sheet — symptom → look here

| Symptom | First look | Then | Usually a waste |
|---|---|---|---|
| **Missed document, run succeeded** | Alerts index for that `ancestors.id` (was it actually missed?). Event log for that execution uuid: status, `alerts_candidate_count` vs new alerts, warnings. For ES\|QL, `alerts_candidate_count` is overwritten per page, so a multi-page run reports the last page only. | Source doc `_id`/`_index`/`_version`. Rule export (query, lookback, `max_signals`). Re-run the query by hand for that window. | Rule `lastRun` (latest only). Audit log. ES stdout, unless the run was not actually clean. |
| **Alerted days later** | The late alert: `execution.type`, `execution.uuid`, `intended_timestamp`, `revision`. Event log that day for `execute-backfill` (`backfill.id` / `start` / `interval`). | Event log `gap-auto-fill-schedule` (system backfills have no user audit). Kibana audit for fill_gaps / manual run. `ad_hoc_run_params` only if it's still running. Confirm a scheduled run cannot reach that old `@timestamp` (lookback + at most 4 catch-up intervals). | Treating it as a normal scheduled hit. |
| **Failed / partial-failure runs** | Event log `status-change` / alerting `execute` outcome + message. | Kibana stdout (non-user failures at error; partial failures need debug). ES stdout for shard failures / timeouts. Actions event log if the customer only saw a missing webhook. | Hunting source `_id`s before you know the run failed. Kibana stdout at default level for partial failures. |
| **Huge scheduling delay, empty Gaps table** | Event log: schedule delay vs `gap_duration_s` / `gap` events. | [rule_gaps_and_catchup.md](./rule_gaps_and_catchup.md). Catch-up may have covered the drift. | Assuming delay = missed data. |
| **Did anyone backfill / re-run?** | Alert `execution.type`. Event log `execute-backfill`, `gap-auto-fill-schedule`. | Kibana audit (user-initiated only). `ad_hoc_run_params` (pending / running only). | Kibana stdout. Treating an empty audit log as "no backfill". |
| **Rule changed during the window** | Event log `rule.revision` per run (covers runs with no alerts). Rule export `revision` vs `kibana.alert.rule.revision` on the alerts. | Rule change history (9.5+) for the then-active query. Kibana audit for who edited. Older clusters: ask for the *then-active* query, not today's export. | Today's rule export on its own. |
| **Action fired but no alert (or the reverse)** | Alerts index first, then `actions` events for that execution uuid. | Rule action config (webhook vs index). Customer history indexes are not ours. | Assuming the webhook is the alerts index. |

---

## What you cannot reconstruct

After the fact, you will not get these on any cluster, at any log level:

- The ES\|QL (or EQL / query) hit list from that run
- Why one `_id` in the window was skipped
- Per-document "marked handled" / `excludedDocuments` state

No logger ever writes them. The most trace / debug (or extended-logging
`message` events) give you is the request body, search-after cursors,
page sizes, timings and counts. Even that needs debug/trace on stdout, or
both extended-logging gates, and the event log only keeps 90 days.

If the event log for that day is gone, you are left with the alert document
(if any), the source document, the rule export and, on 9.5+, rule change
history. Ask for those first; do not wait on stdout.

---

## Code pointers

For "what event gets written":

- Event log writer: `.../rule_monitoring/logic/rule_execution_log/`
- Alerting execute / backfill / gap actions: `x-pack/platform/plugins/shared/alerting/server/plugin.ts` (`EVENT_LOG_ACTIONS`)
- ES\|QL trace of the request: `.../rule_types/esql/esql.ts` (`ruleExecutionLogger.trace`)
- Extended logging gates: `extendedRuleExecutionLoggingEnabled` experimental flag (default `false`) + min level advanced setting (default `info`): `.../rule_execution_log/execution_settings/fetch_rule_execution_settings.ts`
- Console log levels: `.../rule_execution_log/client_for_executors/client.ts`, `consoleLogLevelFromExecutionStatus` in `common/api/detection_engine/rule_monitoring/model/log_level.ts`
- Backfill SO cleanup: `x-pack/platform/plugins/shared/alerting/server/task_runner/ad_hoc_task_runner.ts` (`cleanup`)
- Auto gap fill: `x-pack/platform/plugins/shared/alerting/server/lib/rule_gaps/task/gap_auto_fill_scheduler_task.ts`
- Rule change history: `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/`, `@kbn/change-history`

---

## What's available by version

Checked against the `8.19`, `9.4` and `9.5` branches. `main` (9.6) matches 9.5.

| Source / field | 8.19 | 9.4 | 9.5 |
|---|---|---|---|
| Event log retention: data stream lifecycle, 90d | Yes | Yes | Yes |
| Alerting `execute-backfill` with `backfill.{id,start,interval}` | Yes | Yes | Yes |
| Alerting `gap` events | Yes | Yes | Yes |
| Alerting event log `alerts_candidate_count` | — | Yes | Yes |
| Security `execution-metrics` `gap_range` | Yes | Yes | Yes |
| Security `execution-metrics` `gap_reason` | — | Yes | Yes |
| `rule.revision` on every security event log doc | Yes | Yes | Yes |
| Extended logging behind experimental flag (default off) | Yes | Yes | Yes |
| ES\|QL request in rule execution log | `debug`, "ES\|QL query request: …" | `trace`, "ES\|QL query to execute" | `trace`, "ES\|QL query to execute" |
| Security console status changes at `debug` (non-user failures at `error`) | Yes | Yes | Yes |
| Alert `execution.type` / `intended_timestamp` | Yes | Yes | Yes |
| Audit `rule_schedule_backfill` / `rule_fill_gaps` | Yes | Yes | Yes |
| Backfill SOs deleted on completion | Yes | Yes | Yes |
| Backfill `initiator` (`user` / `system`) on `ad_hoc_run_params` | — | Yes | Yes |
| Auto gap fill (`gap-auto-fill-schedule` event, `gap_auto_fill_scheduler_*` audit) | — | Yes | Yes |
| Task Manager verbose health logging off by default | Yes | Yes | Yes |
| Task Manager event log (`event.provider: taskManager`, `task-run` / `task-cancel` with `kibana.task.schedule_delay`) | — | Yes | Yes |
| Task Manager `task-run-start` event | — | — | Yes |
| Rule change history (`.kibana_change_history`, `rule_get_history` audit) | — | — | Yes |

On 8.19 that means: no candidate count to compare against, no per-run
schedule delay history beyond the alerting `execute` event, any backfill is
user-initiated (so it shows in audit, if audit is on), and past rule
revisions only come from exports.
