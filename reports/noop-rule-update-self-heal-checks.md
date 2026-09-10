# No-op rule updates: cheap self-heal for stale API keys and missing TM tasks

**Date:** 2026-09-10  
**Issue:** [elastic/kibana#285343](https://github.com/elastic/kibana/issues/285343)  
**Related:** [elastic/kibana#145093](https://github.com/elastic/kibana/issues/145093) (`bulkEdit` already skips no-ops), [elastic/kibana#275204](https://github.com/elastic/kibana/issues/275204) (import overwrite → `bulkUpdate`), [sdh-security-team#1026](https://github.com/elastic/sdh-security-team/issues/1026#issuecomment-2236628506) (no-op update used to rotate stale keys)  
**Slack:** [DEX thread](https://elastic.slack.com/archives/C09S1NKF8HX/p1786733442774769?thread_ts=1781628763.734789&cid=C09S1NKF8HX) (Georgii: empty history is a bug); [kibana-alerting](https://elastic.slack.com/archives/CHSSGF015/p1787554824052939) (Mike Cote: treat key/task repair as edge cases)

---

## Verdict

Skip no-op writes by default. Before skipping, run two cheap reads:

1. **API key** — will ES reject this key when the next TM run presents it?
2. **TM task** — does the backing task exist (and is it recognized)?

If either check fails, let the update through (rotate the key / recreate the task as today’s write already does). Otherwise skip: no SO write, no `updated_at` bump, no key rotation, no blank history row.

That keeps the self-heal Detection Engineering actually gets SDHs for, without paying GRANT + write on the 99% healthy path (ConnectWise: 720 rules × ~300 spaces, daily, 1–2 real changes).

Mike Cote’s take is right as a *framework* position — `updateApiKey` and disable/enable already exist, and keys/tasks should not drop out randomly. We still want the check because **we** pick up the support tickets when a rule looks enabled and silently never fires.

---

## Problem

A no-op `rulesClient.update()` (single save, or `rules/_import?overwrite=true` of an identical rule) still:

- writes the rule SO
- advances **Updated**
- rotates the API key (`createNewAPIKeySet` when the rule is enabled)
- writes a blank change-history row

`RulesClient.bulkEdit` already skips this (`RULE_NOT_MODIFIED`, #145093). Single `update()` and import-overwrite do not.

The accidental write is also the unofficial repair path: support has told customers to “just save the rule” to rotate a key ES will no longer accept, and enable’s `getShouldScheduleTask` is the official repair for a missing TM task. A blunt skip would close those doors.

---

## What “stale” means here

**Stale = Elasticsearch rejects the key when a TM task runs.**

Not “the key is old.” Not privilege drift (user lost an index privilege). The task runner builds a fake request with the stored key (`Authorization: ApiKey …`) and talks to ES as that user. If ES refuses that credential, the rule is broken until someone rotates the key.

Typical causes: key invalidated, expired, deleted, or the stored secret no longer authenticates. Decrypt failure (Kibana cannot even read the key off the SO) is a sibling failure — same user-visible outcome, different check.

Privilege drift is out of scope. Mike’s point stands there: rotate when the *rule* changes (query / indices / owner), not on every save.

---

## Cost bar

Today’s no-op on an **enabled** rule:

| Step | Cost |
|------|------|
| Decrypt rule SO | already paid on update |
| `createNewAPIKeySet` → ES **GRANT** | expensive write (~70% of enabled-create latency) |
| SO overwrite | write + change-history row |
| Queue old key for invalidation | extra SO |
| TM `bulkUpdateSchedules` | only if interval changed (no-op: skip) |

A self-heal check only has to beat **GRANT + write**. Unconditional skip is cheaper still; the two reads are the price of keeping repair.

Disabled rules: skip both checks. No key obligation, no running task.

---

## 1) Checking the API key

### Free (already on the decrypted SO)

Do these first. No extra I/O.

- Enabled rule, `apiKey` null/missing → treat as stale, write.
- `getDecryptedRuleSo` failed → same recovery `updateApiKey` already documents: rotate without being able to invalidate the old value.

`executionStatus` from the last failed run is **not** a good signal. It only exists after a failure, and auth errors are not a dedicated `RuleExecutionStatusErrorReasons` (they land as Execute/Read). Lagging, incomplete.

### Faithful check (recommended)

`security.authc.apiKeys.validate({ id, api_key })` already exists. Synthetics uses it.

```459:476:x-pack/platform/plugins/shared/security/server/authentication/api_keys/api_keys.ts
  async validate(apiKeyPrams: ValidateAPIKeyParams): Promise<boolean> {
    // ...
    const fakeRequest = getFakeKibanaRequest(apiKeyPrams);
    try {
      await this.clusterClient.asScoped(fakeRequest).asCurrentUser.security.authenticate();
      return true;
    } catch (e) {
      this.logger.info(`Failed to validate API key: ${e.message}`);
    }
    return false;
  }
```

That is `GET /_security/_authenticate` presented as the stored key — the same first thing a TM run does. One cheap ES **read**. Decode is free: the SO stores `base64(id:secret)`.

Alerting’s `RulesClientContext` today only has `createAPIKey`. We would add a `validateAPIKey` (or call core `security.authc.apiKeys.validate` from the factory). No new ES API.

### Cheaper, slightly less faithful

`GET /_security/api_key?id=…`, or `_security/_query/api_key` for a batch of ids.

Tells you: exists / `invalidated` / expired. Does **not** present the secret, so it misses “id exists, secret is wrong” (rare). Internal-user metadata read; one query for a 720-rule import.

Good enough for import-scale if `validate()` per rule is too chatty. Prefer `validate()` on single update (one rule, want the exact TM failure mode).

### Do not do

- Mint a new key to “check” (that *is* today’s no-op).
- Run the rule.
- Compare role descriptors / privileges. Out of scope, and not cheap.

### UIAM / serverless caveat

`validate()` is ES authenticate. Cloud/`essu_…` keys and `uiamApiKey` go through a different task-runner branch (`shouldGrantUiam` + `ApiKeyType.UIAM`). A stateful check does not automatically cover serverless. Call that out in the ticket; do not pretend one probe covers both.

User-owned keys (`apiKeyCreatedByUser: true`): `validate()` still answers “will ES accept this?” Rotation rules stay different (do not invalidate the caller’s live key).

---

## 2) Checking the TM task

The enable path already does this. Copy it; do not invent a new protocol.

```61:83:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_enable/bulk_enable_rules.ts
const getShouldScheduleTask = async (
  context: RulesClientContext,
  scheduledTaskId: string | null | undefined
) => {
  if (!scheduledTaskId) return true;
  try {
    const task = await context.taskManager.get(scheduledTaskId);
    if (task.status === TaskStatus.Unrecognized) {
      await context.taskManager.removeIfExists(scheduledTaskId);
      return true;
    }
    return false;
  } catch (err) {
    return true;
  }
};
```

Same idea on single enable (`enable_rule.ts`). Missing task or `Unrecognized` → schedule a fresh one.

### What to treat as “missing”

| Signal | Extra I/O | Action |
|--------|-----------|--------|
| Enabled rule, no `scheduledTaskId` | none (on SO) | write / repair |
| `taskManager.get(id)` throws (not found) | 1 SO get | write / repair |
| Task exists, `status === Unrecognized` | same get | write / repair |
| Task exists, `enabled: false` on an enabled rule | same get | treat as broken (won’t run) |

Modern task id **equals** rule id. `scheduledTaskId !== id` is legacy; get by `scheduledTaskId`, not by guessing.

### Cost

`taskManager.get` is one SO get on `.kibana_task_manager`. Enable already pays it.

The store also has `taskExists(id)` — same get, **no** task-key decrypt. Cheaper, but **not** on the public TM start contract (`get` / `bulkGet` / `remove` / …). Use `get()` unless ResponseOps exposes `taskExists`. For import, `bulkGet(ids)` is the batch form.

`get()` also decrypts the task’s own API key. Wasteful for an existence check, still tiny vs GRANT.

### What a “write” repairs

A no-op `update()` does **not** currently recreate a missing task. It rotates the key and overwrites the rule SO. Task repair lives on **enable** (`getShouldScheduleTask` → `scheduleTask`).

So “let the update through” is enough for the **key**. For a missing task, the write alone is not enough unless we also call the enable-style schedule (or ask the caller to disable+enable). The comment on #285343 should say this plainly: either piggy-back `getShouldScheduleTask` + `scheduleTask` on the no-op-that-we-decided-to-write path, or document that key repair is automatic and task repair still needs enable.

Architecture note (already written up in `kibana-knowledge/architecture/rule_so_task_consistency.md`): “enabled SO, no working task” is the **one** desync the task runner cannot self-heal — nothing is running to notice. That is exactly the SDH we do not want to create by skipping blindly, and exactly the state a cheap `get` catches.

---

## Recommended shape

On a detected no-op (payload equal to current rule):

```
if rule.enabled:
  staleKey = missing/undecryptable apiKey
             OR !validate(decode(apiKey))          // single
             // OR id not in GET/_query api_key    // bulk alternative
  missingTask = !scheduledTaskId
                OR get(scheduledTaskId) missing/Unrecognized/disabled
  if staleKey OR missingTask:
    proceed with update
    if missingTask: also scheduleTask (enable-style repair)
  else:
    skip (RULE_NOT_MODIFIED)
else:
  skip
```

Single update / single save: `validate()` + `taskManager.get`. Two reads, then maybe a write.

Import / `bulkUpdate`: same logic, batched — `_query/api_key` for ids + `taskManager.bulkGet`. Only the 1–2 unhealthy rules take the GRANT+write path.

Keep single-rule UI save on this path too, not only import. The blank history row on “Edit → Save with no changes” is the same bug; the SDH rotation trick is usually a single save.

---

## Why not “just skip, use the dedicated APIs”?

That is Mike’s position ([#kibana-alerting, 2026-08-24](https://elastic.slack.com/archives/CHSSGF015/p1787589036.610949)):

> Rotating API keys would only really be needed if the queries or other aspects of the rule changed. For cases where the API key needs re-creation or the task needs to be re-enabled, we could probably treat these as edge cases (bug/user error), and users already have the API key and enable/disable APIs available.

Agreed as the *steady-state* design. Two reasons we still want the cheap check:

1. **Support lands on Detection Engineering.** The unofficial “save the rule” repair is already in [sdh-security-team#1026](https://github.com/elastic/sdh-security-team/issues/1026#issuecomment-2236628506). If import starts skipping every no-op, that repair disappears for the customer workflow that hits it most (daily re-import). Dedicated APIs only help if someone knows to call them.
2. **The check is cheap enough.** Authenticate + TM get vs GRANT + SO write + invalidate + history is not a close call. We are not choosing between “fast” and “correct”; we can have both on the healthy path.

What we should *not* keep: rotating every key on every no-op “just in case.” That is not self-heal, that is churn. Mike is right that keys do not need a daily refresh if the rule did not change.

---

## Open questions (for the #285343 comment)

1. **Task repair on the write path.** Confirm with ResponseOps that piggy-backing `scheduleTask` on a no-op-we-decided-to-write is acceptable, vs requiring disable+enable for missing tasks only.
2. **`validateAPIKey` on `RulesClientContext`.** Small factory change; needs ResponseOps review.
3. **UIAM.** Separate probe or “stateful only” for v1 of this?
4. **Where the skip lives.** Detection-engine import can skip before calling alerting (Patrick: fewer layers). Self-heal checks need decrypted `apiKey` + `scheduledTaskId`, so they belong in alerting `update` / `bulkUpdate`, not only in `security_solution`. Otherwise import skip would drop repair unless we duplicate the checks.
5. **Bulk metadata vs per-key `validate()`.** Import at 720 may want `_query/api_key`; single save should use `validate()`.

---

## Sources

- `update_rule.ts` — always `createNewAPIKeySet` when `originalRule.enabled`; no no-op skip
- `update_rule_api_key.ts` — official rotation; decrypt-failure still rotates
- `api_key_as_alert_attributes.ts` — stored key is `base64(id:secret)`
- `api_keys.ts` `validate()` — `security.authenticate()` as the key
- `synthetics/.../get_api_key.ts` — existing caller of `validate()`
- `bulk_enable_rules.ts` `getShouldScheduleTask` / `enable_rule.ts` — TM existence + Unrecognized
- `task_store.ts` — `get` (decrypts), `taskExists` (not public), `bulkGet`
- `rule_loader.ts` — TM run presents stored key; decrypt/not-found/disabled gates
- `kibana-knowledge/architecture/rule_so_task_consistency.md` — enabled-without-task is the silent-dead state
- `kibana-knowledge/architecture/bulk_api_key_generation.md` — GRANT vs skip vs clone/reuse
