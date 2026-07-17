# PR Review: #278125 — [Detection Engineering] Fix input schema in prebuilt rule upgrade endpoint

**PR:** [elastic/kibana#278125](https://github.com/elastic/kibana/pull/278125) by @denar50
**Issue:** [elastic/kibana#232614](https://github.com/elastic/kibana/issues/232614)

**Scale:** Small PR.

---

### Context / Motivation

Community bug filed by Mick ([#232614](https://github.com/elastic/kibana/issues/232614), Aug 2025, Kibana 9.0.4): when a customized prebuilt rule and an Elastic update both change `required_fields`, resolving that conflict in the Rule Update UI and saving fails with a 400.

> Changing the "Final Update" for Required Fields in the UI does not allow setting the "ecs" fields for any Required Field, which is required in the backend.

Error from the issue:

```
rules.0.fields.required_fields.resolved_value.5.ecs: Required
```

Expected (from the issue): either the UI can set `ecs`, or the backend derives it so the update succeeds.

The PR takes the second path: treat upgrade `resolved_value` as input (`RequiredFieldInput`: name + type only), keep `ecs` as a server-computed response field.

### Validating the issue — does this PR address it?

**The concern is technically valid. The PR addresses it correctly.**

- **Where the problem manifests** — `POST /internal/detection_engine/prebuilt_rules/upgrade/_perform` validates each field's `resolved_value` via `RuleFieldsToUpgrade` → `DiffableUpgradableFields`, which previously reused `DiffableAllFields.required_fields` = `RequiredFieldArray` (`ecs: z.boolean()` mandatory). The flyout serializer (`requiredFieldsSerializer`) already emits `RequiredFieldInput[]` (no `ecs`), matching create/patch.
- **Why the old approach was a problem** — response schema was used to validate input. Users could not set `ecs` in the UI, and correctly shouldn't need to — `addEcsToRequiredFields` already computes it on the server (patch, create defaults, convert-to-alerting-rule, normalize for review).
- **How the PR fixes it** — overrides only the upgrade-input schema:

```ts
DiffableAllFields.omit(DiffableFieldsToOmit).extend({
  required_fields: z.array(RequiredFieldInput),
});
```

  Leaves `DiffableAllFields` / `_review` response shape unchanged (`ecs` still returned).
- **Residual caveat** — coverage is schema-unit only. No integration/API test stages a real triad + `_perform` with RESOLVED `required_fields`. The PR body has a solid repro script, but it isn't checked in.

### Summary

Fixes the validation mismatch that blocked resolving `required_fields` conflicts during prebuilt rule upgrade. The upgrade endpoint's `resolved_value` for that field now accepts the same input shape as create/patch (`name` + `type`); `ecs` remains response-only and is recomputed server-side. Intent in the PR description matches the diff.

### Files touched

- **Upgrade request schema** (`perform_rule_upgrade_route.ts`) — where `DiffableUpgradableFields` / `RuleFieldsToUpgrade` define valid `resolved_value` shapes for `_perform`. The only production change: override `required_fields` to `RequiredFieldInput`.
- **Schema unit tests** (`perform_rule_upgrade_route.test.ts`) — regression for accept-without-`ecs`, strip-extra-`ecs`, and still-require-`name`/`type`.

### Flow trace

1. User opens Rule Updates, preview rule with `required_fields` conflict.
2. `_review` returns diff with `merged_version` items that include `ecs` (`DiffableAllFields` / `RequiredField`).
3. Flyout final edit uses `RequiredFieldsEdit` + `requiredFieldsSerializer` → drops to `{ name, type }[]`.
4. Save → `_perform` with `pick_version: 'RESOLVED'` and that array as `resolved_value`.
5. Zod parses via `RuleFieldsToUpgrade` → now accepts without `ecs` (and strips `ecs` if present).
6. `getValueForField` takes `resolved_value`, maps through `mapDiffableRuleFieldValueToRuleSchemaFormat`.
7. Upgraded asset is persisted; `convertRuleResponseToAlertingRule` / related paths call `addEcsToRequiredFields` so stored/response rules still have correct `ecs`.

### Assumptions

- `addEcsToRequiredFields` always runs before `required_fields` are persisted or returned as `RequiredField[]` — true on the convert-to-alerting-rule and normalize-response paths used after upgrade.
- `RequiredFieldInput` is non-strict (Zod object default), so leftover `ecs` from older workarounds is stripped rather than rejected — the new test locks that in.
- No other Diffable field has a response-only computed property that would need the same override; `required_fields`/`ecs` appears to be the special case.
- `_review` and UI types can keep using `DiffableAllFields` (with `ecs`); only upgrade *input* needed the split.

### Risks

- **Schema-only regression net** — a future change that breaks the post-parse persistence path (e.g. stops calling `addEcsToRequiredFields` on upgrade writes) would not be caught by these tests; you'd get rules without `ecs` or inconsistent response data rather than a 400. **Mitigation — see activities #4–#5** (FTR API integration test ask). *(Strengthened — see activity #6)* Existing FTR `required_fields.ts` RESOLVED cases all send `ecs: false`, so that suite also wouldn't have caught #232614 on `main` (false confidence). Jest RTL flyout tests assert the UI *sends* no `ecs` against a mocked `_perform` — they never exercise server acceptance or persistence.
- **Asymmetric types FE vs request** — FE still types resolved conflicts as `DiffableAllFields` (includes `ecs`) while the wire format for this field is input-shaped. Pre-existing; this PR aligns the server with what the FE already sends, but the type story stays a bit muddled. *(Minor — lowest severity)* Confirmed under api-contract pass (activity #3): `FieldsUpgradeState.resolvedValue` and `constructRuleFieldsToUpgrade` can still put `ecs` on the wire; Zod strips it. Server contract is now correct; client types still describe the review/response shape. **Reconfirmed — see activity #7** (`SetRuleFieldResolvedValueFn` / `FieldsUpgradeState` still `DiffableAllFields`; `constructRuleFieldsToUpgrade` builds via `Record<string, unknown>` so TS won't catch the mismatch). Out of scope to fix in this PR.

### Open questions

- ~~Worth promoting the PR's repro script (or a slimmed version) into an API/integration test so the full triad → review → perform path is covered, not just Zod parse?~~ **Answered — see activities #4–#5.** Yes — need an FTR API integration test (`_perform` without `ecs` → GET asserts computed `ecs`); ask drafted for the author. Existing `required_fields.ts` RESOLVED cases all send `ecs: false`, so they wouldn't have caught this.
- ~~Any other callers of `_perform` (non-UI scripts, older clients) that depended on `ecs` being *required* for validation? Unlikely to be a problem since extras are stripped and missing `ecs` is now the happy path — but worth a quick check of known workarounds.~~ **Answered — see activity #3.**

### Notes for your codebase map

- Prebuilt upgrade has a deliberate split: `DiffableAllFields` = review/diff *response* shape; `DiffableUpgradableFields` = `_perform` *input* shape for `resolved_value`.
- `RequiredField` (with `ecs`) vs `RequiredFieldInput` (without) is an established create/patch pattern; upgrade was the odd one out until this PR.
- `ecs` is never user-authored — always derived via `addEcsToRequiredFields` from the ECS field map (`name` + `type` match).
- UI already treated upgrade editing of required fields as input-shaped (`requiredFieldsSerializer`); the bug was purely server validation.

### Review activities

1. **Compared independent fix to this PR.** Reproduced #232614 on fresh `main` and landed a fix documented in `.knowledge/reports/prebuilt-rule-upgrade-required-fields-ecs.md`. Same core change as the PR (override `DiffableUpgradableFields.required_fields` → `RequiredFieldInput`). Independent fix also called `addEcsToRequiredFields()` in `get_value_for_field` on RESOLVED `required_fields`; the PR does not.

2. **Checked whether early `addEcsToRequiredFields` in `get_value_for_field` is needed.** Intermediate upgrade asset is `PrebuiltRuleAsset` / create-shaped (`required_fields: RequiredFieldInput[]`, no `ecs`). Persistence already stamps `ecs` via `applyRuleDefaults` / `convertRuleResponseToAlertingRule`. Dry-run only returns `id` / `rule_id` / `version`, not the field list. Conclusion: early compute is redundant; schema override alone is the right fix. Drafted PR comment along those lines — not posted; tone still wrong.

3. **Focused review: api-contract.** Pass over the `_perform` request/response surface and persistence. Findings: request schema is a deliberate **widening** (ecs optional/stripped) on internal `apiVersion: '1'` — non-breaking for callers that sent ecs; fixes callers that omitted it. Response body and persisted SO shape unchanged. Client-supplied `ecs` was never authoritative (`addEcsToRequiredFields` overwrites on persist) so strip-on-parse isn't a semantic break. Intentional `_review` (RequiredField) vs `_perform` resolved_value (RequiredFieldInput) split matches create/patch. Downgraded Risk #2 severity; answered Open question #2 (requiring ecs was the bug; strip keeps old workarounds working). No blockers.

4. **Need for a persistence-path regression test.** Worked out whether schema unit tests are enough for Risk #1. They aren't: they only prove Zod accepts `required_fields` without `ecs`. They wouldn't catch a future break where persistence stops calling `addEcsToRequiredFields` / stops computing `ecs`. Conclusion: yes, need a test that `_perform`s without `ecs` and asserts the GET’d rule has `ecs` computed.

5. **Where to put it / ask the author.** Home is existing FTR API integration (`security_solution_api_integration/.../diffable_rule_fields/common_fields/required_fields.ts` via `testFieldUpgradesToResolvedValue`) — current RESOLVED cases all send `ecs: false`, so they never would have caught #232614. Ask drafted for the PR author:

> I think we should add an FTR/integration test that calls prebuilt_rules/upgrade/_perform using required_fields values without ecs, then GETs the rule again and asserts that ecs was computed. The schema unit tests only cover parse, they wouldn’t catch a future break on the persistence path where we stop computing these values.

6. **Focused review: test-coverage.** PR adds three solid schema cases (accept without `ecs`, strip `ecs`, reject missing `type`) — right regression shape for the validation bug, but they stop at `safeParse`. Confirmed Risk #1 / ask #5: no new FTR/API coverage in the PR. Existing FTR RESOLVED cases always include `ecs` (wouldn't fail pre-fix). Jest RTL `__integration_tests__/.../required_fields.test.ts` already expects a no-`ecs` request body but mocks fetch — covers FE wire shape only. Nits only: no empty-array case; no missing-`name` counterpart to missing-`type`. Strengthened Risk #1 with the false-confidence note.

7. **Focused review: type-hygiene.** PR correctly uses canonical `RequiredFieldInput` on `DiffableUpgradableFields` — good. Blast radius small (`DiffableUpgradableFields` only feeds `RuleFieldsToUpgrade`). FE still types accepted resolved values as `DiffableAllFields` (`fields_upgrade_state.ts`, `set_rule_field_resolved_value.ts`); `constructRuleFieldsToUpgrade` accumulates into `Record<string, unknown>` then returns as `RuleFieldsToUpgrade`, so the new input/response split isn't enforced at compile time. Reconfirmed Risk #2; not a ask for this PR.

8. **Focused review: clean-code.** Schema change itself is minimal and readable. Nit: the new JSDoc on `DiffableUpgradableFields` (~8 lines) earns the *why* (input vs response + #232614) but could be ~2 lines + issue link under the team's minimise-comments habit. Test comments linking #232614 are fine. No naming/structure issues in the diff.

9. **Posted approval review** ([review](https://github.com/elastic/kibana/pull/278125#pullrequestreview-4724137273) by @sdesalas, APPROVED, conditional). Body: reproduced #232614 on fresh `main`; same root cause (route-level Zod requiring `ecs`); independent fix matched the PR’s schema override; noted early `addEcsToRequiredFields` in `get_value_for_field` is redundant with persistence. Ask: FTR/integration test `_perform` without `ecs` → GET asserts computed `ecs` (schema tests only cover parse / persistence-path gap). Nit: shorten comment above `DiffableUpgradableFields`.