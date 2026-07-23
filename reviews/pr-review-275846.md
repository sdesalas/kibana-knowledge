# PR Review: #275846 — [@kbn/change-history] Add getHistoryFieldAggregation for change-history facets

**PR:** [elastic/kibana#275846](https://github.com/elastic/kibana/pull/275846) by @yngrdyn
**Scale:** Substantive (new public API on a shared package; focused scope)

---

### Summary

Adds `ChangeHistoryClient.getHistoryFieldAggregation` so callers can run a scoped terms aggregation over an object's change history — the facet pattern for filter popovers (authors via `user.name`, actions via `event.action`, etc.). Returns `{ field, buckets, sumOtherDocCount }` with a default bucket cap of 100.

Intent matches the diff. There's also a small type tightening on `LogChangeHistoryOptions.data` (`LogChangeHistoryDataOverrides`) that narrows allowed `event` overrides to `type` | `reason` — aligns the type with what `logBulk` already applies at runtime. Not mentioned in the PR summary, but it's a sensible correction.

CI looks green enough on the code side; the PR is currently **dirty / needs rebase** (`mergeable_state: dirty`, `prbot:outdated`).

### Files touched

- **Client API** — `src/client.ts`, `index.ts`, `src/constants.ts`: new method on `IChangeHistoryClient` / `ChangeHistoryClient`; extracts `getInitializedClient` + `buildHistoryFilters` so `getHistory` and the new agg share the same scope; exports `DEFAULT_FIELD_AGGREGATION_SIZE` and `CHANGE_HISTORY_AGGREGATE_FIELDS`.
- **Aggregation helpers** — `src/field_aggregation.ts` (+ unit test): allowlisted fields, terms DSL builder, response parser with string-key enforcement.
- **Types** — `src/types.ts`: re-exports aggregation types; introduces `LogChangeHistoryDataOverrides`.
- **Docs / tests** — README facet section; integration coverage for scope, empty history, truncation, filters, unaggregatable field, uninitialized client.

### Flow trace

1. Caller invokes `getHistoryFieldAggregation(spaceId, objectType, objectId, { field, size?, additionalFilters? })`.
2. `getInitializedClient()` throws if `initialize()` wasn't called (same guard as `getHistory`).
3. `buildHistoryFilters` builds the bool filter: `event.module`, `event.dataset`, `object.type`, `object.id`, plus any `additionalFilters`.
4. `client.search` runs with `space: spaceId`, `size: 0` (hits unused), and a terms agg from `buildFieldTermsAggregation` (`order: { _count: 'desc' }`, size default 100).
5. `parseFieldAggregationResult` reads the `values` agg, validates string-terms shape, maps buckets to `{ key, docCount }`, and surfaces `sum_other_doc_count` as `sumOtherDocCount`.
6. Result is returned with the requested `field` echoed back.

Space scoping is delegated to `@kbn/data-streams` via `search({ space })` — same path as `getHistory`, not reinvented here.

### Assumptions

- **Allowlist is compile-time only.** `ChangeHistoryAggregateField` constrains `opts.field` in TypeScript; there is no runtime check against `CHANGE_HISTORY_AGGREGATE_FIELDS`. A cast (as in the integration test for `event.reason`) falls through to Elasticsearch, which rejects unaggregatable / unmapped paths.
- **Space isolation lives in DataStreamClient.** Filters do not include a space term; they rely on `search({ space: spaceId })` the same way `getHistory` does.
- **`additionalFilters` is trusted server-side DSL.** Documented clearly; same footgun as existing `getHistory`. Callers are expected to build clauses from validated params, not pass user-controlled query DSL.
- **Missing optional fields simply omit buckets.** `user.id` is optional on documents; terms aggregations skip missing values — no empty/"unknown" bucket unless something was actually indexed as `''`.
- **Empty string keys are valid.** Follow-up commit dropped the `key.length === 0` reject (bot review was correct); unit test covers `key: ''`.

### Risks

1. **Raw `additionalFilters` on a shared package API** — same as `getHistory`, but facets are more likely to be wired to UI filter chips. If a route ever forwards client query DSL, this is query injection into a privileged ES client. README warns; worth confirming first consumers keep construction server-side.
2. **No validation of `size`** — `0`, negative, or huge values go straight to ES. `getHistory` has the same pattern, so this is consistency over defense-in-depth, but a facet endpoint with `size: 10000` could be expensive on a busy object.
3. **`LogChangeHistoryDataOverrides` is a quiet type break** — previous `data?: Partial<Pick<ChangeHistoryDocument, 'event' | 'tags' | 'metadata'>>` allowed typing `event.id` / `event.action` etc. even though runtime ignored most of them. Grep suggests current callers only pass `type`/`reason`, so likely fine, but not called out in the PR body.
4. **Branch is behind main** — needs `@elasticmachine merge upstream` / rebase before merge.

### Open questions

1. Is there a planned first consumer (Workflow UI facets?) that exercises `user.id` / `event.type`, or are those exported for completeness ahead of need? Integration tests only cover `user.name` and `event.action`.
2. Should `size` get a hard ceiling (or at least reject `<= 0`) in the client, or is that left entirely to route-layer validation?
3. Intentional that `CHANGE_HISTORY_AGGREGATE_FIELDS` is both re-exported from `types.ts` (value export in a types module) and again from package `index.ts`? Works, just a bit dual-pathed.
4. Was the `LogChangeHistoryDataOverrides` tightening meant to ride along here, or leftover from another change? Fine either way — just nice to mention in the summary.

### Notes for your codebase map

- `@kbn/change-history` is the shared write/read client over the `.kibana_change_history` data stream; module/dataset scope is constructor-level, object/space scope is per-call.
- History reads share `buildHistoryFilters` + DataStreamClient `space` — aggs reuse that rather than inventing a parallel query path.
- Facet fields are an explicit allowlist of mapped keywords (`user.name`, `user.id`, `event.action`, `event.type`); `event.reason` is `text` and correctly fails terms agg.
- `sumOtherDocCount` is document-count truncation signal for “top N” UIs, not a distinct-value remainder count.
- Package still gated by `FLAGS.FEATURE_ENABLED` at `initialize()` time.

### Review activities

1. **Checked bot inline comment on empty keys.** Earlier revision rejected `key.length === 0`; commit `db0d74a7` ("fixing build") removed that guard and added a unit test accepting `''`. Current tree matches the bot suggestion — no remaining issue there.
2. **Verified mappings for allowlisted fields.** `src/mappings.ts` maps `user.id`, `user.name`, `event.action`, `event.type` as keyword; `event.reason` as text — matches the integration test that expects terms-agg failure on `event.reason`.
3. **Checked `LogChangeHistoryDataOverrides` call sites.** Only in-package README + integration test pass `data.event`; both use `type`/`reason` only. Alerting change-tracking tests don't appear to pass fuller `event` overrides.
4. **Reviewed @sdesalas inline comments (2026-07-21).** Checked the 14 inline comments against PR code and `origin/main`. Confirmed: types currently live in `field_aggregation.ts` and are re-exported from `types.ts`; `logBulk` still duplicates the uninitialized-client guard instead of using `getInitializedClient()`; `buildFieldTermsAggregation` / `FIELD_AGGREGATION_NAME` / `aggregationName` are single-use; main has `src/client.test.ts` and no longer exports `ILM_POLICY_NAME` from package `index.ts` (PR reintroduces it). On the throw-on-ES-shape comments: ES aggregation types are wide because the response shape can vary (`AggregationsAggregate` union, bucket `key: FieldValue`); it may be preferable to narrow (e.g. soft-fail / empty buckets) instead of erroring out on an unexpected shape.
