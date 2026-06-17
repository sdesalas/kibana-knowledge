# `bulkValidateActions` design tradeoffs

**Subject:** Phase B1 (`prepareRule.validateActions`) in
`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`,
calling `validateActions` per-rule via `pMap` with concurrency 50.

**Issue:** [#273680](https://github.com/elastic/kibana/issues/273680)

**Question:** how do we eliminate the N×`listTypes()` + N×`getBulk()` overhead during bulk rule operations?

**Prior art:** commit [`d0483a2`](https://github.com/elastic/kibana/commit/d0483a20df2fa7e96cb7ecff036656185b69147f) ("Add performance improvements") implemented a prefetch + optional `preFetchedActions` pass-through across four files. It worked but introduced an optional-parameter pattern that didn't extend to `listTypes` and added two code paths to every validator. Captured below as **Option D**.

## What `validateActions` actually does

Looking at `rules_client/lib/validate_actions.ts`, the function mixes two kinds of work:

1. **External IO**:
   - `actionsClient.getBulk({ ids })` — connector SOs (per-rule action IDs).
   - `actionsClient.listTypes({})` — every registered connector type. Identical for every rule.
2. **Pure in-memory checks** against the fetched data + the rule itself:
   - Duplicate UUIDs across actions/systemActions
   - Missing-secret connectors (with `allowMissingConnectorSecrets` branching)
   - Endpoint-security connectors are rejected
   - Workflows-only connectors are rejected
   - Action groups exist on the ruleType
   - Per-action frequency vs rule-level `notifyWhen`/`throttle`
   - Per-action throttle ≥ schedule interval
   - `alertsFilter` shape (query/timeframe, hours, days, AAD support)

For 1000 rules: 1000 `listTypes()` (identical), and 1000 `getBulk()` calls where the unique connector IDs across the full batch are typically O(10) — same Slack/email/PagerDuty connector reused across every rule.

## Where the same problem shows up across the rules client

Before locking in a design, here's the actual blast radius across bulk methods.

### Hot spots (N × `getBulk` + N × `listTypes`)

1. **`bulkCreateRules`** → `prepareRule` → `validateActions`.
   Per-rule, inside `pMap` with concurrency 50 (Phase B1).
   `bulk_create/utils.ts:55`.

2. **`bulkEditRules`** (when an operation has `field: 'actions'`) → `getUpdatedAttributesFromOperations` → `validateActions`.
   Per-rule, inside `pMap` with concurrency 50 in `rules_client/common/bulk_edit/bulk_edit_rules_occ.ts:88`.
   `bulk_edit/bulk_edit_rules.ts:290`.

3. **`bulkEditRules`** legacy-frequency fallback → `attemptToMigrateLegacyFrequency` → `validateActions`.
   Fires only when the first `validateActions` throws on legacy rule-level frequency params. Same per-rule path.
   `bulk_edit/bulk_edit_rules.ts:469`.

4. **`bulkMigrateLegacyActions`** (called by bulkEdit before the per-rule pMap) → `transformAndDeleteLegacyActions` → `validateTransformedActions` → `validateActions`.
   Per legacy-action SO, sequential `asyncForEach`. SIEM-only path that runs once per bulkEdit when legacy action sidecars exist.
   `siem_legacy_actions/transform_and_delete_legacy_actions.ts:178`.

### A second N-call problem next door: system actions

`validateAndAuthorizeSystemActions` (`server/lib/validate_authorize_system_actions.ts`) is called per-rule alongside `validateActions` in:

- `bulk_create/utils.ts:56` (`prepareRule`)
- `bulk_edit/bulk_edit_rules.ts:281`

And it does **the same shape of work**:

- `actionsClient.getBulk({ ids })` — system action connector SOs.
- `actionsClient.listTypes({ includeSystemActionTypes: true })` — same superset of types, just with the system-action flag set.

### A third one: `denormalizeActions`

Right after validation, `prepareRule` calls `extractReferences` → `denormalizeActions` (`rules_client/lib/denormalize_actions.ts:25`), which does *another* `actionsClient.getBulk` per rule. Same connector IDs, freshly fetched again, just to compute action refs.

So the per-rule cost in `prepareRule` is actually **5** `actionsClient` calls today, not 2:

| Source | `getBulk` | `listTypes` |
|---|---|---|
| `validateActions` | 1 | 1 |
| `validateAndAuthorizeSystemActions` | 1 | 1 (with `includeSystemActionTypes: true`) |
| `denormalizeActions` (via `extractReferences`) | 1 | — |

For 1000 rules: ~5000 `actionsClient` calls when one shared `getBulk` (union of all IDs) and one shared `listTypes({ includeSystemActionTypes: true })` would suffice. A `listTypes` with `includeSystemActionTypes: true` returns a superset; both validators can share it with a client-side filter.

### Bulk methods that are unaffected

- `bulkEnableRules`, `bulkDisableRules`, `bulkDeleteRules`, `bulkEditRuleParams`, `bulkMuteUnmuteAlerts`, `bulkUntrack`, `bulkGetRules`, `aggregate` — none call `validateActions` or `validateAndAuthorizeSystemActions`. They either don't touch action data, or operate on already-validated rules.
- `cloneRule` doesn't call `validateActions` either — relies on the source rule's prior validation.

### Single-rule callers (out of scope for the perf fix)

- `createRule`, `updateRule` — one call each, no bulk amplification.
- `transformAndDeleteLegacyActions` is called from both `bulkMigrateLegacyActions` (bulk path, item 4 above) and from per-rule paths via `format_legacy_actions.ts`. The bulk one is the hot path.

### What this means for the design

The fix has to land in two methods, not one: `bulkCreateRules` and `bulkEditRules`. And the same family of fix wants to apply to both `validateActions` and `validateAndAuthorizeSystemActions`. Whichever option we pick should be evaluated against that — a clean shape for `bulkCreate` only that doesn't extend to `bulkEdit` or to system actions is a half-fix.

## Original proposal (from the issue)

> Introduce a dedicated `bulkValidateActions` function (not a patch on the existing `validateActions`) designed for bulk operations:
>
> 1. Accepts all rules' action data at once.
> 2. Collects all unique connector IDs across all rules, performs a single `getBulk()`.
> 3. Calls `listTypes()` once.
> 4. Runs per-rule validation logic in-memory against the pre-fetched data.
> 5. Returns a per-rule result (pass/error) that the caller can use to include or exclude individual rules.
>
> This keeps `validateActions` untouched for single-rule paths (create, update, clone) while giving bulk paths a purpose-built alternative with the same validation semantics but fewer round-trips.
>
> **Where it fits in `bulkCreateRules`**
>
> Currently `prepareRule` calls `validateActions` as one of several per-rule steps. With `bulkValidateActions`, the bulk path would:
>
> 1. Run `bulkValidateActions` once for the whole batch **before** entering `pMap`.
> 2. Exclude failed rules from the prepare step (or pass pre-validated connector context to `prepareRule`).
> 3. `prepareRule` would skip the per-rule `validateActions` call since it's already been handled.
>
> **Expected impact**
>
> - Eliminates ~999 redundant `listTypes()` calls per batch of 1000 rules.
> - Reduces `getBulk()` calls from N (one per rule) to 1 (one for all unique connector IDs).
> - Reduces Phase B1 latency, especially in deployments where SO reads have higher latency.

The discovery in [Where the same problem shows up across the rules client](#where-the-same-problem-shows-up-across-the-rules-client) widened the scope after this proposal was written: the same shape of redundancy also exists in `validateAndAuthorizeSystemActions` and `denormalizeActions`, and in `bulkEditRules`. That doesn't invalidate the proposal — a new bulk function is still one of the four credible designs — but it does mean the "Acceptance criteria" need to acknowledge whether system actions, `denormalizeActions`, and `bulkEditRules` get coordinated treatment or are deferred.

## Option A — new `bulkValidateActions` function (the original proposal)

Purpose-built bulk function. Accepts all rules' action data, deduplicates connector IDs across the whole batch, runs one `getBulk`, one `listTypes`, then loops the per-rule in-memory checks. Returns a per-rule `{ id, error? }` map.

Bulk caller wires it in **before** `pMap`, in `runBatch` (or earlier, in Phase A). `prepareRule` stops calling `validateActions` and trusts the pre-validated result.

**Pros**

- Cleanest external API. Bulk callers get a function that's obviously about bulk.
- Single-rule paths (`createRule`, `updateRule`, `bulkEdit` per-rule branch) keep `validateActions` untouched. Zero risk of regression on those.
- Each function has one job: `validateActions` for the single-rule path, `bulkValidateActions` for the bulk path.
- Easy to test in isolation — feed it N rules and pre-mocked `actionsClient` responses.

**Cons**

- Logic duplication. The in-memory checks (~150 lines: action groups, frequency, alertsFilter, throttle) get copied into the bulk version. Any future change to a validation rule needs to be made in both functions, and a drift bug here would be a silent correctness issue — bulk-created rules pass with rules that single-create rejects, or vice versa.
- Two functions to keep in sync forever. There is no compiler signal when they drift; only tests catch it, and only if tests exist for the specific check.
- Extra surface area in `rules_client/lib`. Anyone touching action validation now has to know which one to update.

**Where it lives**

`rules_client/lib/bulk_validate_actions.ts`, exported alongside `validateActions`.

## Option B — split `validateActions` into IO + pure validator, then compose

Refactor `validateActions` into two pieces:

1. `fetchActionContext(actionsClient, actionIds)` → `{ actionResults, allConnectorTypes }`. Pure IO. Returns the two fetched datasets.
2. `validateActionsAgainstContext(ruleType, data, context, allowMissingConnectorSecrets)` → throws/returns errors. Pure, no IO. Takes the pre-fetched context as a parameter.

Existing `validateActions` becomes a 3-line composition: fetch, then validate. Behaviour unchanged for single-rule callers.

Bulk path:

1. Collect unique action IDs across the batch.
2. Call `fetchActionContext` once for the whole batch.
3. Per-rule, call `validateActionsAgainstContext` with the rule's slice of `actionResults` and the shared `allConnectorTypes`. Either inside `pMap` or as a plain `for` loop (it's CPU-only now, so `pMap` buys nothing).

**Pros**

- Single source of truth for the in-memory checks. No drift risk.
- Each piece is independently testable: mock the IO once, test the validator with synthetic data.
- The split is a useful refactor on its own — separates "what the rule needs to be valid" from "where the data comes from". Makes future changes (e.g. caching, batching, swapping the connector store) trivial.
- Bulk path becomes obviously correct: same validator runs per-rule, just fed pre-fetched data.

**Cons**

- More invasive. Touches `validateActions` (used by `createRule`, `updateRule`, `bulkEdit`, `transformAndDeleteLegacyActions`) and its tests. Risk surface is "did the refactor preserve behaviour exactly".
- Slightly awkward API for the per-rule call — caller has to filter `actionResults` down to the IDs this rule uses, or the validator has to look up by ID internally. Either way it's an extra step the single-rule path didn't need.
- Slicing `actionResults` per rule is a small per-rule allocation. Not a real problem at N=1000 but worth noting given prior OOM history with bulk create.

**Where it lives**

Same file — `validate_actions.ts` — refactored in place. Two exports: `fetchActionContext` and `validateActionsAgainstContext`. `validateActions` stays as the composed convenience wrapper.

## Option C — per-request memoization wrapper around the two `actionsClient` calls

Don't touch `validateActions`. Wrap `actionsClient.getBulk` and `actionsClient.listTypes` with a tiny cache that's scoped to a single `bulkCreateRules` call.

- `listTypes()` cache: trivial, single key, fetch once, return the cached value for the lifetime of the bulk call.
- `getBulk({ ids })` cache: keyed by connector ID. First call fetches the union of all unique IDs the bulk request will ever ask for (we can pre-compute this from `inputs` at the top of `bulkCreateRules`). Subsequent per-rule calls return slices from the cache.

The wrapper is passed into `prepareRule` instead of the raw `actionsClient`, or attached to `context` for the duration of the call.

**Pros**

- Smallest diff. `validateActions` itself doesn't change at all.
- Lowest risk. The validation logic — including all the edge cases around `allowMissingConnectorSecrets`, endpoint security, workflows-only — is untouched.
- Works for *any* future caller of `actionsClient.getBulk` / `listTypes` inside the bulk operation, not just `validateActions`. If `prepareRule` ever grows another call to either, it benefits automatically.

**Cons**

- The shape of the optimisation is hidden inside a wrapper. Someone reading `validateActions` still sees per-rule `getBulk` / `listTypes` calls and won't realise they're cached unless they trace where the actionsClient came from.
- Cache scoping is fiddly. It must die at the end of the bulk call — if it leaks (e.g. someone attaches it to `RulesClientContext` and forgets to clear it) you get stale connector data on the next request. Bug surface area is non-zero.
- Pre-fetching the union of all IDs at the start is a separate code path that needs to be kept in sync with what `validateActions` actually asks for. If validation ever starts requesting IDs that weren't in the original collection (system actions for example), the cache misses and you're back to per-rule fetches with the cache adding no value.
- Doesn't address the call-overhead from inside `validateActions` itself — N function calls, N awaits, N error-handling paths still happen. The win is purely on the underlying SO/ES calls.

**Where it lives**

A thin wrapper class or factory in `bulk_create/utils.ts` or a new `bulk_create/cached_actions_client.ts`. Passed into `prepareRule` via the args bag.

## Option D — prior art: prefetch + optional `preFetchedActions` pass-through

This was the approach tried in commit [`d0483a2`](https://github.com/elastic/kibana/commit/d0483a20df2fa7e96cb7ecff036656185b69147f) and then dropped. Worth reading carefully because it's the only one of the four that has actually been built and the ticket dismisses it briefly ("messier architecture").

**Shape of the change in [`d0483a2`](https://github.com/elastic/kibana/commit/d0483a20df2fa7e96cb7ecff036656185b69147f)**

- A new `prefetchActions` helper in `bulk_create/utils.ts` runs once at the start of `bulkCreateRules`. It collects the union of every action and system-action ID across all input rules, does one `actionsClient.getBulk`, and returns a `Map<id, ActionResult | InMemoryConnector>`. Soft-fail: on error it logs and returns `undefined`, falling through to per-rule fetches.
- An optional `preFetchedActions?` parameter was added to three functions:
  - `validateActions` (single-rule, ~9 lines changed)
  - `validateAndAuthorizeSystemActions` (~19 lines)
  - `extractReferences` → `denormalizeActions` (~7+15 lines)
- `prepareRule` slices the relevant subset of the map per rule (`sliceActionsById`) and passes it into each of the three functions.

**What it actually solved**

- **`getBulk`**: 3N → 1 per batch. The big win. All three callers share one prefetched map.
- **`listTypes`**: untouched. Still 2N per batch (N from `validateActions`, N from `validateAndAuthorizeSystemActions`).
- Only `bulkCreate` was wired in. `bulkEdit` would have needed the same plumbing.

**Pros**

- Smallest semantic change to existing functions — they keep working exactly as before when no `preFetchedActions` is supplied.
- Single-rule paths (`createRule`, `updateRule`) are completely unaffected — they just don't pass the optional param.
- Soft-fail is genuinely nice: a hiccup in the batched call doesn't kill the operation, it just degrades to the old behaviour.
- Already exists and demonstrably works.

**Cons** (the reasons it didn't land)

- **Optional pass-through threaded through four files** (`validateActions`, `validateAndAuthorizeSystemActions`, `extractReferences`, `denormalizeActions`). Each function grows a parameter that only one caller ever uses. The parameter has no internal meaning — it's just "use this instead of fetching" — which is a code smell: the function is being told what to do, not what it needs.
- The prefetched data **only covers `getBulk`**, not `listTypes`. To extend, you'd thread *another* optional param (`preFetchedActionTypes?`) through the same four files. The pattern doesn't compose — each new piece of cached data is a new optional pass-through.
- The `sliceActionsById` helper has subtle correctness traps. It silently drops IDs that aren't in the prefetched map. If a rule references a connector that was excluded from the prefetch (e.g. added after the prefetch ran, edge case), validation now misses it. The original per-rule fetch would have errored cleanly.
- Behaviour drift between the prefetch path and the per-rule fallback path. Two code paths through the same validator means two test paths, and the fallback is much harder to trigger in tests so it bit-rots.
- Doesn't help `bulkEdit` until you also thread the prefetch through `getUpdatedAttributesFromOperations` and `attemptToMigrateLegacyFrequency`. By the time you've done that, the optional-param surface is across ~6 files.

**Where it lives** (in the prior attempt)

`prefetchActions` in `bulk_create/utils.ts`. Optional params in `validate_actions.ts`, `validate_authorize_system_actions.ts`, `extract_references.ts`, `denormalize_actions.ts`.

**My read on D vs A/B/C**

D is option C without the encapsulation. C puts the dedup behind a wrapped client; D puts it in optional params on every consumer. D is faster to write (it already exists) and lower-risk than C because there's no cache lifecycle to manage — the prefetched map is just a local variable in `bulkCreateRules`. But the API smell is real: every consumer of `actionsClient.getBulk` now has two ways to be called, and the relationship between them isn't enforced anywhere.

## Quick comparison

| Concern | A (new bulk fn) | B (split + compose) | C (cached client) | D (prior art: prefetch + pass-through) |
|---|---|---|---|---|
| Eliminates N×`getBulk` | yes | yes | yes | yes |
| Eliminates N×`listTypes` | yes | yes | yes | **no** (would need extra param) |
| Covers `denormalizeActions` `getBulk` | needs explicit wiring | needs explicit wiring | yes (free) | yes (already done) |
| Code duplication of validation rules | high | none | none | none |
| Optional-param plumbing surface | none | none | none | 4+ files |
| Risk to single-rule paths | none | low-medium | none | very low (optional param defaults to current behaviour) |
| Diff size | medium | medium-large | small | small (already written) |
| Helps future bulk callers automatically | no | partial | yes | no |
| Drift risk over time | high (logic) | low | low | medium (two code paths inside each function) |
| Already implemented and tested | no | no | no | yes |

## Open questions worth flagging

1. **System actions.** `validateAndAuthorizeSystemActions` has the same N-call shape as `validateActions` and runs right next to it in both `prepareRule` and `bulk_edit_rules.ts:281`. Combined, that's 4 `actionsClient` calls per rule today. Do we fix both in this PR, or scope strictly to `validateActions` and leave system actions for a follow-up? (A single `listTypes({ includeSystemActionTypes: true })` covers both; not coordinating now means doing the same work twice later.)
2. **bulkEdit.** `bulkEditRules` has the same per-rule pattern via `pMap` in `bulk_edit_rules_occ.ts`. If we pick A or B, do we wire the bulk variant into `bulkEdit` in the same PR, or stage it?
3. **Legacy SIEM actions migration.** `bulkMigrateLegacyActions` → `validateTransformedActions` is a third hot spot, sequential `asyncForEach`. Fewer rules in practice (only when legacy sidecars exist), but the same shape. Include or defer?
4. **`addGeneratedActionValues` placement.** Already discussed in [`bulk-create-dedup-action-values-memory.md`](./bulk-create-dedup-action-values-memory.md). If we move action enrichment to A1 (preValidate), bulk action validation can also run in A1 against the enriched data, and `prepareRule` becomes purely about API keys + transforms. These two changes share the same data path — worth deciding together.
5. **Strict mode behaviour.** When `exitEarlyOnError = true`, do we want bulk-validate to short-circuit on the first per-rule error, or always run all per-rule checks so the caller sees the full list? Current per-rule `validateActions` throws on first error per rule, but the bulk wrapper has a choice.
