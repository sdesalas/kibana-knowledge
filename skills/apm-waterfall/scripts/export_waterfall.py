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
