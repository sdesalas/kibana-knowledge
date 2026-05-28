---
name: bulk-create verifyBatches() extraction
overview: "Move whole-call, in-memory rule validation out of per-batch `runBatch()` and into a new `verifyBatches()` step that runs once over every input. Failing rules are REMOVED from the call (not demoted), `exitEarlyOnError=true` short-circuits before any ES write. Also drop manual `runAt`/`scheduledAt` and `BULK_TM_SCHEDULE_DELAY` from `buildTaskInstance` so Task Manager's jitter (commit 6669b2a) applies on `bulkSchedule`."
todos:
  - id: types
    content: "Update types.ts: drop `authzCache` from `PrepareRuleArgs`. No new exported types needed (verifyBatches return is inline)."
    status: pending
  - id: verify-batches
    content: "Add `verifyBatches()` to utils.ts. Phase 1: sequential per-rule for-loop, cheap-first try/catch (addGeneratedActionValues -> createRuleDataSchema.validate -> ruleTypeRegistry.get -> ensureRuleTypeEnabled -> validateRuleTypeParams -> parseDuration + full min-interval gate (enforce reject + non-enforce warn)). Phase 2: deduped per-pair ensureAuthorized; on rejection, per-rule CREATE-failure audit + per-rule error. Skip Phase 2 entirely if Phase 1 left zero survivors. Returns `{ survivors, errors }`."
    status: pending
  - id: slim-prepare-rule
    content: "Trim `prepareRule` in utils.ts: drop createRuleDataSchema.validate, ruleTypeRegistry.get/ensureRuleTypeEnabled, validateRuleTypeParams, the authzCache + ensureAuthorized block, and the ENTIRE parseDuration + min-interval block. Keep a single registry.get call at top (to get `ruleType` for downstream calls). Keep the second addGeneratedActionValues call (its output is what lands in the SO)."
    status: pending
  - id: task-instance
    content: "In `buildTaskInstance` (utils.ts): delete `runAt: new Date()` and `scheduledAt: new Date()` fields. Delete the commented `// import { BULK_TM_SCHEDULE_DELAY }` line."
    status: pending
  - id: constants
    content: "Remove `BULK_TM_SCHEDULE_DELAY` from `x-pack/.../rules_client/common/constants.ts` (no remaining production references after this change)."
    status: pending
  - id: bulk-rewire
    content: "Rewire `bulkCreateRules`: assign ids up-front for ALL inputs, call `verifyBatches` once over them, append verifyErrors to top-level errors[], honour exitEarlyOnError + zero-survivors short-circuit, slice survivors into batches, call `runBatch` with pre-id'd batch input (no longer assigns ids inside runBatch). Remove the `authzCache` inside runBatch."
    status: pending
  - id: tests-verify
    content: "Expand bulk_create_rules.test.ts: verifyBatches coverage — per-rule isolation (one schema-invalid rule does not affect others), exitEarlyOnError short-circuit (zero ES writes), zero-survivors short-circuit (no authz call), unregistered/disabled alertTypeId, invalid params, parseDuration + min-interval enforce-reject and non-enforce-warn move into verifyBatches, deduped per-pair authz with per-rule audit+error on rejection, partial-authz (pair A passes, pair B rejected)."
    status: pending
  - id: tests-taskinstance
    content: "Update existing task-instance tests in bulk_create_rules.test.ts: drop `BULK_TM_SCHEDULE_DELAY` import and the `minRunAt = now + BULK_TM_SCHEDULE_DELAY` assertions; assert `bulkSchedule` is called with task instances WITHOUT `runAt`/`scheduledAt`."
    status: pending
  - id: verify
    content: "Run scripts/type_check for alerting plugin; scripts/jest on bulk_create folder; scripts/eslint --fix on changed files; scripts/check_changes.ts."
    status: pending
isProject: false
---


# bulk_create_rules: verifyBatches() extraction

## Goals

1. Pull cheap, fail-fast per-rule validation **out of per-batch `runBatch()`** and **up into a whole-call `verifyBatches()`** that runs exactly once over every input before any batch loop iteration.
2. Treat `verifyBatches` failures as **removals** (push to `errors[]`, exclude from `runBatch` entirely). The existing 4 in-batch demotion paths (`api_key_creation_failed`, `schedule_limit_exceeded`, `task_schedule_failed`, `task_validation_failed`) stay in `runBatch` unchanged.
3. Honor `exitEarlyOnError`: if any rule fails verifyBatches **and** the flag is set, return immediately with the collected errors and **zero ES writes**.
4. Drop alerting-side `runAt` / `scheduledAt` / `BULK_TM_SCHEDULE_DELAY` so TM's `addJitter` (commit `6669b2a`) applies on `bulkSchedule` and avoids the thundering-herd problem when a large bulk lands.

Confirmed scope decisions (from clarifying questions):

- All verifyBatches failures are **REMOVE**, never demote.
- `parseDuration` + the **full** minimum-interval gate (`enforce=true` reject branch AND `enforce=false` warn branch) move into verifyBatches. `prepareRule` no longer touches the schedule interval.
- Phase 1 is a **sequential** `for` loop (tightest memory; no I/O so still fast at the 10k cap).
- `addGeneratedActionValues` is **re-run** inside `prepareRule` on survivors; the Phase 1 output is discarded (memory-lean; ~250ms duplicate CPU at 10k cap is acceptable).
- Phase 2 emits **per-rule** `RuleAuditAction.CREATE` failure audit events on pair rejection (preserves today's per-rule audit cardinality from `prepareRule`).

## Files to change

- [bulk_create_rules.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts)
- [utils.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts)
- [types.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/types.ts)
- [constants.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/common/constants.ts)
- [bulk_create_rules.test.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.test.ts)

## `verifyBatches()`

Lives in `utils.ts` next to `prepareRule`. Signature:

```ts
export const verifyBatches = async <Params extends RuleParams>({
  context,
  inputsWithIds,
}: {
  context: RulesClientContext;
  inputsWithIds: Array<{ id: string; rule: BulkCreateRulesItem<Params> }>;
}): Promise<{
  survivors: Array<{ id: string; rule: BulkCreateRulesItem<Params> }>;
  errors: BulkCreateOperationError[];
}>;
```

Internal scratch is created and discarded inside the function — the caller receives only the two lean arrays. No new types exported.

### Phase 1: per-rule, cheapest first (sequential, in-memory)

A single `for ... of inputsWithIds` loop. Each iteration is wrapped in its own `try / catch`; one bad rule does not affect the others. On the **first throw**, push a `BulkCreateOperationError` keyed by `id`, then `continue` to the next rule.

Per rule, in this exact order (stop at first failure):

1. `addGeneratedActionValues(rule.data.actions, rule.data.systemActions, context)` — KQL parse can throw `Boom.badRequest`. Result is held in a local `data` variable for the rest of the iteration.
2. `createRuleDataSchema.validate(data)` — schema. Catch and re-throw as `Boom.badRequest('Error validating create data - ${err.message}')` to match the single-rule `create_rule.ts` semantics.
3. `ruleTypeRegistry.get(data.alertTypeId)` — throws 400 if unregistered. Captured into local `ruleType`.
4. `ruleTypeRegistry.ensureRuleTypeEnabled(data.alertTypeId)` — throws if disabled.
5. `validateRuleTypeParams(data.params, ruleType.validate.params)` — params shape.
6. `parseDuration(data.schedule.interval)` — throws if interval format is invalid. Hold result as `intervalInMs`.
7. Minimum-interval gate (full block moves from `prepareRule`):
   - if `intervalInMs < context.minimumScheduleIntervalInMs && context.minimumScheduleInterval.enforce` → throw `Boom.badRequest('Error creating rule: the interval is less than the allowed minimum interval of ${context.minimumScheduleInterval.value}')`. Rule is REMOVED.
   - if `intervalInMs < context.minimumScheduleIntervalInMs && !context.minimumScheduleInterval.enforce` → `context.logger.warn(...)` with the exact existing message (substitute `ruleType.id` and `id`) and continue. Rule is RETAINED.

At end of iteration, the entry pushed to the `survivors` array is just `{ id, rule }` — the locally generated `data` (with action UUIDs), `ruleType`, and `intervalInMs` are all discarded. `addGeneratedActionValues` will be re-run inside `prepareRule` for survivors only; this is an explicit memory-vs-CPU trade.

Also collect, for each survivor, the unique `${alertTypeId}::${consumer}` pair into a `Map<authzKey, { ruleTypeId, consumer, ids: string[], names: Map<id, name> }>` so Phase 2 can iterate pairs once.

If **zero rules** survive Phase 1, return `{ survivors: [], errors }` immediately. Phase 2 is skipped — the contract is "in-memory checks first, ES later", so a totally-invalid call performs zero ES reads.

### Phase 2: deduped per-pair `ensureAuthorized`

Iterate the pair-map. For each unique pair, wrap a single `context.authorization.ensureAuthorized({ ruleTypeId, consumer, operation: WriteOperations.Create, entity: AlertingAuthorizationEntity.Rule })` in a `try / catch`.

On rejection:

- For **each rule id** in the rejected pair: emit one `RuleAuditAction.CREATE` audit event with `savedObject: { type: RULE_SAVED_OBJECT_TYPE, id, name }` and the caught error (mirrors today's per-rule audit emitted by `prepareRule`).
- Push a per-rule `BulkCreateOperationError` for each id in the pair to `errors[]`.
- Remove every id in the pair from the survivors list.
- Continue checking other pairs — one rejected pair must not skip the others.

Phase 2 **never throws**. All failures are converted to per-rule errors regardless of `exitEarlyOnError` (the caller decides what to do).

## Caller wiring in `bulkCreateRules`

```ts
const username = await context.getUserName();
const actionsClient = await context.getActionsClient();
const successfulIds: string[] = [];
const errors: BulkCreateOperationError[] = [];

const inputsWithIds = rules.map((rule) => ({
  id: rule.options?.id ?? SavedObjectsUtils.generateId(),
  rule,
}));

const { survivors, errors: verifyErrors } = await verifyBatches({ context, inputsWithIds });
errors.push(...verifyErrors);

if (verifyErrors.length > 0 && exitEarlyOnError) {
  logger.warn(
    `bulkCreateRules: exiting early on verifyBatches; ${verifyErrors.length} rule(s) failed pre-flight, zero ES writes.`
  );
  return { successfulIds, errors, total };
}
if (survivors.length === 0) {
  return { successfulIds, errors, total };
}

const totalBatches = Math.ceil(survivors.length / batchSize);
logger.debug(
  `bulkCreateRules: ${total} input(s), ${survivors.length} survivor(s) after verifyBatches, ${totalBatches}x batches of ${batchSize}.`
);

for (let batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
  const start = batchIndex * batchSize;
  const batch = survivors.slice(start, start + batchSize);
  const result = await runBatch<Params>({ context, username, actionsClient, batch });
  successfulIds.push(...result.successfulIds);
  errors.push(...result.errors);
  if (exitEarlyOnError && result.soFailureOccurred) { /* existing early-exit log + break */ }
}

return { successfulIds, errors, total };
```

ID generation moves from `runBatch` up to `bulkCreateRules` so `verifyBatches` operates against final ids (needed for Phase 2 audit / error reporting).

## `runBatch` changes

- `RunBatchArgs.batch` becomes `Array<{ id: string; rule: BulkCreateRulesItem<Params> }>` instead of `Array<BulkCreateRulesItem<Params>>`.
- Drop the inline `inputsWithIds = batch.map(...)` step — ids are already attached.
- Drop the `authzCache = new Map<string, Promise<void>>()` — Phase 2 of verifyBatches owns deduped authz now.
- `pMap` over `batch` (with `API_KEY_GENERATE_CONCURRENCY`) still calls `prepareRule`, but with a slimmer `PrepareRuleArgs` (no `authzCache`).
- Phases 2–4 of `runBatch` (`validateScheduleLimit`, `bulkSchedule`, `bulkCreate`, per-row outcomes, cleanups) stay byte-for-byte as today.

## `prepareRule` slim-down (in utils.ts)

Remove from `prepareRule`:

- `createRuleDataSchema.validate(data)` block.
- `ruleTypeRegistry.get(data.alertTypeId)` (the first standalone call) — keep only the single later call needed to obtain `ruleType` for downstream use.
- The `authzCache` plumbing + the `context.authorization.ensureAuthorized` call + its catch/audit block (Phase 2 of `verifyBatches` owns this now).
- `ruleTypeRegistry.ensureRuleTypeEnabled(data.alertTypeId)`.
- `const ruleType = context.ruleTypeRegistry.get(data.alertTypeId)` stays (or move to the top — there must be exactly one in the survivor path).
- `const validatedRuleTypeParams = validateRuleTypeParams(data.params, ruleType.validate.params)` — already validated upstream; replace with `validatedRuleTypeParams = data.params as <typed>` OR re-call `validateRuleTypeParams` cheaply (it's pure CPU). Recommend keeping the call (cheap, no I/O, makes the local invariant explicit). Confirm in implementation.
- The ENTIRE `parseDuration` + min-interval block (both branches — enforce-reject throw AND enforce=false warn) — moved into verifyBatches.

Keep in `prepareRule`:

- The second `addGeneratedActionValues` call (its output is what lands in the SO).
- `validateActions`, `validateAndAuthorizeSystemActions`.
- API-key mint with the existing soft-fail to `api_key_creation_failed` demotion.
- `extractReferences`, `transformRuleDomainToRuleAttributes`, `addMissingUiamKeyTagIfNeeded`.
- The single per-rule CREATE audit emitted inside `runBatch` after `prepareRule` returns — unchanged.

## `buildTaskInstance` + `BULK_TM_SCHEDULE_DELAY`

In [utils.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/utils.ts):

```ts
export const buildTaskInstance = (
  context: RulesClientContext,
  prepared: PreparedRule
): TaskInstanceWithDeprecatedFields => ({
  id: prepared.id,
  taskType: `alerting:${prepared.ruleTypeId}`,
  schedule: prepared.schedule,
  params: { alertId: prepared.id, spaceId: context.spaceId, consumer: prepared.consumer },
  state: { previousStartedAt: null, alertTypeState: {}, alertInstances: {} },
  scope: ['alerting'],
  enabled: true,
  // runAt / scheduledAt intentionally omitted — TM addJitter (commit 6669b2a) applies.
});
```

Also delete the commented `// import { BULK_TM_SCHEDULE_DELAY } from '../../../../rules_client/common/constants';` line at the top.

In [constants.ts](x-pack/platform/plugins/shared/alerting/server/rules_client/common/constants.ts):

- Delete the `export const BULK_TM_SCHEDULE_DELAY = 30_000;` line. (Verified above: the only remaining references are the alerting-side test file, which is also being updated.)

## Types

In [types.ts](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/types.ts):

- Remove `authzCache: Map<string, Promise<void>>;` from `PrepareRuleArgs`.
- No new exported types — `verifyBatches`'s return shape is inline; internal pair/scratch maps are private to `utils.ts`.

`BulkCreateOperationError` and `BulkCreateDisabledReason` are unchanged (verifyBatches errors never carry a `disabledReason`; they're plain removals).

## Control flow

```mermaid
flowchart TD
  Start[bulkCreateRules] --> Cap[Reject if total > MAX]
  Cap --> Clamp[Clamp batchSize]
  Clamp --> Ids["Assign ids up front for ALL inputs"]
  Ids --> Verify["verifyBatches (Phase 1 in-mem sequential + Phase 2 deduped authz)"]
  Verify --> Early{verifyErrors > 0 AND exitEarlyOnError?}
  Early -->|yes| Done["Return collected errors; zero ES writes"]
  Early -->|no| Survivors{survivors.length === 0?}
  Survivors -->|yes| Done
  Survivors -->|no| Loop[Slice survivors into batches]
  Loop --> RunBatch["runBatch: prepareRule (slim) -> validateScheduleLimit -> bulkSchedule -> bulkCreate"]
  RunBatch --> SoCheck{exitEarlyOnError AND SO failure?}
  SoCheck -->|yes| Done
  SoCheck -->|no| More{More batches?}
  More -->|yes| RunBatch
  More -->|no| Done
```

## Test plan (`bulk_create_rules.test.ts`)

New `verifyBatches` cases (add `describe('verifyBatches')` block):

- **Per-rule isolation**: one schema-invalid input among three valid → invalid reported in `errors[]`, two valid forwarded to `runBatch`; `runBatch` mock asserts the batch contains only the survivors.
- **All inputs fail verifyBatches** → zero calls to `validateScheduleLimit`, `taskManager.bulkSchedule`, `unsecuredSavedObjectsClient.bulkCreate`, `createAPIKey`, **and `authorization.ensureAuthorized`**. The Phase 2 skip is asserted explicitly.
- **`exitEarlyOnError=true` + at least one verifyBatches error** → returns immediately with collected errors; zero ES writes; zero `runBatch` invocations.
- **Unregistered `alertTypeId`** → per-rule error originating from `verifyBatches` (assert error message matches the registry throw); `runBatch` not called for that id.
- **Disabled `alertTypeId`** (`ensureRuleTypeEnabled` throws) → per-rule error from verifyBatches.
- **Invalid params** (`validateRuleTypeParams` throws) → per-rule error from verifyBatches.
- **`parseDuration` throws** (malformed interval string) → per-rule error from verifyBatches.
- **Minimum-interval, enforce=true, interval < min** → per-rule error from verifyBatches (rule REMOVED). Assert error message matches the existing one.
- **Minimum-interval, enforce=false, interval < min** → `logger.warn` called from verifyBatches; rule retained and forwarded to runBatch. Assert warn message format unchanged.
- **Deduped per-pair authz**: two rules with the same `${alertTypeId}::${consumer}`, both unauthorized → `ensureAuthorized` called **exactly once**; both rules get per-rule `RuleAuditAction.CREATE` failure audit events; both rules in `errors[]`; neither reaches `runBatch`.
- **Partial authz**: pair A authorized, pair B rejected → only pair A's rules survive; pair B rules get audit + error; pair A's rules reach `runBatch`.
- **`addGeneratedActionValues` runs twice per successful rule** (once in verifyBatches, once in prepareRule) — assert final SO actions still carry generated UUIDs; not a behavioural change, just a non-regression check.

Existing `runBatch` cases to adjust:

- The "all-enabled happy path" task-instance test and the "per-batch runAt is at least the buffer beyond now" test: drop the `BULK_TM_SCHEDULE_DELAY` import and the `minRunAt = now + BULK_TM_SCHEDULE_DELAY` assertions; instead assert each task instance passed to `bulkSchedule` does **not** contain `runAt` or `scheduledAt`.
- Anywhere existing tests stub `context.ruleTypeRegistry.get` / `ensureRuleTypeEnabled` / `validateRuleTypeParams` / `authorization.ensureAuthorized` expecting them to be called from inside `prepareRule`/`runBatch`: move those expectations to the verifyBatches block.
- Existing tests that assert ids are generated inside `runBatch` need to switch to asserting ids are generated inside `bulkCreateRules` before verifyBatches.

## Out of scope (deliberately)

- Per-batch connector prefetch / `preFetchedActions` shared-helper signature changes.
- Moving `validateScheduleLimit` out of `runBatch` (it depends on the surviving enabled subset post-API-key-mint; that subset is only known after `prepareRule`).
- Security-solution-side changes — [bulk_import_rules.ts](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_import_rules.ts) and [bulk_create_prebuilt_rules.ts](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_create_prebuilt_rules.ts) already domain-pre-flight on their side and benefit automatically.

## Verification

- `node scripts/type_check --project x-pack/platform/plugins/shared/alerting/tsconfig.json`
- `node scripts/jest x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/`
- `node scripts/eslint --fix $(git diff --name-only)`
- `node scripts/check_changes.ts`
