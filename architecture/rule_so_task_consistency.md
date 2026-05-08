# Rule SO ↔ Task Manager consistency in alerting

## Context

This document captures evidence from the alerting plugin source code and git
history about the relationship the system tries to maintain between the
**rule saved object** (in `.kibana`) and the **Task Manager task** (in
`.kibana_task_manager`) that drives its execution.

It also walks through every observed desync combination, tracing the actual
code paths to determine which states the system can recover from on its own,
which require user action, and which (if any) leave a quietly broken rule.

Investigation prompted by reviewing the order of `bulkSchedule` and
`bulkCreate` calls in `bulk_enable_rules.ts`, then expanded to
`create_rule_saved_object.ts`, `enable_rule.ts`, `bulk_create_rules.ts`,
`delete_rule.ts`, `disable_rule.ts`, `bulk_disable_rules.ts`,
`task_runner.ts`, and `rule_loader.ts`.

## Important caveat — this is best-effort, not guaranteed

The rule saved object lives in `.kibana` and the Task Manager task lives in
`.kibana_task_manager`. Elasticsearch does not offer cross-index transactions,
and Kibana does not run a saga / two-phase-commit layer over the saved
objects client and the task manager client. That means:

- A TCP failure, pod kill, or process restart between two sequential writes
  can always leave the two stores out of sync, regardless of the order
  chosen.
- A "compensating delete" can itself fail (and in fact the code logs and
  swallows that error rather than retrying).
- The `bulk_enable_rules.ts` flow has no compensating cleanup at all if
  `taskManager.bulkSchedule` partially fails after the rule SO write
  succeeds.

So the patterns documented below describe a **design intent and a best-effort
consistency target** — implemented through prevent-or-repair logic — not a
formal guarantee. Operationally the system relies on:

1. The application code following the documented order in the happy path.
2. Compensating deletes / demotions / self-healing re-schedules covering
   common failures.
3. The task runner itself acting as a second line of defence, detecting
   missing-rule and disabled-rule cases on its next execution and asking
   Task Manager to delete or disable the task.

When reading the rest of this document, treat phrases like "the system tries
to ensure …" as shorthand for that prevent-or-repair pattern, not for a
transactional guarantee.

## Summary of the consistency target

In one sentence:

> A rule SO with `enabled: true` should have a `scheduledTaskId`, and that id
> should resolve to a TM task whose `taskType` matches the rule's
> `alertTypeId`. A rule SO with `enabled: false` may or may not have a
> matching task; if it does, the task is expected to be `enabled: false`
> in TM.

Three rules of thumb fall out of the code:

1. **The TM task is the runtime resource. The rule SO is the source of truth
   for whether it should exist.** The task runner reads the rule SO every
   run, and any mismatch (rule missing, rule disabled, taskInstance.id
   mismatched with `scheduledTaskId`) becomes the task's signal to
   self-delete or self-disable.
2. **Task ids are deterministic and equal to rule ids in the modern code
   path.** When you see `scheduleTask({ id })` or `bulkSchedule({ id:
   rule.id })`, the task id is the rule id. The "scheduledTaskId differs
   from rule id" branches only fire for legacy data.
3. **The repair direction is biased toward removing/demoting work, not
   creating it.** When the system finds an inconsistent state, it prefers
   to (a) delete the orphaned task, (b) flip the rule SO to
   `enabled: false`, or (c) re-schedule a missing task. It never silently
   resurrects a deleted rule from a leftover task.

## Evidence — the application code

### Evidence #1 — single create has had a compensating delete since June 2019

The "delete the rule SO if scheduling the task fails" pattern was introduced
in `98f7c75ff4a0`
([PR #37042](https://github.com/elastic/kibana/pull/37042), Mike Côté,
"Introduce basic alerting and actions plugin"). The original diff:

```diff
+      scheduledTask = await this.scheduleAlert(createdAlert.id, rawAlert, this.basePath);
+    } catch (e) {
+      // Cleanup data, something went wrong scheduling the task
+      try {
+        await this.savedObjectsClient.delete('alert', createdAlert.id);
+      } catch (err) {
+        // Skip the cleanup error and throw the task manager error to avoid confusion
+        ...
```

That same block survives almost word-for-word in today's
`create_rule_saved_object.ts`:

```102:139:x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts
  if (rawRule.enabled) {
    let scheduledTaskId: string;
    try {
      const scheduledTask = await scheduleTask(context, {
        id: createdAlert.id,
        consumer: rawRule.consumer,
        ruleTypeId: rawRule.alertTypeId,
        schedule: rawRule.schedule,
        throwOnConflict: true,
      });
      scheduledTaskId = scheduledTask.id;
    } catch (e) {
      // Cleanup data, something went wrong scheduling the task
      try {
        await deleteRuleSo({
          savedObjectsClient: context.unsecuredSavedObjectsClient,
          id: createdAlert.id,
        });
      } catch (err) {
        // Skip the cleanup error and throw the task manager error to avoid confusion
        context.logger.error(
          `Failed to cleanup rule "${createdAlert.id}" after scheduling task failed. Error: ${err.message}`
        );
      }
      throw e;
    }
```

This is the strongest evidence that the missing-task state is something the
design tries to avoid producing: a **compensating delete** of the rule SO if
`scheduleTask` fails. The compensating delete itself is best-effort — see the
inner `try/catch` and the "Failed to cleanup rule …" log line — but the
intent is unambiguous.

Confirmed via `git log -S 'something went wrong scheduling the task'`: the
comment originated in `98f7c75ff4a0` (PR #37042) and `a3220fe1b6f0` (the
2022 file split that copied it forward).

### Evidence #2 — disable preserves the task on purpose

`0cf0e3dd97d9` ([PR #139826](https://github.com/elastic/kibana/pull/139826),
Ying Mao, Sep 2022, "Keep task document when enabling/disabling rules") made
disable **keep** the TM task (just toggle it to `enabled: false`) instead of
deleting it. Today's `disable_rule.ts` reflects that:

```100:135:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/disable/disable_rule.ts
  if (attributes.enabled === true) {
    const migratedIds = await bulkMigrateLegacyActions({ context, rules: [alert] });

    await context.unsecuredSavedObjectsClient.update(
      RULE_SAVED_OBJECT_TYPE,
      id,
      updateMeta(context, {
        ...attributes,
        enabled: false,
        scheduledTaskId: attributes.scheduledTaskId === id ? attributes.scheduledTaskId : null,
        ...
      }),
      ...
    );
    ...
    // If the scheduledTaskId does not match the rule id, we should
    // remove the task, otherwise mark the task as disabled
    if (attributes.scheduledTaskId) {
      if (attributes.scheduledTaskId !== id) {
        await context.taskManager.removeIfExists(attributes.scheduledTaskId);
      } else {
        await context.taskManager.bulkDisable(
          [attributes.scheduledTaskId],
          Boolean(isLifecycleAlert)
        );
      }
    }
  }
```

This is the design counterpart to evidence #1: by **preserving** the task
across disable, the system makes it likely that when you re-enable, the task
is already there. The enable path therefore doesn't usually need to
re-schedule — it just calls `bulkEnable`. The relationship "rule SO
`enabled: true` + `scheduledTaskId` ⇒ matching TM task" tends to hold across
the disable boundary because disable doesn't break it.

The `attributes.scheduledTaskId !== id` branch handles legacy data where the
task id wasn't equal to the rule id; for those rules, disable removes the
task (since the task id doesn't match the rule id, it's not addressable by
the modern self-healing branch on enable).

### Evidence #3 — single enable self-heals when the task is missing or unrecognized

The single-rule enable path in `enable_rule.ts` writes `enabled: true` to the
SO **without modifying `scheduledTaskId`** (it carries forward the existing
value), then verifies or repairs the task:

```218:253:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/enable_rule/enable_rule.ts
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

Three branches, all evidence-based:

- `scheduledTaskId` set, task exists, `status !== Unrecognized` → just
  `bulkEnable` the existing task.
- `scheduledTaskId` set, but `taskManager.get` throws (task missing) **or**
  task has status `Unrecognized` → remove if needed, then schedule a fresh
  task and patch `scheduledTaskId`.
- `scheduledTaskId` not set at all → schedule a new task and patch
  `scheduledTaskId`.

The `Unrecognized` branch was added in `c875a284af46`
([PR #152975](https://github.com/elastic/kibana/pull/152975), Ying Mao, Mar
2023, "Delete `unrecognized` tasks when enabling a rule"). The same logic
exists in `bulk_enable_rules.ts` via `getShouldScheduleTask`.

So **the single-rule enable path is itself a repair path**. If a rule SO
shows up with `enabled: true` and a stale `scheduledTaskId`, simply
re-enabling it (even though it's already "enabled") would bring it back into
sync — except that, in practice, you don't re-enable an already-enabled
rule. See "What happens when each desync combination occurs" below.

### Evidence #4 — bulk enable inherits the same per-rule self-healing

`bulk_enable_rules.ts` is structurally similar:

```108:155:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts
  const { errors, rules, accListSpecificForBulkOperation } = await retryIfBulkOperationConflicts({
    action: 'ENABLE',
    logger: context.logger,
    bulkOperation: (filterKueryNode: KueryNode | null) =>
      bulkEnableRulesWithOCC(context, { filter: filterKueryNode }),
    filter: kueryNodeFilterWithAuth,
  });

  const [taskIdsToEnable] = accListSpecificForBulkOperation;

  const taskIdsFailedToBeEnabled = await tryToEnableTasks({
    taskIdsToEnable,
    logger: context.logger,
    taskManager: context.taskManager,
  });
  ...
```

Inside `bulkEnableRulesWithOCC`, per-rule:

1. `getShouldScheduleTask(context, rule.attributes.scheduledTaskId)` — same
   self-healing logic as single-rule enable (missing task or `Unrecognized`
   status ⇒ schedule a new one).
2. Tasks needing scheduling go into `tasksToSchedule` and are
   `bulkSchedule`-d (with `enabled: false`) **before** the rule SO
   `bulkCreate`.
3. SO `bulkCreate({ overwrite: true })` writes `enabled: true` and
   `scheduledTaskId: rule.id` for all successful rules.
4. After the OCC retry returns, `taskManager.bulkEnable(taskIdsToEnable)`
   flips the new tasks to `enabled: true` and randomises their `runAt` so
   they don't all stampede.

So the order is the same as single-rule create: **schedule (or repair) the
task first, then write the SO that points at it**. The motivation for
batching is even `runAt` distribution (see PR #174656); the ordering
relative to the SO write is inherited from the original 2019 pattern.

**Gap**: there is no compensating cleanup if `bulkSchedule` partially
fails after the SO `bulkCreate` — see the "honest gap" section below.

### Evidence #5 — bulk create uses persist-first with demotion on schedule failure

`bulk_create_rules.ts` (currently work-in-progress in this branch — note the
modified flag in `git status`) takes a different approach: it persists the
rule SOs first and demotes them to `enabled: false` if scheduling fails.

```49:60:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts
/**
 * Persist-first bulk rule create. 2 parts:
 * 1. Foreground: Rule creation.
 *    - validate, generate api keys, SO bulkCreate, audit, return.
 * 2. Background: Schedule enabled rule tasks (`result.backgroundWork`)
 *    - limit checks, task scheduling, demotion / rule SO update (-> disabled), key invalidation.
 *
 * Returned `rules[]` reflect input intent; the background promise may
 * later demote rules to "disabled" if related tasks failed to schedule.
 */
```

The phases that matter here:

- **Phase 2** — `bulkCreateRulesSo` writes all rule SOs (with input
  `enabled` value).
- **Phase 4A** — schedule-limit circuit breaker. If exceeded, all
  enabled-persisted ids get queued for demotion.
- **Phase 4B** — `taskManager.bulkSchedule(tasksToSchedule)`. Every id that
  fails (whole-call throw) or is silently dropped (returned set smaller
  than input set) gets queued for demotion.
- **Phase 4C** — `demotePersistedRules`: bulk-update those rule SOs to
  `enabled: false`, `scheduledTaskId: null`, `lastEnabledAt: null`,
  invalidate their API keys. From `bulk_create/utils.ts`:

```441:497:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts
  for (const [id, { reason, message }] of demotedIds) {
    const prepared = preparedRules.get(id);
    if (!prepared) continue;
    ...
    const cleared = {
      ...nullKey,
      enabled: false,
      scheduledTaskId: null,
      lastEnabledAt: null,
    } as unknown as Partial<RawRule>;

    rulesToUpdate.push({ id, attributes: cleared });
    ...
  }

  if (rulesToUpdate.length === 0) return errors;

  try {
    await withSpan({ name: 'unsecuredSavedObjectsClient.bulkUpdate', type: 'rules' }, () =>
      bulkUpdateRuleSo({
        savedObjectsClient: context.unsecuredSavedObjectsClient,
        rules: rulesToUpdate,
      })
    );
  } catch (err) {
    context.logger.error(
      `bulkCreateRules: bulkUpdate to demote ${rulesToUpdate.length} rules failed: ${err.message}`
    );
  }
```

This is a **demotion** repair pattern — semantically equivalent to single
create's compensating delete in that it removes the obligation for a backing
task, but kinder to callers because the rule SO survives and can be
re-enabled later. Note that the demotion bulkUpdate itself is best-effort
(the catch only logs).

### Evidence #6 — single delete removes the SO first, then the task

```117:155:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/delete/delete_rule.ts
  ...
  const removeResult = await deleteRuleSo({
    savedObjectsClient: context.unsecuredSavedObjectsClient,
    id,
  });

  await Promise.all([
    taskIdToRemove ? context.taskManager.removeIfExists(taskIdToRemove) : null,
    context.backfillClient.deleteBackfillForRules({ ... }),
    (apiKeyToInvalidate || uiamApiKeyToInvalidate) && !apiKeyCreatedByUser
      ? bulkMarkApiKeysForInvalidation(...)
      : null,
  ]);

  return removeResult;
}
```

The order here is the **reverse** of create: SO is deleted first, then the
task is removed in a `Promise.all` alongside backfill/API-key cleanup. If
the task removal fails after the SO is gone, you're left with an orphaned
task — but as we'll see in the task-runner section, that orphan
self-deletes on its next run.

### Evidence #7 — bulk disable forwards taskIds to disable / delete / clear-state

```70:92:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_disable/bulk_disable_rules.ts
  const { errors, rules, accListSpecificForBulkOperation } = await withSpan(
    { name: 'retryIfBulkOperationConflicts', type: 'rules' },
    () =>
      retryIfBulkOperationConflicts({
        action: 'DISABLE',
        logger: context.logger,
        bulkOperation: (filterKueryNode: KueryNode | null) =>
          bulkDisableRulesWithOCC(context, { filter: filterKueryNode, untrack }),
        filter: kueryNodeFilterWithAuth,
      })
  );

  const [taskIdsToDisable, taskIdsToDelete, taskIdsToClearState] = accListSpecificForBulkOperation;

  await Promise.allSettled([
    tryToDisableTasks({ ... }),
    tryToRemoveTasks({ ... }),
  ]);
```

Same shape as the single-rule disable: SO write inside the OCC retry, then
TM operations after, classified into "disable matching task" /
"remove non-matching task" buckets.

## Evidence — the task runner

The task runner is the **second line of defence** against drift. Whenever a
task runs, three checks gate it:

### Rule SO not found → unrecoverable error → task deleted

```130:158:x-pack/platform/plugins/shared/alerting/server/task_runner/rule_loader.ts
export async function getDecryptedRule(
  context: TaskRunnerContext,
  ruleId: string,
  spaceId: string
): Promise<RuleData> {
  ...
  try {
    rawRule = await context.encryptedSavedObjectsClient.getDecryptedAsInternalUser<RawRule>(
      RULE_SAVED_OBJECT_TYPE,
      ruleId,
      { namespace }
    );
  } catch (e) {
    const error = new ErrorWithReason(RuleExecutionStatusErrorReasons.Decrypt, e);
    if (SavedObjectsErrorHelpers.isNotFoundError(e)) {
      throw createTaskRunError(error, TaskErrorSource.USER);
    }
    throw createTaskRunError(error, TaskErrorSource.FRAMEWORK);
  }
  ...
}
```

That error propagates up to the runner and is then routed through
`getSchedule`:

```33:55:x-pack/platform/plugins/shared/alerting/server/task_runner/lib/get_schedule.ts
  return resolveErr<IntervalSchedule | undefined, Error>(schedule, (error) => {
    if (isAlertSavedObjectNotFoundError(error, ruleId)) {
      const spaceMessage = spaceId ? `in the "${spaceId}" space ` : '';
      logger.warn(
        `Unable to execute rule "${ruleId}" ${spaceMessage}because ${error.message} - this rule will not be rescheduled. To restart rule execution, try disabling and re-enabling this rule.`
      );
      throwUnrecoverableError(error);
    }
    ...
```

`throwUnrecoverableError` is recognised by Task Manager's runner:

```778:790:x-pack/platform/plugins/shared/task_manager/server/task_running/task_runner.ts
          shouldDeleteTask,
          shouldDisableTask,
        }: SuccessfulRunResult & { attempts: number }) => {
          if (shouldDeleteTask) {
            // set the status to failed so task will get deleted
            return asOk({ status: TaskStatus.ShouldDelete });
          }

          if (shouldDisableTask) {
            shouldTaskBeDisabled = true;
            return asOk({ status: TaskStatus.Idle });
          }
```

Combined with the `rescheduleFailedRun` path (line 732 of the same file)
that checks `isUnrecoverableError(error)` and falls through to
`{ status: TaskStatus.Failed }`, the final `processResultForRecurringTask`
deletes the task SO so it doesn't linger forever.

**Net effect**: an orphaned task whose rule SO was deleted
self-destructs on its next scheduled run. Recovery is automatic, with one
wasted execution.

### Rule SO found but `enabled: false` → task asks TM to disable it

```60:70:x-pack/platform/plugins/shared/alerting/server/task_runner/rule_loader.ts
  const { enabled, apiKey, uiamApiKey, apiKeyCreatedByUser, alertTypeId: ruleTypeId } = rawRule;

  if (!enabled) {
    throw createTaskRunError(
      new ErrorWithReason(
        RuleExecutionStatusErrorReasons.Disabled,
        new Error(`Rule failed to execute because rule ran after it was disabled.`)
      ),
      TaskErrorSource.FRAMEWORK
    );
  }
```

That `Disabled` reason is detected by `task_runner.ts`:

```742:762:x-pack/platform/plugins/shared/alerting/server/task_runner/task_runner.ts
    let shouldDisableTask = false;
    try {
      const validatedRuleData = await this.prepareToRun();
      ...
    } catch (err) {
      if (isOutdatedTaskVersionError(err)) {
        this.logger.info(
          `Outdated task version: The task instance ID: ${this.taskInstance.id} does not match the rule ID: ${ruleId}.`
        );
        return getDeleteRuleTaskRunResult();
      }

      runRuleResult = asErr(err);
      schedule = asErr(err);
      shouldDisableTask = err.reason === RuleExecutionStatusErrorReasons.Disabled;
    }
```

`shouldDisableTask: true` is returned to TM, which then sets the task to
`enabled: false` (see the snippet above and lines 866–869 of TM's
`task_runner.ts`).

**Net effect**: a task that's still running for a rule whose SO has been
disabled gets disabled in TM on its next run, with no user intervention.

### Task id doesn't match rule id or `scheduledTaskId` → task deleted

```553:561:x-pack/platform/plugins/shared/alerting/server/task_runner/task_runner.ts
      // Check that this task is current
      const scheduledTaskId = ruleData.rawRule.scheduledTaskId;
      if (this.taskInstance.id !== ruleId && this.taskInstance.id !== scheduledTaskId) {
        throw new ErrorWithType({
          message: 'The task ID does not match the rule ID',
          type: OUTDATED_TASK_VERSION,
        });
      }
```

That `OUTDATED_TASK_VERSION` is caught in `run()` and explicitly returns
`getDeleteRuleTaskRunResult()`:

```70:74:x-pack/platform/plugins/shared/alerting/server/task_runner/types.ts
export const getDeleteRuleTaskRunResult = (): RuleTaskRunResult => ({
  state: {},
  schedule: { interval: '5m' },
  shouldDeleteTask: true,
});
```

→ TM deletes the task on this run.

**Net effect**: stale tasks (e.g. from a legacy rule whose `scheduledTaskId`
got rewritten to a new value) are deleted on their next run.

## State matrix — what happens when the SO and TM go out of sync

Each row describes a possible inconsistent state (rows 1–2 are the
consistent baselines for reference) and what the actual code paths do about
it. The "Repair trigger" column says what has to happen for the system to
notice and repair.

| # | Rule SO state | TM task state | Application code behaviour | Task runner behaviour | Repair trigger | Recoverable? | Severity if left |
|---|---|---|---|---|---|---|---|
| 1 | `enabled: true`, `scheduledTaskId: X` | task `X` exists, `enabled: true`, `taskType` matches | Happy path | Task runs normally | n/a | n/a | n/a |
| 2 | `enabled: false`, `scheduledTaskId: X` (or null) | task `X` exists, `enabled: false` | Happy path after disable | TM doesn't claim disabled tasks | n/a | n/a | n/a |
| 3 | `enabled: true`, `scheduledTaskId: null/undefined` | no matching task | enable (single or bulk) self-heals: `scheduledTaskIdToCreate = id` → schedules a fresh task. See `enable_rule.ts` line 233-235 and bulk's `getShouldScheduleTask` line 62. | Never runs (no task). | User issues an enable on this rule (or it's part of a bulk enable). | YES — repaired on next user-triggered enable, or on the next call to `getShouldScheduleTask` from bulk enable. | **Medium-high while it lasts**: the rule appears enabled in the UI and never fires. There is no automatic detection. |
| 4 | `enabled: true`, `scheduledTaskId: X` | no task `X` | Same as #3: enable's `try { taskManager.get(...) } catch { scheduledTaskIdToCreate = id }` repairs it. See `enable_rule.ts` line 230-232. | Never runs. | Same as #3. | YES — same path as #3. | Same as #3. |
| 5 | `enabled: true`, `scheduledTaskId: X` | task `X` exists, `status: Unrecognized` (TM doesn't recognise the `taskType` — typical after rule-type unregistration / version downgrade) | enable removes the unrecognised task and reschedules. See `enable_rule.ts` line 226-229 and bulk's `getShouldScheduleTask` line 70-73. PR #152975. | TM does not claim Unrecognized tasks. | Same as #3 — needs an enable call. | YES — repaired on next enable. | Same as #3. |
| 6 | rule SO does not exist | task `X` exists, `taskType` registered, `enabled: true` | n/a (no rule to operate on) | Task runs → `getDecryptedRule` throws `Decrypt(NotFoundError)` → `getSchedule` calls `throwUnrecoverableError` → TM's `processResultForRecurringTask` sets `TaskStatus.Failed` → task SO is deleted. See `rule_loader.ts` line 147-148, `get_schedule.ts` line 34-40, TM `task_runner.ts` line 814-820. | Automatic, on next run. | YES — fully self-healing. | **Low**: the orphaned task wakes up once, fails, deletes itself. Some wasted CPU and a noisy log line per orphan, otherwise harmless. |
| 7 | `enabled: true`, `scheduledTaskId: X` | task `Y` exists with `Y !== X` and `Y !== rule.id` (legacy mismatched id) | n/a | Task runs → `taskInstance.id !== ruleId && taskInstance.id !== scheduledTaskId` → `OUTDATED_TASK_VERSION` → `getDeleteRuleTaskRunResult` → `shouldDeleteTask: true` → TM deletes task `Y`. See `task_runner.ts` line 555-561 and 752-757. After that, you're back to row #4, which the next user-enable repairs. | Automatic for the orphan task; row #4 path for the rule. | YES — two-stage. | **Low**: same noisy-log story as row #6 for the wrong task; rule then becomes "enabled but no task," same severity as row #3 until enable runs again. |
| 8 | `enabled: false`, `scheduledTaskId: X` | task `X` exists with `enabled: true` (drift after a failed disable) | n/a | Task runs → `validateRuleAndCreateFakeRequest` throws `Disabled` → `shouldDisableTask: true` → TM sets task `enabled: false`. See `rule_loader.ts` line 62-70 and TM `task_runner.ts` line 786-789. | Automatic, on next run. | YES — fully self-healing. | **Low**: one wasted execution attempt; no actions/alerts get fired because the runner throws before the rule executor is invoked. |
| 9 | `enabled: false`, `scheduledTaskId: null` | task `X` exists (orphaned) | n/a | If TM still has `taskType` registered, task wakes up and runs → reads rule SO → `Disabled` reason → row #8 path. If `taskType` is unregistered (`Unrecognized`), TM never claims it; only repaired by a subsequent enable that finds it via `getShouldScheduleTask` (but only if `scheduledTaskId` is repopulated). | Automatic if registered; otherwise dormant. | Mostly YES; partially NO if the rule SO has no `scheduledTaskId` to follow back to the task. | **Low**: orphan task is dormant or self-cleans. The rule SO is correctly disabled. |
| 10 | `enabled: true`, `scheduledTaskId: X` | task `X` exists, `enabled: true`, but `params.alertId !== rule.id` (stored params point at a different rule) | n/a | Task runs with `alertId: <wrong-id>` → loads the wrong rule SO. The id-match check at line 555-561 of `task_runner.ts` compares against `this.taskInstance.id`, not `params.alertId`, so this drift is **not** caught here. The wrong rule fires using the wrong API key. | **Not detected by the runner**; only by user observation. | Manual: user must delete or rebuild the rule + task. | **NO automatic recovery for this specific shape.** | **Higher**: a rule fires with another rule's parameters and credentials. In practice this state is unreachable through normal API flows because tasks are created with `params: { alertId: rule.id }` and `id: rule.id` together; only direct ES manipulation produces it. |
| 11 | `enabled: true`, `scheduledTaskId: X` | task `X` exists but `taskType` does not match rule's `alertTypeId` | n/a | Task runs → TM dispatches to whichever rule type's runner is registered for `taskType`. If `taskType` is registered, runner reads rule SO whose `alertTypeId` differs → `validateRuleTypeParams` likely throws → user error → task continues retrying without self-deletion. | Not detected as drift; fails as a normal user error. | Manual: user must delete the rule. | **Mostly NO automatic recovery for this shape.** | **Medium**: rule appears enabled but never produces results. Same severity as row #3, but harder to debug because it runs and fails rather than never running. Like row #10, only direct ES manipulation produces it. |
| 12 | `enabled: true`, `scheduledTaskId: X` | task `X` exists but encrypted attributes can't be decrypted (e.g. encryption key rotated and old key not in `keyRotation.decryptionOnlyKeys`) | n/a | Task runs → `getDecryptedRule` throws `Decrypt(non-NotFound)` wrapped as `TaskErrorSource.FRAMEWORK` → `isAlertSavedObjectNotFoundError` returns `false` → not unrecoverable → TM reschedules with a retry. The task keeps failing every interval. | Not self-healing. Will keep retrying indefinitely. | Manual: re-enable the rule (which triggers a new API key) or restore the encryption key. | YES, but only via user action. | **Medium**: noisy logs every interval; rule never produces results. Operational pain rather than data corruption. |

A few observations from this matrix:

- **Rows 6, 7, 8 (and 9 in the registered case) are fully self-healing.**
  Whatever drift gets the task running with the wrong assumptions, the
  task runner's gates (`Decrypt`, `Disabled`, `OUTDATED_TASK_VERSION`)
  cause TM to delete or disable the task on its next run.
- **Rows 3, 4, 5 are recoverable but require user action.** A rule SO
  marked `enabled: true` with no working task is a silently dead rule. The
  system has no proactive scan that would notice and re-enable it; a user
  has to disable+enable, or call bulk enable on it, or hit the "Run
  rule manually" button.
- **Rows 10 and 11 are not automatically recoverable.** Both require
  direct ES manipulation to produce, so they're realistic only after a
  bad migration, manual recovery, or a Kibana bug. The task runner's
  identity check is by `taskInstance.id`, not by `params.alertId` or by
  comparing `taskType` to `alertTypeId`.

## What happens when the SO and TM go out of sync, summarised

> **Recoverable, automatic** (rows 6, 7, 8, partial 9): orphan tasks
> self-delete on their next run via `throwUnrecoverableError`; tasks for
> disabled rules disable themselves via `shouldDisableTask`; tasks with the
> wrong `taskInstance.id` delete themselves via `shouldDeleteTask`. The
> cost is one wasted run per orphan plus log noise.
>
> **Recoverable, requires user action** (rows 3, 4, 5, 12): rule SOs
> claiming `enabled: true` but lacking a working task. The system has no
> background scan; the user has to issue a disable+enable or call bulk
> enable. Severity is "rule appears enabled in the UI but never produces
> results" until the user notices.
>
> **Not automatically recoverable** (rows 10, 11): tasks whose
> `params.alertId` or `taskType` don't match the rule SO they nominally
> belong to. These shapes aren't producible through normal API flows —
> they require direct ES manipulation, a faulty migration, or a Kibana
> bug — but if they happen, the user has to delete the rule (and the task)
> by hand. Severity is moderate-to-high because the task may execute
> against the wrong rule.

## The honest gap

Two specific places in the application code are weaker than the rest of the
prevent-or-repair scheme:

1. **`bulk_enable_rules.ts` does not compensate for partial `bulkSchedule`
   failure.** The flow is `bulkSchedule(tasks)` → `bulkCreate(rules)` →
   `bulkEnable(taskIds)`. If `bulkSchedule` partially succeeds (some tasks
   created, some not) and the SO `bulkCreate` then proceeds with all
   `enabled: true` and `scheduledTaskId: rule.id`, the rules whose tasks
   failed to schedule end up in row #3 or #4 of the matrix above — silently
   dead until the user re-enables them. This is in lines 344–348 of
   `bulk_enable_rules.ts`. The single-create equivalent (evidence #1) has
   a compensating delete; the bulk-create equivalent (evidence #5) has
   demotion-on-failure; bulk-enable has neither.
2. **The compensating delete in single create is itself best-effort.** If
   `deleteRuleSo` after a failed `scheduleTask` itself throws, the code logs
   `"Failed to cleanup rule … Error: …"` and rethrows the original task-manager
   error. The rule SO survives in the broken state (row #3) and waits for the
   user to re-enable it.

Stacked on top of the cross-store, non-transactional reality from the
caveat section, this means the bulk-enable path is the weakest link in
practice, and the only state that escapes the task runner's auto-cleanup
is "rule SO says enabled, no working task" — which the runner can't see
because nothing is running to see it.

## Summary table — by code path

| Boundary | Mechanism | Origin |
|---|---|---|
| Single create | Compensating delete of rule SO if `scheduleTask` fails | PR #37042 (June 2019) |
| Bulk create (current WIP) | Persist-first; demote `enabled: false` + clear `scheduledTaskId` on schedule limit / `bulkSchedule` failure / silent drop | This branch (`bulk_create_rules.ts` is `M` in `git status`) |
| Single disable | Task preserved (`enabled: false`) so the link survives across re-enable; legacy mismatched ids removed | PR #139826 (Sep 2022) |
| Single enable | Self-healing via `scheduleTask` if task is missing or `Unrecognized`; otherwise just `bulkEnable` the existing task | PR #139826 (Sep 2022) + PR #152975 (Mar 2023) |
| Bulk enable | `bulkSchedule` precedes SO `bulkCreate`; per-rule `getShouldScheduleTask` self-heals on the next pass; **no compensating cleanup on partial schedule failure** | Inherited from single-rule pattern via PR #146612 (Dec 2022) and PR #174656 (Jan 2024) |
| Single delete | SO deleted first, then `removeIfExists` on the task in parallel with API key invalidation; orphan tasks are picked up by the task-runner unrecoverable-error path | Original pattern carried forward |
| Bulk disable | OCC retry around the SO write; classifies tasks into disable/delete/clear-state buckets handled by `tryToDisableTasks` and `tryToRemoveTasks` after the OCC returns | Same shape as single disable |
| Task runner (any rule) | Detects missing rule SO (`Decrypt` + `NotFoundError` → `throwUnrecoverableError` → TM deletes task), disabled rule SO (`Disabled` → `shouldDisableTask`), and id mismatch (`OUTDATED_TASK_VERSION` → `shouldDeleteTask`) | `task_runner.ts`, `rule_loader.ts`, `lib/get_schedule.ts` |

## TL;DR

- The alerting plugin treats "rule SO `enabled: true` + `scheduledTaskId`
  with no matching TM task" as a state to avoid producing and to repair on
  contact. It uses three patterns: compensating delete (single create),
  demotion (bulk create), and self-healing re-schedule (single and bulk
  enable). Disable is the inverse — it preserves the task to keep the
  link intact across re-enable.
- Out-of-sync states where the **task is the orphan** are reliably
  self-healing: the task runner's `getDecryptedRule`, enabled-flag check,
  and id-match check all turn drift into TM deletions or disables on the
  next run, at the cost of one wasted execution.
- Out-of-sync states where the **rule SO is the orphan** (claims enabled,
  no working task) are recoverable only via user action — there is no
  background scan to repair them. The only realistic source of these in
  production is a partial `bulkSchedule` failure during bulk enable, or a
  Kibana process death between the SO write and the task write.
- The two states that are not automatically recoverable
  (`taskInstance.params.alertId` or `taskType` not matching the rule SO)
  are unreachable through normal API flows; they require direct ES
  manipulation or a faulty migration to produce.
