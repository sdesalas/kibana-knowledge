# PR Review: #285608 — [Security Solution] Adds Exception List Bulk Actions endpoint (Delete)

**PR:** [elastic/kibana#285608](https://github.com/elastic/kibana/pull/285608) by @jr-araque
**Created Date: Thursday, Sep 17, 2026**

**Scale:** Substantive — new internal HTTP endpoint, a new `lists` plugin extension point, a cross-plugin authz-sensitive callback, and a streaming cascade delete. ~3,200 net new lines across 32 files (a big chunk is tests + a 484-line test plan).

### Summary
Adds `POST /api/exception_lists/_bulk_action` (internal, versioned `1`, ESS + Serverless). Only `delete` is wired up; it deletes up to 100 lists by SO `id`, cascading each list's items first (streamed, one page at a time), then the container. It refuses to delete a list that detection rules reference, returning a per-list `409` naming the rules. Partial failures return HTTP `200` with per-list outcomes in the body — matching the detection-rules `_bulk_action` convention.

Elasticsearch has no transactions, so keeping rules and lists coordinated is best-effort. The endpoint blocks deleting a list that detection rules still reference (a check `security_solution` plugs in, which fails closed when it can't verify), but nothing is atomic across that check, the item cascade, and the container delete — a failure partway through can leave things half-done (see Risks).

### Files touched
- **API contract** (`kbn-securitysolution-exceptions-common/api/bulk_delete_exception_list/*`, `quickstart_client.gen.ts`, `list-constants`, `test-api-clients`): new zod/OpenAPI schema, generated client, the `EXCEPTION_LIST_BULK_ACTION_URL` constant.
- **`lists` plugin route + service** (`routes/bulk_exception_list_action_route.ts`, `services/exception_lists/bulk_delete_exception_list.ts`, `delete_exception_list_items_by_list.ts`, `bulk_delete_exception_list_items.ts`): the endpoint, the per-list orchestration, and the streamed item cascade.
- **`lists` extension point machinery** (`extension_points/types.ts`, `exception_list_client.ts`, `exception_list_client_types.ts`): defines `exceptionsListPreDeleteList` + blocker shape, wires `bulkDeleteExceptionList` on the client with the pipeRun hook and a response validator.
- **`security_solution` callback** (`lists_integration/endpoint/handlers/exceptions_pre_delete_list_handler.ts`, `register_endpoint_extension_points.ts`, `endpoint_app_context_services.ts`): the rule-reference check, plus two new context accessors `getRulesClient` / `getAlertingAuthorization`.
- **Tests + docs**: unit tests for the service/client/callback, an API integration suite (17 tests), and a test plan markdown.

### Flow trace
`POST /_bulk_action` → `bulkExceptionListActionRoute` validates body (zod), switches on `action` → `exceptionLists.bulkDeleteExceptionList({ ids, namespaceType })`.

1. Client builds `preDeleteListHook` (only when `enableServerExtensionPoints`), which calls `pipeRun('exceptionsListPreDeleteList', …)` with a response validator guarding list-identity and `blockedBy` shape.
2. `bulkDeleteExceptionList` dedupes ids (`skipped` = dupes removed), `bulkGet`s them, partitions into validation errors (404 / non-`list` type) vs found lists.
3. `pMap` over found lists at concurrency 10 → `checkAndDeleteList`:
   - runs the hook; a throw → per-list error; non-empty `blockedBy` → per-list `409` with `rule_references`.
   - else `deleteListWithItems`: `deleteExceptionListItemsByListStreamed` (PIT finder, 1k/page, `assertNoUnexpectedItemDeleteErrors` treats 404 as no-op) → `savedObjectsClient.delete(container)`.
4. In the SS callback: fail-closed if no `request`; fetch alerting authorization, refuse if `authorizedRuleTypes.size === 0`; else `findRules({ hasReference: { id, type }, perPage: 10000 })` in the request's space; map matches to blockers.
5. Results aggregated into `{ success, results, errors, summary }`; `success` iff zero errors.

### Assumptions
- The caller's SO client is already space-scoped, and `namespace_type` correctly maps to the SO type for every id in the batch (mixed-namespace batches aren't supported — a single-space list id sent with `agnostic` just 404s). Confirmed as intended design.
- A list is referenced by ≤10,000 rules — `findRules` uses a single `perPage: 10000` page with no pagination. Beyond that, blocker names are truncated (but the delete still blocks, so it stays safe).
- Deleting items then the container is acceptable as a non-atomic sequence — there's no transaction across item pages + container.
- The alerting rules client + authorization built from the request reflect the caller's real privileges (the whole fail-closed argument rests on `getAllAuthorizedRuleTypesFindOperation` being the right signal).

### Risks
1. (LEFT COMMENT TO AUTHOR) **Items-first cascade leaves a half-emptied list if a later PIT page fails.** Child items are deleted 1k at a time via PIT, then the container. If a later page throws, `deleteListWithItems` returns without deleting the container — no rollback. Reproduced locally: 2000-item unlinked list, throw on PIT page 2 → container still there, 1000 items remain. A missing container fails cleanly (rule skips those exceptions); a half-emptied one can still be used as the entry point. @denar50 already asked to delete the list first in the [design review](https://docs.google.com/document/d/1-lMRDfNEqCGaODQmHDlIT6KYECViz3YNbj5qso2KWNM/edit?disco=AAACENwOMXc). Steven posted the same ask on this PR ([discussion_r4045760782](https://github.com/elastic/kibana/pull/285608#discussion_r4045760782)). Severity: medium. Not an unlinking problem — it happens on a list no rule references.
2. **Fail-closed authz refusal surfaces as `status_code: 500`, not 403/409.** The callback throws `EndpointError` for both "no request" and "not authorized to read detection rules." `EndpointError` has no `statusCode`, so `transformError` defaults it to 500 (confirmed in `transform_error/index.ts`). A caller with `exceptions-all` but no detection-rule-read access therefore can't bulk-delete anything and gets a misleading per-list 500. This is both a real 500-vs-403 inconsistency and an *undocumented effective-permission change* — the PR description acknowledges the permission bump, but the API schema/authz docs don't. Severity: low/medium.
3. **N calls to alerting per batch.** The check runs per list at concurrency 10 — up to 100 lists means up to 100 `getAlertingAuthorization` + `getAllAuthorizedRuleTypesFindOperation` + `findRules` round-trips, each potentially returning up to 10k rules. The authorization lookup in particular is request-scoped, not list-scoped, so it's recomputed identically for every list — an easy hoist. Severity: low (perf, not correctness); worth scale-testing the worst case.
4. (DEFERRED) ~~**Cross-space blindness for agnostic lists** (author-acknowledged, deferred to [#281072](https://github.com/elastic/kibana/issues/281072)). A rule in another space referencing an agnostic list won't block its delete → stale reference. Fail-closed doesn't help here because the same-space search legitimately returns empty. Severity: medium, out of scope by deferral.~~ A same-space caller still can't see or unlink rules in other spaces, and blocking the delete would need an elevated all-spaces search. This PR *could* add a console warning during rule execution when a referenced exception-list container is missing ([`find_exception_list_items_point_in_time_finder.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/lists/server/services/exception_lists/find_exception_list_items_point_in_time_finder.ts)) — that would surface the stale-ref case we reproduced (delete from space 1, default-space rule keeps the id). Pre-existing: single `DELETE` of an agnostic list does the same thing — `deleteExceptionList` has no rule-ref check at all. Best handled in [#281072](https://github.com/elastic/kibana/issues/281072), where unlinking and the warning can land together, rather than as a one-off in this PR. ([issuecomment-5728854283](https://github.com/elastic/kibana/issues/281072#issuecomment-5728854283))

### Open questions
1. **Deletion order** — Steven asked to flip to container-first on the PR ([discussion_r4045760782](https://github.com/elastic/kibana/pull/285608#discussion_r4045760782)). Waiting on Reinaldo.
2. Should the fail-closed authz path (risk #2) return `403` instead of a per-list `500`? And should the new "detection-rule-read required to bulk-delete" behavior be documented in the schema/authz section rather than only in the PR description?
3. Any concern about the per-list authorization round-trips (risk #3) at 100 lists on a busy cluster? Could authorized rule types be resolved once per request and passed into each list check? Has the worst-case scale test run?
4. `findRules` caps at `perPage: 10000` with no pagination — is a list referenced by >10k rules realistic enough to care about the truncated `rule_references` list (delete still blocks correctly, only the names are capped)?
5. The `uniqueIds.length === 0` early return looks unreachable given the schema's `minItems: 1` + dedupe always yielding ≥1 — intentional defensive code, or dead? (Harmless either way.)
6. **Cross-endpoint response inconsistency** — a client that already integrates with detection-rules `_bulk_action` will get a *different* contract here: 200 (not 500) on partial failure, and flat `results`/`errors`/`summary` (not the `attributes` envelope + `rules_count`). The 200 choice is defensible (arguably more correct), but is the *inconsistency between two same-named Security Solution endpoints* acceptable, or should the divergence at least be called out in the API docs so consumers don't assume parity?

### Notes for your codebase map
- **`lists` extension points** are the sanctioned way for `security_solution` to inject domain logic into a plugin that must stay ignorant of detection rules. This is the 10th; the pattern is `pipeRun(type, data, ctx, validator?)`, callbacks defined with `function()` (not arrow) to get `this`/context, and a lazy non-recursive `ExceptionListClient` in the context to avoid infinite loops.
- **Fail-closed authz idiom**: alerting rule searches silently filter to readable rule types, so "empty result" ≠ "no rules." The correct check is `getAllAuthorizedRuleTypesFindOperation(...).size === 0`. Good pattern to reuse anywhere you gate on alerting visibility.
- **`_bulk_action` convention is *not* uniform across Security Solution.** This endpoint puts per-item outcomes in the body with HTTP 200 and reserves 4xx/5xx for request-level failures. The detection-rules `_bulk_action` it borrows the *name* from actually returns HTTP 500 on partial failure and nests its payload under an `attributes` envelope with `rules_count`. So "matches the rules convention" is only true for the envelope idea, not the status code or body shape — the divergence was intentional (`bulk_actions_response.ts` `buildBulkResponse`).
- **Streaming deletes**: `createPointInTimeFinder` at 1k/page with a `finally { finder.close() }` swallow is the house style for bounded-memory cascades; the bulk path adds strict per-page error handling (`assertNoUnexpectedItemDeleteErrors`) while single-delete/import keep the tolerant behavior.
- **`transformError` defaults unknown errors to 500** — any custom error thrown across these boundaries needs a `statusCode` to surface a meaningful HTTP code.

### Follow-up Review Activities

1. **Reconciled the PR against the design RFC** ("API Design - Bulk Delete Exception Lists", Reinaldo Araque, [Google Doc](https://docs.google.com/document/d/1-lMRDfNEqCGaODQmHDlIT6KYECViz3YNbj5qso2KWNM/edit), exported with all comment threads to `.knowledge/skip/bulk-delete-exception-lists-rfc.md`). Read the full doc + resolved/open comments and cross-checked every settled decision against the code.
   - **The PR faithfully implements the agreed approach — no scope drift.** All settled decisions are honored: `_bulk_action` envelope with `action: "delete"`; `ids`-only targeting, min 1 / max 100 (Aug 5 decision dropped `list_ids`); whole-batch `namespace_type`; internal/"private" first, public later (Aug 3); HTTP 200 + per-list errors for partial failure (the 200-vs-500 debate resolved in favor of 200); root-level `results`/`errors`/`summary` with no `attributes` envelope; `summary.skipped` = dedupe count. The **Aug 12 pivot** — defer rule unlinking (no `force_unlink`/`dry_run`) but add rule-reference checking with per-list 409s — is exactly what the extension point + SS callback implement.
   - **Validated my assumption** that only `id` + `namespace_type` locate a list (list_id lookups were dropped): confirmed by Reinaldo's comment thread and the Aug 5 decision log. Holds.
   - **Three risks are corroborated by the review threads, not novel to me:** risk #1 (deletion order) was raised by Edgar Santos and is an unresolved "Missing decision" (#6); risk #2 (500 vs 403 + effective-permission change) contradicts the RFC's Authorization section, which promises 403 and never mentions detection-rule-read access; risk #4 (cross-space agnostic refs) isn't covered by the RFC's agnostic section, which only addresses authz scoping.
   - **Approval is not unanimous:** Steven de Salas and Maxim Palenov LGTM; Georgii Gorbachev "Under review" (his rule-reference thread is the single still-OPEN comment, though the discussion reads as agreed); Edgar Santos "Under review" and Yara Tercero not started. Added an open question on sign-off status.
   - Cosmetic mismatch: the RFC labels the version `2023-10-31` (public scheme) while the endpoint ships internal `version: '1'`.
   - **Not yet done:** haven't verified whether the API integration suite exercises the *intra-list partial cascade* failure (item page fails mid-stream, container survives) — the highest-value untested-looking path from risk #1.

2. **Verified the "matches the detection-rules `_bulk_action` convention" claim in the Summary — it doesn't.** Read `bulk_actions_response.ts` `buildBulkResponse`.
   - Detection-rules `_bulk_action` returns **HTTP 500** whenever `numFailed > 0` (partial *or* total failure); it only returns `response.ok` (200) when everything succeeds. Its body nests `results`/`errors`/`summary` under an `attributes` envelope and carries `rules_count`.
   - This endpoint returns **HTTP 200** on partial failure with flat root-level `results`/`errors`/`summary` + a `success` boolean.
   - So the two same-named endpoints diverge on both status code and body shape; only the general "one call, per-item outcomes in the body, summary counts" idea is shared. The divergence is intentional (Maxim/Edgar RFC thread argued 500 is wrong for partial failure; the team chose 200).
   - Corrected the Summary and the Notes bullet to state the divergence instead of claiming parity, and added open question #6.

3. **Posted an inline comment on the PR** about the 200-on-partial-failure divergence — [discussion_r4038385795](https://github.com/elastic/kibana/pull/285608#discussion_r4038385795), anchored on `bulk_exception_list_action_route.ts` line 53 (the `response.ok(...)` in the `delete` case).
   - Final posted wording (Steven's, edited from my draft): flags that the endpoint returns 200 on partial failure *and even on total failure across all items* (nothing checks the failed count), links the rules [500 convention](https://github.com/elastic/kibana/blob/fbf4d1a5fed8cf4eff10d96d24354b6fd21ea614/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/bulk_actions_response.ts#L84-L104) and the [API design review thread](https://docs.google.com/document/d/1-lMRDfNEqCGaODQmHDlIT6KYECViz3YNbj5qso2KWNM/edit?disco=AAACENwOMXY), and notes there wasn't consensus.
   - **Steven's stated position:** 200/207 is the right approach, so *not* requesting a change. But the divergence will confuse consumers already automating rule/exception deletion; since this is an internal endpoint (no public OAS), **release notes** are the realistic mitigation. Asked the author to plan for easing that migration.
   - New observation surfaced while drafting: the `success`/status logic never inspects *how many* lists failed — an all-lists-failed batch still returns 200. Worth considering whether total failure should read differently from partial failure.

4. **Posted an inline comment asking for agnostic-namespace test coverage** — [discussion_r4039221520](https://github.com/elastic/kibana/pull/285608#discussion_r4039221520), anchored on `bulk_delete_exception_lists.ts` line 250 (`should delete lists in the agnostic namespace`, the only agnostic test).
   - Requested three cases the suite is missing for agnostic lists: a **namespace-mismatch guard** (agnostic list not deletable via a `single` request and vice versa — expect 404, list intact), an **agnostic cascade** (mirror of the `single` cascade test), and **cross-space reachability** (a global list created in one space is deletable from another — the MSSP scenario; likely needs `@skipInServerless`).
   - Confirmed low cost before asking: the first two are single-space copies of existing tests; cross-space is cheap because `bulkDeleteExceptionLists` already takes a `kibanaSpace` arg and a `spaces` FTR service exists. Left the wiring detail to the author.

5. **Posted a top-level PR comment questioning the performance justification** — [issuecomment-5726409116](https://github.com/elastic/kibana/pull/285608#issuecomment-5726409116). Shifted from *how* the PR is built to *why*: the description and the [initiative](https://github.com/elastic/kibana/issues/266239) frame this as a scale/duration improvement over the current one-DELETE-per-list workflow (~3h16m in one measurement), but the PR ships no before/after numbers. Asked what the actual performance gain to users is beyond the convenience of a single bulk call, and argued those figures should be answered here before merge.

6. **How an agnostic exception list gets created — there is no UI control for it.** Confirmed by reading the Shared Lists create path, Endpoint artifact ensure-created path, and the two SO types.
   - **Shared Lists UI always creates `single`.** The flyout (`create_shared_exception_list/index.tsx`) only sends `{ name, description }` to `POST /api/exception_lists/shared`. The route (`manage_exceptions/route.ts`) hardcodes `namespaceType: 'single'` and `type: 'detection'`. Rule-default lists from the rule details page are also `single`.
   - **Agnostic lists are Endpoint containers, created lazily.** Trusted Apps / Event Filters / Blocklist / Host Isolation / Trusted Devices / Custom YARA each ship a list definition with `namespace_type: 'agnostic'` and call `INTERNAL_EXCEPTIONS_LIST_ENSURE_CREATED_URL` on first page load. `createEndpointList()` does the same for Endpoint Exceptions, also triggered when the prebuilt "Endpoint Security" rule installs. Those land as SO type `exception-list-agnostic` (`namespaceType: 'agnostic'`), shared across every space.
   - **The other way is the raw API** — `POST /api/exception_lists` with `namespace_type: 'agnostic'` (default is `single`). That's how the PR's one agnostic test creates its list. Import of an NDJSON that already has `namespace_type: agnostic` would do the same.
   - **You won't see most of them on Shared Lists.** That page queries both namespaces but only shows `type: detection` (and Endpoint Exceptions if the "moved under management" flag is off). Trusted Apps etc. are filtered out via `hideLists: ALL_ENDPOINT_ARTIFACT_LIST_IDS` and live on the Management artifact pages instead. A custom agnostic *detection* list created via API would show up — there's just no UI that creates one.
   - Implication for this PR: `namespace_type: 'agnostic'` on bulk-delete is for Endpoint artifacts + API/import-created lists, not for anything an analyst picks in Shared Lists. Matches Reinaldo's RFC reply: "Agnostic/global exceptions lists are mostly used by the Endpoint Exceptions."

7. **Local testing at `http://localhost:5603/kbn`**
   - **Inspected** (9.6.0, security-solution spaces `default` and `1`).
     - **Rules:** one disabled prebuilt `new_terms` copy per space (`rule_id` `25d917c4-…`, `immutable: true`, renamed per space). Each references three `single` lists; none reference the Endpoint agnostic lists. No other rules.
     - **Agnostic:** only `endpoint_list` and `endpoint_trusted_apps` (empty, same SO ids in both spaces, `created_by: kibana`). No custom agnostic detection list.
     - **Single, per space:** `rule_default` ("Exceptions for rule - Network Activity Detected via Kworker") + two `detection` lists ("Bad IPs" and "Bad IPs (value list)"). Same `list_id`s / item `item_id`s, distinct SO ids — imported into space `1` then renamed. Items: HOME IP `match_any` `192.168.1.1/2`; Bad IPs match `145.178.0.2`; value-list entry pointing at `bad.ip-list.small.txt`.
     - **Dangling value list:** `GET /api/lists?id=bad.ip-list.small.txt` is 404 in both spaces; `_find` returns 0. Bulk-delete would drop the exception item, not the (already missing) value list.
     - **Bulk-delete as first seen:** the three `single` lists would 409. Empty Endpoint agnostic lists would succeed and vanish from both spaces.
   - **Created an agnostic detection list via API** so there's something to see on Shared Lists.
     - `POST /api/exception_lists` with `namespace_type: agnostic`, `type: detection`, `list_id: agnostic-cross-space-ips`.
     - 3 items: `10.0.0.0/8`, `172.16.0.0/12`, scanner `203.0.113.10` / `.11`.
     - Same SO id `c4447968-…` visible from both spaces.
   - **Default-space rule now has 4 exception refs** — original three `single` lists plus the new agnostic one.
     - rule_default: HOME IP (`192.168.1.1/2`)
     - Bad IPs: match `145.178.0.2`
     - Bad IPs (value list): entry pointing at missing `bad.ip-list.small.txt`
     - agnostic Cross-space IPs: those 3 items
     - Bulk-delete of `agnostic-cross-space-ips` from `default` should **409**. Space `1`'s rule was not updated, so a delete from space `1` would still succeed — live demo of the deferred cross-space gap.
   - **Created a shared detection list with 100 items** and attached it to the default-space rule.
     - `list_id: shared-100-ips`, SO id `a3c75249-…`, `type: detection`, `namespace_type: single`. Name: "Default space shared list: 100 IPs".
     - 100 items: `source.ip` match `198.51.100.1` … `198.51.100.100` (TEST-NET-2).
     - Default-space rule now has **5** exception refs. Bulk-delete of this list from `default` should **409**. Not present in space `1`.
   - **Added `.knowledge/scripts/check-exceptions.sh`** (same shape as `check-tasks.sh`). Inventories rules, list containers, item counts, and rule→list associations per space. `KIBANA_DEV_PORT=5603 .knowledge/scripts/check-exceptions.sh`. Confirmed against this stack: default 5 refs (including agnostic + 100-item list), space 1 still 3 refs; agnostic Cross-space IPs shows as unreferenced in space 1.
   - **Tried bulk-delete of all 4 `single` lists in default** via `POST /api/exception_lists/_bulk_action` (`action: delete`, `namespace_type: single`). HTTP **200**, `success: false`, `summary.failed: 4`. Each list returned per-item **409** naming the default-space rule. Nothing was deleted. Live confirmation of the rule-ref gate, and of 200-on-total-failure (open question #6).
   - **Created 10 unlinked shared detection lists** in default (`unlinked-100-ips-01` … `10`), 100 items each (1000 items total). Not attached to any rule, so bulk-delete of these should succeed.
   - **Bulk-deleted those 10 unlinked lists.** `POST /api/exception_lists/_bulk_action` with the 10 SO ids, `namespace_type: single`. HTTP **200**, `succeeded: 9`, `failed: 1`. 01–09 gone (items cascaded). `unlinked-100-ips-10` 409'd — `Endpoint Security (Elastic Defend)` (`9a1a2dae-…`) actually references it alongside `endpoint_list`. We didn't attach it; likely the UI. Partial-success 200 confirmed live.

     ```json
     {
       "success": false,
       "results": [
         {
           "id": "9bc5603e-e98f-40f3-989d-7b092b952c1a",
           "list_id": "unlinked-100-ips-01",
           "type": "detection",
           "name": "Default space shared list: unlinked 01",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5ODgsMV0=",
           "tie_breaker_id": "6ac8978f-7bac-471d-b629-081a7b9959e9",
           "created_at": "2026-09-18T09:20:04.386Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:04.386Z",
           "updated_by": "elastic"
         },
         {
           "id": "69555e16-d916-462c-b0b1-78d60bad9a4e",
           "list_id": "unlinked-100-ips-02",
           "type": "detection",
           "name": "Default space shared list: unlinked 02",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5ODksMV0=",
           "tie_breaker_id": "78e65833-ea5b-40ac-97d8-73324a42d496",
           "created_at": "2026-09-18T09:20:04.720Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:04.720Z",
           "updated_by": "elastic"
         },
         {
           "id": "1be5a549-9030-4774-90c1-36e3ba8b7ddf",
           "list_id": "unlinked-100-ips-03",
           "type": "detection",
           "name": "Default space shared list: unlinked 03",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTAsMV0=",
           "tie_breaker_id": "09284e91-a54e-491d-bf7b-901e676453ba",
           "created_at": "2026-09-18T09:20:05.750Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:05.750Z",
           "updated_by": "elastic"
         },
         {
           "id": "6c4602d8-ea80-4aae-81f5-f77297099927",
           "list_id": "unlinked-100-ips-04",
           "type": "detection",
           "name": "Default space shared list: unlinked 04",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTEsMV0=",
           "tie_breaker_id": "e9cf03c5-633b-48de-b11d-2662e2618397",
           "created_at": "2026-09-18T09:20:06.759Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:06.759Z",
           "updated_by": "elastic"
         },
         {
           "id": "e37c60ef-5a0c-4227-b509-a2272670c3a0",
           "list_id": "unlinked-100-ips-05",
           "type": "detection",
           "name": "Default space shared list: unlinked 05",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTIsMV0=",
           "tie_breaker_id": "ac55f46d-028d-4147-8114-e4f9e61a005f",
           "created_at": "2026-09-18T09:20:07.785Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:07.785Z",
           "updated_by": "elastic"
         },
         {
           "id": "357ace48-6b8d-404f-a839-7b46c3306a37",
           "list_id": "unlinked-100-ips-06",
           "type": "detection",
           "name": "Default space shared list: unlinked 06",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTMsMV0=",
           "tie_breaker_id": "339edbe6-77f6-466c-ae41-ebbb4d8731d2",
           "created_at": "2026-09-18T09:20:08.799Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:08.799Z",
           "updated_by": "elastic"
         },
         {
           "id": "7190a985-db6e-4843-bbf2-56c28ee4c142",
           "list_id": "unlinked-100-ips-07",
           "type": "detection",
           "name": "Default space shared list: unlinked 07",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTQsMV0=",
           "tie_breaker_id": "01d0d73f-f66b-405b-8714-c9ba8142e527",
           "created_at": "2026-09-18T09:20:09.814Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:09.814Z",
           "updated_by": "elastic"
         },
         {
           "id": "574679c5-4b1a-474a-ab71-9facc19487e6",
           "list_id": "unlinked-100-ips-08",
           "type": "detection",
           "name": "Default space shared list: unlinked 08",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTUsMV0=",
           "tie_breaker_id": "88d5474b-bb8a-45ed-a778-ec1314e9a0aa",
           "created_at": "2026-09-18T09:20:10.840Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:10.840Z",
           "updated_by": "elastic"
         },
         {
           "id": "c622879d-d54b-4529-b902-343e22427946",
           "list_id": "unlinked-100-ips-09",
           "type": "detection",
           "name": "Default space shared list: unlinked 09",
           "description": "Unlinked shared list with 100 items for bulk-delete local testing.",
           "immutable": false,
           "namespace_type": "single",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU5OTYsMV0=",
           "tie_breaker_id": "8ad603e7-9860-4585-81b0-b23a9f8da239",
           "created_at": "2026-09-18T09:20:11.885Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:20:11.885Z",
           "updated_by": "elastic"
         }
       ],
       "errors": [
         {
           "message": "Exception list \"Default space shared list: unlinked 10\" cannot be deleted because it is linked to 1 rule. Unlink the list from all rules before retrying.",
           "status_code": 409,
           "lists": [
             {
               "id": "bc872007-f66d-4de3-86fb-084b7f1cddf5",
               "list_id": "unlinked-100-ips-10"
             }
           ],
           "rule_references": [
             {
               "rule_id": "9a1a2dae-0b5f-4c3d-8305-a268d404c306",
               "id": "726b3fd6-2ad9-44f4-8891-7e175b6c2ff1",
               "name": "Endpoint Security (Elastic Defend)"
             }
           ]
         }
       ],
       "summary": {
         "total": 10,
         "succeeded": 9,
         "failed": 1,
         "skipped": 0
       }
     }
     ```
   - **Deleted the agnostic shared list from space 1** (`POST /s/1/api/exception_lists/_bulk_action`, id `c4447968-…`, `namespace_type: agnostic`). HTTP **200**, `success: true`, `succeeded: 1` — space 1 had no local rule ref, so the gate did not 409. List is now 404 from **both** spaces. Default-space Kworker rule still carries the stale `exceptions_list` entry. Live confirmation of deferred risk #4 / #281072.

     ```json
     {
       "success": true,
       "results": [
         {
           "id": "c4447968-699c-4675-95a5-370ea4e061a9",
           "list_id": "agnostic-cross-space-ips",
           "type": "detection",
           "name": "Agnostic shared list: Cross-space IPs",
           "description": "Created via API for bulk-delete PR review. namespace_type=agnostic so it is visible in every space.",
           "immutable": false,
           "namespace_type": "agnostic",
           "os_types": [],
           "tags": [],
           "version": 1,
           "_version": "WzU4ODMsMV0=",
           "tie_breaker_id": "9f9840a7-dcfa-4405-ae72-832473e3f739",
           "created_at": "2026-09-18T09:03:39.389Z",
           "created_by": "elastic",
           "updated_at": "2026-09-18T09:03:39.390Z",
           "updated_by": "elastic"
         }
       ],
       "errors": [],
       "summary": {
         "total": 1,
         "succeeded": 1,
         "failed": 0,
         "skipped": 0
       }
     }
     ```
   - **Confirmed risk #1 live** (intra-list partial cascade). Created unlinked `cascade-probe-100` (100 items, SO `dbd3d7da-…`). Injected a throw after the 50th item delete in `deleteExceptionListItemsByListStreamed`, waited ~30s for compile, then bulk-deleted. HTTP **200**, `success: false`, per-list error `TEST: abort cascade after item 50` with `status_code: 500`. **Container still exists. 50 items remain.** Container was not deleted after the item-cascade throw — a half-emptied list, which is worse for rules than a missing container. Reverted the throw after the probe.
   - **Risk #1 probe was artificial.** Production deletes a whole PIT page (up to 1k) in one `bulkDelete`. The 50/50 leftover needed a per-item loop we added for the probe. Struck risk #1 as **REASSESSED** — see Risks.
   - **Reproduced risk #1 on the production path** (second PIT page). Created unlinked `cascade-probe-2000` (2000 items, SO `c9af4eda-…`). Threw at the start of PIT page 2 in `deleteExceptionListItemsByListStreamed` (page 1 still one 1k `bulkDelete`). HTTP **200**, `success: false`, `TEST: abort cascade on PIT page 2`. **Container still exists. 1000 items remain.** First page committed; second never ran; container delete skipped. Reverted the throw.

     ```json
     {
       "success": false,
       "results": [],
       "errors": [
         {
           "message": "TEST: abort cascade on PIT page 2",
           "status_code": 500,
           "lists": [
             {
               "id": "c9af4eda-5434-4525-b160-e713f6b65020",
               "list_id": "cascade-probe-2000"
             }
           ]
         }
       ],
       "summary": {
         "total": 1,
         "succeeded": 0,
         "failed": 1,
         "skipped": 0
       }
     }
     ```

     ```json
     {
       "success": false,
       "results": [],
       "errors": [
         {
           "message": "TEST: abort cascade after item 50",
           "status_code": 500,
           "lists": [
             {
               "id": "dbd3d7da-4151-4ad5-a01c-bd762fd1190f",
               "list_id": "cascade-probe-100"
             }
           ]
         }
       ],
       "summary": {
         "total": 1,
         "succeeded": 0,
         "failed": 1,
         "skipped": 0
       }
     }
     ```

   - **Dangling list on rule execution:** if a rule still refs a missing container, `getExceptions` / `findExceptionListItemsPointInTimeFinder` skip that `list_id` (null from `getExceptionList`) and PIT-find the rest. No warning. Rule runs; extra alerts possible. Rule Exceptions UI uses the same skip (`fetchExceptionListsItemsByListIds`), so the items table matches execution. Half-emptied leftover lists still apply remaining items.
   - **Parked a missing-list warn.** Tried logging via `ruleExecutionLogger.warn` during execution. Returning `warningMessages`, extra `getExceptionList`s, a second `onMissingListIds` callback, and stuffing `missingListIds` onto `executeFunctionOnStream` were all ugly. Reverted. Existing silent skip stands.

8. **Posted an inline comment asking to delete the container before items** — [discussion_r4045760782](https://github.com/elastic/kibana/pull/285608#discussion_r4045760782), anchored on `delete_exception_list_items_by_list.ts` line 103 (`bulkDeleteExceptionListItems` in the PIT loop). Quotes @denar50's design-review thread, includes the 2000-item page-2 repro and throw diff.
