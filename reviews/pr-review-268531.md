# PR Review: #268531 — Remove axios from shared test infrastructure (Phase 5)

**Author:** azasypkin  
**Branch:** `issue-2244-remove-axios-phase-5` → `main`  
**Scale:** Substantive PR (48 files, 13 CODEOWNER groups, ~3160 diff lines). Your team's exposure is **trivial** — one file, one line. The depth here is mostly context.

---

## Ownership (`@elastic/security-detection-rule-management`)

**Your team's files (1):**
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/alerts/migrations/delete_migrations.ts` — co-owned with `@elastic/security-detection-engine`

**Other teams' files (selected):**
- `src/platform/packages/shared/kbn-kbn-client/...` → `@elastic/appex-qa` + `@elastic/kibana-operations` (the core change)
- `src/platform/packages/private/kbn-journeys/...` → `@elastic/kibana-operations`
- `src/platform/packages/shared/kbn-test-saml-auth/...` → `@elastic/appex-qa`
- `packages/kbn-failed-test-reporter-cli/...` → `@elastic/kibana-operations`
- `x-pack/solutions/security/plugins/security_solution/common/endpoint/...` → `@elastic/security-defend-workflows`
- `x-pack/solutions/security/plugins/security_solution/scripts/endpoint/...` → `@elastic/security-defend-workflows`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/ai4dsoc/...` → `@elastic/security-engineering-productivity`
- `x-pack/solutions/security/test/security_solution_api_integration/test_suites/genai/...` → `@elastic/security-generative-ai`
- `x-pack/platform/test/fleet_api_integration/...` → `@elastic/Fleet`

---

## Summary

Phase 5 of a multi-PR migration replacing `axios` with the native `fetch` API in `@kbn/kbn-client`, `@kbn/test-saml-auth`, `@kbn/journeys`, and `@kbn/failed-test-reporter-cli`. The core contract change is in `KbnClientRequesterError`: the HTTP status code that was previously buried as `.axiosError.response.status` (or `.axiosError.status`) is now a flat `.status` property directly on the error. Every downstream consumer that was catching errors and branching on `e?.response?.status` needed a mechanical one-line fix; this PR does all of them in one shot because splitting would have left CI red.

Stated intent matches the diff exactly — there are no scope creep additions, and the `KbnClient.request()` return signature is preserved (`{ data, status, statusText, headers }`).

---

## Files touched

**`@kbn/kbn-client` — core (3 files, ~250 lines):**  
The heart of the change. `kbn_client_requester.ts` drops `axios` + `https.Agent` in favour of native `fetch` + `undici` `Agent`. `kbn_client_requester_error.ts` is rewritten from scratch — it now holds `.status?: number` and `.headers?: Headers` directly instead of a stripped `AxiosError` copy. `kbn_client_import_export.ts` switches from the `form-data` package to the WHATWG `FormData`/`Blob` API.

**`@kbn/test-saml-auth` (2 files):**  
`fetch_kibana_version.ts` and `saml_auth.ts` both used `axios.request()` and caught `AxiosError`. Migrated to native `fetch`.

**`@kbn/journeys` (2 files):**  
`journey_ftr_harness.ts` and `auth.ts` consumed the `KbnClient`-returned response/error shapes; updated to new contracts.

**`@kbn/failed-test-reporter-cli` (3 files):**  
`existing_failed_test_issues.ts` and `github_api.ts` each had their own `axios` HTTP calls (distinct from `KbnClient`); both now use native `fetch` with the same retry pattern. Tests updated to `jest.spyOn(global, 'fetch')` instead of `jest.mock('axios')`.

**Consumer adaptations (~30 files across security, observability, fleet):**  
Purely mechanical: `e?.response?.status` → `e?.status`, `e?.response?.status !== 404` → `e?.status !== 404`. Your team's file is in this category.

---

## Flow trace (your team's file)

1. `deleteMigrationsIfExistent` is called from FTR test setup/teardown with a list of saved-object IDs for `signalsMigrationType`.
2. Each ID is passed to `kbnClient.savedObjects.delete()`, which calls `KbnClientRequester.request()` under the hood.
3. If the object is already gone, Kibana returns `404`. `KbnClientRequester.request()` (new code) throws a `KbnClientRequesterError` with `.status = 404`.
4. Old catch: `if (e?.response?.status !== 404)` — this read the Axios shape; under the new error it would always be `undefined`, so the condition was always `true`, meaning a 404 would no longer be silently swallowed — it would be rethrown. This is the bug the PR fixes.
5. New catch: `if (e?.status !== 404)` — reads directly from `KbnClientRequesterError.status`, correctly swallows 404, rethrows everything else.

---

## Assumptions

- `kbnClient.savedObjects.delete()` throws `KbnClientRequesterError` (not a raw `Error` or some other type) for HTTP error responses. This is true for the new code path in `kbn_client_requester.ts`.
- The `e?.status` optional chain handles the case where something other than `KbnClientRequesterError` is thrown (e.g. a network error) — it won't accidentally silence those.
- `undici` is already available as a transitive dependency (it ships with Node.js ≥ 18 and is a direct dep in Kibana for server-side use). The PR adds it as an explicit dep in `@kbn/kbn-client`.

---

## Risks

**Your team's file — minimal.** The fix is exactly right: `.status` is a flat property on `KbnClientRequesterError` and the optional chain correctly falls back to `undefined` if a non-`KbnClientRequesterError` is thrown.

**Broader PR risks (not your team's problem to review, but worth knowing):**

1. **`ignoreErrors` behaviour change**: previously `isIgnorableError` returned `error.response` (the full Axios response object) for ignored statuses. The new code returns `{ data, status, statusText, headers }`. Callers that were destructuring from the return value are fine (contract preserved), but any caller that compared the return identity or depended on it being an `AxiosResponse` would break. The PR description says this is fixed, but it's worth spot-checking at call sites.

2. **URL credential stripping**: native `fetch` rejects `user:pass@host` URLs; the requester now strips them at construction time and converts to a `Basic` auth header. `resolveUrl()` still returns the original credentialed URL for FTR connector tests. If any test bypasses `KbnClient` and passes the `KbnClient.resolveUrl()` output directly to a different HTTP client that also rejects credentialed URLs, that would break. Unlikely but non-obvious.

3. **`undici` dispatcher for self-signed certs**: replaces `https.Agent({ rejectUnauthorized: false })`. The behaviour should be identical for FTR use, but `undici` has subtly different TLS error messages. Any test that matches on the literal TLS error string would break.

4. **Body double-read risk in error path**: in the new `request()` implementation, on a non-ok response, the code calls `response.text()` to include the body in the error message. The body stream is then consumed and unreachable. This is fine because `ignoreErrors` was already handled before this point. Worth confirming the diff doesn't accidentally call `readBody` after `response.text()` on the same response — a quick read confirms it doesn't.

---

## Open questions

1. **Other `e?.response?.status` catches not in this PR?** The scan of `x-pack/solutions/security/test/` finds only the one file touched here. The `supertest_error_logger.ts` file at `edr_workflows/utils/` has a similar pattern but for `supertest` errors (a different HTTP client), so it's correctly untouched. But if anyone writes new test utilities that catch `KbnClient` errors and use the old shape, there's no linting rule preventing it — worth checking if the eslint config adds a no-axios rule for the migrated paths (yes, the `.eslintrc.js` diff removes them from the legacy allowlist).

2. **What happens if `kbnClient.savedObjects.delete()` throws a network-level error (not HTTP)?** In the old code, `e?.response?.status` would be `undefined`, which is `!== 404`, so it would rethrow — correct. In the new code, `e?.status` would also be `undefined` (network `TypeError` doesn't have `.status`), so same behaviour. Fine.

3. **Is `delete_migrations.ts` even exercised in CI with the current test setup?** It's a utility file used in detection response integration tests. Might be worth confirming the test suite that imports it runs against the migrated `kbn-kbn-client` before merging.

---

## Notes for your codebase map

- `KbnClientRequesterError` now exposes `.status?: number` and `.headers?: Headers` directly; `.axiosError` is gone. Any catch that branches on the old `.response?.status` is broken until updated.
- `KbnClientRequester.request()` now returns `KbnClientResponse<T>` (defined in `kbn_client_requester.ts`) instead of `AxiosResponse<T>`. The shape is the same fields — safe for destructuring callers.
- `undici`'s `Agent` replaces `https.Agent` for self-signed cert acceptance in FTR. Dispatcher is passed as `{ dispatcher }` in the fetch options (Node.js fetch extension, not part of the web standard).
- The axios lint freeze (`AXIOS_LEGACY_CONSUMERS` in `.eslintrc.js`) is being wound down path by path. Once it's empty, there's presumably a follow-up to remove the rule entirely.
- `resolveUrl()` on `KbnClient` intentionally returns the **credentialed** URL (with `user:pass@host`) even after the fetch migration, because FTR connector tests extract credentials from it. The internal `urlForFetch` strips them.
