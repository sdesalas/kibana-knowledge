# Bulk Rule Import (Create Path) via `bulkCreateRules` — Risks & Open Questions

**Date**: 2026-06-30
**Ticket**: [#264909](https://github.com/elastic/kibana/issues/264909) — [Security Solution] Optimize bulk rule `_import` (create path) via bulkCreate
**Epic**: #264906 · **Depends on**: #264893 (merged in #269340) · **Follow-up**: #275204 (update path) · **Related**: #249176 (import timeout)
**Reference patch**: `.knowledge/patches/wiring-for-bulk-create-and-changes-history.patch` (import portions only)
**Branch**: `optimize-rule-bulk-import-create-path`

---

## Summary

Wire `POST .../rules/_import` so *new* rules go through a single `rulesClient.bulkCreateRules()` call instead of the per-rule loop, behind a new `bulkCreateRulesEnabled` experimental flag. Existing rules (with `overwrite: true`) keep the per-rule `importRule` fallback; the bulk update path is deferred to #275204. Expected ~3x speedup.

The mechanics are sound and the flag defaults off, so production is unaffected until enabled. The risks below are mostly about **behavior parity** between the new bulk path and the established per-rule path, plus a couple of scaling/contract concerns.

---

## Context: import size is already capped

- `maxRuleImportPayloadBytes` default = **10 MB** (`server/config.ts:27`).
- `maxRuleImportExportSize` default = **10000 rules** (`server/config.ts:26`).
- 10 MB ≈ **~1000 rules without connectors** in practice.

So the vast majority of customers never approach 1000 rules, let alone 10000. Anyone importing more has deliberately tuned `maxRuleImportPayloadBytes` / `maxRuleImportExportSize` and is operating their cluster accordingly. **In that light the alerting-side `MAX_RULES_NUMBER_FOR_BULK_OPERATION = 10000` limit is reasonable** and not a practical blocker.

---

## Correctness risks

### 1. Whole-batch failure replaces per-rule failure  (Medium)
`bulkCreateRules` (`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`) throws `Boom.badRequest` for the **entire** call in three cases the per-rule loop handled individually:
- total `> MAX_RULES_NUMBER_FOR_BULK_OPERATION` (10000),
- `bulkEnsureAuthorized` — any unauthorized ruleType/consumer pair fails *all* rules,
- `validateScheduleLimit` — one enabled rule that trips the schedule-limit circuit breaker fails *all* rules.

Today, one bad/unauthorized rule still lets the rest succeed. After this change it can 400 the whole import.
**Mitigation**: have `bulkImportRules` catch these Boom throws and convert to per-rule import errors so partial-success semantics are preserved, or consciously accept the stricter behavior and document it.

### 2. Validation / error-message parity  (Medium — highest test-breakage risk)
Schema validation moves into alerting's `preValidate` (`createRuleDataSchema`) rather than the security layer. Error messages and status codes for malformed rules may differ from the per-rule path. Existing import **API integration tests assert exact messages/status codes** in several places.
**Mitigation**: run the existing import suites against the new path early; reconcile any message/status differences before adding new tests.

### 3. Conversion parity  (Medium)
The bulk path builds alerting data with `applyRuleDefaults` + `convertRuleResponseToAlertingRule`; the per-rule create path uses its own mergers. Confirm equivalent output for the tricky fields:
- response actions / osquery,
- system actions (`addGeneratedActionValues`),
- throttle,
- `exceptions_list`.

Easy to silently drop a field here. Worth an explicit field-by-field diff plus targeted tests.

### 4. `findRules` KQL OR-list scaling  (Low/Medium)
Conflict detection is a single query: `alert.attributes.params.ruleId: ("a" OR "b" OR ...)`. At the upper bound (thousands of rule_ids) this is a large bool query that can hit ES `indices.query.bool.max_clause_count`. Given the size cap above, realistic imports stay well under this, but a tuned large-import deployment could trip it — exactly the case #249176 cares about.
**Mitigation**: batch the conflict lookup (e.g. chunk rule_ids) rather than one giant filter.

---

## Behavior changes (intentional, but call out)

### 5. Concurrency limiter is unconditional  (Decision needed)
In the patch, `routeLimitedConcurrencyTag(RULE_MANAGEMENT_IMPORT_CONCURRENCY = 1)` is added to the route options, **not** gated by `bulkCreateRulesEnabled`. Merging this serializes **all** rule imports to one-at-a-time per Kibana process (excess requests rejected), even with the flag off. This affects DaC/CI users running parallel imports.
**Decision**: keep it global (intended memory hardening) or gate it behind the flag.

### 6. Peak memory from `ruleChunks.flat()`  (Low/Medium)
The old loop processed 50-rule chunks and let each go out of scope; the new path flattens everything and builds the full `bulkInputs` array (converted alerting data + applied defaults) before alerting re-batches internally. For large imports with big exception lists, peak heap rises — the same failure mode as #249176. The size cap bounds this in practice, but keeping `bulkImportRules` internally chunked would be safer than one flat call.

### 7. Enabled imported rules take a new path  (Low)
Old import created rules disabled then bulk-enabled tasks afterward; the new path lets `bulkCreateRules` mint API keys + schedule tasks inline. Functionally better, but it's a different path — integration tests should confirm enabled imports actually schedule and run.

### 8. Audit log shape  (Low)
New path emits `BULK_CREATE` audit events instead of per-rule `CREATE`. Anything consuming audit logs sees a different shape.

---

## Open questions

1. **Partial success vs whole-batch throw** (ties to risk #1): do we preserve today's partial-success behavior by catching Boom throws inside `bulkImportRules`?
2. **TOCTOU window**: conflict detection now runs once up-front for the whole batch, and SO ids are random uuids (the SO layer doesn't enforce `rule_id` uniqueness). Slightly wider race than the per-rule `getRuleByRuleId`-then-create. Pre-existing weakness — accept it?
3. **`bulkCount` semantics in change history**: set to `rules.length` (total, incl. overwrites/conflicts) on the create branch, while overwrites log their own history via `rulesClient.update`. Confirm that's the intended count.
4. **Limiter scope**: should `RULE_MANAGEMENT_IMPORT_CONCURRENCY` be flag-gated (see #5)?

---

## Recommendation

Proceed. The `MAX_RULES_NUMBER_FOR_BULK_OPERATION = 10000` limit is fine given the import size cap (10 MB payload ≈ ~1000 rules without connectors; larger imports require deliberate tuning). Prioritize, in order:
1. **Parity** — run existing import integration tests against the new path (#2, #3) before writing new tests.
2. **Whole-batch failure handling** — decide partial-success vs strict, implement accordingly (#1).
3. **Limiter gating decision** (#5).
4. Internal chunking of the conflict lookup and bulk-create call as a safety margin for tuned large imports (#4, #6).

---

## Appendix: Why `bulkImportRules()` looks complex (block-by-block mapping)

A common reaction is that `bulkImportRules()` carries far more logic than the simple single-rule `importRule`. It does not do more *work* — it does the **same** work that today is spread across four layers, collapsed into one function, plus two genuinely new bits forced by batching.

### Today's per-rule path is 4 layers, not 1

```
import_rules.ts (orchestrator)      ← loops chunks, maps responses to status codes
  └─ methods/import_rules.ts (DRC)  ← per-chunk prep, loops rules
       └─ methods/import_rule.ts    ← per-rule conflict check + create/update decision
            └─ methods/create_rule.ts ← shapes rule→alerting data, calls rulesClient.create
```

`bulkImportRules()` flattens layers 2–4 into itself, which is why it looks heavier — most of it is pre-existing code, relocated and turned from "per rule" into "per array".

### Block-by-block

| Block in `bulkImportRules()` | Equivalent in the per-rule path |
|---|---|
| `if (rules.length === 0) return` | orchestrator `import_rules.ts` empty-chunks guard |
| `getReferencedExceptionLists({ rules })` | `methods/import_rules.ts:45` — identical |
| `ruleSourceImporter.setup(rules)` | `methods/import_rules.ts:49` — identical |
| prepare: version default | `methods/import_rules.ts:56-58` — identical |
| ↳ `ruleToImportHasVersion` check | `methods/import_rules.ts:60-72` — identical |
| ↳ `validateMlAuth` (cached per type) | `methods/import_rule.ts:47` — same call per rule; bulk dedupes per type |
| ↳ `checkRuleExceptionReferences` | `methods/import_rules.ts:74-78` — identical |
| ↳ `calculateRuleSource` | `methods/import_rules.ts:80` — identical |
| **conflict detection (`findRules` OR-list)** | `methods/import_rule.ts:49` `getRuleByRuleId` per rule. **Bulk replaces N lookups with 1.** |
| classify conflict / overwrite / create | `methods/import_rule.ts:54-84` — same three-way decision, materialized into arrays |
| push conflict error | `methods/import_rule.ts:54-60` — same error object, pushed instead of thrown |
| overwrite branch (`pMap` → `importRuleSingle`) | **calls the same `importRule`** — no optimization, deferred to #275204 |
| build `bulkInputs` (`applyRuleDefaults` + `convertRuleResponseToAlertingRule` + `alertTypeId`/`consumer`/`enabled`) | `methods/create_rule.ts:43-52` — **identical shaping**, inline over an array |
| `rulesClient.bulkCreateRules(...)` | `create_rule.ts:54` `rulesClient.create(...)` — N calls → 1 |
| **uuid map + re-pair `successfulIds`/`errors` → `rule_id`** | **no equivalent** (see below) |

### The only genuinely-new complexity

Both are forced by batching (scatter/gather):

1. **Batched conflict detection** — `escapeKql` + `params.ruleId: ("a" OR "b" …)` + `existingByRuleId` map. This is the ticket's whole point: N `getRuleByRuleId` round-trips become one `findRules`.
2. **uuid re-pairing** — `rulesClient.bulkCreateRules()` returns a flat `{ successfulIds, errors }` keyed by SO id, not full rule bodies tied to inputs. The per-rule path gets that mapping free (each `importRule` returns its own `RuleResponse` 1:1). In bulk we pre-assign a uuid per rule and map results back to `rule_id`.

### Why it can't be as thin as `importRule`

- Conflicts/overwrites/`rule_source`/exceptions are security-domain logic; `bulkCreateRules` knows none of it, so it must happen before the call — same as today.
- Overwrite isn't batched yet (no `bulkUpdate`, #275204), so existing rules must keep the per-rule `importRule` — hence the dual branch.
- We bypass `createRule` and call `rulesClient.bulkCreateRules` directly, so we lose the data-shaping `createRule` did for us and inline it. Extracting that shaping into a shared helper is the one real refactor lever.

---

## Appendix: Self-critique — what we probably don't need

Honest root cause: the first implementation ported the reference patch wholesale instead of questioning each piece. The patch was a "prove it works" spike, and its ceremony got carried into the implementation. Candidates to cut:

### Stuff to cut

1. **Per-type ML-auth caching.** Premature optimization. `cacheMlAuthError` + the `checkedTypes` Set + `mlAuthErrorByType` Map exist to avoid re-calling `validateMlAuth`, but that's an in-memory license/capability check, not a round trip. The existing `importRule` just calls it per rule. ~25 lines of state for a non-cost — call it per rule.

2. **`__testing_escapeKql` + its 3 unit tests.** Exporting an internal purely for tests is a smell, and 3 string-escape assertions are low value. Worse: `escapeKql` + the `params.ruleId: (...)` OR-list was hand-rolled without first checking how `getRuleByRuleId` builds its rule_id filter. `findRules` already has a `ruleIds` param + `enrichFilterWithRuleIds` helper (targets `alert.id`, not `params.ruleId`, so not a drop-in — but the rule_id-KQL convention is likely already centralized and should be reused instead of inventing escaping).

3. **Bespoke FTR boot config for a default-off flag.** The most expensive item. A new Kibana-boot config + manifest entry burns CI minutes and adds flake surface to test a flag that's off in production. Unit tests already cover every branch; the existing import suite covers the per-rule path. Better: fold bulk assertions into the existing suite when the flag goes permanent, or skip until then. This was driven by "the plan said add API integration tests," not by cost/benefit.

4. **Concurrency limiter + `timeouts.ts`→`constants.ts` rename, in this PR.** Scope creep (same as risk #5). It's unconditional — hits everyone including flag-off — and has nothing to do with "use bulkCreate." Ship it separately.

5. **Duplicate change-tracking tests.** `bulk_import_rules.test.ts` already asserts the `ruleImport` action + `bulkCount` forwarding; the two additions in `change_tracking.test.ts` re-assert the same thing. Pick one home.

6. **`emptyResult()` helper and `PrepareRuleArgs`/`PrepareRuleResult` ceremony.** `emptyResult()` is a one-liner used twice — inline it. `prepareRuleForImport` with two dedicated interfaces is more structure than a single prep loop warrants.

Trimming 1, 2, 5, 6 likely drops 60–80 lines and reads closer to "prep → bulk conflict check → classify → bulk create + re-pair." Items 3 and 4 are PR-scope calls — both should probably leave this PR.

### Stuff NOT to cut (defensible)

- **Conflict detection** — required for `rule_id` uniqueness / 409 semantics; SO ids are random uuids, nothing else enforces it.
- **uuid re-pairing** — not optional; `bulkCreateRules` returns flat `successfulIds`/`errors` keyed by SO id, no rule bodies.
- **Dual overwrite branch** — overwrite can't be batched until `bulkUpdate` exists (#275204); per-rule `importRule` for overwrites is the scope line, not gold-plating.

---

## Appendix: Design Q&A

### KQL injection in the conflict `findRules` filter

`rule_id` is `z.string()` — free-form, so a `"` or `\` can appear and break out of the quoted literal in `params.ruleId: ("a" OR ...)`.

- **It's KQL, not a `query_string`.** Parsed to an AST by `@kbn/es-query`, scoped by alerting `find` to the `alert` SO type + the user's space + RBAC. It **cannot mutate data** — far smaller blast radius than SQL injection. No cross-tenant read either; `find` only returns rules the user can already see.
- **Worst realistic case is robustness, not security**: a malformed `rule_id` causes a KQL parse error → the single OR-list lookup throws → the *whole* batch import fails. The per-rule `getRuleByRuleId` path only fails that one rule. The OR-list batching widened the blast radius of a bad id.
- **Classification is self-correcting**: results are re-keyed by exact `rule_id` equality (`existingByRuleId.has(p.rule.rule_id)`), so extra matches from a manipulated filter are ignored — no unrelated rule is wrongly overwritten.
- **Two conventions in-tree**: raw interpolation (`getRuleByRuleId`, `read_rules`, `get_export_by_object_ids`, `prebuilt_rule_objects_client` — some don't even quote) vs. the escaped helper `prepareKQLStringParam` in `common/utils/kql.ts` (used by the newest code: agent-builder `find_rules_tool`, prebuilt installation KQL, rule filtering). `prepareKQLStringParam` was built for user-typed search input.
- **Decision**: left raw, matching the established `getRuleByRuleId` rule_id convention. Not re-adding a bespoke `escapeKql`.

### Why `pMap` (capped) for overwrite vs. `Promise.all` in `import_rules.ts`

Concurrency bound lives in different places:
- Old per-rule path is bounded by **chunking** — the route chunks at `CHUNK_PARSED_OBJECT_SIZE = 50`, the orchestrator loops chunks sequentially, and `import_rules.ts` does `Promise.all` over **one 50-rule chunk**. So ≤50 in flight at any moment; chunk size is the implicit limiter.
- The bulk path **flattens all chunks** into one array (to make a single `findRules` + single `bulkCreateRules` call), which discards that bound. A naive `Promise.all` over all overwrites could fan out thousands of concurrent `importRuleSingle` calls (each a find + update + maybe enable), hammering ES and spiking heap.
- `pMap(..., { concurrency: OVERWRITE_FALLBACK_CONCURRENCY })` re-introduces the cap that flattening removed. Same goal, different mechanism.

### Why reuse `importRuleSingle` for overwrite instead of `rulesClient.update()` directly

The overwrite path is not just an update. `importRule` wraps four correctness-critical steps around `rulesClient.update`:
1. `applyRuleUpdate` — merges imported fields onto the existing rule; for prebuilt rules pulls the base asset via `prebuiltRuleAssetClient`.
2. re-applies `rule_source` / `immutable` overrides (which `applyRuleUpdate` otherwise prefers from the existing rule).
3. `toggleRuleEnabledOnUpdate` — `update` strips `enabled`, so enable/disable is a separate call.
4. both-direction `RuleResponse` ↔ alerting-rule conversions.

Calling `rulesClient.update()` directly means duplicating all of that and risking drift from canonical import behavior. Reuse gives byte-for-byte overwrite parity for free. **Cost**: `importRuleSingle` runs its own `getRuleByRuleId` find per rule — a redundant round-trip since the batched lookup already confirmed existence. Accepted because overwrites are the less-common path (and `pMap`-capped); new rules — the hot path this ticket targets — skip all of it via the single `bulkCreateRules` call. The asymmetry is intentional: bulk-create the wins, reuse the proven per-rule path for overwrites.

---

## Appendix: Self-critique round 2 — holes in the design reasoning

Plain-language version of four weak spots in the arguments above:

### 1. The "one bad rule_id fails the whole import" problem is still unsolved
A `rule_id` can contain any character. If one contains a stray quote, the single OR-list query (`params.ruleId: ("a" OR "b" OR ...)`) may fail to parse, and **that one bad id takes down the conflict check for every rule in the import**. The old per-rule path only failed the one bad rule. Two separate things got blurred together when this was waved off: (a) a manipulated filter matching *extra* rules is harmless — we re-check exact `rule_id` equality afterward, so nothing wrong gets overwritten; but (b) a filter that won't *parse* throws and kills the batch. Point (a) was used to dismiss point (b); they're unrelated. And nobody has actually tested whether a quote in a `rule_id` really does break the query — it's assumed, not verified.

### 2. The concurrency numbers don't match the story  (resolved)
The overwrite branch was justified as "restore the ~50-at-a-time limit the old chunked code had," but the limit was set to **10**, not 50 — 5x stricter with no reason. Fixed: `OVERWRITE_FALLBACK_CONCURRENCY` is now **50** to actually match `CHUNK_PARSED_OBJECT_SIZE`.

### 3. The "optimization" may not help — or may hurt — the most common real workflow
Detection-as-Code pipelines re-import the same ruleset constantly. That's an **all-overwrite** import, and overwrites don't use the fast bulk path. Worse, the overwrite path reuses `importRuleSingle`, which looks each rule up again with its own `getRuleByRuleId` — even though the batched lookup already found it. So a re-import does: 1 batched find + **N redundant per-rule finds** + N updates + N enable-toggles, all throttled to 10 at a time. The old path did N finds + N updates at ~50 at a time. For re-imports this change does *more* work at *lower* concurrency — a likely **regression**. It was dismissed as "the less-common path" without checking whether that's actually true; for DaC it's the main path.

### 4. The parity bar is applied to one branch but not the other
The overwrite branch eats N redundant lookups specifically to get exact behavior parity by reusing `importRule`. The create branch does the opposite — it hand-rolls the rule-shaping (`applyRuleDefaults` + `convertRuleResponseToAlertingRule`) instead of reusing `createRule`, and that hand-rolled shaping is exactly what risk #3 (conversion parity) warns about. So parity is treated as non-negotiable on overwrite and optional on create. The consistent fix is to extract `createRule`'s shaping into a shared helper and use it on both sides — the refactor named in the first self-critique but not done.

**Net**: the conflict-lookup win (N finds → 1) is real for genuinely-new rules. For re-imports the design may break even or regress, and its internal consistency was oversold. Before calling this an optimization: (a) actually test a malformed `rule_id`, (b) reconcile the `10` vs `50` concurrency, (c) reason about / measure the overwrite-heavy case.
