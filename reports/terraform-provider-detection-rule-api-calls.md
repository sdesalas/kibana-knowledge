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
