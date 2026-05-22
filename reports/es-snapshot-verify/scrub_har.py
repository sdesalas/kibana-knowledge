#!/usr/bin/env python3
"""
Scrub a mitmproxy HAR file before publishing.

Scrubbing rules (per agreed configuration):
  * Authorization headers (request + response) -> value replaced with "REDACTED",
    header itself preserved so the structure of the capture remains intact.
  * traceparent and tracestate headers (request + response) -> removed entirely.
  * Everything else (x-opaque-id, UUIDs, timestamps, IPs, user-agent, hosts, ...)
    is left untouched.

Reads the input HAR with stdlib json (loads the full document into memory; a
283 MB HAR will peak around ~2 GB of RAM, which is fine on a workstation).
Writes a new file alongside the original. The original is never modified.

Usage:
    python3 scrub_har.py <input.har> [<output.har>]

If <output.har> is omitted, the output is written next to the input with a
".scrubbed.har" suffix (e.g. may11.har -> may11.scrubbed.har).
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

REDACT_VALUE_HEADERS = {"authorization"}
REMOVE_HEADERS = {"traceparent", "tracestate"}


def scrub_headers(headers: list[dict], stats: Counter) -> list[dict]:
    """Return a new header list with the configured scrubbing rules applied."""
    out: list[dict] = []
    for header in headers:
        name = header.get("name", "")
        lname = name.lower()
        if lname in REMOVE_HEADERS:
            stats[f"removed:{lname}"] += 1
            continue
        if lname in REDACT_VALUE_HEADERS:
            stats[f"redacted:{lname}"] += 1
            out.append({**header, "value": "REDACTED"})
            continue
        out.append(header)
    return out


def scrub_entry(entry: dict, stats: Counter) -> None:
    """Mutate a single HAR log entry in place."""
    request = entry.get("request")
    if isinstance(request, dict) and isinstance(request.get("headers"), list):
        request["headers"] = scrub_headers(request["headers"], stats)

    response = entry.get("response")
    if isinstance(response, dict) and isinstance(response.get("headers"), list):
        response["headers"] = scrub_headers(response["headers"], stats)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or len(argv) > 3 or argv[1] in {"-h", "--help"}:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    in_path = Path(argv[1])
    if not in_path.is_file():
        print(f"error: input file not found: {in_path}", file=sys.stderr)
        return 1

    if len(argv) == 3:
        out_path = Path(argv[2])
    else:
        out_path = in_path.with_name(in_path.stem + ".scrubbed.har")

    if out_path.resolve() == in_path.resolve():
        print("error: refusing to overwrite the input file", file=sys.stderr)
        return 1

    in_size = in_path.stat().st_size
    print(f"reading  {in_path}  ({in_size / 1_000_000:.1f} MB) ...", file=sys.stderr)
    with in_path.open("r", encoding="utf-8") as fh:
        har = json.load(fh)

    entries = har.get("log", {}).get("entries", [])
    if not isinstance(entries, list):
        print("error: HAR has no log.entries array", file=sys.stderr)
        return 1

    stats: Counter = Counter()
    for entry in entries:
        scrub_entry(entry, stats)

    print(f"writing  {out_path} ...", file=sys.stderr)
    with out_path.open("w", encoding="utf-8") as fh:
        json.dump(har, fh, ensure_ascii=False, indent=4)

    out_size = out_path.stat().st_size
    print(file=sys.stderr)
    print(f"entries processed: {len(entries)}", file=sys.stderr)
    if stats:
        print("changes:", file=sys.stderr)
        for key in sorted(stats):
            print(f"  {key:30s} {stats[key]:>8d}", file=sys.stderr)
    else:
        print("no headers matched the scrubbing rules", file=sys.stderr)
    print(file=sys.stderr)
    print(
        f"input:  {in_size / 1_000_000:>9.1f} MB",
        file=sys.stderr,
    )
    print(
        f"output: {out_size / 1_000_000:>9.1f} MB",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
