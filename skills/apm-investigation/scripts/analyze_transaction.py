#!/usr/bin/env python3
"""Rank spans for one APM trace by union wall-clock impact."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from es_api import es_request, esql, esql_rows, load_creds  # noqa: E402


def parse_ts(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    if "." in s:
        head, rest = s.split(".", 1)
        frac = ""
        tz = "+00:00"
        for i, ch in enumerate(rest):
            if ch.isdigit():
                frac += ch
            else:
                tz = rest[i:]
                break
        s = f"{head}.{(frac + '000000')[:6]}{tz}"
    return datetime.fromisoformat(s)


def union_seconds(intervals: list[tuple[datetime, datetime]]) -> float:
    if not intervals:
        return 0.0
    iv = sorted(intervals)
    merged: list[tuple[datetime, datetime]] = []
    cs, ce = iv[0]
    for s, e in iv[1:]:
        if s <= ce:
            if e > ce:
                ce = e
        else:
            merged.append((cs, ce))
            cs, ce = s, e
    merged.append((cs, ce))
    return sum((e - s).total_seconds() for s, e in merged)


def pattern_for(name: str, n: int, union_s: float, sum_s: float) -> str:
    low = name.lower()
    if n >= 50 and "has_privileges" in low:
        return "authz N+1"
    if n >= 100 and ("update_by_query" in low or "/_doc/" in low):
        return "N+1 ES"
    if n >= 20 and sum_s > 3 * max(union_s, 0.001):
        return "parallel fan-out"
    if n <= 15 and union_s > 0.9 * sum_s and sum_s >= 0.5 and (
        "_bulk" in low or "import" in low or "route handler" in low
    ):
        return "serial / critical path"
    if "ebt-" in low or "usage_counters" in low or "telemetry" in low:
        return "side-effect noise"
    if "api_key" in low or "createapikey" in low or "grant" in low:
        return "api-key work"
    if "exception" in low:
        return "exception path"
    if n >= 50:
        return "high call count"
    return ""


def fetch_txn(creds: dict, idx: str, trace_id: str) -> dict | None:
    q = f"""FROM {idx}
| WHERE trace.id == "{trace_id}"
| WHERE processor.event == "transaction"
| KEEP @timestamp, transaction.name, transaction.duration.us, transaction.span_count.started, transaction.span_count.dropped, url.path, service.environment, host.hostname, labels.deploymentName, transaction.id, transaction.type
| SORT transaction.duration.us DESC
| LIMIT 10"""
    rows = esql_rows(esql(creds, q))
    if not rows:
        return None
    # Prefer request-type / longest
    for r in rows:
        if (r.get("transaction.type") == "request") or (
            r.get("url.path") and r.get("transaction.name", "").startswith(("GET", "POST", "PUT", "DELETE", "PATCH"))
        ):
            return r
    return rows[0]


def page_spans(
    creds: dict,
    idx: str,
    trace_id: str,
    t0: str,
    t1: str,
) -> list[dict]:
    spans: list[dict] = []
    after = None
    while True:
        body: dict = {
            "size": 2000,
            "sort": [{"@timestamp": "asc"}, {"_doc": "asc"}],
            "query": {
                "bool": {
                    "filter": [
                        {"term": {"processor.event": "span"}},
                        {"term": {"trace.id": trace_id}},
                        {"range": {"@timestamp": {"gte": t0, "lte": t1}}},
                    ]
                }
            },
            "_source": ["@timestamp", "span", "parent"],
        }
        if after:
            body["search_after"] = after
        res = es_request(creds, f"/{idx}/_search", body)
        hits = res.get("hits", {}).get("hits", [])
        if not hits:
            break
        for h in hits:
            src = h.get("_source") or {}
            span = src.get("span") or {}
            name = span.get("name")
            us = (span.get("duration") or {}).get("us")
            if name is None or us is None:
                continue
            start = parse_ts(src["@timestamp"])
            end = start + timedelta(microseconds=int(us))
            spans.append(
                {
                    "name": name,
                    "start": start,
                    "end": end,
                    "us": int(us),
                    "id": span.get("id"),
                    "parent": (src.get("parent") or {}).get("id"),
                }
            )
        after = hits[-1]["sort"]
        if len(hits) < 2000:
            break
    return spans


def analyze_trace(
    creds: dict,
    trace_id: str,
    *,
    pad_seconds: float = 2.0,
    top: int = 25,
    dropped_warn_threshold: int = 100,
) -> dict:
    """Return union-wall ranking dict for one trace.id."""
    idx = creds.get("APM_INDEX") or "traces-apm*"
    txn = fetch_txn(creds, idx, trace_id)

    if txn:
        dur_us = int(txn.get("transaction.duration.us") or 0)
        started = txn.get("transaction.span_count.started")
        dropped = txn.get("transaction.span_count.dropped")
        if dropped is None:
            dropped = 0
        rh_start = parse_ts(txn["@timestamp"])
        window_start = rh_start - timedelta(seconds=pad_seconds)
        window_end = rh_start + timedelta(microseconds=dur_us) + timedelta(seconds=pad_seconds)
        txn_dur_s = dur_us / 1e6
        label = txn.get("transaction.name")
    else:
        q = f"""FROM {idx}
| WHERE trace.id == "{trace_id}"
| WHERE processor.event == "span"
| WHERE span.name == "route handler"
| KEEP @timestamp, span.duration.us
| SORT span.duration.us DESC
| LIMIT 1"""
        rows = esql_rows(esql(creds, q))
        if not rows:
            raise LookupError(f"No transaction or route handler for trace.id={trace_id}")
        rh_start = parse_ts(rows[0]["@timestamp"])
        dur_us = int(rows[0]["span.duration.us"])
        txn_dur_s = dur_us / 1e6
        window_start = rh_start - timedelta(seconds=pad_seconds)
        window_end = rh_start + timedelta(microseconds=dur_us) + timedelta(seconds=pad_seconds)
        started = dropped = None
        label = "route handler (no HTTP txn doc)"
        txn = {"@timestamp": rows[0]["@timestamp"], "transaction.name": label}

    def iso(dt: datetime) -> str:
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    all_spans = page_spans(creds, idx, trace_id, iso(window_start), iso(window_end))
    rh_end = rh_start + timedelta(microseconds=dur_us)
    spans = [s for s in all_spans if s["end"] >= rh_start and s["start"] <= rh_end]

    by: dict[str, list] = defaultdict(list)
    for s in spans:
        by[s["name"]].append(s)

    ranked = []
    for name, lst in by.items():
        uni = union_seconds([(x["start"], x["end"]) for x in lst])
        sm = sum(x["us"] for x in lst) / 1e6
        n = len(lst)
        ranked.append(
            {
                "name": name,
                "n": n,
                "union_s": uni,
                "sum_s": sm,
                "pct": 100.0 * uni / txn_dur_s if txn_dur_s else 0.0,
                "pattern": pattern_for(name, n, uni, sm),
            }
        )
    ranked.sort(key=lambda r: r["union_s"], reverse=True)

    dropped_n = int(dropped) if dropped is not None else 0
    incomplete = dropped is not None and dropped_n > dropped_warn_threshold

    return {
        "trace_id": trace_id,
        "transaction": {
            "name": label,
            "timestamp": txn.get("@timestamp"),
            "duration_s": txn_dur_s,
            "span_count_started": started,
            "span_count_dropped": dropped,
            "url.path": txn.get("url.path"),
            "service.environment": txn.get("service.environment"),
            "host.hostname": txn.get("host.hostname"),
            "labels.deploymentName": txn.get("labels.deploymentName"),
        },
        "incomplete_due_to_dropped_spans": incomplete,
        "spans_analyzed": len(spans),
        "top": ranked[:top],
        "all": ranked,
    }


def print_analysis(out: dict, *, top: int = 25) -> None:
    txn = out["transaction"]
    print(f"trace.id:     {out['trace_id']}")
    print(f"transaction:  {txn.get('name')}")
    print(f"started at:   {txn.get('timestamp')}")
    print(f"duration:     {txn.get('duration_s'):.3f}s")
    print(f"url.path:     {txn.get('url.path')}")
    print(f"environment:  {txn.get('service.environment')}")
    print(f"deployment:   {txn.get('labels.deploymentName')}")
    print(f"hostname:     {txn.get('host.hostname')}")
    print(
        f"span_count:   started={txn.get('span_count_started')}  "
        f"dropped={txn.get('span_count_dropped')}"
    )
    print(f"spans used:   {out['spans_analyzed']} overlapping txn window")
    print()

    if out.get("incomplete_due_to_dropped_spans"):
        dropped_n = int(txn.get("span_count_dropped") or 0)
        started = txn.get("span_count_started")
        print("🚨" * 8)
        print(
            f"🚨 APM dropped {dropped_n} spans "
            f"(started={started}, dropped={dropped_n}) — this trace is INCOMPLETE."
        )
        print(
            "🚨 Prefer raising `elastic.apm.transactionMaxSpans` in kibana.dev.yml "
            "(or equivalent), restart Kibana, re-run the operation, then re-analyze."
        )
        print(
            "🚨 Continuing on partial data only if you cannot reproduce — "
            "counts and rankings may be wrong."
        )
        print("🚨" * 8)
        print()

    ranked = out.get("all") or out.get("top") or []
    print(f"{'rank':>4}  {'n':>5}  {'union_s':>8}  {'%txn':>6}  {'sum_s':>8}  pattern              name")
    print("-" * 120)
    for i, r in enumerate(ranked[:top], 1):
        print(
            f"{i:4d}  {r['n']:5d}  {r['union_s']:8.3f}  {r['pct']:5.1f}%  {r['sum_s']:8.3f}  "
            f"{(r['pattern'] or '-'):20s}  {r['name']}"
        )

    print()
    print("Top actions (by union wall):")
    shown = 0
    for r in ranked:
        if r["name"] == "route handler":
            continue
        shown += 1
        print(
            f"  {shown}. {r['name']}: {r['union_s']:.3f}s ({r['pct']:.1f}% of txn), n={r['n']}"
            + (f" [{r['pattern']}]" if r["pattern"] else "")
        )
        if shown >= 5:
            break


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--trace-id", required=True)
    p.add_argument("--pad-seconds", type=float, default=2.0)
    p.add_argument("--top", type=int, default=25)
    p.add_argument("--json", action="store_true")
    p.add_argument("--dropped-warn-threshold", type=int, default=100)
    args = p.parse_args()

    try:
        out = analyze_trace(
            load_creds(),
            args.trace_id,
            pad_seconds=args.pad_seconds,
            top=args.top,
            dropped_warn_threshold=args.dropped_warn_threshold,
        )
    except LookupError as e:
        print(str(e), file=sys.stderr)
        return 1

    if args.json:
        # keep payload smaller in json mode
        slim = {k: v for k, v in out.items() if k != "all"}
        print(json.dumps(slim, indent=2, default=str))
        return 0

    print_analysis(out, top=args.top)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())