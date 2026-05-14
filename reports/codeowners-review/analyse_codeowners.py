#!/usr/bin/env python3
"""
analyse_codeowners.py

Print every tracked file in the repo that is owned by a given CODEOWNERS team.
Run from the Kibana repo root.

Usage:
  ./analyse_codeowners.py [team-handle]

Defaults to @elastic/security-detection-rule-management.

Output:
  stdout: one owned path per line
  stderr: summary (fully-owned vs shared)

Uses a CODEOWNERS-native matcher with last-match-wins semantics. Unlike a
synthetic .gitignore + `git check-ignore` approach, this honours per-file
overrides inside owned directories — gitignore's "you cannot un-ignore inside
an ignored directory" rule does NOT apply to CODEOWNERS, so any tool that
reuses gitignore semantics will mis-attribute files like
`<team-owned-dir>/<other-team-owned-file>` to the directory's team.
"""

from __future__ import annotations
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_TEAM = "@elastic/security-detection-rule-management"


def parse_codeowners(path: Path) -> list[tuple[str, list[str]]]:
    """Return [(pattern, teams)] for every non-empty CODEOWNERS line."""
    entries: list[tuple[str, list[str]]] = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        pattern = parts[0]
        teams = [p for p in parts[1:] if p.startswith("@")]
        entries.append((pattern, teams))
    return entries


def compile_pattern(pattern: str) -> re.Pattern[str]:
    """Compile a CODEOWNERS glob to a regex matching repo-relative paths.

    Honours:
      - leading '/'  -> anchor to repo root
      - trailing '/' -> directory (and everything below)
      - '*'          -> [^/]*
      - '**'         -> .*
      - '?'          -> [^/]
      - everything else is escaped
    Last-match-wins is applied by the caller.
    """
    p = pattern
    anchored = p.startswith("/")
    if anchored:
        p = p[1:]
    if p.endswith("/"):
        p = p[:-1]

    out: list[str] = []
    i = 0
    while i < len(p):
        ch = p[i]
        if ch == "*":
            if i + 1 < len(p) and p[i + 1] == "*":
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif ch == "?":
            out.append("[^/]")
            i += 1
        elif ch in r".^$+(){}|\\":
            out.append("\\" + ch)
            i += 1
        else:
            out.append(re.escape(ch))
            i += 1
    body = "".join(out)
    prefix = r"\A" if anchored else r"(?:\A|/)"
    suffix = r"(?:/.*)?\Z"
    return re.compile(prefix + body + suffix)


def find_repo_root() -> Path:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
        return Path(out)
    except subprocess.CalledProcessError:
        print("Not inside a git repo.", file=sys.stderr)
        print("Please run this script from the Kibana repo root.", file=sys.stderr)
        sys.exit(1)


def main(argv: list[str]) -> int:
    team = argv[1] if len(argv) > 1 else DEFAULT_TEAM

    repo_root = find_repo_root()
    codeowners_path = repo_root / ".github" / "CODEOWNERS"
    if not codeowners_path.is_file():
        print(f"CODEOWNERS not found at {codeowners_path}", file=sys.stderr)
        print("Please run this script from the Kibana repo root.", file=sys.stderr)
        return 1

    entries = parse_codeowners(codeowners_path)
    compiled = [(compile_pattern(pat), teams) for pat, teams in entries]

    all_files = subprocess.check_output(
        ["git", "-C", str(repo_root), "ls-files"], text=True
    ).splitlines()

    fully = 0
    shared = 0
    for f in all_files:
        last_teams: list[str] | None = None
        for rx, teams in compiled:
            if rx.search(f):
                last_teams = teams
        if last_teams is None or team not in last_teams:
            continue
        print(f)
        if len(last_teams) == 1:
            fully += 1
        else:
            shared += 1

    print(file=sys.stderr)
    print(f"--- CODEOWNERS summary for {team} ---", file=sys.stderr)
    print(f"Fully owned (only this team): {fully}", file=sys.stderr)
    print(f"Shared with other teams:      {shared}", file=sys.stderr)
    print(f"Total owned:                  {fully + shared}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
