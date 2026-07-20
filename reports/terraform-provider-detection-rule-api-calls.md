# Terraform Provider: Detection Rule API Call Patterns

**Repo:** `elastic/terraform-provider-elasticstack`
**Date:** 2026-07-20

## How current state is determined during `terraform plan`

### With `refresh=true` (default)

Before computing a diff, Terraform calls `Read()` on every resource instance in state. For each detection rule the provider fires:

```
GET /s/{spaceId}/api/detection_engine/rules?id={uuid}
```

One request per rule, no batching. With 1000 rules that's **1000 individual GETs** before the plan diff is computed.

Call path:
```
base_envelope.go: Read()
  → readDetectionRule()   (read.go)
    → kbClient.API.ReadRuleWithResponse()
      → GET /s/{spaceId}/api/detection_engine/rules?id={uuid}
```

### With `refresh=false`

Terraform skips all `Read()` calls. It treats `.tfstate` as the current state, so **zero API calls** happen during plan. The diff is computed purely from tfstate vs config.

---

## APIs hit during `terraform apply` (1000 rules all needing an update)

For each rule that the plan decided needs updating, two sequential calls fire:

| # | Method | Endpoint | Purpose |
|---|--------|----------|---------|
| 1 | `PUT` | `/s/{spaceId}/api/detection_engine/rules` | update the rule |
| 2 | `GET` | `/s/{spaceId}/api/detection_engine/rules?id={uuid}` | read-after-write refresh |

Both are single-rule operations — there is no bulk endpoint used anywhere in this path.

With 1000 rules: **1000 PUTs + 1000 GETs = 2000 requests total**.

Call path for apply:
```
kibana_resource_envelope.go: runKibanaWrite()
  → updateDetectionRule()   (update.go)
    → kbClient.API.UpdateRuleWithResponse()
      → PUT /s/{spaceId}/api/detection_engine/rules
  → readDetectionRule()     (read.go)  [read-after-write, always fires]
    → kbClient.API.ReadRuleWithResponse()
      → GET /s/{spaceId}/api/detection_engine/rules?id={uuid}
```

---

## Key files

| File | Role |
|------|------|
| `internal/entitycore/base_envelope.go:Read()` | Drives the plan-time refresh loop |
| `internal/kibana/security_detection_rule/read.go:readDetectionRule()` | Issues the GET per rule |
| `internal/entitycore/kibana_resource_envelope.go:runKibanaWrite()` | Drives create/update + read-after-write |
| `internal/kibana/security_detection_rule/update.go:updateDetectionRule()` | Issues the PUT per rule |

---

## Implications

- **`plan` with default refresh and 1000 rules** is expensive: 1000 GETs, all sequential per rule (Terraform parallelises across resource *types*, but each resource instance goes through its own Read call).
- **`refresh=false`** eliminates plan-time GETs entirely but risks stale drift going undetected.
- **apply** always does read-after-write regardless of `refresh` flag — there is no way to skip the post-write GET today without a provider code change (`SkipReadAfterWrite` option exists in the ES envelope but is not wired for detection rules).
- There is no bulk read or bulk update endpoint used anywhere in this flow.

---

## Appendix: Kibana bulk action endpoint — feasibility for provider use

`POST /api/detection_engine/rules/_bulk_action` exists and supports bulk operations selected by an `action` field. The question is whether it could replace the per-rule PUT/GET pattern.

### Bulk edit internals

The `edit` action calls `bulkEditRules()` (security_solution) → `rulesClient.bulkEdit()` (alerting) → `bulkEditRulesOcc()`. The execution model is:

1. **Bulk read** via a point-in-time saved-objects finder (100 rules per page)
2. **Per-rule compute** — `paramsModifier` runs individually per rule (via `pMap`, concurrency-limited for API key generation)
3. **Bulk write** — a single `bulkCreate({ overwrite: true })` saved-objects call persists all modified rules

So the save itself is genuinely bulk, but the modification logic runs per rule on the server side.

### Fields covered by bulk edit

The `edit` action only touches a specific subset of fields:

| Edit type | Fields touched |
|-----------|----------------|
| `add/delete/set_tags` | `tags` |
| `add/set_rule_actions` | `actions`, `throttle`, `notifyWhen` |
| `add/delete/set_index_patterns` | `index`, `dataViewId` |
| `add/delete/set_investigation_fields` | `investigationFields` |
| `set_alert_suppression` / `set_alert_suppression_for_threshold` / `delete_alert_suppression` | `alertSuppression` |
| `set_timeline` | `timelineId`, `timelineTitle` |
| `set_schedule` | `from`, `meta.from` (interval + lookback) |

**Not covered** (partial list): `name`, `description`, `query`, `language`, `filters`, `severity`, `risk_score`, `threat`, `max_signals`, `exceptions_list`, `threshold`, `threat_*` fields, ML job IDs. Enable/disable are separate bulk actions (`enable`/`disable`), not `edit`.

### What would be needed to optimize Terraform

To eliminate the 1000-GET plan refresh and 2000-request apply cycle, Kibana would need to extend `POST /api/detection_engine/rules/_bulk_action` (the route in `route.ts` above) with two new action types:

- **`get`** — accept a list of rule IDs (or a KQL query) and return the full rule objects. This would let the provider replace 1000 individual `GET /api/detection_engine/rules?id=…` calls with a single request during plan refresh.
- **`put`** (or `update_all`) — accept a list of fully-specified rule payloads and write each as a complete replacement, equivalent to calling `PUT /api/detection_engine/rules` per rule. This would replace 1000 individual PUTs on apply.

The existing `edit` action is not sufficient for the `put` case because it is a partial field patcher, not a full rule replacement (see field coverage table above).

Both new actions would sit alongside the existing ones in `performBulkActionRoute` and delegate to the detection rules client, following the same `fetchRulesByQueryOrIds` → action → `buildBulkResponse` pattern already in place.

### Conclusion

The `edit` bulk action cannot substitute for the per-rule `PUT` the provider currently uses. `PUT /api/detection_engine/rules` is a full rule replacement; the bulk `edit` action is a partial field patcher. Using it would require splitting each Terraform update into multiple bulk action calls per field group, re-reading state after each, and losing atomicity — worse than the current approach. The bulk endpoint is useful for mass operational changes (re-tagging, re-scheduling) but not for general rule sync.

Key files (kibana repo):
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts` — route handler, action dispatch
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/bulk_actions/bulk_edit_rules.ts` — security_solution bulkEdit orchestration
- `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/bulk_actions/rule_params_modifier.ts` — per-rule field patching logic
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/bulk_edit_rules_occ.ts` — alerting-layer bulk read/write execution
