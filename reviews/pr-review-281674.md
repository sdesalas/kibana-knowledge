# PR Review: #281674 — [Jest] Replace Babel transformer with SWC

**PR:** [elastic/kibana#281674](https://github.com/elastic/kibana/pull/281674) by @tylersmalley
**Built on:** [elastic/kibana#269972](https://github.com/elastic/kibana/pull/269972) (SWC with Babel fallback)

**Scale:** Small PR for `@elastic/security-detection-engineering`. The overall change is a repo-wide Jest transform swap; this team's blast radius is three Emotion snapshot hashes.

**Ownership (team: `@elastic/security-detection-engineering`)**
- **Your team's files (2):** `x-pack/solutions/security/packages/kbn-securitysolution-exception-list-components/src/generate_linked_rules_menu_item/__snapshots__/generate_linked_rules_menu_item.test.tsx.snap`, `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_exceptions/components/value_with_space_warning/__tests__/__snapshots__/value_with_space_warning.test.tsx.snap` — *focus review effort here*
- **The third snap you flagged:** `x-pack/solutions/security/plugins/security_solution/public/common/components/cell_actions/__snapshots__/cell_actions_renderer.test.tsx.snap` (`@elastic/security-solution` — no more-specific CODEOWNERS rule under `public/common/components/cell_actions`)
- **Other teams' files:** the other ~100 files are the SWC transformer (`@elastic/kibana-operations`, `@elastic/appex-qa`), plus Emotion snapshot churn for threat-hunting, entity-analytics, kibana-security, sharedux, visualizations, management, ML, APM, etc.
- **Unowned:** `package.json`, `pnpm-lock.yaml`, `renovate.json` (`@swc/jest` pin)

---

### Context / Motivation

[#269972](https://github.com/elastic/kibana/pull/269972) added `@swc/jest` but still fell back to `babel-jest` for `jest.mock()`, `lazyObject()`, and string-constant enums. This PR deletes that fallback and compensates with source rewrites before SWC (JSX whitespace collapse, enum inlining, `jest.mock()` hoisting, `lazyObject()` expansion) plus CommonJS export-helper patches so Sinon/`jest.spyOn` still work.

The only reason this team is on the review is Emotion. `@swc/plugin-emotion` emits different generated class names than Babel's emotion plugin, so Jest snapshots that serialize `class=` had to be refreshed. No detection-engine product code moves.

CI claim in the PR body: Jest 5.8% faster, Jest Integration 26.9% faster, combined 11.2% vs two `main` `kibana-on-merge` builds from 2026-09-11. Transform cache means dropping Babel did not change those totals much versus the fallback version.

---

### Summary

DEX-owned (and the adjacent cell-actions) snapshots change **only Emotion generated class hashes**. Markup, copy, `data-test-subj`, and structure are untouched. No `.tsx` / `.ts` under those three components is in the diff.

Two patterns:

| File | What changed |
|---|---|
| `generate_linked_rules_menu_item.test.tsx.snap` | `ee8mt0m0` → `e1vodehr0`. Semantic class `emotion-…-LinkedRulesMenuItem` stays. |
| `value_with_space_warning.test.tsx.snap` | `ejh5q6j0` → `e1uepjbj0`. Content hash `css-mwb0ig-Container` stays. Empty-render snaps still `<div />`. |
| `cell_actions_renderer.test.tsx.snap` | Both the content hash **and** the generated class change: `css-jlsvsc-ProviderContentWrapper e1p0plmv0` → `css-1s7tdhk-ProviderContentWrapper e14kwmf30`. |

That last one is the only one that is not a pure `e…` suffix swap. `ProviderContentWrapper` is a `styled.span` with CSS comments and no trailing semicolon on the last declaration — the same shape the new transformer special-cases in `makeEmotionLabelsSafe()` (`kbn-test` SWC transform). Nearby snaps owned by other teams show the same split: trailing-semicolon styled blocks keep `css-…` hashes (e.g. header title `css-1tgxtfm` / `css-80vzk8`); comment-y / no-semicolon blocks pick up a new content hash (e.g. tables `css-19lowmu-subtext` → `css-du0w0-subtext`).

---

### Files touched

- **Exception linked-rules menu snapshot** — `toMatchSnapshot()` of `LinkedRulesMenuItem` (`styled(EuiContextMenuItem)`). Two cases: single rule with left icon, and the second item when length > 1.
- **Value-with-space-warning snapshot** — plugin copy of the exceptions warning icon (the package-level test does not snapshot). Only the "show warning" case has a class.
- **Cell-actions renderer snapshot** *(not CODEOWNERS-DEX, included because it is the third Security snap in this set)* — `ProviderContentWrapper` around mocked `SecurityCellActions`. Used in tables/timelines, not detection-engine-owned.

Everything else in the PR is the Jest transform, lockfile, or other teams' Emotion snaps.

---

### Assumptions

- These three Jest files actually ran under SWC in CI (PR build 500731 succeeded, with flakes). If they had not, the old hashes would still be in tree and would fail later on `main`.
- Runtime CSS for `ProviderContentWrapper` is equivalent after the content-hash change — comments/label delimiters, not selectors. The snapshot still only asserts class strings, not computed styles.
- No other DEX-owned snapshot tests needed a refresh. Full Jest CI is the evidence; there is no extra DEX `.snap` sitting stale in this branch.

---

### Risks

1. ~~**`cell_actions` CSS content hash changed, the other two did not.** Why this is worth a look: that means SWC serialized the styled template differently, not just renamed the generated class. Looking at the source, the difference is comments + a missing trailing `;` in `ProviderContentWrapper`. That matches the transformer's emotion-label workaround, so a visual break is unlikely. Still the only non-mechanical thing in this team's three files.~~ **(HARMLESS)** — comments and `makeEmotionLabelsSafe` are not involved. See follow-up #1. The two hashes are equivalent serializations of the same rules (`>span` vs `> span`, plus Babel's extra `;` when merging a precompiled styles object). Computed CSS does not change.

---

### Open questions

- None that are specific to these three snaps. The transform itself is `@elastic/kibana-operations` / `@elastic/appex-qa` territory; several of those teams have already approved.

---

### Notes for your codebase map

- Emotion snapshots encode two names: `css-{contentHash}-{label}` (stable if the CSS string is identical) and `e{generated}` (always moves when the compiler that emitted the styled component changes).
- `@swc/plugin-emotion` plus `makeEmotionLabelsSafe()` in `kbn-test/src/jest/transforms/swc/index.js` is why some hashes move and some do not: labels concatenated onto a CSS tail with no `;` used to get eaten; the rewrite inserts a delimiter.
- DEX CODEOWNERS for this UI: package `kbn-securitysolution-exception-list-components`, and plugin `public/detection_engine/rule_exceptions`. `public/common/components/cell_actions` has no override, so it stays `@elastic/security-solution`.
- The package-level `value_with_space_warning` test does not use snapshots; only the plugin copy does. That is why there is no third DEX-owned snap in that package.

---

### Follow-up Review Activities

1. **Risk 1 — why `css-jlsvsc` became `css-1s7tdhk`.** Transformed the real `cell_actions_renderer.tsx` with both `@emotion/babel-preset-css-prop` (old Jest config: `autoLabel: 'always'`, `labelFormat: '[local]'`) and `@swc/plugin-emotion` (new Jest config), then hashed the strings Emotion actually serializes at runtime (`@emotion/hash` murmur2, same path as `serializeStyles`).

- `makeEmotionLabelsSafe()` does **not** run on these files. It only rewrites `css()` calls from `@emotion/react` / `@emotion/css`. All three snaps use `styled` from `@emotion/styled`, which puts `label` on the styled options object. The undelimited-label regex does not even match the styled output.
- Comments are stripped by **both** compilers. SWC output with and without the CSS comments is the identical string `> span.euiToolTipAnchor{display:block;}> span.euiToolTipAnchor.eui-textTruncate{display:inline-block;}`. The comments-in-the-template theory was wrong.
- Babel, for a **static** (no interpolation) styled block, compile-time-extracts `{ name, styles }` and minifies by stripping the space after `>`: `>span.euiToolTipAnchor{...}`. SWC leaves a string and **keeps** that space: `> span.euiToolTipAnchor{...}`.
- At runtime `createStyled` always does `styles.push("label:" + name + ";")` then the compiler output. `serializeStyles` only uses the precomputed `{name, styles}` when it is the **sole** argument, so the label push forces a full re-hash. For the Babel object, `handleInterpolation` also appends an extra `;` (`serializedStyles.styles + ";"`).
- Hashes reproduce exactly:
  - old `jlsvsc` = hash(`label:ProviderContentWrapper;>span.euiToolTipAnchor{display:block;}>span.euiToolTipAnchor.eui-textTruncate{display:inline-block;};`)
  - new `1s7tdhk` = hash(`label:ProviderContentWrapper;> span.euiToolTipAnchor{display:block;}> span.euiToolTipAnchor.eui-textTruncate{display:inline-block;}`)
- `e1p0plmv0` → `e14kwmf30` is the compiler `target` option (component-selector class). Babel on the real file emits `target: "e1p0plmv0"`; SWC emits `e14kwmf30`. Unrelated to the CSS rules.
- `value_with_space_warning` / linked-rules keep `css-mwb0ig` because they have interpolations, so **both** compilers emit the same string-part + function form (`"display:inline;margin-left:", fn, ";"`). Runtime hash after theme substitution is unchanged; only `target` moves. Confirmed: hash(`label:Container;display:inline;margin-left:4px;`) = `mwb0ig`.
- Stylis treats `>span` and `> span` as the same selector. Babel's extra `;` is an empty declaration. No computed-style difference. Jest class names also never matched webpack production (`labelFormat: '[filename]--[local]'`, labels off in prod).
