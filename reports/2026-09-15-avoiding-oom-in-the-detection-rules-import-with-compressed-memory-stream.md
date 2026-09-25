# Avoiding OOM in the detection rules import with compressed memory stream

- **Date:** 2026-09-15 (heap numbers: 2026-09-25)
- **Status:** Design only. Not implemented.
- **Related:** [#275695](https://github.com/elastic/kibana/pull/275695) (import create path), [#290918](https://github.com/elastic/kibana/issues/290918) (10 MB payload cap)
- **Fixture:** `.knowledge/data/rules-import/12000disabled-rules.internal.ndjson`

---

## Summary

[`import_rules/route.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts) handles `POST /api/detection_engine/rules/_import`. 

It has to import **connectors and exceptions before rules**, but the NDJSON file is written the other way around, (see [`export_rules/route.ts` L115](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/export_rules/route.ts#L115)).

```
${rulesNdjson}         <-- Rules top of the file
${exceptionLists}      <-- Dependencies appear after 
${actionConnectors}        🤷‍♂ (oh dear)
${exportDetails}
```

Because of this, the route today slurps the whole upload. 

If we upload 10K rules, it loads ALL 10K rules into memory (200MB heap usage, 4-500MB RSS)(`createPromiseFromRuleImportStream` → `sortImports` → `createConcatStream([])`) before it does any writes.

| | heapUsed | RSS |
|---|---:|---:|
| 10KRetained (`rules` after the await) | **~120 MB** | **~450 MB** |
| Peak during the await (JSON.parse + Zod copy both live) | **~160–200 MB** | **~490 MB** |

See [Heap measurement](#heap-measurement) below.

A file that mixes rules, exceptions, and connectors — with connectors and exceptions required first — is a **poor streaming format**: you cannot emit a usable first batch until you’ve seen the tail. Scanning backwards would also get you the tail first, but it’s a bad idea. A `HapiReadableStream` (and a single zstd/deflate blob) only goes forward, so “backwards” means buffering the whole thing anyway.

There is another pproach that works here, to **forward classify and compress**. Read the Hapi upload once. Park connectors and exceptions in small arrays. Spill rule lines into one **in-memory [zstd](https://en.wikipedia.org/wiki/Zstd) stream**.

When the upload ends, import deps, then stream-inflate rules in batches of 200. That matches the [DRC comment](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules/import_rules.ts#L70-L71) that outer batching should live in `route.ts` if we ever stop holding every rule in RAM.

zstd level 3 (Node 24 `zlib`, no extra dep) took a 12k-rule fixture from **102 MB → 16.9 MB in 185 ms**. This approach reduced memory usage by not keeping 12k parsed rule objects.

---

## Approach

The following approach used in a 10K rule import would **reduce peak heap by ~10×** from ~160–200 MB to 15–20 MB. See [Expected heap (before vs after)](#expected-heap-before-vs-after).

We create one in-memory zstd stream for rule lines.

The existing maps already run **one line at a time** (split → parse → filter → migrate → strip). The memory problem is `sortImports`: it is a reduce that keeps every parsed rule until the file ends. Do not do that.

Classify each parsed object the way `sortImports` already does (top-level keys only):

- `list_id` / `item_id` / `entries` → exception (keep)
- `attributes` → connector (keep)
- `exported_count` → drop
- parse / schema failure populate → `errors[]`, drop the object
- else → rule: write the **raw line bytes** to the zstd stream, then discard the parsed object

Exceptions and connectors are tiny. Leave them as arrays. `errors[]` is a `BulkError` list passed forward — do not mix `Error` into a `rules[]`. If you keep parsed rules, compression is pointless.

```ts
// after the Hapi stream is fully classified and rulesZstd.end()
await importRuleActionConnectors({ actionConnectors, ... });
await importRuleExceptions({ exceptions, ... });

for await (const batch of inflateNdjsonBatches(rulesZstd, 200)) {
  await detectionRulesClient.importRules({ rules: batch, ... });
}
```

Inflate rules **forward** (file order) with `createZstdDecompress()`, parse, chunk 200, discard the batch. Do not `zstdDecompressSync` the whole rules blob or you’re back to holding every rule.

The upload still has to finish before you can import connectors — they sit at the end of the file, not the end of the TCP stream. And if the route starts yielding 200-rule batches, move outer DRC batching up so you don’t chunk twice.

---

## Codec and numbers

In-memory repetitive JSON on Node 24.21. Use `zlib.createZstdCompress` / `createZstdDecompress`.

| | ratio | speed | in `node:zlib` | |
|---|---|---|---|---|
| **zstd -3** | better than deflate | fastest of the good-ratio ones | yes | **use this** |
| deflate / gzip | fine | slower | yes | `deflateRaw` if you must |
| brotli | best | slower on the request path | yes | static assets, not this |
| lz4 | weaker | very fast | extra dep | skip |

Don’t compress per line — header overhead kills the ratio. One rules stream. Independent ~64 KB blocks only if you later need a real reverse walk.

**Fixture** (12,000 lines, 102,074,802 bytes). Whole file, one blob, `*Sync` APIs. No `.zst` written.

| algorithm | size | ratio | time |
|---|---:|---:|---:|
| zstd -1 | 21.23 MB | 4.8× | 148 ms |
| **zstd -3** | **16.90 MB** | **6.0×** | **185 ms** |
| zstd -6 | 14.13 MB | 7.2× | 485 ms |
| deflateRaw / gzip | 21.88 MB | 4.7× | 971 ms |
| brotli q4 | 13.72 MB | 7.4× | 328 ms |

Brotli q4 saves another ~3 MB and isn’t worth it next to `bulkCreateRules`. This fixture is almost all rules, so three streams wouldn’t change the numbers.

```js
const { zstdCompressSync, constants } = require('node:zlib');
const src = require('node:fs').readFileSync(file);
zstdCompressSync(src, { params: { [constants.ZSTD_c_compressionLevel]: 3 } });
```

---

## What this does not do

- Raise `maxRuleImportPayloadBytes`. This 102 MB file still cannot be POSTed until [#290918](https://github.com/elastic/kibana/issues/290918).
- Stream off the socket. You wait for the upload, then process.
- Fix the file format. Classify-then-split is a workaround. A real large-file answer is an async import API.

---

## Dead ends

These were the first ideas. They don’t work without holding the whole file.

**Pipe Hapi into one compressed stream and read the last line first.** The pipe works. Seeking to the end does not. Inflate is front-to-back. Peak memory is compressed + full uncompressed — worse than keeping the NDJSON.

**Buffer every line, reverse(), then read.** Same memory as today’s concat. The Hapi upload isn’t seekable.

**One zstd of the whole file, then walk it backwards.** Same limit as deflate. Independently compressed pieces (per line or per 64 KB block) can be walked from the end. A single frame cannot.

---

## If we build it

1. Replace “parse everything into three arrays” in `createPromiseFromRuleImportStream` with classify-and-spill.
2. Keep connectors / exceptions as arrays.
3. One `createZstdCompress()` for rule lines. Stream-decompress, Zod-parse in 200s, pass each batch to `importRules`.
4. Move outer DRC batching to the route only if the route now yields batches.
5. Don’t compress deps. Don’t use brotli. Don’t use files.

---

## Compatibility

[`node:zlib`](https://nodejs.org/docs/latest-v24.x/api/zlib.html) ships Gzip, Deflate, Brotli, and Zstd. `createZstdCompress` / `createZstdDecompress` landed in **22.15 / 23.8**, so every Node 24+ has them. They are compiled into the Node binary — not an OS library — on official win/darwin/linux × x64/arm64/ppc64le/s390x builds.

Kibana pins `engines.node` to **24.21.0**. Local check: `typeof zlib.createZstdCompress === 'function'`.

**Stability 1 (Experimental)** means the *API* (option names, constants) may still move. The functions are not optional and will not be `undefined` on a normal 24+ binary. Node 26 still marks the zstd options experimental; the `zlib` module itself is Stability 2.

Missing only on Node **&lt; 22.15**, or a broken custom build (`--shared-zstd` with no libzstd). There is no `--without-zstd`. Not an Elastic concern.

gzip / deflate / brotli are older and stable. Same availability: bundled, all platforms. zstd is not weaker on coverage — only on API stability.

This path compresses and inflates in the **same process**. No host `zstd` CLI, no `.zst` on disk, no client-side codec.

---

## Heap measurement

Measured 2026-09-25. First 10,000 lines of `.knowledge/data/rules-import/12000disabled-rules.internal.ndjson`: **85,060,484 bytes (~81 MB)** NDJSON, ~8.5 KB/rule (eql, ~5.6 KB `note`). Isolated Node 24 process (`--expose-gc`). Zod cost is a same-shape object-graph clone (strings shared) — a stand-in for `RuleToImport.safeParse` in `validateRulesStream`.

RSS baseline for that process was ~43 MB, so this slurp is **+~410 MB retained / +~450 MB peak** on top of a Kibana server’s existing RSS.

- `JSON.parse` of 10k rules: **~114 MB** heap (~11–13 KB/rule vs 8.5 KB JSON).
- `validateRulesStream` then `safeParse`s **all 10k at once**. Peak is both object graphs: **~156 MB** measured. `createConcatStream([])` only wraps the one reduce result.
- `sortImports` doing `[...acc.rules, item]` 10k times is pointer arrays. Noise.
- Line strings do not all sit around — the reduce accumulates parsed objects as the stream flows.
- The ~80 MB upload Buffer often stays mapped as **external**, not `heapUsed`. That is most of the RSS − heapUsed gap, with V8 `heapTotal` slack on top.

The 120 MB `rules` array lives for the rest of the handler (dedup, action migration, then 200-rule `importRules` batches). Later writes add more. Default `maxRuleImportPayloadBytes` is 10 MB, so this file never reaches this line until [#290918](https://github.com/elastic/kibana/issues/290918).

---

## Expected heap (before vs after)

After classify, before the 200-loop. 10k / 81 MB fixture, zstd -3.

| | Before (today) | After (classify + zstd) | Notes |
|---|---:|---:|---|
| Parsed rules | **~114 MB** | **0** | Today `sortImports` keeps every `JSON.parse`. After: write raw line, drop the object. |
| Zod clone | **~40 MB extra** (peak **~156 MB** with parse) | **0 retained** | Today `validateRulesStream` `safeParse`s all 10k at once. After: Zod one line or one 200-batch, then drop. |
| Retained heap (`rules` after await) | **~120 MB** | **~15–20 MB** | After is almost all the zstd blob (~14 MB) + a ~1 MB `rule_id` map if you keep last-wins. |
| Peak heap during the slurp | **~160–200 MB** | **~15–20 MB + ~25 KB** | After peak is growing zstd + one line (~8.5 KB) + one parse (~12 KB). Maybe one more Zod clone if you validate per line. |
| Exceptions + connectors | in the same reduce acc | same arrays, tiny | Unchanged. Do not compress. |
| `errors[]` | mixed `Error`s inside `rules[]` | `BulkError[]` only | Failures don’t keep a rule object alive. |
| Upload Buffer (RSS / external) | **~80 MB** | **~80 MB** | Hapi still holds the POST. This approach does not free it. |
| RSS (isolated process, ~43 MB baseline) | **~450 MB** retained / **~490 MB** peak | **~140 MB** ballpark | Baseline + ~80 MB upload + ~15 MB zstd + V8 slack. Not 450. |

At the **current 10 MB cap**, after is ~1.5–2 MB zstd. The table is the #290918-sized file.

Once you inflate 200s, add **~2–3 MB** for that batch (200 × ~12 KB), then drop it. The zstd blob stays until the handler ends.
