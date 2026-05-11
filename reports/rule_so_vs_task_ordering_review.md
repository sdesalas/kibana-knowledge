# Rule SO ↔ Task Manager write ordering across rules‑client methods

## Scope

This report compares the **order** in which the alerting rules client writes to the
**rule saved object** (in `.kibana`) and to the **Task Manager task** (in
`.kibana_task_manager`).

The starting hypothesis from the reviewer is that there are **two distinct
philosophies** in the codebase, split along the single‑vs‑bulk axis:

> - **Single write** → write rule SO (as enabled), then create TM task as
>   enabled.
> - **Bulk write** → create TM tasks (as disabled), write rule SO (as
>   enabled), then enable tasks.

The conclusion below is that the **split is real** and lines up exactly with
single‑vs‑bulk. The bulk path is the only one that splits scheduling and
enabling into two TM calls; in the single path scheduling and enabling are a
single atomic TM call. The "why" section at the end explains the engineering
reasons that drove the split.

Across the entire rules client surface, only a handful of methods can move a
rule into the enabled state or schedule its TM task. The table below
enumerates them and notes when (and how) each one touches TM:

| Method | Can enable a rule? | Schedules TM task? | When TM is touched |
|---|---|---|---|
| `enable_rule` | Yes — primary single‑rule path | Yes | `scheduleTask` if no task exists or the existing one is `Unrecognized`; otherwise `bulkEnable` on the existing task id |
| `bulk_enable_rules` | Yes — primary bulk path | Yes | `bulkSchedule` (created `enabled: false`) for missing/`Unrecognized` tasks, then `bulkEnable` to activate (with randomised `runAt`) |
| `create_rule` | Implicitly, when caller passes `enabled: true` | Yes | `scheduleTask` (created `enabled: true`), only when the input `enabled === true`; skipped for disabled creates |
| `clone_rule` | Implicitly, mirrors `create_rule` (delegates to `createRuleSavedObject`) | Yes | Same path as `create_rule`; preserves source rule's `enabled` value |
| `bulk_create_rules` (excluded — WIP on this branch) | Implicitly, when input `enabled: true` | Yes | `bulkSchedule` after SO `bulkCreate`; demotes SOs to `enabled: false` on schedule failure |

Methods that explicitly **cannot** enable a rule (so they are out of scope of
this report): `update_rule` (preserves `enabled`, only retunes existing task
schedule), `bulk_edit_rules` (`enabled` not in `BulkEditFields`),
`bulk_edit_rule_params`, `disable_rule` / `bulk_disable_rules`,
`delete_rule` / `bulk_delete_rules`, `run_soon`, `update_api_key`.

The four in‑scope methods analysed below are `create_rule`, `clone_rule`,
`enable_rule`, and `bulk_enable_rules`. `bulk_create_rules` is excluded as
requested (work in progress on this branch).

For the wider context (compensating deletes, demotion, task‑runner self‑healing,
the consistency target the system aims for), see
[`.knowledge/architecture/rule_so_task_consistency.md`](../architecture/rule_so_task_consistency.md).

## Two philosophies, more in-depth

> - **Single‑write philosophy** → write rule SO (as enabled) → create TM
>   task as enabled (single `scheduleTask` call) → patch SO with the
>   resulting `scheduledTaskId`. Compensating SO delete on TM failure for
>   `create`/`clone`; nothing for `enable`.
> - **Bulk‑write philosophy** → `bulkSchedule` the missing tasks as
>   disabled → `bulkCreate` the SOs (enabled, with `scheduledTaskId`
>   already filled in) → `bulkEnable` the tasks (now activated and
>   staggered). No compensation.


The four methods cluster cleanly into two ordering patterns. The split lines
up with single‑rule vs bulk‑rule operations, exactly as the reviewer
suspected.

### Philosophy A — single‑write: SO‑first, then create TM task as enabled

**Members:** `create_rule`, `clone_rule`, `enable_rule` (new‑task path) +
`enable_rule` (existing‑task path, which is a degenerate version that
re‑uses an existing task via `bulkEnable` instead of creating one).

```
   ┌──────────────────────────────────────────────┐
   │ Caller wants enabled rule X (single)         │
   └──────────────────────┬───────────────────────┘
                          │
                          v
        ┌─────────────────────────────────────┐
        │  SO write: rule.enabled = true      │
        │  (scheduledTaskId not yet known)    │
        └────────────────────┬────────────────┘
                             │
                             v
        ┌─────────────────────────────────────┐
        │  TM: scheduleTask({ enabled:true }) │   <-- 1 TM call, task born enabled
        └────────────────────┬────────────────┘
                             │
                  scheduleTask failed?
                  ┌──────────┴──────────┐
              yes │                     │ no
                  v                     v
        ┌──────────────────┐  ┌─────────────────────────────┐
        │ Compensating SO  │  │  SO update: write           │
        │ delete           │  │  scheduledTaskId            │
        │ (create+clone    │  │  (skipped in enable's       │
        │  only;           │  │   existing‑task path,       │
        │  enable: none)   │  │   which uses bulkEnable     │
        └──────────────────┘  │   instead of scheduleTask)  │
                              └─────────────────────────────┘
```

| Method | Step 1: SO write | Step 2: TM | Step 3: SO follow‑up | Compensation on TM failure | Notes |
|---|---|---|---|---|---|
| `create_rule` | `createRuleSo` writes SO with caller's `enabled` flag, no task id | `scheduleTask` — creates task with `enabled: true` (only if SO had `enabled: true`) | `updateRuleSo({ scheduledTaskId })` | **Best‑effort `deleteRuleSo`**; logs on failure of the cleanup itself | Originating pattern, [PR #37042](https://github.com/elastic/kibana/pull/37042) (June 2019) |
| `clone_rule` | Identical to `create_rule` (delegates to `createRuleSavedObject`) | Identical | Identical | Identical | Inherits create's compensating delete; preserves source rule's `enabled` value |
| `enable_rule` (new task path) | `update` writes `enabled: true` (no task id change yet) | `scheduleTask` — creates task with `enabled: true` | `update` SO with new `scheduledTaskId` | **None** — partial failure leaves "enabled, no task" silent‑dead rule | New‑task branch fires when `scheduledTaskId` is null or task is missing/Unrecognized |
| `enable_rule` (existing task path) | `update` writes `enabled: true` | `taskManager.bulkEnable([scheduledTaskId])` (no `scheduleTask`) | (none) | **None** — TM failure leaves SO `enabled: true` while task stays disabled | Degenerate single‑task variant of the bulk path's third step |

Common shape across all of philosophy A:

- **One SO write before TM.** The SO claim that the rule is enabled is
  committed before any TM work happens.
- **TM creates the task as enabled in one call.** `scheduleTask` writes the
  task with `enabled: true` directly (see `rules_client/lib/schedule_task.ts`
  line 29). The degenerate existing‑task branch of `enable_rule` substitutes
  a single `bulkEnable` for the same effect.
- **Optional second SO write** to attach the freshly generated
  `scheduledTaskId`. This *is* gated on TM confirmation.
- **Compensation is per‑method.** `create` and `clone` undo the SO if TM
  fails; `enable` does not.

### Philosophy B — bulk‑write: TM schedule first (disabled), then SO, then TM enable

**Members:** `bulk_enable_rules` (the only in‑scope bulk method that schedules
new tasks).

```
   ┌──────────────────────────────────────────────┐
   │ Caller wants N enabled rules (bulk)          │
   └──────────────────────┬───────────────────────┘
                          │
                          v
        ┌─────────────────────────────────────┐
        │  TM: bulkSchedule(tasks, enabled:   │   <-- batch #1, all created disabled
        │  false) — only for rules whose      │
        │  task is missing or Unrecognized    │
        └────────────────────┬────────────────┘
                             │
                             v
        ┌─────────────────────────────────────┐
        │  SO bulkCreate({ overwrite:true })  │   <-- one SO round‑trip for all rules,
        │  writes enabled:true AND            │       carrying scheduledTaskId = rule.id
        │  scheduledTaskId for every rule     │
        └────────────────────┬────────────────┘
                             │
                             v
        ┌─────────────────────────────────────┐
        │  TM: bulkEnable(taskIds) — flips    │   <-- batch #2, also randomises runAt
        │  tasks to enabled:true,             │       to avoid stampede
        │  staggers their runAt               │
        └─────────────────────────────────────┘

        (No compensating cleanup if any of the three steps partially fails —
         the gap called out in the architecture doc.)
```

| Method | Step 1: TM schedule | Step 2: SO write | Step 3: TM enable | Compensation on failure | Notes |
|---|---|---|---|---|---|
| `bulk_enable_rules` | `taskManager.bulkSchedule(tasks)` with each task `enabled: false`. Only invoked for rules with missing or `Unrecognized` task. | `bulkCreateRulesSo({ overwrite: true })` writes `enabled: true` and `scheduledTaskId` for every rule in the batch | `taskManager.bulkEnable(taskIdsToEnable)` flips tasks to `enabled: true`, randomising `runAt` to avoid the stampede | **None** — partial `bulkSchedule` still proceeds to the SO write; surviving rules of a partial failure end up "enabled, no task" | Two‑step TM dance is the runAt‑stagger pattern from [PR #174656](https://github.com/elastic/kibana/pull/174656) (Jan 2024); per‑rule self‑healing comes from `getShouldScheduleTask` ([PR #152975](https://github.com/elastic/kibana/pull/152975)) |

Common shape of philosophy B (currently a one‑member club among in‑scope
methods, but also the shape `bulk_disable_rules` mirrors on the deletion
side, and the shape `bulk_create_rules` deliberately rejected in favour of
persist‑first‑with‑demotion):

- **TM schedule precedes SO write.** Tasks are created (disabled) before any
  rule SO claims they exist.
- **SO write is one big batch.** `bulkCreate` with `overwrite: true` is
  effectively idempotent on retry.
- **Enable is a separate TM round‑trip.** Step 3 exists specifically so the
  randomised `runAt` from `bulkEnable` can prevent thundering‑herd starts.
- **No compensation.** All three steps are best‑effort; partial failure
  yields the silent "enabled, no task" state until a user re‑enables.

## Why two philosophies?

The split is not historical accident (see the
**Appendix: Commit‑history evidence for philosophy B** at the end of this
document for the three commits that prove it). 

The sections below cover one underlying constraint and four 
engineering pressures it produces, all of which push the bulk 
path away from philosophy A. 

> ### Underlying constraint: no cross‑index transactions
> The premise underneath everything is that **Elasticsearch is not a relational 
> database and gives Kibana no transactional guarantees across 
> the two indices that matter here.**

The rule SO lives in `.kibana` and the TM task lives in `.kibana_task_manager`.
Elasticsearch offers neither cross‑index transactions nor per‑document MVCC
across indices, and Kibana does not run a saga / two‑phase‑commit layer over
the saved‑objects client and the task‑manager client. 

The four pressures below are best read as "given that there are no
transactions, which compensating pattern can each path afford?" — not as
independent reasons.

### 1. Compensating rollback doesn't generalise to bulk

The 2019 origin of the single‑create pattern ([PR #37042](https://github.com/elastic/kibana/pull/37042), evidence #1 in the
architecture doc) is "if `scheduleTask` fails, delete the rule SO we just
wrote, throw the TM error to the user." That works because:

- One SO write to undo, one TM call to fail, one error to surface.
- The user's mental model is "the create either succeeded or it didn't."
- A best‑effort `deleteRuleSo` at the end of an exception path is cheap and
  obviously correct.

For bulk, the analogous compensation would be: "if some of the
`bulkSchedule` calls fail, delete the corresponding rule SOs we just wrote."
That's much harder:

- The SOs may have been concurrently modified by another writer between
  `bulkCreate` and the rollback `bulkDelete`. Deleting them blind would
  destroy user changes.
- `bulkCreate` with `overwrite: true` may have *replaced* an existing rule
  rather than created a new one — rolling that back is much worse than
  leaving it.
- The user mental model is "I asked you to enable 500 rules; some of them
  worked." Surfacing partial success is fine; silently rolling some of them
  back to a different state is not.

So bulk picks a different bias: **TM first, so partial failure happens
before the visible SO change**. If `bulkSchedule` partially fails, the SO
write proceeds anyway and the user gets the silent‑dead‑rule failure mode
(which `getShouldScheduleTask` repairs on the next bulk enable, plus the
task‑runner gates handle the inverse drift).

### 2. RunAt stampede prevention forces the two‑step TM dance

This is the dominant reason and is explicitly documented in the commit
history (see **Appendix: Commit‑history evidence for philosophy B** at the
end of this document for the three commits and the verbatim PR description).
[PR #172742](https://github.com/elastic/kibana/pull/172742)
(Dec 2023) gave `taskManager.bulkEnable` a per‑task random `runAt` offset.
[PR #174656](https://github.com/elastic/kibana/pull/174656) (Jan 2024) then reshaped the rules‑client side to actually use
it, by replacing the inline `scheduleTask` (which created tasks enabled and
therefore got skipped by `bulkEnable`) with a `bulkSchedule` that creates
tasks disabled. The commit message of [PR #174656](https://github.com/elastic/kibana/pull/174656) spells this out:

> as we create the tasks already enabled, `bulkEnable` method of the TM
> skips them. This PR replaces `scheduleTask` with `bulkSchedule` and
> creates task as disabled, so `bulkEnable` can pick them up.

Concretely: if you scheduled 500 tasks with `enabled: true` and
`runAt: now`, all 500 would race to be claimed by the first poll cycle,
hammering ES and starving the cluster. Creating them disabled and then
`bulkEnable`ing them lets TM stagger their `runAt` over the polling
interval so they trickle in.

The single path doesn't have this problem — one task, one `runAt`, no
herd — so it can keep the simpler `enabled: true` at creation time. The
bulk path's three‑step shape (`bulkSchedule` disabled → SO write →
`bulkEnable`) is the cost of stampede prevention.

### 3. SO write granularity favours different orderings

A single SO `update` is OCC‑version‑checked end‑to‑end. The retry loop
(`retryIfConflicts`) wraps the *entire* operation, so SO‑first‑then‑TM is
fine: if a concurrent writer bumps the version, the whole thing replays from
scratch.

A bulk SO `bulkCreate({ overwrite: true })` doesn't have per‑document OCC
that re‑reads on conflict — it just overwrites. The framework's
`retryIfBulkOperationConflicts` retries the whole batch on conflict, but the
window between "decide attributes" and "write attributes" is wider in bulk
(the `pMap` over hundreds of rules takes time). Putting `bulkSchedule`
*first* means by the time the SO write happens, you've already paid for the
expensive TM round‑trip and you want the SO write to be one fast,
overwriting, idempotent‑on‑retry call. SO‑first would mean carrying the
freshly‑generated `scheduledTaskId`s around and updating the SOs again, which
defeats the batching.

### 4. Distance from caller acknowledgement

Single methods return one result; bulk methods return `{ rules, errors }`.
The implicit contract is different:

- Single: "either it worked or it didn't, errors throw." The SO write is the
  caller's acknowledgement; if TM fails after, we hide it by rolling back the
  SO and throwing the TM error. The caller never sees the partial state.
- Bulk: "some succeeded, some didn't, here's the list." The caller is
  *expected* to inspect `errors` and `taskIdsFailedToBeEnabled`. There's no
  contract that says "if any TM step fails, no SOs change." So bulk doesn't
  bother trying to roll back; it just reports what worked.

This is why bulk_enable's `tryToEnableTasks` returns a
`taskIdsFailedToBeEnabled` array all the way up to the caller, while single
enable just throws.

### Summary of the "why"

- **Underlying constraint:** ES has no cross‑index transactions; everything
  below is a workaround for that one fact.
- **Compensation cost:** single rollback is cheap and unambiguous; bulk
  rollback is expensive and dangerous.
- **Stampede prevention:** bulk needs the disabled‑then‑staggered‑enable
  dance; single doesn't.
- **SO write granularity:** single SO writes are OCC‑safe end‑to‑end; bulk
  SO writes want to be one big idempotent overwrite at the end.
- **Caller contract:** single throws, bulk returns partial errors — so the
  ordering optimises for different failure surfaces.

Philosophy A is what you do when you can roll back. Philosophy B is what you
do when you can't, so you fail fast in TM before touching SOs visibly, and
then accept that the residual silent‑dead‑rule case has to be repaired
on the next user‑triggered bulk enable. 

With ACID across indices, neither philosophy would need to exist in
this shape — both are deliberate non‑transactional workarounds.

| ES limitation | Code pattern it forces |
|---|---|
| No rollback across SO + TM | **Compensating delete** in `createRuleSavedObject` ([PR #37042](https://github.com/elastic/kibana/pull/37042)) — the only available "undo." Best‑effort; can itself fail and just logs. |
| No rollback across N SOs + N tasks | **Demotion** in `bulk_create_rules` instead of rollback — flip the SOs to `enabled: false` rather than try to delete them, because deleting overwritten/concurrent SOs is unsafe. |
| Can't enforce "task exists ⇔ SO references it" | **Deterministic task id = rule id**, so re‑scheduling is idempotent and no orphaned references can leak. |
| Can't enforce "SO write and TM write happen together" | **Choose which failure mode you prefer**: SO‑first (single) optimises for visible rollback; TM‑first (bulk) optimises for fail‑fast before SOs change. Either way one of the two stores can drift if the process dies between writes. |
| Can't atomically retry both writes | **`overwrite: true` on `bulkCreate`** + **`retryIfBulkOperationConflicts`** — the SO write is engineered to be idempotent on replay. TM operations are similarly idempotent (re‑schedule with same id is a no‑op or replaces). |
| Can't detect drift transactionally | **Task runner self‑healing** as the second line of defence: `getDecryptedRule` → `Unrecoverable`, `Disabled` → `shouldDisableTask`, id mismatch → `shouldDeleteTask`. The runner is essentially an eventual‑consistency reconciler because eager consistency is unavailable. |


## Appendix: Per‑method ordering

The walkthroughs below are the source material for the philosophy summaries
above. Each one shows the actual writes a method performs in the order they
happen, with the code snippets that produce that order.

### A1. `create_rule.ts` → `createRuleSavedObject`

The actual writes happen inside
`x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts`,
which `create_rule.ts` calls at line 249–260.

```62:139:x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts
  let createdAlert: SavedObject<RawRule>;
  try {
    createdAlert = await withSpan(
      { name: 'unsecuredSavedObjectsClient.create', type: 'rules' },
      () =>
        createRuleSo({
          ruleAttributes: updateMeta(context, rawRule),
          ...
        })
    );
  } catch (e) {
    // Avoid unused API key
    ...
    throw e;
  }
  if (rawRule.enabled) {
    let scheduledTaskId: string;
    try {
      const scheduledTask = await scheduleTask(context, {
        id: createdAlert.id,
        ...
      });
      scheduledTaskId = scheduledTask.id;
    } catch (e) {
      // Cleanup data, something went wrong scheduling the task
      try {
        await deleteRuleSo({ ... id: createdAlert.id });
      } catch (err) {
        context.logger.error(
          `Failed to cleanup rule "${createdAlert.id}" after scheduling task failed. Error: ${err.message}`
        );
      }
      throw e;
    }

    await withSpan({ name: 'unsecuredSavedObjectsClient.update', type: 'rules' }, () =>
      updateRuleSo({
        ...
        updateRuleAttributes: { scheduledTaskId },
      })
    );
    createdAlert.attributes.scheduledTaskId = scheduledTaskId;
  }
```

Order:

1. **SO write** — `createRuleSo` writes the rule SO (with `enabled` from the
   caller, no `scheduledTaskId` yet).
2. **TM write** — `scheduleTask` schedules a new task. The task is created
   **already enabled** in a single TM call (see
   `rules_client/lib/schedule_task.ts` line 29: `enabled: true`). On failure:
   compensating `deleteRuleSo` (best‑effort).
3. **SO update** — `updateRuleSo` patches `scheduledTaskId` onto the rule.

So this method is **SO → TM (created enabled) → SO**. The first SO write
happens before TM, but the SO update that records `scheduledTaskId` is gated
on TM confirmation. There is no separate "enable task" step — `scheduleTask`
hard‑codes `enabled: true`.

### A2. `clone_rule.ts`

`clone_rule` reads the source rule, builds a fresh `RawRule` (resetting
`scheduledTaskId: null`, `revision: 0`, monitoring state, etc.) and then
delegates to **the exact same `createRuleSavedObject` helper** that
`create_rule` uses:

```164:174:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/clone/clone_rule.ts
  const clonedRuleAttributes = await withSpan(
    { name: 'createRuleSavedObject', type: 'rules' },
    () =>
      createRuleSavedObject(context, {
        intervalInMs: parseDuration(ruleAttributes.schedule.interval),
        rawRule: ruleAttributes,
        references: ruleSavedObject.references,
        ruleId,
        returnRuleAttributes: true,
      })
  );
```

So clone inherits the **SO → TM (created enabled) → SO** ordering verbatim,
including the compensating `deleteRuleSo` if `scheduleTask` fails. The only
difference from `create_rule` is the source of the `RawRule` (cloned from an
existing one rather than built from caller input).

A subtlety: clone preserves the source rule's `enabled` attribute (it is
copied via `...sourceAttributes` at line 138 and never overridden), so cloning
a disabled rule produces a disabled rule and skips the TM write entirely
(same `if (rawRule.enabled)` gate as create).

### A3. `enable_rule.ts` (single enable)

```142:253:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/enable_rule/enable_rule.ts
  if (attributes.enabled === false) {
    ...
    const updateAttributes = updateMeta(context, {
      ...
      enabled: true,
      updatedBy: username,
      updatedAt: nowIso,
      lastEnabledAt: nowIso,
      executionStatus: { status: 'pending', ... },
    });

    try {
      if (migratedIds.includes(alert.id)) {
        await context.unsecuredSavedObjectsClient.create<RawRule>( ... { id, overwrite: true, version, references: alert.references });
      } else {
        await context.unsecuredSavedObjectsClient.update( ... updateAttributes, { version });
      }
    } catch (e) { throw e; }
  }

  let scheduledTaskIdToCreate: string | null = null;
  if (attributes.scheduledTaskId) {
    try {
      const task = await context.taskManager.get(attributes.scheduledTaskId);
      if (task.status === TaskStatus.Unrecognized) {
        await context.taskManager.removeIfExists(attributes.scheduledTaskId);
        scheduledTaskIdToCreate = id;
      }
    } catch (err) {
      scheduledTaskIdToCreate = id;
    }
  } else {
    scheduledTaskIdToCreate = id;
  }

  if (scheduledTaskIdToCreate) {
    const scheduledTask = await scheduleTask(context, { id, ... });
    await context.unsecuredSavedObjectsClient.update(RULE_SAVED_OBJECT_TYPE, id, {
      scheduledTaskId: scheduledTask.id,
    });
  } else {
    await context.taskManager.bulkEnable([attributes.scheduledTaskId!]);
  }
```

Order, branching on whether a fresh task is needed:

- **Always first**: SO update sets `enabled: true` and refreshes API key /
  metadata (line 204 or `create … overwrite: true` at line 193 for
  legacy‑actions migration).
- **New‑task branch** (line 238–249): TM `scheduleTask` → SO update with the
  new `scheduledTaskId`.
- **Existing‑task branch** (line 252): TM `bulkEnable` only, no further SO
  update.

So:

- New‑task path: **SO (enabled=true) → TM (schedule) → SO (scheduledTaskId)**.
- Existing‑task path: **SO (enabled=true) → TM (bulkEnable)**.

There is **no compensating cleanup** in either branch. If `scheduleTask` or
`bulkEnable` fails after the SO has been flipped to `enabled: true`, the rule
is in row #3/#4 of the architecture doc's state matrix until a user re‑enables.

### A4. `bulk_enable_rules.ts` (bulk enable)

The flow has two layers: `bulkEnableRulesWithOCC` (run inside
`retryIfBulkOperationConflicts`) and `bulkEnableRules` (the wrapper that
invokes `tryToEnableTasks` after the OCC retry returns).

```212:362:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts
      await pMap(
        rulesFinderRules,
        async (rule) => {
          ...
          const shouldScheduleTask = await getShouldScheduleTask(
            context,
            rule.attributes.scheduledTaskId
          );

          if (shouldScheduleTask) {
            tasksToSchedule.push({
              id: rule.id,
              taskType: `alerting:${rule.attributes.alertTypeId}`,
              ...
              enabled: false, // we create the task as disabled, taskManager.bulkEnable will enable them by randomising their schedule datetime
            });
          }

          rulesToEnable.push({ ...rule, attributes: updatedAttributes });
          ...
        },
        { concurrency: MAX_RULES_TO_UPDATE_IN_PARALLEL }
      );

  if (tasksToSchedule.length > 0) {
    await withSpan({ name: 'taskManager.bulkSchedule', type: 'tasks' }, () =>
      context.taskManager.bulkSchedule(tasksToSchedule)
    );
  }

  const result = await withSpan(
    { name: 'unsecuredSavedObjectsClient.bulkCreate', type: 'rules' },
    () =>
      bulkCreateRulesSo({
        savedObjectsClient: context.unsecuredSavedObjectsClient,
        bulkCreateRuleAttributes: rulesToEnable as Array<SavedObjectsBulkCreateObject<RawRule>>,
        savedObjectsBulkCreateOptions: { overwrite: true },
      })
  );
```

Then back in the wrapper at line 116–122:

```116:122:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts
  const [taskIdsToEnable] = accListSpecificForBulkOperation;

  const taskIdsFailedToBeEnabled = await tryToEnableTasks({
    taskIdsToEnable,
    logger: context.logger,
    taskManager: context.taskManager,
  });
```

Order:

1. **TM write #1** — `taskManager.bulkSchedule(tasksToSchedule)` for any rule
   whose task is missing or `Unrecognized`. Tasks are created with
   `enabled: false`.
2. **SO write** — `bulkCreateRulesSo({ overwrite: true })` writes every rule's
   SO with `enabled: true` and `scheduledTaskId: rule.id`.
3. **TM write #2** — `taskManager.bulkEnable(taskIdsToEnable)` flips the
   resulting tasks to `enabled: true` (also randomising `runAt`).

So this method is **TM → SO → TM**. The hypothesis ("TM first, then SO once
TM is confirmed") matches if you stop reading after step 2: TM is touched
before the SO write that announces `enabled: true`.

There is no compensating cleanup if step 1 partially fails (the gap called
out in the architecture doc).

## Appendix: Commit‑history evidence for philosophy B

Running `git log --follow` on `bulk_enable_rules.ts` (and the pre‑split
location `x-pack/plugins/alerting/server/rules_client/methods/bulk_enable.ts`,
plus its in‑line ancestor in `rules_client.ts`) gives a clean three‑step
origin story for the TM‑first bulk pattern. The commits below are in
chronological order.

### Commit 1 — [`e76f15c5`](https://github.com/elastic/kibana/commit/e76f15c557165c8196fdfa557d6a51702db944ce) "[RAM] bulk enable rules api ([#144216](https://github.com/elastic/kibana/pull/144216))" (Nov 2022)

The originating commit for `bulkEnableRules`. Important for the hypothesis:
**this version did not yet match philosophy B**. It used the same
`scheduleTask` helper (`enabled: true`) as the single path, but called it
**per rule, inline in the `pMap` loop**, before any `bulkCreate`:

```js
// from rules_client.ts at e76f15c5 (lines added by PR #144216)
const shouldScheduleTask = await this.getShouldScheduleTask(
  rule.attributes.scheduledTaskId
);
let scheduledTaskId;
if (shouldScheduleTask) {
  const scheduledTask = await this.scheduleTask({
    id: rule.id,
    consumer: rule.attributes.consumer,
    ruleTypeId: rule.attributes.alertTypeId,
    schedule: rule.attributes.schedule as IntervalSchedule,
    throwOnConflict: false,
  });
  scheduledTaskId = scheduledTask.id;
}

rulesToEnable.push({
  ...rule,
  attributes: {
    ...updatedAttributes,
    ...(scheduledTaskId ? { scheduledTaskId } : undefined),
  },
});
// …after the loop:
const result = await this.unsecuredSavedObjectsClient.bulkCreate(rulesToEnable, {
  overwrite: true,
});
// …then bulkEnable on the *previously existing* task ids only.
```

So in late 2022, bulk enable was philosophy A repeated `N` times with a
batched final SO write — TM was created **enabled** per‑rule before the SO
write that referenced it. The current shape did not exist yet.

### Commit 2 — [`00a2f49e`](https://github.com/elastic/kibana/commit/00a2f49e68d73a48eaaf782f02e6dc90288aa5f6) "[Task Manager] Evenly distribute bulk‑enabled alerting rules ([#172742](https://github.com/elastic/kibana/pull/172742))" (Dec 2023)

A pure Task Manager change — no rules‑client edits. From the commit message:

> When `bulkEnable`ing more than 1 task, adds a random delay to each
> subsequent task's `runAt` and `scheduledAt` to more evenly distribute their
> execution times. This offset is a maximum of 5 minutes, or the task's
> interval, whichever is shorter. […] this is a random distribution of
> execution times instead of a predictable, algorithmic offset. We believe
> that a random distribution will do a better job of avoiding spikes than
> anything more directed.

This commit gave `taskManager.bulkEnable` the stampede‑prevention
super‑power, but it was wasted on bulk enable as it stood — because tasks
were being created enabled inline, `bulkEnable` had nothing to flip and
skipped them.

### Commit 3 — [`e3fed0c0`](https://github.com/elastic/kibana/commit/e3fed0c0c17e6150442b2568cb13abd02d62d8d4) "Evenly distribute bulk‑enabled alerting rules ([#174656](https://github.com/elastic/kibana/pull/174656))" (Jan 2024)

This is the commit that **established philosophy B as it exists today**. The
commit message reads almost verbatim like the "why bulk is shaped this way"
section of this report:

> This is a follow‑on issue of [#172742](https://github.com/elastic/kibana/pull/172742). Above issue randomises `runAt` of
> the bulk enabled rules. And creates new tasks (by using `scheduleTask` for
> each one of them) if they don't have any. **But, as we create the tasks
> already enabled, `bulkEnable` method of the TM skips them.**
>
> **This PR replaces `scheduleTask` with `bulkSchedule` and creates task as
> disabled, so `bulkEnable` can pick them up.**

The diff confirms the three‑step shape we see today:

```diff
-          let scheduledTaskId;
           if (shouldScheduleTask) {
-            const scheduledTask = await scheduleTask(context, {
+            tasksToSchedule.push({
               id: rule.id,
-              consumer: rule.attributes.consumer,
-              ruleTypeId: rule.attributes.alertTypeId,
-              schedule: rule.attributes.schedule as IntervalSchedule,
-              throwOnConflict: false,
+              taskType: `alerting:${rule.attributes.alertTypeId}`,
+              ...
+              enabled: false, // we create the task as disabled, taskManager.bulkEnable will enable them by randomising their schedule datetime
             });
-            scheduledTaskId = scheduledTask.id;
           }
```

And the `bulkSchedule` call was added outside the `pMap` loop, before the
SO `bulkCreate`:

```diff
+  if (tasksToSchedule.length > 0) {
+    await withSpan({ name: 'taskManager.bulkSchedule', type: 'tasks' }, () =>
+      context.taskManager.bulkSchedule(tasksToSchedule)
+    );
+  }
```

That `enabled: false,` line and its trailing comment are still present
verbatim in the file today (line 296 of `bulk_enable_rules.ts`). The wider
shape of the file has had only cosmetic edits since.

### What the blame establishes for the hypothesis

- **Philosophy B is not historical accident.** It was deliberately introduced
  by [PR #174656](https://github.com/elastic/kibana/pull/174656) in Jan 2024 as the only way to actually get the TM stagger
  feature (added by [PR #172742](https://github.com/elastic/kibana/pull/172742) a month earlier) to apply to bulk‑enable.
- **The "why bulk creates tasks disabled first" is documented in‑tree.** The
  inline comment `enabled: false, // we create the task as disabled,
  taskManager.bulkEnable will enable them by randomising their schedule
  datetime` is the canonical justification, and the commit message of
  [PR #174656](https://github.com/elastic/kibana/pull/174656) explains the sequencing reason ("as we create the tasks
  already enabled, `bulkEnable` … skips them").
- **The current bulk shape is a deliberate departure from philosophy A.**
  Before Jan 2024 the bulk path was philosophy A repeated `N` times with a
  batched final SO write. The split into a distinct philosophy was a direct
  consequence of needing per‑task `runAt` randomisation, which only
  `bulkEnable` performs and which only fires for tasks that are currently
  disabled.

This is the strongest single piece of evidence for the
single‑vs‑bulk‑philosophy split: a PR whose commit message **explicitly
describes the ordering change and its motivation**, with the comment it
introduced still living in the code today.
