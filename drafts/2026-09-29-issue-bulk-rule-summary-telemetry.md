## Summary

Prebuilt rule installation (`installation/_perform`) and rule import (`rules/_import`) send one EBT event per rule: `detection_rule_install` and `detection_rule_import`. A full prebuilt install is ~2.1K events, and a single import can be up to 10K (`maxRuleImportExportSize`).

That doesn't scale well with the server-side shipper (`ElasticV3ServerShipper` in `@elastic/ebt`):

- It has a single in-memory queue capped at **10K events**, shared by every server-side EBT event on the `kibana-server` channel, not just ours.
- It drains slowly: ~10KB every 10s. Each rule event is ~1KB once context is attached, so that's roughly 1 event per second.
- A full prebuilt install takes **~35 min** to leave Kibana. A 10K import takes **~2h45m**.
- A max-size import fills the queue by itself. Anything past 10K is dropped (`queue_full`), including other teams' events, for as long as the queue stays full.
- Back-to-back bulk operations (e.g. installing all prebuilt rules in several spaces) can also overflow.

This came up in review of #293496, which restores per-rule install telemetry.

## Proposal

Send one summary event per bulk call, then retire the per-rule events. Two PRs, a few weeks apart:

1. **Add summary events.** Register `detection_rule_install_summary` and `detection_rule_import_summary`, sent once per `installation/_perform` / `rules/_import` call. Keep sending the per-rule events for now, so dashboards can move over.
2. **Retire per-rule events.** Once summary data is flowing and dashboards are updated, stop sending `detection_rule_install` and `detection_rule_import`.

We use new event names instead of changing the existing schemas, so historical data under the old names stays consistent.

There's a precedent already: prebuilt rule upgrade sends a `detection_rule_bulk_upgrade` summary alongside the per-rule `detection_rule_upgrade` events (see `update_rule_telemetry.ts`).

### Payload (to be agreed)

Counts only, no per-rule IDs. Rough idea:

- Totals: succeeded, failed
- Breakdown by rule type (query, eql, esql, threshold, ...)
- Import only: how many were prebuilt, customized prebuilt, and custom

## Open questions

- Which dashboards or queries use `detection_rule_install` / `detection_rule_import` today? We need their owners on board before step 2.
- Do we lose anything we care about without per-rule `ruleId` (e.g. which prebuilt rules get installed most)? Can we get that from other telemetry instead?
- Prebuilt rule upgrade has the same per-rule scaling issue with `detection_rule_upgrade`. Out of scope here, but worth a follow-up.

## Acceptance criteria

- [ ] `detection_rule_install_summary` and `detection_rule_import_summary` registered in `events.ts`
- [ ] Each is sent once per bulk call; nothing is sent when the call installs/imports nothing
- [ ] Unit and API integration tests cover the new events
- [ ] Follow-up PR removes the per-rule `detection_rule_install` and `detection_rule_import` events once dashboards have moved

## References

- #289600: missing telemetry on bulk prebuilt rule installation
- #293496: restores per-rule install telemetry
