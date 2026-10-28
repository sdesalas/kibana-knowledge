# Prebuilt tag filter: 8.19 never had the stale-version bug

- **Date:** 2026-09-22
- **Area:** Security Solution — Detection Engine / prebuilt rule installation `_review`
- **Issue:** [#290911](https://github.com/elastic/kibana/issues/290911)
- **Status:** 8.19 does not need the fix. [#292509](https://github.com/elastic/kibana/pull/292509) can stay closed.

---

## Summary

When the Add Elastic Rules table is filtered by a tag, `_review` asks `fetchLatestVersions` which rules to show. That function runs two Elasticsearch searches. The first decides which version of each rule is the latest. The second loads those versions and returns them to the UI.

On `main`, before [#292386](https://github.com/elastic/kibana/pull/292386), the tag filter was applied on the first search. This is the bug that was fixed, if we filter by **both** latest rule versions and a set of tags, we will inevitably get some older versions.

```typescript
// Search 1. This is supposed to find the latest version of each rule.
// The tag filter is passed in here, so Elasticsearch throws away newer
// assets that no longer have the tag before top_hits runs.
const latestVersionSpecifiers = await fetchLatestVersionSpecifiers(
  savedObjectsClient,
  ruleIds,
  filter // <-- tag filter, too early
);


// Search 2. 
// no filter here   ¯\_(ツ)_/¯
const latestVersions = await fetchVersionsBySoIds(savedObjectsClient, soIds, sort); 

```

In other words, [#247375](https://github.com/elastic/kibana/pull/247375) introduced server-side tag filtering and put the tag filter on the first search (incorrectly). If version 10 had renamed `Data Source: AWS` to `Platform: AWS`, the table showed version 9. Installing that version made Rule Updates offer an upgrade straight away. [#292386](https://github.com/elastic/kibana/pull/292386) fixed this on `main` on 21 September by moving the tag filter onto the second search, after the real latest version had already been chosen ([fixed code](https://github.com/elastic/kibana/blob/baddd143b7b0abe16856e4644ada7b5d84c3ad7e/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_versions.ts#L56-L175)).

## The backport is different

Interestingly, the 8.19 backport of that same change, [#249475](https://github.com/elastic/kibana/pull/249475), never put the tag filter on the first search. It picks the latest version with no tag clause, then drops the rule if that latest version does not have the tag. 8.19 already behaves the way [#292386](https://github.com/elastic/kibana/pull/292386) does, so the backport [#292509](https://github.com/elastic/kibana/pull/292509) is not needed.

There is one more related PR that made changes to this search: [#266112](https://github.com/elastic/kibana/pull/266112). But it did not move the filter. It left the tag filter on the first search and only changed it from a structured filter object into a KQL string. That landed on `main` on 29 May 2026 for 9.5, marked `backport:skip`, so it never went to 8.19 either.

---

## What the fix looks like on main

[#292386](https://github.com/elastic/kibana/pull/292386), commit [`baddd143`](https://github.com/elastic/kibana/commit/baddd143b7b0abe16856e4644ada7b5d84c3ad7e).

The first search now only chooses the latest version. The tag filter is a parameter of the second search, which loads those latest saved objects and then keeps the ones that still match.

```typescript
// Search 1. Tags are gone. This is the real latest version per rule.
const latestVersionSpecifiers = await fetchLatestVersionSpecifiers(
  savedObjectsClient,
  ruleIds
);

query: {
  bool: prepareQueryDslFilter({ ruleIds, excludeRuleIds: deprecatedRuleIds }),
},
```

```typescript
// Search 2. Load those latest ids, then apply the tag.
// If the latest asset lost the tag, the rule disappears.
// The older asset is not offered instead.
const latestVersions = await fetchVersionsBySoIds(savedObjectsClient, soIds, sort, filter);

const filterClauses = [{ terms: { _id: soIds } }];
if (additionalFilter) {
  filterClauses.push(...prepareQueryDslFilter({ filter: additionalFilter }).filter);
}
```

| | First search (which version?) | Second search (load it) |
|---|---|---|
| [#247375](https://github.com/elastic/kibana/pull/247375) through [#266112](https://github.com/elastic/kibana/pull/266112) | rule id and the tag | whatever the first search kept |
| [#292386](https://github.com/elastic/kibana/pull/292386) | rule id only | the true latest version, then the tag |

Broken query, with the tag inside the aggregation: [`e1d9b596` `fetch_latest_versions.ts`](https://github.com/elastic/kibana/blob/e1d9b5969dfdaddbbd922b48742181e1de23275a/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_versions.ts#L54-L169). The tag term itself is built in [`utils.ts`](https://github.com/elastic/kibana/blob/e1d9b5969dfdaddbbd922b48742181e1de23275a/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/utils.ts#L39-L47).

---

## What 8.19 has been doing since January

[#249475](https://github.com/elastic/kibana/pull/249475), commit [`7c6119bf`](https://github.com/elastic/kibana/commit/7c6119bf34eee7be4ea8b525db952eb7d6a5ce83), merged 22 January 2026. [`fetch_latest_versions.ts` on 8.19](https://github.com/elastic/kibana/blob/8.19/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_versions.ts#L62-L165) has one search, and the tag is not part of it. The only filter on that search is an optional list of rule ids. After the latest version is chosen, `filterRuleVersions` checks the tags in memory.

```typescript
savedObjectsClient.find({
  type: 'security-rule',
  filter: kqlFilter, // rule ids only, never tags
  aggs: {
    rules: {
      terms: { field: 'security-rule.attributes.rule_id' },
      aggs: {
        latest_version: {
          top_hits: {
            size: 1,
            sort: [{ 'security-rule.version': 'desc' }],
          },
        },
      },
    },
  },
});

const filteredVersions = filterRuleVersions(latestVersions, filter);
```

```typescript
const tagValues = filter.fields.tags?.include?.values;
if (tagValues?.length) {
  const matchesAllTags = tagValues.every((tag) => versionInfo.tags.includes(tag));
  if (!matchesAllTags) return false;
}
```

Checked on a local 8.19 after the prebuilt rules were uninstalled. 206 assets have `Data Source: AWS` on some version. 51 of those dropped the tag on the latest version. `_review` filtered by that tag returned the other 155, each at its real latest version, and none of the 51.

[#292509](https://github.com/elastic/kibana/pull/292509) tried to backport [#292386](https://github.com/elastic/kibana/pull/292386) anyway. The production file conflicted and was left unchanged. The test that did get added calls `savedObjectsClient.search` and passes a KQL string, which is `main`'s API. 8.19 calls `savedObjectsClient.find` and filters with `filterRuleVersions`.
