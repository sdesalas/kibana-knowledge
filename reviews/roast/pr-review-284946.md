# Roast: pr-review-284946.md

**Target:** [`.knowledge/reviews/pr-review-284946.md`](../pr-review-284946.md)
**PRs in scope:** [#284946](https://github.com/elastic/kibana/pull/284946) (POC + callers) and [#286508](https://github.com/elastic/kibana/pull/286508) (alerting primitive; #284946 sits on it)
**Date:** 2026-08-21
**Branch:** `rule-bulk-update-poc`

---

The review is frozen on an older tree. Import enable/skip/breaker is mostly right. Tests, `#264892` auto-close, and PIT decrypt are not — and it never looked hard at upgrade or mixed-batch throws.

---

1. **[STALE] — “alerting `bulkUpdateRules` has no unit tests” / Risk #4 / activity #8**
   **Claim:** OCC, key invalidation, disabled+interval TM, circuit breaker, authz-throw — none of it has a unit test; tests were drafted then dropped.
   **Reality:** Both PRs ship an 892-line unit file. It covers empty input, on/off keys, disabled+interval TM, 10k/batchSize caps, missing ids, authz throw (including later-batch), breaker leftovers, prepare isolation, full SO throw vs per-row, 409 reload/retry/exhaustion, TM swallow, `exitEarlyOnError`, `allowMissingConnectorSecrets`, audit, change tracking. Integration tests are still missing. The “no tests” line is just wrong.
   **Evidence:** `bulk_update_rules.test.ts:165–873` (in #284946 and #286508). Ticket #264894 still asks for integration tests; #286508 explicitly leaves those out.

2. **[STALE] — GitHub will auto-close #264892 / Risk #7**
   **Claim:** `closingIssuesReferences` lists both #264894 and #264892.
   **Reality:** #284946 only closes #264894. #286508 closes nothing. Body already says Related, not Fixes.
   **Evidence:** `gh pr view 284946 --json closingIssuesReferences` → `[264894]`; `286508` → `[]`.

3. **[WRONG] — PIT decrypt failure looks like “not found”**
   **Claim:** One decrypt miss → per-item not-found; no undecrypted GET fallback (unlike `updateRule`).
   **Reality:** ESO PIT **returns the SO** with `error` plus stripped attributes. `loadRulesByIds` concatenates `saved_objects` and never checks `so.error`. `runBatch` treats it as loaded and merges/overwrites. `updateRule` at least falls back to `getRuleSo` and skips key invalidation. Here the old key is gone from the stripped doc, so it cannot be invalidated, and the write can proceed on a half-decrypted original.
   **Evidence:** `encrypted_saved_objects/server/saved_objects/index.ts:154-169`; `bulk_update/utils.ts:65-72`; `bulk_update_rules.ts:158-166`; `update_rule.ts:99-116`.

4. **[MISSING] — zero tests for `bulkUpgradePrebuiltRules`**
   **Claim:** residual is “upgrade still N `getRuleByRuleId`”; import-client tests are the coverage story.
   **Reality:** #264908 asked for same-type / type-change / mixed unit tests **and** API integration tests. There is no `bulk_upgrade_prebuilt_rules.test.ts`. Handler already loaded currents; the method fetches again, then always writes (no `getChanges` skip). That’s the second caller of the new primitive, untested.
   **Evidence:** only `methods/bulk_upgrade_prebuilt_rules.ts`; `perform_rule_upgrade_handler.ts:127-245`.

5. **[MISSING] — mixed import chunk: enable throw skips creates**
   **Claim:** `updateRules` throw → those `rule_id`s become errors; body saved, no flip (activity #3).
   **Reality:** `importRules` does update **then** create. If `bulkEnableRules` / `bulkDisableRules` throw (they can — schedule/authz in `bulk_enable_rules.ts`), `createRules` never runs. Same-chunk creates are reported as errors and never written. Review only talked about the update ids.
   **Evidence:** `import_rules.ts:148-173`, `446-491`; `bulk_enable_rules.ts:223-229`.

6. **[MISSING] — mixed upgrade batch: type-change already committed when same-type authz throws**
   **Claim:** authz still throws; upgrade lets it bubble (Risk #2 / OQ #2).
   **Reality:** type-change `upgradePrebuiltRule` pMap runs **first** and persists. Then same-type hits `bulkUpdateRules`. Authz throw 500s the HTTP handler. Type-change successes never make it into `results`. Breaker no longer throws, so this is specifically the authz path.
   **Evidence:** `bulk_upgrade_prebuilt_rules.ts:90-131`.

7. **[MISSING] — split PR + files the review never listed**
   **Claim:** files touched = bulk_update + detection callers.
   **Reality:** #286508 is the alerting-only slice (tests + `BULK_UPDATE` audit + `bulk_create_rules.ts` APM span renames). Review never names it. Files touched skips `bulk_update_rules.test.ts`, `audit_events.ts`, and the `bulkCreateRules` span rename.
   **Evidence:** #286508 file list; `audit_events.ts:57`; `bulk_create_rules.ts` span name changes.

8. **[OVERSTATED] — `applyRuleDefaults` false-write is “FIXED”**
   **Claim:** per-key `getChanges` (missing === `undefined`) closed the dirty-reimport hole (activity #6).
   **Reality:** missing vs `undefined` is true in the implementation (`get_changes.ts:28-34`) — but there is no test for that case. `get_changes.test.ts` never sets a missing key. Activity #4’s action-UUID hole is still open: `getChanges` diffs `RuleResponse` actions; export-less NDJSON without action ids vs installed actions with ids still looks changed every time. `null` vs `undefined` is still `isEqual` false.
   **Evidence:** `get_changes.ts:20-37`; `get_changes.test.ts:11-50`; `apply_rule_defaults.ts:40`.

9. **[MISSING] — OQ #9 is cited and then absent**
   Activity #2 says leftover `upgradePrebuiltRules` pMap on promotion-rule / legacy prepackaged is OQ #9. Open questions jump 8 → 10. The leftover path is real (`install_promotion_rules.ts`, `legacy_create_prepackaged_rules.ts`).

---

**Fix the doc:** strike Risk #4 / #7; say unit tests exist and integration tests do not; say PIT decrypt is “stripped SO, no `so.error` check,” not not-found; add upgrade-test gap, mixed-chunk enable-throw skipping creates, and type-change-then-authz-throw. Mention #286508.

**Leave it:** import enable/disable after skip (`updateRules` + `toggleImportedEnabled`), tradeoff 10B, breaker-as-errors + migrate-after-schedule, `enabled?: never`, leaky `IDetectionRulesClient.bulkUpdateRules` (Risk #8), stale `route.test.ts` composition comment (Risk #9), double connector `getBulk` (Risk #10), #264892 copied per batch on purpose. Those still match the code.
