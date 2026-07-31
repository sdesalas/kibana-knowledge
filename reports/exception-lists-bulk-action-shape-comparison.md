# Exception lists `_bulk_action` vs rules `_bulk_action` — shape comparison

RFC: [Bulk Delete Exception Lists](https://docs.google.com/document/d/1-lMRDfNEqCGaODQmHDlIT6KYECViz3YNbj5qso2KWNM)
Reference: `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/bulk_actions/bulk_actions_route.schema.yaml`

## Request

| Field | Rules `_bulk_action` | RFC proposal |
|---|---|---|
| `action` | ✅ required enum discriminator | ✅ same |
| `ids` | ✅ UUID array, **no maxItems** | ✅ same, but **maxItems: 100** |
| `query` | ✅ KQL string (alternative to `ids`) | ❌ missing entirely |
| `list_ids` | ❌ doesn't exist | ➕ new field |
| `namespace_type` | ❌ doesn't exist | ➕ new field |
| Schema dispatch | `oneOf: [BulkDeleteRules, ...]` at body level | flat object, no `oneOf` |
| Mutual exclusion | n/a (only one ID field) | runtime check only |

## Response (200)

| Field | Rules `_bulk_action` | RFC proposal |
|---|---|---|
| `success` | ✅ optional boolean | ✅ same |
| `status_code` | ❌ **only on 500**, not 200 | ➕ added to 200 body |
| `rules_count` | ✅ top-level count | ❌ missing |
| `attributes` wrapper | ✅ **required** | ❌ missing |
| `attributes.results` wrapper | ✅ **required** | ❌ missing — `deleted` is top-level |
| `results.updated/created/deleted/skipped` | ✅ all four arrays | ❌ only `deleted`, no `skipped` |
| `summary` | inside `attributes` | ❌ top-level |
| `summary.skipped` | ✅ present | ❌ missing |
| `errors` | inside `attributes` | ❌ top-level |
| Objects in results | full `RuleResponse` objects | full `ExceptionList` objects ✅ |
