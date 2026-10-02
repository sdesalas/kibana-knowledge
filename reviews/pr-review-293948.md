# PR Review: #293948 — [Security Solution] Skip unchanged rules on `rules/_import` overwrite

**PR:** [elastic/kibana#293948](https://github.com/elastic/kibana/pull/293948) by @sdesalas
**Created Date: 2026-10-01**
**Reviewed at:** [`c6baea443cfe`](https://github.com/elastic/kibana/pull/293948/commits/c6baea443cfeca6a61919866e9cf482cdf04bc4f) (PR head, 2 commits)

**Scale:** Substantive, but the core logic is small (~40 lines in `overwrite_rules.ts`). The rest is API schema, telemetry plumbing and tests. Standard review, all files.

---

### Context / Motivation

Users keep re-uploading the same import file with only minor changes. This is especially true for Detections as Code (DaC) users, whose CI pipeline pushes the whole rule set from source control with `rules/_import?overwrite=true` on every change. [Issue #285343](https://github.com/elastic/kibana/issues/285343) puts it this way:

> Users often re-upload the same import file with only minor changes. If we have an import file with 999 unchanged rules and only 1 rule that changed we should avoid tracking unnecessary changes to 999 of those rules.

Today every rule in that file gets written, changed or not. Each no-op write bumps `updated_at`, rotates the API key and adds a blank "No visible field changes" entry to change history. For a DaC user, that means one real edit leaves 999 meaningless history rows, makes 999 rules look recently updated, and swaps 999 API keys. Change history went GA around 2026-08-03, so those blank entries are now visible to users.

The expected behavior is scoped to import-overwrite: unchanged rules get no saved-object write, no update-date change, no API key rotation and no change-history row.

The issue also flags a catch:

> However note that this unexpected behavior is also [used to rotate API keys](https://github.com/elastic/sdh-security-team/issues/1026#issuecomment-2236628506) when they become stale.

It also points to the precedent in alerting:

> `RulesClient.bulkEdit` already skips no-ops (`RULE_NOT_MODIFIED`, #145093) and does not update the saved object or invalidate API keys. Single `update()` and import-overwrite do not.

This PR only fixes the **import-overwrite** path. Single `update()` and `patch()` are out of scope by design (see activity #6).

### Validating the issue — does this PR address it?

**The concern is real. The PR fixes it for import-overwrite, and the comparison it uses is sound.**

- **Where the problem happens.** `overwriteRules()` used to push every matched rule into `bulkInputs`. `bulkUpdateRules()` then rewrites the saved object unconditionally: it calls `createNewAPIKeySet(..., shouldUpdateApiKey: originalRule.enabled)`, bumps `revision` and `updatedAt`, and logs a change-history entry (`alerting/.../bulk_update/utils.ts` ~L164-204). Nothing in that path checks whether anything changed.
- **How the PR fixes it.** Before queuing a rule, it runs both the existing `RuleResponse` and the merged incoming rule through `convertRuleResponseToAlertingRule()` and compares them with `isEqual`. It also checks that `enabled` is unchanged. If both match, the rule goes straight to `successes` with `unchanged: true`. That means no `bulkUpdateRules`, no enable/disable call, no history entry and no new API key.
- **Same pattern as restore-from-history.** `restore_rule_state.ts` L51-55 already does the identical check (`isEqual` of two `convertRuleResponseToAlertingRule` outputs). So the PR description's claim holds.
- **Leftover caveat.** API-key rotation also stops for unchanged rules. That's intended per the issue's "Expected behavior", but the PR description never mentions it (see Risks).

### Summary

On `rules/_import?overwrite=true`, rules whose alerting payload and `enabled` state match what's stored are skipped instead of rewritten. They still count as successful imports. The response gains an optional `unchanged_count` (a subset of `success_count`). The `detection_rule_import` telemetry event gains an `outcome` field (`created` / `updated` / `unchanged`) and now has its own schema, separate from the shared lifecycle schema. The diff matches the PR description and stays inside the linked issue's scope.

### Files touched

- **Core logic:** `methods/import_rules/overwrite_rules.ts` (the unchanged check and the skip), `methods/import_rules/types.ts` (adds `unchanged?` to `ImportRuleSuccess` and switches telemetry to `RuleImportTelemetryData`), `methods/import_rules/create_rules.ts` (tags new rules `outcome: 'created'`).
- **API contract:** `import_rules_route.schema.yaml`, `import_rules_route.gen.ts`, and the two bundled OpenAPI files (ESS and serverless) add the optional `unchanged_count`. `api/rules/import_rules/route.ts` fills it in by counting `successes` that have `unchanged`.
- **Telemetry:** `rule_lifecycle_telemetry.ts` adds the `RuleImportOutcome` / `RuleImportTelemetry` types and a dedicated send loop. `telemetry/event_based/events.ts` gives `DETECTION_RULE_IMPORT_EVENT` its own schema with `outcome`. Install and revert events are untouched.
- **Tests:** client unit tests (skip, mixed changed/unchanged, enable-flip still writes), route unit tests (`unchanged_count`), telemetry unit tests, and a new FTR `import_rules_telemetry.ts` (created/updated/unchanged/invalid in one import).

### Flow trace

`POST /api/detection_engine/rules/_import?overwrite=true` with a file of rules that already exist:

1. `route.ts`: parses the ndjson, imports connectors and exceptions, sets `bulkCount = validatedResponseActionsRules.length`, then calls `detectionRulesClient.importRules()` in chunks of `RULE_IMPORT_BATCH_SIZE`.
2. `import_rules.ts`: loads `existingRules` by `rule_id` and splits rules into create and overwrite paths.
3. `overwrite_rules.ts`, for each rule: `applyRuleUpdate()` merges the incoming rule onto the existing one (defaults, prebuilt-asset handling, checked `exceptions_list`), then overrides `rule_source` and `immutable` with the import's calculated values.
4. Both `existingRule` and `updated` go through `convertRuleResponseToAlertingRule()`. If `isEqual` passes and `enabled` matches, the rule goes to `successes` with `outcome: 'unchanged'` and `unchanged: true`.
5. Otherwise the enable/disable toggle is queued, the rule goes to `pending` with `outcome: 'updated'`, and its payload joins `bulkInputs`.
6. If `bulkInputs` is empty, the method returns early. `bulkUpdateRules` and the toggles are never called.
7. Otherwise `bulkUpdateRules()` runs (legacy-actions migration, new API key for enabled rules, `revision`/`updatedAt` bump, change history), followed by `toggleState()`.
8. `detection_rules_client.ts`: `sendRuleImportTelemetryEvents()` sends one `detection_rule_import` event per success, including unchanged ones, each with its `outcome`.
9. `route.ts`: `success_count = successes.length` and `unchanged_count = successes.filter(unchanged).length`.

### Assumptions

- **Both sides normalize the same way.** `existingRule` (read from the saved object) and `updated` (from `applyRuleUpdate`) must produce identical converter output when semantically equal. If they differ, the rule is reported as "changed" and gets written, which is safe. A false "unchanged" can only happen if a meaningful field isn't in the converter output. I checked `UpdateRuleData`: `enabled` is handled separately, and timestamps, `revision` and `execution_summary` aren't writable through this path anyway. I didn't find a gap.
- **Hand-written action entries always look changed.** `transformRuleToAlertAction` only emits `uuid` when present. Stored rules always have action `uuid`s, so an incoming file whose actions lack `uuid` always counts as changed. Exported files include `uuid`, so export-then-reimport round-trips work. This is why `import_rules_with_actions.ts` L238-261, which re-imports an identical payload and expects `revision + 1`, still passes.
- **Skipping validation is acceptable for unchanged rules.** Unchanged rules skip `bulkUpdateRules`' validation: rule-type authz (`bulkEnsureAuthorized`), `validateActions` / connector existence, and the minimum schedule interval. A stored rule that would now fail those checks (deleted connector, interval below a newly enforced minimum) used to come back as an import error. It now comes back as a success.
- **`bulk_count` semantics.** `bulkCount` in change-tracking metadata stays the full import size. A 1000-rule re-import where only 1 rule changed records a single history entry with `bulk_count: 1000`.

### Risks

1. ~~**Re-import no longer rotates or re-owns API keys for unchanged rules, and the PR description doesn't say so.** The old path minted a new API key under the importing user for every enabled rule. The linked issue explicitly calls out that support uses this as a workaround for stale keys ([sdh-security-team#1026](https://github.com/elastic/sdh-security-team/issues/1026#issuecomment-2236628506)). It also served as an implicit "take ownership" step: an admin re-importing rules made them run as the admin. After this PR, unchanged rules keep the old key and owner. The issue's expected behavior includes "no API-key rotation", so this is intended, but it's a user-visible behavior change that belongs in the release note and needs a documented alternative (for example, disable/enable).~~ **(DISCARDED)** Expected behavior of the bug fix, now documented in the PR. Key ownership is still rotated the same way as before (Stack Management → Rules → Update API key), as explained in [this issue comment](https://github.com/elastic/kibana/issues/285343#issuecomment-5933664503). Disable/enable is _not_ a replacement. See activities #1 (confirms `main` rotates keys on every overwrite), #5 (Update API key as the workaround), #8 (an ownership check that keeps re-import rotating keys) and #9 (when a stale key owner actually breaks a rule).
2. ~~**Backport labels on a default-behavior change.** The PR carries `v9.5.6` + `backport:version` + `release_note:fix`. Changing default import semantics (risk 1) and adding an API response field in a patch release is a bigger step than a typical bug-fix backport.~~ **(SKIPPED)** The fix can't avoid a behavior change, and the new `unchanged_count` field is how that change is made visible to users. The backport targets 9.5 only, because change history went GA in 9.5 and that's when the blank entries started showing. Reviewers can push back if they disagree. See activity #7.
3. ~~**Errors become successes for unchanged-but-broken rules.** Because unchanged rules skip alerting validation, a rule whose connector was deleted, or whose interval now breaks an enforced minimum, used to return an import error and now returns success. No data is written, so it's not a safety issue, but it changes what the response tells the user.~~ **(IGNORED)** Not really a problem. The rule already exists in that exact state, so throwing an error on import doesn't leave anyone better off.
4. ~~**Telemetry schema change.** `detection_rule_import` gets a new required `outcome` keyword field, and the event no longer shares the lifecycle schema. Dashboards or downstream models (SDA/dbt) that union install/import/revert on a shared shape may need updating. Event counts stay continuous, which is good.~~ **(IGNORED)** The change is additive. The new schema spreads `ruleLifecycleTelemetrySchema` and adds `outcome`, so the event type and every existing field stay the same. Install and revert are untouched, and unchanged rules still send an import event, so counts don't move.
5. **FTR coverage of the skip is thin.** The new FTR (`import_rules_telemetry.ts`) does run the real stored-vs-incoming comparison end to end, but only for one disabled custom query rule, and it only checks `unchanged_count` and the telemetry `outcome`. No FTR asserts that an unchanged re-import leaves `revision`, `updated_at` and change history alone. The existing overwrite FTRs all change `name` before re-importing, so they only cover the changed path. Not covered end to end: other rule types (ML, threshold, EQL, ES|QL, new terms, indicator match), prebuilt rules with `rule_source`, rules with actions or exceptions, enabled rules, and export → re-import with no edits (the DaC flow). See activity #10.
6. **The public API docs now say the wrong thing about overwrite.** The `> warn` block in `import_rules_route.schema.yaml` (L17-19) says the importing user's key "gets assigned to the affected rules", which is no longer true for unchanged rules. The `overwrite` param description (L58) still says only "existing rules ... are overwritten" and doesn't mention that identical rules are skipped. The docs that reach users (bump.sh, via the bundled specs) will describe the old behavior. See activity #2.
7. ~~**`Fixes: #285343` will auto-close an issue that's only partly fixed.** The issue covers no-op writes from single `update()`/`patch()` (the UI "Save" with no edits) as well as import-overwrite. This PR only touches import. Once merged, the UI-save half of the bug has no open issue tracking it. See activity #3.~~ **(DISCARDED)** Not a risk. The concern is only imports, where users re-upload the same file with minor changes. A single update is a deliberate user action that should still rotate the API key and write change history, and it doubles as the remedial path when something goes wrong.
8. **`overwrite=true` no longer guarantees its side effects.** Before, every matched rule got `revision + 1`, a new `updated_at`/`updated_by`, a change-history entry and legacy-actions migration. Now those happen only when the payload differs. API clients that read `revision`/`updated_at` after import to confirm it applied, or that assume overwrite migrates legacy actions, will see different results. This is the intended fix, but it's a public API behavior change and should be documented as one (ties to Risks 1 and 6). See activity #4.

### Open questions

- Should the PR description and release note call out that re-import no longer rotates API keys or changes the rule owner for unchanged rules? What's the recommended alternative for support's stale-key workaround?
  - *Suggested reading: activity #5. Ownership rotation goes through the **Update API key** bulk action in Stack Management → Rules, same as before ([issue comment](https://github.com/elastic/kibana/issues/285343#issuecomment-5933664503)).*
- ~~Is backporting to 9.5.6 intended, given the default behavior change and the new response field? Or should this be 9.6-only?~~ **Answered — yes, 9.5 only, since that's when change history went GA. See activity #7.**
- Was an opt-out (for example a query param that forces a rewrite) considered for users who relied on re-import to refresh keys? The PR's "Decisions" section argues against rewriting but doesn't mention keys.
  - *Suggested reading: activity #5. An existing bulk action already covers key and owner refresh without bumping revisions, so an opt-out may not be needed.*
- ~~Is it OK for an unchanged rule that would fail current validation (missing connector, interval below an enforced minimum) to be reported as a success?~~ **Answered — yes. The rule already exists in that state, so an import error doesn't help. See Risk #3 (ignored).**
- Should `bulk_count` in change history reflect the full import size or the number of rules actually written?
- ~~Does the `detection_rule_import` schema change need sign-off or an update in the downstream telemetry mapping (SDA/dbt models that read `detection_rule_*` events)?~~ **Answered — no. The change only adds a field. See Risk #4 (ignored).**
- Would it be worth adding one FTR that re-imports an exported rule unchanged and asserts `revision`, `updated_at` and history count stay the same? Ideally a prebuilt rule plus one non-query type.
- Small design point: `unchanged?: boolean` and `telemetry.outcome === 'unchanged'` encode the same fact. Could `unchanged_count` just be derived from `outcome`?
- Does the PR need a `## Release Note` section? Without one, the release note falls back to the PR title, which says nothing about unchanged rules keeping their old API key and owner.
- Do the user-facing "Import detection rules" docs in `elastic/docs-content` describe overwrite as always updating rules? If so, they need a matching update.
- Should the PR use `Part of #285343` (or open a follow-up for `update()`/`patch()`) instead of `Fixes:`?
  - *Suggested reading: Risk #7 (discarded). Single updates are meant to keep writing, so `Fixes:` holds as long as the issue scope matches.*
- Would splitting the telemetry `outcome` commit into its own PR make the 9.5.6 backport cleaner? The bug fix doesn't depend on it.
- Should the `isEqual(convert(existing), convert(next))` check become a shared helper now that restore-from-history and import both use it, and `update()`/`patch()` will likely be next?
- Do stored rules with legacy (pre-8.x) actions show up as "unchanged" on re-import? If so, they now skip the `bulkMigrateLegacyActions` step that the write path used to run.
- Since the route always sends `unchanged_count`, should the schema list it under `required` like the other count fields? As it stands, generated client types make it optional.

### Notes for your codebase map

- `convertRuleResponseToAlertingRule()` is the de facto "what actually gets written" normalizer. Comparing two of its outputs with `isEqual` is now the house pattern for no-op detection (restore-from-history and import-overwrite).
- `bulkUpdateRules()` in alerting always rewrites. It mints a new API key for enabled rules, bumps `revision`/`updatedAt`, runs `bulkMigrateLegacyActions` and logs change history. Any no-op skipping has to happen on the caller side, unlike `bulkEdit`, which has `RULE_NOT_MODIFIED`.
- Import's `changeTracking.metadata.bulkCount` is set once in the route from the full validated rule count, not per batch or per write.
- `transformRuleToAlertAction` drops `uuid` when absent, so action `uuid`s decide whether a hand-written rule file looks "changed".
- `detection_rule_import` now has its own EBT schema (`ruleLifecycleTelemetrySchema` + `outcome`). Install and revert still share the base schema.

### Follow-up Review Activities

**1. Does a no-op overwrite on main actually rotate the API key?**

The first pass only read the `createNewAPIKeySet` call site. This time I traced it through. Confirmed: yes, for enabled rules.

- `bulk_update/utils.ts` `prepareUpdate()` always calls `createNewAPIKeySet(..., shouldUpdateApiKey: originalRule.enabled)`. Nothing compares the old and new payloads first.
- `resolve_rule_api_key.ts`: when `enabled` is false it returns no key. When `enabled` is true, every branch returns a key tied to the caller. It either clones the caller's key (`cloneKey`), grants a new one (`grantKey` → `context.createAPIKey`), or, for API-key auth, stores the caller's own key (`isAuthTypeApiKey: true`). It never reuses the rule's existing key.
- `bulk_update_rules.ts` L485-487: after a successful write, `prepared.oldKeys` goes into `invalidKeys`, and L492-499 invalidates them.
- `apiKeyAsAlertAttributes(createdAPIKey, username, ...)` also sets `apiKeyOwner` to the importing user.
- Net effect on main: re-importing an identical enabled rule swaps in a new key owned by the importer and invalidates the old one. Disabled rules get no new key. This matches repro step 5 in the linked issue. The PR's skip removes this for unchanged rules, so Risk 1 holds, but only for **enabled** rules.

**2. Focused review: documentation**

- `import_rules_route.schema.yaml` L17-19 (`> warn`): says the importing user's key "gets assigned to the affected rules". That's no longer true for unchanged rules. Raised as Risk #6.
- `import_rules_route.schema.yaml` L58 (`overwrite` param): describes overwrite only as "existing rules ... are overwritten". It doesn't say identical rules are skipped (no revision bump, no `updated_at` change, no history entry). Raised as Risk #6.
- `unchanged_count` description: "had no changes and were not written" describes the mechanism. Users would get more from the effect: revision, update time and change history stay the same. It also never says the value is always `0` when `overwrite=false`. Nit.
- Bundled ESS and serverless specs: both updated, matching the source YAML, with the example included. Clean.
- `oas_docs/output/kibana*.yaml` aren't updated in the PR, but `.buildkite/scripts/steps/openapi_bundling/final_merge.sh` runs `make api-docs` and auto-commits the result on PRs. Not a problem.
- The generated `.gen.ts` picks up the description as JSDoc. New exported telemetry types and functions have no JSDoc, which matches their siblings in `rule_lifecycle_telemetry.ts`. Clean.
- Release note: added an open question on whether a `## Release Note` section is needed to cover the API key and owner change.
- Public docs-content pages: not in this repo, so I couldn't check them. Added as an open question.

**3. Focused review: architecture**

- PR body says `Fixes: #285343`, but the issue also covers no-op writes from `update()`/`patch()`, and those paths are untouched. Raised as Risk #7, plus an open question.
- Placement of the no-op check: putting it in the Security caller rather than in alerting's `bulkUpdateRules()` is defensible. `bulkEdit` does its skip inside alerting (`RULE_NOT_MODIFIED`), but `bulkUpdateRules` takes a full replacement payload, and only Security knows how to normalize `RuleResponse` the same way on both sides. Moving the check into alerting would also change key-rotation behavior for every consumer. Clean.
- Duplication: `overwrite_rules.ts:77-80` repeats the exact check in `restore_rule_state.ts:51-54`. That's two callers today, and the rest of the issue (`update()`/`patch()`) would add a third. Suggesting a shared helper (nit). Added as an open question.
- `types.ts:22-26` (`ImportRuleSuccess`): the "unchanged" fact lives in two places, `unchanged?: boolean` and `telemetry.outcome`. The route reads one and telemetry reads the other. A top-level `outcome`, with telemetry derived from it, would keep the domain result separate from the telemetry payload. Nit; already an open question.
- `rule_lifecycle_telemetry.ts:79-96`: the import sender copies the try/catch from `sendRuleLifecycleTelemetryEvent` (L32-44) instead of making that helper generic over the event payload. Nit.
- Scope: commit 2 (telemetry `outcome` plus the new event schema) can be separated from the bug fix but ships with it, including into the 9.5.6 backport. Ties to Risk #2; added as an open question.
- Dependency direction: `telemetry/event_based/events.ts` importing types from `detection_engine/.../rule_lifecycle_telemetry` follows the existing pattern (`RuleLifecycleTelemetry` and `RuleDuplicateTelemetry` already do this). Clean.

**4. Focused review: api contract**

- Response shape: `unchanged_count` is additive, optional, on the same `2023-10-31` version, and documented as a subset of `success_count`. Existing clients that compare `success_count` to `rules_count` are unaffected. Clean.
- `unchanged_count` isn't in the response `required` list, though `route.ts:232` always sends it. Every other count field is required. Nit; added as an open question.
- Consumers of `ImportRulesResponse`: the UI import modal (`rule_import_modal/utils.ts:57-58`) toasts `success_count` only, so unchanged rules still show as "Successfully imported". The FTR helper and `public/.../api.ts` treat the type as an opaque pass-through. Clean.
- Behavior contract of `overwrite=true`: the guaranteed side effects (revision, timestamps, history, API key and owner, legacy-actions migration) are now conditional. Raised as Risk #8, building on Risks #1 and #6.
- Per-rule errors becoming successes for unchanged-but-invalid rules is also a response-contract change. Already Risk #3.
- Persisted data: no saved-object attributes or mappings change. Change-history `metadata.bulk_count` keeps its value (the full import size), but now sits on fewer entries. Already noted under Assumptions; no migration needed.
- Legacy actions: unchanged rules skip `bulkMigrateLegacyActions`. I didn't verify whether rules with legacy actions can compare as unchanged. Added as an open question.
- Out of focus: the EBT `detection_rule_import` schema change is a telemetry contract, covered by Risk #4.

**5. Digging deeper on Risk #1: API key ownership and the workaround**

- Context: the team discussions (#kibana-alerting with Mike Cote and Patrick Mueller on Aug 24; Georgii on Sep 24; Yara, Kseniia and Georgii confirming in the DEX thread on Sep 28) agreed that rotating keys on no-op imports is a bug. They focused on key *freshness*. Steven's [follow-up on #285343](https://github.com/elastic/kibana/issues/285343#issuecomment-5933664503) makes the point that freshness really comes down to *ownership*: a key goes stale because its owner gets deactivated or loses privileges, so rotating it only helps if someone else takes ownership.
- Verified that disable/enable is **not** a workaround (this corrects the earlier Risk #1 wording and the Aug 24 suggestion). `enable_rule.ts` L150 and `bulk_enable_rules.ts` L245 only call `createNewAPIKeySet` when the rule has no key (`!existingApiKey` / `!rule.attributes.apiKey`), so enabling reuses the old key and owner.
- Verified that **Stack Management → Rules → Update API key** is a valid workaround:
  - the UI calls `bulkEdit` with `field: 'apiKey'` (`triggers_actions_ui/.../rule_api/update_api_key.ts` L36);
  - `update_rule_in_memory.ts` L224-229 mints a new key under the current user (`shouldUpdateApiKey: attributes.enabled || hasUpdateApiKeyOperation`), so the caller becomes the new owner;
  - `bulk_edit_rules.ts` L46 excludes `apiKey` from revision bumps (`bulkEditFieldsToExcludeFromRevisionUpdates`), and change tracking records it as `ruleUpdateApiKey` rather than a blank update (L480);
  - it's a bulk action, so it scales to hundreds of rules, matching what re-import was used for.
- Outcome: Risk #1 is struck through. Keys and owners staying put for unchanged rules is expected behavior of the bug fix, not a regression that needs a workaround. Ownership rotation goes through **Update API key**, same as before. What's left is communication, not code. Risk #6 (API docs `> warn` block) still stands, as does the release-note open question.
- PR description updated on GitHub: added "Unchanged rules keep their existing API key and owner" as decision #2 (worded as expected behavior, linking the [issue comment](https://github.com/elastic/kibana/issues/285343#issuecomment-5933664503)), plus a new `## Risks` section covering ownership on re-import, skipped validation for unchanged rules, conditional `overwrite=true` side effects, safe false-"changed" results, and the telemetry schema change.

**6. Descoped single rule updates from the fix (Risk #7)**

- Edited [#285343](https://github.com/elastic/kibana/issues/285343) so the expected behavior covers only `rules/_import?overwrite=true`, where users re-upload the same file with minor changes.
- Descoped single `update()`/`patch()` on purpose. A single update is an intended user action that should still rotate the API key and write change history, and it's also the remedial path when there's a problem.
- Risk #7 discarded: it's outside the intended fix.

**7. Kept the 9.5 backport (Risk #2)**

- The fix can't land without a behavior change: an identical re-import has to stop writing.
- The new `unchanged_count` response field is deliberate. It tells API users which rules were skipped, so the change is visible rather than silent.
- The backport targets 9.5 only. Change history went GA in 9.5, which is when the blank "No visible field changes" entries became visible to users.
- Risk #2 skipped. Reviewers can push back on the backport if they want.

**8. Explored a fix for Risk #1: refresh the key when a different user runs the import**

Looked at whether import could still rotate keys for the main DaC case: a pipeline or admin re-imports rules owned by someone else. It can, by comparing the rule's `apiKeyOwner` with the importing user.

- An enabled, unchanged rule whose `apiKeyOwner` isn't the importer is rewritten through `bulkUpdateRules()`, which mints a new key under the importer. Patch: [no-op-force-key-refresh-when-ownership-changes.diff](https://github.com/sdesalas/kibana-knowledge/blob/main/patches/no-op-force-key-refresh-when-ownership-changes.diff).
- The comparison is like for like: Alerting stamps `apiKeyOwner` from `core.security.authc.getCurrentUser(request).username` (`rules_client_factory.ts` L454-457, `api_key_as_alert_attributes.ts` L82), the same call Security makes on the same request.
- To be decided.

**9. Dug deeper: what happens to a rule when its key owner is deactivated or replaced**

Looked into how a rule's API key behaves once the owner's account changes, since that's what makes a stale owner a problem in the first place. The rule doesn't re-check the owner at run time, so most owner changes go unnoticed. Script to confirm on a live cluster: [test-rule-api-key-owner.sh](https://github.com/sdesalas/kibana-knowledge/blob/main/scripts/test-rule-api-key-owner.sh).

- Rule runs authenticate with the stored key (`rule_loader.ts` L231/L283). Rule loading does no user or privilege check.
- An ES API key keeps a snapshot of the owner's permissions from when it was created (`limited_by`). Removing roles from the owner later doesn't affect the rule.
- Alerting creates keys with no expiration (`rules_client_factory.ts` L473-479), so rule keys never expire on their own. Only invalidation, or an expiration set later by the owner, breaks them.
- Ran the script on a local 9.6.0-SNAPSHOT stack (native users). Removing bob's read role, disabling bob and deleting bob all leave the rule working: it still alerts (1 → 2), and the key stays valid with both roles in `limited_by`.
- Invalidating or expiring the key breaks the rule (alerts stay at 1 → 1). The likely real-world trigger is offboarding: admins deleting a leaver's API keys in Stack Management or with `DELETE /_security/api_key {"username": ...}`.
- A dead key shows up as the warning "Unable to find matching indices", not an auth error. `run_execution_validation.ts` L80-92 calls `IndexPatternsFetcher.getIndexPatternMatches()`, which swallows errors (`index_patterns_fetcher.ts` L209, L246). Looks like a separate bug worth raising.
- The other case that bites is a key with too little access: the owner's role is widened, or a data view the rule uses grows, after the key was made. The rule runs but can miss data. Not tested.
- A rule running on a leaver's old access isn't a functional problem. It only matters for audit or compliance.
- For this PR: on `main`, a re-import by someone else fixed the deleted-keys case. With #293948 it doesn't. With the activity #8 patch it does again. Update API key still fixes it either way.
- Not tested: Serverless (UIAM keys), external login systems (SAML, OIDC, LDAP), built-in role changes on upgrade.
- Full write-up with a scenarios table: [rule_api_key_owner_staleness.md](https://github.com/sdesalas/kibana-knowledge/blob/main/architecture/rule_api_key_owner_staleness.md).
- Followed up on external login systems with SAML (scenario #11 in the write-up). ES holds no account for a SAML user, so "removing" one means killing their sessions and tokens, changing their IdP groups, or disabling their user profile. Added `saml-*` scenarios to the script, using the dev mock IdP.
- Ran them on 2026-10-02 (local 9.6.0-SNAPSHOT). All three leave the rule alerting (1 → 2) with the key still valid. The key is granted from the user's ES access token and belongs to the SAML realm, but nothing done to the user afterwards reaches it. Same result as native users.
- OIDC grants keys the same way, so it should match. Still not tested: LDAP, removing the SAML realm from ES, and deleting a SAML user's keys at offboarding (expected to break like the native invalidate case).

**10. Checked FTR coverage of the unchanged-rule skip (Risk #5)**

Pulled the PR diff (same two commits as reviewed) and read the new and existing import FTRs to see how much of the skip is tested end to end. There's more coverage than Risk #5 first claimed, but nothing asserts the actual promise of the fix: no revision bump, no `updated_at` change, no history entry.

- The new `import_rules_telemetry.ts` imports a disabled custom query rule, then re-imports it identically and expects `unchanged_count: 1`. That's a real stored-vs-incoming comparison: if normalization disagreed, the rule would count as updated. So the round trip isn't "only mocks".
- The unit tests (`detection_rules_client.import_rules.test.ts`) cover the other half: unchanged rules never reach `bulkUpdateRules`, `bulkEnableRules` or `bulkDisableRules`. Together that's indirect coverage of "unchanged means nothing written".
- The existing overwrite FTRs (`import_rules.ts` L434, `import_rules_with_overwrite.ts` incl. its change-history block at L800, both batch-boundary suites, and the export round trip in `import_rules_identity.ts` L323) all change `name` before re-importing. They only exercise the changed path, which is also why they still pass with `revision + 1`.
- Gaps: other rule types, prebuilt rules with `rule_source`, actions and exceptions, enabled rules (the API key path), and export → re-import with no edits.
- Couldn't confirm CI on the PR; `gh pr checks` only returned skipped jobs on the first page.
- Reworded Risk #5 to the narrower gap.

