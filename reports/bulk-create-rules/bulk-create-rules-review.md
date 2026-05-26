# Code review: `bulk_create_rules.ts`

**Reviewer:** senior tech lead
**Date:** 2026-05-05
**Subject:** `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
**Reference design:** `.claude/reports/bulk-create-with-enable.md`

Findings from reading the implementation, the test file, the design report it was meant to follow, and the surrounding code (`createRule`, `bulkEnableRules`, `createRuleSavedObject`, the API-key helpers). Grouped by severity so the team can decide what to push back on first.

---

## 1. Hard bugs (must answer before merge)

### 1.1 The test file does not compile — missing export

The test imports a symbol the implementation never exports:

```ts
// bulk_create_rules.test.ts (line 33)
import { BULK_CREATE_AS_DISABLED_PREFIX } from './bulk_create_rules';
```

…and uses it four times (lines 331, 375, 403, 430). The implementation only has a private `getBulkCreateAsDisabledMessage` that wraps `i18n.translate(...)`:

```ts
const getBulkCreateAsDisabledMessage = (message: string): string =>
  i18n.translate('xpack.alerting.rulesClient.bulkCreate.ruleCreatedDisabledErrorMessage', {
    defaultMessage: 'Rule created in a disabled state: {message}',
    values: { message },
  });
```

**Questions:**
- Did you actually run `node scripts/jest .../bulk_create_rules.test.ts`? This won't even compile.
- If you intend to keep `i18n.translate` for the prefix, how does the test get a stable string back? `i18n.translate` returns a localized string; tests should assert on `disabledReason` (machine-readable) rather than a translated string. The `disabledReason` field exists exactly for this purpose — why also assert on a prefix?
- If you want a constant prefix, either export one (`export const BULK_CREATE_AS_DISABLED_PREFIX = 'Rule created in a disabled state: '`) and have `getBulkCreateAsDisabledMessage` use it, or drop the assertion. Pick one.

### 1.2 Missing `addMissingUiamKeyTagIfNeeded` — known gap from the design doc, still not done

The single-rule `createRule` does this for every API-key-minting path:

```ts
// create_rule.ts lines 206-212
const tagsWithUiamCheck = await addMissingUiamKeyTagIfNeeded(
  data.tags,
  apiKeyProps.uiamApiKey,
  apiKeyProps.apiKeyCreatedByUser,
  context.isServerless,
  context.featureFlags
);
```

`bulkCreateRules` mints API keys (`createNewAPIKeySet`) but never calls `addMissingUiamKeyTagIfNeeded`. The design report (Sections 3.5 and 6.4 of `.claude/reports/bulk-create-with-enable.md`) called this out explicitly as something to fix as part of the work:

> **Known gap worth fixing alongside this work:** `bulkEnableRules` (and any disabled-only `bulkCreateRules`) skips `addMissingUiamKeyTagIfNeeded`. In serverless with `PROVISION_UIAM_API_KEYS_FEATURE_FLAG` enabled, rules created or enabled via these paths will lack the `MISSING_UIAM_API_KEY_TAG`.

**Questions:**
- Why was this dropped? In Phase 1 you have the API key result in hand; calling `addMissingUiamKeyTagIfNeeded` on `data.tags` is a few lines and zero extra round-trips.
- Have you confirmed serverless with the UIAM feature flag enabled is acceptable to ship without this tag?

### 1.3 Caller-supplied id collision + `enabled: true` will nuke a pre-existing rule's task

Phase 3 calls `taskManager.bulkSchedule(tasksToSchedule)`. Per `task_store._bulkSchedule`, that uses `bulkCreate` with `overwrite: true` — so a colliding caller-supplied id silently overwrites the existing task. We then add the id to `newlyScheduledTaskIds`. Phase 4's bulk SO write returns 409 for that row, and:

```ts
// Only ids we scheduled in Phase 3. Skipping caller-supplied id collisions
// avoids nuking a pre-existing rule's task on a 409.
if (newlyScheduledTaskIds.has(so.id)) {
  taskIdsToCleanUp.push(so.id);
}
```

The comment is correct *only for disabled callers* — the test at lines 452-463 confirms that path. But for an **enabled** caller with a colliding id, Phase 3 *does* schedule (overwriting the existing task), `newlyScheduledTaskIds.has(so.id)` is `true`, and we then `bulkRemove` the id. Net effect: the pre-existing rule's task disappears and its rule SO orphans.

**Questions:**
- Did you trace through the "enabled rule + caller-supplied id that collides with an existing rule" scenario? It is not in the test suite. Is it intentionally out of scope (caller error) or did it slip through?
- The guard `newlyScheduledTaskIds.has(so.id)` is necessary but not sufficient. Possible mitigations: (a) pre-flight `findRules` to filter colliding ids out of `enabledInputs` before Phase 3, (b) check that the bulkSchedule return for that id wasn't an overwrite (TM doesn't expose this), or (c) document this as a known footgun. Which path did you consider?
- The design report explicitly called out this concern (Section 3.3, Phase 4). The mitigation in the report relied on `removeIfExists` being targeted at the per-row case, but it didn't address the overwrite-during-bulkSchedule path.

---

## 2. Behavioral inconsistencies with the precedent paths

### 2.1 The `bulkRemove` vs `removeIfExists` swap — was this deliberate?

Design Section 3.3 (Phase 4 per-row error handling) prescribes `taskManager.removeIfExists(rule.id)`. The implementation batches into `taskManager.bulkRemove(taskIdsToCleanUp)`:

```ts
if (taskIdsToCleanUp.length > 0) {
  try {
    await context.taskManager.bulkRemove(taskIdsToCleanUp);
  } catch (cleanupError) {
    context.logger.error(...);
  }
}
```

**Questions:**
- `bulkRemove` semantics on a non-existent id: does it throw, or skip? `removeIfExists` is idempotent by name; `bulkRemove` is not necessarily. If a task was already cleaned up by another process between Phase 3 and here, does the entire batch error out, losing cleanup for the rest? Worth verifying against `task_store.bulkRemove`.
- The test (line 444) only asserts the call shape, not idempotence under a partial-failure response.

### 2.2 ENABLE audit event is emitted but the single-rule path doesn't emit one

```ts
// Audit per-rule ENABLE for the enabled subset (mirrors single-rule semantics).
context.auditLogger?.log(
  ruleAuditEvent({
    action: RuleAuditAction.ENABLE,
    outcome: 'unknown',
    savedObject: { type: RULE_SAVED_OBJECT_TYPE, id: so.id, name: preparedRules.get(so.id)?.name },
  })
);
```

The comment says "mirrors single-rule semantics" — but the single-rule `createRule` / `createRuleSavedObject` does **not** emit a separate `RuleAuditAction.ENABLE` on create. It only emits `CREATE outcome:unknown`. The comment is misleading.

The design report (Section 3.3 Phase 6) does ask for `RuleAuditAction.ENABLE` for the enabled subset, but it incorrectly justifies that as "mirroring the single-rule path." This is a deliberate divergence.

**Questions:**
- Is the extra `ENABLE` event intentional (in which case fix the comment to say "explicitly diverges from single-rule, emits ENABLE because the rule is being scheduled") or accidental (drop it)?
- Have you signed off this audit-event delta with the security/compliance side that consumes audit logs?

### 2.3 Per-row SO failure does not emit an `outcome:failure` audit event

Single-rule `createRuleSavedObject` emits one CREATE event with `outcome:'unknown'` before the write and lets the absence of a follow-up event be the failure signal — the bulk path follows the same pattern for whole-call failures. Fine.

But for per-row SO errors in Phase 4, `bulkEnableRules` emits a paired error audit event (line 324-334 of `bulk_enable_rules.ts`). The bulk-create path doesn't emit anything when an individual SO write fails — the audit trail just shows `CREATE outcome:unknown` with no resolution.

**Question:** Should we emit a paired `CREATE error:` event for per-row SO failures so the audit log can correlate "we said unknown" → "it actually failed"?

### 2.4 Phase 1 audit log is partial

Inside `prepareRule`:

```ts
try {
  await authzCache.get(authzKey)!;
} catch (authzError) {
  context.auditLogger?.log(
    ruleAuditEvent({
      action: RuleAuditAction.CREATE,
      savedObject: { type: RULE_SAVED_OBJECT_TYPE, id, name: data.name },
      error: authzError,
    })
  );
  throw authzError;
}
```

We audit on authz failure, but **not** on schema validation failure, rule-type-not-registered, action validation failure, etc. The single-rule path is similarly partial. Probably acceptable (authz failures are security-relevant; the rest are caller-input errors), but worth a sanity check.

---

## 3. Logic / robustness questions

### 3.1 The authz cache awaits the same rejected promise from N rules

The cache keyed by `alertTypeId::consumer` means multiple rules sharing a key all await the same promise and (correctly) all get the same rejection. This means **N audit-log entries** for one underlying rejection. Not strictly wrong (each rule did fail authz), but worth confirming the rule author intended that audit volume.

### 3.2 Phase 2 demotes ALL enabled rules unconditionally, not the actual offenders

```ts
const enabledIds = enabled.map((p) => p.id);
if (validationPayload) {
  demotePreparedRules({
    ids: enabledIds,
    reason: 'schedule_limit_exceeded',
    ...
  });
}
```

`validateScheduleLimit` returns a single payload; we don't know which subset of intervals would have fit. The implementation makes the worst-case decision: demote everyone. That's safe but can be surprising if a caller submits 100 rules and only 3 push past the limit — all 100 get demoted.

**Questions:**
- Did you consider "best-fit" allocation — keep enabling rules in order until the next would breach? Or is the guarantee "either all enabled inputs pass or none survive enabled" intentional? Document the choice in the docstring.
- The design report Section 3.3 Phase 2 has an "open decision" on this — has it been resolved with product?

### 3.3 API keys are minted before the schedule-limit check — wasted work

Phase 1 mints a key per enabled rule. Phase 2 then potentially trips and invalidates every one of them. With `PREPARE_CONCURRENCY = 10` and N=1000 enabled, that's 1000 pointless ES API-key creations followed by 1000 invalidations.

**Questions:**
- Why isn't `validateScheduleLimit` done *before* Phase 1 mints keys? The interval is in the input; you don't need a fully-prepared rule to compute the cumulative interval load.
- Doing this also saves on the security-plugin throughput cost the comment near `PREPARE_CONCURRENCY` was worried about.

### 3.4 `errors` typed as `BulkOperationError[]` but population includes `BulkCreateOperationError`

`const errors: BulkOperationError[] = [];` but the result type is `BulkCreateOperationError[]` and `demotePreparedRules` pushes objects with `disabledReason`. TypeScript widens (subtype assignable) so it compiles, but this is the kind of type laxity that causes drift later.

**Suggestion:** make the local typed `BulkCreateOperationError[]` and let `demotePreparedRules` and `prepareRule` both accept that array — single source of truth.

### 3.5 Demotion + Phase 4 per-row failure → two errors for the same rule

If a rule is demoted in Phase 2 (`schedule_limit_exceeded`) and the disabled SO write then 409s in Phase 4, the user gets two errors for the same rule id:

1. `{ disabledReason: 'schedule_limit_exceeded', message: 'Rule created in a disabled state: ...' }`
2. `{ status: 409, message: 'conflict', rule.id: same }`

Noisy and could be misleading ("rule was created in disabled state… and also conflicted?"). Probably fine, but worth a deduplication pass before returning, or at least a docstring note.

### 3.6 `apiKeysMap` semantics rely on demote + delete ordering

`demotePreparedRules` deletes the entry from `apiKeysMap` *after* queuing the key for invalidation. The Phase 4 whole-call throw path then re-iterates `apiKeysMap.values()`. Since Phase 2/3 demotions remove their entries, this works — but it's fragile: any future refactor that re-orders the queue/delete will silently double-invalidate or skip-invalidate. A unit test that exercises "Phase 2 demotion + Phase 4 throw" would protect this. The tests don't cover that combination.

### 3.7 Whole-call `bulkSchedule` throw — key invalidation works, test assertion is loose

Reading carefully:

```ts
try {
  const scheduledTasks = await ...;
  scheduledIds = scheduledTasks.map((task) => task.id);
} catch (error) {
  demotePreparedRules({
    ids: survivingEnabledIds,
    reason: 'task_schedule_failed',
    ...
  });
}
```

`demotePreparedRules` does add keys to `keysToInvalidate` and remove from `apiKeysMap`. Good. The flush happens at end of function or in the SO whole-call catch. That works — but the test `expect(bulkMarkApiKeysForInvalidation).toHaveBeenCalled()` doesn't actually verify the *keys* in the call, only that it was called. Tighten that assertion to verify the right key string is in the array.

### 3.8 Defensive guard on silent per-task drop diff is meaningless

```ts
if (preparedRules.size > 0 && scheduledIds.length < survivingEnabledIds.length) {
  ...
}
```

The `preparedRules.size > 0` guard is redundant — at this point we're inside `survivingEnabled.length > 0`, so by construction `preparedRules.size > 0`. Either drop the guard or document why it's there. Minor, but reads like cargo-culted defensiveness.

### 3.9 `taskManager.bulkSchedule` ordering assumption

The diff `new Set(scheduledIds)` is order-independent, so this is safe. ✓

### 3.10 No retry on transient SO `bulkCreate` failure

Phase 4 SO write throws → invalidate keys → bulk-remove tasks → rethrow. No transient-error retry. The design report explicitly opted out of OCC because there's no conflict to resolve, but it didn't say anything about transient ES failures (timeouts, 503, etc.). Single-rule `createRule` also doesn't retry, so this matches precedent. Acceptable, but call out in docs that callers must implement their own retry.

---

## 4. Smaller issues / nits

- **`apiKeyProps` type union** — `ReturnType<typeof apiKeyAsRuleDomainProperties> | Awaited<ReturnType<typeof createNewAPIKeySet>>` is awkward. Both runtime-equivalent; pick one type via a small adapter.
- **`PREPARE_CONCURRENCY = 10`** — design report recommended `API_KEY_GENERATE_CONCURRENCY` (the same value). Why not import that constant directly so any future tuning is centralised?
- **`PreparedRule.rawRule` is `RawRule`** but `demotePreparedRules` mutates it (`delete scheduledTaskId`, `lastEnabledAt`). `RawRule` types should be reviewed to confirm those fields are optional.
- **`if (effectiveEnabled) { lastEnabledAt = ...; scheduledTaskId = id; }`** — the `scheduledTaskId = id` assumes 1:1 rule-id ↔ task-id. That's the convention everywhere, but it's the kind of invariant that deserves a code comment pointing to where it's enforced.
- **`[...data.actions, ...(data.systemActions ?? [])]`** — `data.systemActions ?? []` is reasonable, but `data.actions` is *not* defaulted to `[]`. Is `data.actions` guaranteed non-null by `createRuleDataSchema`? Worth a peek.
- **`if (prepared) preparedRules.set(id, prepared); else if (error) errors.push(error);`** — what if both are undefined? `prepareRule` always returns one or the other, but the `else if` is asymmetric — make it just `else`.
- **`updateMeta(context, prepared.rawRule)`** mutates `prepared.rawRule`. After demotion, we already mutated it. `updateMeta` should be idempotent on the disabled shape, but the mutation chain is non-obvious.
- **No `withSpan` around `validateScheduleLimit`, `extractReferences`, `validateActions`, etc.** Single-rule `createRule` wraps each in `withSpan`. The bulk path skips this for performance reasons? Or oversight? Observability gap either way.
- **Empty-input early return:** `total` is `rules.length`, but the empty-input early-return uses `total: 0`. `total` was set to `rules.length` already; just use `total`. Trivial.
- **`pMap` concurrency over `inputsWithIds`** — no error-on-throw; `prepareRule` itself catches and returns. ✓ Good.

---

## 5. What I'd ask the engineer to do before this lands

1. **Make the test compile** — either export `BULK_CREATE_AS_DISABLED_PREFIX` (and use it as the prefix in `getBulkCreateAsDisabledMessage`) or drop the prefix assertion in favor of `disabledReason`.
2. **Add `addMissingUiamKeyTagIfNeeded`** in `prepareRule` for enabled rules, parallel to the single-rule path. Add a serverless+feature-flag test.
3. **Cover the missing test:** "Phase 4 per-row 409 on a caller-supplied id that *was* scheduled in Phase 3" (i.e., enabled rule with colliding caller id). Decide what the right behavior is. Currently it nukes the pre-existing rule's task.
4. **Move `validateScheduleLimit` ahead of API-key minting** in Phase 1, or document why ordering can't change.
5. **Reconcile the audit-event story:** drop the `ENABLE` event or fix the comment, and decide whether per-row SO failure should emit a paired error event.
6. **Tighten test assertions** (e.g. `bulkMarkApiKeysForInvalidation` should be called *with which keys*, not just "called").
7. **Add a Phase-2-demotion + Phase-4-throw combined test** to lock in `apiKeysMap` ordering invariants.
8. **Verify `taskManager.bulkRemove` partial-failure semantics** vs `removeIfExists`.

---

## Verdict

The overall structure of the file (Phase 0–6, demote-don't-fail philosophy, isolated `prepareRule`, batched TM cleanup, end-of-function key flush) is **sound and follows the design report faithfully**. The issues above are mostly correctness-on-the-edges and test/audit hygiene rather than architectural problems.

But (1.1) and (1.2) at minimum need to be fixed before this is mergeable; (1.3) needs a decision recorded one way or the other.
