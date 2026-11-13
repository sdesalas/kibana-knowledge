# Handoff — implement `bulkValidateActions` (#273680)

## TLDR

One new function, `bulkValidateActions`, merges `validateActions` and `validateAndAuthorizeSystemActions` into a single call over an array of rules, sharing one union `getBulk` across the whole array and returning the prefetched connector results. `extractReferences` and `denormalizeActions` each take an optional prefetched-actions param — use it when present, otherwise fall back to their own `getBulk` so nothing breaks. Wire it into bulk create, bulk update, single create, single update, and bulk edit, with the one wrinkle that bulk edit `add` and `delete` must pass the **post-merge** action set, not the op payload validate saw.

## 1. Motivation and context

Bulk (and single) rule create/update/edit paths in the Alerting `rules_client` repeatedly load the same connector saved objects from Elasticsearch. The cost shows up as `actionsClient.getBulk` → saved-objects `bulkGet` → ES `POST /_mget` on action documents. On a typical prepare path the same connector IDs are fetched up to three times per rule:

1. **`validateActions`** — loads connectors to check action groups, frequency, filters, secrets, etc.
2. **`validateAndAuthorizeSystemActions`** — loads system-action connectors again for type/authz/adapter checks.
3. **`extractReferences` → `denormalizeActions`** — loads the same IDs again to build `actionRef` / `actionTypeId` and SO references for persist.

Those four helpers (`validateActions`, `validateAndAuthorizeSystemActions`, `extractReferences`, `denormalizeActions`) are effectively **stateless** given rule type, rule data, and the actions list: they do not depend on each other’s side effects. In principle a **single union `getBulk`** of connector IDs can feed all of them. The hard part is not the helpers themselves — it is the **callers** around them (ordering with API keys/schedule, bulk-edit merge semantics, SIEM legacy validate-only paths, backfill’s direct `denormalizeActions`, error collect-vs-throw differences).

**Prior art:** commit [`d0483a20df2fa7e96cb7ecff036656185b69147f`](https://github.com/elastic/kibana/commit/d0483a20df2fa7e96cb7ecff036656185b69147f) — Steven de Salas, 2026-05-07, message “Add performance improvements,” 7 files (+642/−433). It added a Phase 0 `prefetchActions` path in bulk create (`bulk_create_rules.ts` / utils) and optional `preFetchedActions` plumbing into `extract_references.ts` and `denormalize_actions.ts` (and related validate helpers). That approach was later dropped; it remains the closest working sketch of prefetch + pass-through.

**Tracking / design writing:**

- Issue: https://github.com/elastic/kibana/issues/273680 — `[Alerting] Add bulkValidateActions to reduce connector lookups during bulk rule operations`
- Tradeoffs (Options A–E): `~/Code/sdesalas/kibana-knowledge/reports/bulk-create-rules/2026-06-17.bulk-validate-actions-tradeoffs.md`

Options **A–E** were evaluated in that document. **Option A** (a dedicated `bulkValidateActions` entry that owns a union fetch for the validators, with prefetch reused downstream) is the **chosen direction**, with refinements discussed during design (optional prefetch into extract/denormalize; reuse on single create/update; bulk-edit merge guards). Do not revive dropped side-branches beyond what A–E already document.

## 2. Option A — design and cons

**Design:** Option A introduces `bulkValidateActions` that **combines** `validateActions` and `validateAndAuthorizeSystemActions` behind **one shared union `getBulk`** across the rule array. It does **not** change `extractReferences` or `denormalizeActions`; those keep their own per-rule `getBulk` unless callers wire something extra.

**Cons (updated):**

1. **Does not cover `denormalizeActions`** unless the prefetched actions returned by `bulkValidateActions` are passed in as an optional parameter to `extractReferences` and `denormalizeActions`. The per-rule `getBulk` in denormalize remains, so the redundant `getBulk` / `_mget` problem persists for that leg unless wired separately.
2. **Two functions to keep in sync forever**, unless `bulkValidateActions` can also be used in the single create and update pathways — in which case this con does not stand. There is no compiler signal when they drift; only tests catch it, and only if tests exist for the specific check.

**Dropped variation (not in plan):** A related idea labeled **Option F** was discussed — `bulkValidateActions` returning prefetched actions and threading them through `extractReferences` / `denormalizeActions`. It was **dropped** as too similar to A (A plus an optional pass-through). **F is not part of the plan**; treat optional prefetch into extract/denormalize as an A wiring detail if pursued, not a separate option letter.

## 3. Option E — cons (self-contained)

Option E in the tradeoffs doc proposes a general entry point that runs all four steps (`validateActions` → `validateAndAuthorizeSystemActions` → `extractReferences` → `denormalizeActions`) behind one union `getBulk`. Even if A is the chosen direction, these E cons still constrain any design that returns or threads **prefetched** connector snapshots into later steps:

1. **Bulk-edit `add` / `delete` partial-set.** When bulk-editing the `actions` field with `add` or `delete`, `validateActions` and `validateAndAuthorizeSystemActions` only receive the **operation payload** — the connector IDs being added or removed. After `applyBulkEditOperation`, `extractReferences` runs on the **merged post-operation** list (existing injected actions ∪ new ones for `add`, or remaining actions after `delete`). A prefetch captured only at the validate step would therefore **miss pre-existing connector IDs** that extract still must resolve, producing wrong or missing saved-object references. **Guard:** prefetch the **post-merge** set, or re-fetch after applying the op — do not assume validate’s ID set equals extract’s.

2. **Freshness ownership.** `bulkValidateActions` (or any union prefetch) returns a **point-in-time snapshot** of connector saved objects. Every downstream caller that skips a fresh `getBulk` is trusting that snapshot. If anything between validate and extract could mutate or replace the rule’s action data (or if connectors change concurrently in ES), the snapshot can be **stale**. Callers must treat returned prefetched actions as potentially stale and know when a re-fetch is required.

3. **Paths outside a four-step shape.** Bulk-edit operations on **non-actions** fields (tags, schedule, snooze, `apiKey`, …) **never call** the validators, yet `extractReferences` still runs on the injected post-migrate action set. If extract accepts prefetched actions, that site must **seed from `injectReferencesIntoActions`**, not from a prior validate. Separately, the SIEM legacy path in `transform_and_delete_legacy_actions.ts` validates **sidecar-transformed** actions only and has **no** `extractReferences` call of its own; its callers mutate saved-object attributes. That path sits **outside** the validate→extract prefetch question entirely (carve-out / leave on fallback).

## 4. Per-site freshness inventory (validate → extract)

Base path: `x-pack/platform/plugins/shared/alerting/server/`.  
Question: if extract/denormalize take **prefetched** connectors from a prior validate-time `getBulk`, is the **rule action ID list** the same object/lineage, or must callers guard?

No production site reloads actions via `rulesClient.get` between validate and extract. Connector SO content races under concurrent writers are orthogonal (snapshot freshness — §3.2).

### `validateActions` — def `rules_client/lib/validate_actions.ts:28` (`getBulk` ~:59)

| # | Site | Lines | Actions seen | → extract? | Verdict |
|---|---|---|---|---|---|
| 1 | `application/rule/methods/create/create_rule.ts` | 193 | Request `data.actions` / `systemActions` | Yes (:226) — same request list | **safe** |
| 2 | `application/rule/methods/update/update_rule.ts` | 196 | Request `data` | Yes (`updateRuleAttributes` :315) — request `updateRuleData`; `bulkMigrateLegacyActions` mutates **SO attrs** only | **safe** |
| 3 | `application/rule/methods/bulk_create/utils.ts` (`prepareRule`) | 57 | Same `data` after `addGeneratedActionValues` | Yes (:100); API key mint in between does not touch actions | **safe** |
| 4 | `application/rule/methods/bulk_update/utils.ts` (`prepareUpdate`) | 134 | Same `data` | Yes (:170); sync schedule checks only | **safe** |
| 5 | `application/rule/methods/bulk_edit/bulk_edit_rules.ts` (actions op) | 296 | **`genActions` / `genSystemActions` = op value only** | Yes — via `update_rule_in_memory.ts:171` on **`updatedRuleActions`** after `applyBulkEditOperation` | **`set`: safe.** **`add`/`delete`: needs guard** (partial-set vs post-merge) |
| 6 | `bulk_edit_rules.ts` (`attemptToMigrateLegacyFrequency`) | 475 | Same `genActions` retry after clearing rule-level `notifyWhen`/`throttle` | Indirect (same edit path) | **safe** for ID set vs first validate; does not remove add/delete guard |
| 7 | `rules_client/lib/siem_legacy_actions/transform_and_delete_legacy_actions.ts` (`validateTransformedActions`) | 339 | Sidecar-transformed actions only | **No** extract pairing | **unpaired** — not a prefetch source for extract |

### `validateAndAuthorizeSystemActions` — def `lib/validate_authorize_system_actions.ts:23` (`getBulk` ~:49)

| # | Site | Lines | Input | Same IDs as extract? | Verdict |
|---|---|---|---|---|---|
| 1 | `create/create_rule.ts` | 197 | `data.systemActions` | Yes — folded into `allActions` | **safe** |
| 2 | `update/update_rule.ts` | 197 | `data.systemActions` | Yes | **safe** |
| 3 | `bulk_create/utils.ts` | 59 | `data.systemActions` | Yes | **safe** |
| 4 | `bulk_update/utils.ts` | 136 | `data.systemActions` | Yes | **safe** |
| 5 | `bulk_edit/bulk_edit_rules.ts` | 286 | `genSystemActions` (op only) | `set`: yes; `add`/`delete`: merged/remaining may differ | **`set` safe; `add`/`delete` needs guard** |

### `extractReferences` — def `rules_client/lib/extract_references.ts:17` → `denormalizeActions`

| # | Site | Lines | Actions source | Preceding validate? | Verdict |
|---|---|---|---|---|---|
| 1 | `create/create_rule.ts` | 226 | `[...data.actions, ...systemActions]` | Yes | **safe** — pass validate-time prefetch |
| 2 | `update/update_rule.ts` | 315 | `updateRuleData` actions | Yes (earlier in `updateRule`) | **safe** |
| 3 | `bulk_create/utils.ts` (`prepareRule`) | 100 | same `data` | Yes | **safe** |
| 4 | `bulk_update/utils.ts` (`prepareUpdate`) | 170 | same `data` | Yes | **safe** |
| 5 | `rules_client/common/bulk_edit/update_rule_in_memory.ts` | 171 | `updatedRuleActions` after ops (every **non-skipped** rule) | Only if an `actions` field op ran | **`set` safe; `add`/`delete` guard; non-actions: never validates before extract** — seed from `injectReferencesIntoActions` |

### `denormalizeActions` — def `rules_client/lib/denormalize_actions.ts:15` (`getBulk` ~:26)

| # | Site | Lines | How reached | Verdict |
|---|---|---|---|---|
| 1 | `rules_client/lib/extract_references.ts` | 34 | All extract callers above (incl. `prepareRule` / bulk create) | Today always internal `getBulk`; optional prefetch later with fallback |
| 2 | `backfill_client/backfill_client.ts` | 696 | **Direct** — no validate/extract pairing | Leave fallback / follow-up |

### Bulk-edit actions op — between validate and extract

Flow in `bulk_edit_rules.ts` → `update_rule_in_memory.ts`:

1. Validate/system on **op payload** (`genActions` / `genSystemActions`) — lines ~286–300.
2. Optional `attemptToMigrateLegacyFrequency` (second validate on same `genActions`) — :475.
3. **Sync** `applyBulkEditOperation` → updates `updatedRuleActions` (`set` / `add` / `delete`) — ~312–320.
4. Schedule check (sync).
5. Return into `updateRuleInMemory`: optional async **`paramsModifier`** / param authz — **no action reload**.
6. `extractReferences(updatedRuleActions, …)` — :171 → `denormalizeActions` (internal `getBulk` today).

`updatedRuleActions` is what extract sees; for `add`/`delete` it is **not** the same ID set validate saw.

### Rollup

| Path | Verdict |
|---|---|
| create / update / bulk create / bulk update | **safe** — same in-memory action list through extract |
| Bulk edit `set` actions | **safe** |
| Bulk edit `add` / `delete` actions | **needs guard** — prefetch post-merge (or re-fetch) |
| Bulk edit non-actions | **never validates** before extract |
| SIEM legacy `validateTransformedActions` | **no extract pairing** |

## 5. Bulk edit specifics and `bulkValidateActions` design

### Bulk edit — what validate vs extract see

| Op | Validate / system-authorize see | Extract / denormalize see | Prefetch |
|---|---|---|---|
| **`add`** | New actions only (op payload) | Existing injected actions **plus** new | **Guard** — post-merge IDs |
| **`delete`** | Items being removed (op payload) | Remaining after `deleteItemsFromArray` | **Guard** — post-delete IDs |
| **`set`** | Op payload | Same set after apply | **Safe** |
| **Non-actions** (tags, schedule, snooze, `apiKey`, …) | No validate | Injected actions **plus** any prior actions-op result in `updatedRuleActions` | Seed from inject / post-op list, not from validate |

**Between validate and extract on actions ops:** sync `applyBulkEditOperation` → schedule check → optional async `paramsModifier` / param authz (no action reload). `updatedRuleActions` flows into `paramsModifier` / param authz, then `extractReferences(updatedRuleActions)`.

### `bulkValidateActions` design (chosen plan)

- Takes an **array of rules** (length can be **1** for single `createRule` / `updateRule`).
- Runs **both** validator steps (`validateActions` + `validateAndAuthorizeSystemActions`) with **one union `getBulk`** of connector IDs across the array.
- **Returns `prefetchedActions`** for reuse downstream.
- **Used in:** bulk create, bulk update, single create, single update, and bulk edit (with post-merge prefetch for `add`/`delete`).
- **`extractReferences` and `denormalizeActions`** gain an **optional** `prefetchedActions` parameter. If absent → **fallback** to a second `getBulk` (backward compatible).

## 6. Suggested implementation order and links

1. Implement **`bulkValidateActions`** (union `getBulk` + both validators; return `prefetchedActions`). Prefer shared in-memory checks to avoid drift with `validateActions`.
2. Wire **bulk create** and **bulk update** (batch-level union).
3. Wire **single `createRule`** and **`updateRule`** (N=1 through the same entry — kills the “two functions forever” con).
4. Wire **bulk edit** with merge handling (`set` safe; `add`/`delete` prefetch **post-merge** IDs).
5. Add optional **`prefetchedActions?`** on **`extractReferences`** / **`denormalizeActions`** (absent → fallback `getBulk`). Can land earlier if it unblocks wiring; must exist before callers pass the snapshot.

Typecheck alerting; Jest touched packages. Bench wall clock (scenarios #9/#12) before claiming the AC win.

### Links

- Tradeoffs (Options A–E): `~/Code/sdesalas/kibana-knowledge/reports/bulk-create-rules/2026-06-17.bulk-validate-actions-tradeoffs.md`
- Issue: https://github.com/elastic/kibana/issues/273680
- Epic / Bulk Primitives: https://github.com/elastic/kibana/issues/264906
- Prior art: https://github.com/elastic/kibana/commit/d0483a20df2fa7e96cb7ecff036656185b69147f — Steven de Salas, 2026-05-07, “Add performance improvements” (Phase 0 `prefetchActions`; optional `preFetchedActions` on extract/denormalize)
- Design-comment locations patch: `.knowledge/patches/2026-11-13.273680-bulk-validate-actions-design-comments.patch` — list of `// HERE:` comments marking the call sites that need updating (helps Steven navigate the locations).
- Earlier quick handoff: `~/Code/sdesalas/kibana-knowledge/handoff/handoff-2026-11-13-1458-bulk-validate-actions.md`
- Wall bench guide: `~/Code/sdesalas/kibana-knowledge/guides/detection_rule_wall_bench.md`

**Goal:** one `bulkValidateActions` union `getBulk` for both validators, with optional prefetch into extract/denormalize, wired across create/update/bulk create/bulk update/bulk edit (post-merge guard on edit add/delete).
