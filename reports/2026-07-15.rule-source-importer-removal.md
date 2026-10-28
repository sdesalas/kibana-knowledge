# `ruleSourceImporter` — can we drop it from the bulk import path?

Context: PR [#275695](https://github.com/elastic/kibana/pull/275695) reworks rule
`_import` to use `rulesClient.bulkCreateRules`. banderror flagged the
`ruleSourceImporter` usage in the new bulk path as an "anemic abstraction"
([discussion_r3570203724](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724)):

> I don't think we need this anemic abstraction anymore. It doesn't do much
> and it's time to get rid of it since we're reworking the import logic.

This report walks through what the class actually does, what it costs to keep
it, and what removing it would look like.

---

## What it is

`RuleSourceImporter` lives at
[x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/rule_source_importer/rule_source_importer.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/rule_source_importer/rule_source_importer.ts).
Public surface (`IRuleSourceImporter`):

```typescript
setup(rules: RuleToImport[]): Promise<void>
isPrebuiltRule(rule: RuleToImport): boolean
calculateRuleSource(rule: ValidatedRuleToImport): CalculatedRuleSource
```

It's created once per request from the route
([route.ts:157](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts))
and passed down. Internally it holds four dictionaries populated during
`setup()`:

| Field                       | Populated by                                                                          | Consumed by                             |
| --------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------- |
| `latestPackagesInstalled`   | `ensureLatestRulesPackageInstalled(ruleAssetsClient, context, logger)` (once, cached) | `validateSetupState()` guard            |
| `matchingAssetsByRuleId`    | `ruleAssetsClient.fetchAssetsByVersion({rule_id, version}[])`                         | `calculateRuleSource`                   |
| `availableRuleAssetIds`     | `ruleAssetsClient.fetchLatestVersions` + `fetchDeprecatedRules`                       | `isPrebuiltRule`, `calculateRuleSource` |
| `currentRulesById`          | `prebuiltRuleObjectsClient.fetchInstalledRulesByIds({ruleIds})`                       | `calculateRuleSource`                   |
| `rulesToImport`             | derived from `rules` arg                                                              | `validateRuleInput()` guard             |

`calculateRuleSource` itself is a thin delegate to the pure
[`calculateRuleSourceForImport`](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/calculate_rule_source_for_import.ts)
function.

## What it costs

- One class + interface + mock + dedicated test file
  ([rule_source_importer.test.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/rule_source_importer/rule_source_importer.test.ts),
  ~170 lines, 12 `it` blocks).
- Two runtime guards (`validateSetupState`, `validateRuleInput`) that only
  exist to protect against misuse of the class's stateful contract — pure
  functions wouldn't need them.
- Mock is threaded through every import-related client test
  ([detection_rules_client.change_tracking.test.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.change_tracking.test.ts),
  [detection_rules_client.bulk_import_rules.test.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.bulk_import_rules.test.ts),
  [detection_rules_client.import_rules.test.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.import_rules.test.ts),
  [import_rules.test.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.test.ts)).

## Callers today (import path only)

1. Legacy [`methods/import_rules.ts`](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts)
   — being deleted per banderror's other comment
   ([discussion_r3570078935](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935)).
2. New [`methods/bulk_import_rules.ts`](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_import_rules.ts)
   — the only caller left after that cleanup.

## Overlap with the new bulk path

The new bulk path already runs its own installed-rules lookup for conflict
detection (`findExistingRuleIds`), which builds effectively the same KQL as
`fetchInstalledRulesByIds`:

```typescript
// bulk_import_rules.ts findExistingRuleIds:
alert.attributes.params.ruleId: ("id1" OR "id2" ...)

// prebuilt_rule_objects_client.ts fetchInstalledRulesByIds:
alert.attributes.params.ruleId:(id1 or id2 ...)
```

Same index, same set of rule IDs, different projection:
- `findExistingRuleIds` returns `Set<ruleId>` (conflict detection only).
- `fetchInstalledRulesByIds` returns full `RuleResponse[]` (needed by
  `calculateRuleSourceForImport` to diff against the base asset).

Two ES round-trips per import batch, on the same filter. Collapsible.

## Options

### A. Do nothing this PR

Leave `ruleSourceImporter` where it is. Address banderror by (a) explaining
we've narrowed the caller list to just the bulk path, and (b) parking removal
as a follow-up.

- Pros: zero risk; keeps this PR focused on the perf change.
- Cons: doesn't resolve his comment; the abstraction remains with only one
  caller, which is exactly the shape he called out.

### B. Inline the three fetches into the bulk method

Delete the class + interface + mock + dedicated test. Move the four setup
steps into `bulkImportRules` (or a small non-exported helper in the same
file), and pass the resulting maps directly into `calculateRuleSourceForImport`.

Rough shape:

```typescript
const { matchingAssetsByRuleId, availableRuleAssetIds } = await loadPrebuiltAssets({
  ruleAssetsClient,
  rules,
});

// Reuse the existing conflict lookup — but return full rules, not just IDs.
const existingRulesById = await findExistingRulesById({ rulesClient, ruleIds });

// ... later, per rule:
const { ruleSource, immutable } = calculateRuleSourceForImport({
  importedRule: rule,
  currentRule: existingRulesById[rule.rule_id],
  prebuiltRuleAssetsByRuleId: matchingAssetsByRuleId,
  isKnownPrebuiltRule: availableRuleAssetIds.has(rule.rule_id),
});
```

Also folds the two current ES round-trips (conflict lookup + installed rules
by id) into one — small perf win, aligned with the PR's goal.

- Pros: kills the abstraction, dedupes an ES call, removes two runtime
  guards, shrinks test surface (~170 lines + mock + 4 mock wire-ups).
- Cons: bigger diff on this PR; `ensureLatestRulesPackageInstalled` moves to
  the route or bulk method — one more thing that path is responsible for.
  Test mocks for four client tests need reworking to expose
  `prebuiltRuleAssetsClient` / `prebuiltRuleObjectsClient` fixtures directly.
- Risk: medium. The refactor is mechanical, but the class is currently a
  cache for the whole request — inlining means we recompute it per batch
  unless we hoist the setup back to the route handler.

### C. Partial removal — keep pure helpers, drop the class

Extract `fetchAvailableRuleAssetIds`, `fetchMatchingAssets`, and a new
`fetchInstalledRulesByIds` wrapper as standalone async functions. Delete
`RuleSourceImporter`. `bulkImportRules` calls the pure helpers directly.
Route still calls `ensureLatestRulesPackageInstalled` once, up-front.

- Pros: same benefits as (B) without the "recompute per batch" concern; the
  route owns the once-per-request work explicitly.
- Cons: still a big-ish diff; `route.ts` grows slightly.
- This is what I'd default to if we take on the removal.

## Recommendation

Option **C** if we have time and appetite in this PR; otherwise **A** with a
short reply to banderror pointing out that (1) once the legacy path is gone,
`ruleSourceImporter` has one caller, and (2) we'll fold it into the bulk
path in a follow-up, tracked as a TODO in `bulk_import_rules.ts`.

The main reason not to do (C) right now is scope creep — this PR is already
touching the feature flag, the constants rename, `changeTracking` plumbing,
and the KQL escaping tests. Piling a class removal + test-fixture rewiring on
top increases review surface and reviewer round-trips. If banderror is OK
with (A), do (A) here and (C) as a small follow-up PR.

## Open question

banderror's comment landed on `line: 108` of `bulk_import_rules.ts`, which is
literally `await ruleSourceImporter.setup(rules);`. The three interpretations
that fit "anemic abstraction":

1. The `ruleSourceImporter` **class** itself (this report's assumption).
2. The `BulkImportRulesResult` wrapper (`{ responses: [...] }`) — trivial
   one-property object; but that's on line 62, not 108.
3. The `PreparedImport` interface — also not on 108.

Confirmed with user (`sdesalas`): interpretation (1) is correct.
