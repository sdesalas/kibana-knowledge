#!/usr/bin/env python3
"""
6-month PR-review-noise analysis for @elastic/security-detection-rule-management.

Two passes:

  1. Targeted: for each candidate path in CANDIDATES, count PRs touched and
     "PRs uniquely freed" (dropping that single line removes the team from
     review). Reports totals over 6 months and monthly averages.

  2. Discovery: for EVERY CODEOWNERS line owning the team, compute the same
     stats. Surfaces any other lines worth dropping that weren't in CANDIDATES.

Implementation note:
  Uses a CODEOWNERS-native matcher (last-match-wins, glob semantics), matching
  what `analyse_codeowners.py` does. We do NOT use the synthetic-gitignore
  trick (`git check-ignore` against a generated .gitignore) because gitignore's
  "you cannot un-ignore inside an ignored directory" rule systematically
  misattributes per-file CODEOWNERS overrides nested inside directory-owning
  lines (e.g. .gen.ts files under test-api-clients/).
"""

from __future__ import annotations
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent
CODEOWNERS = REPO / ".github" / "CODEOWNERS"
TEAM = "@elastic/security-detection-rule-management"
SINCE = "6 months ago"
MONTHS = 6.0

CANDIDATES: dict[str, str] = {
    # Tier 1 - high-value platform packages we incidentally own
    "kbn-openapi-bundler":             "src/platform/packages/shared/kbn-openapi-bundler/",
    "kbn-openapi-common":              "src/platform/packages/shared/kbn-openapi-common/",
    "kbn-openapi-generator":           "src/platform/packages/shared/kbn-openapi-generator/",
    "kbn-zod-helpers":                 "src/platform/packages/shared/kbn-zod-helpers/",
    "kbn-rule-data-utils":             "src/platform/packages/shared/kbn-rule-data-utils/",
    "kbn-change-history":              "x-pack/platform/packages/shared/kbn-change-history/",
    "kbn-securitysolution-utils":      "x-pack/solutions/security/packages/kbn-securitysolution-utils/",
    # Tier 2 - new discoveries surfaced by 6mo analysis
    "server/routes":                   "x-pack/solutions/security/plugins/security_solution/server/routes/",
    "api_integration/detections_response/utils": "x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils/",
    "common/test":                     "x-pack/solutions/security/plugins/security_solution/common/test/",
    # Tier 3 - marginal UI components
    "components/links_to_docs":        "x-pack/solutions/security/plugins/security_solution/public/common/components/links_to_docs/",
    "components/ml_popover":           "x-pack/solutions/security/plugins/security_solution/public/common/components/ml_popover/",
    "components/missing_privileges":   "x-pack/solutions/security/plugins/security_solution/public/common/components/missing_privileges/",
    "components/popover_items":        "x-pack/solutions/security/plugins/security_solution/public/common/components/popover_items/",
    # Tier 4 - debatable
    "alerting/change_tracking":        "x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/",
}


def parse_codeowners() -> list[tuple[int, str, list[str]]]:
    """Return [(line_num, pattern, teams)] for every non-empty CODEOWNERS line."""
    entries: list[tuple[int, str, list[str]]] = []
    for i, raw in enumerate(CODEOWNERS.read_text().splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            entries.append((i, "", []))
            continue
        parts = line.split()
        # Preserve trailing slash; matters semantically (dir-only vs prefix).
        pattern = parts[0]
        teams = [p for p in parts[1:] if p.startswith("@")]
        entries.append((i, pattern, teams))
    return entries


def _compile_codeowners_pattern(pattern: str) -> re.Pattern[str]:
    """Compile a CODEOWNERS pattern to a regex matching repo-relative paths.

    CODEOWNERS semantics (per GitHub docs), with the gotcha that — unlike
    gitignore — there is NO 'parent directory blocks un-ignore' rule. Last
    match always wins.

    Pattern rules used here:
      - Leading '/'              -> anchored to repo root.
      - No leading '/'           -> can match a path component anywhere.
      - Trailing '/'             -> directory; matches the dir and anything below.
      - No trailing '/' on dir   -> still matches files under it (CODEOWNERS
                                    treats `foo/bar` as "foo/bar and below").
      - '*'                      -> [^/]*
      - '**'                     -> .*
      - '?'                      -> [^/]
    """
    p = pattern
    anchored = p.startswith("/")
    if anchored:
        p = p[1:]
    trailing_slash = p.endswith("/")
    if trailing_slash:
        p = p[:-1]

    # Build regex token by token to handle ** vs *.
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

    if anchored:
        prefix = r"\A"
    else:
        prefix = r"(?:\A|/)"
    # Match the path itself OR anything below it (treating pattern as dir prefix).
    suffix = r"(?:/.*)?\Z"
    return re.compile(prefix + body + suffix)


def build_file_to_line_map(entries: list[tuple[int, str, list[str]]]) -> dict[str, int]:
    """For every tracked file, return the CODEOWNERS line number that owns it
    AND has TEAM as one of its owners. Files whose final-match line does not
    list TEAM are omitted. Implements CODEOWNERS last-match-wins semantics
    (no gitignore parent-directory shenanigans)."""
    compiled: list[tuple[int, re.Pattern[str], list[str]]] = []
    for ln, pat, teams in entries:
        if not pat:
            continue
        compiled.append((ln, _compile_codeowners_pattern(pat), teams))

    all_files = subprocess.check_output(
        ["git", "-C", str(REPO), "ls-files"], text=True
    ).splitlines()

    result: dict[str, int] = {}
    for f in all_files:
        last_ln = None
        last_teams: list[str] = []
        for ln, rx, teams in compiled:
            if rx.search(f):
                last_ln = ln
                last_teams = teams
        if last_ln is not None and TEAM in last_teams:
            result[f] = last_ln
    return result


def in_any_candidate(path: str) -> str | None:
    for name, prefix in CANDIDATES.items():
        if path.startswith(prefix):
            return name
    return None


def git_log_with_files(since: str) -> list[tuple[str, str, list[str]]]:
    out = subprocess.check_output(
        [
            "git", "log", "main",
            f"--since={since}",
            "--name-only",
            "--no-renames",
            "--pretty=format:__COMMIT__%H\t%s",
        ],
        text=True,
    )
    commits: list[tuple[str, str, list[str]]] = []
    cur_sha = ""
    cur_subj = ""
    cur_files: list[str] = []
    for line in out.splitlines():
        if line.startswith("__COMMIT__"):
            if cur_sha:
                commits.append((cur_sha, cur_subj, cur_files))
            sha_subj = line[len("__COMMIT__"):]
            cur_sha, _, cur_subj = sha_subj.partition("\t")
            cur_files = []
        elif line.strip():
            cur_files.append(line.strip())
    if cur_sha:
        commits.append((cur_sha, cur_subj, cur_files))
    return commits


def main() -> int:
    entries = parse_codeowners()
    line_to_entry = {ln: (pat, teams) for ln, pat, teams in entries}

    print(f"Loading CODEOWNERS -> file map for {TEAM} ...", file=sys.stderr)
    file_to_line = build_file_to_line_map(entries)
    print(f"  Files team-owned: {len(file_to_line)}", file=sys.stderr)

    print(f"Loading {SINCE} of commits on main ...", file=sys.stderr)
    commits = git_log_with_files(SINCE)
    print(f"  Commits: {len(commits)}", file=sys.stderr)

    # Per-PR state ---------------------------------------------------------
    # (sha, subj, team_files_touched, candidate_buckets_touched, lines_touched)
    team_touched_prs: list[tuple[str, str, set[str], set[str], set[int]]] = []
    for sha, subj, files in commits:
        team_files = [f for f in files if f in file_to_line]
        if not team_files:
            continue
        buckets: set[str] = set()
        for f in team_files:
            b = in_any_candidate(f)
            if b is not None:
                buckets.add(b)
        lines = {file_to_line[f] for f in team_files}
        team_touched_prs.append((sha, subj, set(team_files), buckets, lines))

    total_team_prs = len(team_touched_prs)
    print()
    print(f"=== {SINCE} ({MONTHS:.0f} months) ===")
    print(f"Commits on main:                                {len(commits)}")
    print(f"PRs that pinged {TEAM}: {total_team_prs}")
    print(f"  Monthly average:                              {total_team_prs / MONTHS:.1f}")
    print()

    # All-candidates aggregate --------------------------------------------
    ping_kept = 0
    ping_freed = 0
    for _sha, _subj, team_files, _b, _l in team_touched_prs:
        has_non_cand = any(in_any_candidate(f) is None for f in team_files)
        if has_non_cand:
            ping_kept += 1
        else:
            ping_freed += 1

    print(f"If ALL {len(CANDIDATES)} candidates were dropped:")
    print(f"  PRs still pinged (team-essential touched):    {ping_kept}  ({ping_kept/MONTHS:.1f}/mo)")
    print(f"  PRs no longer pinged:                         {ping_freed}  ({ping_freed/MONTHS:.1f}/mo)")
    print(f"  Review-load reduction:                        {ping_freed / max(total_team_prs,1):.1%}")
    print()

    # Per-candidate --------------------------------------------------------
    per_cand_raw = {k: 0 for k in CANDIDATES}
    per_cand_uniq = {k: 0 for k in CANDIDATES}
    for _sha, _subj, team_files, buckets, _l in team_touched_prs:
        for b in buckets:
            per_cand_raw[b] += 1
        has_non_cand = any(in_any_candidate(f) is None for f in team_files)
        if not has_non_cand and len(buckets) == 1:
            (only,) = buckets
            per_cand_uniq[only] += 1

    print("=== Per-candidate breakdown (6 months) ===")
    print(f"  {'candidate':35s} {'PRs touched':>11s} {'/mo':>5s} {'uniq freed':>12s} {'/mo':>5s}")
    for name in CANDIDATES:
        r = per_cand_raw[name]
        u = per_cand_uniq[name]
        print(f"  {name:35s} {r:>11d} {r/MONTHS:>5.1f} {u:>12d} {u/MONTHS:>5.1f}")
    print()

    # Per-candidate PR lists -----------------------------------------------
    # For each candidate, capture every PR that touched it, with a flag
    # marking whether the PR is *uniquely freed* by dropping that single line.
    per_cand_prs: dict[str, list[tuple[str, str, bool]]] = {k: [] for k in CANDIDATES}
    pr_rx = re.compile(r"\(#(\d+)\)\s*$")
    for sha, subj, team_files, buckets, _l in team_touched_prs:
        has_non_cand = any(in_any_candidate(f) is None for f in team_files)
        for b in buckets:
            uniquely = (not has_non_cand and len(buckets) == 1)
            per_cand_prs[b].append((sha, subj, uniquely))

    pr_list_path = REPO / "codeowners_pr_savings_links.md"
    with pr_list_path.open("w") as fh:
        fh.write("# PRs touched by each removal candidate (last 6 months)\n\n")
        fh.write("Generated by `analyse_pr_savings.py`. ★ marks PRs *uniquely freed* by dropping that single line (without dropping any other candidate). Unmarked rows are PRs that touched the candidate but also touched a team-essential or another-candidate path — they don't free the team's review by themselves.\n\n")
        for name in CANDIDATES:
            prs = per_cand_prs[name]
            fh.write(f"## `{name}` (line {next((ln for ln, (pat, teams) in line_to_entry.items() if pat and CANDIDATES[name].rstrip('/').endswith(pat.lstrip('/').rstrip('/')) ), '?')})\n\n")
            if not prs:
                fh.write("_No PRs touched this path in the last 6 months._\n\n")
                continue
            seen: set[str] = set()
            for sha, subj, uniquely in prs:
                if sha in seen:
                    continue
                seen.add(sha)
                m = pr_rx.search(subj)
                if m:
                    pr_num = m.group(1)
                    clean_subj = pr_rx.sub("", subj).strip()
                    star = "★ " if uniquely else "  "
                    fh.write(f"- {star}[#{pr_num}](https://github.com/elastic/kibana/pull/{pr_num}) — {clean_subj}\n")
                else:
                    star = "★ " if uniquely else "  "
                    fh.write(f"- {star}`{sha[:9]}` — {subj}\n")
            fh.write("\n")
    print(f"Wrote per-candidate PR lists -> {pr_list_path.relative_to(REPO)}", file=sys.stderr)
    print()

    # Discovery: every team-owned CODEOWNERS line --------------------------
    line_raw: dict[int, int] = {}
    line_uniq: dict[int, int] = {}
    for _sha, _subj, team_files, _b, lines_touched in team_touched_prs:
        for ln in lines_touched:
            line_raw[ln] = line_raw.get(ln, 0) + 1
        # "Line uniquely freed" = this is the only CODEOWNERS line that pinged the
        # team for this PR. Dropping that single line takes us out of review.
        if len(lines_touched) == 1:
            (only_line,) = lines_touched
            line_uniq[only_line] = line_uniq.get(only_line, 0) + 1

    # Identify the lines already in CANDIDATES so we can filter for NEW finds.
    candidate_lines: set[int] = set()
    for ln, (pat, teams) in line_to_entry.items():
        if not pat or TEAM not in teams:
            continue
        norm = pat.lstrip("/")
        for prefix in CANDIDATES.values():
            if norm == prefix.rstrip("/") or norm.startswith(prefix):
                candidate_lines.add(ln)
                break

    print("=== Discovery: team-owned CODEOWNERS lines by review noise (6 months) ===")
    print("(Sorted by 'uniquely freed' PRs. Lines already in CANDIDATES are tagged [C].)")
    print(f"  {'line':>5s}  {'PRs':>4s} {'uniq':>4s}  pattern")
    ranked = sorted(line_uniq.items(), key=lambda kv: -kv[1])
    for ln, uniq in ranked:
        if uniq == 0:
            continue
        pat, teams = line_to_entry[ln]
        tag = "[C]" if ln in candidate_lines else "   "
        teamstr = " ".join(teams)
        print(f"  {ln:>5d} {tag} {line_raw.get(ln,0):>4d} {uniq:>4d}  {pat}  ({teamstr})")
    print()

    # Show top "PRs touched" entries with 0 uniquely-freed (shared in PRs
    # together with core team code) for completeness.
    print("=== Lines with PR touches but 0 uniquely freed (still useful context) ===")
    print(f"  {'line':>5s}  {'PRs':>4s} {'uniq':>4s}  pattern")
    for ln, raw in sorted(line_raw.items(), key=lambda kv: -kv[1]):
        if line_uniq.get(ln, 0) > 0:
            continue
        if raw < 3:
            continue
        pat, teams = line_to_entry[ln]
        tag = "[C]" if ln in candidate_lines else "   "
        teamstr = " ".join(teams)
        print(f"  {ln:>5d} {tag} {raw:>4d} {0:>4d}  {pat}  ({teamstr})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
