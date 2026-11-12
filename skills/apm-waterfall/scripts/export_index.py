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
