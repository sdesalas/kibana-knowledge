# Prebuilt rule upgrade fails when resolving Required Fields without `ecs`

**Date**: 2026-07-17
**Related issue**: https://github.com/elastic/kibana/issues/232614
**Reported by**: mick-lue (issue), Steven de Salas (this report / fix)

**API endpoint affected**:

- `POST /internal/detection_engine/prebuilt_rules/upgrade/_perform` — apply a pending prebuilt rule upgrade with a manually resolved `required_fields` value

---

## The problem

When upgrading a customized prebuilt rule that has a conflict on **Required Fields**, the Rule Update UI lets you edit the final value and send it as `pick_version: "RESOLVED"`. That request fails with 400:

```
[request body]: rules.0.fields.required_fields.resolved_value.N.ecs: Invalid input: expected boolean, received undefined
```

(Older wording from 9.0.4 in #232614: `...ecs: Required`.)

The UI only collects `name` + `type` for each required field. It never sends `ecs`. Existing fields copied from the diff response often still have `ecs` attached; **newly added** fields do not — so the failure shows up as soon as someone adds or rebuilds a field during conflict resolution.

### Why it happens

Create / patch / import already treat `ecs` as a **server-computed** property:

- Request schema uses `RequiredFieldInput` (`name` + `type` only).
- Server fills `ecs` via `addEcsToRequiredFields()` (ECS field map lookup by name + type).

The upgrade perform route did not follow that pattern. `RuleFieldsToUpgrade` reused `DiffableUpgradableFields`, and `required_fields` there is `RequiredFieldArray` — the **response** shape, where `ecs` is required.

So validation rejected valid UI payloads before the handler could run.

---

## The fix

1. **Request schema** (`perform_rule_upgrade_route.ts`): override `required_fields` so `resolved_value` accepts `RequiredFieldInput[]`. If a client still sends `ecs`, Zod strips it.
2. **Server apply path** (`get_value_for_field.ts`): when applying a RESOLVED `required_fields` value, call `addEcsToRequiredFields()` before building the upgraded rule asset.

Persistence already went through `applyRuleDefaults` / `convertRuleResponseToAlertingRule`, which also call `addEcsToRequiredFields` — the schema change is what unblocks the request; the explicit call keeps the intermediate asset correct.

### Files touched

- `common/api/detection_engine/prebuilt_rules/perform_rule_upgrade/perform_rule_upgrade_route.ts`
- `common/api/detection_engine/prebuilt_rules/perform_rule_upgrade/perform_rule_upgrade_route.test.ts`
- `server/lib/detection_engine/prebuilt_rules/api/perform_rule_upgrade/get_value_for_field.ts`

---

## How to verify

Dry-run (or real) upgrade with a RESOLVED `required_fields` payload that omits `ecs` on at least one entry — should return 200, and saved fields should have `ecs` computed server-side.
