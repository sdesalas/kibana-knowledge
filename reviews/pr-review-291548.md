# PR Review: #291548 — [Security Solution] Add overwrite FTR coverage for `rules/_import`

**PR:** [elastic/kibana#291548](https://github.com/elastic/kibana/pull/291548) by @sdesalas
**Created Date: Friday, Sep 18, 2026**

**Scale:** Small — FTR-only, 4 files, +413/−7. No product code. This is the overwrite-side contract lock for the later `bulkUpdate` rewrite ([#275204](https://github.com/elastic/kibana/issues/275204) / sibling [#291560](https://github.com/elastic/kibana/pull/291560)).

**PR status:** Open, `REVIEW_REQUIRED`. Libra green. Flaky-test runner 25/25 on all four import/export configs (ESS + serverless × trial + basic). Latest push is today (18 Sep 17:53); the Sept 16 `kibana-pull-request` build is stale, and the current check rollup does not show a new main CI run yet.

---

### Context / Motivation

[#275204](https://github.com/elastic/kibana/issues/275204) asks to land extra overwrite FTR **on `main` before** switching `rules/_import` from per-rule `rulesClient.update()` to `bulkUpdate()`:

> Review FTR coverage. Add extra overwrite cases that may have been missed in the create-path FTR audit ([#280531](https://github.com/elastic/kibana/issues/280531)). Land those in a **separate PR on `main` before** the optimization PR so the same suite can run before and after the write-path change.

[#280531](https://github.com/elastic/kibana/issues/280531) (closed) was the create-path audit. This PR is the overwrite sibling called out as still open in the [#291560](https://github.com/elastic/kibana/pull/291560) review.

The missing-`file` 500 is called out as known current behavior, not a fix — see [this thread on #280553](https://github.com/elastic/kibana/pull/280553#discussion_r3659153286).

### Validating the issue — does this PR address it?

The concern is valid. The PR locks the overwrite outcomes the rewrite is most likely to break.

- **Where the problem manifests** — overwrite today is `overwriteRules()`: `pMap` of `rulesClient.update()` plus `toggleRuleEnabledOnUpdate()`, concurrency 50 (`RULE_IMPORT_BULK_UPDATE_CONCURRENCY`). Outer chunking is `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200). A later `bulkUpdate` + bulk enable/disable can drop `created_at`, skip a revision bump, lose `interval`, mishandle a chunk edge, or fail a whole chunk when one rule is bad.
- **Why the old coverage was thin** — create-path FTR already had mixed-batch and overwrite-only chunk tests, plus basic overwrite / enable-disable singles. It did not lock interval, partial-failure isolation on overwrite (trial), chunk-edge revision samples, enable/disable at a full 200-rule chunk, or import-suite change history.
- **How the PR fixes it** — new tests and extra asserts on those seams. Same import/export shard that #291560 will re-run.
- **Residual caveat** — the change-history test is nearly a copy of `change_tracking.ts`. The 200-rule enable/disable test is one full chunk, not a multi-chunk span (the 568-rule test still does that).

### Summary

Adds overwrite FTR on `rules/_import` so current `main` behavior is pinned before the write-path change. Five new tests (interval, schema-invalid partial overwrite, missing-connector partial overwrite, enable/disable at batch size, ESS change history) plus extra revision / `created_at` / chunk-edge asserts on existing tests. One comment on the missing-`file` 500. Matches the stated intent; nothing in the diff is product behavior.

### Files touched

- **Trial overwrite suite** (`trial_license_complete_tier/import_rules_with_overwrite.ts`) — single-rule and small-batch overwrite contract. New: interval, two partial-success cases, ESS history. Extra: revision on enable/disable; `created_at` preserved / `updated_at` changed on the basic overwrite.
- **Trial overwrite chunk suite** (`import_rules_overwrite_at_batch_boundary.ts`) — 568-rule existing-only overwrite. Adds chunk-edge sample indexes (199/200/399/400) and a 200-rule enable/disable flip (100 each way).
- **Trial mixed create+overwrite chunk** (`import_rules_at_batch_boundary.ts`) — 501-rule mix (251 existing). Now asserts overwrite keeps SO id and bumps revision; a create gets revision 0.
- **Basic transport errors** (`basic_license_essentials_tier/import_rules_transport_errors.ts`) — comment only. Missing `file` still expects 500.

Basic-license overwrite already has the schema-invalid partial case (from the create-path audit) without revision asserts. Connector / interval / history stay on trial, which is where actions and change history live.

### Flow trace

1. Test builds existing rules (`createRule` or `importRulesWithSuccess` with `overwrite: false`).
2. Optional `findRules` snapshot of `{ id, revision }` by `rule_id`.
3. `importRules` / `importRulesWithSuccess` posts NDJSON to `rules/_import?overwrite=true`.
4. Route parses / schema-validates each line (bad `risk_score` dies here — 400, no `rule_id` on the error).
5. `importRules()` chunks at 200, finds installed rules, `validateRulesToImport`. Missing connectors fail in `validate_rule_actions` (404, `rule_id` present) and never enter `toOverwrite`.
6. `overwriteRules()` updates survivors one-by-one (`rulesClient.update` + `toggleRuleEnabledOnUpdate`).
7. Tests re-read via `readRule` / `findRules` and check identity, revision, field values, and (ESS) `rule_import` history.

### Assumptions

- `findRules` with `per_page: 200` or `568` returns the full set after `deleteAllRules` — no hidden max; the 568 test already depends on this.
- Schema-invalid NDJSON lines are rejected before DRC write, so siblings in the same request still overwrite. Connector failures are per-rule validation, same isolation.
- Change history is ESS-only until `ruleChangesHistoryEnabled` is on in serverless — the `@ess @skipInServerless` nest matches that.
- `BATCH_SIZE = 200` is meant to match `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`, not the stale “chunking on main (50)” comment still sitting on the 568-rule test.
- 100 rules imported as `enabled: true` in setup is acceptable FTR cost. Flaky runner 25/25 suggests it held up.

### Risks

1. (FIXED) ~~**Change-history test duplicates `change_tracking.ts` almost line-for-line.** If the two suites drift, one will lie. Worth keeping only if the import/export shard is the one #291560 will treat as the contract.~~ Full clone removed. Import suite keeps a smoke that only locks overwrite diffs (revision, name, `old_values`, `bulk_count`); the snapshot stays in `change_tracking.ts`.
2. (NIT) ~~**Enable/disable batch only spot-checks 6 of 200 rules.** Consistent with the other chunk tests, but a `bulkUpdate` bug that dropped a non-sampled index would slip through. Chunk-edge samples on the 568-rule test are the better net for that.~~
3. (FIXED) ~~**`BATCH_SIZE` is a magic 200** named `RULE_IMPORT_BATCH_SIZE` in a comment. The real constant is `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`. If that value moves, this test silently stops being “one full batch.”~~ Now `BATCH_SIZE = RULE_IMPORT_BULK_CREATE_BATCH_SIZE`; chunk-edge samples are derived from it. FTR already imports server constants from that tree.
4. (NIT) ~~**Schema-invalid error is locked without `rule_id`.** The test asserts `toBeUndefined()`. A later “fix” that adds `rule_id` will fail this. That’s useful as a contract pin, not a bug — just don’t treat it as accidental.~~

### Open questions

- (FIXED) ~~Is the import-suite history test intentional duplication so #291560’s import/export FTR shard owns that contract, or can it stay only in `change_tracking.ts`?~~ It stays in `change_tracking.ts`. Import suite only smokes overwrite-specific diffs.
- (FIXED) ~~Should `BATCH_SIZE` import `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` instead of hard-coding 200?~~ Yes — nothing blocked it; the const is now imported.
- (ANSWERED) ~~Anything still missing vs the coverage report before #291560 relies on this — exceptions overwrite, prebuilt overwrite, `updated_by` / `created_by`?~~ No required gaps left. Prebuilt overwrite is already Covered. Exceptions/actions at chunk scale are Optional/later. `created_by` / `updated_by` are not in the report; this PR locks `created_at` / `updated_at` only.

### Notes for your codebase map

- Overwrite on `main` is still `overwriteRules()` → per-rule `rulesClient.update()` + `toggleRuleEnabledOnUpdate()`, `pMap` concurrency 50.
- Import chunk size is `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (200), shared by outer find/validate and inner `bulkCreateRules`.
- NDJSON schema failures omit `rule_id` on the error; missing-connector failures include it (`validate_rule_actions`).
- Rule change history for import overwrite is already covered in `change_tracking.ts`; this PR adds a second copy under import/export, ESS-only.
- Basic-license overwrite already has the schema-invalid partial case; trial is the richer overwrite suite (actions, history, interval, revision).

### Follow-up Review Activities

1. Checked the risks and open questions against current code.

- **Risk 3:** FTR can import `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`. Wired `BATCH_SIZE` and the chunk-edge samples to it. No other import test used a local `BATCH_SIZE`. 501/568/`change_tracking` 568 stay hardcoded on purpose — they sit *above* any chunk. Only import the const when the test *is* one batch.
- **Risk 1:** Full clone of `change_tracking.ts` is gone. Import-suite smoke keeps the original name and locks overwrite diffs: revision bump, name change, `old_values`, `bulk_count: 1` vs `rule_create` with no `bulk_count`.
- **Risks 2 and 4:** Nits. Spot-checks match the other chunk tests; missing `rule_id` on schema errors is a contract pin.
- **Boundary `bulk_count`:** Not in the overwrite-at-boundary suite. `change_tracking.ts` already covers create and overwrite at 568 rules (`bulk_count === 568`, samples `[0, 50, 300, 500, last]`). Those samples still skip the 200-chunk edges.
- **Open question 3:** Reviewed [#291560](https://github.com/elastic/kibana/pull/291560) and Alerting `bulkUpdateRules` for leftover coverage gaps. Report must-locks and prebuilt overwrite are already done. TM enable/disable failures stay Jest/manual. Added the three seams the rewrite can break: `created_by`/`updated_by`, interval change while enabled, and exceptions_list attach on overwrite.

---
