# Kibana Idle Heap Analysis

**Total heap:** 630.5 MB  
**Snapshot type:** V8 heap snapshot with allocation tracking  
**Plugins discovered:** 236

---

## Finding 1 — APM instrumentation (~265 MB, 42% of heap)

This is the single biggest cost and almost certainly unexpected in magnitude.

| Source | Allocated |
|---|---|
| `require-in-the-middle` | 216.2 MB (34.3%) |
| `elastic-apm-node` | 49.5 MB (7.8%) |

`require-in-the-middle` (RITM) is the mechanism `elastic-apm-node` uses to monkey-patch modules for distributed tracing. For every `require()`-able module it instruments, RITM creates closure wrappers that retain the original exports. With 236 plugins and hundreds of packages loaded at startup, those closures accumulate.

The smoking gun: `(no plugin frame in alloc stack)` in the plugin allocation table is **219.7 MB** — nearly identical to RITM's 216.2 MB. RITM runs as pre-plugin infrastructure so its allocations fall into the unattributed bucket. They match.

**Actions:**
- If APM is on in a non-prod environment: disabling it recovers ~265 MB immediately.
- If APM must be on: check whether the instrumented module list is over-broad. APM can be told to instrument only specific modules (ES client, HTTP). Every module removed from the list eliminates its RITM wrapper closure.
- `@kbn/tracing` (5.9 MB allocated) configures APM. If tracing is disabled in config, this 5.9 MB should not be allocated at all.

---

## Finding 2 — Zod / connector schema eager construction (~88 MB allocated, 82 MB saved)

`zod` is 14.0% of allocations (88.4 MB live). The biggest drivers:

| Package | Allocated | What it does |
|---|---|---|
| `@kbn/config-schema` | 64.3 MB | Kibana's zod wrapper for route + config schemas |
| `@kbn/connector-schemas` | 18.6 MB | Zod schemas for all connector types |
| `@kbn/connector-specs` | 16.2 MB | Specs for all connector types |

The connector schema cost is the clearest fix. `@kbn/actions-plugin` + `@kbn/stack-connectors-plugin` together allocate **51 MB** (plugin allocation view) but only retain **3.7 MB** (dominator view). The delta is almost entirely `connector-schemas` + `connector-specs` — every schema for every connector type, built at startup, whether or not that connector is enabled or ever used. These two packages account for 34.8 MB and are a textbook lazy-load candidate: build/import a connector's schema only when that connector type is first registered.

`@kbn/config-schema` at 64.3 MB is harder to avoid (it's on the load path for all HTTP routes), but worth checking for schema deduplication — if the same shape is expressed as multiple independent `schema.object({...})` calls, each creates its own zod tree.

---

## Finding 3 — i18n eager message parsing (~22 MB allocated, 19.5 MB saved)

| Source | Allocated |
|---|---|
| `@kbn/i18n` | 21.9 MB |
| `@formatjs/icu-messageformat-parser` | 8.0 MB |
| `intl-messageformat` | 7.3 MB |
| `@formatjs/intl` | 4.3 MB |

All translation messages for all plugins are parsed into ICU ASTs at registration time. The saved figure (19.5 MB) confirms this data isn't shared load-bearing infra — it's the message ASTs themselves. On the server side, most of these messages are never formatted at idle (they're for UI strings or error paths that haven't been hit). Deferring AST compilation to first-use would recover most of this with near-zero observable cost.

---

## Finding 4 — `gpt-tokenizer` eager load (~10.3 MB at idle)

The full BPE vocabulary table for GPT tokenization is in memory at server startup. This is only needed by AI assistant features. `@kbn/elastic-assistant-plugin` / `@kbn/inference-plugin` are loading it eagerly. Lazy-importing on first AI request is the fix — the vocabulary is a static file that doesn't need to be in RAM until someone invokes the assistant.

---

## Finding 5 — `@kbn/palettes` anomaly (~10.4 MB)

A color palette package has no business allocating 10 MB. This is almost certainly mis-attribution: some heavier library (likely a large constants file or lookup table) is being allocated in a call path that passes through palettes code before reaching its real owner. Worth checking what `@kbn/palettes` imports at module load time — if it eagerly imports a large chart theme object or vendor bundle, that would explain it.

---

## Summary

| Finding | Potential savings | Mechanism |
|---|---|---|
| RITM / APM instrumentation | ~265 MB | Narrow module list or disable APM |
| Connector schemas eager load | ~35 MB | Lazy-load per connector type |
| `@kbn/config-schema` zod | ~10–20 MB | Schema deduplication |
| i18n message ASTs | ~15–20 MB | Lazy ICU compilation |
| `gpt-tokenizer` | ~10 MB | Lazy import in AI plugins |
| `@kbn/palettes` | ~10 MB | Investigate load-time dep pull |
| `@kbn/screenshotting-plugin` | ~6 MB | Defer init to first screenshot |

The APM finding dwarfs everything else. If this snapshot was taken with APM enabled in a context where it isn't strictly needed, fixing that alone halves idle consumption before touching any plugin code.

---

## Raw Data Reference

### Heap Breakdown by V8 Node Type

| Node Type | Self | Self % | Count |
|---|---|---|---|
| string | 201.2 MB | 31.9% | 765,987 |
| array | 111.5 MB | 17.7% | 497,558 |
| object | 102.4 MB | 16.2% | 2,169,512 |
| code | 79.4 MB | 12.6% | 750,034 |
| closure | 50.5 MB | 8.0% | 882,067 |
| object shape | 34.5 MB | 5.5% | 439,615 |
| concatenated string | 19.8 MB | 3.1% | 618,430 |
| hidden | 17.9 MB | 2.8% | 370,372 |
| sliced string | 9.0 MB | 1.4% | 280,885 |

### Top Packages by Saved (counterfactual)

| Package | Retained MB | Saved MB |
|---|---|---|
| `zod` | 77.5 MB | 81.8 MB |
| `@kbn/i18n` | 8.3 MB | 19.5 MB |
| `@kbn/security-solution-plugin` | 18.7 MB | 19.3 MB |
| `@elastic/eui` | 14.2 MB | 14.4 MB |
| `@kbn/config-schema` | 9.4 MB | 9.6 MB |
| `@kbn/fleet-plugin` | 8.3 MB | 8.6 MB |
| `@kbn/alerting-plugin` | 6.4 MB | 6.6 MB |

### Top Packages by Allocation Site

| Package | Allocated MB |
|---|---|
| `require-in-the-middle` | 216.2 MB |
| `zod` | 88.4 MB |
| `elastic-apm-node` | 49.5 MB |
| `joi` | 46.4 MB |
| `@kbn/config-schema` | 64.3 MB |
| `@kbn/connector-schemas` | 18.6 MB |
| `@kbn/connector-specs` | 16.2 MB |
| `gpt-tokenizer` | 10.3 MB |
| `@hapi/hapi` | 9.8 MB |
| `@formatjs/icu-messageformat-parser` | 8.0 MB |
| `intl-messageformat` | 7.3 MB |
