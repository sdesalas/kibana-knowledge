# PR Review — #266371 [Core] First-class spaceId in Core

> Reconstructed from a prior analysis transcript that crashed before writing the report (2026-05-15 against base `5a7d131bcc9e25a2917cd1bd6fb3154520a8a5e6`). The PR may have evolved since then — re-verify any specific findings against the latest revision.

- **Author:** @rudolf
- **Scale:** Substantive (multi-component, shared utility delete, public Core API change, ~80 consumer migrations)
- **Team-aware lens:** `@elastic/security-detection-rule-management` (DRM) — but DRM surface area is tiny (see Ownership), so this review is primarily a standard cross-team analysis with a DRM call-out at the end.

## Ownership (team: `@elastic/security-detection-rule-management`)

- **Your team's files (3, all low-impact):**
  - `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/install_prebuilt_rules/review_installation.ts` — test file
  - `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/signals/set_signal_status/set_signals_status_route.gen.ts` — generated
  - `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/signals/set_signal_status/set_signals_status_route.schema.yaml` — source for the gen
- **Other teams' files:** everything else — Core HTTP, Core Spaces, Spaces plugin, alerting, task_manager, security_solution (non-DRM), entity_analytics, plus ~80 consumer migrations across many teams.
- **Unowned:** none material.

The two `set_signal_status` files only re-format description strings (folded YAML scalars in `set_signals_status_route.schema.yaml`, equivalent string-literal changes in the `.gen.ts`). No behavior change — looks like a downstream re-generation, likely from a codegen-tool version bump rather than something this PR strictly needs. The DRM test file change was not inspected in detail but appears to be a small touch-up consistent with the rest of the migration.

**Net DRM exposure: effectively zero risk.** You were likely cc'd for visibility on the cross-cutting public-API change, not because anything in DRM is at stake.

## Summary

`KibanaRequest.spaceId` becomes a required, first-class `readonly SpaceId` property populated by Core itself. The mechanics that used to live in `@kbn/spaces-utils` (URL parsing, basePath/space prefix stripping) move into:

- a new `src/core/packages/spaces/common` package (`SpaceId`, `asSpaceId`, `getSpaceIdFromPath`, `addSpaceIdToPath`, `spaces_url_parser`)
- Core's HTTP layer, where **both basePath and `/s/<id>` stripping now happen in `onRequest`** instead of being split between Core (`onRequest`) and the Spaces plugin (`onPreRouting`).

`@kbn/spaces-utils` is deleted. About 80 in-tree consumers are migrated from `basePath.set(fakeRequest, '/s/${spaceId}')` and ad-hoc URL parsing to either `FakeRawRequest.spaceId` or reading `request.spaceId` directly. The browser side gets `spaceId` from injected metadata (populated by the rendering service from the request).

The intent — "make spaceId a first-class concept so plugins stop reinventing it" — matches the diff. The scope, however, is wider than the title suggests: it's both an additive API and a removal of a load-bearing utility package, plus a behavioral reordering of HTTP lifecycle hooks. That reordering is the most interesting thing in the PR and worth focused review.

## Files touched

Grouped by concern (rough counts; only the meaningful groups are called out):

- **New Core Spaces package** — `src/core/packages/spaces/common/**` (`space_id.ts`, `spaces_url_parser.ts`, `index.ts`). The new shared home for `SpaceId`, `asSpaceId`, parsers.
- **Core HTTP server** — `src/core/packages/http/server-internal/src/http_server.ts`, `base_path_service.ts`, `router-server-internal/src/request.ts`. Where the lifecycle reordering and the new `spaceId` assignment live.
- **Core HTTP public types** — `src/core/packages/http/server/src/{base_path.ts,router/request.ts,router/raw_request.ts}`. Public API delta: `KibanaRequest.spaceId: SpaceId` (required), `FakeRawRequest.spaceId?: SpaceId`, `FakeRawRequest.path` relaxed to optional.
- **Core rendering / browser plumbing** — `src/core/packages/rendering/server-internal/src/rendering_service.tsx`, `src/core/packages/injected-metadata/**`, `src/core/packages/http/browser/**`. Server-side renders inject `spaceId`; browser `http.spaceId` reads it via `asSpaceId(injectedMetadata.getSpaceId())`.
- **Spaces plugin** — `x-pack/platform/plugins/shared/spaces/server/**`. The plugin's `onPreRouting` hook for URL rewriting is removed; the Spaces plugin no longer owns the stripping behavior.
- **Cluster client** — `src/core/packages/elasticsearch/...` collapses `asScoped`'s `UrlRequest`-typed overload (now expects a `KibanaRequest`-shaped object).
- **Consumer migrations (~80)** — task_manager `task_runner`, alerting `rule_loader`, alerting `run_report`, entity_analytics `risk_score/tasks/helpers.ts` and `privilege_monitoring/tasks/privilege_monitoring_task.ts`, plus many others that previously did `basePath.set(fakeRequest, '/s/${spaceId}')`. All now use `FakeRawRequest.spaceId` directly.
- **Package deletion** — `src/platform/packages/shared/kbn-spaces-utils/**` fully removed. The diff only shows ~3 explicit deletions because git detects most files as renames into `core-spaces-common`.
- **Tests** — new integration test `src/core/server/integration_tests/http/space_id_on_request.test.ts`, updates to `http_server.test.ts`, `request.test.ts`, `user_activity_injected_context.test.ts`, plus fixture renames like `otherSpace` → `other-space` in `wrap_new_terms_alerts.test.ts` (changes the resulting alert UUID hash).
- **DRM-owned (above)** — 1 small test + 2 regenerated route schema files.

## Flow trace — an incoming HTTP request in a spaceful URL

Tracing `GET /kibana/s/myspace/api/echo` with `server.basePath = /kibana, rewriteBasePath = true`:

1. **HTTP server receives the request.** `http_server.ts` `onRequest` runs (this is the *new* location for the rewrite logic). The original URL `/kibana/s/myspace/api/echo` is captured up-front as `rewrittenUrl` *before* any stripping.
2. **Core strips `config.basePath`** via `stripConfiguredBasePath`, yielding `/s/myspace/api/echo`.
3. **Core parses spaceId** by calling `getSpaceIdFromPath(request.url.pathname)`. The regex `/^\/s\/([a-z0-9_-]+)(\/|$)/` matches, `asSpaceId('myspace')` validates, and the parser returns `{ spaceId: 'myspace', pathname: '/api/echo' }`. The path is rewritten to the stripped form.
4. **`request.url.pathname` is now `/api/echo`** and `request.spaceId` is set to `'myspace'`. (If no match, `spaceId` defaults to `DEFAULT_SPACE_ID`.)
5. **`onPreRouting` hooks run.** All plugin-registered `onPreRouting` handlers now see the *fully stripped* URL — no `/kibana`, no `/s/myspace`. Previously, the Spaces plugin's own `onPreRouting` did the `/s/<id>` stripping, so plugins that registered `onPreRouting` *before* Spaces could observe the unstripped URL. **That ordering is gone.** (Risk #1 below.)
6. **Route handler runs** and reads `request.spaceId` directly.
7. **For background tasks** that need to act as a different space, the consumer constructs a `FakeRawRequest` with `spaceId: 'myspace'` and `path` optionally set. `CoreKibanaRequest` reads `spaceId` from the raw request (falling back to `DEFAULT_SPACE_ID`). The old `basePath.set(fakeRequest, '/s/myspace')` pattern is removed; there is no compatibility shim.
8. **Server-side rendering** reads `request.spaceId` and embeds it into injected metadata.
9. **Browser** reads `spaceId` via `asSpaceId(injectedMetadata.getSpaceId())`, surfacing it on `http.spaceId`.

## Assumptions

- **No plugin's `onPreRouting` handler needs to see the `/s/<id>` segment.** The lifecycle reordering moves that visibility window closed. In-tree consumers were migrated; out-of-tree plugins that introspect `request.url.pathname` in `onPreRouting` will silently see `DEFAULT_SPACE_ID`-shaped URLs.
- **Persisted space identifiers obey the new `asSpaceId` regex (`[a-z0-9_-]+`).** The Spaces plugin's management UI validates with the same regex, and URL routing already constrained space IDs to lowercase, so production data should be conformant. Anything created out-of-band (server-side API, scripted setup, old serialized state) may not be.
- **`state.namespace` on background-task state is always a valid `SpaceId`.** In `entity_analytics/privilege_monitoring/tasks/privilege_monitoring_task.ts` (and similar), `state.namespace` is now passed through `asSpaceId(...)`. If a task with malformed persisted state is rehydrated, this throws.
- **`rewriteBasePath: false` deployments do not actually deliver basePath-prefixed URLs to Kibana.** The new parser no longer defensively strips basePath when `rewriteBasePath` is false. Correct in well-behaved proxy setups; old code was strictly more defensive.
- **All `asScoped(...)` callers pass a `KibanaRequest`-shaped object, not a partial.** The signature collapse drops the `UrlRequest` overload.
- **`FakeRawRequest.path` becoming optional is a relaxation, not a regression for any caller.** Anything that previously *read* `path` from a FakeRawRequest must now handle `undefined`.
- **The set_signal_status schema regeneration is byte-equivalent in semantics.** I inspected only the diff (folded scalars), not the OpenAPI generator output downstream.

## Risks

Ordered by likelihood × blast radius.

1. **Silent semantic change for `onPreRouting` consumers.** Anything (in-tree or, more dangerous, out-of-tree) doing `getSpaceIdFromPath(request.url.pathname)` inside an `onPreRouting` hook now silently gets `DEFAULT_SPACE_ID`. No type error, no runtime error — it just behaves as if every request is in the default space. This is the single highest-blast-radius behavioral change in the PR. Worth an explicit migration note in the release docs beyond the PR description.
2. **Breaking public-API removal: `basePath.set(fakeRequest, '/s/${id}')`.** The setter on `IBasePath` is gone. Any out-of-tree task-manager/alerting/SO-client consumer calling this on a fake request will hit a `TypeError`. The PR is explicit about this in its description, but it is a hard break, not a deprecation.
3. **`asSpaceId(...)` throws on malformed input.** In particular:
   - `alerting/server/task_runner/rule_loader.ts` calls `asSpaceId(spaceId)` *without* a `DEFAULT_SPACE_ID` fallback. `task_manager/server/task_running/task_runner.ts` does have a fallback. The inconsistency means a rule SO with a missing/malformed `spaceId` will crash rule loading rather than execute in the default space.
   - `entity_analytics/privilege_monitoring/tasks/privilege_monitoring_task.ts` passes `state.namespace` through `asSpaceId`. Legacy task state with a non-conforming namespace will throw on rehydration.
4. **`KibanaRequest.spaceId` becomes required in the public type.** Strictly speaking this is a TypeScript breaking change for any out-of-tree implementer of `KibanaRequest`. In practice only `CoreKibanaRequest` implements it, so the practical blast radius is the type contract itself (consumers using a `Pick<>`/`Partial<KibanaRequest>` in tests or mocks).
5. **`asScoped` signature collapse.** Out-of-tree code that previously passed a `UrlRequest`-typed object (partial / URL-only) will no longer typecheck. Compile-time break, not runtime.
6. **Test-fixture rename (`otherSpace` → `other-space`) implies alert UUID hash changes.** The `wrap_new_terms_alerts` snapshot was updated for this. If any other plugin embeds the alert UUID in stored data and we have snapshots/fixtures with `otherSpace`-shaped IDs, those will need similar updates. Production deployments don't ship with `otherSpace`, so this is a fixture-hygiene risk, not a runtime risk.
7. **`rewriteBasePath: false` regression.** In well-behaved proxy setups this is fine. In setups where Kibana sometimes still sees the basePath prefix (misconfigured proxies, dev tooling), spaceId parsing will silently fail and fall back to `DEFAULT_SPACE_ID`. Low probability, but worth confirming with whoever supports the air-gapped / unusual-proxy customers.

## Open questions

- **Lifecycle ordering for `onPreRouting`:** is there an out-of-tree plugin survey / community heads-up planned for the behavior change in #1? The PR description mentions in-tree migration but I didn't see release-note-level callout for downstream consumers of `request.url.pathname` inside `onPreRouting`.
- **Why no fallback in `alerting/rule_loader`?** The intentional difference between `rule_loader` (no fallback) and `task_runner` (fallback to default) — is that deliberate ("we want loud failures on malformed rule SOs") or an oversight?
- **`privilege_monitoring_task` / risk_score helpers** — was the choice to call `asSpaceId(state.namespace)` (validating) versus trusting the persisted state intentional? Either is defensible, but it's worth saying which one in a comment near the call.
- **`set_signal_status` regeneration** (DRM lens) — is the folded-scalar reformatting an intended part of this PR, or an unrelated codegen-tool drift that snuck in? If the latter, splitting it into its own PR (or reverting it here) would keep the diff cleaner.
- **`FakeRawRequest.path` going optional** — any consumer that reads it and currently asserts non-null? A search for `fakeRequest.path` / `rawRequest.path` callsites would close this out.
- **`@kbn/spaces-utils` package metadata** — `package.json`, `kibana.jsonc`, etc. for the deleted package: are they removed in the same commit, or is there cleanup left over? The diff was renamed-as-moves for most of these but worth double-checking nothing landed in the workspace registry referencing the dead package.

## Notes for your codebase map

- **`spaceId` is now a Core-level concept**, not a Spaces-plugin concept. The Spaces plugin still owns the *management* surface (CRUD on space SOs, the management UI), but URL-level identification and propagation live in `src/core/packages/spaces/common` and the Core HTTP layer.
- **HTTP lifecycle:** Core's `onRequest` does both basePath stripping and `/s/<id>` stripping in one pass before any `onPreRouting` runs. Plugins that registered `onPreRouting` to do URL rewriting (Spaces plugin's old behavior) no longer need to — and if they still do, they will see an already-rewritten URL.
- **`FakeRawRequest` is now the supported shape for background-task fake requests** carrying space context, with `spaceId` as a typed field rather than encoded into the `path`. Migrating new fake-request creators: set `spaceId` explicitly; do **not** synthesize `/s/<id>` into the path.
- **`asSpaceId`** is a runtime-validating constructor for the branded `SpaceId` type, regex-gated on `[a-z0-9_-]+`. Treat it as load-bearing: anywhere a `string` comes from persisted state and gets typed as `SpaceId`, you're asserting conformance with that regex.
- **Browser-side `http.spaceId`** comes from injected metadata at render time, not from a runtime fetch. Anything that needs to react to space changes still needs to navigate / reload.
- **`@kbn/spaces-utils` is gone.** Any internal doc/runbook/snippet referencing it should redirect to `@kbn/core-spaces-common` (or whatever the final published name turns out to be).

---

*Source: reconstructed from the 2026-05-15 review transcript (`780ff641-335b-4487-a7b9-aabd72ecb9c5`). Base commit: `5a7d131bcc9e25a2917cd1bd6fb3154520a8a5e6`. Re-verify against current PR head before relying on specific line-level claims.*
