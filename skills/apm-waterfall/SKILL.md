---
name: apm-waterfall
description: >-
  Export an Elastic APM transaction (trace) to a self-contained, collapsible HTML
  waterfall that mimics Kibana's Trace Sample timeline, plus a JSON span dump.
  Use when the user invokes /apm-waterfall, or wants APM traces saved for future
  reference, attached to a ticket/PR, or published next to benchmark results.
disable-model-invocation: true
---

# APM Waterfall Export

Turn one or more APM transactions into **static HTML pages** people can open in
any browser without access to the monitoring cluster. Each page shows the full
span tree on a shared timeline (teal bars, nested rows, collapse chevrons,
service chip, duration, `blocking` tag), close to Kibana's
*APM → Transactions → Trace sample → Timeline* view.

This skill **records** traces; it does not analyse them. For hotspot ranking use
`apm-investigation`.

## When to use

- Archive the APM side of a benchmark run next to its `SUMMARY.md`.
- Attach a trace to a GitHub issue / PR / Slack thread for readers without
  monitoring-cluster access (or after the cluster's retention expires).
- Keep a before/after pair of the same endpoint for later comparison.

Not for: ranking optimisation candidates, comparing environments numerically,
or live debugging. Use the Kibana APM UI or `apm-investigation` for those.

## Setup

### 1. Recreate the scripts (only if missing)

```
<skill dir>/scripts/export_waterfall.py      ← Appendix A
<skill dir>/scripts/waterfall_template.html  ← Appendix B
<skill dir>/scripts/export_index.py          ← Appendix C
```

Python 3.9+, standard library only. No npm, no CDN: the HTML inlines its CSS,
JS and data.

### 2. Credentials: `~/config/apm.creds` (chmod 600, never commit)

Read access to the **monitoring Elasticsearch** that stores the APM data
(the `*.es.*` endpoint, not the APM intake server, not Kibana):

```bash
mkdir -p ~/config
cat > ~/config/apm.creds <<'CREDS'
# Monitoring Elasticsearch for APM traces (edit me)
APM_ES_URL=https://YOUR-MONITORING-ES.example.com
APM_ES_USER=agent
APM_ES_PASSWORD=change-me
APM_INDEX=traces-apm*
CREDS
chmod 600 ~/config/apm.creds
```

If you had to create it, **stop** and ask the user to fill in real values. Never
invent credentials. `APM_*` environment variables override the file. Health check:

```bash
set -a && source ~/config/apm.creds && set +a
curl -sS -u "$APM_ES_USER:$APM_ES_PASSWORD" "${APM_ES_URL%/}/_cluster/health"
```

## Usage

### Single trace

```bash
python3 scripts/export_waterfall.py \
  --trace-id b1ad448315e182bfcf3b5e29cdc2d834 \
  --transaction-id 951efe78ca55c463 \
  --out-dir <bench dir>/apm \
  --slug 01-import-1000-disabled \
  --title "#1 Import → Create 1,000 disabled rules" \
  --kibana-url "<monitoring Kibana trace URL>"
```

- `--transaction-id` is optional. Without it the longest transaction in the
  trace is used, which is normally the HTTP request you want.
- `--kibana-url` adds an "Open in Kibana APM ↗" link to the header.
- It prints `<indexed>/<started> spans` so you see straight away whether the
  trace is complete.
- `--from-json <dir>/<slug>.spans.json` rebuilds the HTML from the saved JSON
  with no ES access. Use it after changing the template.

### Finding trace IDs

Kibana trace URLs carry `traceId=` and `transactionId=` query params. Otherwise
search ES for the slowest matching transaction in a time window:

```bash
set -a && source ~/config/apm.creds && set +a
curl -sS -u "$APM_ES_USER:$APM_ES_PASSWORD" -H 'Content-Type: application/json' \
  "${APM_ES_URL%/}/${APM_INDEX:-traces-apm*}/_search" -d '{
  "size": 5,
  "sort": [{"transaction.duration.us": "desc"}],
  "_source": ["@timestamp","trace.id","transaction.id","transaction.name","transaction.duration.us"],
  "query": {"bool": {"filter": [
    {"term": {"processor.event": "transaction"}},
    {"term": {"service.environment": "<env>"}},
    {"term": {"transaction.name": "POST /api/detection_engine/rules/_import"}},
    {"range": {"@timestamp": {"gte": "<from ISO>", "lte": "<to ISO>"}}}
  ]}}}'
```

Cloud deployments may tag runs with `labels.deploymentName` instead of (or as
well as) `service.environment`.

### Batch (e.g. every scenario in a bench SUMMARY)

There's no batch script on purpose, because every source table looks different.
Write a throwaway loop in the scratchpad instead:

1. Parse rows into `(n, scenario, trace_id, transaction_id, kibana_url)`.
   With a Markdown table, a regex over each `| n | scenario | … | [\`trace\`](url) |`
   row works, and `transactionId=` is in the URL.
2. Pick a short, stable kebab slug per row and prefix the zero-padded number
   (`01-import-1000-disabled`, `14-delete-21-exception-lists`) so files sort in
   table order.
3. Call `export_waterfall.py` once per row with `--title "#<n> <scenario>"`.
   Running them one after another is fine: a 10k-span trace takes about 10s.
4. Compare each `<indexed>/<started>` line with the source table's span count
   and report any gaps (see *Incomplete traces*).
5. Build the listing page with `export_index.py` (see *Index page*).

### Index page

After the waterfalls are exported, generate a browseable `index.html` next to
`apm/` from the saved `*.spans.json` (no ES access):

```bash
python3 scripts/export_index.py \
  --apm-dir <bench>/apm \
  --title "APM waterfalls — <stamp>" \
  --h1 "APM waterfalls — full bench PR #300213 (19 scenarios)" \
  --pill 2026-11-06T1331 \
  --pill b758fc70 \
  --link "PR #300213=https://github.com/elastic/kibana/pull/300213" \
  --link "SUMMARY=https://github.com/…/SUMMARY.md#apm-transactions"
```

- Reads every `*.spans.json` in `--apm-dir` and writes `<apm-dir>/../index.html`
  (override with `--out`).
- **Single column** when files are `NN-slug.spans.json`.
- **Multi column** when files are paired as `NN-slug.main.spans.json` /
  `NN-slug.pr.spans.json` (any side suffix works; `main`/`pr` sort first).
- Scenario names come from each JSON `title` (leading `#N` and trailing
  `(main)` / `(PR)` are stripped). Duration and span counts come from the
  transaction; an `incomplete` pill appears when indexed `< started`.
- `--pill`, `--link LABEL=URL`, and `--meta-html` fill the header meta row.

## Output

Per trace, in `--out-dir`:

| File | Purpose |
| --- | --- |
| `<slug>.html` | Self-contained page (data embedded). Open locally or host anywhere. |
| `<slug>.spans.json` | Raw span tree: `transaction` + `spans[]` (`id`, `parent`, `name`, `type`, `subtype`, `start_us` offset from txn start, `duration_us`, `outcome`, `sync`, `service`, `agent`). The source for `--from-json`. |

Per bench folder (from `export_index.py`):

| File | Purpose |
| --- | --- |
| `index.html` | Table of all waterfalls under `apm/`, with duration + span counts. |

Convention: put them in an `apm/` folder next to the report they belong to
(`<bench>/SUMMARY.md` → `<bench>/apm/NN-<slug>.html`) and link each one from
the report's table. Also drop `index.html` beside `SUMMARY.md`.

Sizes: about 270 bytes per span for each of the two files (a 1k-span trace is
about 330 KB of HTML, 11k spans is about 2.7 MB). The JSON repeats data that's
already in the HTML, so leave it out where repo size matters and you won't need
to re-render.

GitHub's blob view shows `.html` as source, not as a page. Readers need to
download it, use GitHub Pages, or open the raw file through an HTML preview service.

## Sample output

From a 13.4s `POST /api/detection_engine/rules/_import` with 1,245 spans.
Full page and screenshot: `examples/01-import-1000-disabled.html`,
`examples/01-import-1000-disabled.png`.

Console:

```
1245/1245 spans → <bench>/apm/01-import-1000-disabled.spans.json
<bench>/apm/01-import-1000-disabled.html
```

Page (top rows, default view: 245 of 1,246 rows shown):

```
#1 Import → Create 1,000 disabled rules
Fri, 06 Nov 2026 10:28:19 GMT  13 s (100% of trace)  [POST https://…/_import?…] [200 OK]  1,245 spans
[Expand all] [Collapse all] [Default view] [Filter spans by name…]  245 of 1,246 rows shown   Services ● kibana
     0 s                       5 s                       10 s                 13 s
v 2  ██████████████████████████████████████████████████████████████████████████
     ⇄ success POST /api/detection_engine/rules/_import [● kibana] [⏱ 13 s]
 v 2 ███████████
     pre-route handler middlewares [● kibana] [⏱ 2,168 ms]
     |
     ⛁ Elasticsearch: GET /_security/_authenticate [● kibana] [⏱ 3.9 ms] blocking
 v 18           ██████████████████████████████████████████████████████████████
                route handler [● kibana] [⏱ 11 s] blocking
```

`<slug>.spans.json` (trimmed to two spans):

```json
{
 "title": "#1 Import → Create 1,000 disabled rules",
 "trace_id": "b1ad448315e182bfcf3b5e29cdc2d834",
 "kibana_url": "https://<monitoring-kibana>/app/apm/…&traceId=…&transactionId=…",
 "transaction": {
  "id": "951efe78ca55c463",
  "name": "POST /api/detection_engine/rules/_import",
  "type": "request",
  "result": "success",
  "duration_us": 13424349,
  "timestamp_us": 1793960899053003,
  "timestamp": "2026-11-06T10:28:19.053Z",
  "span_count": { "started": 1245 },
  "status_code": 200,
  "method": "POST",
  "url": "https://<kibana>/api/detection_engine/rules/_import?overwrite=true",
  "service": "kibana",
  "environment": "sdesalas.pr.300213.import-apm",
  "agent": "nodejs",
  "outcome": "unknown"
 },
 "spans": [
  {
   "id": "1db670f8ad575bfc",
   "parent": "951efe78ca55c463",
   "name": "route handler",
   "type": "custom",
   "subtype": null,
   "start_us": 2168585,
   "duration_us": 11253990,
   "outcome": "success",
   "sync": true,
   "service": "kibana",
   "agent": "nodejs"
  },
  {
   "id": "6d831f3093b2293e",
   "parent": "86667cb562a75abe",
   "name": "Elasticsearch: GET /_security/_authenticate",
   "type": "db",
   "subtype": "elasticsearch",
   "start_us": 2152,
   "duration_us": 3872,
   "outcome": "success",
   "sync": true,
   "service": "kibana",
   "agent": "nodejs"
  }
 ]
}
```

## Reading the page

- **Header:** title, UTC timestamp, duration, method + URL, HTTP status pill,
  span count, environment, trace id, link back to Kibana.
- **Rows:** a bar on top and a label underneath. The bar is placed by start time
  and sized by duration against the whole transaction. The label shows the name,
  service chip, ⏱ duration (`μs` below 1 ms, one decimal below 10 ms, whole `ms`
  below 10 s, then `s`), and the sync tag. Labels flip to right-aligned once
  the bar starts past 55% of the timeline. Hover a row for its start offset,
  % of the transaction, type/subtype, outcome, child count and span id.
- **Gutter:** chevron plus direct child count, indented 10px per level.
- **Sync tag**, matching Kibana's `getSyncLabel`: `blocking` when `sync=true` and the
  agent is `nodejs`/`js-base`/`rum-js`; `async` when `sync=false` and the agent
  is any other language; nothing otherwise.
- **Default collapse:** parents with ≥10 children and ≥5 children per distinct
  child name start collapsed. That folds N+1 fan-outs, e.g. 200×
  `_has_privileges`, or 1,762 children that alternate `_has_privileges` /
  `createAPIKey`, but leaves mixed parents like `route handler` open. The
  "Expand all", "Collapse all" and "Default view" buttons override it.
- **Filter box:** shows spans whose name contains the text, along with their
  ancestors (highlighted). Collapse toggles are ignored while a filter is set.
- **Failures:** spans with `outcome=failure` get coral bars.

## Incomplete traces

Two different problems, and the page flags both in the header:

1. **Not indexed:** `transaction.span_count.started` is more than the span
   docs in ES. The agent started spans that never got stored (queue drops,
   intake errors). This has nothing to do with `span_count.dropped`, which can be
   missing or 0 at the same time. Banner: `⚠ N of M started spans not indexed`.
2. **Orphans:** spans whose `parent.id` points at one of those missing spans.
   They're grouped under a grey dashed **placeholder row** per missing parent
   (`missing parent span <id> (not indexed)`), stretched over the time range
   of its children and collapsed by default. They're never silently attached
   to the root. Banner: `⚠ N orphan spans under K missing parents`.

When you hand over the output, say which traces are incomplete and by how much.
If it matters, re-run the operation with a higher
`elastic.apm.transactionMaxSpans` / agent queue size and export again.

## Appendix A: `scripts/export_waterfall.py`

```python
#!/usr/bin/env python3
"""Export one APM transaction's span tree to JSON plus a self-contained HTML waterfall.

Usage:
  export_waterfall.py --trace-id <id> --out-dir <dir> --slug <slug> [--transaction-id <id>] [--title "..."] [--kibana-url URL]
  export_waterfall.py --from-json <dir>/<slug>.spans.json   # re-render HTML only, no ES access
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

CREDS_PATH = Path.home() / "config" / "apm.creds"
TEMPLATE = Path(__file__).resolve().parent / "waterfall_template.html"
PAGE = 2000


def load_creds() -> dict[str, str]:
    creds: dict[str, str] = {}
    if CREDS_PATH.is_file():
        for line in CREDS_PATH.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                creds[key.strip()] = value.strip()
    for key in ("APM_ES_URL", "APM_ES_USER", "APM_ES_PASSWORD", "APM_INDEX"):
        if os.environ.get(key):
            creds[key] = os.environ[key]
    for key in ("APM_ES_URL", "APM_ES_USER", "APM_ES_PASSWORD"):
        if not creds.get(key) or creds[key] in ("change-me",) or "YOUR-MONITORING-ES" in creds[key]:
            raise RuntimeError(f"{key} missing or placeholder in {CREDS_PATH}")
    creds.setdefault("APM_INDEX", "traces-apm*")
    return creds


def search(creds: dict[str, str], body: dict) -> list[dict]:
    token = base64.b64encode(f"{creds['APM_ES_USER']}:{creds['APM_ES_PASSWORD']}".encode()).decode()
    req = urllib.request.Request(
        f"{creds['APM_ES_URL'].rstrip('/')}/{creds['APM_INDEX']}/_search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.load(resp).get("hits", {}).get("hits", [])
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:2000]}") from e


def fetch_transaction(creds: dict, trace_id: str, txn_id: str | None) -> dict:
    filters: list[dict] = [
        {"term": {"trace.id": trace_id}},
        {"term": {"processor.event": "transaction"}},
    ]
    if txn_id:
        filters.append({"term": {"transaction.id": txn_id}})
    hits = search(
        creds,
        {
            "size": 1,
            "sort": [{"transaction.duration.us": "desc"}],
            "query": {"bool": {"filter": filters}},
        },
    )
    if not hits:
        raise RuntimeError(f"No transaction found for trace {trace_id}")
    src = hits[0]["_source"]
    txn = src["transaction"]
    return {
        "id": txn["id"],
        "name": txn["name"],
        "type": txn.get("type"),
        "result": txn.get("result"),
        "duration_us": txn["duration"]["us"],
        "timestamp_us": src["timestamp"]["us"],
        "timestamp": src["@timestamp"],
        "span_count": txn.get("span_count", {}),
        "status_code": src.get("http", {}).get("response", {}).get("status_code"),
        "method": src.get("http", {}).get("request", {}).get("method"),
        "url": src.get("url", {}).get("full"),
        "service": src.get("service", {}).get("name"),
        "environment": src.get("service", {}).get("environment"),
        "agent": src.get("agent", {}).get("name"),
        "outcome": src.get("event", {}).get("outcome"),
    }


def fetch_spans(creds: dict, trace_id: str, txn: dict) -> list[dict]:
    spans: list[dict] = []
    after = None
    while True:
        body: dict = {
            "size": PAGE,
            "sort": [{"timestamp.us": "asc"}, {"span.id": "asc"}],
            "query": {
                "bool": {
                    "filter": [
                        {"term": {"trace.id": trace_id}},
                        {"term": {"processor.event": "span"}},
                        {"term": {"transaction.id": txn["id"]}},
                    ]
                }
            },
            "_source": ["timestamp.us", "span", "parent.id", "event.outcome", "service.name", "agent.name"],
        }
        if after:
            body["search_after"] = after
        hits = search(creds, body)
        for h in hits:
            src = h["_source"]
            span = src.get("span", {})
            spans.append(
                {
                    "id": span["id"],
                    "parent": src.get("parent", {}).get("id"),
                    "name": span.get("name"),
                    "type": span.get("type"),
                    "subtype": span.get("subtype"),
                    "start_us": src["timestamp"]["us"] - txn["timestamp_us"],
                    "duration_us": span.get("duration", {}).get("us", 0),
                    "outcome": src.get("event", {}).get("outcome"),
                    "sync": span.get("sync"),
                    "service": src.get("service", {}).get("name"),
                    "agent": src.get("agent", {}).get("name"),
                }
            )
        if len(hits) < PAGE:
            break
        after = hits[-1]["sort"]
    return spans


def render_html(data: dict, out: Path) -> None:
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    title = (data.get("title") or data["transaction"]["name"]).replace("&", "&amp;").replace("<", "&lt;")
    html = TEMPLATE.read_text().replace("__TITLE__", title).replace("/*__DATA__*/null", payload)
    out.write_text(html)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trace-id")
    ap.add_argument("--transaction-id")
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--slug")
    ap.add_argument("--title")
    ap.add_argument("--kibana-url", help="Link back to the live APM trace view")
    ap.add_argument("--from-json", type=Path)
    args = ap.parse_args()

    if args.from_json:
        data = json.loads(args.from_json.read_text())
        html_path = args.from_json.with_name(args.from_json.name.replace(".spans.json", ".html"))
        render_html(data, html_path)
        print(html_path)
        return 0

    if not (args.trace_id and args.out_dir and args.slug):
        ap.error("--trace-id, --out-dir and --slug are required unless --from-json is given")

    creds = load_creds()
    txn = fetch_transaction(creds, args.trace_id, args.transaction_id)
    spans = fetch_spans(creds, args.trace_id, txn)
    data = {
        "title": args.title,
        "trace_id": args.trace_id,
        "kibana_url": args.kibana_url,
        "transaction": txn,
        "spans": spans,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.out_dir / f"{args.slug}.spans.json"
    json_path.write_text(json.dumps(data, indent=1) + "\n")
    html_path = args.out_dir / f"{args.slug}.html"
    render_html(data, html_path)
    started = txn["span_count"].get("started", len(spans))
    print(f"{len(spans)}/{started} spans → {json_path}\n{html_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

## Appendix B: `scripts/waterfall_template.html`

The exporter replaces `__TITLE__` and `/*__DATA__*/null` (the JSON payload, with `</` escaped).

````html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root {
  --bg: #ffffff;
  --bg-alt: #f7f8fc;
  --bg-hover: #eef3fc;
  --text: #1d2a3e;
  --muted: #5a6d8c;
  --border: #e3e8f2;
  --grid: #edf0f5;
  --bar: #16c5c0;
  --bar-root: #16c5c0;
  --chip-bg: #ffffff;
  --chip-border: #cad3e2;
  --tag-bg: #e3e8f2;
  --dot: #54b399;
  --ok-bg: #24c292;
  --ok-text: #0b3b2c;
  --fail: #e7664c;
  --match: #fff3c4;
  --link: #0b64dd;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #0b1628;
    --bg-alt: #111c2e;
    --bg-hover: #17253c;
    --text: #dfe5ef;
    --muted: #8e9fbc;
    --border: #23314a;
    --grid: #1a273d;
    --chip-bg: #0b1628;
    --chip-border: #34445f;
    --tag-bg: #23314a;
    --match: #4a3f12;
    --link: #61a2ff;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 12px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif;
}
header { padding: 16px 16px 8px; border-bottom: 1px solid var(--border); }
h1 { font-size: 16px; margin: 0 0 6px; font-weight: 600; }
.meta { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; color: var(--muted); }
.meta a { color: var(--link); }
.pill {
  display: inline-flex; align-items: center; gap: 4px;
  padding: 0 6px; border-radius: 3px; font-size: 11px; line-height: 18px;
  background: var(--tag-bg); color: var(--text); white-space: nowrap;
}
.pill.ok { background: var(--ok-bg); color: var(--ok-text); }
.pill.fail { background: var(--fail); color: #fff; }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
.toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 8px 16px; border-bottom: 1px solid var(--border); }
.toolbar button, .toolbar input {
  font: inherit; color: var(--text); background: var(--chip-bg);
  border: 1px solid var(--chip-border); border-radius: 4px; padding: 3px 8px;
}
.toolbar button { cursor: pointer; }
.toolbar input { width: 260px; max-width: 100%; }
.legend { display: inline-flex; align-items: center; gap: 4px; margin-left: auto; color: var(--muted); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dot); display: inline-block; flex: none; }

#wf { --gutter: 48px; position: relative; padding: 0 16px 24px; }
.axis {
  position: sticky; top: 0; z-index: 2; height: 26px;
  display: flex; background: var(--bg); border-bottom: 1px solid var(--border);
}
.axis .track, .row .track { position: relative; flex: 1; margin-right: 40px; }
.axis .gut, .row .gut { width: var(--gutter); flex: none; }
.tick { position: absolute; top: 8px; transform: translateX(-50%); color: var(--muted); font-size: 10px; white-space: nowrap; }
.tick:first-child { transform: none; }
.tick.end { transform: translateX(-100%); color: var(--text); font-weight: 600; }
.grid { position: absolute; top: 26px; bottom: 24px; left: calc(16px + var(--gutter)); right: 56px; pointer-events: none; }
.grid i { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--grid); }

.row { display: flex; height: 33px; border-bottom: 1px solid var(--border); position: relative; }
.row:nth-child(even) { background: var(--bg-alt); }
.row:hover { background: var(--bg-hover); }
.row.match { background: var(--match); }
.row .gut { display: flex; align-items: center; color: var(--muted); font-size: 10px; }
.toggle {
  all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 2px;
  padding: 2px 3px; border-radius: 3px; color: var(--muted);
}
.toggle:hover, .toggle:focus-visible { background: var(--tag-bg); color: var(--text); }
.toggle svg { transition: transform .1s; }
.toggle[aria-expanded="false"] svg { transform: rotate(-90deg); }
.bar { position: absolute; top: 4px; height: 8px; min-width: 1px; background: var(--bar); border-radius: 1px; }
.bar.fail { background: var(--fail); }
.bar.ghost { background: transparent; border: 1px dashed var(--muted); }
.row.missing .name { color: var(--muted); font-style: italic; }
.pill.warn { background: #fdecc8; color: #6a4a00; }
.label {
  position: absolute; top: 14px; display: flex; align-items: center; gap: 5px;
  white-space: nowrap; font-size: 11px;
}
.label.flip { flex-direction: row-reverse; }
.label .name { overflow: hidden; text-overflow: ellipsis; max-width: 520px; }
.chip {
  display: inline-flex; align-items: center; gap: 4px; padding: 0 5px; line-height: 15px;
  border: 1px solid var(--chip-border); border-radius: 3px; background: var(--chip-bg); font-size: 10px;
}
.tag { padding: 0 5px; line-height: 15px; border-radius: 3px; background: var(--tag-bg); font-size: 10px; }
.icon { color: var(--muted); flex: none; }
.outcome { font-size: 10px; color: var(--muted); }
.empty { padding: 24px; color: var(--muted); }
</style>
</head>
<body>
<header>
  <h1 id="title"></h1>
  <div class="meta" id="meta"></div>
</header>
<div class="toolbar">
  <button type="button" id="expand">Expand all</button>
  <button type="button" id="collapse">Collapse all</button>
  <button type="button" id="reset">Default view</button>
  <input type="search" id="filter" placeholder="Filter spans by name…" aria-label="Filter spans by name">
  <span id="count" class="outcome"></span>
  <span class="legend" id="legend"></span>
</div>
<div id="wf">
  <div class="axis"><div class="gut"></div><div class="track" id="ticks"></div></div>
  <div class="grid" id="grid"></div>
  <div id="rows"></div>
</div>
<script id="data" type="application/json">/*__DATA__*/null</script>
<script>
(() => {
  const DATA = JSON.parse(document.getElementById('data').textContent);
  const { transaction: txn, spans } = DATA;
  const total = txn.duration_us;
  const AUTO_COLLAPSE_CHILDREN = 10;
  const SYNC_DEFAULT_AGENTS = new Set(['nodejs', 'js-base', 'rum-js']);

  const fmtDur = (us) => {
    if (us < 1000) return `${Math.round(us)} μs`;
    const ms = us / 1000;
    if (ms < 10) return `${ms.toFixed(1)} ms`;
    if (ms < 10000) return `${Math.round(ms).toLocaleString('en-US')} ms`;
    return `${Math.round(ms / 1000)} s`;
  };
  const fmtOffset = (us) => (us >= 1e6 ? `${(us / 1e6).toFixed(3)} s` : fmtDur(us));
  const pct = (us) => Math.max(0, Math.min(100, (us / total) * 100));
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const root = {
    id: txn.id, name: txn.name, start_us: 0, duration_us: total, depth: 0,
    service: txn.service, outcome: txn.outcome, result: txn.result, isRoot: true, children: [],
  };
  const byId = new Map([[root.id, root]]);
  spans.forEach((s) => byId.set(s.id, { ...s, children: [] }));
  const missingParents = new Map();
  spans.forEach((s) => {
    const node = byId.get(s.id);
    const parent = byId.get(s.parent);
    if (parent) {
      parent.children.push(node);
      return;
    }
    if (!missingParents.has(s.parent)) {
      missingParents.set(s.parent, {
        id: `missing-${s.parent}`, name: `missing parent span ${s.parent} (not indexed)`,
        isMissing: true, start_us: Infinity, end_us: 0, children: [],
      });
    }
    const placeholder = missingParents.get(s.parent);
    placeholder.children.push(node);
    placeholder.start_us = Math.min(placeholder.start_us, s.start_us);
    placeholder.end_us = Math.max(placeholder.end_us, s.start_us + s.duration_us);
  });
  missingParents.forEach((p) => {
    p.duration_us = p.end_us - p.start_us;
    root.children.push(p);
  });
  const orphanCount = [...missingParents.values()].reduce((sum, p) => sum + p.children.length, 0);
  const notIndexed = (txn.span_count?.started ?? spans.length) - spans.length;
  const nodes = [];
  const walk = (node, depth, parent) => {
    node.depth = depth;
    node.parentNode = parent;
    node.children.sort((a, b) => a.start_us - b.start_us);
    nodes.push(node);
    node.children.forEach((c) => walk(c, depth + 1, node));
  };
  walk(root, 0, null);
  const maxDepth = Math.max(...nodes.map((n) => n.depth));
  document.getElementById('wf').style.setProperty('--gutter', `${44 + maxDepth * 10}px`);

  // Auto-collapse N+1 fan-outs: many children drawn from a handful of repeated span names.
  const isNoisyParent = (n) => {
    if (n.isMissing) return true;
    if (n.isRoot || n.children.length < AUTO_COLLAPSE_CHILDREN) return false;
    const distinctNames = new Set(n.children.map(({ name }) => name)).size;
    return n.children.length / distinctNames >= 5;
  };
  const defaultCollapsed = () => new Set(nodes.filter(isNoisyParent).map((n) => n.id));
  let collapsed = defaultCollapsed();
  let filter = '';

  document.title = DATA.title || txn.name;
  document.getElementById('title').textContent = DATA.title || txn.name;
  const status = txn.status_code ? `${txn.status_code}${txn.status_code < 400 ? ' OK' : ''}` : txn.result;
  const meta = [
    `<span>${esc(new Date(txn.timestamp).toUTCString())}</span>`,
    `<span>${fmtDur(total)} (100% of trace)</span>`,
    txn.url ? `<span class="pill mono">${esc(txn.method || '')} ${esc(txn.url)}</span>` : '',
    status ? `<span class="pill ${txn.status_code >= 400 ? 'fail' : 'ok'}">${esc(status)}</span>` : '',
    `<span>${spans.length.toLocaleString('en-US')} spans</span>`,
    notIndexed > 0
      ? `<span class="pill warn" title="span_count.started minus spans found in ES">⚠ ${notIndexed.toLocaleString('en-US')} of ${txn.span_count.started.toLocaleString('en-US')} started spans not indexed</span>`
      : '',
    orphanCount
      ? `<span class="pill warn">⚠ ${orphanCount.toLocaleString('en-US')} orphan spans under ${missingParents.size} missing parent${missingParents.size > 1 ? 's' : ''}</span>`
      : '',
    txn.environment ? `<span>env <span class="mono">${esc(txn.environment)}</span></span>` : '',
    `<span>trace <span class="mono">${esc(DATA.trace_id)}</span></span>`,
    DATA.kibana_url ? `<a href="${esc(DATA.kibana_url)}" target="_blank" rel="noopener">Open in Kibana APM ↗</a>` : '',
  ];
  document.getElementById('meta').innerHTML = meta.join('');
  const services = [...new Set(nodes.map((n) => n.service).filter(Boolean))];
  document.getElementById('legend').innerHTML =
    `Services ${services.map((s) => `<span class="dot"></span>${esc(s)}`).join(' ')}`;

  const niceStep = (range) => {
    const raw = range / 5;
    const mag = 10 ** Math.floor(Math.log10(raw));
    return [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw);
  };
  const tickLabel = (us) => (total >= 1e6 ? `${+(us / 1e6).toFixed(1)} s` : fmtDur(us));
  const step = niceStep(total);
  const tickEls = [];
  const gridEls = [];
  for (let t = 0; t < total - step * 0.25; t += step) {
    tickEls.push(`<span class="tick" style="left:${pct(t)}%">${tickLabel(t)}</span>`);
    gridEls.push(`<i style="left:${pct(t)}%"></i>`);
  }
  tickEls.push(`<span class="tick end" style="left:100%">${fmtDur(total)}</span>`);
  gridEls.push('<i style="left:100%"></i>');
  document.getElementById('ticks').innerHTML = tickEls.join('');
  document.getElementById('grid').innerHTML = gridEls.join('');

  const DB_ICON = '<svg class="icon" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><ellipse cx="8" cy="3.5" rx="5.5" ry="2"/><path d="M2.5 3.5v9c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2v-9M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2"/></svg>';
  const TXN_ICON = '<svg class="icon" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 5h11l-3-3M14 11H3l3 3"/></svg>';
  const CHEVRON = '<svg width="10" height="10" viewBox="0 0 16 16" fill="currentColor"><path d="M3.3 5.3a1 1 0 0 1 1.4 0L8 8.6l3.3-3.3a1 1 0 1 1 1.4 1.4l-4 4a1 1 0 0 1-1.4 0l-4-4a1 1 0 0 1 0-1.4z"/></svg>';

  const syncTag = (n) => {
    if (n.sync == null || !n.agent) return '';
    const syncDefault = SYNC_DEFAULT_AGENTS.has(n.agent);
    if (n.sync && syncDefault) return '<span class="tag">blocking</span>';
    if (!n.sync && !syncDefault) return '<span class="tag">async</span>';
    return '';
  };

  const tooltip = (n) => [
    n.name,
    `start: +${fmtOffset(n.start_us)}`,
    `duration: ${fmtDur(n.duration_us)} (${pct(n.duration_us).toFixed(1)}% of txn)`,
    n.type ? `type: ${n.type}${n.subtype ? `/${n.subtype}` : ''}` : '',
    n.outcome ? `outcome: ${n.outcome}` : '',
    n.children.length ? `children: ${n.children.length}` : '',
    `id: ${n.id}`,
  ].filter(Boolean).join('\n');

  const toggle = (n) => (n.children.length
    ? `<button class="toggle" data-id="${n.id}" aria-expanded="${!collapsed.has(n.id)}" aria-label="Toggle ${n.children.length} children">${CHEVRON}${n.children.length}</button>`
    : '');

  const rowHtml = (n) => {
    const left = pct(n.start_us);
    const width = pct(n.duration_us);
    const end = left + width;
    const flip = left > 55;
    const failed = n.outcome === 'failure';
    if (n.isMissing) {
      return `<div class="row missing" title="${esc(tooltip(n))}">`
        + `<div class="gut" style="padding-left:${n.depth * 10}px">${toggle(n)}</div>`
        + `<div class="track"><div class="bar ghost" style="left:${left}%;width:${width}%"></div>`
        + `<div class="label${flip ? ' flip' : ''}" style="${flip ? `right:${100 - end}%` : `left:${left}%`}">`
        + `<span class="name">⚠ ${esc(n.name)}</span><span class="chip">⏱ ${fmtDur(n.duration_us)} (children range)</span></div></div></div>`;
    }
    const pos = flip ? `right:${100 - end}%` : `left:${left}%`;
    const icon = n.isRoot ? TXN_ICON : n.type === 'db' ? DB_ICON : '';
    const outcome = n.isRoot && n.result ? `<span class="outcome">${esc(n.result)}</span>` : '';
    const service = n.service ? `<span class="chip"><span class="dot"></span>${esc(n.service)}</span>` : '';
    return `<div class="row${filter && n.name.toLowerCase().includes(filter) ? ' match' : ''}" title="${esc(tooltip(n))}">`
      + `<div class="gut" style="padding-left:${n.depth * 10}px">${toggle(n)}</div>`
      + `<div class="track"><div class="bar${failed ? ' fail' : ''}" style="left:${left}%;width:${width}%"></div>`
      + `<div class="label${flip ? ' flip' : ''}" style="${pos}">${icon}${outcome}<span class="name">${esc(n.name)}</span>`
      + `${service}<span class="chip">⏱ ${fmtDur(n.duration_us)}</span>${syncTag(n)}</div></div></div>`;
  };

  const visibleNodes = () => {
    if (filter) {
      const keep = new Set();
      nodes.forEach((n) => {
        if (!n.name.toLowerCase().includes(filter)) return;
        for (let p = n; p && !keep.has(p.id); p = p.parentNode) keep.add(p.id);
      });
      return nodes.filter((n) => keep.has(n.id));
    }
    const out = [];
    const visit = (n) => {
      out.push(n);
      if (!collapsed.has(n.id)) n.children.forEach(visit);
    };
    visit(root);
    return out;
  };

  const rowsEl = document.getElementById('rows');
  const countEl = document.getElementById('count');
  const render = () => {
    const visible = visibleNodes();
    rowsEl.innerHTML = visible.length ? visible.map(rowHtml).join('') : '<div class="empty">No spans match.</div>';
    countEl.textContent = `${visible.length.toLocaleString('en-US')} of ${nodes.length.toLocaleString('en-US')} rows shown`;
  };

  rowsEl.addEventListener('click', (e) => {
    const btn = e.target.closest('.toggle');
    if (!btn || filter) return;
    const { id } = btn.dataset;
    if (collapsed.has(id)) collapsed.delete(id); else collapsed.add(id);
    render();
  });
  document.getElementById('expand').onclick = () => { collapsed = new Set(); render(); };
  document.getElementById('collapse').onclick = () => {
    collapsed = new Set(nodes.filter((n) => n.children.length && !n.isRoot).map((n) => n.id));
    render();
  };
  document.getElementById('reset').onclick = () => { collapsed = defaultCollapsed(); render(); };
  let debounce;
  document.getElementById('filter').addEventListener('input', (e) => {
    clearTimeout(debounce);
    debounce = setTimeout(() => { filter = e.target.value.trim().toLowerCase(); render(); }, 120);
  });
  render();
})();
</script>
</body>
</html>
````

## Appendix C: `scripts/export_index.py`

```python
#!/usr/bin/env python3
"""Build index.html listing exported waterfalls in an apm/ folder.

Scans `*.spans.json` next to their `.html` siblings. Filenames:

  NN-slug.spans.json           → single-column index
  NN-slug.main.spans.json      → multi-column (one column per side: main, pr, …)
  NN-slug.pr.spans.json

Usage:
  export_index.py --apm-dir <bench>/apm
  export_index.py --apm-dir <bench>/apm --out <bench>/index.html \\
    --title "APM waterfalls — …" --h1 "APM waterfalls — …" \\
    --pill 2026-11-12T0852 --pill r3 \\
    --link "PR #304858=https://github.com/elastic/kibana/pull/304858" \\
    --link "SUMMARY=https://…"
"""

from __future__ import annotations

import argparse
import json
import re
from collections import OrderedDict
from pathlib import Path

FILE_RE = re.compile(
    r"^(?P<num>\d+)-(?P<body>.+?)(?:\.(?P<side>[^.]+))?\.spans\.json$"
)
TITLE_NUM_RE = re.compile(r"^#?\d+\s+")
TITLE_SIDE_RE = re.compile(r"\s*\([^)]*\)\s*$")

CSS = """\
:root {
  --bg: #ffffff;
  --bg-alt: #f7f8fc;
  --bg-hover: #eef3fc;
  --text: #1d2a3e;
  --muted: #5a6d8c;
  --border: #e3e8f2;
  --tag-bg: #e3e8f2;
  --link: #0b64dd;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #0b1628;
    --bg-alt: #111c2e;
    --bg-hover: #17253c;
    --text: #dfe5ef;
    --muted: #8e9fbc;
    --border: #23314a;
    --tag-bg: #23314a;
    --link: #61a2ff;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif;
}
header { padding: 20px 24px 12px; border-bottom: 1px solid var(--border); }
h1 { font-size: 18px; margin: 0 0 8px; font-weight: 600; }
.meta { display: flex; flex-wrap: wrap; gap: 6px 12px; color: var(--muted); }
.meta a { color: var(--link); }
.pill {
  display: inline-flex; align-items: center;
  padding: 0 7px; border-radius: 3px; font-size: 11px; line-height: 18px;
  background: var(--tag-bg); color: var(--text); white-space: nowrap;
}
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
main { padding: 16px 24px 32px; max-width: 1200px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; }
tr:hover td { background: var(--bg-hover); }
td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
td.idx { color: var(--muted); width: 2.5em; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
.note { margin-top: 16px; color: var(--muted); font-size: 12px; }
"""

DEFAULT_NOTE = (
    "Durations and span counts from the exported transactions. Each waterfall is a "
    "static export of the matching monitoring transaction. Rows marked "
    '<span class="pill">incomplete</span> have fewer indexed span docs than '
    '<span class="mono">span_count.started</span> (not-indexed / orphans — see page banner).'
)

SIDE_ORDER = {"main": 0, "baseline": 1, "before": 2, "pr": 10, "after": 11}
SIDE_LABEL = {"pr": "PR", "main": "main", "baseline": "baseline", "before": "before", "after": "after"}


def side_label(side: str) -> str:
    return SIDE_LABEL.get(side, side)


def esc(s: str) -> str:
    return (
        str(s)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def fmt_dur(us: int) -> str:
    s = us / 1e6
    if s < 10:
        return f"{s:.1f}s"
    return f"{round(s)}s" if s >= 100 else f"{s:.1f}s"


def load_entry(path: Path) -> dict:
    data = json.loads(path.read_text())
    txn = data["transaction"]
    started = txn.get("span_count", {}).get("started")
    indexed = len(data.get("spans", []))
    title = data.get("title") or txn.get("name") or path.stem
    html_name = path.name.replace(".spans.json", ".html")
    return {
        "title": title,
        "duration_us": txn["duration_us"],
        "dur": fmt_dur(txn["duration_us"]),
        "spans": started if started is not None else indexed,
        "indexed": indexed,
        "started": started,
        "html": html_name,
        "incomplete": started is not None and indexed < started,
    }


def scenario_name(title: str) -> str:
    name = TITLE_NUM_RE.sub("", title).strip()
    name = TITLE_SIDE_RE.sub("", name).strip()
    if name and not name.endswith("."):
        name += "."
    return name


def incomplete_pill(entry: dict) -> str:
    if not entry["incomplete"]:
        return ""
    tip = f'{entry["indexed"]}/{entry["started"]} expected={entry["started"]}'
    return f' <span class="pill" title="{esc(tip)}">incomplete</span>'


def side_key(side: str | None) -> tuple:
    if side is None:
        return (0, "")
    return (SIDE_ORDER.get(side, 50), side)


def collect(apm_dir: Path) -> tuple[list[dict], list[str]]:
    """Return (rows, sides). sides empty → single-column mode."""
    groups: OrderedDict[tuple[int, str], dict] = OrderedDict()
    sides_seen: set[str] = set()

    for path in sorted(apm_dir.glob("*.spans.json")):
        m = FILE_RE.match(path.name)
        if not m:
            continue
        num = int(m.group("num"))
        body = m.group("body")
        side = m.group("side")
        entry = load_entry(path)
        key = (num, body)
        if key not in groups:
            groups[key] = {"num": num, "slug": body, "by_side": {}, "single": None}
        if side:
            sides_seen.add(side)
            groups[key]["by_side"][side] = entry
        else:
            groups[key]["single"] = entry

    sides = sorted(sides_seen, key=side_key)
    rows = []
    for (_num, _body), g in groups.items():
        if sides:
            # Prefer a title from the first available side
            sample = next((g["by_side"][s] for s in sides if s in g["by_side"]), None)
            if sample is None:
                continue
            rows.append(
                {
                    "num": g["num"],
                    "name": scenario_name(sample["title"]),
                    "by_side": g["by_side"],
                }
            )
        else:
            if g["single"] is None:
                continue
            rows.append(
                {
                    "num": g["num"],
                    "name": scenario_name(g["single"]["title"]),
                    "single": g["single"],
                }
            )
    rows.sort(key=lambda r: r["num"])
    return rows, sides


def render_meta(pills: list[str], links: list[tuple[str, str]], extra: list[str]) -> str:
    parts = [f'<span class="pill mono">{esc(p)}</span>' for p in pills]
    parts.extend(extra)
    parts.extend(f'<a href="{esc(url)}">{esc(label)}</a>' for label, url in links)
    return "\n    ".join(parts)


def parse_link(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError(f"--link needs LABEL=URL, got {raw!r}")
    label, _, url = raw.partition("=")
    if not label or not url:
        raise argparse.ArgumentTypeError(f"--link needs LABEL=URL, got {raw!r}")
    return label, url


def render_single(rows: list[dict]) -> tuple[str, str]:
    thead = """      <tr>
        <th>#</th>
        <th>Scenario</th>
        <th class="num">APM dur</th>
        <th class="num">spans</th>
        <th>Waterfall</th>
      </tr>"""
    body = []
    for r in rows:
        e = r["single"]
        body.append(
            f"""      <tr>
        <td class="idx">{r['num']}</td>
        <td>{esc(r['name'])}{incomplete_pill(e)}</td>
        <td class="num mono">{esc(e['dur'])}</td>
        <td class="num mono">{e['spans']}</td>
        <td><a href="apm/{esc(e['html'])}">{esc(e['html'])}</a></td>
      </tr>"""
        )
    return thead, "\n".join(body)


def render_multi(rows: list[dict], sides: list[str]) -> tuple[str, str]:
    head_cells = ["        <th>#</th>", "        <th>Scenario</th>"]
    for side in sides:
        label = side_label(side)
        head_cells.append(f'        <th class="num">{esc(label)} APM</th>')
        head_cells.append(f'        <th class="num">{esc(label)} spans</th>')
        head_cells.append(f"        <th>{esc(label)} waterfall</th>")
    thead = "      <tr>\n" + "\n".join(head_cells) + "\n      </tr>"

    body = []
    for r in rows:
        pills = "".join(
            incomplete_pill(r["by_side"][s]) for s in sides if s in r["by_side"]
        )
        cells = [
            f'        <td class="idx">{r["num"]}</td>',
            f'        <td>{esc(r["name"])}{pills}</td>',
        ]
        for side in sides:
            e = r["by_side"].get(side)
            if not e:
                cells.extend(
                    [
                        '        <td class="num mono">—</td>',
                        '        <td class="num mono">—</td>',
                        "        <td>—</td>",
                    ]
                )
                continue
            cells.extend(
                [
                    f'        <td class="num mono">{esc(e["dur"])}</td>',
                    f'        <td class="num mono">{e["spans"]}</td>',
                    f'        <td><a href="apm/{esc(e["html"])}">{esc(e["html"])}</a></td>',
                ]
            )
        body.append("      <tr>\n" + "\n".join(cells) + "\n      </tr>")
    return thead, "\n".join(body)


def render_html(
    *,
    title: str,
    h1: str,
    meta: str,
    thead: str,
    tbody: str,
    note: str,
) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
{CSS}</style>
</head>
<body>
<header>
  <h1>{esc(h1)}</h1>
  <div class="meta">
    {meta}
  </div>
</header>
<main>
  <table>
    <thead>
{thead}
    </thead>
    <tbody>
{tbody}
    </tbody>
  </table>
  <p class="note">{note}</p>
</main>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apm-dir", type=Path, required=True, help="Folder with *.spans.json + *.html")
    ap.add_argument("--out", type=Path, help="Defaults to <apm-dir>/../index.html")
    ap.add_argument("--title", help="Document <title>")
    ap.add_argument("--h1", help="Page heading (defaults to --title)")
    ap.add_argument("--pill", action="append", default=[], help="Header pill (repeatable)")
    ap.add_argument(
        "--link",
        action="append",
        default=[],
        type=parse_link,
        help="Header link as LABEL=URL (repeatable)",
    )
    ap.add_argument("--meta-html", action="append", default=[], help="Raw HTML snippet for the meta row")
    ap.add_argument("--note", default=DEFAULT_NOTE, help="Footer note HTML")
    args = ap.parse_args()

    apm_dir = args.apm_dir.resolve()
    if not apm_dir.is_dir():
        raise SystemExit(f"not a directory: {apm_dir}")

    rows, sides = collect(apm_dir)
    if not rows:
        raise SystemExit(f"no *.spans.json found in {apm_dir}")

    out = args.out or (apm_dir.parent / "index.html")
    stamp = apm_dir.parent.name
    default_title = f"APM waterfalls — {stamp}"
    title = args.title or default_title
    h1 = args.h1 or title

    if sides:
        thead, tbody = render_multi(rows, sides)
        mode = f"multi ({', '.join(sides)})"
    else:
        thead, tbody = render_single(rows)
        mode = "single"

    meta = render_meta(args.pill, args.link, args.meta_html)
    html = render_html(title=title, h1=h1, meta=meta, thead=thead, tbody=tbody, note=args.note)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html)
    print(f"{len(rows)} scenarios · {mode} → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```
