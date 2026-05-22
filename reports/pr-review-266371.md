# PR Review #266371 — [Core] First-class spaceId in Core

**Scale:** Substantive PR overall (848 files, +20.5k / -11.4k). **Substantive in DRM scope** — 10 files owned by `@elastic/security-solution` (the umbrella DRM belongs to) or `@elastic/security-detection-rule-management` directly. Most are mechanical migrations, but one (`SavedObjectsClientFactory`) is a meaningful refactor.

**Author:** rudolf (Core) · **Base:** `main` · **Branch:** `ralph/core-space-id-on-request` · **State:** OPEN

## Ownership (team: `@elastic/security-detection-rule-management` + parent `@elastic/security-solution`)

### Directly DRM-owned
- `x-pack/solutions/security/plugins/security_solution/docs/openapi/ess/security_solution_detections_api_2023_10_31.bundled.schema.yaml` — YAML block scalar change only (see Risks #6).
- `x-pack/solutions/security/plugins/security_solution/docs/openapi/serverless/security_solution_detections_api_2023_10_31.bundled.schema.yaml` — same.
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/install_prebuilt_rules/review_installation.ts` — import-source rename.

### Owned by parent `@elastic/security-solution` (DRM is in scope as sub-team)
- `src/platform/packages/shared/kbn-cypress-test-helper/src/services/stack_services.ts` — `buildUrlWithSpaceId` simplified to use the new `pathname` return field; behavior change considered below.
- `src/platform/packages/shared/kbn-cypress-test-helper/tsconfig.json` — dep rename.
- `x-pack/solutions/security/plugins/security_solution/common/utils/alert_detail_path.ts` — import-source rename.
- `x-pack/solutions/security/plugins/security_solution/server/deprecations/signals_migration.ts` — inline `/s/${space}` template replaced by `getSpaceUrlPrefix(space as SpaceId)`.
- `x-pack/solutions/security/plugins/security_solution/server/plugin.ts` — `SavedObjectsClientFactory` no longer takes `core.http`; `EndpointAppContextService.setup` no longer takes `httpServiceSetup`.
- `x-pack/solutions/security/plugins/security_solution/tsconfig.json` — add `@kbn/core-spaces-common` (note: `@kbn/spaces-plugin` is left in place; see Risks #2).
- `x-pack/solutions/security/test/security_solution_api_integration/tsconfig.json` — dep rename.

### Adjacent (Endpoint-owned but pulled along by the same refactor)
- `x-pack/solutions/security/plugins/security_solution/server/endpoint/services/saved_objects/saved_objects_client_factory.{ts,mocks.ts}` — drops `httpServiceSetup` constructor param, replaces `basePath.set(fakeRequest, addSpaceIdToPath('/', spaceId))` smuggling with first-class `FakeRawRequest.spaceId: asSpaceId(spaceId)`. This is exactly the migration pattern the PR is designed to enable.
- `x-pack/solutions/security/plugins/security_solution/server/endpoint/{endpoint_app_context_services,mocks/mocks}.ts` — drop the now-unused `httpServiceSetup` from the setup contract.

## Summary

Makes the active Kibana space a first-class branded property on `KibanaRequest.spaceId` (server) and `HttpSetup.spaceId` (browser), populated once by Core's `onRequest` handler. Introduces `@kbn/core-spaces-common` as the canonical home for `SpaceId`, `getSpaceIdFromPath`, `addSpaceIdToPath`, `DEFAULT_SPACE_ID`, and the new `getSpaceUrlPrefix`. Migrates ~80 in-tree consumers off URL-reparsing helpers and deletes `@kbn/spaces-utils`. The Spaces plugin's `onPreRouting` handler is removed; `BasePath.set` and the per-request WeakMap are also gone — Spaces and basePath are now properly decoupled.

Stated intent matches the diff. The PR description's "Breaking changes for out-of-tree consumers" section is accurate but **omits two real ones** (see Risks #4 and #5).

## Flow trace — `SavedObjectsClientFactory` (the most consequential DRM-scope change)

This is the only non-mechanical change in our scope, so worth walking through.

**Before**: `Plugin.start` constructs `new SavedObjectsClientFactory(core.savedObjects, core.http)`. To get an internal SO client scoped to a non-default space, `createFakeHttpRequest(spaceId)` was called:

1. Build a `FakeRequest` with `path: '/'`, empty headers, empty url.
2. If `spaceId !== 'default'`, call `httpServiceSetup.basePath.set(fakeRequest, addSpaceIdToPath('/', spaceId))` to *retroactively* tag the request with its space via the WeakMap that `IBasePath` was caching internally.
3. Saved-objects client downstream calls `getSpaceIdFromPath(http.basePath.get(request))` to recover the space.

**After**: the factory drops `httpServiceSetup` entirely. `createFakeHttpRequest(spaceId)`:

1. Builds a `FakeRawRequest` with `spaceId: asSpaceId(spaceId)` set as a top-level field (the new `FakeRawRequest.spaceId` shape from this PR).
2. Saved-objects client downstream reads `request.spaceId` directly — no URL reparse, no WeakMap.

**This is the correct, intended migration shape**. It also removes the `httpServiceSetup` dependency from the endpoint app context service plumbing, which simplifies setup wiring.

**Validation note**: `asSpaceId(spaceId)` now throws on values that don't match `/^[a-z0-9_-]+$/`. That regex is identical to the one Spaces enforces at space-creation time (`x-pack/platform/plugins/shared/spaces/server/lib/space_schema.ts:12`), so every space ID that exists in a customer's cluster will pass. No customer upgrade risk. The throw is only reachable if a developer passes a hardcoded bad string from in-tree code — which is a bug-catching improvement, not a regression.

## Flow trace — `signals_migration.ts` deprecation builder

Previously: `space === 'default' ? '' : \`/s/${space}\`` — manual inline template, no validation.

Now: `getSpaceUrlPrefix(space as SpaceId)` — uses the new canonical helper, with a `space as SpaceId` cast.

Notable detail: `getSpaceUrlPrefix` itself does **not** validate (only `asSpaceId` does the regex check). So the `as SpaceId` cast here is a deliberate bypass of validation — the comment in the diff says "`space` is a known space id from cluster state — trusted boundary." That's fine; the cluster-state-sourced `space` value has been validated upstream. Just be aware: the cast hides a contract that's only enforceable by reading the comment.

## Flow trace — `buildUrlWithSpaceId` in `stack_services.ts`

Used by Cypress tests across security_solution to rewrite an existing URL into a different space.

**Before** (5 lines, two branches):
1. Call `getSpaceIdFromPath(pathname)` to detect current `/s/<existing>` prefix.
2. If `pathHasExplicitSpaceIdentifier`, slice off the prefix manually.
3. Call `addSpaceIdToPath('/', spaceId, requestPath)` to prepend the new prefix.

**After** (2 lines):
1. Destructure `{ pathname }` from `getSpaceIdFromPath(newUrl.pathname)` — the new helper already returns the stripped pathname.
2. Call `addSpaceIdToPath('/', spaceId, pathname)`.

Semantically equivalent for all valid space ids. The simplification is correct. **Caveat**: `addSpaceIdToPath` now throws on invalid `spaceId`. Cypress tests typically use known-good IDs (`'default'`, named test spaces), but if any test passes a derived value (e.g. from a fixture file with capital letters), it will now throw at runtime instead of producing a broken URL. Easy to spot if it happens — the test will fail loudly. Low risk.

## Assumptions

- The new `getSpaceIdFromPath` return shape (`{ spaceId, pathname, hasExplicitSpaceIdentifier }`) is consumed correctly at all in-tree call sites. `stack_services.ts` is migrated to the new `pathname` field; no remaining DRM-scope consumer destructures the old `pathHasExplicitSpaceIdentifier` (verified by grep — no in-repo matches).
- The `space as SpaceId` cast in `signals_migration.ts` is safe because `space` originates from saved-objects cluster state, which has its own validation upstream.
- `kibanaRequestFactory` in `@kbn/core-http-server-utils` accepts the new `RawRequest`/`FakeRawRequest` shape with optional `path` and optional `spaceId` — confirmed by reading `src/core/packages/http/server-utils/src/request.ts`.
- The Endpoint team is aware of the `httpServiceSetup` constructor-arg removal from `SavedObjectsClientFactory` — this is their primary consumer and the change affects their internal SO-client scoping mechanism. Worth confirming with them rather than just stamping it through.

## Risks

Ordered by likely impact to DRM-scope code.

1. **`asSpaceId` validation is a no-op for real customer spaces.** The new `asSpaceId(value)` regex is `/^[a-z0-9_-]+$/`, which is **identical** to the Spaces plugin's own `SPACE_ID_REGEX` in `space_schema.ts:12` (`/^[a-z0-9_\-]+$/` — the escaped hyphen inside a character class is semantically identical). Any space a customer has ever created through the Spaces API went through that same validation; in addition, the management UI auto-sanitizes input via `toSpaceIdentifier` (lowercases, replaces whitespace and special chars with dashes). **Upgrade risk for existing customer spaces: zero.** On the request path, `getSpaceIdFromPath` only calls `asSpaceId(match[1])` after a URL match on `/^\/s\/([a-z0-9_\-]+)/`, so by construction the captured value satisfies the validator — it cannot throw. A malformed URL like `/s/Foo Bar/...` simply fails the URL regex and falls through to `DEFAULT_SPACE_ID` with `hasExplicitSpaceIdentifier: false`. The only way to make `asSpaceId` throw is for an *in-tree developer* to pass a hardcoded bad string directly to `asSpaceId` or `addSpaceIdToPath` — which is a developer-time bug, not a customer-impact issue, and arguably a feature of the new design (surfaces bugs earlier).

2. **`DEFAULT_SPACE_ID` migration is incomplete and the PR description overclaims.** The PR description says *"All `DEFAULT_SPACE_ID` imports → `@kbn/core-spaces-common`"*, but a repo-wide grep shows **~125 files still import `DEFAULT_SPACE_ID` from `@kbn/spaces-plugin/common`** vs ~38 that import from the new `@kbn/core-spaces-common`. Inside `security_solution` alone, ~20 files still import it from the old path (mostly endpoint-owned, plus two DRM-adjacent rule_response_actions test files). This is **safe at runtime** — the PR doesn't remove `DEFAULT_SPACE_ID` from `@kbn/spaces-plugin/common/constants.ts`; it only removes the `addSpaceIdToPath`/`getSpaceIdFromPath` re-exports. But it leaves the codebase with **two `DEFAULT_SPACE_ID` constants of different TS types**: the new one is `SpaceId` (branded), the old one is plain `string`. Mixing them works structurally but defeats the whole point of the brand. Worth pinning down with the author: was the description aspirational, or were these left for a follow-up? If a follow-up, is there an issue to track? `@kbn/spaces-plugin` in `security_solution/tsconfig.json` is therefore still legitimately needed — both for `DEFAULT_SPACE_ID` and for `Space`, `SpacesApi`, `SpacesPluginStart`, mocks, etc., which have no replacement in `@kbn/core-spaces-common`.

3. **`addSpaceIdToPath` now validates its `spaceId` argument and throws — but only on malformed *input strings*, not on real space IDs.** Same regex as #1; same conclusion — any real customer space ID will pass. The DRM-scope call sites all use known-good IDs (literal `'custom-space-review-test'`; the trusted cluster-state `space` value; the Cypress test-helper's `spaceId` parameter from controlled callers). **No customer regression possible** because the regex matches what Spaces enforces at creation. The throw is only reachable for developer-error inputs and is arguably a bug-catching feature, not a hazard.

4. **`getSpaceIdFromPath` return shape renamed: `pathHasExplicitSpaceIdentifier` → `hasExplicitSpaceIdentifier`, plus a new `pathname` field.** *Not flagged in the PR description's breaking changes list.* No in-repo consumers using the old name, but third-party consumers will break silently — destructuring `pathHasExplicitSpaceIdentifier` gives `undefined`, which in a boolean context is treated as "no explicit prefix," changing behavior.

5. **`addSpaceIdToPath` throw-on-invalid is also not in the breaking changes list.** Same omission as #4 — silent contract tightening.

6. **The OpenAPI source schema was incidentally reformatted, and the generated zod code is now malformed.** This is not just a YAML formatting artifact — the source file `common/api/detection_engine/signals/set_signal_status/set_signals_status_route.schema.yaml` is also modified in this PR. The `Reason.description` was changed from a single-quoted folded string (`description: '...'`) to a YAML block scalar (`description: >\n  ...`). The bundler (`scripts/openapi/bundle_detections.js`, which invokes `@kbn/openapi-bundler` from `scripts/openapi`) propagates this to both `ess` and `serverless` bundled outputs (`>-` → `>`), and the zod generator (`set_signals_status_route.gen.ts`) emits **broken JSDoc**:

   ```
   /**
     * The reason for closing the alerts...
   
     */
   ```

   The `*` is indented two extra spaces (misaligned with `/**`), and there's an extra blank line before the closing `*/`. This is generator output for `>`-style block scalars — likely a bug in `@kbn/openapi-generator`'s handling of block-scalar `description` fields. Functionally harmless (JSDoc still parses), but it's lint-noise and the kind of thing that drifts further every time someone regenerates. The whole change appears to be a **drive-by reformat from running the OpenAPI generators**, unrelated to the spaceId migration that's the topic of this PR. The PR description doesn't mention OpenAPI work. **Worth either reverting the source change (keeping `description: '...'`) or splitting it into a separate PR with the zod-generator fix.** Filing as DRM-relevant because `signals/set_signal_status` is detection-engine territory but the bundled schemas are explicitly DRM-codeowned (`/x-pack/solutions/security/plugins/security_solution/docs/openapi/{ess,serverless}/security_solution_detections_api_*`).

7. **`httpServiceSetup` dependency removed from `EndpointAppContextServiceSetupContract`.** This is a public-ish setup contract; any test, helper, or solution-side consumer constructing this contract will fail TS until they drop the field. The mock in `endpoint/mocks/mocks.ts` is updated, but if there's an out-of-tree consumer (unlikely, but: serverless solution plugins?) it will break the build.

8. **Background-task `FakeRequest` migration deferred** — the PR description's "Follow-up work" calls out a Phase 3 around credentials-and-scoping for background tasks. DRM should scan its background tasks (prebuilt-rules package install, rule monitoring) for `FakeRequest` construction that still relies on the legacy `app: { spaceId }` smuggling. If found, they'll silently default to `DEFAULT_SPACE_ID` after this PR lands.

## Open questions for the author

- **The PR description claims "All `DEFAULT_SPACE_ID` imports → `@kbn/core-spaces-common`", but ~125 files repo-wide (and ~20 in `security_solution`) still import from `@kbn/spaces-plugin/common`.** Was the migration intentionally partial? If so, is there a tracking issue for the follow-up? The codebase now has two `DEFAULT_SPACE_ID` constants with different TS types (branded vs plain `string`) — worth either finishing the migration or documenting why the split is acceptable.
- **Was the `pathHasExplicitSpaceIdentifier` → `hasExplicitSpaceIdentifier` rename intentional?** And was the new throw-on-invalid behavior of `addSpaceIdToPath` discussed? Neither is in the PR description's breaking changes list, and both could surprise out-of-tree consumers (including partner repos).
- **Did Endpoint team sign off on the `SavedObjectsClientFactory` constructor signature change?** It's their service, and the dependency removal cascades through their setup contract. CC `@elastic/defend-workflows` if they're not already on the PR.
- **Why does this PR ship an unrelated OpenAPI source-schema reformat plus a broken zod codegen output?** The `set_signals_status_route.schema.yaml` `Reason.description` is changed from a single-quoted folded string to a `>` block scalar, which makes the generated `set_signals_status_route.gen.ts` emit malformed JSDoc (misaligned `*`, extra blank line). It looks like an accidental drive-by from running `scripts/openapi/bundle_detections.js` + the codegen. Either revert that source change or split it out so it can be reviewed/fixed independently. The bundled YAMLs are DRM-codeowned, so it lands in DRM's review queue.
- **Did anyone audit DRM-owned background tasks (prebuilt-rules install, rule monitoring) for `FakeRequest` construction?** Out of scope for this PR but worth a follow-up before Phase 3.

## Notes for your codebase map

- `@kbn/spaces-utils` is deleted. New canonical home for SpaceId types and URL helpers: **`@kbn/core-spaces-common`** at `src/core/packages/spaces/common`. The Spaces plugin no longer re-exports these from `common/`.
- `KibanaRequest.spaceId` is now a branded `SpaceId` type (opaque `string & { __spaceIdBrand }`). The brand is created via `asSpaceId(value)` which validates `^[a-z0-9_-]+$`. `DEFAULT_SPACE_ID` is a `SpaceId` constant, not a plain string.
- `KibanaRequest.basePath` is also now a first-class field; `IBasePath.get(request)` is a thin wrapper that returns `request.basePath`. The per-request WeakMap and `IBasePath.set` are gone.
- `FakeRawRequest` gains an optional top-level `spaceId: SpaceId` field. This is the canonical way for background tasks / synthetic requests to express space scoping — no more `basePath.set(fakeRequest, addSpaceIdToPath(...))`.
- `request.rewrittenUrl` now captures the original URL **before any rewrites** — including Core-driven basePath strip and space-prefix strip — not only `onPreRouting`-driven rewrites. Documented in the new JSDoc on `KibanaRequest.rewrittenUrl`. Audit-log consumers should be aware.
- The CPS NPRE bug (#261861, #262465) is fixed as a side effect because `getSpaceNPRE` now reads `request.spaceId` directly instead of reparsing a URL that may have already been rewritten.
- `getSpaceUrlPrefix(spaceId: SpaceId): string` is the new single source of truth for the `/s/<id>` convention. Returns `''` for the default space, `'/s/<id>'` otherwise. Does **not** validate (only `asSpaceId` does). Use this instead of inline `\`/s/${id}\`` templates.
- The PR's `tasks/prd-core-space-id-credentials-and-scoping-api.md` foreshadows a Phase 3 that will loosen `getScopedClient` / `asScoped` to accept `ScopeableRequest`, eliminating the synthetic-`KibanaRequest` workaround in background tasks. Relevant for DRM's prebuilt-rules install task and rule monitoring task.
