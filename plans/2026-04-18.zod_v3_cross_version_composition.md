# Cross-version Zod composition: why a "rule_schema only" v3 island leaks

## TL;DR

Reverting `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/**` to Zod v3 while leaving the rest of Kibana on Zod v4 cannot be done with the folder boundary alone. The minimum viable boundary is the **value-level dependency closure** of every schema exported from `rule_schema/`. After running a scoped typecheck of `security_solution`, that closure produces **1,627 errors across ~350 files**, almost all of them the same root cause: a Zod **v3 schema is being passed as an argument to a Zod v4 schema constructor** (`z.object`, `z.discriminatedUnion`, `.merge`, `.extend`, etc.).

This document explains the mechanism, shows a representative error, lists the radiating call sites, and proposes options.

## What's incompatible

`zod@4.x` ships **two parallel runtimes** under one npm package: `zod/v3` and `zod/v4`. They are *both* "Zod" semantically but their TypeScript types are intentionally distinct:

| | `zod/v3` | `zod/v4` |
| --- | --- | --- |
| Base class | `ZodType<Output, Def, Input>` (legacy `_def` / `typeName` discriminator) | `$ZodType<Output, Input, Internals>` (new `_zod` internals struct) |
| Object | `ZodObject<{ [k]: ZodTypeAny }, "strip" \| "strict" \| "passthrough", …>` | `ZodObject<Readonly<{ [k]: $ZodType<unknown, unknown, $ZodTypeInternals<…>> }>, "$strip" \| …>` |
| Issue model | `ZodError` with nested `unionErrors`, `ZodIssueCode` enum | `$ZodError` with flat `errors`, codes are string literals |
| Refinement ctx | `RefinementCtx` from `zod/v3` | `RefinementCtx` from `zod/v4` (different generic shape) |

These are **structurally** different types. TypeScript will not unify them. Hence:

```ts
import { z as z3 } from '@kbn/zod/v3';
import { z as z4 } from '@kbn/zod/v4';

const RuleResponseV3 = z3.object({ id: z3.string() }); // ZodObject<…, $strip> from v3

const Wrapper = z4.object({                            // expects v4 shape
  rule: RuleResponseV3,                                // ❌ TS2345
});
```

The same incompatibility applies to `.merge`, `.extend`, `.and`, `.or`, `z.discriminatedUnion`, `z.union`, `.transform` chains that hand the inner schema to a v4 combinator, and to `z.ZodType<T>` casts where `z` is the wrong flavor.

## A representative error

After regenerating the v3 island, a typical failure outside the folder looks like:

```text
x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/prebuilt_rules/model/diff/diffable_rule/diffable_rule.ts:244:45 -
error TS2345: Argument of type
  'ZodObject<{ type: ZodLiteral<"query">; kql_query: ZodDiscriminatedUnion<…>;
               data_source: ZodOptional<…>; alert_suppression: ZodOptional<…>;
               …; }, $strip>'
is not assignable to parameter of type
  'ZodObject<Readonly<{ [k: string]: $ZodType<unknown, unknown, $ZodTypeInternals<unknown, unknown>>; }>, $strip>'.
```

Reading it: `diffable_rule.ts` uses `z` from `@kbn/zod/v4` and feeds in schemas (`QueryRule`, `SavedQueryRule`, …) that, after the island change, are now `@kbn/zod/v3` schemas. The v4 combinator's parameter type is "v4 ZodObject", the argument is "v3 ZodObject", so TypeScript rejects it.

## Why the boundary cannot be `rule_schema/`

The original assumption was that the boundary could stay at the folder. Two facts make that impossible:

### 1. `.gen.ts` files compose across folders

`rule_schemas.gen.ts` builds discriminated unions from schemas defined in `rule_response_actions/**` and `rule_monitoring/model/**`, so those have to flip to v3 too — already addressed by adding them to the island.

But `siem_migrations/model/rule_migration.gen.ts` and `siem_migrations/model/api/rules/rule_migration.gen.ts` import `RuleResponse`, `Threat`, and `RelatedIntegration` **as values** (not just as types) from `rule_schema/`. They were also moved into the island for that reason.

### 2. Hand-written code composes value-level exports too

This is where it leaks far beyond OpenAPI-generated code. A non-exhaustive list of value-level consumers found by `grep` and surfaced by typecheck:

- `common/api/detection_engine/prebuilt_rules/model/diff/diffable_rule/diffable_rule.ts` and the `diff/**` neighbours.
- `common/api/detection_engine/prebuilt_rules/review_rule_upgrade/review_rule_upgrade_route.ts`
- `common/api/detection_engine/prebuilt_rules/review_rule_installation/review_rule_installation_route.ts`
- `common/api/detection_engine/rule_management/import_rules/rule_to_import.ts`
- `common/api/detection_engine/rule_management/model/query_rule_by_ids_validation.ts`
- `common/api/detection_engine/rule_management/crud/{create_rule,update_rule}/request_schema_validation.test.ts`
- `server/lib/detection_engine/rule_types/factories/utils/build_alert.ts` (and most `server/lib/detection_engine/rule_types/**` siblings)
- `server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts`
- `server/usage/detections/rules/**` (transform / usage utilities)
- `server/lib/siem_migrations/**`

Each of these either:
- imports `RuleResponse` / `RuleParams` / `Threat` / `AlertSuppression` / `RelatedIntegrationArray` / etc. as a **value** and passes it into `z.object(...)` or another v4 combinator, or
- destructures `z.infer<typeof RuleResponse>` and then walks members that the v3 inferred type widens differently from v4 (e.g. `params.alertSuppression.duration` becomes `unknown` because v3's discriminated-union narrowing differs from v4's).

### 3. Cascade is transitive

If `diffable_rule.ts` becomes v3 to fix its own composition, then `prebuilt_rules/diff/calculation/**` which imports `DiffableRule` as a value also needs to be v3, and so on through the prebuilt rules pipeline, the rule importer, route handlers, alert factories, telemetry, and the SIEM migrations agent code. This is the radiation visible in the 1,627 errors.

## What does NOT cause a problem

- **Type-only imports.** `import type { RuleResponse } from '…/rule_schema'` is fine in v4 code; it's just a TypeScript type alias.
- **Schemas the island never exports.** Anything outside the closure stays v4 with no edits.
- **Helpers.** `@kbn/zod-helpers/v3` and `@kbn/zod-helpers/v4` coexist cleanly because each is internally consistent with its own `z`.
- **The OpenAPI generator's per-YAML opt-in.** `x-zod-flavor: v3` only changes which `z` import the generated file uses — it does not by itself create cross-version mixing.

## Mental model

> **Zod has no implicit conversion between v3 and v4 schemas.** A Zod schema is a graph of typed nodes; the entire graph must use one runtime. Flipping a leaf to v3 only works if every parent node that holds it as a value also flips to v3. The boundary is therefore "the value-level dependency closure", not a folder.

If you only want **runtime values that are still validated**, the boundary is structural. If you only need **the inferred TypeScript type** at the boundary (i.e. you parse with v3 inside, then hand the parsed payload around as `RuleResponse`), the boundary can be drawn at imports — by switching outside consumers to type-only imports plus an opaque schema (`z.custom<RuleResponse>()` / `z.unknown().transform(x => x as RuleResponse)`) when they need a v4 schema slot.

## Options on the table

1. **Expand the island along the cascade.** Convert every value-level consumer (the `~350` files above) to `@kbn/zod/v3`. Largest surface; ends up converting most of detection_engine + siem_migrations to v3 — which contradicts "leave the rest of Kibana on v4".

2. **v4 facade re-exports.** Keep v3 internally inside `rule_schema/**/*.gen.ts`, but additionally export v4 `z.ZodType<RuleResponse>` (etc.) facades — typically `z.custom<RuleResponse>(v => RuleResponseV3.safeParse(v).success)` — so external code can keep its v4 compositions. Bounded blast radius, but the generator (or a hand-written shim) has to emit both shapes.

3. **Type-only boundary at consumers.** Edit each value-level consumer to import `RuleResponse` *as a type* and replace the runtime slot with `z.custom<RuleResponse>()` or `z.unknown()`. Surgical; runtime validation at the boundary is reduced to a single `safeParse` call where it really matters.

4. **Roll back the YAML / handwritten flips.** Keep the platform changes (`@kbn/zod/v3`, `@kbn/zod-helpers/v3`, `x-zod-flavor: v3` support, granular helper detection) staged for later; revert the island annotations and re-discuss the boundary before touching consumers.

5. **Narrow the island further.** E.g. only flip `rule_schema/**` and accept that `rule_response_actions`, `rule_monitoring/model`, `siem_migrations/model` stay v4. The compose graph still breaks (those files import `rule_schema` schemas as values), so this only reduces the cascade — it doesn't avoid it.

## Recommendation

Option **2** (v4 facade re-exports) or option **3** (type-only boundary) match the user's stated intent — "the rest of Kibana stays on v4" — without an unbounded cascade. They differ on where the cost lands:

- Option 2 puts the cost in the generator and `rule_schema/index.ts` (one-time, mechanical, applies to all current and future consumers).
- Option 3 puts the cost on each consumer call site (one-time, more invasive at sites, but no generator changes).

Option 1 is technically possible but contradicts the goal. Option 4 is appropriate if the design needs to be re-litigated. Option 5 is unlikely to help on its own.
