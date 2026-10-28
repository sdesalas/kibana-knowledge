---
name: Address banderror PR comments
overview: "Address banderror's outstanding review comments on PR #275695: remove the feature flag + legacy import path, split/rename batching constants, move `changeTracking` construction into the route handler, add KQL-escaping regression tests, and remove `ruleSourceImporter` in favour of pure helpers (Option C from [rule-source-importer-removal.md](../reports/rule-source-importer-removal.md))."
todos:
  - id: flag
    content: Remove `bulkImportRulesEnabled` from experimental_features.ts
    status: completed
  - id: constants
    content: "Rename constants: drop RULE_MANAGEMENT_IMPORT_BATCH_SIZE; add RULE_IMPORT_BULK_CREATE_BATCH_SIZE and RULE_IMPORT_BULK_UPDATE_CONCURRENCY"
    status: completed
  - id: import_rules
    content: Remove legacy branching from logic/import/import_rules.ts, keep bulk path only
    status: completed
  - id: client_consolidate
    content: Merge detectionRulesClient.bulkImportRules into importRules; delete legacy methods/import_rules.ts; rename methods/bulk_import_rules.ts to methods/import_rules.ts
    status: completed
  - id: change_tracking_route
    content: "Move full changeTracking (incl. action: ruleImport) construction into route.ts; stop hardcoding action in the client method"
    status: completed
  - id: kql_tests
    content: Add regression tests for rule_id values with KQL metacharacters and keyword tokens
    status: completed
  - id: test_updates
    content: Update / rename affected test files to match new method name and route-provided action
    status: completed
  - id: rsi_extract_helpers
    content: Extract pure helpers (fetchAvailableRuleAssetIds, fetchMatchingAssets, fetchInstalledRulesByIds wrapper) from rule_source_importer.ts into a new module
    status: completed
  - id: rsi_route_ensure_package
    content: Move ensureLatestRulesPackageInstalled call into the import route handler (once per request)
    status: completed
  - id: rsi_rewire_bulk
    content: Rewire methods/import_rules.ts to call pure helpers directly and feed calculateRuleSourceForImport; drop the ruleSourceImporter arg from ImportRulesArgs
    status: completed
  - id: rsi_delete_class
    content: Delete RuleSourceImporter class + IRuleSourceImporter interface + mock + rule_source_importer.test.ts; fix all remaining references in tests
    status: completed
  - id: replies
    content: "Draft replies for the still-open banderror threads (#3570188905 quality, #3570233773 inner batching, #3570171000 batch size, #3570087843 changeTracking params)"
    status: completed
  - id: verify
    content: Run eslint, type_check (security_solution project), and the touched jest suites
    status: completed
isProject: false
---


## Comments being addressed

Concrete edits (uncontested + accepted by you):

### 1. Feature flag removal
- **banderror** ([#3569884511](https://github.com/elastic/kibana/pull/275695#discussion_r3569884511) on `common/experimental_features.ts:33`):
  > I think a feature flag would be an overkill for this work - no multiple PRs are needed to resolve the issue. My suggestion is to remove it and simply change the existing implementation of the import logic to use the `bulkCreate` method.
  >
  > Let me know if I'm missing something you had in mind.
- **banderror follow-up** ([#3586442017](https://github.com/elastic/kibana/pull/275695#discussion_r3586442017)):
  > @sdesalas As a reviewer, I will certainly test the changes locally once the implementation looks good enough.
  >
  > Are you saying you would still be concerned about breaking the import functionality by this PR beyond your own and my local testing? If so:
  >
  > - First, I think a feature flag wouldn't make it any safer
  > - Feel free to request extra regression testing from @pborgonovi
  > - Use your agent to audit the current integration test coverage of the rule import API endpoint. In `main`. If any tests are missing, please add them in a separate PR.
  >
  > Having a comprehensive integration test suite should be (and has always been) our primary way to not lose confidence when changes are not trivial.

### 2. Legacy code path removal
- **banderror** ([#3570078935](https://github.com/elastic/kibana/pull/275695#discussion_r3570078935) on `logic/import/import_rules.ts:58`):
  > No need to have the feature flag and to switch between the legacy and the optimized code paths. Let's remove all the legacy / outdated / non-optimized code and the branching logic.
- **sdesalas reply** ([#3578328198](https://github.com/elastic/kibana/pull/275695#discussion_r3578328198)): "Ok"

### 3. Consolidate `bulkImportRules` into `importRules` on the client
- **banderror** ([#3570058501](https://github.com/elastic/kibana/pull/275695#discussion_r3570058501) on `detection_rules_client/detection_rules_client.ts:275`):
  > Why are we introducing a new method of the detection rules client + a new `bulkImportRules` function, instead of modifying the existing `importRules` method and corresponding function?
- **sdesalas reply** ([#3578326161](https://github.com/elastic/kibana/pull/275695#discussion_r3578326161)):
  > This is related to keeping the previous functionality running side by side instead of replacing it. Since we're replacing it I dont mind reusing the same method.

### 4. Split/rename batch constants
- **banderror** ([#3552390865](https://github.com/elastic/kibana/pull/275695#discussion_r3552390865) on `api/constants.ts:18`):
  > **Domain term: `RULE_MANAGEMENT_IMPORT_BATCH_SIZE` reused for an unrelated concern.** This constant is documented as "Batch size for the legacy per-rule import loop" and is consumed that way in `import_rules.ts`, but `methods/bulk_import_rules.ts` also reuses it as the `pMap` concurrency bound for the new bulk path's overwrite branch (a value that has nothing to do with the legacy loop's chunk size). The comment here acknowledges the dual use ("also bounds overwrite-branch concurrency") but a single constant serving two independently-tunable knobs across two different code paths is the kind of legacy-notation reuse the domain calls out to avoid on new bulk work — a dedicated `RULE_MANAGEMENT_BULK_IMPORT_OVERWRITE_CONCURRENCY` (or similar) would let the two be tuned independently and avoid confusing a future reader of the legacy loop.
  >
  > -----
  >
  > I agree with AI here, and my concrete suggestion would be to:
  >
  > 1. Remove all the legacy import code - no need to keep it in main.
  > 2. Have two constants for the new optimized code: `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` and `RULE_IMPORT_BULK_UPDATE_CONCURRENCY` - concrete naming could be different

### 5. Move `changeTracking` (including `action`) into route handler
- **banderror** ([#3570263078](https://github.com/elastic/kibana/pull/275695#discussion_r3570263078) on `bulk_import_rules.ts:190`):
  > The current code makes it unclear where which parts of the `changeTracking` payload should be specified. I think the whole payload, including the `action`, should be specified in the route handler. Please refer to rule installation.

### 6. Adversarial `rule_id` KQL regression tests
- **banderror** ([#3552390871](https://github.com/elastic/kibana/pull/275695#discussion_r3552390871) on `bulk_import_rules.ts:280`):
  > `findExistingRuleIds` hand-builds a KQL filter (`alert.attributes.params.ruleId: ("id1" OR "id2" ...)`) using only `escapeQuotes` from `@kbn/es-query`, which escapes `\` and `"` but not `()`, `*`, `<`, `>`, or the `and`/`or`/`not` keywords (the fuller `escapeKuery` does that). `rule_id` (`RuleSignatureId`) is an unconstrained `z.string()` with no pattern restriction, so an imported rule's `rule_id` can legally contain KQL metacharacters. Because the value stays wrapped in `"..."` and `escapeQuotes` neutralizes embedded quotes, breaking out of the quoted literal is prevented for this specific call site - but it's a bespoke, unescaped-beyond-quotes filter-string builder with no test covering a `rule_id` containing special characters (parens, `*`, ` or `). Given the sibling helper in this same domain (`enrich_filter_with_rule_ids.ts`) also builds an OR'd KQL list without full escaping, this pattern of ad-hoc string-built filters recurs and is worth hardening or at least covering with a regression test for adversarial `rule_id` values.
- **sdesalas reply** ([#3578232093](https://github.com/elastic/kibana/pull/275695#discussion_r3578232093)):
  > Thanks, I will add some extra tests here I think. I considered fully escaping but did not see the point:
  >
  > The additional characters `()`, `*`, `<`, `>` and keywords will be enveloped inside the quotes `"` (since these last ones _are_ escaped, along with the escape character itself `\`). So at worst what we get is someone intentionally injecting some characters into a `rule_id` (like `"abc123-def56*&and\\blahblah"` and that incorrectly created `rule_id` not matching with a genuine one inside ES. This is a non-issue AFAICT.
  >
  > In addition, as you pointed out, not fully escaping KQL seems to be the convention used by most other sibbling calls that perform KQL filters.
  >
  > All in all, I rather just add extra tests to confirm my expectations instead of complicating the logic unnecessarily.

### 7. `ruleSourceImporter` removal from bulk import path
- **banderror** ([#3570203724](https://github.com/elastic/kibana/pull/275695#discussion_r3570203724) on `bulk_import_rules.ts:108`):
  > I don't think we need this anemic abstraction anymore. It doesn't do much and it's time to get rid of it since we're reworking the import logic.
- **sdesalas reply** ([#3578382792](https://github.com/elastic/kibana/pull/275695#discussion_r3578382792)): "Thanks. On it."
- Approach: **Option C** from the [side report](../reports/rule-source-importer-removal.md) — extract pure helpers, drop the wrapper class. Details below under "Files that change".

---

Held for banderror clarification (not in this plan):

### A. Code quality / decompose the bulk method body
- **banderror** ([#3570188905](https://github.com/elastic/kibana/pull/275695#discussion_r3570188905) on `bulk_import_rules.ts:87`):
  > It doesn't seem this code matches the bar of a quality code in our area. Please put a bit more effort in making it readable and decomposed into clear single-purpose functions. If this comment is too vague, I'm happy to elaborate.
- **sdesalas reply** ([#3578367611](https://github.com/elastic/kibana/pull/275695#discussion_r3578367611)):
  > Yes this comment is pretty vague so would appreciate some examples. There are a few single purpose functions in there. Not too many, not too few (in my eyes). I normally go for "easy to read", and would be happy to hear specifics since "quality of code" is highly subjective.

### B. Inner batching in `findExistingRuleIds`
- **banderror** ([#3570233773](https://github.com/elastic/kibana/pull/275695#discussion_r3570233773) on `bulk_import_rules.ts:125`):
  > The way how it's written may cause ES to return errors if two conditions apply:
  >
  > - ES runs on low-spec hosts with low amount of RAM
  > - The number of `ruleIds` is too high for that amount of RAM
  >
  > In this case ES would return a "too many clauses" error.
  >
  > I think we could mitigate this by batching the calls inside of this `findExistingRuleIds` function, with a batch size that always works. WDYT?
- **sdesalas reply** ([#3578411889](https://github.com/elastic/kibana/pull/275695#discussion_r3578411889)):
  > Good catch, but I think this is already done. `findExistingRuleIds` runs once per import batch, and batches are capped at `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE` which will be somewhere 200-500, so the OR-list never exceeds 500 clauses.
  >
  > That's below the [`max_clause_count`](https://github.com/elastic/elasticsearch/blob/1b1acdd6b81464d626ce17c6899ecf6d38f819e3/server/src/main/java/org/elasticsearch/search/SearchUtils.java#L17-L36) floor (1024) even on low-heap hosts, so it shouldn't trip "too many clauses" regardless of RAM. Also, vCPU factors into the same calculation (see related [investigation](https://github.com/elastic/kibana/pull/275695#discussion_r3504900068)), however in practice even 5000 clauses would be ok for most RAM/vCPU combinations.
  >
  > Since this is already dealt with by existing batching. I think I'd rather not add a second layer of batching inside `findExistingRuleIds`, it'll just create unnecessary complexity. Happy to add a unit test pinning the clause count, though, if that'd give more confidence. It'll take care of possible future changes to the way batching works, in case someone sets an outer batch size greater than 1024.

### C. Batch size = 200 vs alternatives
- **banderror** ([#3570171000](https://github.com/elastic/kibana/pull/275695#discussion_r3570171000) on `api/constants.ts`):
  > Why is it 200, and not 100, 250, or 500? Have we done performance testing with different batch sizes to be able to select the optimal value?
- **sdesalas reply** ([#3571238617](https://github.com/elastic/kibana/pull/275695#discussion_r3571238617)):
  > Hi @banderror.
  >
  > Unfortunately doing all this performance testing is pretty time consuming. I've done batches of 200, 350 and 500. See comment below:
  >
  > https://github.com/elastic/kibana/pull/275695#issuecomment-4958201347

### D. "Other change tracking parameters"
- **banderror** ([#3570087843](https://github.com/elastic/kibana/pull/275695#discussion_r3570087843) on `route.ts:192`):
  > What about passing other change tracking parameters?
- **sdesalas reply** ([#3578344451](https://github.com/elastic/kibana/pull/275695#discussion_r3578344451)):
  > We usually pass the `action` as deep in the stack as possible. To avoid over-handling it. In this case inside `importRules`/`importRule`. We dont really have other metadata to inject at this point. Were you thinking something specific related to rule imports? Maybe the file name?

## Files that change

### Feature flag + legacy removal + constants
- [x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts](../../x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts) — remove `bulkImportRulesEnabled` entry + doc block
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/constants.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/constants.ts) — drop `RULE_MANAGEMENT_IMPORT_BATCH_SIZE`; rename `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE` → `RULE_IMPORT_BULK_CREATE_BATCH_SIZE`; add `RULE_IMPORT_BULK_UPDATE_CONCURRENCY` (initially the same value as the current overwrite concurrency, 50)
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts) — remove `experimentalFeatures` branching + legacy chunk loop; keep only the bulk path, calling `detectionRulesClient.importRules`

### Client consolidation
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts) — delete `bulkImportRules` method wrapper; rewire `importRules` to call the (renamed) bulk implementation and return `BulkImportRulesResult`
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts) — drop `bulkImportRules` from the interface; change `importRules` signature/return type to the bulk one; alias `BulkImportRulesArgs` goes away
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_import_rules.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/bulk_import_rules.ts) — file renamed to `methods/import_rules.ts`; stop injecting `action` (route does it); stop importing `RULE_MANAGEMENT_IMPORT_BATCH_SIZE` (use new names); no longer accepts a `ruleSourceImporter` — takes pre-fetched prebuilt context instead (see below)
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules.ts) — delete (legacy per-rule method)

### Route handler (change tracking + prebuilt context)
- [x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts):
  - Stop reading `experimentalFeatures` and building `ruleSourceImporter`
  - Build the full `changeTracking` payload (including `action: SecurityRuleChangeTrackingAction.ruleImport`) here
  - Call `ensureLatestRulesPackageInstalled` once per request (moved out of `RuleSourceImporter.setup`)

### Option C — `ruleSourceImporter` removal
- New file `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/fetch_prebuilt_import_context.ts` — pure helpers extracted from `rule_source_importer.ts`:
  ```typescript
  export interface PrebuiltImportContext {
    matchingAssetsByRuleId: Record<string, PrebuiltRuleAsset>;
    availableRuleAssetIds: Set<string>;
    installedRulesById: Record<string, RuleResponse>;
  }

  export const fetchPrebuiltImportContext = async ({
    rules, ruleAssetsClient, ruleObjectsClient,
  }): Promise<PrebuiltImportContext>;
  ```
  Called once by the client method with a batch's rules. Internally reuses the same three fetches (`fetchLatestVersions` + `fetchDeprecatedRules`, `fetchAssetsByVersion`, `fetchInstalledRulesByIds`).
- `methods/import_rules.ts` (formerly `bulk_import_rules.ts`) — uses `fetchPrebuiltImportContext` and calls [`calculateRuleSourceForImport`](../../x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/calculate_rule_source_for_import.ts) directly. `findExistingRuleIds` is dropped: conflict detection derives from `installedRulesById` (single ES round-trip for both concerns).
- Delete:
  - `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/rule_source_importer/rule_source_importer.ts`
  - `.../rule_source_importer/rule_source_importer_interface.ts`
  - `.../rule_source_importer/rule_source_importer.mock.ts`
  - `.../rule_source_importer/rule_source_importer.test.ts`
  - the `index.ts` re-export in that folder if it exists
- All import-related tests lose the `ruleSourceImporterMock` fixture and instead mock the new `fetchPrebuiltImportContext` (small `jest.mock(...)` shim). Affected: `detection_rules_client.change_tracking.test.ts`, `detection_rules_client.bulk_import_rules.test.ts` (renamed), `detection_rules_client.import_rules.test.ts`, `logic/import/import_rules.test.ts`.

### Tests
- Rename `detection_rules_client.bulk_import_rules.test.ts` → `detection_rules_client.import_rules.test.ts`
- Update `logic/import/import_rules.test.ts`: drop the `bulkImportRulesEnabled` describe block; keep chunking coverage under the new method name
- Update `detection_rules_client.change_tracking.test.ts`: caller no longer supplies `action` (route does); assert `action` on the outgoing `bulkCreateRules` call still equals `ruleImport`
- New KQL regression tests (once helpers are extracted, these live where the conflict-detection filter is built — probably alongside `fetchPrebuiltImportContext` or in the client method test): `rule_id` values containing `"`, `\`, `(`, `)`, `*`, `<`, `>`, and the tokens `and`/`or`/`not` — asserting the rule is found/created correctly and does not blow up `findRules`

## Reply drafts (for the ones still open with banderror)

### To #3570188905 (code quality / decompose the bulk method)

> The consolidated `importRules` (formerly `bulkImportRules`) is now decomposed into four small single-purpose helpers, each testable in isolation:
>
> - `fetchPrebuiltImportContext` — single Promise.all that returns `{ matchingAssetsByRuleId, availableRuleAssetIds, installedRulesById }`. Also replaces the previous `findExistingRuleIds` round-trip (conflict detection now piggybacks on the same map).
> - `prepareRules` — per-rule prep loop: default-version, ML authz, exception refs, `calculateRuleSourceForImport`.
> - `overwriteExisting` — `pMap` per-rule fallback for the overwrite branch.
> - `buildBulkInputs` — pure conversion from prepared rules to `bulkCreateRules` inputs, keyed by uuid so per-row errors round-trip back to their `rule_id`.
>
> The classification block (conflict / overwrite / bulk-create) is left inline in the top-level function since it's what the function *is*. If there's a specific chunk you'd still like broken up further, happy to iterate.

### To #3570233773 (inner batching in `findExistingRuleIds`)

> `findExistingRuleIds` is now gone — conflict detection reuses `installedRulesById` from `fetchPrebuiltImportContext`, so there is no second ES round-trip. The single `findRules` call inside `fetchPrebuiltImportContext` is still bounded by `RULE_IMPORT_BULK_CREATE_BATCH_SIZE` (currently 100, hard cap well under ES's 1024 `max_clause_count` floor), so "too many clauses" still cannot trigger regardless of host size. Happy to add a unit test pinning the clause count if you want it as a guard against future changes to the outer batch size.

### To #3570171000 (batch size = 200 vs alternatives)

> The value is 100 in this PR now. Performance data across 200 / 350 / 500 is in [this comment](https://github.com/elastic/kibana/pull/275695#issuecomment-4958201347). If you'd like a re-run at 100 vs 250 I can schedule it, otherwise happy to keep 100 as the initial ship value — it leaves headroom for `max_clause_count`, keeps alerting-plugin bulk memory low, and can be tuned via the constant later.

### To #3570087843 ("other change tracking parameters")

> The whole `changeTracking` payload is now assembled in `route.ts` (`{ action: ruleImport, metadata: { bulkCount } }`) and passed through `logic/import/import_rules.ts` → `detectionRulesClient.importRules` → `rulesClient.bulkCreateRules` verbatim. `action` is no longer hardcoded inside the client method. Are you thinking of anything specific beyond `action` + `metadata.bulkCount` — e.g. an import-file identifier / user attribution — that we should be adding here?

## Validation

- `node scripts/eslint --fix $(git diff --name-only)`
- `node scripts/type_check --project x-pack/solutions/security/plugins/security_solution/tsconfig.json`
- `node scripts/jest x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.import_rules.test.ts`
- `node scripts/jest x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.test.ts`
- `node scripts/jest x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.change_tracking.test.ts`
- `node scripts/jest x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/fetch_prebuilt_import_context.test.ts` (new)
