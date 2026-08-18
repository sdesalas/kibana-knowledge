# Handoff: import overwrite via bulkUpdateRules — next: FTR

## Context

Steven (`sdesalas`) in `kibana-4th` on branch `rule-bulk-update-poc` ([PR #284946](https://github.com/elastic/kibana/pull/284946)). Session aligned Security Solution `rules/_import` **overwrite** with the create-path design from [PR #275695](https://github.com/elastic/kibana/pull/275695), then refactored `import_rules.ts` into `createRules` / `updateRules` siblings. **Next agent: FTR the import path.** Use the commands below — config paths alone are not a recipe.

## Original dialog

- Check current PR; extend 275695’s bulk-import **create** approach so bulk-import **update** sits on top of it.
- Inline `buildBulkUpdateInputs`.
- Convert `buildBulkInputs()` into `createRules()` (include `rulesClient.bulkCreateRules`); rename `overwriteExisting` → `updateRules`; siblings; shorter `importRules()`.
- “So much easier to read!”
- `/handover`. Next agent tests this. FTR suites for importing rules — see 280553. Pass in the `.config.ts` files modified there. Don’t run the tests, don’t figure out how. Pass on what you already know.

## Conclusions

- **284946 vs 275695:** 275695 already had prepare → classify → `bulkCreateRules`, with overwrite as `pMap` + `importRule`. 284946’s Security wire had been a parallel rewrite of old `import_rules.ts`. This session pulled 275695’s create-path files onto `rule-bulk-update-poc` and replaced overwrite with `rulesClient.bulkUpdateRules`.
- **`importRules()`** (`methods/import_rules.ts`): fetch exceptions + prebuilt context + `findInstalledRulesByRuleIds` in parallel → `prepareRules` → classify conflict | update | create → `updateRules` / `createRules`. Whole-batch throws become per-rule errors for unresponded `rule_id`s.
- **`createRules`:** convert (`applyRuleDefaults` + uuid `options.id`) → `bulkCreateRules` (`RULE_IMPORT_BULK_CREATE_BATCH_SIZE`) → re-pair `successfulIds` / errors to `rule_id`. Enabled is set inline on create.
- **`updateRules`:** convert (`applyRuleUpdate` + existing SO id) → `bulkUpdateRules` (`RULE_IMPORT_BULK_UPDATE_BATCH_SIZE`, `skipIfUnchanged: true`) → re-pair. `enabled` is **not** in `UpdateRuleData`; after a successful save, `toggleImportedEnabled` calls `bulkEnableRules` / `bulkDisableRules` when the file’s `enabled` differs from the installed rule.
- **Constants:** `RULE_IMPORT_BULK_CREATE_BATCH_SIZE = 100`; `RULE_IMPORT_BULK_UPDATE_BATCH_SIZE` aliases it. Outer orchestrator (`logic/import/import_rules.ts`) chunks at create batch size.
- **Removed (matching 275695):** `rule_source_importer/`; `api/timeouts.ts` → `api/constants.ts`.
- **Unit tests already green (this session):** `detection_rules_client.import_rules.test.ts` (17), plus orchestrator / `fetch_prebuilt_import_context` / `find_installed_rules_by_rule_ids` / change-tracking import cases. Overwrite tests assert `bulkUpdateRules` not `importRule`; mixed create+overwrite hits both bulk APIs; changeTracking forwarded; enabled flip uses `bulkEnableRules`.
- **Alerting `RulesClient.bulkUpdateRules`** is already on this branch (committed). Security import wire is **uncommitted**.
- **This branch now contains 275695 create-path files vs `main`.** Landing both PRs will overlap. Overlay vs 275695 is update path + `createRules`/`updateRules` split.

## Current state

- **Repo:** `/Users/sdesalas/Code/sdesalas/kibana-4th`
- **Branch:** `rule-bulk-update-poc` (tracks `origin/rule-bulk-update-poc` for committed alerting work). HEAD `4e118d094ba` (tradeoffs md). **Uncommitted Security Solution import wire** — staged/unstaged mix from `git checkout FETCH_HEAD` of 275695 plus later edits. Do not discard without checking `git status`.
- **Hot file:** `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts`
- **Trial ESS FTR green (follow-up session):** 107 passing on `trial_license_complete_tier/configs/ess.config.ts` (`@ess` grep). Includes overwrite, mixed 501 create+overwrite, 568 overwrite-only, create, conflicts, identity, concurrent, exceptions, actions, connectors.
- **Not done:** basic-license ESS FTR; large-payload FTR; commit of Security wire; PR body still says import create is out of scope (stale vs this work); no rebase onto 275695 (files copied instead).

## Next session focus

**FTR `POST /api/detection_engine/rules/_import` against the uncommitted Security import wire.** Working tree is the SUT — do not discard. Split server/runner so the stack stays up. Config paths from kibana root. Do not invent flags; do not run serverless unless asked.

Suites come from [PR #280553](https://github.com/elastic/kibana/pull/280553). `ess.large_payload.config.ts` is the file that PR modified — it is **not** the starting config.

ESS runner grep (required for the npm wrappers; pass the same if you invoke `functional_test_runner` directly):

`--grep '/^(?!.*@skipInEss).*@ess.*/'`

npm cwd: `x-pack/solutions/security/test/security_solution_api_integration`

### 1. Trial ESS — start here (overwrite + mixed + create)

Same license/stack. Highest-value first: overwrite + batch-boundary, then the full `@ess` suite.

```
node scripts/functional_tests_server.js --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/trial_license_complete_tier/configs/ess.config.ts
node scripts/functional_test_runner --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/trial_license_complete_tier/configs/ess.config.ts --grep '/^(?!.*@skipInEss).*@ess.*/'
```

Fast first pass: `--grep "import_rules with rule overwrite|import rules overwrite at batch boundary|import rules at batch boundary"`

npm: `rule_import_export:server:ess` / `rule_import_export:runner:ess`

### 2. Basic license ESS — new FTR server (different license)

Cannot reuse the trial stack. Kill trial server first.

```
node scripts/functional_tests_server.js --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/basic_license_essentials_tier/configs/ess.config.ts
node scripts/functional_test_runner --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/basic_license_essentials_tier/configs/ess.config.ts --grep '/^(?!.*@skipInEss).*@ess.*/'
```

npm: `rule_import_export:basic:server:ess` / `rule_import_export:basic:runner:ess`

Loads: `export_rules`, `import_rules`, `import_rules_with_overwrite`, `import_rules_transport_errors`.

### 3. Large payload — Kibana restart (extra server arg)

Cannot reuse trial/basic Kibana. This config sets `--xpack.securitySolution.maxRuleImportPayloadBytes=20971520` and a 60m mocha timeout. **Not** the main overwrite suite — only `import_rules_large_payload.ts` (8000 disabled + 2000 enabled). No npm script.

```
node scripts/functional_tests_server.js --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/trial_license_complete_tier/configs/ess.large_payload.config.ts
node scripts/functional_test_runner --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_import_export/trial_license_complete_tier/configs/ess.large_payload.config.ts --grep '/^(?!.*@skipInEss).*@ess.*/'
```

### Expected behavior

- Overwrite keeps definition updates; `enabled` only changes via follow-up enable/disable (file `enabled` vs existing). Alerting `bulkUpdateRules` never writes `enabled`.
- Per-item errors (schema, missing connector, ML auth, conflict without overwrite); whole-batch throws (authz / schedule limit) become per-rule import errors; earlier HTTP chunks stay saved.
- Mixed NDJSON: new `rule_id`s → `bulkCreateRules`; existing + `overwrite` → `bulkUpdateRules`.
- Batch size 100 (`RULE_IMPORT_BULK_*_BATCH_SIZE`); orchestrator chunks at that size. 275695/284946 both mention ~10MB / ~1000 rules upload cap.

## Suggested skills

- `/ftr-testing` — these are Security Solution API FTR suites, not Scout.
- `/kbn-github` — PR 284946 / 275695 / 280553.

## Artifacts

- [PR #284946](https://github.com/elastic/kibana/pull/284946) — this branch; alerting `bulkUpdateRules` + (uncommitted) Security import wire.
- [PR #275695](https://github.com/elastic/kibana/pull/275695) — create-path design this wire extends (`optimize-rule-bulk-import-create-path`).
- [PR #280553](https://github.com/elastic/kibana/pull/280553) — FTR coverage for `rules/_import`.
- [Issue #264894](https://github.com/elastic/kibana/issues/264894) / [#275204](https://github.com/elastic/kibana/issues/275204) — bulk update / import overwrite.
- Tradeoffs: `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_update/bulk_update_rules_tradeoffs.md` (esp. tradeoff 2: no `enabled` in update; callers toggle after).
- Implementation: `.../detection_rules_client/methods/import_rules.ts`; orchestrator `.../logic/import/import_rules.ts`; route `.../api/rules/import_rules/route.ts`.
- Unit tests: `.../detection_rules_client.import_rules.test.ts`.
- Manual fixtures (from PR bodies, not run this session): `kibana-knowledge` `data/rules-import`, `scripts/check-tasks.sh`.
