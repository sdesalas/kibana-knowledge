# PR Review: #292511 — [9.4] [Security Solution] Fix prebuilt rule tag filter installing stale rule versions (#292386)

**PR:** [elastic/kibana#292511](https://github.com/elastic/kibana/pull/292511) by @hannahbrooks
**Created Date: 2026-09-22**

**Scale:** Small diff (2 files), full pass. The change is a backport of [#292386](https://github.com/elastic/kibana/pull/292386), and the 9.4 filter type does not match the code that was copied from `main`.

---

### Context / Motivation

[#290911](https://github.com/elastic/kibana/issues/290911) (Steven de Salas, 14 Sep 2026). Installing from the Add Elastic Rules table while it is filtered by a tag the newest asset no longer has persists the older version. Rule Updates then offers an upgrade immediately.

The reported case is the AWS tag rename, `Data Source: AWS` → `Platform: AWS`. Filter by the old tag, install, and the table's version is one behind the real latest.

Steven's follow-up on the issue, after a DEX thread with @approksiu:

> PM opinion … (@approksiu: why are they even in the table?). Which implies the approach here should be to avoid displaying these records on the table. Ie. we shouldn't show older assets when the tag has changed. So the fix is on read(`_review`), not so much changes to `_perform` endpoint.

[#292386](https://github.com/elastic/kibana/pull/292386) did that on `main` and merged 21 Sep 2026. This PR is the automatic backport of that commit onto `9.4`. The 9.5 backport ([#292475](https://github.com/elastic/kibana/pull/292475)) is already merged. The 8.19 backport ([#292509](https://github.com/elastic/kibana/pull/292509)) is a different story: 8.19 never applied the tag inside the latest-version aggregation.

`kibana-ci` on this PR is red ([build 506541](https://buildkite.com/elastic/kibana-pull-request/builds/506541)). No Buildkite token in this session, so the failing job log was not read.

### Validating the issue — does this PR address it?

The concern is technically valid. The placement of the filter in this diff is the right fix. The backport as copied from `main` does not compile or test against 9.4's filter type, so it does not actually close the bug on this branch yet.

- **Where the problem manifests.** `reviewRuleInstallationHandler` passes the table filter into `fetchLatestVersions`. Before this PR, that filter was an argument to `fetchLatestVersionSpecifiers`, whose query is the `terms` aggregation plus `top_hits` sorted by version desc. Elasticsearch dropped newer assets that lacked the tag before `top_hits` ran, so the "latest" hit was the newest asset that still had the tag. The UI then posts that `{ rule_id, version }` from `installOneRule` / `installSelectedRules`.

- **Why the old approach was a problem.** v9 tagged `Data Source: AWS`, v10 tagged `Platform: AWS`. Filter by the old tag and the aggregation never sees v10. The table shows v9. Status and upgrade review call `fetchLatestVersions()` with no filter, so they see v10. Install, then an instant upgrade.

- **How the PR fixes it.** The tag (and name) filter is removed from the aggregation and applied on the second search, `fetchVersionsBySoIds`, which loads the true latest saved-object ids and then keeps only those that still match. A latest asset that lost the tag disappears from the table. The older asset is not offered in its place.

  On 9.4 that second search goes through `prepareQueryDslFilter`, which already knows the structured filter (`fields.tags.include.values` → a `term` on `security-rule.tags`, `fields.name` → a wildcard). Passing the same object there would do the right thing. The backport instead types the new argument as `string` and the new tests pass a KQL string (`security-rule.tags: "Data Source: AWS"`). That is `main`'s filter, after [#266112](https://github.com/elastic/kibana/pull/266112). 9.4 never got that change. `PrebuiltRuleAssetsFilter` here is still the zod object, and `prepareQueryDslFilter` reads `filter?.fields.tags`. A string has no `.fields`, so that line throws. `ESFilter` is also used in `fetchVersionsBySoIds` and is not imported.

- **Residual caveat.** `_perform` in `SPECIFIC_RULES` mode still checks that the `rule_id` is installable, then installs the version from the request body. A client that posts an old version directly can still persist it. That matches the issue comment: the leak is the table, and the write path was left alone.

### Summary

Moves the Add Elastic Rules filter so it runs after the latest version per `rule_id` has been chosen, instead of inside that aggregation. Rules whose current asset no longer has the filtered tag drop out of the table, which stops a filtered install from saving a stale version and immediately showing up under Rule Updates.

The diff matches the `main` fix. On 9.4 the filter value is a `{ fields: { tags, name } }` object, and `prepareQueryDslFilter` already turns that into Elasticsearch clauses. The new parameter is typed as a KQL `string`, `ESFilter` is not imported, and the new tests pass KQL. Those three things are `main`'s API. They do not typecheck here, and the filter tests throw if Jest strips the types and runs them.

### Files touched

- `fetch_latest_versions.ts` — the two-search helper behind `IPrebuiltRuleAssetsClient.fetchLatestVersions`. `_review` is the only caller that passes `filter`. Status, upgrade review, install-all, metrics, endpoint install, and rule import call it with rule ids or with nothing, so they already see the true latest.
- `fetch_latest_versions.test.ts` — new unit test. Mocks `savedObjectsClient.search` twice (aggregation, then the asset fetch). `fetchDeprecatedRules` uses `.find`, so that mock order is right. The assertions are written for a KQL string.

### Flow trace

1. The Add Elastic Rules table builds the filter in `prepareFilters` (`use_prebuilt_rules_install_review.ts`): `{ fields: { tags: { include: { values: ['Data Source: AWS'] } } } }`.
2. That body is `POST`ed to the installation `_review` route.
3. `getInstallableRuleVersions` calls `ruleAssetsClient.fetchLatestVersions({ sort, filter })`.
4. `fetchLatestVersionSpecifiers` no longer receives `filter`. It still loads deprecated rule ids and excludes them in this query, then runs `terms` on `rule_id` plus `top_hits` size 1 sorted by version desc. That is the real latest version. Deprecation stays on this query on purpose: filtering deprecated assets by `type` here would return the previous non-deprecated version. Tags are the opposite problem, which is why they move and deprecation does not.
5. Those `{ rule_id, version }` pairs become saved-object ids (`security-rule:{ruleId}_{version}`).
6. `fetchVersionsBySoIds` searches those ids. When `filter` is set it also appends `prepareQueryDslFilter({ filter }).filter`. On 9.4, given the real object, that is a `term` on `security-rule.tags` (and a name wildcard if the name box is filled). A latest asset that fails the term is absent from the hits. Nothing substitutes an older version.
7. The handler drops already-installed rules and license-restricted rules, slices the page, and `fetchAssetsByVersion` loads the full assets for that page.
8. Install reads `version` off those rows and posts it to `_perform`.
9. The tag dropdown is a separate unfiltered `fetchLatestVersions()` inside `fetchStats`, then `fetchTagsByVersion`. This PR does not change that. The dropdown stays latest-only, which is what the issue asked for.

### Assumptions

- The only production caller that passes `filter` is installation `_review`. Checked the other `fetchLatestVersions` call sites; they pass `ruleIds` or nothing.
- `prepareQueryDslFilter` on this branch understands the structured object and does not parse KQL. There is no `fromKueryExpression` anywhere under `rule_assets`.
- Tag and name `exclude` are on the zod schema and are still ignored by `prepareQueryDslFilter`. That is unchanged.
- The terms aggregation size is `MAX_PREBUILT_RULES_COUNT` (10_000). Applying the tag after the aggregation means the cap is on all rule ids, then the tag narrows the list. The catalog is well under that cap. The unfiltered path already aggregated every rule id.
- `_perform` keeps trusting the version in the body, as long as the `rule_id` is one of the latest installable ids.

### Risks

1. (ALREADY NOTED) ~~The backport will not pass typecheck, and the new filter tests do not exercise 9.4's filter. `fetchVersionsBySoIds` takes `additionalFilter?: string`, but `fetchLatestVersions` passes `PrebuiltRuleAssetsFilter`. `ESFilter` is referenced and never imported. The tests pass `` `${PREBUILT_RULE_ASSETS_SO_TYPE}.tags: "…"` `` into both `fetchLatestVersions` and `prepareQueryDslFilter`. The helper then evaluates `filter?.fields.tags`, which throws on a string. The one test with no filter is the only one that matches this branch. `kibana-ci` is already red; the job log was not opened here.~~

   ~~The query change itself is what 9.4 needs. Typing that argument as `PrebuiltRuleAssetsFilter`, importing `ESFilter`, and feeding the tests `{ fields: { tags: { include: { values: [tag] } } } }` would make the same diff valid. `prepareQueryDslFilter(...).filter` is the right thing to spread: tag and name includes are the only clauses it returns when `excludeRuleIds` is omitted, so `must_not` is not dropped on this path.~~

### Open questions

- (ALREADY NOTED) ~~Can the new tests be rewritten against the structured filter, instead of the KQL string from `main`? The "filter is on the second search only" assertion is the right check. It just needs `prepareQueryDslFilter` to be called with `{ fields: { tags: { include: { values } } } }`, which is what `_review` actually sends.~~
- (ALREADY NOTED) ~~`fetchLatestVersionSpecifiers` still declares a `filter` argument and nothing passes it or reads it. Worth deleting so the next change does not put the tag back on the aggregation.~~

### Notes for your codebase map

- `fetchLatestVersions` is two searches. Search 1 picks the latest version per `rule_id` (and is where deprecated rule ids are excluded). Search 2 loads those saved objects. On 9.4 the table filter belongs on search 2.
- 9.4's `PrebuiltRuleAssetsFilter` is `{ fields: { name?, tags? } }`. `prepareQueryDslFilter` turns includes into a wildcard (name) and `term` clauses (tags). `main` later replaced that with a KQL string ([#266112](https://github.com/elastic/kibana/pull/266112), `backport:skip`). A `main` backport that touches this filter has to be retyped for 9.4.
- The tag dropdown is not the table query. It comes from an unfiltered latest-version fetch plus `fetchTagsByVersion`.
- `SPECIFIC_RULES` install does not re-resolve the version. It installs the version the client sent, after checking the `rule_id` is installable.
- 8.19 already filters tags in memory after picking the latest version (`filterRuleVersions`). It never had this aggregation bug. 9.5 has the KQL filter, so its backport of the same commit matches that branch.

### Follow-up Review Activities

1. Re-read `fetch_latest_versions.ts` and `fetch_latest_versions.test.ts` only, looking for anything not already in Risks / Open questions.

- Nothing new on the production file. The string-typed `additionalFilter`, missing `ESFilter` import, and unused `filter` arg on `fetchLatestVersionSpecifiers` are the same three items.
- The exclude / match tests return whatever the mock is queued to return. They do not inspect the latest asset's tags. The placement test is the only one that would actually catch the filter landing on the wrong search, and it already fails on the KQL/object mismatch.

2. Focused pass: solution-integration. Checked `prepareQueryDslFilter` and `savedObjectsClient.search` against the new `bool.filter` wrap. No new risk. The string-vs-object filter is still Risk #1. Query wrap is valid (see below).
