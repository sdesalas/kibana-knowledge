# `install_large_bundled_package` regression — root cause confirmed

**Status:** Root cause **identified** via HAR analysis of side-by-side Kibana → Elasticsearch traffic from the good (11 May) and bad (12 May) ES snapshots.

**Companion reports:**
- [`install-large-bundled-package-regression.md`](./install-large-bundled-package-regression.md) — original reproduction report
- [`install-large-bundled-package-regression-candidates.md`](./install-large-bundled-package-regression-candidates.md) — pre-HAR top-3 candidate analysis (this report supersedes the ranking)

**HAR data referenced below:**
- [`may11.scrubbed.har.zip`](./may11.scrubbed.har.zip) — 274 MB unzipped, 24 048 entries
- [`may12.scrubbed.har.zip`](./may12.scrubbed.har.zip) — 72 MB unzipped, 1 520 entries
- All analysis scripts live in `har/` next to the HARs (`analyze_har.py`, `timeline.py`, `find_stall.py`, `early_activity.py`, `show_request.py`).

---

## TL;DR

The 12 May snapshot is **not slower** than the 11 May one — it is **hard-failing** a single Kibana → Elasticsearch request, then Kibana enters an exponential-backoff retry loop until Mocha's 360 s timer expires. The reason the test looks "slow" is that mitmproxy/HAR captures it as a long wait, but actually all the traffic is normal-latency.

**Culprit commit:** [`488c8e730e8`](https://github.com/elastic/elasticsearch/commit/488c8e730e8b23f53e5e9ee205a0696a3ac73c59) "Introduce `array_objects.limit` to guard against array-of-objects OOM (#148596)" by Dimitris Rempapis.

**Mechanism:** Adds a new `index.mapping.array_objects.limit` index setting (default **20 000**) that limits the cumulative count of `START_OBJECT` tokens inside arrays across a single document. The Kibana `epm-packages:security_detection_engine` saved object includes an `installed_kibana[]` array with **30 000 entries** (3 000 unique prebuilt rules × 10 historical versions). Indexing that SO now throws `document_parsing_exception` with status `400`.

**Smoking-gun ES response (from `may12.scrubbed.har`):**

```json
{
  "error": {
    "root_cause": [{
      "type": "document_parsing_exception",
      "reason": "[1:1150968] The total number of objects across all arrays in the document has exceeded the allowed limit of [20000]. This limit can be set by changing the [index.mapping.array_objects.limit] index level setting."
    }],
    "type": "document_parsing_exception",
    "reason": "[1:1150968] The total number of objects across all arrays in the document has exceeded the allowed limit of [20000]. This limit can be set by changing the [index.mapping.array_objects.limit] index level setting."
  },
  "status": 400
}
```

---

## Why the previous "per-doc slowdown" theory was wrong

The original report's hypothesis (per-write critical path slowing from 30 → 360+ ms × 3 000) was logical given a 12× test-time blow-up — but the HAR data falsifies it directly:

| Metric | may11 (good) | may12 (bad) |
|---|---|---|
| Total ES requests during run | **24 048** | **1 520** |
| Sum of per-request server time (`time` field in HAR) | **527.8 s** | **12.1 s** |
| Window from first to last request | 30 s | **427 s** |
| `PUT /.kibana_alerting_cases_9.5.0/_create/{id}` calls (= test Phase C6) | **3 000** @ ~89 ms mean | **0** |
| `POST /.kibana_security_solution_9.5.0/_search` calls (= Phase C4/D1 agg) | 3 112 | 0 |
| `POST /_bulk?refresh=false&require_alias=true` (= Phase C3 SO bulk install) | 307 @ 14.8 ms | 303 @ 14.3 ms |

The bad run **never reaches** the rule-installation phase. Individual request latencies are identical-or-faster than the good run. The wall-clock time is consumed entirely by waiting between Kibana's retries of the failing `PUT`.

Per-request latency table on may12, reproducible with:

```bash
cd har/
python3 analyze_har.py may11.scrubbed.har may12.scrubbed.har
```

In particular, the "regressed-most" comparison rows are dominated by background telemetry/task-manager traffic and not any test-relevant API. There is **no** ES endpoint with a meaningfully worse mean latency on may12.

---

## The actual failure flow (reconstructed from `may12.scrubbed.har`)

| Offset | Event |
|---|---|
| +0 s — +57 s | FTR runner bootstraps; Kibana background telemetry/task-manager polling only. |
| **+57.32 s** | Test body starts: `PUT /.kibana_security_solution_9.5.0/_create/exception-list-agnostic:endpoint_list?refresh=wait_for` → `409` (idempotent C1, expected). |
| +57.33 s | `GET /.kibana_ingest_9.5.0/_doc/epm-packages:security_detection_engine` → `404` — Fleet bundled-package install starts. |
| +59.14 s | `PUT /.kibana_ingest_9.5.0/_doc/epm-packages:security_detection_engine?refresh=wait_for` → `201 created`, `_seq_no=4`. Initial pending-install marker SO written. |
| +59.21 s — +68.4 s | Burst of **~280 × `POST /_bulk?refresh=false&require_alias=true`** at ~13 ms each. This is Phase C3: SO `bulk_create` chunks writing the 30 000 `security-rule` assets + index templates etc. Completes normally. |
| **+69.28 s** | `PUT /.kibana_ingest_9.5.0/_doc/epm-packages:security_detection_engine?refresh=false&if_seq_no=4&if_primary_term=1` with a **1 732 523-byte body** containing the full asset inventory (`installed_kibana[]` with 30 000 entries). **→ `400 document_parsing_exception`** (see the smoking-gun JSON above). |
| +70.32 s, +72.36 s, +76.40 s, +84.49 s, +100.54 s, +132.57 s, +196.62 s, +324.65 s | **8 more retries** of the same PUT — Kibana's Fleet/EPM install logic uses exponential backoff (≈ 1 s, 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s). Each retry hits the same hard 400. |
| +427 s | mitmproxy capture ends; Mocha test had already timed out at +360 s from test start (= +60 s + 360 s = ~+420 s wall-clock in the HAR's clock). |

Reproduce the timeline with:

```bash
cd har/
python3 early_activity.py may12.scrubbed.har --from-s 55 --to-s 85
```

Reproduce the retry count with:

```bash
cd har/
python3 - << 'PY'
import json
from pathlib import Path
from datetime import datetime
entries = sorted(
    json.loads(Path("may12.scrubbed.har").read_text())["log"]["entries"],
    key=lambda e: datetime.fromisoformat(e["startedDateTime"]),
)
first = datetime.fromisoformat(entries[0]["startedDateTime"])
for e in entries:
    if (
        "epm-packages%3Asecurity_detection_engine" in e["request"]["url"]
        and e["request"]["method"] == "PUT"
        and e["response"]["status"] == 400
    ):
        rel = (datetime.fromisoformat(e["startedDateTime"]) - first).total_seconds()
        print(f"+{rel:>7.2f}s  400  PUT  ...epm-packages:security_detection_engine")
PY
```

Reproduce the smoking-gun request body / response with:

```bash
cd har/
python3 show_request.py may12.scrubbed.har \
    --url-contains 'epm-packages%3Asecurity_detection_engine' \
    --status 400 --method PUT --limit 1
```

And confirm the same PUT on may11 succeeds with `200`:

```bash
cd har/
python3 show_request.py may11.scrubbed.har \
    --url-contains 'epm-packages%3Asecurity_detection_engine' \
    --method PUT --limit 2 --body-chars 300
```

---

## Updated culprit assessment

### #1 — Confirmed: `488c8e730e8` "Introduce `array_objects.limit`" (#148596)

- **Author:** Dimitris Rempapis
- **Date:** Mon May 11 11:41:41 2026 +0300
- **PR:** <https://github.com/elastic/elasticsearch/pull/148596>
- **Confidence:** Definitive — the exact error message in the 400 response on may12 names the new setting (`index.mapping.array_objects.limit`) introduced by this PR; the matching PUT on may11 returns `200`.

The PR adds an `IndexSettings` field `mappingArrayObjectsLimit` defaulting to `20 000` and a per-document counter in `DocumentParserContext`:

```java
public final void incrementAndCheckObjectArrayElementLimit() {
    long limit = indexSettings().getMappingArrayObjectsLimit();
    if (objectArrayElementCounter.incrementAndGet() > limit) {
        throw new DocumentParsingException(
            parser().getTokenLocation(),
            "The total number of objects across all arrays in the document has exceeded the allowed limit of ["
                + limit
                + "]. This limit can be set by changing the ["
                + MapperService.INDEX_MAPPING_ARRAY_OBJECTS_LIMIT_SETTING.getKey()
                + "] index level setting."
        );
    }
}
```

This is invoked unconditionally inside `DocumentParser.parseArrayElements` on every `START_OBJECT` token nested in any array. The Kibana `epm-packages:security_detection_engine` SO's `installed_kibana[]` array contains 30 000 `{"id": "...", "type": "security-rule"}` objects on this test, exceeding the 20 000 default.

**Default-on, applies to all indices.** No new index-template or system-index override changes the limit, so `.kibana_ingest_9.5.0` inherits the 20 000 default.

#### Yellow flag from the prior report
Three of the feature's own integration tests were muted in the same commit range:

- `2441c907211 Mute org.elasticsearch.index.mapper.ArrayObjectsLimitIT testNestedArrayExceeded #148747`
- `b21f48ac18a Mute org.elasticsearch.index.mapper.ArrayObjectsLimitIT testBulkPartialFailureOnArrayObjectsLimit #148746`
- `7ded0a49385 Mute org.elasticsearch.index.mapper.ArrayObjectsLimitIT testDynamicSettingUpdateAffectsSubsequentDocuments #148745`

These are the strongest pre-HAR signal that the feature was not behaving as designed in CI either.

### #2 — Ruled out by HAR: `a1610b82766` "Use eirf for mappings on the sequential path" (#148095)

The previous top candidate. With HAR evidence in hand, this is **not** the culprit: the bad run never executes the sequential per-doc indexing path that this commit reworks (no `PUT /.kibana_alerting_cases_9.5.0/_create/{id}` calls happen). Kibana stalls on the upstream `epm-packages` PUT before it ever gets to Phase C6.

### #3 — Ruled out by HAR: `6a6d6abac97` "Allow audit logging to be turned on/off without server restart" (#147333)

No evidence of any audit-related slowdown in the HARs. Per-request latencies for security-checked endpoints (e.g. `POST /_security/user/_has_privileges` — 6 754 requests in the good run, 33 in the bad run) are statistically indistinguishable between runs.

### Other commits in the bisect range

All other commits previously listed in `install-large-bundled-package-regression-candidates.md` Tier-2 / ruled-out are also confirmed irrelevant by the HAR: the failure is reproduced before any of those code paths is exercised.

---

## Suggested fixes (in order of preference)

1. **Best fix — Elasticsearch side:** Raise or remove the default `index.mapping.array_objects.limit` for system indices. The `.kibana*` index templates already grant Kibana broad mapping authority; setting `index.mapping.array_objects.limit` to `Long.MAX_VALUE` (or at least `1 000 000`) for system indices preserves the OOM guard for user data while not breaking documented Kibana SO patterns. The limit currently has no index-template exemption logic.

2. **Alternative fix — Elasticsearch side:** Raise the default. `20 000` is well below what existing Kibana / Fleet workloads ship today. The Fleet `installed_kibana[]` field is documented to scale with installed-asset count, which a 30 000-rule bundled package will routinely exceed. A 200 000 default would still catch genuinely runaway docs (e.g. 10 M-object SO) while letting Fleet operate. Add a deprecation note for the previous unbounded behavior.

3. **Kibana-side mitigation:** Have Fleet/EPM split the `epm-packages` SO so that `installed_kibana[]` is sharded into multiple SOs once it exceeds some threshold (e.g. 10 000 assets). This is the heaviest fix and reshapes a long-standing SO contract, so it's the least desirable.

4. **Test-side workaround (short-term, not a real fix):** The bundled-large-package config can set `index.mapping.array_objects.limit` on `.kibana_ingest_*` via the FTR cluster `esTestConfig`. Buys time but doesn't fix the underlying compatibility break.

---

## What an investigator looking at this report from scratch should do

1. **Unzip and load the HARs:**

   ```bash
   unzip may11.scrubbed.har.zip
   unzip may12.scrubbed.har.zip
   ```

2. **Confirm the per-endpoint diff doesn't show a slowdown** — run `analyze_har.py` and observe that no endpoint regresses in mean latency on may12.

3. **Confirm the bad run stops short** — run `early_activity.py may12.scrubbed.har --from-s 55 --to-s 85` and find the burst of `POST /_bulk` ending at +68 s.

4. **Confirm the failing PUT and its ES error message** — run the `show_request.py` invocation above; the 400 response literally names the new setting introduced by #148596.

5. **Confirm the retry pattern** — run the inline Python snippet above to list the 9 PUT 400s spanning +69 s to +325 s with doubling backoff.

6. **Cross-reference the ES setting** — `git grep INDEX_MAPPING_ARRAY_OBJECTS_LIMIT_SETTING` in `elastic/elasticsearch@main` resolves to `server/src/main/java/org/elasticsearch/index/mapper/MapperService.java`, default `20000L`. The setting was introduced by PR #148596 (#488c8e730e8).

7. **Cross-reference Fleet's SO content** — the failing PUT body is the standard Fleet `epm-packages:security_detection_engine` SO and its `installed_kibana[]` length matches the test's `NUM_OF_RULE_IN_MOCK_LARGE_PKG = 3000` × `PREBUILT_RULE_VERSIONS_COUNT = 10` = 30 000.

If all six steps line up, you have the same root cause this report does.

---

## Anatomy of the smoking-gun request

- **URL:** `PUT /.kibana_ingest_9.5.0/_doc/epm-packages%3Asecurity_detection_engine?refresh=false&if_seq_no=4&if_primary_term=1&require_alias=true`
- **Method:** `PUT` (Kibana SO update with optimistic concurrency control)
- **Request size:** 1 732 523 bytes (~1.7 MB)
- **Body shape (truncated):**
  ```json
  {
    "epm-packages": {
      "installed_kibana": [
        {"id": "test-prebuilt-rule-1_1",  "type": "security-rule"},
        {"id": "test-prebuilt-rule-1_2",  "type": "security-rule"},
        ...
        {"id": "test-prebuilt-rule-3000_10", "type": "security-rule"}
      ],
      "installed_kibana_space_id": "default",
      "installed_es": [...],
      "package_assets": [...],
      ...
    }
  }
  ```
- **Response (may11, good):** `200 OK` (`_version=6, result=updated, _seq_no=13`).
- **Response (may12, bad):** `400 document_parsing_exception` naming `index.mapping.array_objects.limit`.

Both runs send byte-for-byte identical request bodies (same Kibana checkout, same fixture).

---

## Anatomy of the regression in one line

> The Elasticsearch 12 May 2026 daily snapshot enforces a new 20 000 default on `index.mapping.array_objects.limit` (PR #148596). The Kibana Fleet `epm-packages:security_detection_engine` SO carries an `installed_kibana[]` array sized at `NUM_OF_RULE_IN_MOCK_LARGE_PKG (3000) × PREBUILT_RULE_VERSIONS_COUNT (10) = 30 000`, exceeding the limit. The PUT is rejected with `400 document_parsing_exception`; Kibana retries with exponential backoff; Mocha kills the test at 360 s.

---

## Appendix — scripts

All four analysis scripts in `har/` next to the HARs are self-contained and only depend on Python 3.8+ stdlib:

- `analyze_har.py <good.har> <bad.har>` — per-endpoint timing comparison.
- `timeline.py <har>` — biggest gaps between consecutive requests + per-second request density.
- `find_stall.py <har>` — last "real" (non-heartbeat) request and the trailing N non-heartbeat requests.
- `early_activity.py <har> --from-s N --to-s M` — full request list within a time window.
- `show_request.py <har> --url-contains <substr> [--status N] [--method M] --limit K` — dump full request body + response body of matching entries.
