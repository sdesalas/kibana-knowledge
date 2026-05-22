# PR Review — #270587: [Core] Add per-request timing to elasticsearch.query logger

**Scale:** Small PR (one component, ~33 added / 6 removed in the source file + 23 lines of test, single concern).
**Author:** @steliosmavro
**Base:** `main`
**Companion:** #270397 (which enables the `elasticsearch.query` debug logger for the `ess_air_gapped_with_bundled_large_package` FTR config).

## Summary

Adds per-request elapsed-time information to the `elasticsearch.query` debug log line. A `request` diagnostic listener stamps a `performance.now()` start time keyed by `event.meta.request.id`; the existing `response` listener computes `Math.round(performance.now() - startTime)` and the formatter appends ` - <N>ms` after the bytes segment. Map cleanup runs unconditionally so entries are never orphaned when debug logging is off. Stated intent (give the FTR `kibana-elasticsearch-snapshot-verify` test enough data to diagnose a perf regression) matches what the diff does.

## Files touched

- `src/core/packages/elasticsearch/client-server-internal/src/log_query_and_deprecation.ts` — the file that wires the ES client diagnostic events into Kibana's logger; the only place where ES query log lines are formatted, so this is the right (only) place for this change.
- `src/core/packages/elasticsearch/client-server-internal/src/log_query_and_deprecation.test.ts` — adds one new test asserting the `- \d+ms` segment is present when `request` and `response` are both emitted.

Both files are owned by `@elastic/kibana-core` per CODEOWNERS — this is a Core change, not a Security change. If you're reviewing as Detection Rule Management, you're outside the accountable team here; the impact on your team is purely "this is what the elasticsearch.query log lines will look like when we use them in Scout/FTR for perf debugging."

## Flow trace

1. Kibana boots and constructs an ES client; `instrumentEsQueryAndDeprecationLogger` is called once with that client (existing wiring, unchanged).
2. The function now subscribes to **two** `client.diagnostic` events instead of one:
   - `'request'` — new. Whenever a request is dispatched, if `event.meta.request.id` is set, store `performance.now()` in `requestStartTimes`.
   - `'response'` — existing. On every response (success or error).
3. In the response handler, before any logging branch, look up `event.meta.request.id` in `requestStartTimes`. If found, compute `duration = Math.round(performance.now() - start)` and **delete** the map entry. This cleanup is intentionally outside the `if (logQuery || logDeprecation)` guard so the map can't grow when debug logging is disabled.
4. If query or deprecation debug logging is enabled, `getQueryMessage(bytes, error, event, apisToRedactInLogs, duration)` is called.
5. `getQueryMessage` builds `durationMsg = duration !== undefined ? \` - ${duration}ms\` : ''` and threads it into `getResponseMessage` for both the success and `ResponseError` branches. Other-error branches still return `getErrorMessage(error)` only — no duration there (consistent with the pre-existing behavior of those branches not exposing status/bytes either).
6. `getResponseMessage` produces the final string `${statusCode}${bytesMsg}${durationMsg}\n${method} ${url}${body}` — i.e. duration sits in the same header line as status code and size, and the body is still on its own line for copy-paste into Dev Console.
7. Same `queryMsg` is reused inside the `deprecationLogger.debug(...)` branch, so deprecation log lines also carry the `- <N>ms` suffix as a side effect.

## Assumptions

- **`event.meta.request.id` is always populated by `@elastic/elasticsearch`'s transport for both `request` and `response` events, with the same value across the pair.** This is true today (the transport assigns an auto-incrementing id per client and reuses it across the request lifecycle), but it's a transport-internal detail with no contract — a future client upgrade could change the type from `number` to something else, or stop populating it for some event types. The `id` typing is `string | number` in the diagnostic types; using it as a `Map` key is correct.
- **For every emitted `request`, a corresponding `response` is eventually emitted (success or error).** If that ever isn't true (e.g. a transport-level bug, an aborted request that doesn't surface a `response` event, or a process-shutdown race), entries leak in `requestStartTimes` until the client (and thus the closure) is GC'd. In practice clients live as long as the Kibana process so this would manifest as slow memory growth.
- **`performance.now()` from `perf_hooks` is the right clock.** It's monotonic per-process and high-resolution, so subtraction gives sane elapsed times even across clock changes — better than `Date.now()` for this purpose. Good choice.
- **Subscribing to `'request'` unconditionally is acceptable overhead.** Even when no debug logging is ever enabled, every ES request now does an extra `Map.set` + `performance.now()` and the response side does a `Map.get`/`delete`. The same comment that already lives in this file ("we could check this once and not subscribe to response events if both are disabled, but then we would not be supporting hot reload") applies — the cost is small but non-zero on every ES call in every Kibana process.
- **Retries don't double-count or get lost.** If the ES client's retry logic re-emits `'request'` for the same id, the new start time overwrites the old one and the duration reflects only the last attempt. If retries get a new id, each gets its own entry. Either is plausible — see Open questions.

## Risks

Ordered by my best guess at severity. None feel high.

1. **Map leak if a `request` event has no matching `response`.** The cleanup is gated on the response side; there is no time-based eviction. In normal operation this should be zero-or-near-zero, but if the ES transport ever fails to emit a `response` for a dispatched `request` (process shutdown mid-flight, transport-level abort path that bypasses `response`), the start-time entry never goes away. Low probability, slow leak, but worth being aware of.
2. **Log-format consumers that parse the first line.** Anyone scraping or regexing `elasticsearch.query` log output (CI tooling, Kibana support tooling, downstream perf scripts) will now see an extra ` - <N>ms` segment between size and the newline. The PR is `release_note:skip`, which is appropriate, but if any internal tooling parses these logs strictly it'll need updating. This format change is the only externally visible behavior shift.
3. **Deprecation log lines now include the duration.** The same `queryMsg` is reused inside the deprecation branch, so deprecation messages also gain ` - <N>ms`. Probably desired, but not called out in the PR description.
4. **Negligible per-request overhead in non-debug environments.** `performance.now()` + `Map.set`/`get`/`delete` per ES request, always on. For Kibana installs that issue tens of thousands of ES requests per minute this is real but small. Almost certainly fine; mention only because the PR is in a hot path.

## Open questions

- **Does `@elastic/elasticsearch`'s retry path emit fresh ids per attempt or reuse one id across attempts?** This determines whether the recorded duration is "last attempt only" or "first dispatch to final response." Both could be argued for; the current code silently picks one based on transport behavior. If the goal is diagnosing perf regressions, "total wall-clock including retries" would usually be more useful — worth confirming with a quick look at transport docs or test.
- **Is there ever a path where `request` fires but `response` doesn't?** I couldn't conclusively rule this out from the @elastic/elasticsearch transport. If yes, would a `WeakMap`-based or TTL-based approach be safer? (Probably overkill for this use case — flag, don't block.)
- **Should `Math.round` be `Math.floor` or kept as a float?** Sub-millisecond requests will display as `0ms`, and a cluster of `0ms` lines may look odd next to a few `1ms` ones. Not worth changing, but a one-decimal format (e.g. `0.4ms`) would be marginally nicer for diagnostics. Worth a sentence with the author.
- **Does the new test exercise the duration computation meaningfully?** Two synchronous `emit` calls back-to-back will almost always produce `0ms`, and the assertion is `/- \d+ms/`, which matches `- 0ms`. The test verifies that duration is _appended_, not that it's _correct_. That's probably fine for unit-test scope (the formatter is what we're testing), but you could mock `performance.now` to assert `- 42ms` exactly if you wanted a sharper test.
- **Is appending in the header line the right place?** Putting it after bytes (`200 - 73.0B - 45ms`) is reasonable; an alternative is end-of-line (`GET /foo - 45ms\n{body}`) which is closer to where humans look when scanning for slow queries. The chosen position keeps the body line clean for copy-paste into Dev Console, which is probably the right tradeoff.

## Notes for your codebase map

- `src/core/packages/elasticsearch/client-server-internal/src/log_query_and_deprecation.ts` is the **single chokepoint** for ES query/deprecation/warning log instrumentation in Kibana — every ES log line that mentions a query is shaped here. If you ever need to add structured fields, redact something, or change format, this is the file.
- The ES client exposes lifecycle observation via `client.diagnostic.on('request' | 'response' | ...)`. Kibana already uses `'response'`; this PR is the first time `'request'` is also observed. Pattern: keep handlers idempotent and don't forget cleanup.
- `event.meta.request.id` is an `@elastic/elasticsearch`-assigned correlation id (`string | number`) usable to pair `request` and `response` events for the same in-flight call. Useful for any future cross-event diagnostics in this file.
- The file's existing pattern of subscribing on instrumentation regardless of log-level enables hot reload of logging config — the response handler re-checks `isLevelEnabled('debug')` on each event. Any new diagnostics work in this file should follow the same pattern (subscribe always, branch on level inside the handler).
- There's a deliberate split between the ES "query" log channel (`logger.get('query', type)`) and the per-request override (`logger.get('query', loggerName)` from `requestLoggingOptions.context.loggingOptions.loggerName`). Plugins can route specific ES requests to a custom logger by setting `loggingOptions.loggerName` on the request context — relevant if Detection Rule Management ever wants its own ES query log channel.
