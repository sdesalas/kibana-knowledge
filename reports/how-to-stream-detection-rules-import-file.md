# How to stream a detection rules import file

**Date:** 2026-09-15
**Status:** Design only. Not implemented.
**Related:** [#275695](https://github.com/elastic/kibana/pull/275695) (import create path), [#290918](https://github.com/elastic/kibana/issues/290918) (10 MB payload cap)
**Fixture:** `.knowledge/data/rules-import/12000disabled-rules.internal.ndjson`

---

## Summary

[`import_rules/route.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts) handles `POST /api/detection_engine/rules/_import`. It has to import **connectors and exceptions before rules**, but the NDJSON file is written the other way around: rules, then exceptions, then connectors, then a details footer ([`export_rules/route.ts` L115](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/export_rules/route.ts#L115)).

```ts
`${rulesNdjson}${exceptionLists}${actionConnectors}${exportDetails}`
```

That’s why the route today slurps the whole upload (`createPromiseFromRuleImportStream` → `sortImports` → `createConcatStream([])`) before it does any writes.

A file that mixes rules, exceptions, and connectors — with connectors and exceptions required first — is a **poor streaming format**: you cannot emit a usable first batch until you’ve seen the tail. Scanning backwards would also get you the tail first, but it’s a bad idea. A `HapiReadableStream` (and a single zstd/deflate blob) only goes forward, so “backwards” means buffering the whole thing anyway.

The useful move is a **forward classify**. Read the Hapi upload once. Park connectors and exceptions in small arrays. Spill rule lines into one **in-memory zstd stream**.

When the upload ends, import deps, then stream-inflate rules in batches of 200. That matches the [DRC comment](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rules/import_rules.ts#L70-L71) that outer batching should live in `route.ts` if we ever stop holding every rule in RAM.

zstd level 3 (Node 24 `zlib`, no extra dep) took the 12k-rule fixture from **102 MB → 16.9 MB in 185 ms**. The real win is not keeping 12k parsed rule objects. This does not raise Hapi’s 10 MB `maxRuleImportPayloadBytes` — compression happens after the body is already accepted.

Not for #275695. Do it when we raise the cap or when heap on large imports is the next bottleneck. No temp files.

---

## Possible approach

Classify each line the way `sortImports` already does: `attributes` → connector, `list_id` / `item_id` / `entries` → exception, `exportedCount` → drop, else rule. Write the **raw line bytes**. Throw away the parsed object — if you keep parsed rules, compression is pointless.

You only need **one** zstd stream, for rules. Exceptions and connectors are tiny. Leave them as arrays.

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
