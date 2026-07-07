# PR Review: #275695 — [Security Solution] Optimize bulk `rule/_import` (create path) via `bulkCreateRules()`

**PR:** [elastic/kibana#275695](https://github.com/elastic/kibana/pull/275695) by @sdesalas

**Scale:** Substantive — new client method, orchestrator rewrite, feature flag, cross-batch loop, persisted-state side effects.

**Ownership:** All 12 files live under `detection_engine/rule_management/*` — squarely owned by the rule management / detection engineering area. No cross-team files, so review depth is fully warranted here.

---

## Comment triage (what's addressed vs still open)

You asked me to check which PR comments are already handled. Here's the status against HEAD (`b498fc3`):

| Comment | Where | Status |
|---|---|---|
| **Unconditional concurrency tag** (429 on flag-off prod path) | `import_rules/route.ts:69` | ✅ **Addressed.** You removed the concurrency cap entirely — no `registerLimitedConcurrencyRoutes` / `RULE_MANAGEMENT_IMPORT_CONCURRENCY` anywhere in the route now. Flag-off path is back to no cap. |
| **Unescaped KQL `rule_id`** (whole-batch filter blowup) | `bulk_import_rules.ts` conflict lookup | ✅ **Addressed.** `findExistingRuleIds` now wraps each id in `escapeQuotes(id)` from `@kbn/es-query`. |
| **Big imports fail — cap vs chunk (Options A/B/C)** | `bulk_import_rules.ts:145` | ✅ **Addressed.** Went with Option B (chunk internally), at 200 not 5000. Each batch runs its own conflict search + bulk create, so the ES condition-count 500 risk is gone and there's no new hard ceiling. |
| **Uncaught throw from `bulkCreateRules`** (discards per-rule responses) | `bulk_import_rules.ts:253` | ✅ **Mostly addressed.** The `bulkCreateRules` call is now wrapped in `try/catch` and converts a thrown error into per-rule `RuleImportErrorObject`s for the `toBulkCreate` set. Covered by a test ("a thrown bulkCreateRules ... surfaces as per-rule errors"). |
| **Cross-batch partial persistence** (batch N throws, 1..N-1 already committed) | `import_rules.ts:72` | ⚠️ **Partially addressed.** See Risks below — the `bulkCreateRules` throw is now contained, but the chunk loop itself still has no `try/catch`, so a throw from anything *else* inside `bulkImportRules` still aborts mid-loop. |
| **Stale `changeTracking` test** | `bulk_import_rules.test.ts:256` | ✅ **Addressed.** The current test now passes `changeTracking: { metadata: { bulkCount } }` and asserts the merged `{ action: ruleImport, metadata }` shape — matches production. |

Net: the two "blocking-ish" findings (concurrency, KQL escaping) and the design decision (chunking) are done. The remaining nuance is the cross-batch throw window, which is smaller now but not fully closed.

## Summary

Adds a faster path for `POST /api/detection_engine/rules/_import` that routes **new** rules through alerting's `rulesClient.bulkCreateRules()` in batches of 200, instead of the per-rule create loop. Enabled/disabled state, API-key minting and task scheduling all happen inline in the bulk call. It's gated behind a new `bulkImportRulesEnabled` experimental flag (off by default), so production behavior is unchanged until flipped. Rules being **overwritten** (`overwrite: true`) still go through the proven per-rule `importRule` path. The stated intent (parity + ~2-3x speedup on the create path, lower heap) matches what the diff does.

## Files touched

- **Flag + constants:** `common/experimental_features.ts` (new `bulkImportRulesEnabled`), `api/timeouts.ts` → renamed `api/constants.ts` (adds `RULE_MANAGEMENT_IMPORT_BATCH_SIZE = 50` and `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE = 200`). `bulk_actions/route.ts` and `export_rules/route.ts` just update the import path after the rename.
- **New bulk method:** `detection_rules_client/methods/bulk_import_rules.ts` — the core of the PR. Per-rule prep, single conflict lookup, classify (conflict / overwrite / bulk-create), one `bulkCreateRules` call with uuid re-pairing.
- **Wiring:** `detection_rules_client.ts` (adds `bulkImportRules`), `detection_rules_client_interface.ts` (interface + `BulkImportRulesArgs` type alias), `__mocks__/detection_rules_client.ts` (mock).
- **Orchestrator:** `logic/import/import_rules.ts` — now takes a flat `rules` array (not pre-chunked `ruleChunks`), branches on the flag, chunks per path, shared `toImportRuleResponse`. `import_rules/route.ts` passes `experimentalFeatures` and the flat rule list.
- **Tests:** new `detection_rules_client.bulk_import_rules.test.ts` (14 cases), updated `import_rules.test.ts` (bulk-path branch, chunking, error mapping).

## Flow trace (flag ON, mixed enabled/disabled/existing NDJSON)

1. `importRulesRoute` parses NDJSON, validates actions/exceptions, reads `experimentalFeatures`, calls `importRules({ rules, experimentalFeatures, ... })`.
2. `importRules` sees `bulkImportRulesEnabled`, chunks `rules` by 200, calls `detectionRulesClient.bulkImportRules(batch)` per chunk.
3. `bulkImportRules` resolves referenced exception lists, runs `ruleSourceImporter.setup(rules)`, then `prepareRules`: version default, `validateMlAuth`, exception ref check, `calculateRuleSource`. Failures become per-rule errors; survivors are `prepared`.
4. `findExistingRuleIds` runs one escaped KQL OR-filter `findRules` over the batch's rule_ids → `Set` of existing ids.
5. Classify each prepared rule: existing + overwrite → `toOverwrite`; existing + no overwrite → `conflict`; new → `toBulkCreate`.
6. Conflicts pushed as `conflict` errors. `toOverwrite` run through `overwriteExisting` (pMap over per-rule `importRuleSingle`, concurrency 50) — **this persists updates to ES before the bulk create runs**.
7. `buildBulkInputs` converts each new rule to an alerting create input with a pre-assigned uuid (`options.id`), `enabled` preserved; conversion failures become per-rule errors.
8. `rulesClient.bulkCreateRules({ rules, batchSize: 200, changeTracking: { ...ct, action: ruleImport } })` inside a `try/catch`. Successes re-paired by uuid → `{ rule_id }`; per-row errors → per-rule error; a thrown error → every `toBulkCreate` rule gets that error message.
9. `bulkImportRules` returns `{ responses }`; orchestrator maps via `toImportRuleResponse` (409 for conflict, 400 otherwise, 200 success) and accumulates across batches.

## Assumptions

- `params.ruleId` on the alerting side maps 1:1 to the imported `rule_id` — the conflict lookup and the re-pairing both rely on this.
- uuids assigned in `buildBulkInputs` come back verbatim in `successfulIds` / `errors[].rule.id` from `bulkCreateRules`. If alerting ever reassigns ids, re-pairing silently drops responses (the code `if (source)` / `if (!source) return` just skips unmatched).
- `bulkCreateRules` internally batches at `batchSize` and enforces `MAX_RULES_NUMBER_FOR_BULK_OPERATION` (10k) — the outer 200 chunk keeps every call well under that.
- The overwrite branch running before bulk-create is acceptable ordering — overwrites commit even if the later bulk-create throws (now less impactful since the throw is caught).
- `changeTracking.metadata.bulkCount` carries the *pre-batching* NDJSON count from the route, not the per-batch count — the test asserts this threads through unchanged.

## Risks

1. ~~**Cross-batch partial persistence — narrowed but not closed** (`import_rules.ts` bulk loop). The `bulkCreateRules` throw is now caught inside `bulkImportRules`, which was the main case. But the chunk loop still `await`s each `bulkImportRules` with no `try/catch`, and `bulkImportRules` can still throw *before* the guarded section — from `getReferencedExceptionLists`, `ruleSourceImporter.setup`, or `findExistingRuleIds` (`findRules`). If batch N throws there, batches 1..N-1 are already durably in ES but the request returns one top-level error and all accumulated `responses` are discarded → dirty, non-idempotent retry (409s on re-import).~~ **Resolved — see activity #3.** The whole `bulkImportRules` body is now wrapped in one guard that converts any throw into per-rule errors for rules not already reported, so a batch can no longer reject and abort the loop.
2. **Overwrite side effects on a later failure.** `overwriteExisting` commits updates before bulk-create. With the throw now caught this is much less likely to surface as a total failure, but overwrites in an earlier batch are still committed if a *later* batch aborts per (1).
3. **Silent response drop on uuid mismatch.** If `successfulIds`/`errors` ever contain an id not in `inputById`, that rule produces neither a success nor an error response — it just vanishes from the results. Unlikely given uuids are caller-assigned, but there's no assertion/telemetry if it happens. **(see activity #1.)**
4. **`RuleSignatureId` is unconstrained `z.string()`.** Escaping fixed the filter-injection blast radius; worth a passing thought whether any other interpolation of `rule_id` in the new path is unescaped (I only saw the one, and it's fixed).

## Open questions

- For risk (1): is it worth wrapping the per-batch `bulkImportRules` call (or the internal pre-`bulkCreateRules` work) so a throw degrades to per-rule errors for that batch instead of aborting the whole loop? That would fully close the cross-batch dirty-retry case before the flag flips. Or is "flag off + chunk=200 makes findRules throw very unlikely" considered good enough for now?
- `overwriteExisting` uses `pMap` with `concurrency: RULE_MANAGEMENT_IMPORT_BATCH_SIZE` (50). Is 50 concurrent per-rule overwrites (each minting API keys / scheduling tasks) intended, or should overwrite concurrency be its own tuned constant rather than reusing the legacy batch-size number?
- The CI Jest failure in the latest build (`AlertFlyoutOverviewTab ...`) looks unrelated to this diff — is that a known flake, or worth confirming before merge?
- Manual-testing checklist items (flag-on flows, API integration coverage) are still unchecked in the PR body — are those planned before merge or deferred as follow-ups?
- Status codes are flattened on re-wrap: a thrown authz (403), schedule-limit (429), or a per-row `bulkErrors[].status` (e.g. 500) all become `createRuleImportErrorObject` with no status, so `toImportRuleResponse` reports them as `400`. This matches the legacy import model (`RuleImportErrorType` is only `conflict | unknown`), so it's not a regression — but is 400 the right code to show a user for a schedule-limit/authz failure, or worth carrying `status` through the error object? (see activity #1.)

## Notes for your codebase map

- `bulkCreateRules` mints API keys and schedules enabled tasks **inline** per rule — no separate enable pass needed after import. That's the whole speed win vs the per-rule loop.
- Re-pairing pattern: pre-assign a uuid as `options.id`, keep a `Map<uuid, source>`, then map alerting's `successfulIds`/`errors[].rule.id` back to `rule_id`. Reusable pattern for other bulk alerting calls.
- Rule "source" (prebuilt vs custom) is computed via `ruleSourceImporter.calculateRuleSource` + `applyRuleDefaults`, and `params.ruleId` is the stable cross-reference between the security `rule_id` and the alerting rule.
- Import conflict detection is a single KQL OR-list over `alert.attributes.params.ruleId` — ES caps boolean conditions per node (min 1024, heap-scaled), which is exactly why chunk size matters here.
- The per-rule `importRule` path stays authoritative for overwrites; this PR deliberately only optimizes the *create* path.

## Review activities

1. **Error-handling focused pass** over `bulk_import_rules.ts` and `import_rules.ts`. Confirmed the `try/catch` around `rulesClient.bulkCreateRules` correctly contains whole-batch pre-check throws (authz / schedule-limit / hard-limit) and converts them to per-rule errors — the main find from the prior threads is genuinely handled, and a test covers it. **Sharpened Risk #1:** the guard only wraps `bulkCreateRules`; three fallible calls run *before* it inside `bulkImportRules` — `getReferencedExceptionLists`, `await ruleSourceImporter.setup(rules)`, and `findExistingRuleIds` (`findRules`) — none guarded, and the outer chunk loop in `import_rules.ts` has no `try/catch` either. A throw from any of those in batch N still propagates through `importRules` to the route's top-level `catch`, discarding every accumulated per-rule response and leaving batches 1..N-1 committed in ES (classic chunked-write-with-no-rollback). This is the sharpest remaining error-handling gap. **Sharpened Risk #3:** the uuid re-pairing (`if (source)` / `if (!source) return`) silently drops any `successfulIds`/`bulkErrors` id not found in `inputById` — such a rule yields neither success nor error, so it disappears from results with no signal. **New Open question:** re-wrapping via `createRuleImportErrorObject({ ruleId, message })` drops the status code (`RuleImportErrorObject` only distinguishes `conflict | unknown`), so 403/429/500 failures all surface as `400`; consistent with the legacy import model, so not a regression, but flagged for a decision. Checked for missing `await`s (none — all fallible async calls are awaited) and double-reporting in the `catch` (none — `inputById` only holds successfully-built inputs, and `bulkErrors` is processed inside the `try` after the await resolves). Per-rule containment in `prepareRules` and `overwriteExisting` (`pMap` with per-item `try/catch`) is solid.
2. **Over-engineering focused pass** over `bulk_import_rules.ts` (cross-checked against `import_rule.ts`). One real finding: in `overwriteExisting` (`bulk_import_rules.ts:314-328`), the awaited `importRuleSingle` result is cast `as RuleResponse | RuleImportErrorObject` and then guarded with `if (isRuleImportError(updated)) return updated;` — but `importRule` is typed `Promise<RuleResponse>` and only ever *throws* the error object (the sole `createRuleImportErrorObject` in `import_rule.ts:55` is a `throw`, in the `existingRule && !overwriteRules` branch), never returns it. So the resolved-value guard handles a shape the return path can't produce, and the cast exists only to make that dead branch typecheck. The real error object arrives via the `catch` at line 330. Simplify to `const updated = await importRuleSingle(...); return { rule_id: updated.rule_id };` and drop the cast. Secondary note: the catch's `if (isRuleImportError(err)) return err;` is itself unreachable *for this caller* (overwrite path passes `overwriteRules: true` on rules already known to exist, so the conflict-throw branch never fires) — but as a cross-method catch guard it's cheap belt-and-suspenders, leave it. Minor nits: `missingVersionError` and the `BulkImportRulesArgs = ImportRulesArgs` alias are each single-use, but both aid readability — not worth changing. **Non-findings:** the `try/catch` in `buildBulkInputs` and `prepareRules` guard genuinely-throwing calls (conversion of a malformed rule, `validateMlAuth`) — that per-rule isolation is the stated design, not defensiveness. Decomposing the method into `prepareRules`/`findExistingRuleIds`/`overwriteExisting`/`buildBulkInputs` is readable decomposition, not single-use-abstraction bloat.
3. **Fixed Risk #1 (cross-batch partial persistence).** Wrapped the full `bulkImportRules` body (`bulk_import_rules.ts`) in a single `try/catch`; the `catch` builds a set of already-responded `rule_id`s and pushes an error for every input rule not in it, so the method now always resolves with a per-rule outcome and never rejects. This subsumes the old inner `try/catch` around `bulkCreateRules` (removed — the outer guard covers the same `toBulkCreate` set), and also contains throws from `getReferencedExceptionLists`, `ruleSourceImporter.setup`, and `findExistingRuleIds` that previously aborted the chunk loop. Added a regression test ("a thrown conflict lookup surfaces as per-rule errors, not a rejection") mocking `findRules` to reject; full suite 15/15 green. `import_rules.ts` loop left untouched — the guarantee lives at the source. Trimmed an over-long comment per repo style guidance.
