---
name: bulk-schedule-random-offset
overview: Apply the existing `randomlyOffsetRunTimestamp` helper inside `TaskScheduling.bulkSchedule()` for tasks with `enabled === true`, reusing the same logic already used by `bulkEnable`.
todos:
  - id: widen-helper
    content: Generalize randomlyOffsetRunTimestamp signature to accept any task-shaped object with a schedule field
    status: pending
  - id: apply-in-bulk-schedule
    content: Call randomlyOffsetRunTimestamp inside bulkSchedule for tasks where enabled resolves to true
    status: pending
  - id: tests
    content: Add bulkSchedule unit tests covering enabled offset, disabled passthrough, default-enabled, and no-schedule cases
    status: pending
  - id: verify
    content: Run targeted jest, type_check, and eslint on task_scheduling files
    status: pending
isProject: false
---

## Goal

In [x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts](x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts), `randomlyOffsetRunTimestamp` is currently only used by `bulkEnable`. Reuse it in `bulkSchedule()` so newly bulk-scheduled tasks are spread across a randomized window, but only for tasks that will be enabled. Disabled tasks (`enabled === false`) are passed through unchanged.

## Changes

### 1. Generalize the helper signature

`randomlyOffsetRunTimestamp` is typed for `ConcreteTaskInstance`, but in `bulkSchedule` the modified task is a `TaskInstance & { traceparent; enabled }` (not yet a `ConcreteTaskInstance`). The helper only reads `task.schedule?.interval` and spreads back `runAt`/`scheduledAt`, so we can widen the signature with a generic that constrains on the fields it touches:

```ts
const randomlyOffsetRunTimestamp = <T extends { schedule?: IntervalSchedule | RruleSchedule }>(
  task: T
): T & { runAt: Date; scheduledAt: Date } => {
  const now = Date.now();
  const maximumOffsetTimestamp = now + 1000 * 60 * 5;
  const taskIntervalInMs = parseIntervalAsMillisecond(
    (task.schedule as IntervalSchedule | undefined)?.interval ?? '0s'
  );
  const maximumRunAt = Math.min(now + taskIntervalInMs, maximumOffsetTimestamp);
  const runAt = new Date(now + Math.floor(Math.random() * (maximumRunAt - now) + 1));
  return { ...task, runAt, scheduledAt: runAt };
};
```

This keeps the existing `bulkEnable` call site working (returns extend `ConcreteTaskInstance` to `ConcreteTaskInstance`) and lets `bulkSchedule` reuse it.

### 2. Apply it inside `bulkSchedule`

In the existing `bulkSchedule` mapping loop (lines 135–147), after computing `modifiedTask` and resolving `enabled`, branch on `enabled` and pass through the helper only when `true`:

```127:157:x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts
  public async bulkSchedule(
    taskInstances: TaskInstanceWithDeprecatedFields[],
    options?: ScheduleOptions
  ): Promise<ConcreteTaskInstance[]> {
    // ... existing traceparent logic ...
    const modifiedTasks = await Promise.all(
      taskInstances.map(async (taskInstance) => {
        const { taskInstance: modifiedTask } = await this.middleware.beforeSave({
          ...omit(options, 'apiKey', 'request'),
          taskInstance: ensureDeprecatedFieldsAreCorrected(taskInstance, this.logger),
        });
        const enabled = modifiedTask.enabled ?? true;
        const base = {
          ...modifiedTask,
          traceparent: traceparent || '',
          enabled,
        };
        return enabled ? randomlyOffsetRunTimestamp(base) : base;
      })
    );
    // ... unchanged store.bulkSchedule call ...
  }
```

No special case for the first task (per user choice): every enabled task gets a fresh randomized `runAt`/`scheduledAt` within `min(now + interval, now + 5m)`. Tasks without a recurring `schedule.interval` (or with an `RruleSchedule`) fall back to `'0s'`, yielding a 0–1 ms offset — effectively a no-op, which matches today's `bulkEnable` behavior.

### 3. Leave `schedule()` untouched

Per user choice, the singular `schedule()` path is unchanged.

### 4. Tests

Add unit tests in [x-pack/platform/plugins/shared/task_manager/server/task_scheduling.test.ts](x-pack/platform/plugins/shared/task_manager/server/task_scheduling.test.ts) under the existing `bulkSchedule` describe block (alongside the current ones), mirroring the patterns already used for `bulkEnable` (see the `should offset runAt and scheduledAt by no more than 5m...` test around line 506):

- Enabled tasks with an interval schedule get `runAt`/`scheduledAt` set, within `min(interval, 5m)` of `Date.now()`, and `runAt === scheduledAt`.
- Disabled tasks (`enabled: false`) pass through unchanged (no offset applied to `runAt`/`scheduledAt`).
- Tasks that omit `enabled` default to `true` and receive the offset.
- Tasks without a `schedule` still pass through `randomlyOffsetRunTimestamp` (0–1 ms offset is acceptable).

### 5. Risk / Behavioural notes

- This changes the `runAt` and `scheduledAt` of any enabled task scheduled via `bulkSchedule` — previously these were whatever the caller passed (or middleware-defaulted). Callers that rely on a precise `runAt` from `bulkSchedule` would be affected; this matches `bulkEnable`'s long-standing behavior so should be acceptable.
- No change to the `store.bulkSchedule` contract or to `schedule()`.

## Verification

- `node scripts/jest x-pack/platform/plugins/shared/task_manager/server/task_scheduling.test.ts`
- `node scripts/type_check --project x-pack/platform/plugins/shared/task_manager/tsconfig.json`
- `node scripts/eslint --fix x-pack/platform/plugins/shared/task_manager/server/task_scheduling.ts x-pack/platform/plugins/shared/task_manager/server/task_scheduling.test.ts`