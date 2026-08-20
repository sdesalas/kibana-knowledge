# PR #275695 comment triage — bulk rule import create path

**PR:** [elastic/kibana#275695](https://github.com/elastic/kibana/pull/275695) — *[Security Solution] Optimize `rules/_import` (create path) via `bulkCreateRules()`*  
**Author:** @sdesalas; latest implementation work by @maximpn  
**Branch checked:** `optimize-rule-bulk-import-create-path` @ `08f9baca78cd` (“Merge branch 'main' into optimize-rule-bulk-import-create-path”)  
**Date:** 2026-08-20  
**CI at checked commit:** [Buildkite passed](https://github.com/elastic/kibana/pull/275695#issuecomment-5355671338)

**Method:** All 27 review threads fetched through GraphQL, plus non-empty review summaries and top-level human comments. Each claim was checked against the current PR head; GitHub resolved/unresolved flags were not trusted.

**Counts (by verification, not GitHub flags):** 17 addressed · 4 informational/self-notes · 4 duplicate threads for 1 real open telemetry regression · 1 partially addressed performance request · 1 design question needing a reply

---

## Executive summary

The latest refactor substantially addresses Georgii's structural review: the feature flag and parallel legacy path are gone, `DetectionRulesClient.importRules` is the single entry point, `RuleSourceImporter` has been removed, and the implementation is decomposed into focused validation, grouping, create, overwrite, and lookup helpers.

Two areas still need human attention:

1. **Import lifecycle telemetry is missing at the current head.** Four threads independently identify the same regression. The latest reviewer re-verified it against today's refactor. This is the only clear code blocker in the inline comments.
2. **Georgii's performance request is only partially satisfied.** ECH comparisons exist for 1,000 enabled/disabled rules across batch sizes 100–500, and the code now uses 250. His explicit request for separate 2,000-enabled and 2,000-disabled runs has not been completed, nor has the high-end LA/ECH versus local comparison in the current task list.

Reinaldo's suggestion to keep a second parallel bulk-import implementation conflicts directly with Georgii's earlier direction to replace the old path. The code follows Georgii's direction and now gains reviewability through decomposition. That thread needs an explanatory reply, not another implementation.

---

## Themes

### 1. Missing `DETECTION_RULE_IMPORT_EVENT` telemetry (4 threads)

**Status: Not addressed at current head — real blocker**

Raised first by AI, acknowledged by Steven, then repeated by Reinaldo and twice more after later refactors:

- [T12](https://github.com/elastic/kibana/pull/275695#discussion_r3568818939) — original telemetry-parity finding; Steven replied “On it.”
- [T22](https://github.com/elastic/kibana/pull/275695#discussion_r3593160890) — re-raised after the feature flag was removed, making the regression unconditional.
- [T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756) — Reinaldo repeated the concern during his local test/review pass.
- [T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056) — latest reviewer confirmed it against `08f9baca78cd`.

**Current code:** `DetectionRulesClient.importRules` delegates to the new import pipeline and returns the result. It does not call `sendRuleLifecycleTelemetryEvent`. `createRules` returns successful `rule_id`s from `bulkCreateRules`; `overwriteRules` also returns only `rule_id`. The `DETECTION_RULE_IMPORT_EVENT` import/call that existed on the old single-rule wrapper is gone.

**Triage:** Treat all four threads as one issue. Fix once, reply on the latest human thread ([T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756)) and latest active AI thread ([T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056)), then resolve the older duplicates.

**Implementation decision needed:** telemetry expects a successful rule domain object, while the new internal result currently contains only `rule_id`. Avoid emitting events for failed `bulkCreateRules` entries. Either retain the successful rule data through `createRules`/`overwriteRules`, or emit from those helpers with the necessary analytics dependency.

### 2. Replace the old path; remove flag and decompose implementation (7 threads)

**Status: Addressed, except Reinaldo's conflicting design question needs a reply**

Georgii's central review direction was to update the existing import path rather than maintain two implementations:

- [Review summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834)
- [T10](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) — separate create batch size from overwrite concurrency; remove legacy code.
- [T13](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511) — remove the feature flag and replace the existing implementation.
- [T14](https://github.com/elastic/kibana/pull/275695#discussion_r3570058501) — reuse `DetectionRulesClient.importRules` rather than add `bulkImportRules`.
- [T15](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) — remove legacy/optimized branching.
- [T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) — improve readability and decompose into single-purpose functions.
- [T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) — remove the thin `RuleSourceImporter` abstraction.

**Verified current code:**

- No `bulkImportRulesEnabled` flag or old/new branching remains.
- `DetectionRulesClient.importRules` is the single client method.
- Constants are independently named and tunable: `RULE_IMPORT_BULK_CREATE_BATCH_SIZE = 250` and `RULE_IMPORT_BULK_UPDATE_CONCURRENCY = 50`.
- `RuleSourceImporter` and its interface/mock/tests are deleted.
- The current pipeline is split across `validateRulesToImport`, `splitIntoGroups`, `createRules`, `overwriteRules`, `fetchPrebuiltImportContext`, and `findInstalledRulesByRuleIds`.

Reinaldo later asked for the opposite architecture in [T25](https://github.com/elastic/kibana/pull/275695#discussion_r3689533705): keep a parallel `import_rules_bulk` implementation to make parity easier to review. Current code intentionally does not do this, consistent with Georgii's changes-requested review. The August 20 decomposition addresses Reinaldo's reviewability concern without retaining duplicate production paths.

**Suggested reply on T25:** explain that keeping parallel paths was explicitly rejected to avoid permanent tech debt, while the latest helper-level decomposition and parity tests provide the requested review surface.

### 3. Batch-size selection, ECH/local evidence, and ES clause safety (3 threads + review summary)

**Status: Functional safety addressed; performance-selection request partially addressed**

Georgii asked directly in [T17](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) why the value was 200 instead of 100, 250, or 500, and whether testing had established an optimum. His [changes-requested summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834) made the acceptance criteria more concrete:

- test 2,000 enabled rules separately;
- test 2,000 disabled rules separately;
- compare reasonable batch sizes up to 500.

Evidence already posted:

- [ECH comparison: 1,000 rules at 200/350/500](https://github.com/elastic/kibana/pull/275695#issuecomment-4958201347)
- [Additional 100/150 results and local-versus-ECH context](https://github.com/elastic/kibana/pull/275695#issuecomment-4960949341)
- [Earlier localhost 1,000-enabled result](https://github.com/elastic/kibana/pull/275695#issuecomment-4905072940)

This is meaningful evidence, but it does not fulfill the explicit 2,000-rule matrix. The current code now uses 250, apparently as the selected compromise, but the PR thread does not contain a completed 2,000-enabled/disabled comparison supporting that exact value.

ES clause-count safety from [T20](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) **is addressed**: the outer import loop chunks at 250, each `findInstalledRulesByRuleIds` lookup sees at most that batch, and `find_installed_rules_by_rule_ids.test.ts` pins a full batch below the 1,024 floor.

Steven's earlier large-import analysis in [T4](https://github.com/elastic/kibana/pull/275695#discussion_r3504900068) is also implemented: the route-level import loop chunks rather than imposing a new hard ceiling.

**Remaining performance work:** complete or explicitly defer the 2,000-rule matrix and the high-end LA/ECH versus local check. Link the follow-up performance ticket when created, then ask Georgii whether the current 250 value is acceptable for this PR.

### 4. Whole-batch throws and partial persistence (2 threads)

**Status: Addressed**

- [T3](https://github.com/elastic/kibana/pull/275695#discussion_r3503928659) — a `bulkCreateRules` preflight throw could discard specific responses and misreport already-persisted overwrites.
- [T5](https://github.com/elastic/kibana/pull/275695#discussion_r3527416923) — later-batch failure could leave earlier batches persisted while returning a generic request failure.

**Verified current code:** each outer batch calls `DetectionRulesClient.importRules`; the internal `importRules` wraps its complete classification/overwrite/create pipeline in `try/catch`. Existing responses are preserved, and any input rule without a response receives a per-rule error. The outer loop then continues aggregating batch responses. `overwriteRules` also contains per-rule failures via `pMap`.

The current unit suite includes “a thrown bulkCreateRules ... surfaces as per-rule errors, not a rejection” and the equivalent lookup-throw case.

### 5. Change-tracking payload ownership (3 threads)

**Status: Addressed**

- [T9](https://github.com/elastic/kibana/pull/275695#discussion_r3537192453) — author note about `bulkCount` flowing from the route.
- [T16](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) — Georgii asked about other change-tracking parameters.
- [T21](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) — Georgii asked for the whole payload, including `action`, to be set in the route.

**Verified current code:** the route constructs `{ action: ruleImport, metadata: { bulkCount } }` and passes it through `importRules`. `createRules` forwards the caller payload verbatim to `bulkCreateRules`. `overwriteRules` applies a `ruleImport` default and then spreads caller-provided change tracking, so the caller remains able to override it.

The current unit suite explicitly checks that caller change tracking is forwarded verbatim to `bulkCreateRules`.

### 6. KQL safety for adversarial `rule_id` values (2 threads)

**Status: Addressed by escaping plus regression coverage**

- [T2](https://github.com/elastic/kibana/pull/275695#discussion_r3503588112) — embedded quote/backslash could break the entire lookup.
- [T11](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) — Georgii requested either stronger escaping or adversarial regression tests for other metacharacters.

**Verified current code:** `findInstalledRulesByRuleIds` wraps each value in a quoted KQL literal and uses `escapeQuotes`. Its tests cover embedded quotes, backslashes, parentheses, `*`, angle brackets, `and`/`or`/`not`, and a mixed case, and assert both the filter literal and successful round-trip lookup.

### 7. Test wiring and stale tests (2 threads)

**Status: Addressed**

- [T6](https://github.com/elastic/kibana/pull/275695#discussion_r3530801309) — old change-tracking assertion did not match the new production call.
- [T24](https://github.com/elastic/kibana/pull/275695#discussion_r3637352453) — tests constructed the subject with a throwaway rules-client mock.

**Verified current code:** `detection_rules_client.import_rules.test.ts` creates one `rulesClient`, passes that exact instance into `createDetectionRulesClient`, stubs it, and asserts its calls. The suite now includes forwarding, error isolation, conflict, create, overwrite, prebuilt, and validation cases. The stale standalone `bulk_import_rules` test file is gone.

### 8. Informational/self-note threads and stale anchors (4 threads)

**Status: No action**

- [T7](https://github.com/elastic/kibana/pull/275695#discussion_r3537178641) — old author note documenting batch size 200; outdated, current value is 250.
- [T8](https://github.com/elastic/kibana/pull/275695#discussion_r3537183970) — old author note about the legacy 50-rule chunk; legacy path is gone.
- [T9](https://github.com/elastic/kibana/pull/275695#discussion_r3537192453) — author note; superseded by current route ownership described above.
- [T23](https://github.com/elastic/kibana/pull/275695#discussion_r3593361874) — author note about moving a test; the test has moved again under `methods/import_rules/`.

Resolve as obsolete/self-notes after the substantive threads are handled.

---

## Addressed (verified)

| Thread | Who | Ask | Current evidence |
|---|---|---|---|
| [T1](https://github.com/elastic/kibana/pull/275695#discussion_r3503588107) | AI | Remove/gate unconditional route concurrency cap | Concurrency tag absent |
| [T2](https://github.com/elastic/kibana/pull/275695#discussion_r3503588112) | AI | Escape quoted `rule_id` values | `escapeQuotes` in lookup + adversarial tests |
| [T3](https://github.com/elastic/kibana/pull/275695#discussion_r3503928659) / [T5](https://github.com/elastic/kibana/pull/275695#discussion_r3527416923) | AI | Contain whole-batch throws and preserve responses | Full inner pipeline guarded; per-rule fallback errors |
| [T4](https://github.com/elastic/kibana/pull/275695#discussion_r3504900068) | sdesalas | Chunk large imports without hard cap | Outer loop chunks at 250 |
| [T6](https://github.com/elastic/kibana/pull/275695#discussion_r3530801309) | AI | Fix stale change-tracking test | Rewritten current test suite |
| [T10](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) | banderror | Separate create batch/update concurrency; remove legacy | Two constants; legacy removed |
| [T11](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) | banderror | Harden or regression-test adversarial KQL IDs | Regression matrix in lookup test |
| [T13](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511)–[T15](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) | banderror | Remove flag/parallel path; reuse `importRules` | Single unconditional client path |
| [T16](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) / [T21](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) | banderror | Pass complete change-tracking payload from route | Route owns action + metadata; forwarded through pipeline |
| [T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) | banderror | Decompose implementation | Focused helper modules at current head |
| [T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) | banderror | Remove anemic importer abstraction | `RuleSourceImporter` deleted |
| [T20](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) | banderror | Bound lookup clauses on low-spec ES | 250 outer cap + 1,024-floor regression test |
| [T24](https://github.com/elastic/kibana/pull/275695#discussion_r3637352453) | AI | Wire the shared rules-client mock | Subject receives the stubbed/asserted `rulesClient` |

---

## Not addressed / needs decision

| Thread | Who | Ask | Current reality |
|---|---|---|---|
| [T12](https://github.com/elastic/kibana/pull/275695#discussion_r3568818939), [T22](https://github.com/elastic/kibana/pull/275695#discussion_r3593160890), [T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756), [T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056) | AI / jr-araque | Preserve per-success import lifecycle telemetry | Missing at current head; one code issue repeated four times |
| [T17](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) + [review summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834) | banderror | Establish optimal batch size, including separate 2,000 enabled/disabled runs | 1,000-rule ECH/local evidence exists; explicit 2,000 matrix incomplete; current constant is 250 |
| [T25](https://github.com/elastic/kibana/pull/275695#discussion_r3689533705) | jr-araque | Consider parallel legacy/bulk implementations | Intentionally not adopted; conflicts with Georgii's accepted direction; reply needed |

---

## GitHub resolve-flag mismatches

| Threads | GitHub flag | Verified reality |
|---|---|---|
| T1–T6 | Resolved | Correctly addressed |
| T10, T11, T13–T16, T18–T21, T24 | Unresolved | Addressed in current code; safe to reply/resolve |
| T7–T9, T23 | Unresolved | Obsolete informational/self-notes |
| T12, T22, T26, T27 | Unresolved | Correctly open; same telemetry regression |
| T17 | Unresolved | Correctly open/partial until perf acceptance or explicit deferral |
| T25 | Unresolved | Correctly awaiting an architectural explanation |

---

## Priority punch list

1. **Restore successful-import lifecycle telemetry** and add create + overwrite tests that prove failures do not emit events. Reply on T26/T27 and close all four duplicates.
2. **Decide the performance acceptance boundary with Georgii.** Either run the requested 2,000 enabled/disabled matrix (including local and ECH/high-end LA) or link a follow-up ticket and get explicit acceptance of 250 for this PR.
3. **Reply to Reinaldo on T25**: no parallel implementation because Georgii requested in-place replacement; point him to the August 20 decomposition and parity tests.
4. **Resolve addressed stale threads** T10, T11, T13–T16, T18–T21, and T24 after concise evidence replies.
5. **Resolve obsolete author notes** T7–T9 and T23.
