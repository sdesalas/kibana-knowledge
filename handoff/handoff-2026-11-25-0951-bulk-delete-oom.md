# Handoff: Fix bulk rule delete OOM on 1 GB ECH (#304647)

## Context
Steven de Salas (Detection Engineering, Elastic) is picking up Focus task #2: [#304647](https://github.com/elastic/kibana/issues/304647). `POST /api/detection_engine/rules/_bulk_action` with `action: delete` takes Kibana down with a heap OOM at ~4,000+ rules on a 1 GB ECH deployment. It is a production bug (`impact:high`, `9.7 candidate`), filed under phase 2 [#298327](https://github.com/elastic/kibana/issues/298327) and epic [#264906](https://github.com/elastic/kibana/issues/264906). The issue is currently unassigned.

## Current state
- Repro (from 2026-11-11, build `main-at-545231e`): install ~2,200 prebuilt rules, duplicate all to ~4,400, bulk delete everything.
- Suspected root cause: full rules held in heap at once and not batched tightly. Code paths: Security `_bulk_action` route, `DetectionRulesClient`, Alerting `bulk_delete_rules.ts` (and `retryIfBulkOperationConflicts`).
- Bar for done: same repro doesn't OOM.
- A lean bulk delete plan exists as a sample. Steven judged a full rewrite of Alerting's bulk delete not worth it, so prefer capping the working set and dropping redundant copies over a rewrite.
- No code or PR yet. Manager hasn't answered on priority (Steven flagged it 11-23). Steven targets 9.7.
- Steven is on PTO soon, there are ~ 3 working days left.

## Next session focus
1. Read the route handler and the delete path (`bulk_delete_rules.ts`, `DetectionRulesClient` delete) and map where full rule objects are retained per batch.
2. Propose the smallest fix: batch delete in tight chunks and fetch only the fields needed (ids, API key info, actions).
3. Ask Steven to confirm the approach before editing. His global rule: don't change or commit code unless asked.
4. For validating, use QAF (1 GB ECH) with the 4,400-rule repro.

## Artifacts
- Issue: https://github.com/elastic/kibana/issues/304647
- Draft: https://github.com/sdesalas/kibana-knowledge/blob/main/issues/2026-11-11.bulk-delete-oom-1gb.md
- Plan: https://github.com/sdesalas/kibana-knowledge/blob/main/plans/2026-11-10.lean-bulk-delete.plan.md
- Closed audit: https://github.com/elastic/kibana/issues/298304
- Log: /Users/sdesalas/taskmanager/log/2026-11-11.md (section "Bulk delete OOM issue")
- Related memory-fix precedent: ~/Code/sdesalas/kibana-knowledge/reports/2026-09-15.avoiding-oom-in-the-detection-rules-import-with-compressed-memory-stream.md
- QAF skill: https://github.com/sdesalas/kibana-knowledge/blob/main/skills/qaf/SKILL.md
