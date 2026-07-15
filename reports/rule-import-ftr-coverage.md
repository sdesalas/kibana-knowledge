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
| UI | Good | 8 Cypress cases, focused on toasts and round-trips. |
| Scout | **Missing** | No coverage - though probably better to extend existing FTR coverage |
| Error paths (transport) | **Gap** | No corrupt-NDJSON-line test, no empty-file test, no missing `file` field test |
| Change tracking | **Partial** | Only 2 cases (custom rules); no prebuilt-import case. See bulk-specific subsection below |
| **Scale (batching boundaries)** | **Gap** | High-water mark is 150 rules (exceptions test); pure rule imports top out at ~10. 10,001-rule test only checks rejection. **No test exercises `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` chunking** |
| **KQL-metacharacter `rule_id`s** | **Gap** | No API test with `(`, `)`, `*`, `<`, `>`, `and`, `or`, `not` in `rule_id`. Jest coverage exists but no end-to-end assertion through `findRules` |
| **Concurrent imports** | **Gap** | No test of two overlapping requests |
| **Mixed-outcome single request** | **Partial** | Prebuilt mixed suite covers success paths, custom tier covers partial success separately. No single request combining create + overwrite + conflict + prebuilt classification |
| RBAC on `_import` itself | **Partial** | Actions / response-actions RBAC covered. No test for a user lacking plain `rules_management` privilege calling `_import` |
| All rule types | **Partial** | Mostly `custom_query`. No EQL / ML / threshold / new-terms / ES\|QL / indicator-match round-trip through import |
| Skipped tests | **Known holes** | 4 skipped in prebuilt suite (upgradeable-after-import, equal-payload overwrite, overwrite w/o version) |
| **Import-layer batching over `bulkCreateRules`** | **Gap** | Outer 100-rule chunk loop + inner `batchSize: 100` — never exercised end-to-end |
| **Create / overwrite persistence split** | **Gap** | Refactor split persistence: creates → `bulkCreateRules`, overwrites → `pMap` at `RULE_IMPORT_BULK_UPDATE_CONCURRENCY=50`. No single-request test mixes them |
| **Aggregate schedule-limit + whole-chunk fan-out** | **Gap (optional)** | Needs a dedicated sibling FTR config overriding `maxScheduledPerMinute` to a low value. Precedent exists in the same suite. See subsection below |
| **Large payload regression guard (~6 000 rules)** | **Gap (optional)** | Existing tests top out at ~150 rules. Clients who bump `maxRuleImportPayloadBytes` above the 10 MiB default (avg rule ≈ 12 KB → 6 000 rules ≈ 72 MB) have no coverage. The whole motivation for the refactor was heap pressure at scale, so this is the most direct guard that the perf story doesn't regress. See subsection below |

### Bulk-specific behaviors observable through `_import`

The refactor makes the `_import` endpoint the first consumer of
[`rulesClient.bulkCreateRules`](../../x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts).
Because the alerting plugin does not expose `bulkCreateRules` as an HTTP route,
its end-to-end behavior can, in principle, only be exercised from a consumer.
In practice, most of the behavioral differences vs the legacy per-rule loop
turn out to be either impractical to trigger via `_import` or unobservable from
the outside.

**Worth an FTR via `_import`:**

- **Change tracking** — history is observable via the history endpoint. Extend `rule_management/trial_license_complete_tier/change_tracking.ts` with a prebuilt-import case + `metadata.bulkCount` assertion. Already in the highest-value additions list below.

**Worth an FTR, but only via a dedicated sibling config (optional):**

- **Aggregate schedule-limit + whole-chunk abort fan-out.** Default `xpack.alerting.rules.maxScheduledPerMinute` is **32 000**, so no realistic payload trips the limit. A sibling FTR config that overrides the setting to a low value (e.g. `10`) can trigger it deterministically, and the same throw path exercises fan-out (`bulkCreateRules` throws → import `catch` fans the error out to every not-yet-responded `rule_id` in the chunk). Two-in-one guard. Precedent for the pattern already exists in the same suite: [`ess.rule_changes_history_disabled.config.ts`](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs/ess.rule_changes_history_disabled.config.ts) (spreads parent, overrides `kbnTestServer.serverArgs`, points `testFiles` at a subset). Alerting suite's [`config_with_schedule_circuit_breaker.ts`](../../x-pack/platform/test/alerting_api_integration/security_and_spaces/group3/config_with_schedule_circuit_breaker.ts) is the model for the `maxScheduledPerMinute` override. Cost: 1 config file + 1 test file + 1 line in `ftr_security_stateful_configs.yml` — no new Buildkite step. See Tier 2 in the follow-up PR shape.

- **Large payload regression guard (~6 000 rules).** The refactor exists because the legacy per-rule import path had heap issues at scale. Nothing in the current suite validates that (pure-rule imports top out at ~10; the 150-rule case is exception-heavy). Realistic customer rules average ~12 KB, so a 6 000-rule import is ~72 MB — well above the 10 MiB `maxRuleImportPayloadBytes` default. A sibling config bumps `xpack.securitySolution.maxRuleImportPayloadBytes` to ~100 MB (clients can actually do this in production), imports 6 000 disabled rules, and asserts the response comes back successfully within a generous timeout. Guards the "does the perf story still hold?" property directly. Rules should be **disabled** to keep task manager out of the picture and avoid crossing paths with the schedule-limit config. Runtime is minutes, not seconds — belongs in its own file so it can be quarantined easily if it flakes.

---

## Assessment

The FTR API suite is a **solid regression net for the happy paths and most
error / partial-success branches** of the current code — enough that a
per-rule → bulk refactor will loudly break something in CI if it regresses the
externally-visible contract. The prebuilt classification logic in particular is
covered thoroughly across the customization matrix.

That said, the **import layer on top of `bulkCreateRules`** — outer 100-rule
chunking, create/overwrite persistence split, KQL filter over `rule_id`s — is
new behavior that tests never had reason to exercise before, and needs its own
guards. The internals of `bulkCreateRules` itself mostly don't cleanly manifest
via `_import` (see the bulk-specific subsection above); the two exceptions are
change tracking (extends the existing history-endpoint test) and the schedule-
limit / large-payload cases, which need dedicated sibling configs.

The highest-value additions for the follow-up PR, in priority order:

**Tier 1 — import-layer guards (must-have):**

1. **Batch-boundary test.** Import ≥ `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` × 2
   (≥ 201) custom rules in one request, mixing create and overwrite. Directly
   exercises the new outer chunk + inner `bulkCreateRules` batching. Sits
   naturally next to the existing 150-rule exceptions test in
   `trial_license_complete_tier/import_rules.ts`.
2. **Adversarial `rule_id` FTR test.** 8–10 rules with `rule_id`s containing
   `"`, `\`, `(`, `)`, `*`, `<`, `>`, and the tokens `and` / `or` / `not`.
   Assert each rule round-trips (created, then found by `_find`). Guards the
   hand-built KQL filter in `fetchPrebuiltImportContext`.
3. **Mixed-outcome batch.** One request with created + overwritten + conflicted
   + prebuilt-classified rules, asserting the per-row error/success structure of
   the response. Guards the new inline classification block in
   `methods/import_rules.ts` and the new create/overwrite persistence split.
4. **Prebuilt-import change tracking.** Extend
   `rule_management/trial_license_complete_tier/change_tracking.ts` with a
   prebuilt-import case and an assertion on `metadata.bulkCount`.

**Tier 2 — dedicated sibling configs (optional, high value / low plumbing cost):**

5. **Aggregate schedule-limit + whole-chunk fan-out.** Sibling config
   overriding `xpack.alerting.rules.maxScheduledPerMinute` to a low value
   (e.g. `10`), pointing at a small test file. Import K enabled rules where
   Σ intervals overflow: assert **all K** fail with the circuit-breaker error,
   assert every `rule_id` in the response has an error entry with the same
   message (the whole-chunk fan-out from the import `catch`), assert nothing
   persists. Same shape as
   [`ess.rule_changes_history_disabled.config.ts`](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs/ess.rule_changes_history_disabled.config.ts) — cheap plumbing.
6. **Large payload regression guard (~6 000 rules).** Sibling config bumping
   `xpack.securitySolution.maxRuleImportPayloadBytes` to ~100 MB. Import 6 000
   disabled rules (avg ~12 KB each ≈ 72 MB payload). Assert the response
   succeeds within a generous timeout. Directly validates the refactor's
   perf-at-scale motivation and guards against future regressions for clients
   who configure larger payloads in production. Own file so it can be
   quarantined without impacting the rest of the suite.

Everything else that changed inside `bulkCreateRules` is either impractical to
trigger via `_import` or unobservable end-to-end — see the "Bulk-specific
behaviors" subsection above for the rejections and why.

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

**Tier 1 — import-layer guards** (must-have, wire into existing configs):

- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_at_batch_boundary.ts` — new
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_with_adversarial_rule_ids.ts` — new
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_mixed_outcomes.ts` — new
- `test_suites/detections_response/rule_management/trial_license_complete_tier/change_tracking.ts` — extend with a prebuilt-import case

Wire the new files into the surrounding `index.ts`. No new helpers required —
the shared `importRules` / `importRulesWithSuccess` in
`test_suites/detections_response/utils/rules/import_rules.ts` is enough.

**Tier 2 — dedicated sibling configs** (optional):

*Schedule-limit + whole-chunk fan-out (guards both with one config):*

- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/configs/ess.low_schedule_limit.config.ts` — new sibling config, overrides `xpack.alerting.rules.maxScheduledPerMinute=10` (model:
  [`ess.rule_changes_history_disabled.config.ts`](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs/ess.rule_changes_history_disabled.config.ts))
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/schedule_limit_fan_out.ts` — new test file, pointed to by the sibling config's `testFiles`
- `.buildkite/ftr-manifests/ftr_security_stateful_configs.yml` — one line adding the new config to the `enabled:` list (no new Buildkite step)

*Large payload regression guard (~6 000 rules):*

- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/configs/ess.large_payload.config.ts` — new sibling config, overrides `xpack.securitySolution.maxRuleImportPayloadBytes=104857600` (~100 MB)
- `test_suites/detections_response/rule_import_export/trial_license_complete_tier/import_rules_large_payload.ts` — new test file, imports 6 000 disabled rules
- `.buildkite/ftr-manifests/ftr_security_stateful_configs.yml` — one line for this config too
