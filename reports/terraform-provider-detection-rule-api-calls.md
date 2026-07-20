# Terraform Provider: Detection Rule API Call Patterns

**Repo:** [`elastic/terraform-provider-elasticstack`](https://github.com/elastic/terraform-provider-elasticstack)
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

## Appendix: Possible optimization — use `_import` and `_export`

### TL;DR

Update the Terraform provider to use two existing public Kibana endpoints for batched operations: `rules/_export` instead of 1000× `GET /rules?id={id}` and `rules/_import` instead of 1000× `PUT /rules`.

- **`POST /api/detection_engine/rules/_export`** — bulk read: send a list of `rule_id`s, get back full rule objects as NDJSON.
- **`POST /api/detection_engine/rules/_import?overwrite=true`** — bulk write: send NDJSON of full rule payloads, Kibana creates or updates each in one request.

This is the same pattern already in production use in [`elastic/detection-rules`](https://github.com/elastic/detection-rules) (the Detection-as-Code repo).

**NOTE:** We will need to make a change to `_import` so that it respects a caller-supplied `rule.id` on create, which it currently ignores.

**ADDITIONAL NOTE:** This Kibana change is a hard prerequisite. Without it, `_import` assigns a fresh UUID on every create, so Terraform's stored `id` would immediately diverge from the rule Kibana actually created — the provider's state would be broken. The Terraform-side work below is not viable without this change landing first. It could piggy-back on in-flight work to improve `rules/_import` create-path performance — [`elastic/kibana#264909`](https://github.com/elastic/kibana/issues/264909).

### Expected impact (1000 rules)

| Operation | Current | Optimized |
|-----------|---------|-----------|
| Plan-time read (refresh) | 1000 × `GET /rules?id=…` | 1 × `POST /rules/_export` |
| Apply — write | 1000 × `PUT /rules` | 1 × `POST /rules/_import?overwrite=true` |
| Apply — read-after-write | 1000 × `GET /rules?id=…` | 1 × `POST /rules/_export` |
| **Total** | **3000 requests** | **3 requests** |

### What has to change

#### On the Terraform provider (`elastic/terraform-provider-elasticstack`) — most of the work

1. **Change the resource lifecycle from per-rule to batched.** The current `entitycore.KibanaResource` envelope invokes `Read`/`Update` once per resource instance. Batching across instances needs a different mechanism — either a provider-level cache warmed on plan, or a custom resource type that hooks into a multi-instance apply.
2. **Wire up `_import` for updates.** Build a multipart NDJSON body (Go's `mime/multipart`), one JSON object per line, with `filename="rules.ndjson"` and `Content-Type: application/x-ndjson`. Call `kbClient.API.ImportRulesWithBodyWithResponse(ctx, params, contentType, body)` with `Overwrite: true`. See `lib/kibana/kibana/connector.py:ndjson_file_data_prep` in `detection-rules` for a reference NDJSON multipart builder.
3. **Wire up `_export` for reads.** POST `{"objects": [{"rule_id": "…"}, …]}` to `_export`. Response is NDJSON — split on newlines, unmarshal each line into a `RuleResponse`. Use `rule_id` (Optional+Computed in the current schema, always present in state after first apply) as the identity, not the UUID.
4. **Keep the per-rule POST for `Create` until the Kibana change below lands.** Without that change, `_import` on a rule that doesn't yet exist will assign a fresh UUID rather than honouring the one the provider wants to record. Individual POST-per-create sidesteps that.

#### On Kibana ([`elastic/kibana`](https://github.com/elastic/kibana)) — behaviour change to public endpoint `rules/_import`

**PLEASE NOTE:** Modifying behaviour of a public endpoint is generally something to avoid — but this case is arguably a fix rather than a real behaviour change, because the wiring already exists and just isn't hooked up.

Make `_import` respect the `id` field on create. The wiring already exists and just isn't hooked up:

- The `RuleToImport` schema already accepts `id` as optional (inherited from `ResponseFields.partial()`).
- The alerting layer's create method already respects `options.id` when provided ([`create_rule.ts:85`](https://github.com/elastic/kibana/blob/main/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L85) — `const id = options?.id || SavedObjectsUtils.generateId();`).
- The security_solution `createRule` wrapper already accepts and forwards `id` (`create_rule.ts:29`).
- The only missing piece is `import_rule.ts` passing `ruleToImport.id` into that `createRule` call. The public contract says nothing about `id` being dropped — that's an implementation-only detail documented in a code comment.

Change is roughly five lines:

- [`import_rule.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rule.ts) — add `id: ruleToImport.id` to the `createRule` call.
- [`detection_rules_client_interface.ts:92`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts#L92) — add `id?: string` to `ImportRuleArgs`.
- [`import_rules.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts) — propagate `id` through the wrapper.

Callers not sending `id` are unaffected. Callers sending it get their value used instead of dropped.

This could piggy-back on in-flight work to improve the performance of the `rules/_import` create path — see [`elastic/kibana#264909`](https://github.com/elastic/kibana/issues/264909).

### Behavior guarantees

- **UUID (`id`) preserved on update.** `import_rule.ts` looks up existing rules by `rule_id`, then calls `rulesClient.update({ id: existingRule.id, … })`. The existing UUID is never replaced. Verified in `import_rule.ts` lines 49–75.
- **UUID (`id`) preserved on create — after the Kibana change above.** Without the change, `createRule` is called with no `id` and Kibana generates a fresh UUID. With the change, the UUID from the NDJSON payload is honoured.
- **`rule_id` always available in Terraform state.** Schema is `Optional + Computed` (`internal/kibana/security_detection_rule/schema.go:60`). If the user doesn't set one, Kibana auto-generates and Terraform stores it. `_import`/`_export` can therefore always use `rule_id` as the identity.
- **Custom rules: fully supported.** The `_import` path treats non-prebuilt rules as `immutable: false` with an internal `rule_source`.
- **Prebuilt rules: fully supported.** `ruleSourceImporter.isPrebuiltRule(rule)` correctly detects prebuilt rules and recalculates `immutable` and `rule_source`. The only extra requirement is a `version` field, which the provider already stores (`internal/kibana/security_detection_rule/models.go:77`).
- **Response payload identity.** `_export` returns NDJSON where each line is a full `RuleResponse` — identical to what the per-rule `GET` returns today (same `internalRuleToAPIResponse` converter used everywhere).
- **Size limits.** Default `maxRuleImportPayloadBytes` = 10 MB; `maxRuleImportExportSize` = 10 000 rules. 1000 rules fits comfortably.

### Reference implementation

The [`elastic/detection-rules`](https://github.com/elastic/detection-rules) repo has been using this pattern in production for its Detection-as-Code workflow. Key files to study:

- [`lib/kibana/kibana/resources.py`](https://github.com/elastic/detection-rules/blob/main/lib/kibana/kibana/resources.py) — `RuleResource.import_rules()` and `RuleResource.export_rules()` show the request shapes.
- [`lib/kibana/kibana/connector.py`](https://github.com/elastic/detection-rules/blob/main/lib/kibana/kibana/connector.py) — `ndjson_file_data_prep` shows how to build the multipart NDJSON body.
- [`detection_rules/kbwrap.py`](https://github.com/elastic/detection-rules/blob/main/detection_rules/kbwrap.py) — `kibana_import_rules` and `kibana_export_rules` show the end-to-end flow including error handling and `rule_id` reconciliation.

### Key files

**Terraform provider ([`elastic/terraform-provider-elasticstack`](https://github.com/elastic/terraform-provider-elasticstack)):**
- [`internal/entitycore/base_envelope.go`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/entitycore/base_envelope.go) — `Read()`, current per-instance read; would need a batching bypass or wrapper
- [`internal/entitycore/kibana_resource_envelope.go`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/entitycore/kibana_resource_envelope.go) — `runKibanaWrite()`, current per-instance write; same
- [`internal/kibana/security_detection_rule/read.go`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/kibana/security_detection_rule/read.go), [`update.go`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/kibana/security_detection_rule/update.go), [`create.go`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/kibana/security_detection_rule/create.go) — the callbacks to be replaced with batched versions (except create, which stays on per-rule POST until the Kibana change lands)
- [`internal/kibana/security_detection_rule/schema.go#L60`](https://github.com/elastic/terraform-provider-elasticstack/blob/eada3168c4b88f3c0a99bcefee1cfc9b2f7d8c6a/internal/kibana/security_detection_rule/schema.go#L60) — `rule_id` schema (already Optional+Computed)
- `generated/kbapi/kibana.gen.go` — already has `ImportRulesWithBodyWithResponse`, `ExportRulesWithResponse` (generated file, not linked)

**Kibana ([`elastic/kibana`](https://github.com/elastic/kibana)):**
- [`import_rule.ts`](https://github.com/elastic/kibana/blob/db0d74a79a2b97e872372d7ff298fb482337527c/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/import_rule.ts) — add `id: ruleToImport.id` to the `createRule` call
- [`detection_rules_client_interface.ts#L92`](https://github.com/elastic/kibana/blob/db0d74a79a2b97e872372d7ff298fb482337527c/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts#L92) — add `id?: string` to `ImportRuleArgs`
- [`import_rules.ts`](https://github.com/elastic/kibana/blob/db0d74a79a2b97e872372d7ff298fb482337527c/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/import/import_rules.ts) — propagate `id` through the wrapper
- (For context, no change needed:) [`create_rule.ts#L85`](https://github.com/elastic/kibana/blob/db0d74a79a2b97e872372d7ff298fb482337527c/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts#L85) — already respects `options.id`

### Alternatives considered and rejected

- **`POST /api/detection_engine/rules/_bulk_action` with the `edit` action.** Genuinely bulk under the hood (single `bulkCreate` SO write), but `edit` is a partial field patcher — only `tags`, `actions`, `index_patterns`, `investigation_fields`, `alert_suppression`, `timeline`, and `schedule` are covered. Cannot replace the general `PUT` needed for full rule sync.
- **Adding a new `put` action to `_bulk_action`.** Kibana-side change of similar shape to what we now recommend for `_import`, but requires more design (new action type, request/response validation) and doesn't reuse an established pattern. `_import` already handles the exact semantics (`overwrite=true`) and has a reference client to copy from.
- **Batching reads via `GET /_find` with KQL ID filters.** Works today with no changes (splits 1000 GETs into ~20 chunked GETs of 50 IDs each), and the payload is identical to the per-rule GET. Kept as a **fallback** if `_export` isn't viable for some reason, but strictly worse than a single `_export` call.
