# Rule import API — FTR / integration test coverage assessment

Context: PR [#275695](https://github.com/elastic/kibana/pull/275695) reworks the
detection rule `_import` endpoint from a legacy per-rule loop to a bulk-optimized
path built on `rulesClient.bulkCreateRules`. banderror asked
([#3586442017](https://github.com/elastic/kibana/pull/275695#discussion_r3586442017))
to audit the existing integration coverage of the import endpoint in `main` and
add anything missing in a separate PR.

This report inventories what's there today and flags the gaps that specifically
matter for the refactor.

---

## Scope

Endpoint: `POST /api/detection_engine/rules/_import`
(`DETECTION_ENGINE_RULES_IMPORT_URL`).

Test frameworks reviewed:

- FTR API integration (`security_solution_api_integration`)
- FTR functional / UI
- Cypress (`security_solution_cypress`)
- Scout

Implementation is deliberately out of scope — this is a test-coverage audit only.

---

## What exists

### FTR API integration (~120 cases)

All under
[x-pack/solutions/security/test/security_solution_api_integration/](../../x-pack/solutions/security/test/security_solution_api_integration/).
Shared helper:
[test_suites/detections_response/utils/rules/import_rules.ts](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/import_rules.ts)
(`importRules`, `importRulesWithSuccess`, `assertImportedRule`).

#### Custom rule import — `test_suites/detections_response/rule_import_export/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `basic_license_essentials_tier/import_rules.ts` | 19 | Content-type, invalid extension, single / two / 10-rule imports, 10,001-rule limit rejection, conflict handling (duplicate `rule_id` in-batch, existing rule), partial success, overwrite (no conflict, field update, revision bump), malformed `from` validation, defaultable fields |
| `trial_license_complete_tier/import_rules.ts` | 32 | Full custom-rule suite: validation (file type, threshold rules), non-default Kibana spaces, optional fields, bulk (2 rules), action connectors (single + bulk), exceptions (single, agnostic, comments, **150-rule bulk**, non-existent list removal), standalone exception lists, error handling (conflicts, partial success, missing connectors, missing-secrets warning, mixed connector success/failure), endpoint response-action authz (403), forward/backward compat (extra fields stripped, throttle migration) |
| `basic_license_essentials_tier/import_rules_with_overwrite.ts` | 4 | Duplicate `rule_id` in-batch w/ overwrite, re-import same file, overwrite existing rule, overwrite does **not** preserve omitted nullable fields |
| `trial_license_complete_tier/import_rules_with_overwrite.ts` | 4 | Duplicate suite for trial tier |
| `trial_license_complete_tier/import_rules_ess.ts` | 7 | ESS-only: legacy action migration on overwrite, RBAC for rules with/without actions (`hunter`, `hunter_no_actions`), legacy `investigation_fields` array migration (3 variants) |
| `trial_license_complete_tier/import_connectors.ts` | 7 | Connector import w/ and w/o `overwrite_action_connectors`: create, preconfigured, skip existing (409), missing connector (404), overwrite existing |
| `trial_license_complete_tier/import_export_rules.ts` | 4 | Export → reimport round-trip for endpoint + detection exception lists (old/new item versions, comment metadata) |

#### Prebuilt rule import — `test_suites/detections_response/prebuilt_rules/common/import_export/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `import_single_prebuilt_rule.ts` | 19 (1 skipped) | Non-customized / customized prebuilt (no overwrite + overwrite over installed / customized), custom rule, custom↔prebuilt conversion, historical base versions, overwrite matrix. **Skipped**: upgradeable-after-import |
| `import_multiple_prebuilt_rules.ts` | 4 | Mixed batch: non-customized prebuilt + customized prebuilt + custom rule, w/ and w/o overwrite over installed |
| `import_outdated_prebuilt_rules.ts` | 4 | 4 outdated prebuilt rules — fresh import, overwrite outdated installed, overwrite fresh installed, fresh over outdated installed |
| `import_with_missing_base_version.ts` | 6 (1 skipped) | Unknown `rule_id` → custom rule, missing base version (version ±1), overwrite scenarios. **Skipped**: equal-payload overwrite |
| `import_with_missing_fields.ts` | 6 (1 skipped) | Missing `rule_source` / `immutable` inference, missing `rule_id` / `version` errors, custom rule w/o version. **Skipped**: overwrite existing w/o version |
| `import_deprecated_prebuilt_rules.ts` | 2 | Deprecated asset classification, overwrite installed deprecated rule |
| `import_with_installing_package.ts` | 2 | Air-gapped edge cases: import when package not installed, import over existing after package install |
| `export_prebuilt_rules.ts` | 1 import case | Bulk export → delete all → reimport mixed custom + prebuilt rules |

#### Change tracking — `test_suites/detections_response/rule_management/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `trial_license_complete_tier/change_tracking.ts` | 2 | `rule_import` audit event for new import + overwrite import (custom rules only) |

**FTR API subtotal: ~123 defined cases (~119 active, 4 skipped).**

### FTR functional / UI

None. No suite under `x-pack/test/` or `x-pack/platform/test/` hits
`POST /api/detection_engine/rules/_import`. UI coverage is Cypress only.

### Cypress (`security_solution_cypress`) — ~8 cases

| File | Cases | Scenarios |
|------|-------|-----------|
| `rule_actions/import_export/import_rules.cy.ts` | 3 | Import custom rule + exceptions (success toast), re-import conflict (error toast), re-import with overwrite-all |
| `prebuilt_rules/management/import_prebuilt_rule.cy.ts` | 2 | Mixed prebuilt + custom batch (no overwrite, with overwrite-all) |
| `rule_actions/import_export/export_rule.cy.ts` | 1 | Export executed rule → re-import round-trip |
| `prebuilt_rules/management/export_prebuilt_rule.cy.ts` | 1 | Bulk export mixed rules → re-import round-trip |
| `rule_actions/snoozing/rule_snoozing.cy.ts` | 1 | Imported rules are unsnoozed (import as setup) |

Helper: `cypress/tasks/alerts_detection_rules.ts` — `importRules`,
`importRulesWithOverwriteAll` drive the UI file-picker flow and intercept
`POST /api/detection_engine/rules/_import*`.

### Scout

None. No `*.spec.ts` under `x-pack/solutions/security` references `rules/_import`
or detection-rule import helpers.

---

## Gap matrix

| Area | Status | Comment |
|------|--------|---------|
| Custom rule import | Well covered | Both license tiers, spaces, connectors, exceptions |
| Prebuilt rule import | Well covered | Dedicated suite covers classification + overwrite matrix |
| Overwrite branch | Well covered | Dedicated files + inline |
| Conflict handling | Well covered | In-batch dupes + existing-rule conflicts, partial success |
| Error paths (schema) | Good | Invalid extension, malformed fields, 409, 10k cap |
| Error paths (transport) | **Gap** | No corrupt-NDJSON-line test, no empty-file test, no missing `file` field test |
| Change tracking | **Partial** | Only 2 cases (custom rules); no prebuilt case, no `metadata.bulkCount` assertion |
| **Scale (batching boundaries)** | **Gap** | High-water mark is 150 rules (exceptions test); pure rule imports top out at ~10. 10,001-rule test only checks rejection. **No test exercises `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` chunking** |
| **KQL-metacharacter `rule_id`s** | **Gap** | No API test with `(`, `)`, `*`, `<`, `>`, `and`, `or`, `not` in `rule_id`. Jest coverage exists but no end-to-end assertion through `findRules` |
| **Concurrent imports** | **Gap** | No test of two overlapping requests |
| **Mixed-outcome single request** | **Partial** | Prebuilt mixed suite covers success paths, custom tier covers partial success separately. No single request combining create + overwrite + conflict + prebuilt classification |
| RBAC on `_import` itself | **Partial** | Actions / response-actions RBAC covered. No test for a user lacking plain `rules_management` privilege calling `_import` |
| All rule types | **Partial** | Mostly `custom_query`. No EQL / ML / threshold / new-terms / ES\|QL / indicator-match round-trip through import |
| Skipped tests | **Known holes** | 4 skipped in prebuilt suite (upgradeable-after-import, equal-payload overwrite, overwrite w/o version) |
| Scout | **Missing** | No coverage |
| UI | **Thin** | 8 Cypress cases, focused on toasts and round-trips, not response shapes |

### Bulk-specific behaviors (from `rulesClient.bulkCreateRules`)

The refactor swaps a per-rule loop for
[`rulesClient.bulkCreateRules`](../../x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts).
The following are behavioral differences vs the legacy per-rule `rulesClient.create`
path that are worth checking end-to-end. Only creates hit `bulkCreateRules`;
overwrites still go through per-rule `importRule` → `update`.

| # | Behavior | Change vs legacy | FTR coverage today | Worth FTR? |
|---|----------|------------------|--------------------|------------|
| B1 | **Aggregate schedule-limit** — bulk sums all enabled intervals upfront and throws on overflow, fanning the error out to every `rule_id` in the chunk. Legacy shrank capacity per rule and could partially succeed. | Yes | None | **Yes** |
| B2 | **`bulkEnsureAuthorized`** — one authz call for all `(rule_type, consumer)` pairs. Any denial throws → all rules in the chunk fail. Legacy `ensureAuthorized` per rule; one denial did not block the others. | Yes | Partial (actions/response-actions RBAC only) | **Yes** |
| B3 | **Schedule-before-SO ordering** — tasks are scheduled first, then SO bulk-created (no `throwOnConflict`). SO row failures trigger best-effort `bulkRemove` of the orphan task. Legacy was SO-create → schedule → SO-update with `scheduledTaskId`, rollback on schedule failure. | Yes | None (no `scheduledTaskId` / execution-status assertions on import) | **Yes** |
| B4 | **Batch / chunk boundaries** — outer 100-rule chunks in `import_rules.ts` + inner `batchSize: 100` in `bulkCreateRules`. Errors in one chunk do not stop later chunks (`exitEarlyOnError: false`). | Yes | Pure-rule imports top out at ~10; 150-rule test is exception-heavy; 10 001 tests rejection only | **Yes** |
| B5 | **Whole-chunk abort fan-out** — Phase A2/A3 throws in `bulkCreateRules` are caught in `methods/import_rules.ts` and the same message is assigned to every unresponded `rule_id` in that chunk. | Yes (new import surface) | Jest only | **Probably** |
| B6 | **Per-row bulk SO errors → import response** — `{ successfulIds, errors[] }` re-paired via `inputById`; unmapped errors dropped silently. | Partial | Per-row mapping covered in Jest; no FTR isolates an alerting-layer SO failure | **Probably** |
| B7 | **Bulk audit + change tracking** — single bulk `logRuleChanges` and one `RuleAuditAction.BULK_CREATE` audit event per chunk, with shared `changeTracking.metadata.bulkCount`. Legacy emitted one `CREATE` audit per rule. | Partial (per-audit shape changes) | Custom `rule_import` + `bulk_count` covered; prebuilt import case missing | **Probably** (prebuilt only) |
| B8 | **API key generation** — parallel minting (`API_KEY_GENERATE_CONCURRENCY=50`), batch invalidation on failure. Disabled rules skip keys (same as legacy). | Partial | No E2E asserting keys exist / rules actually execute after bulk import | **Probably** |
| B9 | **Mixed create + overwrite in one request** — persistence now split: creates go through `bulkCreateRules`, overwrites through `pMap` with `RULE_IMPORT_BULK_UPDATE_CONCURRENCY=50`. | Yes (persistence split) | Paths covered separately, not one request | **Yes** |

**No new FTR needed** for: duplicate `rule_id` (route dedupes pre-bulk), duplicate
SO id in one call (import always uses fresh UUIDs), action/connector validation
(unchanged, well-covered), overwrite revision bump (unchanged path), `enabled` /
`schedule` defaults (unchanged), task-schedule retry semantics (hard to
reproduce deterministically; owned by alerting unit tests), and
`exitEarlyOnError` (import does not expose it).

---

## Assessment

The FTR API suite is a **solid regression net for the happy paths and most
error / partial-success branches** of the current code — enough that a
per-rule → bulk refactor will loudly break something in CI if it regresses the
externally-visible contract. The prebuilt classification logic in particular is
covered thoroughly across the customization matrix.

That said, the **bulk-specific risk surface is thinly tested**. The current path
uses a per-rule loop, so tests never had reason to exercise batch boundaries,
concurrent round-trips, or `rule_id` values that would round-trip through a
hand-built KQL filter. The refactor changes all three of those.

The highest-value additions for the follow-up PR, in priority order:

1. **Batch-boundary test.** Import ≥ `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` × 2
   (≥ 201) custom rules in one request, mixing create and overwrite. Directly
   exercises the new outer chunk + inner `bulkCreateRules` batching. Sits
   naturally next to the existing 150-rule exceptions test in
   `trial_license_complete_tier/import_rules.ts`. (Covers B4.)
2. **Adversarial `rule_id` FTR test.** 8–10 rules with `rule_id`s containing
   `"`, `\`, `(`, `)`, `*`, `<`, `>`, and the tokens `and` / `or` / `not`.
   Assert each rule round-trips (created, then found by `_find`). Guards the
   hand-built KQL filter in `fetchPrebuiltImportContext`.
3. **Mixed-outcome batch.** One request with created + overwritten + conflicted
   + prebuilt-classified rules, asserting the per-row error/success structure of
   the response. Guards the new inline classification block in
   `methods/import_rules.ts` **and** the new create/overwrite persistence split
   (B9).
4. **Enabled bulk import → task scheduled.** Import M enabled rules; `_find`
   them and assert each has a `scheduledTaskId` (and disabled rules do not).
   Optionally poll for `active` execution status. Guards the inverted
   schedule-before-SO ordering (B3) and the parallel API key path (B8).
5. **Aggregate schedule-limit circuit breaker.** With cluster near schedule
   capacity, import K enabled 1-minute rules where K − 1 would fit individually
   but Σ intervals overflows. Assert **all K** fail with the circuit-breaker
   message and none persist. Legacy would partial-succeed; bulk aborts the
   chunk. (Covers B1.)
6. **Bulk authz all-fail-in-chunk.** User with `create` for query rules but not
   ML. Import a mixed batch and assert both rows error (not "query succeeds, ML
   fails"). Covers B2 — the observable break from the legacy per-rule authz.
7. **Prebuilt-import change tracking.** Extend
   `rule_management/trial_license_complete_tier/change_tracking.ts` with a
   prebuilt-import case and an assertion on `metadata.bulkCount` /
   `RuleAuditAction.BULK_CREATE`. Locks in the payload assembled in `route.ts`
   and the bulk audit shape (B7).

Everything else in the gap matrix is nice-to-have but not directly at risk from
this refactor:

- Concurrent-imports test is a genuine hole but shipping without it isn't
  materially worse than `main` today.
- Missing rule-type coverage (EQL / ML / etc.) is a long-standing gap in the
  import suite, not something this refactor introduces.
- Scout migration for import is worth doing but belongs on the Scout roadmap,
  not this PR.
- Unit coverage in `route.test.ts` and `import_rules.test.ts` addresses the KQL
  regression at the layer where it's built, but does not replace an FTR that
  round-trips through ES.

## Suggested follow-up PR shape

New / modified files, each next to existing suites. Split into two tiers so the
must-haves can ship independently if the bulk-specific ones grow in scope.

**Tier 1 — refactor guards (recommended for the follow-up PR):**

- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_at_batch_boundary.ts` — new (B4)
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_with_adversarial_rule_ids.ts` — new
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_mixed_outcomes.ts` — new (B9 + classification)
- `test_suites/detections_response/rule_management/trial_license_complete_tier/change_tracking.ts` — extend with a prebuilt-import case + `BULK_CREATE` audit assertion (B7)

**Tier 2 — bulk-behavior guards (add if bandwidth allows, or as a second PR):**

- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_enabled_tasks.ts` — new (B3, B8): assert `scheduledTaskId` for imported enabled rules
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_schedule_limit.ts` — new (B1): aggregate schedule-limit fan-out
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_bulk_authz.ts` — new (B2): mixed rule-type authz denial fans out to the whole chunk

Wire each into the surrounding `index.ts`. No new helpers required — the shared
`importRules` / `importRulesWithSuccess` in
`test_suites/detections_response/utils/rules/import_rules.ts` is enough. Tier 2
files may need a low-capacity test-config override (schedule-limit) and an extra
role fixture (bulk authz).
