# Usage notes: `bulkEnsureAuthorized` for Detection callers

Companion to [detection-rules-architecture.md](./detection-rules-architecture.md)
§Q (`consumer`) and `RulesClient.bulkUpdateRules`
([#286508](https://github.com/elastic/kibana/pull/286508)).

---

## What the check does

`bulkEnsureAuthorized({ operation, entity: Rule })` asks Kibana for every
`(ruleTypeId, consumer)` pair in the list. One miss throws
`Boom.forbidden`. There is no per-item authz result.

`bulkUpdateRules` runs that check **per inner batch**, on pairs taken
from the **loaded** SOs (not from the incoming payload). Same helper
as `bulkCreateRules`, `bulkEdit`, and single `updateRule` /
`ensureAuthorized`.

A unit test in `bulk_update_rules.test.ts` stubs the second batch as
unauthorized so the throw-after-write path is covered. That fixture is
not a Detection role.

`ensureAuthorized` is a one-pair wrapper over the same private
`_ensureAuthorized`. Single-rule methods (`updateRule`, `createRule`,
`getRule`, …) use that, not the `bulkEnsureAuthorized` name.

---

## Call sites

Eleven production calls of `authorization.bulkEnsureAuthorized`.
Paths under `x-pack/platform/plugins/shared/`.

### Rule writes (pairs from the rules being written)

| File | Caller | When / pairs |
| --- | --- | --- |
| `alerting/.../bulk_update/bulk_update_rules.ts` | `bulkUpdateRules` | Per inner batch, from loaded SOs. `WriteOperations.Update`. |
| `alerting/.../bulk_create/bulk_create_rules.ts` | `bulkCreateRules` | Once in `preValidate`, after schema/registry, before any write. `WriteOperations.Create`. |
| `alerting/.../lib/check_authorization_and_get_total.ts` | `bulkEdit`, `bulkEnable`, `bulkDisable`, `bulkDelete`, `bulkGet` | Once from a terms agg on the filter. Operation is Enable / Disable / BulkDelete / BulkEdit / Get. |

### Alerts (entity is `Alert`, not `Rule`)

| File | Caller | When / pairs |
| --- | --- | --- |
| `alerting/.../bulk_mute_unmute_alerts/bulk_mute_unmute_instances.ts` | mute / unmute instances | Pairs from the rules that own the instances. |
| `alerting/.../bulk_untrack/bulk_untrack_alerts.ts` | `bulkUntrackAlerts` | Passed into `setAlertsToUntracked`, which collects pairs from the alert docs then calls once. |
| `rule_registry/.../alert_data_client/alerts_client.ts` | `bulkEnsureAuthorizedAndAuditLog` | Alert reads/updates in the RAC client. |

### Backfill and gap auto-fill (pairs from the request or scheduler SO)

| File | Caller | When / pairs |
| --- | --- | --- |
| `alerting/.../backfill/methods/schedule/schedule_backfill.ts` | `scheduleBackfill` | Unique `(ruleTypeId, consumer)` from the selected rules. `WriteOperations.ScheduleBackfill`. |
| `alerting/.../gaps/.../get_gaps_summary_by_rule_ids.ts` | gaps summary | Pairs from the requested rule ids. |
| `alerting/.../gaps/.../create/create_gap_auto_fill_scheduler.ts` | create scheduler | `params.ruleTypes`. |
| `alerting/.../gaps/.../update/update_gap_auto_fill_scheduler.ts` | update scheduler | New `params.ruleTypes` (also loads existing via the helper below). |
| `alerting/.../gaps/.../utils.ts` (`getGapAutoFillSchedulerSO`) | get / delete / find-logs / update | `schedulerSO.attributes.ruleTypes`. |

Detection import / upgrade only go through `bulkUpdateRules` (and
`bulkEnable` / `bulkDisable` afterwards, which use
`checkAuthorizationAndGetTotal`). The rest is Stack / RAC / gap
tooling.

---

## How Security privileges are shaped

`getRulesV4BaseKibanaFeature`
(`x-pack/solutions/security/packages/features/src/rules/v4_features/kibana_features.ts`)
puts every Detection rule type under one `alerting.rule.all` grant,
all `consumer: 'siem'`:

| `ruleTypeId` | Notes |
| --- | --- |
| `siem.queryRule` | |
| `siem.eqlRule` | |
| `siem.esqlRule` | |
| `siem.mlRule` | |
| `siem.indicatorRule` | |
| `siem.savedQueryRule` | |
| `siem.thresholdRule` | |
| `siem.newTermsRule` | |
| `siem.notifications` | legacy sidecar |

Feature `read` is the same list with `alerting.rule.read`. The Security
role UI does not expose per-type Update.

---

## What to keep in mind as a Detection caller

- **Create Detection rules with `consumer: 'siem'`.** That is the
  RBAC axis that separates Security from Observability / Stack. Do not
  register or import types that belong to another solution.
- **HTTP routes already gate write.** `rules/_import` and
  `upgrade/_perform` require `RULES_API_ALL`. A user without Rules
  `all` never reaches `bulkUpdateRules`.
- **A throw means the caller is not allowed to update this feature.**
  For a Detection-only list that is the first batch (or the only
  batch). Handle it like `updateRule` 403 — fail the request. You do
  not get, and do not need, per-item authz errors.
- **Match `batchSize` to the HTTP chunk** so a call is one inner
  batch. Default inner size is 100. Re-checking the same `siem` pairs
  on later batches does not change the outcome.
- **Do not mix this with the schedule circuit breaker.** Overflow
  returns 400s on the result and can keep earlier `successfulIds`.
  Authz does not.

---

## Other callers

A custom Kibana role that lists alerting privileges per `ruleTypeId`,
or a Stack caller that puts `siem` and `logs` / `infrastructure` in
the same `bulkUpdateRules` list, can see different pairs across
batches. That is outside Detection. Those callers own their own
error mapping.
