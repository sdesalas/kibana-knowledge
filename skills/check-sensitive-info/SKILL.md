---
name: check-sensitive-info
description: Scan the current git repo for sensitive data (credentials, keys, tokens) and "odd" public exposures (internal links, team info, incident data). Run with `/check-sensitive-info`. Don't run unless prompted to do so.
---

# Check sensitive info — Repo Sensitive Data Scanner

Scan the current repository for:

1. **Actual secrets** — API keys, tokens, passwords, private keys, credentials
2. **Internal system links** — Slack channels, PagerDuty, Rootly, Google Docs/Drive with sensitive content, internal dashboards
3. **Team member info** — Email addresses, names, roles in sensitive contexts
4. **Incident/operational data** — Raw Slack dumps, RCA documents, internal postmortems
5. **Configuration leaks** — credentials in URLs, auth tokens in env examples

## When to run

- Only when user requests it.

## What it checks

### Secrets (HIGH RISK)
- API keys, bearer tokens, JWT patterns
- Private keys (PEM, RSA, certificates)
- Passwords in plaintext
- Base64-encoded credentials
- AWS access keys, Elastic Cloud tokens

### Internal exposures (MEDIUM RISK)
- Slack permalinks to internal channels
- PagerDuty, Rootly incident links
- Google Docs/Drive links to internal RCAs, investigation notes
- Internal dashboards (overview.elastic-cloud.com, vault-ci-prod, etc.)
- Email addresses in sensitive contexts

### Team/operational data (LOW-MEDIUM RISK)
- Raw Slack JSON dumps or exports
- Incident channel archives
- Internal epic/ticket numbers
- Team member names paired with roles/decisions
- Zoom recordings with access codes

### Configuration (MEDIUM RISK)
- Credentials in URLs (password=, token=, key=)
- Database connection strings with passwords
- SSH config with hostnames/users
- API endpoint examples with auth baked in

## How it works

The audit script:

1. **Scans all tracked files** in git (excludes `.git/`, node_modules, etc.)
2. **Groups findings by risk level** (HIGH, MEDIUM, LOW)
3. **Reports filenames, line numbers, and context** so you can review quickly
4. **Suggests remediation** (delete, redact, move to `.gitignore`, rotate credentials)

## During usage

```bash
check-sensitive-info.sh
```

Output is a categorized report:
- **HIGH RISK findings** (credentials, secrets) — these must be handled
- **MEDIUM RISK findings** (internal links, team data) — consider redacting
- **LOW RISK findings** (naming conventions, other odd exposures) — for awareness

Findings that require authentication to access (Slack, Google Docs) show lower risk, but are still worth reviewing.

Please process script output and research each result further to find out if its genuine or a false positive. Do not skip this step. Note that files in .gitignore are unlikely to be committed.

Once you complete your research, show list the number of files affected in a table of categories such as the one below. Discard false positives.

## Common findings and fixes

| Finding | Risk | Fix |
|---------|------|-----|
| Internal Slack permalinks | LOW | Usually fine; they're gated by Elastic authentication. If sensitive, delete or summarize. |
| Google Docs RCA links | MEDIUM | These point to sensitive postmortems. Move to private wiki or delete from public repo. |
| PagerDuty/Rootly incident links | MEDIUM | These leak incident IDs and timeline. Delete from public repo. |
| Team member emails | LOW-MEDIUM | Public Elastic employees are searchable; usually fine. Remove if in sensitive context (SLA, internal decisions). |
| Raw Slack dumps (JSON) | MEDIUM | Archives can reveal internal discussions. Move to private storage or delete. |
| Epic/ticket numbers | LOW | Internal tracker IDs; low risk if tracker is private, but unusual for public repos. |
| API credentials in examples | HIGH | Must rotate and remove. Use placeholder values instead. |

## If you find HIGH RISK items

Let the user know.

## Notes

- The scan ignores `.gitignore`d files and untracked changes (only scans what `git ls-files` would commit).
- Some false positives are expected (e.g., "password" in detection rule descriptions, test data). Manually review HIGH RISK findings.
- This is a pattern-based scan, not a cryptographic secret scanner. It will not catch every type of credential, especially if obfuscated.

## Related

- `.gitignore` — exclude files before they're tracked
- `git filter-repo` — rewrite history to remove a file from all commits (nuclear option)
- Elastic Vault / HashiCorp Vault — for managing real secrets outside git
