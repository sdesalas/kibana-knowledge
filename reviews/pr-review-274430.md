# PR Review: #274430 — [Detection Engineering] update codeowners

**PR:** [elastic/kibana#274430](https://github.com/elastic/kibana/pull/274430) by @yctercero

**Scale:** Small PR mechanically (1 file, +124/-128), but org-wide in effect — it rewires CODEOWNERS for the whole detection-engineering surface. Worth a careful pass because a half-done rename leaves paths silently owned by a team that no longer exists.

**Ownership (team: `@elastic/security-detection-engineering`):** This *is* the ownership change. The only file touched is `.github/CODEOWNERS`.

## Context / Motivation

The team is consolidating three teams into one new `@elastic/security-detection-engineering`:

- `@elastic/security-detections-response`
- `@elastic/security-detection-rule-management`
- `@elastic/security-detection-engine`

The PR description says all three old teams are being sunset. So the end state should be: zero references to any of the three old handles anywhere CODEOWNERS resolution depends on.

## Summary

The PR find-and-replaces old team handles with `@elastic/security-detection-engineering` in the **hand-maintained** section of `.github/CODEOWNERS` (roughly lines 2627–3700: the "cross teams ownership", "Security Solution sub teams", OpenAPI bundles, and codegen blocks). Where two of the old teams co-owned a path, the merge naturally collapses 3-way lines into 2-way (e.g. the cypress shared-common lines now read `@elastic/security-detection-engineering @elastic/security-threat-hunting`).

It does **not** touch the auto-generated package-ownership section, and it does not update any `kibana.jsonc` `owner` fields. That's the gap both reviewers are pointing at.

## Validating Vitalii's comment — is he right?

> there are still old teams in codeowners file
> `@elastic/security-detection-engine` | 23 lines
> `@elastic/security-detection-rule-management` | 8 lines
> Is there an intent to address it in subsequent PRs or were they missed?

**Yes, he's right, and I can confirm the exact lines and the root cause.** On the PR branch:

- `security-detection-engine` (the old handle, not `-engineering`): **23 lines**
- `security-detection-rule-management`: **8 lines**
- `security-detections-response`: 0 (fully gone)
- `security-detection-engineering` (new): 115 lines

Every leftover line sits in the **generated** block of CODEOWNERS (package paths under `src/platform/packages/**`, `x-pack/solutions/security/packages/**`, `x-pack/solutions/security/plugins/lists`, `x-pack/.../security_solution_api_integration`). The CODEOWNERS header itself says this block is produced by `node scripts/generate codeowners`, so editing it by hand wouldn't stick — it's driven by the `owner` field in each package's `kibana.jsonc`.

The leftover lines, by old handle:

- **`security-detection-rule-management` (8):** L634 `kbn-openapi-bundler`, L635 `kbn-openapi-common`, L636 `kbn-openapi-generator`, L656 `kbn-rule-data-utils` (4-way), L733 `kbn-zod-helpers`, L1030 `kbn-change-history`, L1367 `kbn-securitysolution-utils` (paired), L1373 `test-api-clients`.
- **`security-detection-engine` (23):** L656 `kbn-rule-data-utils`, L669–672 the `kbn-securitysolution-*` platform packages, L1348 `kbn-evals-suite-security-ai-rules`, L1354–1366 the `kbn-securitysolution-*` solution packages, L1367 `kbn-securitysolution-utils`, L1382 `plugins/lists`, L1390–1391 `security_solution_api_integration` + its `detections_response` service config.

Root cause confirmed: **29 `kibana.jsonc` files still carry an old team handle in their `owner` field.** Until those are updated and `node scripts/generate codeowners` is re-run, the generated block keeps emitting the dead teams. So it was "missed" in the mechanical sense, but it's not fixable by editing CODEOWNERS directly — it needs the manifest update + regen that @nikitaindik called out in his approval.

This lines up with @nikitaindik's review:

> The only thing that's left is to also update owners in packages's `kibana.jsonc` files and then run `node scripts/generate codeowners`.

Same fix, two reviewers. The PR is internally consistent for the hand-maintained section; it's just incomplete for the generated section.

## Tie-in with the CODEOWNERS quick-wins research

This consolidation PR touches *exactly* the peripheral lines the [quick-wins report](https://github.com/sdesalas/kibana-knowledge/blob/main/reports/codeowners-review/codeowners_quick_wins.md) recommends trimming — so it's a natural moment to fold in those removals rather than carry the review load forward under the new team name. Overlap between the leftover/edited lines and the report's Tier-1 candidates:

| Path | This PR | Quick-wins recommendation |
| ---- | ------- | ------------------------- |
| `kbn-rule-data-utils` (L656) | still old (`rule-management` + `engine`) | **drop us**; 3 co-owners stay (★ biggest win, 2.2/mo) |
| `kbn-openapi-bundler/common/generator` (L634–636) | still `rule-management` | **drop** (sole owner, platform toolchain) |
| `kbn-zod-helpers` (L733) | still `rule-management` | **drop** (sole owner, generic) |
| `kbn-change-history` (L1030) | still `rule-management` | **keep on `engineering`** — Kibana core will take ownership after feature delivery; planned hand-off, not a drop |
| `kbn-securitysolution-utils` (L1367) | still old (both) | **drop us**; detection-engine→engineering stays |
| `server/routes` (L2878-ish, edited) | now `engineering` + threat-hunting | report says **drop us** (1.5/mo) — PR keeps us |
| cypress `support`/`objects`/`screens/common` (edited) | now `engineering` + threat-hunting | report says **drop us** — PR keeps us |
| `common/test`, `detections_response/utils`+`telemetry` (edited) | now `engineering` | report says **drop us** — PR keeps us |
| `alerting/.../change_tracking` (edited) | now `engineering` | Tier 3: consider giving to `@elastic/response-ops` |

So the PR, as written, renames the team onto all the peripheral paths and preserves the full review burden. If the team wants the quick-wins savings (~28% review-load reduction in the report), the cleanest sequencing is: land this consolidation first (correctness), then a follow-up that applies the removals — *or* fold the removals in here while the same lines are already open. Doing it here avoids a second churn of the same lines, but it does broaden the PR's scope beyond a pure rename, which can slow review. Judgment call for the author; worth raising explicitly.

One nice side effect already in the PR: the `change_tracking` line lost its explanatory comment (`# Change tracking inside alerting framework is managed by ...`). Minor, but if that line stays, the comment was useful context — worth keeping or rewording rather than dropping silently.

## Recommendation

**Land the consolidation correctly first; treat the quick-wins trimming as a deliberate, separate decision.** Concretely:

1. **Finish the rename (blocking).** Update the `owner` field in the **29 `kibana.jsonc`** files still on old handles and run `node scripts/generate codeowners`, so the generated block stops emitting the dead teams. This closes both @vitaliidm's and @nikitaindik's comments. Do it in this PR if feasible — that keeps the tree in a never-broken state and avoids a window where the old GitHub teams are deleted while ~31 package paths still point at them. If it's split into a follow-up, that follow-up must merge **before** the old teams are disbanded.

2. **Take the low-friction Pattern-1 drops in this PR** (banderror's priority, zero coordination needed — both fall back to `@elastic/security-solution`):
   - Common UI components/hooks, under `x-pack/solutions/security/plugins/security_solution/public/common/`: `components/callouts`, `components/health_truncate_text`, `components/links_to_docs`, `components/ml_popover`, `components/missing_privileges`, `components/popover_items`, `hooks/use_form_with_warnings`.
   - Shared API-integration test helpers, under `x-pack/solutions/security/test/security_solution_api_integration/`: `test_suites/detections_response/utils`, `test_suites/detections_response/telemetry`, `test_suites/detections_response/user_roles`, `test_suites/sources`, `config/services/detections_response`.

3. **Defer the threat-hunting-impacting drops to a coordinated follow-up.** cypress shared-commons under `x-pack/solutions/security/test/security_solution_cypress/cypress/`: `support`, `objects`, `screens/common`, `fixtures`, `helpers`; and under `x-pack/solutions/security/plugins/security_solution/`: `server/routes`, `server/utils`, `common/test`. These would become **threat-hunting-only** post-merge (no base owner fallback). Get threat-hunting's explicit OK first — don't fold these into the rename.

4. **Handle the platform `kbn-*` packages in the regen step (step 1), not by hand.** When updating their `kibana.jsonc`, decide per-package whether to migrate to `engineering` or drop. Under `src/platform/packages/shared/`: `kbn-rule-data-utils` can simply drop us (3 co-owners remain); the sole-owned `kbn-openapi-bundler`, `kbn-openapi-common`, `kbn-openapi-generator`, `kbn-zod-helpers` need a real new owner or they orphan.
   - **Exclude `kbn-change-history`** (`x-pack/platform/packages/shared/kbn-change-history`) — keep it on `engineering` for now. Kibana core has indicated they'll take ownership once we finish delivering the feature, so it's a planned hand-off later, not a drop candidate here.

5. **Skip Pattern 2 here.** Carve-outs inside chartered folders (alerts-table, agent-builder, CPS) need new specific lines + cross-team agreement — a separate workstream, not this PR.

**Net:** this PR's scope should be "rename done completely + the two safe Pattern-1 drop groups." Everything else (cypress/server handoffs, platform-package decisions, Pattern 2) is a follow-up so the consolidation isn't held hostage to cross-team negotiation.

## Files touched

- `.github/CODEOWNERS` — the only file. Hand-maintained sections rewritten to the new handle; generated section untouched (by design, since it's generated).

## Risks

- **Dead-team ownership on ~31 generated lines.** Until the `kibana.jsonc` + regen step lands, those package paths resolve to teams that are being deleted. Once the GitHub teams are actually removed, CODEOWNERS validation (the `node scripts/generate codeowners --validate`-style CI check) may start failing, and PRs touching those packages get no valid reviewer auto-request. This is the main thing to close before the old teams are deleted.
- **Ordering against team deletion.** If the old GitHub teams are disbanded before the manifest/regen follow-up merges, review routing for those 29 packages breaks. Sequence matters: finish the rename everywhere *before* deleting the teams.
- **Lost shared visibility on peripheral paths (only if quick-wins applied here).** Not a risk in the current diff, but if removals are folded in, double-check each fallback owner is real (the report claims all fall back to a sensible co-owner or the plugin default — worth spot-checking 2–3).

## Open questions

- Is the `kibana.jsonc` + `node scripts/generate codeowners` follow-up planned as a separate PR, or should it be pulled into this one? (Both reviewers are implicitly asking the same thing.) A single PR keeps the tree in a never-broken state.
- Will the old GitHub teams be deleted before or after the generated section is fixed? If before, what's the plan for the ~31 orphaned lines in the interim?
- Does the team want to take the quick-wins trimming opportunity now (while these lines are open) or defer to a dedicated PR? The report's biggest wins (`kbn-rule-data-utils`, `server/routes`) are right here in the touched/leftover set.
- The `change_tracking` line moved to the new team — is that the intended end state, or should it go to `@elastic/response-ops` (whose plugin it lives in), per Tier 3 of the report?

## Notes for your codebase map

- `.github/CODEOWNERS` has two regions: a **hand-maintained** region and a **generated** region produced by `node scripts/generate codeowners`. The generated region is sourced from each package's `kibana.jsonc` `owner` field — never edit it directly.
- A team rename/merge therefore has two distinct workstreams: (1) sed the hand-maintained region, (2) update every owning `kibana.jsonc` and regenerate. Missing (2) leaves dead-team lines that look like an oversight but are actually a generation artifact.
- ~29 security `kibana.jsonc` manifests still point at the old detection teams — that's the concrete backlog for the follow-up.

## Review activities

1. **Confirmed Vitalii's counts on the PR branch.** Local checkout is already on `update-codeowners-new-team`. `rg -c` gives 23 `security-detection-engine`, 8 `security-detection-rule-management`, 0 `security-detections-response`, 115 `security-detection-engineering`.
2. **Located every leftover line** (L634–L1391) and confirmed all sit in the generated package-ownership block, below the `node scripts/generate codeowners` header note.
3. **Traced root cause to `kibana.jsonc`.** Spot-checked `kbn-change-history` (`"owner": "@elastic/security-detection-rule-management"`) and `kbn-securitysolution-utils` (`["@elastic/security-detection-engine", "@elastic/security-detection-rule-management"]`); both still on old teams. A repo-wide scan found 29 `kibana.jsonc` files still referencing an old handle — these are what drive the leftover generated lines.
4. **Cross-referenced the quick-wins report.** Several leftover/edited lines (`kbn-rule-data-utils`, `kbn-openapi-*`, `kbn-zod-helpers`, `kbn-change-history`, `server/routes`, cypress shared-commons) are Tier-1 removal candidates; the PR currently renames onto them rather than dropping them.
5. **Scoped banderror's Pattern 1 against this PR's diff (what's droppable here).** Pattern 2 (carve-outs inside our own folders) needs new specific lines + cross-team sign-off — out of scope for a rename PR. For Pattern 1, verified fallbacks: `public/common/components/*` and `public/common/hooks/use_form_with_warnings` are sole-owned and fall back to the plugin default `@elastic/security-solution` (L1383) — safest to drop now. The `detections_response/*` test helpers fall back to the api-integration default `@elastic/security-solution` (L2819) — also safe. Key nuance: `security_solution_cypress` has **no base owner line**, and post-merge the old 3-way cypress/`server/routes`/`server/utils`/`common/test` lines are now `engineering + threat-hunting`, so dropping us hands **sole** ownership to threat-hunting (not the report's assumed "detection-engine co-owner stays"). Those need threat-hunting's OK first. Platform `kbn-*` packages are Pattern-1 too but are `kibana.jsonc`-driven, so they belong in the regen follow-up, not this diff.
6. **Wrote the Recommendation section** capturing the prioritised plan (finish rename + regen as blocking; take the two safe Pattern-1 drop groups here; defer threat-hunting handoffs and platform-package decisions; skip Pattern 2).
7. **Excluded `kbn-change-history` from drop candidates** per team input: Kibana core has indicated they'll take ownership once the feature is delivered, so it stays on `engineering` for now (planned hand-off, not a drop). Updated the Recommendation (step 4) and the quick-wins tie-in table accordingly.
