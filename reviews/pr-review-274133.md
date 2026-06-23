# PR Review: #274133 — [Security Solution] Accept semver range-sets in related integrations version field

**PR:** [elastic/kibana#274133](https://github.com/elastic/kibana/pull/274133)

**Scale:** Small PR (5 files, +13/-7), but it loosens an input validation gate, so the risk section gets the fuller treatment.

**Ownership (team: `@elastic/security-detection-rule-management`):** All five files live under `security_solution/public/detection_engine/.../related_integrations/` — squarely in the Detection Rule Management area. In scope.

---

### Context / Motivation

Fixes [#274097](https://github.com/elastic/kibana/issues/274097). Related to detection-rules [#6208](https://github.com/elastic/detection-rules/issues/6208), [#5601](https://github.com/elastic/detection-rules/issues/5601), and kibana [#250550](https://github.com/elastic/kibana/issues/250550).

The rule create/edit UI validated `related_integrations[].version` with a hand-rolled regex:

```
/^(\~|\^)?\d+\.\d+\.\d+$/
```

That only accepts a single plain/tilde/caret version. Valid semver range-sets like `^8.2.0 || ^9.0.0` are rejected, so anyone editing a rule whose related integration uses such a range is blocked from saving. This becomes a live problem once detection-rules#6208 ships OR-style ranges to fix the major-version boundary issue — customers customizing those prebuilt rules in the UI would be stuck.

### Validating the issue — does this PR address it?

The concern is valid and the PR addresses it correctly. The regex was the *only* gate rejecting range-sets:

- **Where it manifested:** `validate_related_integration.ts` ran `SEMVER_PATTERN.test(value.version)`. The pattern requires a full `x.y.z` with at most one leading operator, so `^8.2.0 || ^9.0.0`, `>=8.2.0`, `>1.0.0 <2.0.0` all failed.
- **How the PR fixes it:** swaps the regex for `semver.validRange(value.version)` (`semver` is already a dep and already used in this folder). Any valid range-set now passes; genuine garbage like `^1.2.` still returns `null` and is rejected. Empty-package short-circuit and empty-version (`ERR_FIELD_MISSING`) handling are untouched above the changed line.
- **Residual caveat:** `validRange` is *looser* than "a clean range" — it also accepts `*` and `1.x` (wildcards) and bare partials like `100` (treated as `>=100.0.0 <101.0.0`). That's acceptable for a "is this a usable constraint" check, but see Risks for the downstream consequence.

### Summary

Replaces the regex-based version validator in the related-integrations form with `semver.validRange()`, so valid semver range-sets are accepted instead of just single versions. Help-popover text and the validation error message are reworded to describe ranges, and the test cases are updated to cover range-sets/comparators (and to drop a now-invalid assumption). No server-side or schema change — the API already accepted these strings.

### Files touched

- **Validator** — `validate_related_integration.ts`: the actual behavior change (regex → `semver.validRange`).
- **User-facing copy** — `related_integrations_help_info.tsx` (help popover) and `translations.ts` (error message): reworded to reflect range support. i18n IDs unchanged, so no translation breakage. Wording was pulled from the cleaner closed PR #274138.
- **Tests** — `validate_related_integration.test.ts` (unit): adds range-set/comparator valid cases, moves `' ~ 1.2.3'` from invalid → valid (semver legitimately trims it), adds genuinely-invalid cases (`invalid`, `1.2.3 || invalid`). `related_integrations.test.tsx` (component): changes the "invalid version" input from `'100'` to `'^1.2.'` because `'100'` is now a *valid* partial range under `validRange` and no longer triggers the error.

### Flow trace

Edit a rule's related-integration version in the UI:

1. User types a version in the related-integrations field row (`related_integration_field_row.tsx`).
2. The form runs `validateRelatedIntegration` — the single validator wired to this field.
3. Empty package → skip. Empty version → `ERR_FIELD_MISSING`. Otherwise → `semver.validRange(version)`.
4. Valid range → no error, rule saves. Invalid → `ERR_FIELD_FORMAT`, save blocked with the reworded message.
5. On save, the version string is persisted as-is (server schema types it as `NonEmptyString`, so it never re-validates the shape).
6. Later, when the rule is displayed, `calculateIntegrationDetails` (`integration_details.ts`) interprets the string: `semver.satisfies()` for the mismatch warning, and `getMinimumConcreteVersionMatchingSemver()` → `semver.coerce()` to build the Fleet install URL.

### Assumptions

- The server never enforced the regex — confirmed in the prior session: Fleet ingest schema, `PrebuiltRuleAsset.safeParse`, and the alerting params schema all type `version` as `NonEmptyString`. So the UI was the only gate and loosening it can't desync from a stricter backend.
- `validate_related_integration.ts` is the only validator for this field (no second regex path). Confirmed.
- Downstream consumers already tolerate ranges for the *satisfies* check (`semver.satisfies` handles range-sets natively). True.

### Risks

1. **Install-link target is off for strict comparator ranges — LOW, cosmetic only.** *(Downgraded — see Review activities #8.)* `integration_details.ts` builds the "go install this integration" Fleet URL via `getMinimumConcreteVersionMatchingSemver` = `semver.valid(semver.coerce(version))`. `coerce` grabs the first `x.y.z` token, ignoring the operator, so the *boundary-excluded* comparators produce a non-satisfying target:
   - `>8.0.0` → `8.0.0` (excluded), `<2.0.0` → `2.0.0` (excluded), `>1.0.0 <2.0.0` → `1.0.0` (excluded).
   The coerced value has exactly **one** consumer — it's interpolated into the link URL (`app/integrations/detail/{package}-{coerced}/overview`). It is never shown as text; the mismatch tooltip renders the *raw* `requiredVersion`, and the mismatch *detection* uses `semver.satisfies` on the raw range — both correct. So the only impact is a link that points one patch below what the rule needs (and a mismatch warning that following the link won't clear). **No effect on rule execution, query, alerts, persistence, or mismatch detection** — `related_integrations` is advisory metadata.
   Crucially, the shapes that *aren't* boundary-excluded all behave: `>=X`, `^X`, `~X`, plain `X`, `X.x` coerce to a satisfying floor; `*` → coerce null → URL drops the version segment (lands on package overview, correct for "any version"); `^8.2.0 || ^9.0.0` → `8.2.0`, which *satisfies* the range (valid, just biased to the lowest branch). Projected real inputs are `>=8.2.0` and `^8.2.0 || ^9.0.0` (detection-rules#6208) — both fine. The broken case requires a hand-typed strict `>`/`<`, which is rare. Acceptable for this PR; optional future polish is to swap `coerce` for `semver.minVersion(range)` in the link builder.
2. **`validRange` accepts wildcards/partials (`*`, `1.x`, `100`).** Looser than likely intended. Low severity — they're valid constraints, and `*` degrades gracefully (see above) — but it does widen what flows into the consumer.

### Open questions

- Is the misleading install URL for comparator/OR ranges acceptable for the first release of this fix, or should it be addressed in the same PR? (The ranges detection-rules#6208 generates are OR-of-carets like `^8.2.0 || ^9.0.0`, which hit the "always first branch" case — arguably the most common real input.)
- Do you want to disallow bare `*`/wildcards, or is "any version" a legitimate constraint to store?

### Notes for your codebase map

- Related-integration version validation is **client-only**. The server (Fleet ingest schema, `PrebuiltRuleAsset`, alerting params) only enforces `NonEmptyString` — the UI form validator is the single shape gate.
- `validate_related_integration.ts` is the lone validator, wired once via `related_integration_field_row.tsx`. No duplicate validation path.
- The version string is *interpreted* in exactly one production path: `integration_details.ts` → `calculateIntegrationDetails`. `semver.satisfies` drives the mismatch warning (range-safe); `semver.coerce` builds the Fleet install URL (not range-safe).
- `semver.coerce` ignores operators — fine for plain/caret/tilde, lossy for comparator and OR ranges. Any feature that lets users enter raw ranges inherits this.

### Review activities

These were carried out across two earlier sessions on this PR ([Put together PR for #274097](13442f30-77f8-4fff-bf91-8839d92c4682) and [Check PR 274133 for gaps](ddc33677-c1bd-4f6f-9b7a-800d252a924a)) plus this one:

1. **End-to-end completeness check.** Verified the validator is the only gate, consumers (`integration_details.ts`) already use `semver.satisfies`/`coerce`, and the server schema is `NonEmptyString`-only. Ran the unit tests — 15/15 pass — plus lint and a scoped type check (exit 0). Conclusion: fix is correct and well-scoped.
2. **Copy refinement.** Swapped the help-popover and error-message wording for the cleaner phrasing from the closed PR #274138; kept i18n IDs unchanged so no translation breakage. Switched the validator guard to `if (!semver.validRange(...))` for readability (behavior identical).
3. **CI failure root-caused and fixed.** The `related_integrations.test.tsx` "invalid version" case used `'100'`, which the old regex rejected but `semver.validRange('100')` accepts (`>=100.0.0 <101.0.0`), so no error rendered and the assertion failed. Reproduced the exact Buildkite failure by temporarily restoring `'100'`, then fixed it to `'^1.2.'` (malformed → `validRange` returns null), restored a clean tree, and confirmed green.
4. **Bootstrap / Fleet path checked.** Traced `related_integrations.version` through the prebuilt-rules load (read) and install/create (write) flows. Every checkpoint types `version` as `NonEmptyString` with `unknowns: 'allow'` — nothing on that path rejects a semver range. The UI was always the only enforcement point.
5. **Downstream blast-radius mapped.** Identified `integration_details.ts` (`calculateIntegrationDetails`) as the one place that *interprets* the version. Verified via semver behavior checks that `coerce` mis-targets the install URL for `>`/`<`/compound/OR ranges (e.g. `>1.0.0 <2.0.0` → `1.0.0`, `^8.2.0 || ^9.0.0` → `8.2.0`). Listed the screens that surface this link (rule details definition section, rules management table popover, add/upgrade prebuilt-rules tables, create/edit review step) for targeted manual testing.
6. **Confirmed the risk still stands.** Re-read `integration_details.ts` on the current branch: `getMinimumConcreteVersionMatchingSemver` is still `semver.valid(semver.coerce(semverString))`, so the install-link issue in Risks #1 is live.
7. **Manual-test prep — empirical semver verification + targeted screen list.** To prep manual testing of the loosened validation, ran the actual installed `semver` against the uncommon ranges and confirmed the lossy `coerce` outputs that feed the install URL: `>1.0.0 <2.0.0`→`1.0.0` (violates `>1.0.0`), `<2.0.0`→`2.0.0` and `>9.0.0`→`9.0.0` (off-by-one, don't satisfy the range), `^8.2.0 || ^9.0.0`→`8.2.0` (always first branch), `*`→`null` (URL drops version), `1.x`→`1.0.0`; `satisfies` confirmed range-safe (`9.5.0` ✓ / `8.1.0` ✗ against `^8.2.0 || ^9.0.0`). Re-mapped downstream consumers (one interpreting path: `integration_details.ts` → `calculateIntegrationDetails`; everything else renders raw text, stores, JSON-diffs, or uses `package` only). Produced a ranked manual-test matrix keyed to the mismatch/uninstalled branch (which uses `coerce`): test `>1.0.0 <2.0.0` (broken link), `^8.2.0 || ^9.0.0` with installed `8.1.0` then `9.5.0` (link should switch + warning clear), `*` (no version segment), `>=8.2.0` (sanity); screens to click — rule details Definition section, rules-management table Related-integrations popover, Add/Upgrade prebuilt-rules tables, create/edit review step (all route through `integration_link.tsx`).
8. **Pinned the exact blast radius → downgraded Risk #1 to LOW/cosmetic.** Traced the coerced `targetVersion` and confirmed it has exactly one consumer: it's interpolated into the install-link URL (`buildTargetUrl` → `integration_link.tsx`), never rendered as text. The mismatch tooltip uses the raw `requiredVersion` and the mismatch flag uses `semver.satisfies` on the raw range — both correct. So a bad `coerce` only mis-points a hyperlink (off by one patch for boundary-excluded comparators like `>8.0.0`→`8.0.0`, `<2.0.0`→`2.0.0`); no effect on rule execution, query, alerts, persistence, or mismatch detection, since `related_integrations` is advisory. Verified `*` degrades gracefully (coerce null → URL drops version segment → package overview, which is correct for "any version"). Confirmed the projected real inputs `>=8.2.0` and `^8.2.0 || ^9.0.0` both coerce to *satisfying* versions, so the only affected case is a hand-typed strict `>`/`<` comparator (rare). Optional future polish noted: use `semver.minVersion(range)` in the link builder instead of `coerce`.
