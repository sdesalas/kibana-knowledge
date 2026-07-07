# Duplicate rules on large import: investigation log

Investigation into POST retry behavior experienced in local dev environment that creates
duplicate rules when importing a 12,000-rule `.ndjson` on a clean stack.

A single browser upload gets re-dispatched ~120s after the click (not visible in Network tab),
creating two overlapping executions of the same import run against Kibana. Rule import is a
read-then-create with no `rule_id` uniqueness constraint at the SO/ES layer, so the
overlap creates duplicate rules.

> **This is a pre-existing bug in local dev mode (ie the retry behavior - triggered by the local "base-path proxy" closing a socket connection), but the bulk import path manifests a worse outcome, creating rule duplication in addition to prior `409 Conflict` responses**
>
> The same `"Rule with this rule_id already exists"` reproduces on the **legacy** import
> path (bulk flag off) with ~6,000 rules on a local deployment. However, due to slower
> processing the retry lands after the original has already created *every* rule,
> so **all 6,000** come back as 409 conflicts (the retry creates nothing new — no duplicates).
> The bulk path shows the same race but, because the retry overlaps the original mid-flight,
> it hits only a *subset* as conflicts and duplicates the unrefreshed tail.

This document is a chronological log of what was tried and what it showed — including the
failed attempts and the tests that did *not* prove what they were supposed to. It is not a
recommendations doc.

## Symptom (as experienced)

- Fixture: `12000rules.internal.ndjson` — 12,000 rules, all internal
  (`rule_source.type: internal`, `immutable: false`, `version: 1`), unique
  `rule_id`/`id`.
- Bulk path (`bulkCreateRulesEnabled`) on, batch size
  `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE` = 4000 for testing.
- Clean ES (no rules).
- One browser click on the "Import rule" button.
- HTTP response returned to the UI (after ~2 min 15 s): `success: false`,
  `success_count: 400`, `rules_count: 12000`, `errors: 11,600 × { status_code: 409, "Rule
  with this rule_id already exists" }`.
- Rules list in the UI showed **12,400** rules — 400 more than the file contained.

The same "Rule with this rule_id already exists" error also reproduces on the **legacy**
import path (bulk flag off) with a smaller file (~6,000 rules) on a slower local
deployment. In that variant the retry lands after the original run has already committed
every rule, so all 6,000 come back as 409 conflicts and no duplicates are created. Same
underlying pattern, different timing.

## Investigation timeline

Each step: what we asked, what we did (with commands or code refs), what we saw.

### 1. Verified the fixture is clean

**Question:** are there duplicates in the input file itself?

Ran distinct-count queries against the ndjson (`jq`) and against the file after upload
(`_search` on the `.kibana_alerting_cases_*` index).

**Result:** 12,000 rows, 0 duplicate `rule_id` / `id` / `name`. File is fine.

### 2. Confirmed the response is internally consistent

Broke down the HTTP response body:

- `success_count`: 400
- `errors`: 11,600 unique `rule_id`s, all 409 with `"Rule with this rule_id already exists"`
- 400 + 11,600 = 12,000 = `rules_count`

All 11,600 error `rule_id`s are present in the file.

**The 400 "successes" are the tail of the file** — positions 11,600–11,999 (the last
batch of the file's ordering).

### 3. Confirmed the duplicates in ES and cross-checked

Queried the `.kibana_alerting_cases_9.5.0_001` index directly:

- Total rule SOs: **12,400**
- Distinct `rule_id`: **~12,000**
- `rule_id`s with `doc_count: 2`: exactly **400**

Cross-check: the 400 duplicated `rule_id`s are the same 400 the response called
"successes" — 100 % overlap, positions 11,600–11,999.

The two copies of each duplicate were created ~1 s apart at the very end of the run
(e.g. `12:09:14.910` + `12:09:15.714`; `12:09:16.816` + `12:09:17.850`). All creations
spanned `12:07:06 → 12:09:17`.

### 4. Read APM — found the request ran twice

Filtered APM by `transaction.name: "POST /api/detection_engine/rules/_import"` over the
run window (APM lives in the remote monitoring cluster).

| tx | trace | start | duration | ends |
|----|-------|-------|----------|------|
| Tx2 | `1210aa13…` | 12:06:02.9 | 13.5 s | 12:06:16 |
| **Tx1** | **`983e40a8…`** | 12:07:00.5 | 137.4 s | **12:09:17.9** |
| **Tx3** | **`983e40a8…`** | 12:09:00.9 | 18.0 s | **12:09:18.9** |

**Tx1 and Tx3 share a `trace.id`** with different `transaction.id`s. Tx3 starts
**120.4 s** after Tx1 — matches the 120 s socket-idle timeout on the **dev base-path
proxy's** listener (see steps 8 and 12; the child's per-route `idleSocket` is 1 h and does
not fire). Tx1 and Tx3 overlap `12:09:00.9 → 12:09:17.9`; the duplicate
creations `12:09:14–17` fall in that window.

**Conclusion at this point:** the import is racing against itself. Something is
re-dispatching the request at t+120 s. The next steps chase where the re-dispatch
originates.

### 5. Added per-layer ingress probes

To pin the retry-emitting layer, added two probes gated by
`KBN_DEBUG_IMPORT_RETRY=1` (off by default):

- `packages/kbn-cli-dev-mode/src/base_path_proxy/http1.ts` — new `logProxyIngress()`
  called in each `pre:` step of the h2o2 proxy route. Logs `remote=<host>:<port>`
  (TCP source port of whatever hits the proxy), `traceparent`, `x-forwarded-*`,
  `content-length`, timestamp. Also `listener.on('timeout', …)` logs the 120 s socket
  destroy events.
- `x-pack/solutions/security/plugins/security_solution/server/routes/import_retry_debug.ts`
  — new `registerImportRetryDebug()` that registers `core.http.registerOnPreAuth` and
  filters to `/api/detection_engine/rules/_import`. Logs `reqId`, `traceparent`,
  `X-Forwarded-For`, `X-Forwarded-Port`, `content-length`, `User-Agent`, timestamp.
  Wired in `plugin.ts` next to `registerLimitedConcurrencyRoutes(core)`.

Tags emitted:

- `[import-retry]` — dev proxy (front, `--server.port`)
- `importRetryDebug` — child Kibana (`--dev.basePathProxyTarget`)

### 6. Re-ran the import in Chrome — three POSTs at the server per click

Repro command (with the probes on):

```bash
KBN_DEBUG_IMPORT_RETRY=1 yarn start \
  --server.basePath=/kbn \
  --elasticsearch.hosts=http://localhost:9205 \
  --server.port=5606 \
  --dev.basePathProxyTarget=5616 \
  | tee /tmp/kbn-import-retry.log
```

In a second terminal:

```bash
: > /tmp/kbn-import-retry.log
tail -F /tmp/kbn-import-retry.log | grep -E '\[import-retry\]|importRetryDebug'
```

Then one click in the UI. Grepped the log after ~5 min:

```
proxy basePath ... remote=127.0.0.1:57367 ...  ts=T
child ingress ... xfport=57367 ...            ts=T
proxy socket timeout ... remote=127.0.0.1:57367 ts=T+120s
proxy basePath ... remote=127.0.0.1:57374 ...  ts=T+120s     ← new browser port
child ingress ... xfport=57374 ...            ts=T+120s
proxy socket timeout ... remote=127.0.0.1:57374 ts=T+240s
proxy basePath ... remote=127.0.0.1:59924 ...  ts=T+240s     ← new browser port
child ingress ... xfport=59924 ...            ts=T+240s
```

**Observations:**

- Three distinct `remote=127.0.0.1:XXXXX` values at the proxy — three separate inbound
  TCP connections. The proxy did not multiply a single connection into three upstream
  requests.
- Each `X-Forwarded-Port` at the child matches the corresponding proxy `remote` port
  1:1.
- Each new POST arrives 1–3 ms after the previous socket was destroyed by the 120 s
  timeout.
- Same `traceparent` on all three POSTs.
- DevTools showed **one** row for the request.

### 7. Ran the same import through curl — no retry

Command (adjust ndjson path to whatever is present locally):

```bash
curl -v \
  -X POST 'http://localhost:5606/kbn/api/detection_engine/rules/_import?overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true' \
  -H 'kbn-xsrf: whatever' \
  -H 'elastic-api-version: 2023-10-31' \
  -u elastic:changeme \
  -F 'file=@.knowledge/data/rules-import/12000disabled-rules.internal.ndjson' \
  -o /tmp/import-response.json \
  -w '\nhttp=%{http_code} time=%{time_total}\n'
```

**Result:** at t+120 s curl exits with `curl: (52) Empty reply from server`,
`http=100 time=~120`. The probe log shows exactly **one** proxy ingress and **one** child
ingress. No retry.

What this actually rules out is the set of layers that could *emit a new request on their
own*: node HTTP agent, kernel/loopback, libcurl, `@hapi/h2o2`, `@hapi/wreck`. curl went
**through** the dev base-path proxy and still received the same naked socket close at
t+120 s — it just didn't re-dispatch, because curl (unlike a browser) doesn't retry.

⚠️ **Correction (in light of step 12):** an earlier version of this step also listed
~~the dev base-path proxy itself~~ as "ruled out as a retry source." That is misleading.
The proxy does not *generate* the duplicate POST — but its listener's `socketTimeout`
closing the idle socket is the **trigger** the browser reacts to (proven in step 12).
So the proxy is ruled out as the *emitter* of the retry, **not** as the cause: it is the
hop whose socket close sets the retry off.

### 8. Where the 120 s comes from

Confirmed by reading the config schemas and the listener setup:

- `packages/kbn-cli-dev-mode/src/config/http_config.ts:36-38` — dev-proxy `socketTimeout`,
  default `120000` ms.
- `src/core/packages/http/server-internal/src/http_config.ts:161-163` — production
  Kibana HTTP server `socketTimeout`, also default `120 * SECOND`.
- `src/platform/packages/shared/kbn-server-http-tools/src/get_listener.ts:46-49` — the
  common listener helper used by both:

  ```ts
  listener.setTimeout(config.socketTimeout);
  listener.on('timeout', (socket) => {
    socket.destroy();
  });
  ```

  Both the dev proxy and the child Kibana listener register this handler. The idle
  timer starts once the request body has been fully received; if no response bytes are
  written back within `socketTimeout`, the socket is destroyed.
- `src/core/packages/http/server-internal/src/http_server.ts:1113-1115` — per-route
  hapi `timeout.socket` on the child, also defaulting to `this.config.socketTimeout`.

In the current repro the socket that gets destroyed and logged is the front proxy's
inbound socket. The child listener is subject to the same timeout on its own inbound
connection from h2o2. Our probe only logs proxy-side timeout events; child-side socket
teardown was not directly instrumented.

### 9. Disabled Elastic APM RUM — retry still happens

Added to `config/kibana.dev.yml`:

```yaml
elastic.apm.active: false
elastic.apm.enabled: false
elastic.apm.contextPropagationOnly: false
```

(The last line is required — without it Kibana refuses to start with `Error: APM is
disabled, but context propagation is enabled`.)

Restarted Kibana. Re-ran the import from the browser.

**Result:** Still three POSTs per click, still 120 s apart. `traceparent` is now `-` in
the probe output (as expected with APM off), pattern otherwise identical. Rules out
`@elastic/apm-rum` / Kibana APM instrumentation as the retry source.

### 10. Firefox 152 — three POSTs too

Same repro in a fresh Firefox 152 profile (`rv:152.0 Gecko` in `User-Agent`). Same
pattern: three POSTs, 120 s apart, new TCP source port each time.

This is *not* what Firefox's documented behaviour predicts — since Firefox 46 (2016)
Firefox is documented as *not* auto-retrying non-idempotent POSTs
([bugzilla 1269055](https://bugzilla.mozilla.org/show_bug.cgi?id=1269055)). We did not
confirm the mechanism against Firefox source.

### 11. Chrome through a MITM proxy — retry disappears

Setup mitmproxy in a separate terminal:

```bash
mitmdump \
  --listen-port 8080 \
  --set http2=false \
  --set stream_large_bodies=100m \
  --set flow_detail=2 \
  -w /tmp/mitm.flows \
  2>&1 | tee /tmp/mitm-dump.log
```

Verify it's up:

```bash
curl -s -o /dev/null -w 'proxy=%{http_code}\n' -x http://localhost:8080 http://example.com/
```

Launch a throwaway Chrome pointed through it (note the `<-loopback>` bypass override,
Chrome bypasses `localhost` for proxies by default):

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir=/tmp/chrome-mitm \
  --proxy-server=http://localhost:8080 \
  --proxy-bypass-list="<-loopback>" \
  http://localhost:5606/kbn &
```

Cleared the Kibana probe log, ran the import from that Chrome window. Grepped both
`/tmp/mitm-dump.log` and `/tmp/kbn-import-retry.log` for `_import`.

**Result:**

- mitmproxy saw **one** POST to `_import` from Chrome (client port `[::1]:62158`).
  Upstream: `server closed connection` at t+120 s. mitmproxy converted the closed socket
  into a `502 Bad Gateway` response and sent it to Chrome. The Kibana UI displayed a
  Bad Gateway error.
- The Kibana probe log showed **one** proxy ingress and **one** child ingress. Child
  handler ran to completion at t+2 min 13 s (`child completed`).
- The 12,000 rules were imported successfully — the server-side run finished, the
  browser just never saw the response.

**Key observation:** the retry did not fire when the browser received a real HTTP
response (502) from the intermediate proxy, instead of a naked socket close from Kibana.

### 12. Moved the timeout — retry moved with it (causation, not coincidence)

**Question:** is the ~120 s re-dispatch actually *caused* by the socket-idle timeout, or
just correlated with it?

Set `server.socketTimeout: 30000` in `config/kibana.dev.yml` (nothing was set before, so
the proxy had been on the `120000` default) and re-ran the browser import with the probes
on.

The dev proxy reads `server.socketTimeout` via `httpConfigSchema` in
`packages/kbn-cli-dev-mode/src/config/load_config.ts` — the **same** config key the child
Kibana HTTP server reads. `getServerOptions`
(`src/platform/packages/shared/kbn-server-http-tools/src/get_server_options.ts`) does
**not** set a per-route `routes.timeout.socket`; the only timer on the proxy's inbound
socket is the listener-level `setTimeout(config.socketTimeout)` + `socket.destroy()` from
`get_listener.ts`. So the proxy has no per-route escape hatch — unlike the `_import` route
on the child, which sets `idleSocket: 3600000` (1 h). That is why the route's 1 h override
never helped: it applies to the child, but the proxy destroys the browser connection first.

**Result:** the retry cadence moved from 120 s to **30 s**, to the millisecond:

```
proxy basePath ... remote=127.0.0.1:62909 ...        ts=09:33:34.488
child ingress ... xfport=62909 ...                   ts=09:33:34.495
proxy socket timeout (idle >30000ms) remote=…:62909  ts=09:34:04.649   ← +30.0s
proxy basePath ... remote=127.0.0.1:62902 ...        ts=09:34:04.649   ← retry, same instant
proxy socket timeout (idle >30000ms) remote=…:62902  ts=09:34:34.849   ← +30.0s
proxy basePath ... remote=127.0.0.1:62910 ...        ts=09:34:34.850   ← retry
```

**Conclusion:** the re-dispatch is *caused* by the dev proxy's `server.socketTimeout`
destroying the idle inbound socket — not merely coincident with it. Moving the knob moves
the retry 1:1. The re-dispatch is emitted by the browser within ~1 ms of the socket being
destroyed, and it fires repeatedly (a new POST every timeout interval) until the import
run outlives the window.

**Corollary (local mitigation):** raising `server.socketTimeout` above the import duration
(e.g. `3600000`) in `config/kibana.dev.yml` pushes the idle-close out past the run, so no
naked socket close, no browser retry, no duplicates — *locally*. This masks the race
rather than fixing it; any real upstream intermediary (Cloud proxy, ELB) with its own idle
timeout could still trip the same client behaviour. For how this maps to production —
where the dev proxy does not exist — see step 13.

### 13. The dev base-path proxy — the hop that closes the socket — does not run in production

**Question:** the socket that gets idle-closed at the timeout is the front dev proxy's
inbound socket (steps 8, 12). Does that proxy exist in a production deployment?

Traced the startup path:

- The dev base-path proxy is part of `@kbn/cli-dev-mode`, which is only bootstrapped under
  the `--dev` flag: `getBootstrapScript(cliArgs.dev)` in `src/cli/serve/serve.js`. With
  `--dev` false it uses core's `bootstrap` from `@kbn/core/server` — **no dev parent, no
  optimizer, no base-path proxy** (see also `.knowledge/operations/kibana_serve_and_start_dist.md`).
- `yarn start` is `node scripts/kibana --dev`, so local dev gets the proxy. Production does
  not: the Docker image entrypoint runs `bin/kibana` with **no `--dev`**
  (`CMD ["/usr/local/bin/kibana-docker"]` →
  `exec /usr/share/kibana/bin/kibana …` in
  `src/dev/build/tasks/os_packages/docker_generator/resources/base/bin/kibana-docker`).

**Conclusion:** the *specific reproduction in this log* — the front dev proxy destroying the
browser's inbound socket at `server.socketTimeout` (120 s) and the browser re-dispatching —
**cannot occur in production**, because that proxy hop only exists in `--dev`. In prod the
browser talks to Kibana through the deployment's own ingress (Cloud proxy / ELB / nginx),
not the dev proxy.

**What this does NOT rule out:** the underlying vulnerability — a naked socket close from
*any* intermediary with an idle timeout shorter than the import duration triggering a
browser re-dispatch against a non-idempotent read-then-create. Whether a production ingress
(e.g. the Cloud proxy's idle timeout) reproduces the same naked-close → retry has not been
tested. The `_import` route's per-route `idleSocket: 3600000` only governs Kibana's own
listener, not an upstream proxy. So: the dev-proxy manifestation is dev-only; the class of
bug may still be reachable in prod via a different hop.

**Related ECH constraint (confirmed):** on Elastic Cloud Hosted, setting
`xpack.securitySolution.maxRuleImportExportSize` and
`xpack.securitySolution.maxRuleImportPayloadBytes` in Kibana user settings causes the
instances to **fail to start** — reproduced across several retries. Kibana's own schema does
not cap either value (both plain `schema.number` with no `max`, see
`x-pack/solutions/security/plugins/security_solution/server/config.ts:26-27`), and they are
server-side (not in `exposeToBrowser`), so they are validated at boot. Because the values
`20000` / `209715200` are valid to Kibana, the mechanism is almost certainly the **Cloud
settings allowlist** (maintained in Cloud infra, not in this repo) rejecting these keys; the
exact startup `FATAL` line was not captured here, but the startup failure itself is
confirmed. **Implication:** on ECH the import limits are effectively pinned to the defaults
(`10000` rules / `10 MB` payload), which bounds how large a single import can get on Cloud
and therefore how the retry / duplication risk manifests there — the 12,000-rule
reproduction requires raising these limits, which is not possible on ECH via user settings.

## What is known

1. The import route is being called two or three times per single UI click. Each call is
   a separate POST arriving at the base-path proxy on its own TCP connection.
2. The re-dispatch is emitted client-side. The dev base-path proxy receives multiple
   inbound TCP connections; it does not fan one out.
3. The re-dispatch is **caused** by the dev proxy's socket-idle timeout closing the inbound
   socket, not merely coincident with it. Moving `server.socketTimeout` from 120 s to 30 s
   moved the retry to 30 s, 1:1 (see step 12). The browser re-dispatches within ~1 ms of the
   socket being destroyed, and repeats every interval until the run outlives the window.
4. The timeout value is defined once in the Kibana HTTP config schema (`server.socketTimeout`,
   default 120 s) and applied to both the dev proxy listener and the child Kibana listener via
   a shared helper (see steps 8 and 12). The proxy has no per-route override, so the `_import`
   route's own `idleSocket: 3600000` (1 h) never takes effect — the proxy closes the browser
   connection first. Raising `server.socketTimeout` past the import duration is a local-only
   mitigation that masks the race.
5. Chrome (`AppleWebKit/…`) and Firefox 152 (`rv:152.0 Gecko`) both reproduce the pattern.
   curl does not.
6. APM RUM off does not stop it.
7. mitmproxy in the middle stops it: it converts Kibana's socket close into a
   `502 Bad Gateway` response to the browser, and no retry fires.
8. The bulk rule import is a **read-then-create** with no `rule_id` uniqueness at the
   SO/ES layer:
   - `logic/detection_rules_client/methods/bulk_import_rules.ts` reads existing
     `rule_id`s via `findRules` then calls `rulesClient.bulkCreateRules`.
   - `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
     creates each rule with a fresh random SO `_id`. Two concurrent creates for the same
     `rule_id` both succeed because `rule_id` is a plain attribute.
   - The overlap window is where duplicates come from: Tx3's conflict check saw the
     11,600 rules Tx1 had already committed, but the tail 400 (created <1 s earlier and
     not yet visible) were not yet refreshed → Tx3 created them again.

## What has been ruled out

Each item lists the check that ruled it out.

- **The fixture** — 12,000 distinct rules; no duplicates in `rule_id`/`id`/`name`.
- **Chunking logic (Option B)** — batches are disjoint and each does conflict-check
  before create; a single clean run reports 12,000 success / 0 conflicts. Reproduced by
  importing a 1,200-rule file (~13 s, well under 120 s), always clean.
- **Base-path proxy re-forwarding** — three distinct `remote=127.0.0.1:XXXXX` source
  ports at the proxy per browser import, 1:1 with three distinct `X-Forwarded-Port`
  values at the child. The proxy receives three separate inbound TCP connections.
- **OS / kernel / loopback** — curl reproduces with a single POST at the server. No
  layer below the client application re-issues.
- **`@hapi/h2o2`** — `rg 'retry|redispatch|retries' node_modules/@hapi/h2o2` returns
  zero matches; the downstream `disconnect` handler calls `promise.req.destroy()`, which
  cancels the upstream request rather than retrying it.
- **`@hapi/wreck`** — zero retry matches; internal `options.timeout` produces a
  `Boom.gatewayTimeout` on expiry, not a retry.
- **`http2-proxy` + `http2-wrapper`** — zero retry matches (not on the path in the
  current repro, which reported HTTP/1.1).
- **`@kbn/cli-dev-mode` `dev_server.ts`** — only restarts the child on file-watcher
  events; no HTTP-level retry. No restart log lines appeared during the repro window.
- **Kibana core browser fetch** — `src/core/packages/http/browser-internal/src/fetch.ts`
  wraps `window.fetch` in a `try/catch` that throws on error. No retry.
- **Kibana core HTTP interceptors** —
  `src/core/packages/http/browser-internal/src/intercept.ts` contains no retry logic.
- **`importRules` and the import UI modal** —
  `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/api/api.ts`
  and `.../common/components/import_data_modal/index.tsx` call `http.fetch` inside an
  `AbortController`-based `await`; no retry, no `onError` re-invoke.
- **Elastic APM RUM** — retries persist with `elastic.apm.active: false` and
  `traceparent=-`.

## Still unresolved

- Why mitmproxy in the middle eliminates the retry. Established: when the browser talks
  directly to Kibana, the retry fires; when a MITM proxy is in the middle, the browser
  gets a `502 Bad Gateway` from the proxy (which is what the Kibana UI displayed on
  the mitmproxy run) instead of a naked socket close, and no retry fires. The exact
  browser-side rule that distinguishes the two cases was not investigated further — it
  does not help this investigation.
- Whether the child Kibana listener's own socket timeout fires and what its downstream
  effect is. Only the front-proxy timeout events are instrumented in the current probes.

## To narrow this further (not yet done)

- Add a child-side socket-timeout logger (mirror the front proxy's
  `listener.on('timeout', …)`) to confirm whether the child's inbound socket is also
  destroyed at 120 s.

## Streaming-response prior art in Kibana

Not a recommendation, just a pointer to existing precedent for the "server writes bytes
before the handler finishes" pattern that keeps the socket non-idle:

- `x-pack/platform/packages/shared/ml/response_stream/server/stream_factory.ts` — the
  original `streamFactory(logger, isCloud)`. Returns
  `{ push, end, responseWithHeaders }`. Under the hood it wires a `PassThrough` stream
  and pushes to the client. When `isCloud` is true it emits a periodic
  `: keepalive <padding>\n\n` chunk every 250 ms to defeat cloud proxy buffering.
- `x-pack/solutions/search/plugins/search_playground/server/utils/stream_factory.ts` —
  an adapted copy of the same pattern, minus gzip and ndjson.
- `examples/response_stream/server/routes/single_string_stream.ts` — full example of a
  route that returns a streaming response:

  ```ts
  const { end, push, responseWithHeaders } = streamFactory(
    request.headers,
    logger,
    request.body.compressResponse
  );
  // ... push(...) asynchronously ...
  return response.ok(responseWithHeaders);
  ```

## Files touched during investigation

Instrumentation (added for this investigation, gated by `KBN_DEBUG_IMPORT_RETRY=1`).
Full diff:
[duplicate-import-retry-race.debug.patch](https://github.com/sdesalas/kibana-knowledge/blob/main/patches/duplicate-import-retry-race.debug.patch).

- `packages/kbn-cli-dev-mode/src/base_path_proxy/http1.ts` — `logProxyIngress()` + socket
  timeout logger.
- `x-pack/solutions/security/plugins/security_solution/server/routes/import_retry_debug.ts`
  — new file registering `core.http.registerOnPreAuth` for `_import`.
- `x-pack/solutions/security/plugins/security_solution/server/plugin.ts` — call
  `registerImportRetryDebug(core, logger)` alongside `registerLimitedConcurrencyRoutes`.

Import flow read while investigating (paths under
`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/`
unless noted):

- `api/rules/import_rules/route.ts` — import endpoint; triggered twice by the retry.
- `api/constants.ts` — `RULE_MANAGEMENT_IMPORT_CONCURRENCY` and the batch-size constants.
- `logic/import/import_rules.ts` — orchestrator; chunks per path (legacy vs bulk).
- `logic/detection_rules_client/methods/bulk_import_rules.ts` — bulk path
  read-then-create.
- `logic/detection_rules_client/methods/import_rules.ts` +
  `logic/detection_rules_client/methods/import_rule.ts` — legacy path (flag off).
- `logic/search/find_rules.ts` — the conflict read (`rule_id` OR-list).
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`
  — creates each rule with a fresh SO id.

Config / infra read while investigating:

- `packages/kbn-cli-dev-mode/src/config/http_config.ts` — dev proxy `socketTimeout`
  default (120 000).
- `src/core/packages/http/server-internal/src/http_config.ts` — production Kibana
  `socketTimeout` default (also 120 s).
- `src/platform/packages/shared/kbn-server-http-tools/src/get_listener.ts` — the
  `listener.setTimeout` + `socket.destroy()` used by both.
- `src/core/packages/http/server-internal/src/http_server.ts` — per-route hapi
  `timeout.socket`.
- `packages/kbn-cli-dev-mode/src/base_path_proxy/http1.ts` and
  `.../base_path_proxy/http2.ts` — dev proxy handlers.
- `node_modules/@hapi/h2o2/lib/index.js`, `node_modules/@hapi/wreck/lib/index.js` —
  proxy libs verified for retry code.
- `src/core/packages/http/browser-internal/src/fetch.ts`,
  `.../intercept.ts` — Kibana core browser fetch, verified for retry code.

## Reproduce

### Original (UI) repro

- Import `12000rules.internal.ndjson` via the UI on a clean stack with
  `bulkCreateRulesEnabled` on.
- In APM (remote monitoring cluster) filter
  `transaction.name: "POST /api/detection_engine/rules/_import"`. Two transactions
  ~120 s apart sharing one `trace.id` = the retry.
- In ES: `total siem alerts` > file count and ~400 `rule_id`s with `doc_count: 2`.

### Local debug repro with per-layer ingress probes

Probes are gated by `KBN_DEBUG_IMPORT_RETRY=1` (off by default).

**Start Kibana with the flag on and tee the output:**

```bash
KBN_DEBUG_IMPORT_RETRY=1 yarn start \
  --server.basePath=/kbn \
  --elasticsearch.hosts=http://localhost:9205 \
  --server.port=5606 \
  --dev.basePathProxyTarget=5616 \
  | tee /tmp/kbn-import-retry.log
```

**In a second terminal, tail just the probe output:**

```bash
tail -F /tmp/kbn-import-retry.log | grep -E '\[import-retry\]|importRetryDebug'
```

Emit tags:

- `[import-retry]` — dev proxy (front, `--server.port`).
- `importRetryDebug` — child Kibana (`--dev.basePathProxyTarget`).

**Clear the log between runs (leaves `tail -F` intact):**

```bash
: > /tmp/kbn-import-retry.log
```

**Summarize a run:**

```bash
grep -aE '\[import-retry\]|importRetryDebug' /tmp/kbn-import-retry.log \
  | grep -oE 'proxy (basePath|bypass)|child ingress|child completed|child aborted|socket timeout|socket close\(hadError\)' \
  | sort | uniq -c
```

A clean single request is `1 proxy basePath / 1 child ingress / 1 child completed`. The
retry shows as ≥2 of the first two.

### curl baseline (no retry)

Run from the repo root, adjust the ndjson filename to match what's present locally:

```bash
curl -v \
  -X POST 'http://localhost:5606/kbn/api/detection_engine/rules/_import?overwrite=true&overwrite_exceptions=true&overwrite_action_connectors=true' \
  -H 'kbn-xsrf: whatever' \
  -H 'elastic-api-version: 2023-10-31' \
  -u elastic:changeme \
  -F 'file=@.knowledge/data/rules-import/12000disabled-rules.internal.ndjson' \
  -o /tmp/import-response.json \
  -w '\nhttp=%{http_code} time=%{time_total}\n'
```

Expected outcome (~2 min): `curl: (52) Empty reply from server`,
`http=100 time=~120`. Probe log shows exactly one `proxy basePath` and one `child
ingress`.

### Disabling Elastic APM RUM (control)

Add to `config/kibana.dev.yml`:

```yaml
elastic.apm.active: false
elastic.apm.enabled: false
elastic.apm.contextPropagationOnly: false
```

Restart. Browser repros continue to show three POSTs per import; `traceparent` becomes
`-` in the probe output.

### Chrome through a MITM proxy

Install mitmproxy:

```bash
brew install mitmproxy
```

Start it in its own terminal (leave running for the whole repro):

```bash
mitmdump \
  --listen-port 8080 \
  --set http2=false \
  --set stream_large_bodies=100m \
  --set flow_detail=2 \
  -w /tmp/mitm.flows \
  2>&1 | tee /tmp/mitm-dump.log
```

Verify it's listening:

```bash
curl -s -o /dev/null -w 'proxy=%{http_code}\n' -x http://localhost:8080 http://example.com/
# expected: proxy=200
```

Launch a throwaway Chrome pointed at it. The `<-loopback>` bypass override is required —
Chrome bypasses `localhost` for proxies by default:

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir=/tmp/chrome-mitm \
  --proxy-server=http://localhost:8080 \
  --proxy-bypass-list="<-loopback>" \
  http://localhost:5606/kbn &
```

Log into Kibana in that window. Trigger the import.

Read the `_import` flows after the run:

```bash
grep -cE '^\[::1\]:[0-9]+: POST http://localhost:5606/kbn/api/detection_engine/rules/_import' /tmp/mitm-dump.log
```

Expected outcome: **1** POST at mitmproxy, **1** proxy ingress in the probe log, **1**
child ingress, `child completed` at ~t+2 min 13 s. Chrome shows a `502 Bad Gateway`
(synthesized by mitmproxy). No retry.

## Next steps

Two independent pathways to investigate, in no particular order.

1. **Respond earlier to avoid timeout.** Investigate ways to either keep the connection
   open with a streamed response or return an early response from Kibana, so we don't
   trigger a retry with a closed connection. As one starting point among others,
   `@kbn/ml-response-stream` and
   `examples/response_stream/server/routes/single_string_stream.ts` (see
   "Streaming-response prior art in Kibana" above) show how a route can send response
   headers early and push the body asynchronously; whether that shape fits `_import` is
   an open question.
2. **Idempotency — make retries harmless.** Investigate ways to make the `_import` call
   idempotent, so that a retry does not cause additional records to be created. Code
   that touches the current
   read-then-create behaviour lives around
   `logic/detection_rules_client/methods/bulk_import_rules.ts` and
   `logic/search/find_rules.ts`; the underlying create path goes through
   `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`.
   These are anchor points to read while framing the problem, not a prescribed
   solution.
