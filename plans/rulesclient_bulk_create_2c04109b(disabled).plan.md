---
name: RulesClient bulk create (disabled-only)
overview: Add a new application-layer `bulkCreateRules` that bulk-persists rule SOs in a single Elasticsearch operation. The API only accepts disabled rules — callers wanting an enabled rule must follow up with `bulkEnableRules`.
todos:
  - id: add-bulk-create-app
    content: Add `application/rule/methods/bulk_create/` with `bulkCreateRules`, types, and index barrel — 2-phase pipeline (prepare → bulkCreate SO).
    status: pending
  - id: wire-rules-client
    content: Import and expose `bulkCreateRules` on `RulesClient` in `rules_client.ts`.
    status: pending
  - id: tests
    content: Add `bulk_create_rules.test.ts` covering enabled-rule rejection, mixed successes/errors, and SO partial failures.
    status: pending
isProject: false
---

# Add `bulkCreateRules` to alerting `RulesClient` (disabled-only)

## Core requirement

All rules must be inserted into Elasticsearch **in one go** — no per-rule SO roundtrips, no concurrency throttle.

## Scope restriction: disabled rules only

`bulkCreateRules` rejects any input with `data.enabled === true`. Callers wanting an enabled rule run `bulkCreateRules` followed by `bulkEnableRules({ ids })`. This restriction:

- Removes API-key generation, tracking, and invalidation (disabled rules don't get keys, see [`create_rule.ts` lines 140-158](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L140-L158)).
- Removes the `taskManager.bulkSchedule` call (disabled rules don't have tasks, see [`create_rule_saved_object.ts` line 102](x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts#L102)).
- Removes the schedule-limit circuit breaker (disabled rules don't count toward the per-minute cap, see [`create_rule.ts` line 94](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L94)).
- Removes the rollback-on-schedule-failure path.
- Reduces the bulk operation to a single ES call: `savedObjectsClient.bulkCreate`.

The motivating use case (security-solution prebuilt rule installation) already creates with `enabled: rule.enabled ?? false` ([`detection_rules_client/methods/create_rule.ts` line 48](x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/create_rule.ts#L48)), so this restriction is a clean fit.

## SO calls used

| Layer | Function | ES call |
|-------|----------|---------|
| SO create | [`bulkCreateRulesSo`](x-pack/platform/plugins/shared/alerting/server/data/rule/methods/bulk_create_rule_so.ts) → `savedObjectsClient.bulkCreate` | **1 bulk create** |

That's it. No `taskManager.bulkSchedule`, no `bulkUpdateRuleSo`, no `bulkMarkApiKeysForInvalidation`.

## Pipeline

```
bulkCreateRules(context, params)
  │
  ├─ Validation gate
  │     For every input with data.enabled === true:
  │       push BulkOperationError { message: 'bulkCreateRules only supports disabled rules; use bulkEnableRules to enable after creation', rule: { id: options?.id ?? 'n/a', name } }
  │     Skip those inputs in Phase 1.
  │
  ├─ Phase 1 – PREPARE (Promise.all, no throttle, per-rule try/catch)
  │     For each remaining input, inside its own try/catch:
  │     ├─ addGeneratedActionValues
  │     ├─ createRuleDataSchema.validate(data)
  │     ├─ ruleTypeRegistry.get + ensureRuleTypeEnabled
  │     ├─ authorization.ensureAuthorized  (WriteOperations.Create) — emits CREATE-failure audit on deny
  │     ├─ validateRuleTypeParams
  │     ├─ validateActions + validateAndAuthorizeSystemActions
  │     ├─ minimum-interval enforcement (Boom.badRequest if enforce && < min)
  │     ├─ extractReferences
  │     ├─ transformRuleDomainToRuleAttributes (apiKey/owner/createdByUser all null, no scheduledTaskId, no lastEnabledAt)
  │     └─ updateMeta(rawRule)
  │     Result per item: { kind: 'ok', rawRule, references, ruleId }
  │                    | { kind: 'err', error: BulkOperationError }
  │     After the loop, emit a per-rule RuleAuditAction.CREATE audit with outcome 'unknown' for every successful prepare.
  │
  └─ Phase 2 – PERSIST (one call)
      bulkCreateRulesSo({ savedObjectsClient, bulkCreateRuleAttributes: rawRulesToCreate })
      On whole-batch throw: propagate (no API keys to clean up).
      On partial SO errors: walk result.saved_objects; push rejected rows into errors[].
      Convert successful saved_objects to SanitizedRule via transformRuleAttributesToRuleDomain → transformRuleDomainToRule.

      Return { rules, errors, total }
```

### Per-rule failure isolation in Phase 1 (mirror `bulk_edit_rules_occ`)

Use the same shape as [`bulk_edit_rules.ts`](x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/bulk_edit_rules.ts#L174-L189):

- Shared accumulators: `errors: BulkOperationError[]`, `rawRulesToCreate: Array<SavedObjectsBulkCreateObject<RawRule>>`.
- Wrap each rule's prepare in `try`/`catch`. On any failure: push `{ message, rule: { id, name } }` to `errors[]` and emit a `RuleAuditAction.CREATE` failure audit. **Do not rethrow** — `Promise.all` would short-circuit.
- Successful rules are appended to `rawRulesToCreate[]`.

### No API keys, no schedule limit, no task scheduling

These are the entire reason for the `enabled === false` restriction. Implementing them would require Phase 0 + Phase 3 + the `apiKeysMap` / `bulkMarkApiKeysForInvalidation` machinery from the previous version of this plan; the disabled-only contract eliminates all of it.

### Audit events

Per-rule `context.auditLogger?.log(ruleAuditEvent({ action: RuleAuditAction.CREATE, outcome: 'unknown', ... }))` after a successful prepare. Per-rule failure audit on caught error (matches `createRuleSavedObject`).

## Return shape

```ts
interface BulkCreateRulesResult<Params extends RuleTypeParams> {
  rules: Array<SanitizedRule<Params>>;  // successful creates, in input order
  errors: BulkOperationError[];         // per-rule failures (incl. enabled-rule rejections)
  total: number;                        // params.rules.length
}
```

`BulkOperationError` from [`rules_client/types.ts`](x-pack/platform/plugins/shared/alerting/server/rules_client/types.ts).

Note: `taskIdsFailedToBeScheduled` is **not** part of the result — there is no scheduling step.

## Files to add

| Area | Path |
|------|------|
| Implementation | `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts` |
| Params/result types | `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/types.ts` |
| Barrel | `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/index.ts` |

## Files to change

- [`rules_client.ts`](x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts): add import + `public bulkCreateRules = <Params extends RuleTypeParams = never>(params: BulkCreateRulesParams<Params>) => bulkCreateRules(this.context, params)` next to `bulkDeleteRules` / `bulkEnableRules`.

## Out of scope

- HTTP route / OpenAPI for bulk create.
- New `RuleAuditAction.BULK_CREATE` — per-rule `CREATE` audit fires from Phase 1.
- `pMap` / concurrency throttle — Phase 1 uses `Promise.all`; Phase 2 is a single call.
- Enabled rules — callers must follow up with `bulkEnableRules` if the rule should run.
