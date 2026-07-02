# Duplicate rules on large import: a retry race, not a chunking bug

This is an investigation into retry behavior experienced in local dev environment when
processing large imports (taking longer than 2 minutes to process).
## TL;DR

Importing a 12,000-rule `.ndjson` into a **clean** stack produced **12,400** installed
rules and a response of `success_count: 400` + `11,600 × 409 "Rule with this rule_id
already exists"`. The file was fine and the Option B chunking was fine. The real cause:
the single browser upload was **re-dispatched ~120 s later** (a 2-minute timeout retry),
so **two overlapping executions of the same import** raced. Rule import is a
read-then-create with no `rule_id` uniqueness constraint, so the overlap created 400
duplicate rules.

> **This is a pre-existing bug, not introduced by the bulk import path.** The same
> `"Rule with this rule_id already exists"` reproduces on the **legacy** import path (bulk
> flag off) with ~6,000 rules on a local deployment. There the retry lands after the
> original has already created *every* rule, so **all 6,000** come back as 409 conflicts
> (the retry creates nothing new — no duplicates). The bulk path shows the same race but,
> because the retry overlaps the original mid-flight, it hits only a *subset* as conflicts
> and duplicates the unrefreshed tail. Same root cause (timeout retry + read-then-create,
> no `rule_id` uniqueness); the surface differs only in timing.

## Symptom

- File: `12000rules.internal.ndjson`, 12,000 rules, all internal (`rule_source.type:
  internal`, `immutable: false`, `version: 1`), unique `rule_id`/`id`.
- Bulk path (`bulkCreateRulesEnabled`) on, batch size `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE`
  dropped to 4000 for testing.
- Clean ES (no rules).
- Response: `success: false`, `success_count: 400`, `rules_count: 12000`,
  `errors: 11,600 × {status_code: 409, "Rule with this rule_id already exists"}`.
- UI reported **12,400** installed rules.

## Investigation (data, not vibes)

All queries hit local ES (`.kibana_alerting_cases_9.5.0_001`). APM traces live in the
**remote monitoring cluster**, so those were read there, not locally.

1. **File is clean.** 12,000 rows, 0 duplicate `rule_id`/`id`/`name`.

2. **Response is internally consistent.** 400 success + 11,600 unique 409s = 12,000; all
   11,600 error ids are in the file.

3. **The 400 "successes" are exactly the file tail.** Positions **11600–11999** — the tail
   of the last batch. First 11,600 → 409, last 400 → success.

4. **Duplicates are real and are those same 400.** ES: total `12,400`, distinct `rule_id`
   ~`12,000`, and exactly **400** `rule_id`s with `doc_count: 2`. Cross-check: the 400
   duplicated ids == the 400 the response called "success" (100% overlap), positions
   11600–11999.

5. **Both copies of each duplicate were created ~1 s apart, at the very end.** e.g.
   `12:09:14.910` + `12:09:15.714`; `12:09:16.816` + `12:09:17.850`. All creation spanned
   `12:07:06 → 12:09:17`.

6. **APM: the same request ran twice, overlapping.** Import transactions:

   | tx | trace | start | duration | ends |
   |----|-------|-------|----------|------|
   | Tx2 | `1210aa13…` | 12:06:02.9 | 13.5 s | 12:06:16 |
   | **Tx1** | **`983e40a8…`** | 12:07:00.5 | 137.4 s | **12:09:17.9** |
   | **Tx3** | **`983e40a8…`** | 12:09:00.9 | 18.0 s | **12:09:18.9** |

   Tx1 and Tx3 **share a `trace.id`** (same logical request) with different
   `transaction.id`s. Tx3 starts **120.4 s** after Tx1 — a 2-minute timeout retry. Tx1 and
   Tx3 overlap `12:09:00.9 → 12:09:17.9`, and the duplicate creations (12:09:14–17) fall in
   that window.

   Confirmed by re-running: one browser click, two server POSTs `~2 min` apart.

## Root cause

1. The large import takes >120 s to respond, and the request is **re-sent after ~120 s** —
   same trace, new execution. The timeout that fires and the layer that re-issues sit in
   front of the route handler, not in the import code itself — re-issuing a request on an upstream socket timeout (see "Open question: where the retry
   originates" below).
2. The re-dispatch is almost certainly the **dev basePath proxy** (`dev.basePathProxyTarget`)
   re-forwarding, not the browser: the retry re-used the original `traceparent` (Tx1 and Tx3
   share a `trace.id`), whereas a browser retry would mint a fresh trace. That proxy is
   dev-only, and well-behaved prod proxies/LBs and browsers do not retry `POST`, so this
   exact trigger is unlikely in production. The hole it exposes is not dev-only, though: any
   double submission — a double-click, a refresh-and-resubmit, or an LB set to retry on
   gateway timeouts — drives the same race.
3. Rule import is **read-then-create**: `findRules` for `rule_id` conflicts, then
   `bulkCreateRules`. `rule_id` is **not** a uniqueness key at the SO/ES layer — only the
   conflict check guards it.
4. The retry (Tx3) started while the original (Tx1) was finishing. Tx3's conflict check saw
   the 11,600 rules Tx1 had already committed → 409. The tail 400 weren't visible yet
   (created <1 s earlier / not refreshed), so Tx3 **created them again** → 400 duplicates.
5. The saved response is **Tx3's** (the retry). Tx1's own response would have been ~12,000
   success.

## What it is NOT

- **Not the fixture.** 12,000 distinct rules; nothing duplicated in the file.
- **Not the Option B chunking.** Batches are disjoint and each does conflict-check before
  create, so a *single* clean run reports 12,000 success / 0 conflict / 0 dupes regardless
  of batch count. Reproduced logic is correct; the 1,200-rule file (~13 s, well under the
  120 s timeout) imports cleanly every time.

## Why 1,200 was always clean

~13 s runtime, nowhere near the 120 s timeout, so no retry, no overlap.

## Recommendations

Two classes: mitigations that stop the corruption by serializing, and changes that make
import idempotent so it cannot dupe regardless of retries. Only the latter fully closes the
window.

**Stop the corruption (narrow the window):**

1. **Import-route concurrency limiter** (`RULE_MANAGEMENT_IMPORT_CONCURRENCY = 1` +
   `routeLimitedConcurrencyTag`) — present in the reference implementation, missing from the
   current route. The retry then waits for the original, sees all rules as conflicts, and
   creates nothing → all-409 response, zero duplicates. (See
   `reports/security_solution_route_concurrency_limiter.md`.)
2. **Per-space import lock** — the deployment already has a `.kibana_locks` index. A lock
   keyed by (import, space) serializes imports explicitly and also guards cross-request
   double submissions.
3. **Keep imports fast** (the Option B chunking already helps) so they finish under common
   proxy/LB timeouts and never invite a retry. Runtime reduction, not a correctness fix.

**Close the window (true idempotency):**

4. **Deterministic SO id from `rule_id` (+ space) with `op_type: create`.** The dupe is only
   possible because each create gets a fresh random SO `_id` while `rule_id` is a plain
   attribute, so two creates for one `rule_id` both succeed. A `rule_id`-derived `_id` with
   no-overwrite makes the second create hit a `409` at the SO layer — the only option that
   fully closes the race. Caveat: rules currently use random UUID SO ids with `rule_id`
   separate (arbitrary user string, prebuilt vs custom, migration of existing rules), so it
   is a real behavior change — confirm the rules client accepts a `rule_id`-derived id
   cleanly first.
5. **Asynchronous import via Task Manager** — return `202` + task id, run in the background,
   poll for status. Removes the long synchronous request that invites the timeout/retry
   altogether; best structural fit for imports that run for minutes. Largest scope.
6. **Request idempotency key** — client sends a stable key, server dedupes replays. Standard
   retry-safe pattern, but needs UI cooperation and a small server-side store.

Narrowing-only, not a fix on its own: refreshing the index before the conflict `findRules`,
or per-rule conditional creates, shrink the window but two simultaneous creates can still
both miss.

## Files involved

Import flow touched by this race (paths under
`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/`
unless noted):

- `api/rules/import_rules/route.ts` — import endpoint; triggered twice by the retry.
- `api/constants.ts` — `RULE_MANAGEMENT_IMPORT_CONCURRENCY` and the batch-size constants.
- `logic/import/import_rules.ts` — orchestrator; chunks per path (legacy vs bulk).
- `logic/detection_rules_client/methods/bulk_import_rules.ts` — **bulk path** read-then-create:
  `findRules` conflict lookup → `rulesClient.bulkCreateRules`. Where the tail-duplication
  surfaces.
- `logic/detection_rules_client/methods/import_rules.ts` +
  `logic/detection_rules_client/methods/import_rule.ts` — **legacy path** (flag off);
  per-rule read-then-create. The all-conflict 6k repro runs through here.
- `logic/search/find_rules.ts` — the conflict read (`rule_id` OR-list) used by both paths.
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
  — creates each rule with a fresh SO id and no `rule_id` uniqueness check, so a racing
  create inserts a second row for an existing `rule_id`.

## Open question: where the retry originates

Here is the most likely explanation:

Dev request path: **browser → base path proxy (user port, e.g. 5606) → `@hapi/h2o2` →
Kibana server child process (`dev.basePathProxyTarget`, e.g. 5616)**. In `--dev`,
`@kbn/cli-dev-mode` runs the base path proxy in the CLI parent process and spawns the actual
Kibana server as a child (managed/restarted by `dev_server.ts`). The `_import` route runs in
that child; the APM `process.pid` on the transactions is that child.

What the proxy code shows (`packages/kbn-cli-dev-mode/src/base_path_proxy/http1.ts`):

- Proxies every method via `@hapi/h2o2` with `passThrough`/`xforward`, `maxPayload: 1 GB`,
  `validate: { payload: true }`.
- **No explicit `timeout`** on the proxy handler, and h2o2 forwards once (no built-in
  retry). So neither the ~120 s value nor the re-dispatch is configured here — both come
  from a default or a layer below.

Leads to check when pinning it:

- `@kbn/server-http-tools` `getServerOptions` — the socket / keep-alive / payload timeouts
  applied to both the proxy server and the real server. A ~2-minute socket timeout here is
  the prime suspect.
- `@hapi/h2o2` → `@hapi/wreck` upstream request defaults (socket/response timeout) and its
  agent — confirm whether wreck errors at ~120 s and whether anything re-issues on that
  error.
- Node HTTP server defaults on the child (`server.requestTimeout`, `headersTimeout`,
  `keepAliveTimeout`).
- APM (monitoring cluster): two transactions share one `trace.id`, ~120 s apart, distinct
  `transaction.id`; inspect each transaction's `parent.id` span to see whether the second is
  a proxy re-forward. Correlate with any `dev_server.ts` worker restart at that moment — a
  mid-import recompile could also re-issue the request.
- Cheap isolation repro: put an artificial >120 s handler behind the dev proxy (no large
  payload, no ES) and watch for a second downstream request; that separates the timeout from
  import/ES specifics.

## Reproduce

- Import `12000rules.internal.ndjson` via the UI on a clean stack with
  `bulkCreateRulesEnabled` on.
- Watch APM (remote monitoring cluster), filter `transaction.name: "POST
  /api/detection_engine/rules/_import"`. Two transactions ~120 s apart sharing one
  `trace.id` = the retry.
- Or check ES: `total siem alerts` > file count and ~400 `rule_id`s with `doc_count: 2`.
