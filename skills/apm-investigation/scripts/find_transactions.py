#!/usr/bin/env python3
"""List APM transaction candidates for an endpoint + time window."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from es_api import esql, esql_rows, load_creds  # noqa: E402


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def env_filter_clause(value: str) -> str:
    """Match service.environment OR labels.deploymentName."""
    v = esc(value)
    return (
        f'| WHERE service.environment == "{v}" OR labels.deploymentName == "{v}"'
    )


def run_query(
    creds: dict,
    *,
    path: str,
    time_from: str,
    time_to: str,
    env: str,
    host: str,
    limit: int,
) -> list[dict]:
    idx = creds.get("APM_INDEX") or "traces-apm*"
    path_e = esc(path)
    filters = [
        f'| WHERE @timestamp >= "{time_from}" AND @timestamp <= "{time_to}"',
        '| WHERE processor.event == "transaction"',
        f'| WHERE url.path LIKE "*{path_e}*" OR transaction.name LIKE "*{path_e}*"',
    ]
    if env:
        filters.append(env_filter_clause(env))
    if host:
        filters.append(f'| WHERE host.hostname == "{esc(host)}"')

    query = f"""FROM {idx}
{chr(10).join(filters)}
| KEEP @timestamp, transaction.name, transaction.duration.us, trace.id, url.path, service.environment, labels.deploymentName, host.hostname, transaction.span_count.started, transaction.span_count.dropped
| SORT transaction.duration.us DESC
| LIMIT {limit}"""
    return esql_rows(esql(creds, query))


def print_rows(rows: list[dict], heading: str | None = None) -> None:
    if heading:
        print(f"\n=== {heading} ===")
    if not rows:
        print("No matching transactions.")
        return
    print(
        f"{'duration_s':>10}  {'started':>7}  {'dropped':>7}  {'@timestamp':<28}  transaction.name"
    )
    print("-" * 110)
    for r in rows:
        dur = (r.get("transaction.duration.us") or 0) / 1e6
        started = r.get("transaction.span_count.started")
        dropped = r.get("transaction.span_count.dropped")
        warn = " 🚨" if isinstance(dropped, (int, float)) and dropped and dropped > 100 else ""
        print(
            f"{dur:10.3f}  {str(started):>7}  {str(dropped):>7}{warn}  "
            f"{str(r.get('@timestamp')):<28}  {r.get('transaction.name')}"
        )
        print(f"{'':>10}  {'':>7}  {'':>7}   path={r.get('url.path')}")
        print(
            f"{'':>10}  {'':>7}  {'':>7}   trace.id={r.get('trace.id')}  "
            f"env={r.get('service.environment')}  deploy={r.get('labels.deploymentName')}  "
            f"host={r.get('host.hostname')}"
        )


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--path", required=True, help='URL path fragment, e.g. "rules/_import"')
    p.add_argument("--from", dest="time_from", required=True, help="Start ISO8601")
    p.add_argument("--to", dest="time_to", required=True, help="End ISO8601")
    p.add_argument(
        "--environment",
        default="",
        help="Single env filter (service.environment or labels.deploymentName)",
    )
    p.add_argument(
        "--env-a",
        default="",
        help="Compare side A env (service.environment or labels.deploymentName).",
    )
    p.add_argument(
        "--env-b",
        default="",
        help="Compare side B env (service.environment or labels.deploymentName).",
    )
    p.add_argument("--hostname", default="", help="Optional host.hostname filter")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    creds = load_creds()
    host = args.hostname or ""
    env_a = args.env_a or ""
    env_b = args.env_b or ""
    single_env = args.environment or ""

    if env_a or env_b:
        if not env_a or not env_b:
            print("Both --env-a and --env-b are required for compare discover.", file=sys.stderr)
            return 2
        rows_a = run_query(
            creds,
            path=args.path,
            time_from=args.time_from,
            time_to=args.time_to,
            env=env_a,
            host=host,
            limit=args.limit,
        )
        rows_b = run_query(
            creds,
            path=args.path,
            time_from=args.time_from,
            time_to=args.time_to,
            env=env_b,
            host=host,
            limit=args.limit,
        )
        if args.json:
            print(json.dumps({"a": {"env": env_a, "rows": rows_a}, "b": {"env": env_b, "rows": rows_b}}, indent=2))
            return 0
        print(f"Discover compare: path~{args.path}  {args.time_from} .. {args.time_to}")
        print_rows(rows_a, f"A = {env_a}")
        print_rows(rows_b, f"B = {env_b}")
        print("\nPick one trace.id per side (same scenario), then:")
        print(
            "  compare_traces.py --trace-a <id> --trace-b <id> "
            f"--label-a '{env_a}' --label-b '{env_b}'"
        )
        return 0

    rows = run_query(
        creds,
        path=args.path,
        time_from=args.time_from,
        time_to=args.time_to,
        env=single_env,
        host=host,
        limit=args.limit,
    )
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print("No matching transactions.")
        print(f"Query window: {args.time_from} .. {args.time_to} path~{args.path}")
        return 0
    print_rows(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
