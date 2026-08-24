# Bulk API key generation for alerting rules

Companion to [detection-rules-architecture.md](./detection-rules-architecture.md)
§F (API key and “running as the user”) and
[alerting-uiam-api-key-review.md](./alerting-uiam-api-key-review.md).

This doc is a brief for the Kibana change that should follow
[elastic/elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410)
(`POST /_security/api_key/_bulk_grant`). 

Kibana ticket: [elastic/kibana#273675](https://github.com/elastic/kibana/issues/273675).

Today each enabled rule is one `POST /_security/api_key/grant`. That is
~70% of the extra latency when creating 1000 enabled vs disabled rules.
The issue’s acceptance criteria name `bulkCreateRules` only. Bulk update
and bulk enable pay the same per-rule grant cost and should be in the
same change.

---

## Why a rule has a key

A rule does not run as the interactive user. Task Manager wakes up later
and must talk to Elasticsearch *as that user*. The credential is stored
encrypted on the rule SO (`apiKey`, plus `uiamApiKey` on serverless).

How we get that credential depends on how the **current request** is
authenticated, and (on update/enable) whether the existing rule already
owns a framework key.

| Path | When | What happens | Who owns the key |
|------|------|----------------|------------------|
| **Grant** | Session / password / access token (not API-key auth) | Kibana system user asks ES to mint a new key *as the caller* | Framework (`apiKeyCreatedByUser: false`) |
| **Reuse** | Request is `Authorization: ApiKey …` and the rule is not framework-managed | Copy the caller’s key onto the rule | User (`apiKeyCreatedByUser: true`). Do **not** invalidate on delete — they may still be using it. |
| **Clone** | Request is API-key auth **and** we must not pin the user’s live key on the rule | ES `POST /_security/api_key/clone` (source = request key) → new key, same privileges | Framework. Used when editing a framework-managed rule while API-key-authed, or when a caller sets `cloneApiKeysOnCreate` (e.g. significant events). UIAM `essu_…` keys cannot be cloned; we mint a fresh UIAM key instead. |
| **Skip** | Rule is disabled, or (enable) it already has an `apiKey` | No mint | Unchanged |

An API key **cannot** grant another API key. That is why clone/reuse exist.
Bulk grant only helps the **grant** path. Clone and reuse stay per-rule;
there is no bulk clone. A 1000-rule import while the caller is
API-key-authed will not get this speedup.

Decision tree: `shouldGrantRuleApiKey` /
`resolveRuleAPIKey` in
`x-pack/platform/plugins/shared/alerting/server/rules_client/common/resolve_rule_api_key.ts`.

---

## ES contract to code against

Once [elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410)
lands:

- One set of grant credentials, many key specs.
- `created` is in request order with failures omitted.
- Key ids are server-generated.
- Names are **not** unique. Alerting uses
  `generateAPIKeyName(typeId, name)` → `Alerting: ${typeId}/${name}`.
  Two rules of the same type with the same name collide. Zip `created`
  by **walking names in request order**, not by unique name.

Do not assume `@elastic/elasticsearch` has `security.bulkGrantApiKey`.
`transport.request` is fine until the client grows a typed helper.

Kibana will need something next to `grantAsInternalUser` in the security
plugin, then the alerting bulk methods (`bulkCreateRules`,
`bulkUpdateRules`, `bulkEnableRules`) should use it for grant-path items
only.

Until every cluster has the endpoint, treat 404, 405, and “no handler
found” as “use `grantAsInternalUser` per name.”

---

## Invariants per bulk method

These are true of today’s product. The bulk-grant change must keep them.

### `bulkCreateRules`

- Grant only **enabled** rules (no ownership yet).
- `cloneApiKeysOnCreate` (if set) takes clone, not grant.
- API-key auth without that flag → reuse, not grant.
- Create already has a place to register minted keys before action
  validation so a later prepare failure can invalidate. Use that.

### `bulkUpdateRules`

- Ownership comes from the **existing** SO (`apiKeyCreatedByUser`).
- Mint only when the existing rule is **enabled**. Disabled updates do
  not get a new key. Bulk update does not flip `enabled`.
- `cloneApiKeysOnCreate` does **not** apply (ownership is always passed).
- API-key-authed editor of a framework-managed rule → **clone**, not grant.
- API-key-authed editor of a user-owned rule → **reuse**.
- Old keys are marked for invalidation after a successful write
  (`bulkMarkApiKeysForInvalidation`), except user-owned keys.
- OCC 409 retries remint. Queue the previous attempt’s keys for
  invalidation before minting again.

### `bulkEnableRules`

- Cheap checks first (schedule circuit breaker, actions `execute` auth).
  Only survivors should be granted. Don’t mint keys for rules that will
  be rejected.
- Mint only when `!rule.attributes.apiKey`. A disabled rule that already
  has a key is left alone.
- Ownership from the existing SO, same clone/reuse rules as update.
- Enable has **no** orphan-invalidation list today. Do not mint the
  whole surviving set and hope task schedule / SO write succeed — a
  later throw leaks every key in the batch. Give enable the same pending
  invalidation habit as create/update, or don’t mint until you can unwind.
- OCC 409 retries the whole operation, including mint. Same rule: previous
  attempt’s keys must already be queued, or they leak.

---

## Things to get right

**Grant credentials once.** Username/password or access token (plus
UIAM/JWT `client_authentication`) is shared across the batch. Don’t
re-parse per key.

**Mint grant-path items in a batch, apply later.** Don’t mint inside
per-rule prepare. If an enabled rule needed a key and didn’t get one,
**fail that rule**. The rest of the batch continues.

**Partial ES failures are not “keys disabled.”** `created` omits
failures. A zip miss must be a per-rule error, and any UIAM key already
minted for that name must be invalidated. Do not put
`{ apiKeysEnabled: false }` in the success map for a miss — that
persists an enabled rule with no key and no error.

**License / security off is the only “no key, no error” path.**
`grantAsInternalUser` (and the future bulk equivalent) return `null`.
Persist the rule without a key; don’t error the batch. Don’t conflate
this with a partial ES miss.

**Fallback.** 404 / 405 / “no handler found” → per-rule
`grantAsInternalUser`. Other errors should fail those items (or the
call). Don’t swallow a 500 into a silent second grant pass.

**UIAM is still N calls.** There is no bulk UIAM. Parallel is fine.
If the ES grant fails or omits a key, invalidate the UIAM key already
minted for that name.

**User-owned keys.** `apiKeyCreatedByUser: true` → never invalidate on
delete/update. Reuse copies the caller’s live key.

**Tests.** If you add an optional bulk hook on the rules-client context,
don’t put it on the shared default mock. Tests that don’t wire it should
keep hitting per-rule `createAPIKey` via `resolveRuleAPIKey`.

---

## What this does not change

- Single-rule `create` / `update` / `enable` / `updateApiKey` still use
  `createNewAPIKeySet` → `resolveRuleAPIKey` → one grant/clone/reuse.
- Clone and reuse stay per-rule even inside a bulk call.
- Empty `role_descriptors` on grant — the key inherits the granter’s
  privileges. That is existing alerting behavior, not new.
- Encrypted SO + AAD rules for `apiKey` / `uiamApiKey` are unchanged.
