---
name: Zod v3 for Security Solution generated schemas
overview: Flip every OpenAPI-generated `.gen.ts` file inside `x-pack/solutions/security/**` to Zod v3 via `@kbn/zod/v3` / `@kbn/zod-helpers/v3`. Generator gains a per-call `zodFlavor` option and an optional v4 facade emitter; security_solution plugin/server/public consumers flip to v3, while shared `kbn-securitysolution-*-common` packages additionally emit v4 facades so cross-plugin consumers (e.g. `lists` plugin) need no edits.
todos:
  - id: kbn-zod-v3
    content: Add `@kbn/zod/v3` re-export of `zod/v3` and ensure TS resolution matches `@kbn/zod/v4`.
    status: completed
  - id: kbn-zod-helpers-v3
    content: Add `@kbn/zod-helpers/v3` with v3-typed refinements + test helpers (`isValidDateMath`, `isNonEmptyString`, `arrayFromString`, `booleanFromString`, `expectParseSuccess`, `expectParseError`, `stringifyZodError`).
    status: completed
  - id: openapi-generator-flavor
    content: "Add a per-call `zodFlavor: 'v3' | 'v4'` option (default `'v4'`) to `@kbn/openapi-generator`'s `generate()`. Thread through context. Template emits `@kbn/zod/${flavor}` and `@kbn/zod-helpers/${flavor}`."
    status: pending
  - id: openapi-generator-facade
    content: "Add a per-call `emitV4Facade: boolean` option (default `false`) that, when combined with `zodFlavor: 'v3'`, makes the generator additionally emit a sibling `*.gen.v4.ts` file with `z.custom<T>(value => OriginalSchema.safeParse(value).success)` facades for every exported schema, re-exporting types via `z.infer`."
    status: pending
  - id: openapi-generator-cleanup
    content: "Update `removeGenArtifacts` to also delete `*.gen.v4.ts` companions when present, so re-runs stay deterministic."
    status: pending
  - id: openapi-generator-helper-detection
    content: "Replace the coarse `useZodHelpers: boolean` flag with per-helper flags (`useIsValidDateMath`, `useIsNonEmptyString`, `useArrayFromString`, `useBooleanFromString`) detected from schema shape, so generated files import only the helpers they use and don't trigger `no_unused_imports`."
    status: pending
  - id: security-openapi-script
    content: "Set `zodFlavor: 'v3'` for all five `generate()` calls in `security_solution/scripts/openapi/generate.js`. Set `emitV4Facade: true` for the bundled api_client_supertest outputs that land in `packages/test-api-clients/`."
    status: pending
  - id: shared-packages-openapi-scripts
    content: "Set `zodFlavor: 'v3', emitV4Facade: true` in `kbn-securitysolution-{exceptions,lists,endpoint-exceptions}-common/scripts/openapi_generate.js` so shared package outputs stay consumable by `lists` plugin and external consumers without edits."
    status: pending
  - id: regenerate
    content: "Re-run `node scripts/openapi/generate.js` for security_solution and the three shared packages; commit the new `*.gen.ts` (now v3) and new `*.gen.v4.ts` facades."
    status: pending
  - id: flip-security-solution-consumers
    content: "Inside `x-pack/solutions/security/plugins/security_solution/{common,server,public}/**` and `x-pack/solutions/security/test/**`, switch every value-level import that currently targets `@kbn/zod` (v4) but composes a generated schema to `@kbn/zod/v3` and `@kbn/zod-helpers/v3`. Type-only imports stay unchanged."
    status: pending
  - id: lists-plugin-strategy
    content: "Audit `x-pack/solutions/security/plugins/lists/**` for value-level uses of `kbn-securitysolution-*-common` `.gen.ts` schemas. Where they compose into v4 `z.object` chains, switch the import to the `*.gen.v4.ts` facade. Where they parse directly, switch to `@kbn/zod/v3` and use the v3 schema directly."
    status: pending
  - id: validate
    content: "Run scoped typecheck for `security_solution`, `lists`, `kbn-securitysolution-*-common`, plus jest for changed packages. Run `node scripts/check_changes.ts`."
    status: pending
isProject: false
---

# Zod v3 for the Security Solution generated graph

## Why we widened the scope

The earlier "rule_schema island" attempt (see [`zod_v3_cross_version_composition.md`](.cursor/plans/zod_v3_cross_version_composition.md)) ran into a structural problem: a folder boundary doesn't survive cross-folder schema composition, so the generator had to grow several knobs (per-YAML `x-zod-flavor`, primitive inlining, per-helper detection) **and** the consumer cascade still hit ~350 hand-written files / 1,627 errors inside `security_solution`.

Flipping the entire OpenAPI-generated graph that lives under `x-pack/solutions/security/**` to v3 trades all that generator complexity for a simpler invariant — *"every `.gen.ts` inside the security tree is v3, the rest of Kibana stays v4"* — at the cost of doing the consumer flip across the whole security tree instead of just one folder. The consumer cascade is the same order of magnitude (~500–800 files) because the previous narrow island already pulled in most of detection_engine.

Crucially, **a grep confirms that no plugin outside `x-pack/solutions/security/**` value-imports a security_solution `.gen.ts`** (search `@kbn/security-solution-plugin/common/api/*.gen` returns zero hits outside the security tree). That makes "security solution only" a real boundary.

## Architecture: hybrid v3 + v4 facade

| Tier | Generator settings | Consumer behaviour |
| --- | --- | --- |
| **`security_solution/scripts/openapi/generate.js`** plain outputs (under `security_solution/common/api/**`) | `zodFlavor: 'v3'` | Consumers in `security_solution/{common,server,public}` flip to `@kbn/zod/v3`. No facade — single-flavor inside the plugin. |
| **`security_solution/scripts/openapi/generate.js`** bundled outputs (under `packages/test-api-clients/supertest/*.gen.ts`) | `zodFlavor: 'v3', emitV4Facade: true` | Internal security tests can use either; external test consumers (if any) keep working through the v4 facade. |
| **`kbn-securitysolution-{exceptions,lists,endpoint-exceptions}-common/scripts/openapi_generate.js`** | `zodFlavor: 'v3', emitV4Facade: true` | Shared packages: `security_solution` plugin imports v3 schemas directly; `lists` plugin (and any other consumer that currently composes them in v4 chains) imports the v4 facade. |
| All other Kibana OpenAPI generators (osquery, kbn-elastic-assistant-common, kbn-evals-common, anonymization-common) | unchanged (`zodFlavor` defaults to `'v4'`) | Untouched. |

This keeps the generator change to a single new optional argument plus an optional facade emitter; nothing is global, nothing is YAML-document-level.

## Generator changes (`@kbn/openapi-generator`)

### 1. `zodFlavor: 'v3' | 'v4'` (default `'v4'`)

- Added to the public `generate()` signature in [`@kbn/openapi-generator`](src/platform/packages/shared/kbn-openapi-generator/src/openapi_generator.ts).
- Threaded through the generation context as `zodImportFlavor`.
- [`zod_operation_schema.handlebars`](src/platform/packages/shared/kbn-openapi-generator/src/template_service/templates/zod_operation_schema.handlebars) emits `import { z } from '@kbn/zod/{{zodImportFlavor}}'` and (when any helper is needed) `from '@kbn/zod-helpers/{{zodImportFlavor}}'`.

### 2. `emitV4Facade: boolean` (default `false`)

When `zodFlavor === 'v3' && emitV4Facade === true`, the generator emits a sibling `<base>.gen.v4.ts` file alongside each `<base>.gen.ts`. The companion file:

- imports `z` from `@kbn/zod/v4`.
- imports each schema from `./<base>.gen` and re-exports a v4 facade:
  ```ts
  import { z } from '@kbn/zod/v4';
  import { RuleResponse as RuleResponseV3, type RuleResponse as RuleResponseType } from './rule_response.gen';
  export type RuleResponse = RuleResponseType;
  export const RuleResponse = z.custom<RuleResponseType>((value) => RuleResponseV3.safeParse(value).success);
  ```
- preserves the same export names so consumer code can do `import { RuleResponse } from '@kbn/securitysolution-exceptions-common/api/.../foo.gen.v4'` with no symbol renames.

### 3. `removeGenArtifacts` companion cleanup

[`removeGenArtifacts`](src/platform/packages/shared/kbn-openapi-generator/src/lib/remove_gen_artifacts.ts) currently deletes `**/*.gen.ts`. Extend it to also delete `**/*.gen.v4.ts` so re-runs stay deterministic when `emitV4Facade` is toggled off.

### 4. Per-helper import detection

Replace the coarse `useZodHelpers: boolean` context flag with per-helper flags driven by schema shape:

- `useIsValidDateMath` — set when any field has `format: date-math`.
- `useIsNonEmptyString` — set when any string has `format: nonempty` or `minLength: 1` plus the non-empty refinement convention.
- `useArrayFromString`, `useBooleanFromString` — set when query parameter coercions are emitted.

Template lists only the helpers that are actually used. This eliminates the pre-existing `no_unused_imports` ESLint failures that surface the moment generated files are regenerated, so post-generation `eslint --fix` works cleanly.

## Per-script changes

### `security_solution/scripts/openapi/generate.js`

Edit each of the five `generate()` calls (see [the script](x-pack/solutions/security/plugins/security_solution/scripts/openapi/generate.js)):

- Calls 1 (`'API route schemas'`) and 5 (`'API client for quickstart'`): `zodFlavor: 'v3'`. No facade — outputs are consumed inside the plugin only.
- Calls 2–4 (`api_client_supertest` bundles to `packages/test-api-clients/supertest/{detections,endpoint_management,entity_analytics,timelines}.gen.ts`): `zodFlavor: 'v3', emitV4Facade: true`. The bundled outputs are imported across security test packages and may be picked up by external test infrastructure.

### `kbn-securitysolution-{exceptions,lists,endpoint-exceptions}-common/scripts/openapi_generate.js`

Pass `zodFlavor: 'v3', emitV4Facade: true` to the `generate()` call(s) in each of:

- [`kbn-securitysolution-exceptions-common/scripts/openapi_generate.js`](x-pack/solutions/security/packages/kbn-securitysolution-exceptions-common/scripts/openapi_generate.js)
- [`kbn-securitysolution-lists-common/scripts/openapi_generate.js`](x-pack/solutions/security/packages/kbn-securitysolution-lists-common/scripts/openapi_generate.js)
- [`kbn-securitysolution-endpoint-exceptions-common/scripts/openapi_generate.js`](x-pack/solutions/security/packages/kbn-securitysolution-endpoint-exceptions-common/scripts/openapi_generate.js)

These three are the cross-plugin shared packages (consumed by `plugins/lists/**`), so the facade is the safety valve that keeps the cascade out of `lists`.

### Untouched scripts

- `x-pack/platform/packages/shared/kbn-elastic-assistant-common/scripts/openapi/generate.js`
- `x-pack/platform/packages/shared/kbn-evals-common/scripts/openapi/generate.js`
- `x-pack/platform/packages/shared/ai-infra/anonymization-common/scripts/openapi/generate.js`
- `x-pack/platform/plugins/shared/osquery/scripts/openapi/generate.js`

These keep the default `zodFlavor: 'v4'` and emit no facades.

## Consumer flip

### `security_solution` plugin tree

Switch every value-level import inside `x-pack/solutions/security/plugins/security_solution/{common,server,public}/**` and `x-pack/solutions/security/test/**` that uses `@kbn/zod` together with a `.gen.ts` schema to:

- `import { z } from '@kbn/zod/v3'`
- `import { isValidDateMath, isNonEmptyString, expectParseSuccess, expectParseError, stringifyZodError } from '@kbn/zod-helpers/v3'`

Type-only imports (`import type { ... } from '...gen'`) stay unchanged.

The flip is mechanical (codemod-able). The bulk lives in:
- `common/api/**` hand-written modules (route schemas, validators, mocks)
- `server/lib/detection_engine/**`
- `server/lib/siem_migrations/**`
- `server/lib/entity_analytics/**`
- `public/detection_engine/**`, `public/siem_migrations/**`, `public/entity_analytics/**`, `public/flyout/entity_details/**`
- security test suites under `x-pack/solutions/security/test/**`

### `lists` plugin

`plugins/lists/server/routes/**` currently composes `kbn-securitysolution-*-common` `.gen.ts` schemas in v4 chains. For each such file:

1. If the file just parses a schema (`Schema.safeParse(req.body)`), switch to `@kbn/zod/v3` and import the schema from the original `.gen.ts` path.
2. If the file uses the schema as a value inside a v4 `z.object`, `z.union`, `.merge`, `.extend`, `z.discriminatedUnion`, or `z.custom` chain, change the import path to the `.gen.v4` facade (same symbol name) and leave the surrounding code on `@kbn/zod` (v4).

Both options keep `lists` plugin compiling without forcing it onto v3.

## What is explicitly *not* changing

- The shared primitives ([`primitives.schema.yaml`](x-pack/solutions/security/plugins/security_solution/common/api/model/primitives.schema.yaml)) — no edits, no inlining. `primitives.gen.ts` flips to v3 along with the rest of the security_solution generated tree because it lives under `security_solution/common/api/**`. Nothing outside the security tree value-imports it (verified by grep).
- Other plugins' generators or generated outputs.
- The `@kbn/zod` default export — still `zod/v4`. Anywhere outside the security tree continues to get v4 from `@kbn/zod`.
- No new npm `zod@3.x` package — we use `zod/v3` (already exposed by Zod 4.x via [`node_modules/zod/package.json`](node_modules/zod/package.json) exports).

## Risks and edges

- **Cross-plugin re-exports of security `.gen.ts` symbols.** Anything outside the security tree that imports a symbol re-exported through a hand-written security barrel as a value would still hit cross-version issues. Mitigation: when flipping consumers in the security tree, audit barrels (`common/api/**/index.ts`) for value re-exports and either keep them type-only or expose the v4 facade alongside.
- **Shared package external consumers.** If anything outside `x-pack/solutions/security/**` ever imports a `kbn-securitysolution-*-common` `.gen.ts` symbol as a value, it will get the v4 facade automatically (same symbol name). The facade is a `z.custom<T>` so it accepts the type but only validates with the v3 schema underneath — runtime behaviour is identical, type behaviour is the same v4 shape.
- **Codemod fidelity.** The consumer flip is large enough that a scripted edit (e.g. a `jscodeshift` codemod that rewrites `from '@kbn/zod'` → `from '@kbn/zod/v3'` only in files that also import a `.gen` value) is worth the upfront investment.
- **Test helpers.** Tests using `@kbn/zod-helpers` need the same flip. The v3 helpers are already in place.

## Validation

- `node scripts/type_check --project x-pack/solutions/security/plugins/security_solution/tsconfig.json`
- `node scripts/type_check --project x-pack/solutions/security/plugins/lists/tsconfig.json`
- `node scripts/type_check --project x-pack/solutions/security/packages/kbn-securitysolution-exceptions-common/tsconfig.json` (and the other two shared packages)
- `node scripts/jest x-pack/solutions/security/plugins/security_solution` (scoped per affected area)
- `node scripts/check_changes.ts`
