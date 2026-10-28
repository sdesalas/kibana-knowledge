# `install_large_bundled_package` regression — top 3 ES candidate commits

**Companion to:** [`install-large-bundled-package-regression.md`](./install-large-bundled-package-regression.md)

**ES commit range under investigation:**
[`32342fb5...3cd6e1f7`](https://github.com/elastic/elasticsearch/compare/32342fb5bfd04a6b04ba17f609cb82228c318bca...3cd6e1f7737a51fe53134a0abf61fc29797d48e7)
(11 May → 12 May 2026 daily ES snapshots, 92 commits total, ~19 after filtering test-mutes / docs / ESQL / parquet / native / stateless noise.)

**Methodology:** read each non-noise commit in the range, scored against the report's two prime hypotheses:

- **C6** — 3 000 single-doc `POST /.kibana_alerting_cases/_create/...?refresh=wait_for` at concurrency 20. A 30–50 ms per-write regression here is enough to turn the ~15 s budget into > 300 s.
- **C4 / D1** — `terms` + `top_hits` aggregation on the 30 000-doc `.kibana_security_solution` index, run twice per iteration.

The three commits below are the only ones in the range that touch a code path on which a per-doc regression of that magnitude is mechanically plausible.

---

## Candidate #1 — `a1610b82766` "Use eirf for mappings on the sequential path" (#148095)

- **Author:** Tim Brooks
- **Date:** Mon May 11 15:37:15 2026 -0600
- **Diff size:** ~245 lines net across 13 files; the load-bearing files are `DocumentParser.java`, `SourceToParse.java`, `ParsedDocument.java`, `ShardBatchIndexer.java`.
- **PR:** <https://github.com/elastic/elasticsearch/pull/148095>

### Why this is suspect #1

This is the **only** commit in the range that explicitly reworks the **sequential per-document parsing path** — i.e. the code path that every one of the 3 000 `_create` requests in C6 walks through.

Before the commit, `DocumentParser.parseDocument` did:

```java
XContentHelper.createParser(
    parserConfiguration.withIncludeSourceOnError(source.getIncludeSourceOnError()),
    source.source(),
    source.getXContentType()
)
```

After the commit, `SourceToParse` exposes a new `SourceToParse.Source` indirection that owns the bytes, the XContent type, and the lazy EIRF↔bytes conversion. `DocumentParser.parseDocument` now does:

```java
SourceToParse.Source sourceObject = source.source();
if (sourceObject.isEmpty()) { ... }
...
sourceObject.parser(parserConfiguration)
```

and `ParsedDocument` no longer holds `BytesReference source` / `XContentType xContentType` directly — those move to the inner `Source` class.

The new `Source` class contains a notable hot-path detail:

```java
// Synchronized for now to be safe. Probably unnecessary.
public synchronized BytesReference originalBytes() {
    if (originalSourceBytes == null) {
        try (XContentBuilder builder = XContentBuilder.builder(xContentType.xContent())) {
            EirfRowToXContent.writeRowFromSchema(row, schemaTree, builder);
            originalSourceBytes = BytesReference.bytes(builder);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
    return originalSourceBytes;
}
```

For the **non-EIRF sequential `_create`** path, `originalSourceBytes` is non-null from the constructor, so the synchronized block is never entered — the slowdown can't come from monitor contention. But the broader refactor still:

- Allocates a `Source` wrapper per `SourceToParse`,
- Routes `Engine.Index.source()` reads through `sourceObject.originalBytes()` (an extra indirection on every store/translog read of the document source),
- Reshapes `ParsedDocument`'s source/xContentType from mutable fields to a wrapper that nobody asked to change shape on a hot path.

### What to test

Run the test against the parent of this commit (`825f49c0926` "Fixing StatelessHollowIndexShardsIT.testRecoverHollowShardReadsSingleRegionAndEvictsCache by allowing retries") versus the commit itself. If the parent passes in ~30 s and `a1610b82766` blows past the 360 s timeout, this is your bisect.

### Why this is the top candidate

- It is the **only commit in range that touches the sequential single-doc indexing path explicitly**.
- The report's strongest signal (C6 contributes 12–18 s of the 30 s baseline at concurrency 20) means even modest per-write overhead amplifies × 150 sequential waves.
- The author's own commit message admits the change is part of an in-progress series ("This will be addressed in follow-ups"), and the commit ships with `TODO`s and a `synchronized` block flagged as "probably unnecessary" — neither inspires perf confidence.

---

## Candidate #2 — `488c8e730e8` "Introduce `array_objects.limit` to guard against array-of-objects OOM" (#148596)

- **Author:** Dimitris Rempapis
- **Date:** Mon May 11 11:41:41 2026 +0300
- **Diff size:** +799 / −5 across 12 files; load-bearing in `DocumentParser.java` and `DocumentParserContext.java`.
- **PR:** <https://github.com/elastic/elasticsearch/pull/148596>

### Why this is suspect #2

Adds a new per-document counter that fires on **every `START_OBJECT` token encountered inside an array**, throwing if the cumulative count exceeds `INDEX_MAPPING_ARRAY_OBJECTS_LIMIT_SETTING`:

```java
public final void incrementAndCheckObjectArrayElementLimit() {
    long limit = indexSettings().getMappingArrayObjectsLimit();
    if (objectArrayElementCounter.incrementAndGet() > limit) {
        throw new DocumentParsingException(...);
    }
}
```

The call site is unconditional in `parseArrayElements`:

```java
if (token == XContentParser.Token.START_OBJECT) {
    context.incrementAndCheckObjectArrayElementLimit();
    parseObject(context, lastFieldName);
}
```

Detection-rule SO bodies have several array-of-objects fields (`actions`, `references`, `severity_mapping`, `risk_score_mapping`, `threat`, etc.), so each of the 3 000 docs trips this check many times.

### Yellow flags supporting this candidate

- Three of the integration tests added by this commit are **muted in the very same snapshot range** by sibling PRs:
  - `2441c907211 Mute ArrayObjectsLimitIT testNestedArrayExceeded`
  - `b21f48ac18a Mute ArrayObjectsLimitIT testBulkPartialFailureOnArrayObjectsLimit`
  - `7ded0a49385 Mute ArrayObjectsLimitIT testDynamicSettingUpdateAffectsSubsequentDocuments`

  Three near-simultaneous mutes on the same feature's IT suite is a strong signal that the feature isn't behaving as designed in some test scenarios.
- Each check reads `indexSettings().getMappingArrayObjectsLimit()` (a volatile read) and bumps a non-volatile `long` field via a method call — cheap per-call, but executed many times per doc × 3 000 docs.

### Why it's #2, not #1

The arithmetic doesn't quite reach a 12× cliff on its own: even if every check costs ~1 µs, 3 000 docs × ~20 nested-object tokens × 1 µs ≈ 60 ms of extra CPU per iteration — nowhere near 330 s. The slowdown would need to be amplified by a knock-on effect (e.g. forcing each `_create` to wait for a fresh refresh window because the parse phase now overruns the previous wave), which is plausible but speculative.

### What to test

After ruling out candidate #1, test the parent of `488c8e730e8` (which is `5fa992cc3fd` "Revert 'Revert Introduce columnar index modes'") versus the commit itself.

---

## Candidate #3 — `6a6d6abac97` "Allow audit logging to be turned on/off without server restart" (#147333)

- **Author:** Ankit Sethi
- **Date:** Mon May 11 11:49:46 2026 -0500
- **Diff size:** ~395 lines across 13 files; load-bearing in `Security.java` and `AuditTrailService.java`.
- **PR:** <https://github.com/elastic/elasticsearch/pull/147333>

### Why this is suspect #3

The report explicitly calls out "security/audit" as one of the things that could lengthen the per-write critical path. This commit changes how the audit trail is wired:

**Before** (good snapshot):

```java
final AuditTrail auditTrail = XPackSettings.AUDIT_ENABLED.get(settings)
    ? new LoggingAuditTrail(settings, clusterService, threadPool)
    : null;
final AuditTrailService auditTrailService = new AuditTrailService(auditTrail, getLicenseState());
```

`AuditTrailService.get()` returned `NOOP_AUDIT_TRAIL` via a null check when audit was disabled.

**After** (bad snapshot):

```java
final AuditTrail auditTrail = new LoggingAuditTrail(settings, clusterService, threadPool);
final AuditTrailService auditTrailService = new AuditTrailService(auditTrail, getLicenseState(), clusterService);
```

`LoggingAuditTrail` is **always** constructed, even when `xpack.security.audit.enabled=false` (the Kibana FTR default). `LoggingAuditTrail`'s constructor registers a `ClusterStateListener`, installs Log4j marker filters, and registers multiple dynamic-settings consumers.

`AuditTrailService.get()` then dispatches via a `volatile boolean isAuditEnabled` flag:

```java
public AuditTrail get() {
    if (isAuditEnabled == false) {
        return NOOP_AUDIT_TRAIL;
    }
    ...
}
```

### Why it's #3, not higher

On paper the per-request hot path still dispatches to NOOP via a single volatile read, so it should be ~zero-cost — even with security enabled, the FTR cluster runs with audit disabled by default. The slowdown would have to come from one of the **side effects** of unconditionally constructing `LoggingAuditTrail`:

- A `ClusterStateListener` that now fires on every CS update (Fleet/EPM publishes lots of CS updates during the bundled-package install in Phase C),
- Log4j marker filters now sitting on the logger pipeline (could matter if indexing/bulk logging is on a hot path),
- The dynamic-settings update consumers registered against `clusterService.getClusterSettings()`.

This is the weakest of the three but is the only commit in range that touches the security/audit surface area the report singled out, so it deserves a confirmatory test if #1 and #2 come back clean.

### What to test

Test the parent of this commit (`b11ccfd6838` "Routing field mapper enable doc values by default if index mode is columnar") versus the commit itself, **with Kibana's default FTR security settings** (security enabled, audit unset).

---

## Recommended bisect order

The 12 May snapshot reproduces in ≥ 6 minutes per run, so each cut is expensive. Optimal order:

1. **`a1610b82766`** — single highest-leverage cut; the only commit that demonstrably touches the sequential `_create` parsing path.
2. **`488c8e730e8`** — if #1 is clean, this is the only other commit adding per-doc parse-time work.
3. **`6a6d6abac97`** — if both above are clean, rule out audit-trail side effects.

If all three are clean, fall back to a linear walk of the remaining ~16 non-noise commits between `32342fb5...3cd6e1f7`, prioritizing anything that touches the write path, mapping path, cluster state, or security/authz.

---

## Commits explicitly ruled out (and why)

| Commit | Subject | Why ruled out |
|---|---|---|
| `5fa992cc3fd` | Revert "Revert Introduce columnar index modes" | Gated behind `COLUMNAR_FEATURE_FLAG`; `.kibana_alerting_cases` runs in standard mode |
| `b11ccfd6838` | Routing field mapper doc_values default in columnar | Only changes behavior when `index.mode=columnar`; standard mode untouched |
| `d59a7537a66` | Pass `CircuitBreakingException` through `SearchExecutionContext#toQuery` | 3-line glue change in exception handling |
| `94189072715` | Revert "Remove obsolete ClusterStateSecretsMetadata" | Adds cluster-state bytes, not per-request CPU |
| `d18d1afce16` | add `significant_events-*` privileges | Adds one index pattern + five privilege names to `kibana_system` role; resolver is not linear in unrelated patterns |
| `4351de7ac1f` | Closing async instrument removes it from registry | Removes APM work, doesn't add it |
| `a06bc95e6b0` | Fix UOE in CanMatch empty-shards skipped-by-cluster map | Fixes an error-case branch in canmatch |
| `c1294cc640d` | Return an empty response for scrolls with no shard contexts | Empty-result short-circuit, scrolls unused in this test |
| `423a8b37a32` | SingleNodeShutdownMetadata builder propagation | Shutdown-only path |
| `ab0da8ea42b` | Slice: add `_slice` support to count | Search count, unused in this test |
| `b8f4dcb7ed2` | Add DLM Disruption Integ Tests | Tests-only |
| `ac754a5c0c3` | Fix DLS docs `.enum` sub-field to `.keyword` | DLS docs only |
| `0284b7798f1` | Downgrade AVX512 to AVX2 (older GCE N1) | Native-code path, local laptop unaffected |
| `e8314db9ad3` | `Provider` interface for `ProjectRoutingResolver` | CPS-internal refactor |
| `81378da99cc` | Remove iterations from native scorer tests | Tests-only |
| `3d32d1275f6` | Rename `AbstractBulkByScrollRequest` | Rename, no behavior change |
| `5ad8f96c18f` | ESQL: handle type-conflicted PUNKs during resolution | ESQL-only |

---

## Sources for the analysis

- `git log --oneline 32342fb5bfd04a6b04ba17f609cb82228c318bca..3cd6e1f7737a51fe53134a0abf61fc29797d48e7` against an `elastic/elasticsearch` checkout on `main`.
- Per-commit `git show --stat` and per-file diff inspection for every Tier-1 / Tier-2 candidate.
- Parent commits checked against the good snapshot SHA (`32342fb5bfd04a6b04ba17f609cb82228c318bca`).
