# Handoff — Modify no-op semantics during `rules/_import`

**Date:** 2026-09-28  **Repo:** `elastic/kibana`  **Issue:** [#285343](https://github.com/elastic/kibana/issues/285343)

---

## Context

Steven de Salas (Senior Engineer, Detection Engineering, Elastic) is implementing performance improvements to the `rules/_import` endpoint. The no-op semantics change is a follow-on PR to the update-path wiring ([#291560](https://github.com/elastic/kibana/pull/291560)), targeting a ~10–20× import speedup for deployments that repeatedly import largely-unchanged rule sets (e.g. ConnectWise imports 720 rule sets across spaces daily, ~300 rules actually change).

---

## Decision (confirmed 2026-09-28)

- **Treat no-op skipping as a bug fix** — no opt-in flag.
- Signoff: Yara, Kseniia, Georgii, Alerting team (Mike Cote Aug 2026). [DEX thread](https://elastic.slack.com/archives/C09S1NKF8HX/p1790252224328919)
- Prior concern (API-key rotation / TM self-healing) ruled theoretical — no SDH evidence it occurs in practice.

---

## Current state

- #291560 is **open for review** (Antonio approved, Devin Hurley reviewing). No-op PR must wait for this to merge or stack on top.
- No implementation started yet. Implementation belongs in the Detection Rules import update path, after existing rules are fetched, filtering unchanged ones before `bulkUpdateRules()` is called.
- Backport to 9.5 is a **separate open question** (Kseniia + Georgii input still needed).

---

## Next session focus

Implement the no-op filter in the `rules/_import` update path:

1. After fetching existing rules (already done in #291560 wiring), compare inbound rule payload against stored rule.
2. Filter out rules where no fields differ — exclude from the `bulkUpdateRules()` call.
3. Return skipped rules in the response (alongside `updated` and `errors`).
4. Open a dedicated PR stacked on or after #291560.

Key file area: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/`  — follow the pattern established in #291560.

---

## Artifacts

- [Issue #285343](https://github.com/elastic/kibana/issues/285343) — tracking issue with research comments
- [PR #291560](https://github.com/elastic/kibana/pull/291560) — update-path wiring (must merge first)
- [Feasibility comment](https://github.com/elastic/kibana/issues/285343#issuecomment-5617429413) — Steven's Sep 10 options analysis
- [DEX thread](https://elastic.slack.com/archives/C09S1NKF8HX/p1790252224328919) — final decision thread
- `~/taskmanager/tasks.md` — task tracker (Focus section, #285343 entry)
