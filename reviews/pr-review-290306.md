# PR Review: #290306 — [Security Solution][Alerting] Skip refresh on bulk rule API key grants

**PR:** [elastic/kibana#290306](https://github.com/elastic/kibana/pull/290306) by @sdesalas
**Issue:** [elastic/kibana#290233](https://github.com/elastic/kibana/issues/290233)
**Related:** [elastic/kibana#273675](https://github.com/elastic/kibana/issues/273675), [elastic/elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410), [elastic/elasticsearch#158961](https://github.com/elastic/elasticsearch/pull/158961) (manual-test ES)

**Scale:** Substantive PR.

**Ownership (team: `@elastic/security-detection-engineering`)**

This PR touches **zero** files owned by Detection Engineering. You're a stakeholder (the win is for detection-rule bulk enable / future bulk import), not a CODEOWNER.

- **Your team's files (0):** none — *DEX review is about whether the right Security Solution paths actually get the win*
- **Other teams' files:**
  - `src/core/packages/security/server/**` (`@elastic/kibana-core`)
  - `x-pack/platform/packages/shared/security/plugin_types_server/**` (`@elastic/kibana-security`)
  - `x-pack/platform/plugins/shared/security/**` (`@elastic/kibana-security`)
  - `x-pack/platform/plugins/shared/alerting/**` (`@elastic/response-ops`)
- **Unowned:** none

Draft. No human reviews yet. Latest `kibana-ci` was pending at review time; three earlier builds failed Local Check (the last commit, “Update createAPIKey assertions for optional refresh arg”, is aimed at that).

---

### Context / Motivation

This came out of [kibana#273675](https://github.com/elastic/kibana/issues/273675) (bulk-create API keys are slow) and the ES `_bulk_grant` discussion on [elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410).

- **Original design:** Kibana never sends `refresh` on `POST /_security/api_key/grant`. ES then applies `defaultCreateDocRefreshPolicy`: stateful `wait_for` (~1s), Serverless `refresh=true` (force refresh, because Serverless auto-refresh is slow). The wait is so the new key is **searchable** when grant returns.
- **Objection:** that wait is most of the extra cost when minting 1000 keys at `pMap` concurrency 50. Task Manager does not search for the key — it authenticates with a realtime GET by id (`ApiKeyService.loadApiKeyDoc`).
- **Resolution in this PR:** pass `refresh=false` only on the three alerting bulk mint paths. Leave every other `createAPIKey` / `grantAsInternalUser` caller on the ES default. `_bulk_grant` stays a later, larger change.
- **Deferred:** UIAM grant refresh; Serverless as a first-class test (the [performance comment](https://github.com/elastic/kibana/pull/290306#issuecomment-5621380658) later *did* measure local serverless); wiring Security Solution import onto `bulkCreate`/`bulkUpdate` ([#275695](https://github.com/elastic/kibana/pull/275695)).

---

### Validating the issue — does this PR address it?

**The concern is technically valid. The PR fixes the alerting bulk-grant wait. It does not yet fix today's Security Solution NDJSON import, or Security Solution bulk edit.**

- **Where the problem manifests:** `createAPIKey` → `grantAsInternalUser` → ES `grantApiKey` with no `refresh`. Those grants run 50-wide in `bulkCreateRules` / `bulkUpdateRules` / `bulkEnableRules` / `bulkEdit`.
- **Why the old approach was a problem:** each grant blocks on search visibility. Local numbers in the PR comment: bulk enable ~500 rules 24s → 4s (stateful); serverless gets worse as TM load rises (108s → 12s at ~900 rules). Auth never needed that wait.
- **How the PR fixes it:** optional `refresh` on `grantAsInternalUser` / `createAPIKey` / `createNewAPIKeySet` / `resolveRuleAPIKey`. The three named bulk methods pass `refresh: false`. Security only puts `refresh` on the ES request when it is not `undefined`, so other callers keep today's default.
- **Residual caveat:** today's Security Solution import still calls singular `rulesClient.create` / `rulesClient.update` (`import_rule.ts`), which do **not** pass `refresh: false`. Security Solution bulk edit goes through `rulesClient.bulkEdit`, which also does not. Prebuilt bulk install (`bulkCreateRules`) and bulk enable (`bulkEnableRules`) *do* get the win.

---

### Summary

Adds an optional `refresh` argument on the core/security grant API and on alerting `createAPIKey`, then passes `refresh: false` from `bulkCreateRules`, `bulkUpdateRules`, and `bulkEnableRules`. Intent matches the diff for those three methods. The PR description's “when Security Solution bulk-imports” is ahead of the current import implementation — that path still uses per-rule create/update and will keep paying `wait_for` until it switches to the bulk APIs.

---

### Files touched

- **Core grant contract:** `src/core/packages/security/server/.../api_keys.ts` (+ re-exports) — optional third arg `GrantAPIKeyOptions` on `grantAsInternalUser`. Additive; other callers stay valid.
- **Security implementation:** `x-pack/.../security/server/authentication/api_keys/api_keys.ts`, `build_delegate_apis.ts` — copies `options.refresh` onto ES `grantApiKey` params only when set.
- **Alerting plumbing:** `rules_client/types.ts`, `rules_client_factory.ts`, `resolve_rule_api_key.ts`, `create_new_api_key_set.ts` — thread `refresh` from bulk methods down to the grant.
- **The actual behavior change:** `bulk_create/utils.ts`, `bulk_update/utils.ts`, `bulk_enable_rules.ts` — `refresh: false` at the three mint sites.
- **Tests:** factory + security grant tests for forwarding; `create` / `enable` / `update` / `bulk_edit` / `resolveRuleAPIKey` assertions updated to expect a second `undefined` arg. No method-level test that bulk create/update/enable pass `false` (checklist overclaims that).

---

### Flow trace

1. Security Solution bulk-enables rules → `rulesClient.bulkEnableRules`.
2. `bulkEnableRulesWithOCC` `pMap`s at concurrency 50.
3. For each rule **with no existing `apiKey`**, `createNewAPIKeySet(..., { refresh: false })`.
4. `resolveRuleAPIKey` → `grantKey` → `context.createAPIKey(name, false)` (clone / user-borrowed paths ignore `refresh`).
5. `RulesClientFactory.createAPIKey` grants UIAM first (unchanged), then `grantAsInternalUser(request, params, { refresh: false })`.
6. Security sets `params.refresh = false` and calls ES `grantApiKey`. Grant returns without waiting for `.security` search visibility.
7. Encoded id+secret is written on the rule SO. On failure, `invalidateKeys` queues those **ids** on a pending-invalidation SO (not a search).
8. TM later decrypts the SO key and authenticates. ES `loadApiKeyDoc` is a realtime GET by id — works before the next refresh.
9. Parallel path: `bulkCreateRules` → `prepareRule` does the same when `data.enabled`. `bulkUpdateRules` → `prepareUpdate` does the same when `originalRule.enabled`.
10. Not on this path: Security Solution NDJSON import (`importRule` → `create`/`update`) and `rulesClient.bulkEdit` (`update_rule_in_memory.prepareApiKeys`) still omit `refresh`.

---

### Assumptions

- ES API-key auth stays a realtime GET by id (`GetRequest.realtime` default `true`). If that ever became search-based, `refresh=false` would break first TM runs.
- Orphan / pending invalidation uses stored key ids, not `invalidate-by-query` against `.security`. Confirmed in `invalidate_keys.ts` → `bulkMarkApiKeysForInvalidation`.
- Passing `{ refresh }` with `refresh: undefined` is equivalent to omitting the option, because Security only assigns when `!== undefined`.
- Clone / user-borrowed key paths never need `refresh` (they don't hit grant).
- UIAM grant latency is acceptable to leave alone for this change.
- `bulkUpdateRules` will be the overwrite-import path once the wiring PR lands; it is not what Security Solution import uses today.

---

### Risks

- **Today's Security Solution import does not get this win.** `import_rule.ts` still uses singular `create`/`update`. Those tests were updated to assert `createAPIKey(name, undefined)` — i.e. they still wait. The description reads like import is in scope; it isn't until import is moved onto `bulkCreateRules` / `bulkUpdateRules`.
- **`bulkEdit` is the same 50-wide mint and was left on the default.** `prepareApiKeys` remints whenever `attributes.enabled || hasUpdateApiKeyOperation`. Detection-engine bulk actions (`bulk_edit_rules.ts` → `rulesClient.bulkEdit`) will still pay `wait_for` / Serverless `refresh=true`. The `bulk_edit_rules.test.ts` change locks that in (`undefined`, not `false`).
- **Checklist vs tests.** Plumbing is tested. There is no unit test that `bulkCreate` / `bulkUpdate` / `bulkEnable` pass `refresh: false`. A later edit to those three call sites could drop it silently.
- **No automated “key works before refresh” test.** The PR says so. Safety is the ES GET-by-id argument plus a manual script that needs a custom ES build ([elasticsearch#158961](https://github.com/elastic/elasticsearch/pull/158961)).
- **UIAM grant still uses its own default.** On Serverless, ES grant is only half the mint. The performance comment shows a Serverless win anyway; leftover UIAM wait is the residual.
- **Search-visibility gap of ~1s (stateful) / longer (Serverless).** Stack Management API-key listing and any search-based invalidate could miss a brand-new key. TM and pending-invalidation-by-id should be fine.
- **CI.** Earlier builds failed Local Check on the new optional-arg arity. Latest commit fixes those assertions; confirm the in-flight build is green before asking ResponseOps/Security for review.

---

### Open questions

- Should `bulkEdit` (`update_rule_in_memory.prepareApiKeys`) also pass `refresh: false`? That is the Security Solution bulk-mutate path *today*, and it remints keys for every enabled rule in the batch.
- Is the PR description's “bulk-imports” claim meant to depend on [#275695](https://github.com/elastic/kibana/pull/275695)? If yes, worth saying that explicitly so reviewers don't think current NDJSON import is faster after this merges.
- The description still says Serverless is untested; the [performance comment](https://github.com/elastic/kibana/pull/290306#issuecomment-5621380658) has local serverless numbers (and they're the more interesting ones). Worth updating the Risks section.
- `bulkUpdate` is wired here but the same comment says “wiring PR is not ready / not tested.” Is it better to leave `refresh: false` in `prepareUpdate` now (harmless once callers exist) or drop it until that PR lands?
- Single-rule `create` / `enable` / `update` still wait. Fine for one key — just confirm that's a conscious “don't change the conservative default” choice, not an oversight.

---

### Notes for your codebase map

- Alerting mints TM keys via `createNewAPIKeySet` → `resolveRuleAPIKey` → `RulesClientFactory.createAPIKey` → `grantAsInternalUser`. Grant vs clone vs “borrow the caller's key” is decided in `resolveRuleAPIKey`.
- Bulk mint concurrency is `API_KEY_GENERATE_CONCURRENCY = 50` in create, update, enable, **and** edit.
- ES grant `refresh` is about **search** visibility on `.security`. Auth is GET-by-id and does not need it.
- Security Solution import is still per-rule `create`/`update`. Prebuilt install already uses `bulkCreateRules`. Bulk enable already uses `bulkEnableRules`. Bulk edit uses `bulkEdit`, not `bulkUpdateRules`.
- Pending API-key invalidation writes ids to an SO and invalidates later by id — compatible with `refresh=false`.

---

### Review activities

1. **Should `bulkEdit` also pass `refresh: false`?** Yes. `rulesClient.bulkEdit` always sets `shouldInvalidateApiKeys: true`, then `prepareApiKeys` remints whenever `attributes.enabled || hasUpdateApiKeyOperation`. Same 50-wide `pMap` as the other bulk methods. Params-only `bulkEditRuleParamsWithReadAuth` skips minting entirely (`shouldInvalidateApiKeys: false`), so it wouldn't benefit. Security Solution tags / actions / schedule bulk edits hit the remint path.

2. **Added `refresh: false` to `prepareApiKeys`.** Wired in `update_rule_in_memory.ts`; `bulk_edit_rules.test.ts` now expects `createAPIKey(name, false)`.

3. **AAD vs remint.** `RuleAttributesIncludedInAAD` includes `tags`, `actions`, `schedule`, `throttle`, `notifyWhen`, `params`. AAD only forces **re-encryption** of the stored key, not a new ES grant. `rulesClient.bulkEdit` remints anyway whenever the rule is enabled (`shouldUpdateApiKey: attributes.enabled || hasUpdateApiKeyOperation`) — it does not check AAD. `snoozeSchedule` is not in AAD but still remints on enabled rules. Params-only `bulkEditRuleParamsWithReadAuth` sets `shouldInvalidateApiKeys: false` and does not grant; it re-encrypts the existing key. Security Solution tags / actions / schedule still hit the remint path.
