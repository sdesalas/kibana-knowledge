---
description: Find which team owns files (or the files in a PR/branch) per .github/CODEOWNERS.
alwaysApply: false
---

# CODEOWNERS lookup

To find owners of files, a PR or the current branch, use the bundled script instead of reading `.github/CODEOWNERS` by hand. It is dependency-free, run it from inside a Kibana checkout.

```
node ~/.claude/rules/codeowners/codeowners.js <file...>        # owners + matching CODEOWNERS line per file
node ~/.claude/rules/codeowners/codeowners.js --pr <number>    # PR files grouped by team
node ~/.claude/rules/codeowners/codeowners.js --branch         # HEAD vs upstream/main grouped by team
git diff --name-only | node ~/.claude/rules/codeowners/codeowners.js -
```

Add `--by-file` / `--by-team` to force a view, `--json` for machine output.

Semantics: the last matching rule wins. A rule with no owners marks a file unowned. Inline `# comments` after owners are ignored. `--pr` also checks a renamed file's previous path. CODEOWNERS is read from the local checkout, so it may differ from the PR's base branch.
