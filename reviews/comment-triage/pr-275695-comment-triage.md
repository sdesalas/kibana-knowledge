# PR #275695 comment triage — bulk rule import create path

**PR:** [elastic/kibana#275695](https://github.com/elastic/kibana/pull/275695) — *[Security Solution] Optimize `rules/_import` (create path) via `bulkCreateRules()`*  
**Author:** @sdesalas; later implementation work by @maximpn  
**Branch checked:** `optimize-rule-bulk-import-create-path` @ `6db9ca36adb1` (“Inline split_into_groups to reduce boilerplate”)  
**Previous triage head:** `e132f0064e65` (2026-09-07)  
**Date:** 2026-09-09  
**Review decision:** CHANGES_REQUESTED (Georgii). PR is draft (Georgii converted it 2026-09-08 while work was in progress).  
**CI:** last posted Buildkite result was flaky on `e4b032d` ([build 498148](https://buildkite.com/elastic/kibana-pull-request/builds/498148)). No issue-comment CI result posted yet for `6db9ca36adb1`.

**Method:** All 30 review threads fetched through GraphQL (`--paginate --slurp`), plus non-empty review summaries and top-level human comments. Each claim was checked against the current PR head; GitHub resolved/unresolved flags were not trusted. Local checkout is at the same SHA.

**What changed since 2026-09-07:** telemetry restored (`f401ceb`); batch size set to 200 (`6e86ef2`); `ruleAssetsClient` passed into overwrite (`e4b032d`); overwrite forwards route `changeTracking` verbatim (`d634e1413d4a`); `splitIntoGroups` inlined into `import_rules.ts` (`6db9ca36adb1`). Replies landed on T17, T18, T21, T25–T30. T12/T15/T22/T25–T27/T29 are now GitHub-resolved.

**Counts (by verification, not GitHub flags):** 24 addressed · 4 informational/self-notes · 1 partially addressed performance request · 1 design question waiting on the reviewer

---

## Themes

✅ addressed · ⚠️ waiting / partial · ❌ not addressed

### ✅ 1. Replace the old path; remove flag and decompose implementation (8 threads)

**Status: Addressed. T25 reply landed and the thread is resolved.**

Georgii's central review direction was to update the existing import path rather than maintain two implementations:

- [Review summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834)
- [T10](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) — separate create batch size from overwrite concurrency; remove legacy code.
- [T13](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511) — remove the feature flag and replace the existing implementation.
- [T14](https://github.com/elastic/kibana/pull/275695#discussion_r3570058501) — reuse `DetectionRulesClient.importRules` rather than add `bulkImportRules`.
- [T15](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) — remove legacy/optimized branching.
- [T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) — improve readability and decompose into single-purpose functions.
- [T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) — remove the thin `RuleSourceImporter` abstraction.
- [T25](https://github.com/elastic/kibana/pull/275695#discussion_r3689533705) — Reinaldo asked for the opposite (keep a parallel `import_rules_bulk`). [Replied 2026-09-07](https://github.com/elastic/kibana/pull/275695#discussion_r3948885238): parallel paths were rejected to avoid permanent tech debt. Thread resolved.

**Verified current code:**

- No `bulkImportRulesEnabled` flag or old/new branching remains.
- `DetectionRulesClient.importRules` is the single client method.
- Constants: `RULE_IMPORT_BULK_CREATE_BATCH_SIZE = 200` and `RULE_IMPORT_BULK_UPDATE_CONCURRENCY = 50`.
- `RuleSourceImporter` and its interface/mock/tests are deleted.
- Pipeline is `validateRulesToImport` → inline create/overwrite/conflict split in `import_rules.ts` → `createRules` / `overwriteRules`, with `fetchPrebuiltImportContext` and `findInstalledRulesByRuleIds` for lookups.

### ✅ 2. Missing `DETECTION_RULE_IMPORT_EVENT` telemetry (4 threads)

**Status: Addressed in `f401ceb`. All four threads resolved.**

- [T12](https://github.com/elastic/kibana/pull/275695#discussion_r3568818939) — original telemetry-parity finding.
- [T22](https://github.com/elastic/kibana/pull/275695#discussion_r3593160890) — re-raised after the feature flag was removed.
- [T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756) — Reinaldo repeated it during his local pass.
- [T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056) — AI re-confirmed; Reinaldo agreed.

**Verified current code:** `DetectionRulesClient.importRules` emits `DETECTION_RULE_IMPORT_EVENT` per `result.successes` via `sendRuleLifecycleTelemetryEvent`. `createRules` / `overwriteRules` return `{ rule_id, telemetry }` for successes only. Unit tests cover create + overwrite emit, and no emit on conflict / failed create / thrown bulk create / thrown overwrite.

### ⚠️ 3. Batch-size selection, ECH/local evidence, and ES clause safety (3 threads + review summary)

**Status: Functional safety addressed; performance-selection request still open with Georgii**

Georgii asked in [T17](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) why the value was 200 vs 100/250/500, and whether testing had established an optimum. His [changes-requested summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834) asked for:

- test 2,000 enabled rules separately;
- test 2,000 disabled rules separately;
- compare reasonable batch sizes up to 500.

Evidence already posted:

- [ECH comparison: 1,000 rules at 200/350/500](https://github.com/elastic/kibana/pull/275695#issuecomment-4958201347)
- [Additional 100/150 results and local-versus-ECH context](https://github.com/elastic/kibana/pull/275695#issuecomment-4960949341)
- [Earlier localhost 1,000-enabled result](https://github.com/elastic/kibana/pull/275695#issuecomment-4905072940)

[Steven replied 2026-09-08](https://github.com/elastic/kibana/pull/275695#discussion_r3956633963) that performance is not the only constraint (heap + TM schedule-limit edge cases on mixed enabled/disabled batches). Code now uses **200** (`6e86ef2`). The explicit 2,000-rule matrix is still incomplete. Waiting on Georgii.

ES clause-count safety from [T20](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) **is still addressed**: the outer import loop chunks at 200, each `findInstalledRulesByRuleIds` lookup sees at most that batch, and `find_installed_rules_by_rule_ids.test.ts` pins a full batch below the 1,024 floor.

### ✅ 4. Change-tracking payload ownership (3 threads)

**Status: Addressed. Overwrite leftover fixed in `d634e1413d4a`.**

- [T9](https://github.com/elastic/kibana/pull/275695#discussion_r3537192453) — author note about `bulkCount` flowing from the route.
- [T16](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) — Georgii asked about other change-tracking parameters.
- [T21](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) — Georgii asked for the whole payload, including `action`, to be set in the route. [Replied 2026-09-09](https://github.com/elastic/kibana/pull/275695#discussion_r3965862151).

**Verified current code:** the route constructs `{ action: ruleImport, metadata: { bulkCount } }` and passes it through `importRules`. Both `createRules` and `overwriteRules` forward the caller payload verbatim. Unit tests pin both `bulkCreateRules` and `update`.

### ⚠️ 5. Whole-batch throws and catch shape (3 threads)

**Status: Containment addressed (T3/T5). T28 replied; waiting on Reinaldo.**

- [T3](https://github.com/elastic/kibana/pull/275695#discussion_r3503928659) / [T5](https://github.com/elastic/kibana/pull/275695#discussion_r3527416923) — contain whole-batch throws so earlier responses survive. Done.
- [T28](https://github.com/elastic/kibana/pull/275695#discussion_r3831923999) — Reinaldo asked whether one outer catch over validation → conflicts → overwrite → create is the desired contract.

**Verified current code:** `importRules` still wraps the whole pipeline in one `try/catch`. [Steven replied 2026-09-08](https://github.com/elastic/kibana/pull/275695#discussion_r3957874512): lookups must succeed first; conflicts are mapped; overwrite failures are already swallowed in `pMap`; a create throw has no later stage. No code change. Waiting on Reinaldo.

### ✅ 6. Informational/self-note threads and nits (4 threads)

**Status: T30 addressed. T7–T9 and T23 are obsolete self-notes.**

- [T7](https://github.com/elastic/kibana/pull/275695#discussion_r3537178641) — old author note documenting batch size 200 as the then-new value. Now accurate again, but still just a note.
- [T8](https://github.com/elastic/kibana/pull/275695#discussion_r3537183970) — old author note about the legacy 50-rule chunk; legacy path is gone.
- [T23](https://github.com/elastic/kibana/pull/275695#discussion_r3593361874) — author note about moving a test.
- [T30](https://github.com/elastic/kibana/pull/275695#discussion_r3832002134) — Reinaldo nit: fold `splitIntoGroups` into `validateRulesToImport`. Inlined into `import_rules.ts` instead (`6db9ca36adb1`). [Replied 2026-09-09](https://github.com/elastic/kibana/pull/275695#discussion_r3965946578). Safe to resolve.

### ✅ 7. KQL safety for adversarial `rule_id` values (2 threads)

**Status: Addressed (unchanged)**

- [T2](https://github.com/elastic/kibana/pull/275695#discussion_r3503588112) / [T11](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) — escape + adversarial regression tests.

**Verified current code:** `findInstalledRulesByRuleIds` wraps each value in a quoted KQL literal and uses `escapeQuotes`. Tests still cover embedded quotes, backslashes, parentheses, `*`, angle brackets, `and`/`or`/`not`, and a mixed case.

### ✅ 8. Test wiring and stale tests (2 threads)

**Status: Addressed (unchanged)**

- [T6](https://github.com/elastic/kibana/pull/275695#discussion_r3530801309) / [T24](https://github.com/elastic/kibana/pull/275695#discussion_r3637352453)

**Verified current code:** `detection_rules_client.import_rules.test.ts` still creates one `rulesClient`, passes that instance into `createDetectionRulesClient`, stubs it, and asserts its calls.

### ✅ 9. Recreate `prebuiltRuleAssetClient` in overwrite (1 thread)

**Status: Addressed in `e4b032d`. Thread resolved.**

[T29](https://github.com/elastic/kibana/pull/275695#discussion_r3831960275) — pass the caller’s `ruleAssetsClient` into `overwriteRules`. `import_rules.ts` constructs it once and passes `prebuiltRuleAssetClient: ruleAssetsClient`. Overwrite no longer rebuilds it.

---

## Addressed (verified)

| Thread | Who | Ask | Current evidence |
|---|---|---|---|
| [T1](https://github.com/elastic/kibana/pull/275695#discussion_r3503588107) | AI | Remove/gate unconditional route concurrency cap | Concurrency tag absent |
| [T2](https://github.com/elastic/kibana/pull/275695#discussion_r3503588112) | AI | Escape quoted `rule_id` values | `escapeQuotes` in lookup + adversarial tests |
| [T3](https://github.com/elastic/kibana/pull/275695#discussion_r3503928659) / [T5](https://github.com/elastic/kibana/pull/275695#discussion_r3527416923) | AI | Contain whole-batch throws and preserve responses | Full inner pipeline guarded; per-rule fallback errors |
| [T4](https://github.com/elastic/kibana/pull/275695#discussion_r3504900068) | sdesalas | Chunk large imports without hard cap | Outer loop chunks at 200 |
| [T6](https://github.com/elastic/kibana/pull/275695#discussion_r3530801309) | AI | Fix stale change-tracking test | Rewritten current test suite |
| [T10](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) | banderror | Separate create batch/update concurrency; remove legacy | Two constants; legacy removed |
| [T11](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) | banderror | Harden or regression-test adversarial KQL IDs | Regression matrix in lookup test |
| [T12](https://github.com/elastic/kibana/pull/275695#discussion_r3568818939) / [T22](https://github.com/elastic/kibana/pull/275695#discussion_r3593160890) / [T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756) / [T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056) | AI / jr-araque | Preserve per-success import lifecycle telemetry | `f401ceb`; emit on successes only |
| [T13](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511)–[T15](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) | banderror | Remove flag/parallel path; reuse `importRules` | Single unconditional client path |
| [T16](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) / [T21](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) | banderror | Pass complete change-tracking payload from route | Route owns action + metadata; create and overwrite forward verbatim (`d634e1413d4a`) |
| [T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) | banderror | Decompose implementation | Focused helpers; grouping inlined in `import_rules.ts` |
| [T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) | banderror | Remove anemic importer abstraction | `RuleSourceImporter` deleted |
| [T20](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) | banderror | Bound lookup clauses on low-spec ES | 200 outer cap + 1,024-floor regression test |
| [T24](https://github.com/elastic/kibana/pull/275695#discussion_r3637352453) | AI | Wire the shared rules-client mock | Subject receives the stubbed/asserted `rulesClient` |
| [T25](https://github.com/elastic/kibana/pull/275695#discussion_r3689533705) | jr-araque | Consider parallel legacy/bulk implementations | Intentionally not adopted; replied and resolved |
| [T29](https://github.com/elastic/kibana/pull/275695#discussion_r3831960275) | jr-araque | Pass `prebuiltRuleAssetClient` into `overwriteRules` | `e4b032d`; thread resolved |
| [T30](https://github.com/elastic/kibana/pull/275695#discussion_r3832002134) | jr-araque | Fold grouping into validation | Inlined into `import_rules.ts` (`6db9ca36adb1`) |

---

## Not addressed / needs decision

| Thread | Who | Ask | Current reality |
|---|---|---|---|
| [T17](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) + [review summary](https://github.com/elastic/kibana/pull/275695#pullrequestreview-4663885834) | banderror | Establish optimal batch size, including separate 2,000 enabled/disabled runs | Constant is 200. 1,000-rule ECH/local evidence exists; explicit 2,000 matrix incomplete. Steven replied 2026-09-08. Waiting on Georgii. |
| [T28](https://github.com/elastic/kibana/pull/275695#discussion_r3831923999) | jr-araque | Is one catch over all stages the desired contract? | Replied 2026-09-08: keep the single catch. No code change. Waiting on Reinaldo. |

---

## GitHub resolve-flag review

Checked 2026-09-09 after your second resolve pass. 27 resolved · 3 still open.

| Threads | GitHub flag | Verified reality |
|---|---|---|
| [T1](https://github.com/elastic/kibana/pull/275695#discussion_r3503588107) [T2](https://github.com/elastic/kibana/pull/275695#discussion_r3503588112) [T3](https://github.com/elastic/kibana/pull/275695#discussion_r3503928659) [T4](https://github.com/elastic/kibana/pull/275695#discussion_r3504900068) [T5](https://github.com/elastic/kibana/pull/275695#discussion_r3527416923) [T6](https://github.com/elastic/kibana/pull/275695#discussion_r3530801309) [T7](https://github.com/elastic/kibana/pull/275695#discussion_r3537178641) [T8](https://github.com/elastic/kibana/pull/275695#discussion_r3537183970) [T9](https://github.com/elastic/kibana/pull/275695#discussion_r3537192453) [T10](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) [T11](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) [T12](https://github.com/elastic/kibana/pull/275695#discussion_r3568818939) [T13](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511) [T14](https://github.com/elastic/kibana/pull/275695#discussion_r3570058501) [T15](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) [T16](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) [T19](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) [T20](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) [T21](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) [T22](https://github.com/elastic/kibana/pull/275695#discussion_r3593160890) [T23](https://github.com/elastic/kibana/pull/275695#discussion_r3593361874) [T24](https://github.com/elastic/kibana/pull/275695#discussion_r3637352453) [T25](https://github.com/elastic/kibana/pull/275695#discussion_r3689533705) [T26](https://github.com/elastic/kibana/pull/275695#discussion_r3689831756) [T27](https://github.com/elastic/kibana/pull/275695#discussion_r3821062056) [T29](https://github.com/elastic/kibana/pull/275695#discussion_r3831960275) [T30](https://github.com/elastic/kibana/pull/275695#discussion_r3832002134) | Resolved | Correctly addressed |
| [T18](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) | Unresolved | Addressed in current code; safe to resolve |
| [T17](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) | Unresolved | Correctly open until Georgii accepts 200 or the 2,000 matrix |
| [T28](https://github.com/elastic/kibana/pull/275695#discussion_r3831923999) | Unresolved | Correctly awaiting Reinaldo's reply |

---

## Priority punch list

1. **Decide the performance acceptance boundary with Georgii (T17).** Constant is 200. Either run the requested 2,000 enabled/disabled matrix or get explicit acceptance of 200 for this PR.
2. **Wait on Reinaldo for T28**, or resolve if the 2026-09-08 reply is treated as closed.
3. **Resolve addressed stale threads** T10, T11, T13, T14, T16, T18–T21, T24, and T30.
4. **Resolve obsolete author notes** T7–T9 and T23.
5. **Mark the PR ready for review** once T17 is settled (Georgii drafted it on 2026-09-08).
