#!/usr/bin/env python3
"""Compare union-wall span impact for the same scenario across two traces."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from es_api import load_creds  # noqa: E402
from analyze_transaction import analyze_trace  # noqa: E402


def warn_dropped(label: str, side: dict) -> None:
    if not side.get("incomplete_due_to_dropped_spans"):
        return
    txn = side["transaction"]
    print("🚨" * 8)
    print(
        f"🚨 [{label}] APM dropped {txn.get('span_count_dropped')} spans "
        f"(started={txn.get('span_count_started')}) — INCOMPLETE."
    )
    print(
        "🚨 Prefer raising `elastic.apm.transactionMaxSpans`, restart, re-run, re-compare."
    )
    print("🚨" * 8)
    print()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--trace-a", required=True, help="Baseline / control trace.id")
    p.add_argument("--trace-b", required=True, help="Candidate / PR / new trace.id")
    p.add_argument("--label-a", default="A", help="Display label for side A")
    p.add_argument("--label-b", default="B", help="Display label for side B")
    p.add_argument("--top", type=int, default=25)
    p.add_argument("--pad-seconds", type=float, default=2.0)
    p.add_argument("--dropped-warn-threshold", type=int, default=100)
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    creds = load_creds()
    try:
        a = analyze_trace(
            creds,
            args.trace_a,
            pad_seconds=args.pad_seconds,
            top=max(args.top, 200),
            dropped_warn_threshold=args.dropped_warn_threshold,
        )
        b = analyze_trace(
            creds,
            args.trace_b,
            pad_seconds=args.pad_seconds,
            top=max(args.top, 200),
            dropped_warn_threshold=args.dropped_warn_threshold,
        )
    except LookupError as e:
        print(str(e), file=sys.stderr)
        return 1

    by_a = {r["name"]: r for r in a.get("all") or a["top"]}
    by_b = {r["name"]: r for r in b.get("all") or b["top"]}
    names = set(by_a) | set(by_b)

    rows = []
    for name in names:
        ra = by_a.get(name)
        rb = by_b.get(name)
        ua = ra["union_s"] if ra else 0.0
        ub = rb["union_s"] if rb else 0.0
        pa = ra["pct"] if ra else 0.0
        pb = rb["pct"] if rb else 0.0
        na = ra["n"] if ra else 0
        nb = rb["n"] if rb else 0
        pattern = (rb or ra or {}).get("pattern") or ""
        if ra and not rb:
            note = f"only in {args.label_a}"
        elif rb and not ra:
            note = f"only in {args.label_b}"
        elif ub + 0.05 < ua:
            note = f"improved on {args.label_b}"
        elif ub > ua + 0.05:
            note = f"worse on {args.label_b}"
        else:
            note = "similar"
        rows.append(
            {
                "name": name,
                "a_union_s": ua,
                "b_union_s": ub,
                "a_pct": pa,
                "b_pct": pb,
                "a_n": na,
                "b_n": nb,
                "delta_union_s": ub - ua,
                "abs_delta_union_s": abs(ub - ua),
                "pattern": pattern,
                "note": note,
            }
        )
    rows.sort(key=lambda r: r["abs_delta_union_s"], reverse=True)

    dur_a = a["transaction"]["duration_s"]
    dur_b = b["transaction"]["duration_s"]
    speedup = (dur_a / dur_b) if dur_b else None

    out = {
        "label_a": args.label_a,
        "label_b": args.label_b,
        "a": {k: v for k, v in a.items() if k != "all"},
        "b": {k: v for k, v in b.items() if k != "all"},
        "duration_a_s": dur_a,
        "duration_b_s": dur_b,
        "speedup_a_over_b": speedup,
        "rows": rows[: args.top],
    }

    if args.json:
        print(json.dumps(out, indent=2, default=str))
        return 0

    print(f"Compare: {args.label_a} vs {args.label_b}")
    print(
        f"  {args.label_a}: {dur_a:.3f}s  trace={args.trace_a}  "
        f"env={a['transaction'].get('service.environment')}  "
        f"deploy={a['transaction'].get('labels.deploymentName')}"
    )
    print(
        f"  {args.label_b}: {dur_b:.3f}s  trace={args.trace_b}  "
        f"env={b['transaction'].get('service.environment')}  "
        f"deploy={b['transaction'].get('labels.deploymentName')}"
    )
    if speedup:
        print(f"  speedup ({args.label_a}/{args.label_b}): {speedup:.2f}×")
    print()

    warn_dropped(args.label_a, a)
    warn_dropped(args.label_b, b)
    if a.get("incomplete_due_to_dropped_spans") != b.get("incomplete_due_to_dropped_spans"):
        print(
            "⚠️  Dropped-span completeness differs across sides — "
            "do not trust raw call-count comparisons."
        )
        print()

    print(
        f"{'Δunion':>8}  "
        f"{args.label_a[:6]+'_u':>8} {args.label_a[:6]+'_%':>6} {args.label_a[:6]+'_n':>6}  "
        f"{args.label_b[:6]+'_u':>8} {args.label_b[:6]+'_%':>6} {args.label_b[:6]+'_n':>6}  "
        f"{'note':<22}  name"
    )
    print("-" * 140)
    for r in rows[: args.top]:
        if r["name"] == "route handler":
            continue
        print(
            f"{r['delta_union_s']:+8.3f}  "
            f"{r['a_union_s']:8.3f} {r['a_pct']:5.1f}% {r['a_n']:6d}  "
            f"{r['b_union_s']:8.3f} {r['b_pct']:5.1f}% {r['b_n']:6d}  "
            f"{r['note']:<22}  {r['name']}"
        )

    # Top actions: prefer remaining cost on slower side
    slower_label = args.label_a if dur_a >= dur_b else args.label_b
    slower = a if dur_a >= dur_b else b
    print()
    print(f"Top remaining costs on slower side ({slower_label}):")
    shown = 0
    for r in slower.get("all") or slower["top"]:
        if r["name"] == "route handler":
            continue
        shown += 1
        print(
            f"  {shown}. {r['name']}: {r['union_s']:.3f}s ({r['pct']:.1f}%), n={r['n']}"
            + (f" [{r['pattern']}]" if r["pattern"] else "")
        )
        if shown >= 5:
            break

    print()
    print("Biggest absolute deltas:")
    shown = 0
    for r in rows:
        if r["name"] == "route handler" or r["abs_delta_union_s"] < 0.05:
            continue
        shown += 1
        print(
            f"  {shown}. {r['name']}: {args.label_a} {r['a_union_s']:.3f}s → "
            f"{args.label_b} {r['b_union_s']:.3f}s ({r['delta_union_s']:+.3f}s) — {r['note']}"
        )
        if shown >= 5:
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
