# `bulkCreateRules` — deferred task-enable across batches

Companion to [`bulk-create-with-enable.md`](./bulk-create-with-enable.md). The
existing `bulkCreateRules` in
`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
is structurally correct (Phases 0–6, single-batch failure handling) but has one
fatal property when called repeatedly by an importer that chunks 1,000 rules into
20 batches of 50: **Phase 5 (`taskManager.bulkEnable`) runs at the end of every
batch**.

The moment tasks are flipped to `enabled: true`, Task Manager polling picks them
up and the rules' executors start writing to:

- `.kibana_alerting_cases*` — rule `executionStatus`, `running` flag, rule run
  reports, event-log writebacks.
- `.kibana_task_manager` — task state, `runAt`, `lastRunAt`, retry bookkeeping.

These are precisely the indices the **next batch's Phase 4
(`bulkCreateRulesSo`) and Phase 3 (`taskManager.bulkSchedule`) are about to
write to**. With 50 rules going hot per batch, by batch 10 the import is
contending with ~500 running rule executions on the same indices it needs for
its own writes. Throughput collapses long before the import finishes.

The objective of this report is a flow where:

- Foreground work per batch still does **everything except Phase 5**, i.e. SO
  create, task schedule, API key cleanup, audit, demotion accounting — all
  per-batch as today.
- Tasks for enabled rules are left `enabled: false` until **every batch in the
  import has finished its Phase 4**.
- A **single** `taskManager.bulkEnable` call at the very end flips all 1,000
  tasks on at once.

This is the smallest possible change that eliminates the per-batch contention,
and — importantly — it does **not** turn into the "deferred-serial" anti-pattern
described in [`bulk_create_rules_deferred_serial_flow.md`](./bulk_create_rules_deferred_serial_flow.md),
because we are not deferring schedule, validation, or API key cleanup — only the
final enable.

---

## 1. Why per-batch `bulkEnable` is the bottleneck (and `bulkSchedule` is not)

This is worth spelling out, because it's the entire reason the fix has the
shape it does.

| Step                                  | Index touched                  | Inert after the call?                    | Cost to subsequent batches |
|---------------------------------------|--------------------------------|------------------------------------------|----------------------------|
| Phase 3 — `taskManager.bulkSchedule`  | `.kibana_task_manager`         | **Yes** (tasks written with `enabled: false`) | One-shot write, then nothing. |
| Phase 4 — `bulkCreateRulesSo`         | `.kibana_alerting_cases*`      | **Yes** (rule SO, no executor running)   | One-shot write, then nothing. |
| Phase 5 — `taskManager.bulkEnable`    | `.kibana_task_manager`         | **No** — tasks start polling immediately | TM poller picks them up within seconds; rule executors then write `.kibana_alerting_cases*` + `.kibana_task_manager` continuously. |

Phases 3 and 4 are bounded I/O. They write once and stop. Phase 5 is the only
phase whose effect **persists past the call** as ongoing index traffic. That
ongoing traffic is the slowdown.

Note that Phase 3 already schedules tasks with `enabled: false` (line 49 of
`bulk_enable_rules.ts`, mirrored in `bulkCreateRules` via `buildTaskInstance`).
The existing design already separates "task SO exists" from "task is running" —
we just need to defer the second half across batches instead of doing it within
each batch.

---

## 2. The optimized flow

### 2.1 Scope of change

**Inside `bulkCreateRules` (alerting plugin):**

- Add an optional `deferTaskEnable?: boolean` to `BulkCreateRulesParams`.
- When `true`, Phase 5 (`tryToEnableTasks`) is **skipped**.
- The result envelope carries an additional `taskIdsPendingEnable: string[]`
  with the task ids whose SOs were successfully persisted in Phase 4 and that
  were scheduled in Phase 3 of this call — i.e. the task ids the caller now
  owns the responsibility to enable.
- Everything else per batch — Phase 1, 2, 3, 4, audit, demotion accounting,
  per-row error handling, API key invalidation — stays exactly as it is today.

**Inside the security wrapper (`importRules` / `bulkImportRules`):**

- Iterate `ruleChunks` as today, calling `bulkCreateRules` with
  `deferTaskEnable: true`.
- Accumulate `taskIdsPendingEnable` across all chunks.
- After the loop, do **one** `taskManager.bulkEnable(allTaskIds)`.
- Map any returned per-task failures back to `rule_id`s and surface them as
  warning entries in the import response (same shape used today for
  `taskIdsFailedToBeEnabled`).

### 2.2 Phase diagram (single batch, `deferTaskEnable: true`)

```text
┌─────────────────────────────────────┐
│  PHASE 0 — partition by enabled     │   unchanged
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  PHASE 1 — per-rule prepare         │   unchanged
│  (validation + API key mint)        │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  PHASE 2 — validateScheduleLimit    │   unchanged
│  (enabled subset only)              │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  PHASE 3 — taskManager.bulkSchedule │   unchanged
│  (tasks created with enabled:false) │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  PHASE 4 — bulkCreateRulesSo        │   unchanged
│  + per-row error handling           │
│  + audit CREATE / ENABLE            │
└──────────────────┬──────────────────┘
                   │
        ┌──────────┴──────────┐
        │ deferTaskEnable?    │
        └──────────┬──────────┘
       false       │       true
        │          │          │
        ▼          │          ▼
┌──────────────┐   │   ┌─────────────────────────────┐
│ PHASE 5      │   │   │  PHASE 5 — SKIPPED           │
│ tryToEnable  │   │   │  taskIdsPendingEnable[] is   │
│ Tasks(...)   │   │   │  returned to caller instead. │
└──────┬───────┘   │   └──────────────┬──────────────┘
       │           │                  │
       └───────────┼──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  flushKeysToInvalidate (per-batch)  │   unchanged
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  return { rules, errors, total,     │   + taskIdsPendingEnable
│  taskIdsFailedToBeEnabled, ... }    │
└─────────────────────────────────────┘
```

`taskIdsFailedToBeEnabled` stays in the envelope but is **empty** in the
deferred mode (Phase 5 didn't run, so it can't have failed). The two arrays
are mutually exclusive — `taskIdsFailedToBeEnabled` is what Phase 5 *did*
attempt and failed, `taskIdsPendingEnable` is what Phase 5 *did not* attempt
and the caller still needs to.

### 2.3 Wrapper orchestration (importer side)

```text
                       ┌──────────────────────────────────┐
                       │  importRules(ruleChunks, …)      │
                       │  pendingTaskIds: string[] = []   │
                       │  taskIdToRuleId: Map<…>          │
                       └─────────────┬────────────────────┘
                                     │
              ┌──────────────────────┴──────────────────────┐
              │  for chunk of ruleChunks (sequential)        │
              │                                              │
              │   try {                                      │
              │     const r = await bulkImportRules({        │
              │       …,                                     │
              │       deferTaskEnable: true,                 │
              │     });                                      │
              │     pendingTaskIds.push(...r.taskIds);       │
              │     response.push(...r.responses);           │
              │   } catch (err) {                            │
              │     // hard batch failure: record per-rule   │
              │     // errors for THIS batch, KEEP GOING.    │
              │     for (const rule of chunk) {              │
              │       response.push(toImportError(rule, err))│
              │     }                                        │
              │   }                                          │
              └──────────────────────┬───────────────────────┘
                                     │ (loop exits after batch N)
                                     ▼
                       ┌──────────────────────────────────┐
                       │  if (pendingTaskIds.length > 0)  │
                       │    taskManager.bulkEnable(       │
                       │      pendingTaskIds              │
                       │    )                             │
                       │  → failed ids mapped back to     │
                       │    rule_id via taskIdToRuleId    │
                       │    and pushed as warnings.       │
                       └──────────────────────────────────┘
```

### 2.4 Timing — 1,000 rules / 20 batches

Per-batch foreground cost stays at roughly today's number; the win is that
**no rule is executing** in the background between batches.

```text
                    ────────── per-batch (50 rules) ──────────
batch  1  [fg]   Phases 1-4 + Phase 5 SKIPPED        ≈ 1.0s
batch  2     [fg]                                    ≈ 1.0s    (no contention)
batch  3        [fg]                                 ≈ 1.0s
   …                  …                                  …
batch 19                                  [fg]       ≈ 1.0s
batch 20                                     [fg]    ≈ 1.0s

t=0s    1s   2s   …                            19s  20s        21s
│       │    │    …                            │    │           │
│                                              │    │           │
│                              all 20 batches done — 1,000 SOs persisted,
│                              1,000 tasks scheduled but enabled:false.
│                                                                │
│                              taskManager.bulkEnable(1000 ids) ─┘  ≈ 0.5–1.5s
│
└── total: 20 × ~1s (no compounding contention) + 1 × bulkEnable
                                                          ≈ 20–22s
```

Contrast with today's behaviour, where every batch's Phase 5 makes 50 rules
start running, so batch *n*'s foreground is competing for the same indices
against `50 × (n − 1)` already-executing rule tasks. The compounding is the
reason throughput collapses.

### 2.5 What gets enabled at the end

Exactly one call:

```ts
const enableResult = await context.taskManager.bulkEnable(pendingTaskIds);
```

This is the **same `taskManager.bulkEnable`** that Phase 5 calls today
(via `tryToEnableTasks`). We are not introducing a new path, we are not
re-minting API keys (Phase 1 already did that per batch), we are not calling
`rulesClient.bulkEnableRules` (which would reload the SOs, mint *new* API
keys, validate again, and reintroduce the very contention we're avoiding).

Per-task failures returned by `bulkEnable` are mapped back to `rule_id` via
the `taskId → rule_id` map the wrapper built when constructing each batch's
inputs (the same map `bulkImportRules` already uses today to translate
`taskIdsFailedToBeEnabled` into `RuleImportErrorObject`s — see
`bulk_import_rules.ts:277-286`).

---

## 3. Failure semantics

> Design rule: **never lose work**. The 1,000-rule import case is the worst-case
> blast radius — a transient failure in batch 17 must not undo the 16 batches
> that did succeed, and it must not strand them indefinitely "scheduled but not
> enabled."

| Failure                                                 | Behaviour                                                                                                          |
|---------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| Per-row SO error inside a batch (e.g. 409 on caller-supplied id) | Same as today: per-rule error pushed, that rule's task removed (Phase 4 cleanup), its API key invalidated. The other 49 rules in the batch contribute their task ids to `pendingTaskIds`. |
| Whole-call SO `bulkCreate` throws inside a batch        | Same as today: that batch's keys are flushed, that batch's scheduled task ids are best-effort `bulkRemove`'d, the batch's `bulkCreateRules` throws. **Wrapper catches**, marks every rule in that batch as a failure, **continues to the next batch**. |
| Whole-call `bulkSchedule` throws inside a batch         | Same as today (Phase 3 already handles this): enabled subset is demoted to disabled within that batch, disabled subset still proceeds through Phase 4. No `pendingTaskIds` contribution from the demoted set. Batch returns normally. |
| Silent per-task drops from `bulkSchedule`               | Same as today: missing ids are diff'd against returned ids, those rules demoted to disabled, no `pendingTaskIds` contribution for them. |
| Final `taskManager.bulkEnable` partially fails          | Failed task ids surfaced as `taskIdsFailedToBeEnabled`-style warnings on the import response, mapped to `rule_id`. The rule SOs already exist with `enabled: true`; the caller can re-enable via the standard `bulkEnable` API. |
| Final `taskManager.bulkEnable` whole-call throws        | Wrapper catches, marks **all** `pendingTaskIds` as "rule created but task could not be enabled, please retry," pushes one warning per rule. Rules are persisted, tasks exist but stay disabled. The user-visible state is identical to running with `enabled: false` from the start; standard recovery is `bulkEnableRules({ ids })`. |
| Kibana process crashes mid-loop (before final enable)   | Rules persisted up to the last completed batch exist as enabled SOs whose tasks are `enabled: false`. **No detection coverage gap visible in the rule list as "enabled but not running"**, because — see §5 — the SO write itself sets `enabled: true`. The user can recover by re-issuing `bulkEnableRules` on the affected ids; the `bulkEnable` op is idempotent. |

The wrapper's `for` loop must wrap each batch in `try/catch` so a single bad
batch can't break out of the loop. The current `importRules` loop already
returns one response per chunk and pushes results into a flat array; the only
addition is the catch arm.

---

## 4. API shape changes

### 4.1 `BulkCreateRulesParams`

```ts
// x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/types.ts
export interface BulkCreateRulesParams<Params extends RuleParams = never> {
  rules: Array<BulkCreateRulesItem<Params>>;
  /**
   * When `true`, Phase 5 (taskManager.bulkEnable) is skipped. The successfully
   * persisted enabled rules' task ids are returned in `taskIdsPendingEnable`
   * for the caller to enable in one go after all batches have completed.
   *
   * Defaults to `false` (back-compat: existing callers like prebuilt rule
   * installation and single-batch importers see today's behaviour).
   */
  deferTaskEnable?: boolean;
}
```

### 4.2 `BulkCreateRulesResult`

```ts
export interface BulkCreateRulesResult<Params extends RuleParams = never> {
  rules: Array<SanitizedRule<Params>>;
  errors: BulkCreateOperationError[];
  total: number;
  /** Phase 5 outcome — populated only when `deferTaskEnable !== true`. */
  taskIdsFailedToBeEnabled: string[];
  /**
   * Task ids the caller now owns the responsibility to enable. Populated only
   * when `deferTaskEnable === true`. Mutually exclusive with
   * `taskIdsFailedToBeEnabled` (deferred → Phase 5 didn't run → can't fail).
   *
   * Contains exactly the ids satisfying:
   *   scheduledTaskIdsThisCall ∩ successfullyPersistedEnabled
   * i.e. the same set Phase 5 would have passed to `taskManager.bulkEnable`.
   */
  taskIdsPendingEnable?: string[];
}
```

### 4.3 Where the branch lives in `bulk_create_rules.ts`

Today, the file ends with:

```ts
// Phase 5: enable tasks for successfully persisted enabled rules.
const taskIdsFailedToBeEnabled = await tryToEnableTasks({
  taskIdsToEnable,
  logger,
  taskManager: context.taskManager,
});

// Single end-of-function flush for all collected key invalidations.
await flushKeysToInvalidate(keysToInvalidate, context);
```

The change is to make Phase 5 conditional and to populate
`taskIdsPendingEnable` instead when deferred:

```ts
let taskIdsFailedToBeEnabled: string[] = [];
let taskIdsPendingEnable: string[] | undefined;

if (params.deferTaskEnable) {
  taskIdsPendingEnable = taskIdsToEnable;
} else {
  taskIdsFailedToBeEnabled = await tryToEnableTasks({
    taskIdsToEnable,
    logger,
    taskManager: context.taskManager,
  });
}

// Single end-of-function flush for all collected key invalidations.
await flushKeysToInvalidate(keysToInvalidate, context);

// Phase 6
return {
  rules: sanitizedRules,
  errors,
  total,
  taskIdsFailedToBeEnabled,
  ...(taskIdsPendingEnable ? { taskIdsPendingEnable } : {}),
};
```

That's the only change inside the alerting plugin. **API key invalidation is
not deferred** — it still flushes per batch, which matters for transient
failures and process crashes: an abandoned import doesn't strand 1,000
unminted API keys in the to-invalidate queue.

---

## 5. Audit and SO state during the gap

Two questions deserve explicit answers because they're load-bearing for the
"is this safe?" argument.

### 5.1 Are rule SOs already `enabled: true` between Phase 4 and the final `bulkEnable`?

**Yes.** Phase 1 builds the rule attributes with `enabled: true` for the
enabled subset (matching `bulkEnableRulesWithOCC`'s pattern), and Phase 4
writes those attributes verbatim. There is no separate "flip the SO to
enabled" step after `bulkEnable` succeeds. This means:

- The rule list shows the rule as enabled the moment its batch's Phase 4
  completes.
- The associated task exists in `.kibana_task_manager` with `enabled: false`.
- The user-visible state during the gap is identical to a rule that was
  enabled, then had its task manually disabled — which is the same intermediate
  state `bulkEnableRules` exposes between its Phase 4 (SO write) and Phase 5
  (`bulkEnable`).

This is the load-bearing distinction from
[`bulk_create_rules_deferred_serial_flow.md`](./bulk_create_rules_deferred_serial_flow.md):
the sibling pattern delays both the SO write *and* the schedule, so the rule
doesn't exist for the duration of the gap. **Here, the rule exists, has a
task, and is just waiting for the task to be enabled.** A crash during the
gap leaves a perfectly normal "enabled rule, disabled task" state that the
standard `bulkEnableRules` API can recover from idempotently.

### 5.2 Audit events

`bulk_create_rules.ts` emits two audit events per enabled rule:

- `RuleAuditAction.CREATE` — emitted before persistence for **every** rule
  in `preparedRules`, outcome `unknown` (lines 192-201).
- `RuleAuditAction.ENABLE` — emitted in the Phase 4 success branch for any
  rule whose task is in `newlyScheduledTaskIds`, outcome `unknown` (lines
  269-281).

Both should keep firing per-batch in deferred mode. The `ENABLE` audit reflects
**user intent** (the caller asked for an enabled rule and we successfully
prepared everything required to enable it). It does not reflect the moment the
task starts running. Today's outcome is already `unknown`, which accommodates
the case where Phase 5 fails per-task — the deferred flow is the same shape,
just with the failure window pushed later.

If a stricter audit signal is wanted, the final `bulkEnable` call's per-task
failures can additionally emit `RuleAuditAction.ENABLE` with `outcome:
'failure'` for the failed ids, but this is incremental and out of scope for the
contention-fix.

---

## 6. What this flow deliberately does **not** do

Each of these was considered and rejected; spelling them out so future readers
don't relitigate.

| Tempting change                                               | Why we don't                                                                                                                                                                                                                |
|---------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Defer `bulkSchedule` too                                      | Tasks are inert with `enabled: false`. Scheduling them per batch costs one `.kibana_task_manager` write per batch and **stops there** — no compounding contention. Deferring them recreates the latency/crash issues from `bulk_create_rules_deferred_serial_flow.md` for no contention saving. |
| Defer `bulkCreateRulesSo` too                                 | Same as above plus an enormous in-memory accumulator (1,000 prepared rule SO objects, each with attributes + references). Memory pressure is exactly what batching is meant to avoid. Also defers all CREATE audit events to the end.                                                          |
| Defer API key invalidation across batches                     | Per-batch failure paths (per-row 409, `validateScheduleLimit` demotion) mint keys that should be invalidated promptly. Deferring an invalidation queue across an entire 1,000-rule import inflates the security plugin's pending-invalidation list and worsens the crash-loss surface.        |
| Run batches in parallel                                       | Even with `enabled: false`, parallel batches contend on `.kibana_task_manager` and `.kibana_alerting_cases*` writes. The contention isn't from task *execution* anymore but from concurrent SO bulk writes. User explicitly chose sequential, and the gain is small.                          |
| Call `rulesClient.bulkEnableRules` at the end instead of `taskManager.bulkEnable` | Mints fresh API keys (the second time, after Phase 1 already did), reloads all SOs via the ESO point-in-time finder (decryption pass over 1,000 rules), runs an OCC retry loop, and writes every SO again. All of that recreates the contention we're trying to avoid.            |
| Make `deferTaskEnable` the default                            | Existing callers (`bulkCreatePrebuiltRules`, single-batch importers, future direct callers) rely on the all-in-one semantics. Opt-in keeps the change additive.                                                                                                                              |

---

## 7. Concrete implementation checklist

1. **Alerting plugin** (`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/`):
   - `types.ts` — add `deferTaskEnable?: boolean` to `BulkCreateRulesParams`,
     add `taskIdsPendingEnable?: string[]` to `BulkCreateRulesResult`.
   - `bulk_create_rules.ts` — branch around the Phase 5 call as shown in §4.3.
   - Unit tests:
     - `deferTaskEnable: true` does not call `taskManager.bulkEnable`.
     - `deferTaskEnable: true` populates `taskIdsPendingEnable` with the
       intersection `scheduledTaskIdsThisCall ∩ successfullyPersistedEnabled`.
     - `taskIdsFailedToBeEnabled` is `[]` in deferred mode.
     - `deferTaskEnable: undefined` / `false` behaves exactly as today.
     - Per-row SO failure in deferred mode still removes the orphan task and
       invalidates the API key, and excludes that id from `taskIdsPendingEnable`.

2. **Security wrapper — `bulkImportRules`** (`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_import_rules.ts`):
   - Accept a `deferTaskEnable?: boolean` option from the caller.
   - When `true`, pass it through to `rulesClient.bulkCreateRules`, and
     return both the per-chunk `responses` and the chunk's
     `taskIdsPendingEnable` plus the chunk's `taskId → rule_id` map.
   - When `false`/absent, return today's shape unchanged.

3. **Security wrapper — `importRules`** (`.../logic/import/import_rules.ts`):
   - Replace the current loop's behaviour for the bulk branch:
     - Accumulate `pendingTaskIds: string[]` and a flat `taskIdToRuleId: Map<string, string>` across chunks.
     - Wrap each chunk's `bulkImportRules` call in `try/catch`; on catch, push
       one error response per rule in that chunk and continue.
   - After the loop, if `pendingTaskIds.length > 0`:
     - Call `taskManager.bulkEnable(pendingTaskIds)`.
     - On per-task error, push a warning per mapped `rule_id`.
     - On whole-call throw, push a warning per mapped `rule_id` (rule created,
       enable failed, can retry).
   - Tests:
     - 20 batches × 50 rules → exactly one `taskManager.bulkEnable` call with
       1,000 ids (assert call count and argument length).
     - A throwing batch in the middle does not stop the loop and does not
       prevent the final `bulkEnable` for prior batches.
     - Final `bulkEnable` partial failure produces correct per-`rule_id`
       warnings.

4. **Behavioural observation worth capturing in a benchmark test**: import
   1,000 rules with the current implementation vs the deferred-enable
   implementation, assert wall-clock and aggregate index-write counts on
   `.kibana_alerting_cases*` between batch boundaries. The deferred-enable
   version should show **zero** writes to that index between batches' Phase 4
   and the final `bulkEnable`.

---

## 8. Summary

- The bottleneck is **Phase 5 making tasks start executing while subsequent
  batches' Phase 3/4 writes are still in flight on the same indices**.
- The minimum fix is to add a `deferTaskEnable` option to
  `bulkCreateRules`, have the security importer's per-chunk loop pass
  `deferTaskEnable: true`, accumulate `taskIdsPendingEnable` across chunks,
  and call `taskManager.bulkEnable` exactly once after the loop completes.
- Every other phase remains per-batch, including API key invalidation, audit,
  demotion handling, and per-row SO error cleanup. The SO state is
  `enabled: true` from the moment Phase 4 succeeds for that rule, so the
  visible "rule list" stays consistent throughout the import.
- Failure semantics preserve work: a bad batch does not abort the loop, and
  the final `bulkEnable` is best-effort with per-task error mapping back to
  `rule_id`. Partial state on crash is recoverable through the existing
  `bulkEnableRules` API.
- The change is additive (opt-in via flag) and confined to one method in the
  alerting plugin plus the importer's loop.
