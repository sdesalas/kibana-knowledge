# PR Review: #292386 — [Security Solution] Fix prebuilt rule tag filter installing stale rule versions

**PR:** [elastic/kibana#292386](https://github.com/elastic/kibana/pull/292386) by @hannahbrooks
**Created Date: 2026-09-21**

**Scale:** Small. Two files, one query-order change in `fetchLatestVersions`, plus new unit tests. The install path and `_perform` handler are unchanged.

**Ownership (team: `@elastic/security-detection-engineering`)**
- **Your team's files (2):** `fetch_latest_versions.ts`, `fetch_latest_versions.test.ts` — *focus review effort here*
- **Other teams' files:** none
- **Unowned:** none

---

### Context / Motivation

This started as a side observation from @banderror while smoke-testing the optimized rule import PR ([#275695 comment](https://github.com/elastic/kibana/pull/275695#issuecomment-5663697131)):

> Installing some prebuilt rules tagged as `Data Source: AWS` instantly shows some of them as ready for upgrade to a new version. This looks like a bug in the prebuilt rules logic.

You filed that as [issue #290911](https://github.com/elastic/kibana/issues/290911). Recent AWS assets renamed `Data Source: AWS` → `Platform: AWS`. The Add Elastic Rules table, filtered by the old tag, was offering the last version that still had that tag. Install then immediately appeared under Rule Updates, because status/upgrade review always resolve the true latest version.

The issue listed two possible fixes:

1. `_review`: resolve latest per `rule_id` first, then apply the tag/search filter to that asset only.
2. `_perform` `SPECIFIC_RULES`: if the requested version is not latest, replace it or reject it.

This PR implements (1) only.

### Validating the issue — does this PR address it?

The concern is technically valid. The PR addresses the `_review` half correctly. `_perform` is left as-is.

- **Where the problem manifests** — `fetchLatestVersionSpecifiers` ran a `terms` + `top_hits` agg *after* `prepareQueryDslFilter({ filter })`. If v9 had `Data Source: AWS` and v10 had `Platform: AWS`, the filter hid v10, so `top_hits` picked v9 as "latest." The UI posted `{ rule_id, version: 9 }` to `_perform`.
- **Why the old approach was a problem** — `_perform` `SPECIFIC_RULES` only checks that the `rule_id` is installable, then loads `security-rule:{ruleId}_{version}` as requested. Status/upgrade review call `fetchLatestVersions()` with no filter and see v10. Instant upgrade.
- **How the PR fixes it** — the KQL filter is removed from the aggregation query and applied in `fetchVersionsBySoIds` against the already-chosen latest SO IDs. If the latest asset does not match, the rule is dropped from the table.
- **Residual caveat** — `_perform` still queues the client-supplied `{ rule_id, version }` and fetches that exact asset. A crafted request, or a stale table session, can still install an older version.

### Summary

The PR changes what "latest" means when the Add Elastic Rules table is filtered. The aggregation always picks the true latest asset per `rule_id`. The tag/search filter then keeps or drops that asset. Rules whose newest version dropped the filtered tag disappear from the table instead of installing as an older matching version. Intent in [#290911](https://github.com/elastic/kibana/issues/290911) matches the diff; the second suggested defense on `_perform` is not in this PR.

### Files touched

- **Latest-version resolution:** `fetch_latest_versions.ts` is the two-step helper behind `_review` (`getInstallableRulesForReview` → `fetchLatestVersions`). Step 1 finds latest `(rule_id, version)` per `rule_id`. Step 2 loads those SOs (type, sort). The filter moved from step 1 to step 2.
- **Unit tests:** `fetch_latest_versions.test.ts` is new. It covers "latest no longer has tag → excluded", "filter is not on the agg query", "latest matches → returned", and "no filter → all latest".

### Flow trace

1. Add Elastic Rules table sends a tag/search KQL string into `POST .../installation/_review`.
2. `reviewRuleInstallationHandler` combines that into `combinedKql` and calls `getInstallableRulesForReview`.
3. `getInstallableRuleVersions` calls `fetchLatestVersions({ sort, filter })`.
4. `fetchLatestVersionSpecifiers` now aggregates across all non-deprecated assets (optional `ruleIds` only) and returns the highest version per `rule_id`.
5. `fetchVersionsBySoIds` loads those SO IDs and applies the KQL filter. Non-matching latest assets are omitted.
6. Remaining versions are de-duped against already-installed rules and license, then paged via `fetchAssetsByVersion`.
7. The UI installs with `SPECIFIC_RULES` using the `{ rule_id, version }` from that review payload. `_perform` still trusts that version.

### Assumptions

- "Latest" is defined as highest `security-rule.version` per `rule_id`, same as unfiltered review, status, and upgrade.
- It is acceptable UX for a retired tag to hide the rule entirely rather than show/install an older matching version.
- Callers that pass `filter` (`getInstallableRulesForReview`, and anything else hitting `fetchLatestVersions({ filter })`) want this new meaning. Unfiltered callers (`_perform` ALL_RULES, status, upgrade, metrics) are unchanged.
- `_perform` `SPECIFIC_RULES` will keep receiving the review table's versions; this PR does not assume `_perform` will correct a stale version.

### Risks

1. ~~**(IGNORED) `_perform` can still install a non-latest version.** The handler checks installability by `rule_id` against unfiltered latest versions, then `ruleInstallQueue.push(rule)` uses the request body version and `fetchAssetsByVersion(batch)` loads that exact SO. The UI path is fixed; the API path is not. This is the second fix listed in #290911.~~ Out of scope for this PR.

2. ~~**(FIXED) Tests do not really prove the filter is applied on the asset fetch.** The "excludes when latest no longer has the tag" case mocks the second search as empty no matter what query was sent. The "applies the tag filter only to the asset fetch" case asserts the agg has no `match` clause, and that the second query has a `_id` terms filter — it never asserts the tag KQL landed on that second query.~~ Hannah now asserts the exact `prepareQueryDslFilter` clause is absent from the agg and present on the asset fetch.

### Open questions

- ~~Was skipping the `_perform` guard intentional, or just out of scope for this PR?~~ (IGNORED) Out of scope.
- ~~Should the new tests assert the second `search` query contains the tag clause, and drive the exclude case off that query rather than a hardcoded empty mock?~~ (FIXED) Query placement is asserted. Empty-result case left as a thin no-hits → `[]` check.

### Notes for your codebase map

- Prebuilt install review is a two-step ES search: aggregate latest `(rule_id, version)`, then fetch those SOs. Filters applied in step 1 change the meaning of "latest."
- `_review` and `_perform` are not the same source of truth. Review can filter; `SPECIFIC_RULES` install trusts the client version; `ALL_RULES` / status / upgrade use unfiltered `fetchLatestVersions()`.
- Tag facets on the table (`stats.tags`) come from unfiltered latest installable versions via `fetchTagsByVersion`. The row list is what this PR changes.
- `fetchAssetsByVersion` already guards empty `versions` so it does not fetch every SO. `fetchVersionsBySoIds` has no equivalent guard; after this change an empty `soIds` list is less likely because the agg is unfiltered.

### Follow-up Review Activities

1. Risk 1 marked IGNORED — `_perform` hardening is outside this PR's scope. Looked at what would actually fix Risk 2 (weak tests): the exclude case mocks the second search as empty regardless of query, and the query test never asserts the tag KQL is on the asset fetch. The fix is to reuse `prepareQueryDslFilter` and assert that exact clause is absent from the agg call and present (alongside `_id` terms) on the asset-fetch call. The empty-result assertion can stay as a thin "no hits → []" check, but it is not what proves the tag behavior.

- Confirmed Risk 1 is out of scope; struck it and the matching open question.
- Confirmed Risk 2 is a missing positive assertion on `searchMock.mock.calls[1][0].query.bool.filter`.

2. Drafted an inline review comment in Steven's voice for Hannah, anchored on the query-assertion test (`fetch_latest_versions.test.ts` lines 102–109). Posted after approval with the last sentence removed.

- Comment: https://github.com/elastic/kibana/pull/292386#discussion_r4063742339
- Anchored RIGHT lines 102–109 on `abce543`.

3. Sanity-checked Steven's edited comment (thanks + ☝️ pointing at the anchored expects). Diff block unchanged. Prose still matches the two test gaps: empty-mock exclude case, and query asserts that never check the tag KQL.

- Still correct. The ☝️ makes it clearer that the weak asserts are the anchored block, not the first test.

4. Updated risk/question status after the comment went up and Steven edited it. Risk 2 and the remaining open question marked COMMENTED. Branch is still `abce543` with no local test changes. Waiting on Hannah to tighten the query asserts.

- Live comment: https://github.com/elastic/kibana/pull/292386#discussion_r4063742339
- Edited opener/☝️ only; suggested `diff` unchanged and still valid.

5. Steven approved the PR (review 5268700964, 2026-09-21T15:47:18Z) after leaving the test-assert comment. Test gap is still COMMENTED, not resolved in code.

- Approval: https://github.com/elastic/kibana/pull/292386#pullrequestreview-5268700964

6. Rechecked Hannah's follow-up commits (`a152b07`, `105656e`, `6d58638`). The query test now builds `expectedFilterClause` via `prepareQueryDslFilter` and uses `not.toContainEqual` / `toContainEqual` on the agg vs asset-fetch calls. That is the assertion we asked for (cleaner than the suggested `arrayContaining` form). She did not also assert `_id` terms; not needed. First test still mocks an empty second search. Jest: 4/4 passed.

- Risk 2 and the remaining open question marked FIXED.
