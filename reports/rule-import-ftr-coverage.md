# Rule import API — FTR / integration test coverage assessment

Context: PR [#275695](https://github.com/elastic/kibana/pull/275695) reworks the
detection rule `_import` endpoint from a legacy per-rule loop to a bulk-optimized
path built on `rulesClient.bulkCreateRules`. banderror asked
([#3586442017](https://github.com/elastic/kibana/pull/275695#discussion_r3586442017))
to audit the existing integration coverage of the import endpoint in `main` and
add anything missing in a separate PR.

That coverage PR must land before the rewrite merges. The point is to lock the
externally-visible contract as it behaves today, so the rewrite cannot silently
change it. Adding the same tests after the rewrite only proves the new code
matches itself.

This report inventories what's on `main` today, flags gaps that matter for the
rewrite, and splits additions into: (1) a baseline PR that must merge first, and
(2) tests this rewrite PR should add for behaviours that only exist after bulk.

---

## What the rewrite can break that existing FTR would miss

The FTR suite is a solid net for happy paths, conflicts, overwrite, connectors,
exceptions, and the prebuilt classification matrix. It will catch many regressions.
It will not catch the new import-layer behaviours introduced by the rewrite,
because nothing on `main` exercises them at scale or through the new split paths:

| Risk from the rewrite | Why existing FTR misses it | Where to add coverage |
|-----------------------|----------------------------|----------------------|
| Outer chunking at `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (100) | Pure-rule imports top out at ~10; the 150-rule case is exception-heavy. Jest covers the outer `chunk()` loop in unit tests only. | Baseline: import ≥ 201 disabled custom rules; assert success + `_find` |
| Create vs overwrite persistence split (`bulkCreateRules` vs `pMap` overwrite) | Prebuilt-mix create+overwrite exists at small scale; no custom-only mixed batch across a chunk boundary (≥101) | Baseline: same batch-boundary request mixes creates + overwrites |
| Hand-built KQL `rule_id` filter → real ES | Jest asserts filter string shape with a mocked `find`. Main's unescaped filter 400s on metacharacters | Rewrite PR: adversarial `rule_id` import + `_find` (after escaping lands) |
| Change tracking for prebuilt import | Custom import + overwrite + `bulkCount` covered; no prebuilt-import history case | Baseline: extend `change_tracking.ts` |
| Catch fan-out (whole chunk fails → every not-yet-responded `rule_id` gets the error) | New `catch` path around `bulkCreateRules`; nothing on `main` matches this shape | Rewrite PR: Jest on the `catch` path; optional schedule-limit FTR |
| Large-payload / scale motivation | Commented-out 10k test; rewrite exists because legacy path struggled at scale | Rewrite PR: revive/adapt large-payload FTR under bulk |

Note on "double batching": the outer chunk size and the `bulkCreateRules({ batchSize })`
are both `100`. Within one outer call, the inner `batchSize` is a no-op. An FTR of
≥ 201 rules proves outer multi-batch behaviour only. Inner batching only becomes
observable if those constants diverge.

---

## Scope

Endpoint: `POST /api/detection_engine/rules/_import`
(`DETECTION_ENGINE_RULES_IMPORT_URL`).

Test frameworks reviewed:

- FTR API integration (`security_solution_api_integration`)
- FTR functional / UI
- Cypress (`security_solution_cypress`)

Scout is not used for this endpoint today; keep adding coverage in FTR.

Implementation is deliberately out of scope — this is a test-coverage audit only.

---

## What exists

### FTR API integration (~120 cases)

All under
[x-pack/solutions/security/test/security_solution_api_integration/](../../x-pack/solutions/security/test/security_solution_api_integration/).
Shared helper:
[test_suites/detections_response/utils/rules/import_rules.ts](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/rules/import_rules.ts)
(`importRules`, `importRulesWithSuccess`, `assertImportedRule`).

#### Custom rule import — `test_suites/detections_response/rules_management/rule_import_export/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `basic_license_essentials_tier/import_rules.ts` | 19 | Content-type, invalid extension, single / two / 10-rule imports, 10,001-rule limit rejection, conflict handling (duplicate `rule_id` in-batch, existing rule), partial success, overwrite (no conflict, field update, revision bump), malformed `from` validation, defaultable fields. Also: a commented-out 10,000-rule success test ("uncomment once we speed up the alerts client find api") |
| `trial_license_complete_tier/import_rules.ts` | 32 | Full custom-rule suite: validation (file type, threshold rules), non-default Kibana spaces, optional fields, bulk (2 rules), action connectors (single + bulk), exceptions (single, agnostic, comments, 150-rule bulk, non-existent list removal), standalone exception lists, error handling (conflicts, partial success, missing connectors, missing-secrets warning, mixed connector success/failure), endpoint response-action authz (403), forward/backward compat (extra fields stripped, throttle migration) |
| `basic_license_essentials_tier/import_rules_with_overwrite.ts` | 4 | Duplicate `rule_id` in-batch w/ overwrite, re-import same file, overwrite existing rule, overwrite does not preserve omitted nullable fields |
| `trial_license_complete_tier/import_rules_with_overwrite.ts` | 4 | Duplicate suite for trial tier |
| `trial_license_complete_tier/import_rules_ess.ts` | 7 | ESS-only: legacy action migration on overwrite, RBAC for rules with/without actions (`hunter`, `hunter_no_actions`), legacy `investigation_fields` array migration (3 variants) |
| `trial_license_complete_tier/import_connectors.ts` | 7 | Connector import w/ and w/o `overwrite_action_connectors`: create, preconfigured, skip existing (409), missing connector (404), overwrite existing |
| `trial_license_complete_tier/import_export_rules.ts` | 4 | Export → reimport round-trip for endpoint + detection exception lists (old/new item versions, comment metadata) |

#### Prebuilt rule import — `test_suites/detections_response/rules_management/prebuilt_rules/common/import_export/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `import_single_prebuilt_rule.ts` | 19 (1 skipped) | Non-customized / customized prebuilt (no overwrite + overwrite over installed / customized), custom rule, custom↔prebuilt conversion, historical base versions, overwrite matrix. Skipped: upgradeable-after-import |
| `import_multiple_prebuilt_rules.ts` | 4 | Mixed batch: non-customized prebuilt + customized prebuilt + custom rule, w/ and w/o overwrite over installed (includes create+overwrite in one request) |
| `import_outdated_prebuilt_rules.ts` | 4 | 4 outdated prebuilt rules — fresh import, overwrite outdated installed, overwrite fresh installed, fresh over outdated installed |
| `import_with_missing_base_version.ts` | 6 (1 skipped) | Unknown `rule_id` → custom rule, missing base version (version ±1), overwrite scenarios. Skipped: equal-payload overwrite |
| `import_with_missing_fields.ts` | 6 (1 skipped) | Missing `rule_source` / `immutable` inference, missing `rule_id` / `version` errors, custom rule w/o version. Skipped: overwrite existing w/o version |
| `import_deprecated_prebuilt_rules.ts` | 2 | Deprecated asset classification, overwrite installed deprecated rule |
| `import_with_installing_package.ts` | 2 | Air-gapped edge cases: import when package not installed, import over existing after package install |
| `export_prebuilt_rules.ts` | 1 import case | Bulk export → delete all → reimport mixed custom + prebuilt rules (file has more export-only cases) |

Prebuilt `import_export/` has 3 `it.skip` total (not 4).

#### Change tracking — `test_suites/detections_response/rules_management/rule_management/`

| File | ~Cases | Scenarios |
|------|--------|-----------|
| `trial_license_complete_tier/change_tracking.ts` | 3 import-related | `rule_import` for new import + overwrite import (custom); `metadata.bulk_count` for a 3-rule custom import. Missing: prebuilt-import history case |

FTR API subtotal: ~122 defined cases (~119 active, 3 skipped in prebuilt import_export).

### FTR functional / UI

None. No suite under `x-pack/test/` or `x-pack/platform/test/` hits
`POST /api/detection_engine/rules/_import`. UI coverage is Cypress only.

### Cypress (`security_solution_cypress`) — ~8 import-related cases

| File | Cases | Scenarios |
|------|-------|-----------|
| `rule_actions/import_export/import_rules.cy.ts` | 3 | Import custom rule + exceptions (success toast), re-import conflict (error toast), re-import with overwrite-all |
| `prebuilt_rules/management/import_prebuilt_rule.cy.ts` | 2 | Mixed prebuilt + custom batch (no overwrite, with overwrite-all) |
| `rule_actions/import_export/export_rule.cy.ts` | 1 import | Export executed rule → re-import round-trip (file has more export-only cases) |
| `prebuilt_rules/management/export_prebuilt_rule.cy.ts` | 1 import | Bulk export mixed rules → re-import round-trip |
| `rule_actions/snoozing/rule_snoozing.cy.ts` | 1 | Imported rules are unsnoozed (import as setup) |

Helper: `cypress/tasks/alerts_detection_rules.ts` — `importRules`,
`importRulesWithOverwriteAll` drive the UI file-picker flow and intercept
`POST /api/detection_engine/rules/_import*`.

### Jest already covering rewrite-adjacent behaviour

Worth calling out so the baseline PR doesn't duplicate unit work:

- Outer chunk loop: `logic/import/import_rules.test.ts` (`RULE_IMPORT_BULK_CREATE_BATCH_SIZE + 1`)
- Adversarial `rule_id` filter string construction: `logic/import/fetch_prebuilt_import_context.test.ts` (full metacharacter matrix against a mocked `find`)

These do not replace FTR: they never hit ES or the HTTP `_import` surface.

---

## Gap matrix

Status column is the scan key. No extra emphasis on rows — if it's a Gap, the status says so.

| Area | Status | Comment |
|------|--------|---------|
| Custom rule import | Well covered | Trial/complete: spaces, connectors, exceptions. Basic tier: core custom import + conflicts/overwrite only |
| Prebuilt rule import | Well covered | Dedicated suite covers classification + overwrite matrix |
| Overwrite branch | Well covered | Dedicated files + inline |
| Conflict handling | Well covered | In-batch dupes (400) + existing-rule conflicts (409 in `errors[]`) + partial success |
| Error paths (schema / caps) | Good | Invalid extension (400), malformed fields (400), 10k cap (500). Conflict 409 is under Conflict handling, not here |
| UI | Good | ~8 Cypress import-related cases (toasts + round-trips) |
| Change tracking (custom) | Good | New + overwrite + `bulk_count` for multi-rule custom import |
| Error paths (transport) | Gap | No FTR for corrupt NDJSON / empty file / missing `file`. Jest cases exist in `route.test.ts` but that suite is `describe.skip`. Include in baseline PR |
| Change tracking (prebuilt import) | Gap | No `rule_import` history case for prebuilt rules via `_import` (`rule_install` / upgrade are covered; import is not) |
| Scale (batching boundaries) | Gap | High-water mark is 150 rules (exceptions); pure rule imports top out at ~10. 10,001-rule test only checks rejection. Commented-out 10k success test exists but is disabled. No active test exercises outer chunking end-to-end |
| KQL-metacharacter `rule_id`s | Gap (rewrite PR) | Main builds unescaped `ruleId:(a or b)` filters (HTTP 400 on metacharacters). Escaping + success-path FTR belong with the bulk rewrite, not the main baseline |
| Create / overwrite in one request | Partial | Prebuilt-mix create+overwrite covered (FTR + Cypress). Gap: custom-only mixed batch (some exist, some don't, `overwrite=true`), and that pattern across a chunk boundary (≥101) |
| Concurrent imports | Gap | No overlapping-request test. Include in baseline PR — rewrite changes persistence/batching; races are more interesting after that |
| Mixed-outcome single request | Good enough | Already covered: 2 success + 1 conflict; 1 success + connector failure. Combining create+overwrite+failure in one mega-request is packaging, not a rewrite blocker |
| RBAC on `_import` itself | Partial | Actions / response-actions privilege branching covered (`hunter`, `hunter_no_actions`, endpoint response-actions). No test that a user lacking `RULES_API_ALL` gets 403 on `_import` itself |
| All rule types | Gap | Success paths are almost all `custom_query`. Threshold appears only as validation failures. No EQL / ML / new-terms / ES\|QL / indicator-match import round-trip. Include in baseline PR |
| Skipped tests | Known holes | 3 `it.skip` in prebuilt `import_export/` (upgradeable-after-import, equal-payload overwrite, overwrite w/o version) |
| Aggregate schedule-limit + catch fan-out | Gap (rewrite PR) | New bulk `catch` / schedule-limit interaction. Prefer Jest; optional sibling FTR with low `maxScheduledPerMinute` |
| Large payload (~thousands of rules) | Gap (rewrite PR) | Disabled 10k success test in-tree; revive under bulk as the scale regression guard |

---

## Assessment

Existing FTR is enough to catch regressions in the externally-visible contract for
typical imports (custom, prebuilt, overwrite, conflict, connectors, exceptions).
It is not enough at the seams the rewrite touches, and a few long-standing holes
should be locked before the pathway moves.

Two PRs, two jobs:

- Baseline PR (merge first): lock today's contract on `main`.
- Rewrite PR (#275695): keep those green, and add coverage for behaviours that
  only exist after the bulk path.

### Baseline PR (merge before the rewrite)

Lock externally-visible behaviour that already exists on `main` (or should):

1. Batch-boundary test. Import ≥ `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` × 2
   (≥ 201) disabled custom rules in one request, mixing creates and overwrites.
   Assert response success counts and that rules are readable via `_find`.
2. Prebuilt-import change tracking. Extend
   `rule_management/trial_license_complete_tier/change_tracking.ts` with a
   prebuilt-import case. (`bulk_count` for custom multi-import already exists.)
3. Transport corruption. Corrupt NDJSON line, empty file, missing `file` field.
4. Concurrent imports. Two overlapping `_import` requests (distinct `rule_id`s,
   and a variant that shares a `rule_id` without overwrite).
5. Rule-type matrix. One successful import round-trip per detection rule type
   (`custom_query`, `threshold`, `eql`, `threat_match`, `new_terms`, `esql`,
   and ML where license/setup allows).
6. Identity (`id` vs `rule_id`). Payload `id` ignored on create; overwrite by
   matching `rule_id` keeps the existing SO id; import with existing SO id but
   a different `rule_id` creates a second rule; same payload `id` twice in one
   NDJSON; overwrite cannot reassign SO ownership; conflict key is `rule_id`;
   export round-trip; prebuilt overwrite; cross-space (see
   [#279741](https://github.com/elastic/kibana/issues/279741)).

Note: adversarial `rule_id` import + `_find` is **not** a main baseline case.
On main, import looks up existing/prebuilt rules with an unescaped
`ruleId:(a or b)` KQL filter, so metacharacter `rule_id`s 400 before any
contract is worth locking. Escaping lands with the bulk rewrite — put the
success-path FTR there.

### Rewrite PR (#275695) — new coverage this PR should add

Do not put these in the baseline PR: they assert bulk-path-only behaviour (or
the scale story that motivated the rewrite).

1. Adversarial `rule_id` FTR (success path). 8–10 rules whose `rule_id`s
   contain `"`, `\`, `(`, `)`, `*`, `<`, `>`, and the tokens `and` / `or` /
   `not`. Import, then `_find` each by `rule_id`. Depends on the rewrite's
   KQL escaping; does not pass on main's unescaped filter construction.
2. Catch fan-out (prefer Jest). One throw mid-batch → every not-yet-responded
   `rule_id` gets the same error; nothing extra persists. This `catch` wraps
   `bulkCreateRules` and has no legacy equivalent worth locking first.
3. Schedule-limit + whole-chunk fan-out (optional FTR). Sibling config with low
   `xpack.alerting.rules.maxScheduledPerMinute` (model:
   [`config_with_schedule_circuit_breaker.ts`](../../x-pack/platform/test/alerting_api_integration/security_and_spaces/group3/config_with_schedule_circuit_breaker.ts)
   + local precedent
   [`ess.rule_changes_history_disabled.config.ts`](../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/configs/ess.rule_changes_history_disabled.config.ts)).
   First real HTTP consumer of `bulkCreateRules` is `_import` — this is where
   that circuit-breaker path becomes observable end-to-end.
4. Large payload regression guard. Revive/adapt the commented-out 10,000-rule
   success test (longer timeout / sibling config bumping
   `maxRuleImportPayloadBytes` if needed). Disabled rules. Own file so it can
   be quarantined. This is the perf-at-scale claim the rewrite was made for.

The baseline suite should stay green on this PR unchanged. If a baseline test
needs a rewrite-only assertion, keep the contract assertion in baseline and add
the bulk-specific check here.

---

## Suggested PR shapes

### Baseline PR

- `…/rule_import_export/trial_license_complete_tier/import_rules_at_batch_boundary.ts` — new
- `…/rule_import_export/trial_license_complete_tier/import_rules_transport_errors.ts` — new
- `…/rule_import_export/trial_license_complete_tier/import_rules_concurrent.ts` — new
- `…/rule_import_export/trial_license_complete_tier/import_rules_by_type.ts` — new
- `…/rule_import_export/trial_license_complete_tier/import_rules_identity.ts` — new (`id` vs `rule_id`; locks today’s contract from [#279741](https://github.com/elastic/kibana/issues/279741))
- `…/rule_management/trial_license_complete_tier/change_tracking.ts` — extend with prebuilt-import case

Wire new files into the surrounding `index.ts`. Shared
`importRules` / `importRulesWithSuccess` helpers are enough; concurrent case may
need a thin wrapper that fires two requests without awaiting the first. Reuse
existing rule-param helpers (`getEqlRuleForAlertTesting`, etc.) for the type matrix.

### Rewrite PR (#275695)

- `…/import_rules_with_adversarial_rule_ids.ts` — new (success path; needs rewrite KQL escaping)
- Jest: catch fan-out on the import client method (`methods/import_rules` / equivalent)
- Optional: `configs/ess.low_schedule_limit.config.ts` + `schedule_limit_fan_out.ts` + one line in `.buildkite/ftr-manifests/ftr_security_stateful_configs.yml`
- Optional: revive/adapt the disabled 10k test under a dedicated large-payload config
