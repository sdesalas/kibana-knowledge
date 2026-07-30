# Alerting V1 vs V2 — API key treatment

**Date:** 2026-07-30  
**Context:** Follow-up from review of [PR #276947](https://github.com/elastic/kibana/pull/276947) (rule change history / `metadata.version`), while comparing domain snapshots vs SO attrs.  
**Branch referenced:** `alerting-v2-rule-versioning` (and current V1 alerting / Task Manager code on that branch).

---

## Summary

V1 stores the rule’s execution API key **on the rule saved object** (encrypted).  
V2 does **not** — the rule SO has no `apiKey`. Execution identity lives on the **Task Manager task**, provisioned with `cloneApiKey: true` when the executor task is scheduled.

V2 still uses an encrypted SO `apiKey` pattern for **action policies** (`auth.apiKey`), which is closer to V1’s rule pattern but scoped to policies, not rules.

---

## V1 — key on the rule SO

### What is stored

Rule SO attributes include (among others):

- `apiKey` — encrypted secret (base64 `id:key`)
- `apiKeyOwner` — username that owns/created it
- `apiKeyCreatedByUser` — whether the caller’s own key was reused vs granted/cloned
- (UIAM path) `uiamApiKey` also encrypted

Registration:

```ts
// x-pack/platform/plugins/shared/alerting/server/saved_objects/index.ts
export const RuleAttributesToEncrypt = ['apiKey', 'uiamApiKey'];
```

Export strips secrets (`apiKey` / `apiKeyOwner` / `apiKeyCreatedByUser` → null).

### How it is used at runtime

1. User creates/updates/enables a rule → RulesClient creates or rotates an API key and writes it onto the rule SO via Encrypted Saved Objects.
2. Task Manager schedules the rule’s executor task (task params typically reference the rule id).
3. On run, the alerting task runner decrypts the rule SO, reads `apiKey`, and builds a request under that identity to query ES / write alerts / enqueue actions.

Invalidation is deferred via an `api_key_pending_invalidation`-style SO (and related tasks), so deletes/rotations don’t always revoke immediately.

### Implications

- Rule SO is an **encrypted type**.
- Change history / export / import must carefully exclude or null secrets (V1 export already nulls them).
- Key lifecycle (create, rotate on update, invalidate on delete) is owned by Alerting’s RulesClient.

---

## V2 — key on the Task Manager task (for rules)

### What is stored on the rule

`RuleSavedObjectAttributes` has **no** `apiKey` / `apiKeyOwner` fields.

`alerting_rule` is registered as a normal SO type — **not** passed to `encryptedSavedObjects.registerType`.

Only action policies are encrypted in V2’s SO registration:

```ts
// x-pack/platform/plugins/shared/alerting_v2/server/saved_objects/index.ts
export const ActionPolicyAttributesToEncrypt = ['auth.apiKey'];
// encryptedSavedObjects.registerType({ type: ACTION_POLICY_..., attributesToEncrypt: ... })
```

### How rule execution auth works

When a rule is created, enabled, or its schedule is re-synced while enabled, `RulesClient` schedules the executor via:

```ts
// x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_executor/schedule.ts
await taskManager.ensureScheduled(
  {
    id: getRuleExecutorTaskId({ ruleId, spaceId }),
    taskType: ALERTING_RULE_EXECUTOR_TASK_TYPE,
    schedule,
    params: { ruleId, spaceId },
    state: {},
    scope: ['alerting'],
    enabled: true,
  },
  { request, cloneApiKey: true }
);
```

`cloneApiKey: true` tells Task Manager to:

1. Take the **current HTTP request** (the user enabling/creating the rule).
2. **Clone** an API key (or reuse according to TM’s strategy / UIAM path).
3. Persist that key on the **task** document (TM’s encrypted task attributes).
4. On each run, build a fake Kibana request with `Authorization: ApiKey …` (`buildTaskFakeRequest`) and run the executor under that identity.

Bulk enable uses the same idea: `taskManager.bulkSchedule(..., { request, cloneApiKey: true })`.

The V2 rule executor task runner itself only receives `{ ruleId, spaceId }` in params — it does not decrypt a rule-level apiKey.

### Implications

- Rule SO stays free of secrets → safer for change-history snapshots (`RuleResponse`), exports, and domain-vs-SO divergence.
- Re-scheduling / self-heal on enable–disable matters for **task + key** health, not just `enabled: true` on the rule.
- Key lifecycle for execution is largely **Task Manager’s** concern at schedule time, not RulesClient writing encrypted attrs onto the rule.

---

## V2 — where encrypted apiKeys still exist

| Surface | Encrypted field | Purpose |
|---------|-----------------|--------|
| **Action policy** SO | `auth.apiKey` (+ AAD on `auth.owner`, `auth.createdByUser`) | Credentials used when dispatching actions under that policy |
| **API key pending invalidation** SO | ids / UIAM material as designed | Deferred invalidation after policy key rotation/delete |
| **Task Manager task** SO | task apiKey (TM-owned) | Rule executor (and other tasks) runtime identity |

`ApiKeyService` in alerting_v2 (`server/lib/services/api_key_service`) is used by **ActionPolicyClient** (grant/clone + `markApiKeysForInvalidation`), not by RulesClient for rule execution.

---

## Side-by-side

| Concern | V1 rules | V2 rules |
|---------|----------|----------|
| Where is the execution key? | Rule SO (`apiKey`, encrypted) | Task Manager task (`cloneApiKey: true`) |
| Is the rule SO encrypted? | Yes (`apiKey`, `uiamApiKey`) | No |
| Who creates the key? | Alerting RulesClient | Task Manager at `ensureScheduled` / `bulkSchedule` |
| Owner metadata on rule? | `apiKeyOwner`, `apiKeyCreatedByUser` | Not on rule (task holds identity) |
| Appears in API / domain model? | Stripped / never returned as secret | N/A on rule |
| Change-history risk | Must never snapshot decrypted `apiKey` | Rule snapshots have no apiKey field |
| Closest V2 analogue to V1 rule apiKey | — | Action policy `auth.apiKey` (policies only) |

---

## Why this matters for change history / domain snapshots

PR #276947 stores **`RuleResponse`** (domain / API shape) as `object.snapshot`, not raw SO attributes.

Because V2 rules never put `apiKey` on the SO (or on `RuleResponse`), history cannot accidentally persist execution secrets the way a naive “dump SO attrs” approach could have in V1.

If V2 later added a persistence-only secret on the rule SO, the domain transform would still be the place that must **omit** it from snapshots — same discipline V1 needed for export.

---

## Mental model

```
V1:  User request → RulesClient creates apiKey → encrypted on RULE SO
                   → task runs → decrypt RULE → use rule.apiKey

V2:  User request → RulesClient writes RULE (no secret)
                   → taskManager.ensureScheduled(..., { cloneApiKey: true })
                   → apiKey encrypted on TASK SO
                   → task runs → fake request from TASK apiKey → load RULE by id
```

---

## Code pointers

**V1**

- `x-pack/platform/plugins/shared/alerting/server/saved_objects/index.ts` — `RuleAttributesToEncrypt`
- `x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/v*.ts` — `apiKey`, `apiKeyOwner`, …
- `x-pack/platform/plugins/shared/alerting/server/saved_objects/transform_rule_for_export.ts` — nulls secrets on export

**V2**

- `x-pack/platform/plugins/shared/alerting_v2/server/saved_objects/index.ts` — rule not encrypted; action policy is
- `x-pack/platform/plugins/shared/alerting_v2/server/lib/rule_executor/schedule.ts` — `cloneApiKey: true`
- `x-pack/platform/plugins/shared/alerting_v2/server/lib/rules_client/rules_client.ts` — `scheduleRuleExecutorTask` / bulk schedule
- `x-pack/platform/plugins/shared/alerting_v2/server/lib/services/api_key_service/api_key_service.ts` — action-policy keys
- `x-pack/platform/plugins/shared/task_manager/server/lib/api_key_utils.ts` — clone/grant for tasks
- `x-pack/platform/plugins/shared/task_manager/server/task_running/fake_request_factory.ts` — runtime fake request
