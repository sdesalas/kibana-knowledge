# Rule import API — FTR / integration test coverage assessment

Context: PR [#275695](https://github.com/elastic/kibana/pull/275695) reworks the
detection rule `_import` endpoint from a legacy per-rule loop to a bulk-optimized
path built on `rulesClient.bulkCreateRules`. banderror asked
([#3586442017](https://github.com/elastic/kibana/pull/275695#discussion_r3586442017))
to audit the existing integration coverage of the import endpoint in `main` and
add anything missing in a separate PR.

That coverage must land before the rewrite merges. The point is to lock the
externally-visible contract as it behaves today, so the rewrite cannot silently
change it. Adding the same tests after the rewrite only proves the new code
matches itself.

This report inventories what `_import` coverage exists on `main` today, and
lists the **behavioral gaps** that still need locking (create baseline, bulk
create rewrite, bulk update rewrite). It deliberately describes *what* is
missing — not proposed file layouts from a coverage branch.

---

## Scope

Endpoint: `POST /api/detection_engine/rules/_import`
(`DETECTION_ENGINE_RULES_IMPORT_URL`).

Test frameworks reviewed:

- FTR API integration (`security_solution_api_integration`)
- FTR functional / UI
- Cypress (`security_solution_cypress`)

Scout and unit / Jest tests are out of scope. Prefer new coverage as FTR API
integration tests.

---

## What main already covers

Solid net for typical imports. Roughly ~120 FTR API cases plus ~8 Cypress
import-related flows.

### Custom rules

- Happy path: single / small bulk import, defaultable fields, optional fields
- Non-default Kibana spaces
- Conflicts: in-batch duplicate `rule_id` (400), existing-rule conflict (409 in
  `errors[]`), partial success mixed with successes
- Overwrite: no conflict, field update, revision bump, omitted nullable fields
  cleared (not merged), re-import same file
- Schema / caps: invalid content-type / extension, malformed `from`, threshold
  validation, 10,001-rule rejection (there is a commented-out 10k success case)
- Connectors: import with/without `overwrite_action_connectors`, missing
  connector, missing-secrets warning, mixed connector outcomes, preconfigured
- Exceptions: single-space, agnostic, comments, ~100-rule bulk with exceptions,
  non-existent list removal, standalone exception lists, export→reimport
- Actions / response-actions authz branching (`hunter` / `hunter_no_actions`,
  endpoint response-actions 403)
- ESS-only: legacy action migration on overwrite, legacy `investigation_fields`
- Forward/backward compat: extra fields stripped, throttle migration

Main homes for this:
`rule_import_export/{basic,trial}_license_*/import_rules*.ts`,
`import_connectors.ts`, `import_export_rules.ts`.

### Prebuilt rules

Dedicated suite under `prebuilt_rules/common/import_export/`:

- Non-customized / customized / custom classification matrix
- Overwrite over installed / customized
- Custom ↔ prebuilt conversion, historical base versions
- Mixed batch (non-customized + customized + custom) with and without overwrite
- Outdated rules, missing base version, missing `rule_source` / `immutable`
- Deprecated assets, air-gapped package install edge cases
- Export → delete → reimport mixed custom + prebuilt

3 known `it.skip` holes (upgradeable-after-import, equal-payload overwrite,
overwrite without version).

### Change tracking

`rule_management/.../change_tracking.ts` covers:

- `rule_import` history for a new custom import
- `rule_import` history for a single-rule overwrite
- `metadata.bulk_count` for a small (3-rule) custom import

Not covered on main: prebuilt-import history, multi-chunk `bulk_count`.

### UI (Cypress only)

No FTR functional/UI suite hits `_import`. Cypress covers success/conflict/
overwrite-all toasts, mixed prebuilt+custom, and a couple of export→reimport
round-trips.

### What main does *not* exercise at scale

Largest active pure-rule import in FTR is on the order of ~10 custom rules
(exception-heavy bulk goes higher, ~100). There is no multi-hundred-rule
create/overwrite batch, no pure overwrite across chunk boundaries, and no
success-path test at the 10k import cap.

---

## What the rewrite can break that existing FTR would miss

| Risk from the rewrite | Why main FTR misses it |
|-----------------------|------------------------|
| Outer chunking at bulk-create batch size | No mixed create/overwrite import large enough to span multiple chunks |
| Create vs overwrite persistence split in one request | Prebuilt-mix create+overwrite exists at small scale; custom mixed batch across chunks does not |
| Hand-built KQL `rule_id` filter → real ES | Main builds unescaped `ruleId:(…)` filters; metacharacter `rule_id`s 400 today |
| Change tracking for prebuilt import / multi-chunk `bulk_count` | Only custom create (N=1 / N=3) and overwrite (N=1) |
| Large-payload / scale motivation | 10k success is commented out; only the 10,001 rejection is live |
| Pure overwrite / update path at scale | Overwrite stays per-rule in #275695; #275204 bulk-updates — no overwrite-only multi-chunk lock |

Note on "double batching": when outer chunk size and inner
`bulkCreateRules({ batchSize })` match, a multi-hundred-rule FTR proves outer
multi-batch behaviour. Inner batching only becomes separately observable if
those constants diverge.

---

## Gap matrix (what is missing)

Status is relative to **main today**. Gaps describe the contract to lock, not
where a future PR might put the file.

| Area | Status on main | What's missing |
|------|----------------|----------------|
| Custom rule import (typical) | Covered | — |
| Prebuilt rule import (classification / overwrite) | Covered | 3 skipped cases above |
| Overwrite branch (single-rule contract) | Covered | — |
| Mixed create + overwrite across chunk boundaries | **Gap** | One request with hundreds of rules (some existing, some new), `overwrite=true`; assert success counts and all rules readable via `_find` |
| Pure overwrite across chunk boundaries | **Gap** | Same scale, but every `rule_id` already exists; lock before [#275204](https://github.com/elastic/kibana/issues/275204) |
| Change tracking `bulk_count` on large create | **Gap** | Import spanning multiple chunks; `bulk_count` must equal full import size, not per-chunk length |
| Change tracking `bulk_count` on large overwrite | **Gap** | Same assertion after a multi-chunk overwrite-only import |
| Change tracking for prebuilt import | **Gap** | `rule_import` history when importing a prebuilt rule |
| `enabled` toggle on overwrite | **Gap** | disabled→enabled and enabled→disabled via overwrite import |
| Partial success on overwrite batch | **Gap** | Batch with valid overwrites + one schema-invalid rule; successes keep SO ids, failed rule unchanged |
| Conflict / mixed-outcome (create path) | Covered | Small-scale create/conflict and connector mixes exist |
| Error paths (schema / caps) | Covered | Invalid extension, malformed fields, 10k cap rejection |
| Error paths (transport) | **Gap** | Corrupt NDJSON line, empty file, missing `file` field |
| Identity (`id` vs `rule_id`) | **Gap** | Payload `id` ignored on create; overwrite by `rule_id` keeps SO id; existing SO id + different `rule_id` dual-creates; same payload `id` twice in one NDJSON; overwrite cannot reassign ownership; conflict key is `rule_id`; export round-trip; prebuilt overwrite; cross-space ([#279741](https://github.com/elastic/kibana/issues/279741)) |
| All detection rule types | **Gap** | Successful import round-trip per type: query, threshold, eql, threat_match, new_terms, esql, ML (where license/setup allows) |
| Concurrent imports | **Gap** | Two overlapping `_import` requests — distinct `rule_id`s, and a variant that shares a `rule_id` without overwrite |
| Large payload (~10k rules) | **Gap** | Success at the import size cap (disabled rules); expect to quarantine (slow/flaky on legacy path is useful signal) |
| KQL-metacharacter `rule_id`s | **Gap (rewrite PR)** | Import + `_find` for `rule_id`s containing `"`, `\`, `(`, `)`, `*`, `<`, `>`, `and` / `or` / `not`. Does not pass on main's unescaped filter; belongs with bulk-create escaping |
| Schedule-limit on bulk create | **Gap (rewrite PR)** | Optional: low `maxScheduledPerMinute` once create uses `bulkCreateRules` |
| RBAC on `_import` itself | Partial | Actions / response-actions privilege branching covered; no test that a user lacking rules write privilege gets 403 on `_import` itself |
| UI | Covered enough | Cypress toasts + round-trips; no need for FTR UI |

---

## Assessment

Existing FTR is enough to catch regressions in the externally-visible contract for
typical imports (custom, prebuilt, overwrite, conflict, connectors, exceptions).
It is not enough at the seams the rewrite touches, and a few long-standing holes
should be locked before the pathway moves.

Three jobs (create and update are sequential):

1. **Baseline** — lock today's contract on `main` (gaps above except rewrite-only).
2. **Bulk-create rewrite** ([#275695](https://github.com/elastic/kibana/pull/275695)) — keep baseline green; add create-path-only FTR (KQL escaping, optional schedule-limit). Overwrite stays on the per-rule `importRule` path in that PR.
3. **Bulk-update rewrite** ([#275204](https://github.com/elastic/kibana/issues/275204)) — wire overwrite to `rulesClient.bulkUpdate()`. Lock update-specific gaps *before or with* that work.

### Baseline — behaviors to lock before the rewrite

1. **Mixed create/overwrite across chunks.** Import well above current import
   chunk size (e.g. ≥ 2× chunk size) of disabled custom rules in one request,
   mixing creates and overwrites. Assert response success counts and that rules
   are readable via `_find`.
2. **Prebuilt-import change tracking** + **create `bulk_count` across chunks.**
   Prebuilt `rule_import` history case; large create import where `bulk_count`
   stays the full import size.
3. **Transport corruption.** Corrupt NDJSON line, empty file, missing `file`.
4. **Concurrent imports.** Two overlapping `_import` requests (distinct
   `rule_id`s, and shared `rule_id` without overwrite).
5. **Rule-type matrix.** One successful import round-trip per detection rule type.
6. **Identity (`id` vs `rule_id`).** Contract from
   [#279741](https://github.com/elastic/kibana/issues/279741) — see gap matrix.
7. **Large payload (10k).** Quarantined ESS-only success at the import size cap.
   Disabled rules only. May be slow or flaky on the legacy path — intentional.

Adversarial `rule_id` import + `_find` is **not** a main baseline case. On main,
import looks up existing/prebuilt rules with an unescaped `ruleId:(a or b)` KQL
filter, so metacharacter `rule_id`s 400 before any contract is worth locking.
Escaping lands with the bulk rewrite — put the success-path FTR there.

Tracked elsewhere: [#280553](https://github.com/elastic/kibana/pull/280553) /
[#280531](https://github.com/elastic/kibana/issues/280531).

### Rewrite PR (#275695) — create-path-only FTR

Do not put these in the baseline: they assert bulk-create-path-only behaviour.

1. **Adversarial `rule_id`s (success path).** Import then `_find` rules whose
   `rule_id`s contain KQL metacharacters / reserved tokens. Needs rewrite KQL
   escaping.
2. **Schedule-limit (optional).** Sibling config with low
   `xpack.alerting.rules.maxScheduledPerMinute` (precedent: alerting
   `config_with_schedule_circuit_breaker`). First real HTTP consumer of
   `bulkCreateRules` is `_import`.

Baseline (including quarantined 10k) should stay green unchanged. If a baseline
test needs a rewrite-only assertion, keep the contract assertion in baseline and
add the bulk-specific check here.

### Overwrite / update path — readiness for [#275204](https://github.com/elastic/kibana/issues/275204)

[#275695](https://github.com/elastic/kibana/pull/275695) bulk-optimizes **create**
only. Overwrite still calls per-rule `importRule` → `rulesClient.update` +
`toggleRuleEnabledOnUpdate`. [#275204](https://github.com/elastic/kibana/issues/275204)
routes existing rules through `rulesClient.bulkUpdate()`.

Single-rule overwrite on main is already in good shape (overwrite by `rule_id`,
nullable clearing, revision bump, actions/legacy migrations, prebuilt overwrite
matrix). Still missing before/with bulk-update:

1. **Pure overwrite across chunk boundaries** (hundreds of existing rules).
2. **`bulk_count` on multi-chunk overwrite.**
3. **`enabled` toggle on overwrite** (disabled→enabled and enabled→disabled).
4. **Partial success on overwrite batch** (valid overwrites + one schema-invalid;
   successes keep SO ids, failed rule unchanged).

Optional / later: overwrite + actions or exceptions at multi-chunk scale; richer
overwrite `old_values` beyond the single-rule history case.

Keep these green under `bulkUpdate` — do not treat them as post-hoc coverage of
the new path only.
