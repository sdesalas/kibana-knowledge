# PR #271084 — Remove alternative Saved Objects checks and make CI check hard-fail

- **Author:** @gsoldevila
- **Base:** `main` ← `cleanup/remove-alternative-so-checks`
- **Size:** 53 files, +692 / −9,792 (mostly deletions of legacy code + 6.7k lines of generated baseline JSON)
- **State:** Open, mergeable but BLOCKED (no reviews yet); reviewers requested: `@elastic/kibana-operations`, `@elastic/kibana-core`, `@elastic/security-detection-rule-management`, `@sdesalas`
- **Scale:** Substantive (touches CI gating, snapshot semantics, and Core SO type-checking infra) — **but for the security-detection-rule-management team it is effectively trivial.**

## Ownership (team: `@elastic/security-detection-rule-management`)

- **Your team's files (1):** `src/platform/packages/shared/kbn-openapi-generator/README.md` — docs-only, removes a stale step from the "how to wire your codegen into Buildkite" instructions.
- **Other teams' files:**
  - `@elastic/kibana-core` — `packages/kbn-check-saved-objects-cli/**` (the bulk of the PR), `src/core/**` (deleted `check_registered_types.test.ts`, moon/tsconfig tweaks, doc update).
  - `@elastic/kibana-operations` — `.buildkite/**` (pipeline/script changes, including making the SO check hard-fail).
- **Unowned:** none.

**The PR touches exactly one file owned by your team, and it is a 1-line README deletion.** You are almost certainly cc'd because the SO CI check now hard-fails for everyone (which affects detection-engine SO types like prebuilt rules, exception lists, etc.) and because you own kbn-openapi-generator. Depth-of-review should be calibrated accordingly: skim Core's snapshot-handling logic for assumptions that could bite SO types your team owns, but the heavy lifting of correctness review belongs to Core and Operations.

## Summary

Cleans up a duplicated CI surface area for Saved Objects type checks. Two legacy validators — `scripts/check_mappings_update` (a separate `node` CLI in this same package) and the `check_registered_types.test.ts` Jest integration test — were running in parallel with the newer `check_saved_objects` CLI. This PR deletes both, along with their committed aggregate baselines (`current_mappings.json`, `current_fields.json`) and the Buildkite scripts that ran them. Coverage is preserved by existing `check_saved_objects` validators (`validateAdditiveOnlyMappings`, `validateNoVirtualVersionDowngrade`, `validateChangesExistingType`).

Two behavioral changes ride along:

1. **Hard-fail.** The `check_saved_objects` Buildkite step removes `soft_fail: true`. Going forward, an SO violation blocks merges instead of being advisory.
2. **Snapshot resolution moved into JS.** The bash `findExistingSnapshotSha` (3 retries → walk parents) is replaced by `resolveSnapshotSha` in `kbn-check-saved-objects-cli`, with explicit `ATTEMPTS_PER_SHA = 3`, `MAX_ANCESTOR_DEPTH = 3`, and a 3 s retry delay (= up to 12 GCS HEADs across 4 SHAs). When the resolver falls back to an ancestor snapshot, the PR comment now includes a `[!WARNING]` banner asking the author to rebase. The migrator-vs-snapshot mapping shape mismatch (snapshot stores flattened `properties.x.type`; migrator wants nested `SavedObjectsTypeMappingDefinition`) is bridged by `unflattenSnapshotMappings`, which also re-adds an empty `properties: {}` for types with no mapped fields so downstream `getFlattenedObject(mappings.properties)` calls don't blow up.

The stated intent (description) and the diff line up cleanly; no scope drift.

## Files touched

- **CI gating / hard-fail:** `.buildkite/pipelines/pull_request/check_saved_objects.yml` (drops `soft_fail`), `.buildkite/scripts/steps/check_saved_objects.sh` (deletes bash snapshot-resolution helpers, defers to the CLI), `.buildkite/scripts/steps/checks.sh` (stops invoking the two retired sub-checks).
- **Removed legacy checks:**
  - `scripts/check_mappings_update.js`, all of `packages/kbn-check-saved-objects-cli/src/compatibility/**` and `src/mappings_additions/**` plus their tests/mocks, `current_mappings.json` (5,144 lines), `current_fields.json` (1,552 lines), and the test-fixture `baseline_mappings.json`.
  - `src/core/server/integration_tests/ci_checks/saved_objects/check_registered_types.test.ts` (1,808 lines) and its `jest.integration.config.js`.
  - Buildkite shims `saved_objects_compat_changes.sh`, `saved_objects_definition_change.sh`.
- **New snapshot resolver / extractor (Core):** `src/snapshots/resolve_snapshot_sha.{ts,test.ts}`, `src/snapshots/extract_mappings_from_snapshot.{ts,test.ts}`, plus exports through `src/snapshots/index.ts`.
- **CLI wiring (Core):** `src/commands/run_check_saved_objects_cli.ts` (calls `resolveSnapshotSha` for both baselines, threads `requestedGitRev` / `baselineUsedAncestorSnapshot` through `TaskContext`), `src/commands/tasks/get_snapshots.ts` (label tweak, drops listr retry now that retries live in the resolver), `src/commands/tasks/automated_rollback_tests.ts` (replaces `getFileFromKibanaRepo('current_mappings.json')` with `extractMappingsFromSnapshot(ctx.from!)`), `src/commands/types.ts`, `src/findings/types.ts` (new report fields).
- **PR-comment formatting (Operations-owned, but the new fields originate in Core):** `.buildkite/scripts/steps/checks/notify_saved_objects_changes.{ts,test.ts}` — adds the `[!WARNING]` ancestor-snapshot banner and upgrades the existing 2-step-release reminder to `[!CAUTION]`.
- **Bug fix riding along:** `src/snapshots/validate_changes/common_utils.ts` — dedupes field paths in `validateNoIndexOrEnabledFalse` (would previously double-report when multiple sub-fields under the same parent were added in a model version).
- **Docs / config:** `src/core/server/docs/kib_core_reviewing_so_type_pr.mdx` (updated reviewer guidance), `src/core/moon.yml`, `src/core/tsconfig.json`, `packages/kbn-check-saved-objects-cli/{moon.yml,tsconfig.json,index.ts}`, `src/platform/packages/shared/kbn-openapi-generator/README.md` *(your team)*.

## Flow trace — PR-pipeline run on `main`

1. `.buildkite/scripts/steps/check_saved_objects.sh` runs in `is_pr` branch. With `findExistingSnapshotSha` removed, it now passes `$GITHUB_PR_MERGE_BASE` (and on `main`, `$GITHUB_SERVERLESS_RELEASE_SHA`) directly to `node scripts/check_saved_objects --baseline …`.
2. `runCheckSavedObjectsCli` (in `run_check_saved_objects_cli.ts`) is now responsible for resolving each baseline. For each non-empty baseline, it calls `resolveSnapshotSha(sha)` which:
   - `expandGitRev` → full SHA (so the PR-comment baseline string is stable),
   - `snapshotExists` HEADs `gcsSnapshotUrl(sha)`; if it returns 2xx/3xx, return,
   - otherwise sleep 3 s and retry up to 3 times,
   - then `getParentCommitSha(sha)` (local `git rev-parse sha^`, falling back to `gh api …/parents[0].sha` for SHAs missing from the local clone, e.g. emergency-release branches),
   - repeat up to `MAX_ANCESTOR_DEPTH = 3`.
   - If still not found, throws with the same "rebase onto latest `main`" message the bash version had.
3. The resolved values land in `TaskContext` as `gitRev` / `serverlessGitRev` (resolved) plus `requestedGitRev` / `requestedServerlessGitRev` / `*BaselineUsedAncestorSnapshot` flags.
4. `getSnapshots` task downloads `fetchSnapshot(ctx.gitRev)` — note the listr-level `{ retry: { tries: 5, delay: 2000 } }` is gone here; resilience is now solely in `resolveSnapshotSha`.
5. `automatedRollbackTests` no longer pulls `current_mappings.json` from the repo at the merge-base SHA. Instead, `extractMappingsFromSnapshot(ctx.from!)` derives the baseline mappings from the *snapshot* directly, calling `unflattenSnapshotMappings` on each type. For each type:
   - if any key contains a `.`, treat the mapping as flattened and run `unflattenObject` on it,
   - if the unflattened result has no `properties` key, inject an empty one (so types with no mapped fields still satisfy `getFlattenedObject(mappings.properties)` later).
6. `validateSOChanges` runs the existing snapshot-vs-current validators (additive-only, virtual-version-downgrade, etc.) — unchanged in behavior, those validators continue to operate on flattened maps.
7. The CLI assembles `SavedObjectsCheckReport`, including `baselineSnapshotSha` / `baselineSnapshotUsedAncestor` when an ancestor was used, writes it to `--report-path`, and exits.
8. The "Post Saved Objects PR comment" step runs `notify_saved_objects_changes.ts`. `buildBaselineLagBanner` appends a `[!WARNING]` block to both pass and fail comments when `baselineSnapshotUsedAncestor` is true. With `soft_fail` removed, a non-zero exit now blocks merge.

## Assumptions

- **Snapshot upload latency on `main` is bounded by ~12 attempts × 3 s ≈ 36 s plus 3 ancestor walks.** If the GCS upload pipeline takes longer than that on a busy main (e.g. during incidents), the resolver falls through to the ancestor path. The author has chosen to surface that as a banner rather than fail; risk is unchanged from the bash version (which used 10 attempts × 2 s).
- **The merge-base snapshot's mapping format matches what `extractMigrationInfo` produces *today*.** `unflattenSnapshotMappings` keys off of "any key contains a dot". If an older snapshot stored mappings in mixed/nested form for some types, `isFlattenedMapping` returns false and the path bypasses unflattening — relies on snapshot producers having always emitted one or the other consistently per type.
- **`getFlattenedObject(mappings.properties)` is the only downstream consumer that requires `properties` to exist.** The empty-`properties` injection is targeted at exactly that call site; if any other consumer treats absence-of-`properties` as semantically meaningful, this normalization could mask differences. (No such consumer was visible in the diff or the surrounding code; flagging because it's a silent shape change.)
- **Coverage parity claim.** The PR description maps each retired check to a replacement in `check_saved_objects` (additive-only → `validateAdditiveOnlyMappings`; virtual-version non-downgrade → `validateNoVirtualVersionDowngrade`; declared-vs-mapped fields → `validateChangesExistingType`). Verifying that mapping byte-for-byte is Core's job, not yours; the PR doesn't show the replacement code, only deletes the originals.
- **`gh` is on the agent's PATH.** `getParentCommitSha`'s fallback shells out to `gh api …`. If `gh` is not installed on every CI runner that might hit the fallback, the resolver throws. This was already true of the bash version.

## Risks

In rough order of likelihood × blast-radius. None look critical, but a couple are worth poking at.

1. **Hard-fail is a one-way door for the next few weeks of PRs.** `soft_fail` was the safety net for false positives. With it gone, any latent flakiness in `resolveSnapshotSha` (slow GCS, ancestor walk hitting a non-existent SHA, gh-CLI auth) blocks merges across all teams. Worth confirming with Operations that the hard-fail flip is being communicated and that there's a clear "force-merge / re-run / contact owner" path.
2. **Ancestor-snapshot fallback can produce false positives that span every SO type your team owns.** The banner explicitly warns about this. For teams that have prebuilt-rule SOs, exception-list SOs, etc. (i.e. yours), if the resolver picks an older ancestor than your branch was rebased onto, the comparison can flag any type that changed between merge-base and the older ancestor as if your PR changed it. Mitigation is exactly what the banner says — rebase. Worth a note to your team's RM: the failure mode "I didn't touch SOs and the SO check is failing" now becomes routine and the fix is "rebase".
3. **`unflattenSnapshotMappings` heuristic is ambiguous on legitimately dotted property names.** Saved Object mappings can include subfields like `host.os.name` rendered into ES as `properties.host.properties.os.properties.name` — but in some legacy types, dotted top-level field names exist as raw keys. If any snapshot has an entry like `"foo.bar": "keyword"` *as a property name in the nested form*, `isFlattenedMapping` will misclassify it as flattened and re-`unflattenObject` it. Low likelihood given Core's discipline, but worth asking whether `extractMigrationInfo` ever emits keys that are not pure dotted paths from the *root* of the mapping object.
4. **Loss of `check_registered_types.test.ts` removes a fixture-based regression net.** That test (1,808 lines) historically caught accidental removal/rename of registered SO types because every PR touching a type had to update the fixture. The replacement story is "`validateChangesExistingType` covers it", which is true for the *change-detection* part but not for the *human-eyeballable diff* that the fixture provided in code review. This is a real workflow change for SO-touching teams (yours included) — losing the fixture means there is no longer a `git diff` line that says "you changed type X". Risk is to reviewer attention, not correctness.
5. **`getParentCommitSha` does not validate that the ancestor it walked into is on the same branch lineage.** For unusual cases (force-pushed merge-base, octopus merges), `git rev-parse sha^` always returns the first parent, which may be the wrong ancestor on a merge commit. Probably fine because merge-base is itself a single SHA, but worth flagging if anyone relies on this for non-PR pipelines.

## Open questions

For the PR author / Core / Operations:

1. Why drop the listr-level retry on `fetchSnapshot` in `get_snapshots.ts`? `resolveSnapshotSha` only verifies the snapshot exists via HEAD; the *download* still happens later. If GCS is briefly unhealthy between the HEAD and the GET, there's now no retry. Was this intentional — and if so, is the assumption "HEAD success implies fast GET success"?
2. The `test`-mode path (`--test`) used to load `BASELINE_MAPPINGS_TEST` (a fixture). With that fixture deleted, does `node scripts/jest packages/kbn-check-saved-objects-cli/src` still cover the rollback flow, or did it move to the snapshot-driven path entirely? (Description checks the box, so probably yes — but worth confirming the rollback test isn't silently a no-op now.)
3. The PR description says "Closes elastic/kibana-team#3143" (DRM-internal) — is the issue specifically about removing the alternative checks, or also about something operational (e.g. the hard-fail timing)? Linked issues are private; I couldn't read them.
4. (For your team specifically.) Are any of detection-engine's prebuilt-rule SO migrations relying on `check_registered_types.test.ts`'s fixture as a documentation artefact? If yes, what replaces it for *that* workflow?

## Notes for your codebase map

- `kbn-check-saved-objects-cli` is now the single source of truth for Saved Object CI checks; previously it ran in parallel with `scripts/check_mappings_update` and `check_registered_types.test.ts` (Jest integration), both deleted in this PR.
- The check is invoked by `.buildkite/scripts/steps/check_saved_objects.sh`. Buildkite is now thin — bootstrap + call the CLI. All retry/fallback logic lives in JS (`src/snapshots/resolve_snapshot_sha.ts`).
- Snapshots in GCS (`kibana-so-types-snapshots/<sha>.json`) store mappings in **flattened dot-key form** because that is what `extractMigrationInfo` produces. The migrator API expects nested `SavedObjectsTypeMappingDefinition`. `unflattenSnapshotMappings` is the bridge whenever you need to feed snapshot data back into migrator code paths.
- `SavedObjectsCheckReport` (in `notify_saved_objects_changes.ts`) is the public contract between the CLI and the PR-comment renderer. New fields here are the right place to surface anything else the comment should display.
- `validateNoIndexOrEnabledFalse`'s drive-by dedup fix (`common_utils.ts`) is a hint that `newMappings` from a model version contains *every* dotted sub-path, not just leaf fields, so any path-prefix logic should de-duplicate before iterating.
- For the security-detection-rule-management team specifically: the "alternative SO checks" being removed never produced PRs your team typically reviewed; the README touch in `kbn-openapi-generator` is the only thing that ever surfaced these legacy scripts in your area, and the deletion brings it back in line with reality.
