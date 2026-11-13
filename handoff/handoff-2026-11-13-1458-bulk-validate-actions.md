# Handoff — #273680 `bulkValidateActions` (quick)

## Context
Steven de Salas (Senior Eng, Detection Engineering, Kibana monorepo) is working the Bulk Primitives epic (#264906). Issue #273680 (Alerting): bulk rule operations call `validateActions()` per rule, so ~1,000 rules cause ~2,000 redundant `POST /_mget` connector lookups. Focus #3 in his task list, behind #304647 (bulk-delete OOM) and #304858 (in review).

## Decision / Current state
- Audit agreement (Georgii, Yara, 2026-11-06) ranks it Priority #2: about 7–13s / 19–40% on connector scenarios (#9, #12); medium complexity because it needs a bulk validate path in Alerting.
- Per-rule lookups come from three call sites in `prepareRule`: `validateActions`, `validateAndAuthorizeSystemActions`, `denormalizeActions` (via `extractReferences`). Each calls `actionsClient.getBulk` and `listTypes`.
- `listTypes()` is identical for every rule. `getBulk()` repeats the same connector IDs across rules.
- Issue is unassigned; no code or branch started.
- Caution from #304858: wall clock did not follow span counts (parallel calls overlap). Benchmark wall clock, not just span counts, before claiming gains.

## Next session focus
- Read `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/validate_actions.ts`, `.../lib/validate_authorize_system_actions.ts` and `.../rules_client/lib/denormalize_actions.ts`.
- Check how `bulkCreateRules` (#269340) runs `prepareRule` (pMap, concurrency 50) and where a single up-front `getBulk` (union of connector IDs) plus one `listTypes` could be shared.
- Propose a design: a `bulkValidateActions` that takes the preloaded connector map and types, with per-rule validation done in memory.
- Share the design with Steven before implementing. Scope and design agreement early is feedback from his Impact Connection.
- Verify with the dual-stack ECH wall bench (scenarios 9 and 12) and `guides/detection_rule_wall_bench.md`.

## Artifacts
- Issue: https://github.com/elastic/kibana/issues/273680
- Audit agreement: https://github.com/elastic/kibana/issues/264906#issuecomment-6688284635
- Wall bench guide: /Users/sdesalas/Code/sdesalas/kibana-knowledge/guides/detection_rule_wall_bench.md
- Latest bench summaries: /Users/sdesalas/Code/sdesalas/kibana-knowledge/benchmarks/published/2026-11-12T0852.full-bench-main5452-vs-pr304858-r3/SUMMARY.md
- APM investigation skill: /Users/sdesalas/Code/sdesalas/kibana-knowledge/skills/apm-investigation/SKILL.md
