# Adding a `sequence` Property to Alerting Rules

This guide explains how to add a new top-level property `sequence` to alerting rules that starts at 0 and is incremented on **every** change made via the rules client. It is intended for the implementer and explains *why* each change is needed, not just *what* to change.

## Context: How This Differs From Existing Counters

- **`revision`** (all alerting rules): Stored on the rule saved object. It is incremented **only when certain fields change**; many updates (e.g. API key refresh, snooze, enable/disable) do not bump revision. Logic lives in `shouldIncrementRevision` and `fieldsToExcludeFromRevisionUpdates` in the alerting plugin.
- **`params.version`** (security rules): Semantic version of the rule content (e.g. prebuilt rule version). It is security-specific and lives inside rule params, not as a framework-level attribute.

**`sequence`** should be a **monotonically increasing change counter**: every time the rule document is written (create or update), sequence either is set to 0 (create) or `(current sequence ?? 0) + 1` (any update). No conditional logic—every persisted change increments it. That makes it suitable for change history, cache invalidation, or “version” displays that count edits.

## Where the Rule Document Lives

Rules are saved as Saved Objects of type `alert` (RULE_SAVED_OBJECT_TYPE). The attributes are described by the **RawRule** type and validated by the **raw rule schema**. The document is written in several places:

1. **Create** – `create_rule.ts` builds initial attributes and calls `createRuleSavedObject`.
2. **Update** – `update_rule.ts` builds `updatedRuleAttributes` and saves with `createRuleSo` (overwrite).
3. **Bulk edit** – `bulk_edit_rules.ts` + `update_rule_in_memory.ts` build updated attributes per rule; `bulk_edit_rules_occ.ts` persists via `bulkCreateRulesSo` (overwrite).
4. **Bulk edit params** – `bulk_edit_rule_params.ts` builds updated rule and persists.
5. **Enable / Disable** – `enable_rule.ts` and `disable_rule.ts` call `savedObjectsClient.update` with a subset of attributes.
6. **Update API key** – `update_rule_api_key.ts` calls `savedObjectsClient.update` with updated attributes.
7. **Bulk enable / Bulk disable** – Same idea: they build update payloads and persist.
8. **Snooze / Unsnooze / Mute / Unmute** – If any of these update the rule saved object (not only the task), they must also bump `sequence`.

So the implementation has two parts: (A) add `sequence` to the stored shape and to the API/domain types, and (B) set/increment it on **every** code path that writes the rule.

---

## Part A: Add `sequence` to the Stored Shape and Public Types

### 1. Raw rule schema (persistence)

**Why:** The saved object layer validates and types rule attributes. Existing rules in the index do not have `sequence`, so the field must be optional for backward compatibility.

**Where:**

- [/x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/](/x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/)

**What to do:**

- Add `sequence` to the **latest** raw rule schema (currently v8 re-exports v7; the actual schema is in v3 for revision and similar fields). Prefer adding a new schema version (e.g. v9) that extends the previous one with `sequence: schema.maybe(schema.number())` so that:
  - New rules get `sequence` set explicitly.
  - Old documents without `sequence` still validate (optional).
- Update [raw_rule/latest.ts](/x-pack/platform/plugins/shared/alerting/server/saved_objects/schemas/raw_rule/latest.ts) to export from the new version so **RawRule** includes `sequence?: number`.

**Why optional:** So already-stored rules without the field remain valid; at read time you treat `undefined` as 0 and when writing you always set `sequence: (existing.sequence ?? 0) + 1` (or 0 on create).

### 2. Elasticsearch mapping

**Why:** If you ever search or aggregate on `sequence`, it must be in the index mapping. Even if you only read it back from the document, adding it keeps the mapping explicit and avoids dynamic mapping surprises.

**Where:**

- [/x-pack/platform/plugins/shared/alerting/common/saved_objects/rules/mappings.ts](/x-pack/platform/plugins/shared/alerting/common/saved_objects/rules/mappings.ts) – add a `sequence` property (e.g. `type: 'long'`) next to `revision`.
- [/x-pack/platform/plugins/shared/alerting/server/saved_objects/model_versions/rule_model_versions.ts](/x-pack/platform/plugins/shared/alerting/server/saved_objects/model_versions/rule_model_versions.ts) – add a new model version (e.g. `'9'`) with a `mappings_addition` change for `sequence: { type: 'long' }` and point the create schema to the new raw rule schema that includes `sequence`.

**Why a model version:** So existing deployments get the new mapping when they upgrade, and new installs get it from the start.

### 3. Domain and API types and transforms

**Why:** The rules client returns rule domain objects and sanitized rules. Those types and the transforms that build them must include `sequence` so it is persisted and returned by the API.

**Where:**

- [/x-pack/platform/plugins/shared/alerting/server/application/rule/schemas/rule_schemas.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/schemas/rule_schemas.ts) – add `sequence` to **ruleDomainSchema** and **ruleSchema** (e.g. `sequence: schema.maybe(schema.number())` or `schema.number()` if you default at read time).
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/types/rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/types/rule.ts) – add `sequence` to the **Rule** and **RuleDomain** interfaces (they are driven by the schemas above).
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_attributes_to_rule_domain.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_attributes_to_rule_domain.ts) – set `sequence: esRule.sequence ?? 0` when building the domain object so callers always see a number.
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_domain_to_rule_attributes.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_domain_to_rule_attributes.ts) – include `sequence: rule.sequence` when building **RawRule** (same pattern as `revision`).
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_domain_to_rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_domain_to_rule.ts) – pass through `sequence` from domain to the sanitized rule.
- [/x-pack/platform/plugins/shared/alerting/common/routes/rule/response/schemas/v1.ts](/x-pack/platform/plugins/shared/alerting/common/routes/rule/response/schemas/v1.ts) – add `sequence` to the HTTP response schema (and any find/response types that expose rule fields), so the REST API returns it.

After this, every place that reads a rule from storage and returns it will expose `sequence`; every place that builds domain/attributes from existing data will carry `sequence` through.

---

## Part B: Set and Increment `sequence` on Every Write

Rule of thumb: **whenever you write rule attributes to the saved object (create or update), set `sequence` to 0 on create and to `(current.sequence ?? 0) + 1` on update.** Do not gate this on “meaningful” changes; any write counts.

### 4. Create

**Where:** [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/create/create_rule.ts)

**What to do:** When building the rule object passed to `transformRuleDomainToRuleAttributes` (the block that already sets `revision: 0`), add **`sequence: 0`**. The transform will then include it in the saved attributes.

**Why:** New rules start at 0; the first update will make them 1.

### 5. Single-rule update

**Where:** [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts), inside `updateRuleAttributes`.

**What to do:** After computing `revision` (and before building `updatedRuleAttributes`), compute **`sequence = (originalRule.sequence ?? 0) + 1`**. Add `sequence` to the object passed to `updateMetaAttributes` (same place you set `revision`). Do **not** make this conditional: every update increments sequence.

**Why:** This is the main “edit rule” path; every successful update should bump the change counter.

### 6. Bulk edit (attributes and params)

**Where:**

- [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/bulk_edit_rules.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit/bulk_edit_rules.ts) – in `getUpdatedAttributesFromOperations`, when you apply an operation and update `updatedRule`, you currently conditionally do `updatedRule.revision += 1`. For **sequence**, always increment when the rule is actually modified: e.g. when `!isAttributesUpdateSkipped` or when you’re not skipping the op, set `updatedRule.sequence = (updatedRule.sequence ?? rule.sequence ?? 0) + 1`. Ensure the initial `updatedRule` has `sequence` from the rule (from the domain you built from the saved object).
- [/x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/update_rule_in_memory.ts](/x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/update_rule_in_memory.ts) – when building `updatedRule` from the saved rule, set `updatedRule.sequence = rule.attributes.sequence ?? 0`. Then, whenever you’re not skipping the update (i.e. you will persist), set `updatedRule.sequence = (rule.attributes.sequence ?? 0) + 1` (once per rule, not per operation). That way the domain object that goes into `transformRuleDomainToRuleAttributes` has the new sequence.
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit_params/bulk_edit_rule_params.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_edit_params/bulk_edit_rule_params.ts) – in `getUpdatedParamAttributesFromOperations`, when you apply a change and increment revision, also set `updatedRule.sequence = (updatedRule.sequence ?? 0) + 1`.

**Why:** Bulk edit and bulk edit params are the other main write paths; they must behave like “every persisted change increments sequence.”

### 7. Enable / Disable / Update API key

**Where:**

- [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/enable_rule/enable_rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/enable_rule/enable_rule.ts) – in the `updateAttributes` object passed to `updateMeta` (and then to `create` or `update`), add **`sequence: (attributes.sequence ?? 0) + 1`**.
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/disable/disable_rule.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/disable/disable_rule.ts) – in the object passed to `updateMeta` for the rule update, add **`sequence: (attributes.sequence ?? 0) + 1`**.
- [/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update_api_key/update_rule_api_key.ts](/x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update_api_key/update_rule_api_key.ts) – in `updateAttributes`, add **`sequence: (attributes.sequence ?? 0) + 1`**.

**Why:** These paths all call `savedObjectsClient.update` (or create with overwrite) and therefore change the rule document; they should all bump the sequence so that “number of changes” is accurate.

### 8. Bulk enable / Bulk disable / Snooze / Unmute / etc.

**Where:** Search for any other use of `unsecuredSavedObjectsClient.update` or `create` with rule attributes in the alerting plugin (e.g. bulk_enable_rules.ts, bulk_disable_rules.ts, snooze, mute_all, unmute_all).

**What to do:** For each place that updates the rule saved object with (a subset of) rule attributes, add **`sequence: (attributes.sequence ?? 0) + 1`** to the payload (using the current rule’s attributes so you read the latest sequence before incrementing). If the flow uses a domain object, ensure that object has `sequence` and that the transform to attributes includes it, and that you increment once per rule when building the update.

**Why:** Any write to the rule document must increment sequence; otherwise the counter no longer means “total number of changes.”

---

## Summary Table

| Area | Purpose |
|------|--------|
| Raw rule schema + latest | Persistence type and validation; optional for backward compatibility. |
| Mappings + model version | ES mapping and upgrade path for existing installs. |
| Rule/rule domain schemas + types | So `sequence` is part of the domain and API. |
| Transforms (attributes ↔ domain ↔ rule) | So `sequence` is read from ES, passed through domain, and written back. |
| Create | Set `sequence: 0`. |
| Update, bulk edit, bulk edit params | Set `sequence = (current ?? 0) + 1` on every persisted update. |
| Enable, disable, update API key, bulk enable/disable, snooze, mute, etc. | Same: include `sequence: (attributes.sequence ?? 0) + 1` in every update payload. |

## Testing and Consistency

- **Unit tests:** Where tests assert on `revision` (e.g. create_rule.test.ts, update_rule.test.ts), add expectations for `sequence` (0 on create, incremented on update). For update paths that don’t change revision but do change the document (e.g. enable/disable, update API key), add assertions that `sequence` still increments.
- **Backward compatibility:** Using `(existing.sequence ?? 0)` everywhere ensures old documents without `sequence` are treated as 0 and then get a correct value on first write after the change.
- **Change tracking:** If you use a change-tracking service (e.g. for rule history), consider whether the stored “current” snapshot should include `sequence` so that history entries can refer to a specific change index; that’s an optional follow-up.

This design keeps `sequence` simple (always increment on write), consistent across all write paths, and backward compatible with existing rules that don’t have the field yet.
