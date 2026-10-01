# Handoff — 2026-09-25 13:39 — prebuilt-install-telemetry

## Context

Steven (Detection Engineering, Elastic) is opening a PR today to restore missing `detection_rule_install` telemetry on the `installation/_perform` route. The event was dropped when the route was rewired to `rulesClient.bulkCreateRules()` in #275523.

## Conclusions

- `detection_rule_install` telemetry was fired from `DetectionRulesClient.createPrebuiltRule()` (line 145 of `detection_rules_client.ts`). That method is no longer called after #275523 wired the route to `bulkCreateRules()`.
- The installation handler (`perform_rule_installation_handler.ts`) has **no telemetry call at all** — confirmed by grep.
- `sendRuleLifecycleTelemetryEvent` + `DETECTION_RULE_INSTALL_EVENT` live in `rule_lifecycle_telemetry.ts` and are still used for revert/update paths.
- Issue notes the same gap applies to `rules/_import` via #275695 — `bulkCreateRules()` returns `{ id, rule_id, version }`, not full rule objects, so telemetry needs to be fired from the handler using those results.

## Current state

- [Issue #289600](https://github.com/elastic/kibana/issues/289600) open, assigned to Steven, no PR yet.
- No owner had been assigned before today; Reinaldo was flagged but never confirmed.
- PR is planned for today (2026-09-25).

## Next session focus

Open a PR fixing `perform_rule_installation_handler.ts` to emit `detection_rule_install` for each successfully installed rule. The handler already has the installed rules list — call `sendRuleLifecycleTelemetryEvent(analytics, DETECTION_RULE_INSTALL_EVENT, rule, logger)` for each. Failures and skipped rules must not emit.

Key files:
- Handler: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts`
- Telemetry helper: `...rule_management/logic/detection_rules_client/rule_lifecycle_telemetry.ts`
- Event def: `...server/lib/telemetry/event_based/events.ts`

## Artifacts

- [Issue #289600](https://github.com/elastic/kibana/issues/289600)
- Related: [#264907](https://github.com/elastic/kibana/issues/264907), [#275523](https://github.com/elastic/kibana/pull/275523)
