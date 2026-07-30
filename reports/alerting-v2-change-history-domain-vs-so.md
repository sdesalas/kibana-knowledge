# Alerting V2: change-history snapshots as `RuleResponse`, not SO attrs

**Scope:** How alerting v2 records rule state in `.kibana_change_history`, how that differs from `RuleSavedObjectAttributes`, future SO migrations, and restore-from-delete.  
**Date:** 2026-07-30  
**Code base:** `alerting_v2` on branch with rule change-history integration  
**Verified against:** current code on that branch (not design intent alone)

---

## Two shapes (there is no `RuleDomain` type)

| | Persistence | Domain / API |
|--|--|--|
| Type | `RuleSavedObjectAttributes` | `RuleResponse` |
| Package / file | `alerting_v2` SO schemas (`@kbn/config-schema`) | `@kbn/alerting-v2-schemas` (zod) |
| Role | What Elasticsearch stores on the rule SO | What the public API returns; intended shape of change-history snapshots |

They are kept as **separate types on purpose** so storage can diverge from the API without forcing every consumer (including history) to absorb SO-only details.

Rule **content** fields are nearly 1:1 today. History snapshots are a **superset** of SO attrs:

| Field | SO attrs | `RuleResponse` / snapshot |
|--|--|--|
| Rule content (`kind`, `metadata.*`, `query`, …) | yes | yes (via explicit map) |
| `metadata.version` (monotonic int) | optional | always present (fallback `1`) |
| `id` | no (SO id outside attrs) | yes |
| `version` (OCC string) | no (SO `_version` / token outside attrs) | optional — **inconsistent by path** (see gaps) |

There is no class or type named `RuleDomain`. “Domain rule” means **`RuleResponse`**.

---

## Runtime path

```
API body (CreateRuleData / UpdateRuleData)
        │  transformCreateRuleBodyToRuleSoAttributes()
        │  / buildUpdateRuleAttributes()
        ▼
RuleSavedObjectAttributes  ──►  rule saved object (ES)
        │  transformRuleSoAttributesToRuleApiResponse(id, attrs, ?occVersion)
        ▼
RuleResponse
        │  RulesClient emitRuleCreated / Updated / …
        │  payload: { ruleId, spaceId, rule?: RuleResponse, correlationId? }
        ▼
in-process domain event bus
        │
        ├─► RuleWorkflowSubscriber
        │     projects to { ruleId, spaceId } only (no snapshot)
        │
        └─► RuleChangesHistorySubscriber
              object.snapshot  = rule          (intended: RuleResponse)
              object.sequence  = rule.metadata.version
```

`RulesClient` does not call the change-history client. It emits a domain event carrying `RuleResponse`. The change-history subscriber turns that into a history document.

The write-side transform comment states the seam explicitly (`utils.ts`): today 1:1, but storage can evolve independently of the public API.

Event payload typing: `rule` is `RuleResponse`, plus envelope fields (`spaceId`, `correlationId`) that are not part of the rule.

**Caveat:** `LogRuleChangesParams.entries[].snapshot` is typed `Record<string, unknown>`, not `RuleResponse`. The subscriber *passes* a `RuleResponse`; the type system does not require it.

---

## Why snapshot `RuleResponse` instead of SO attributes

Saved Objects support **model-version migrations**. Change history is **append-only**: old documents are never rewritten by Kibana SO migrations.

If snapshots were raw `RuleSavedObjectAttributes`:

- Every SO rename, split, or internal field would leave forever-shaped history documents that no longer match current attrs.
- Readers (diff UI, restore, audit) would need an unbounded stack of “understand old SO shapes” logic.
- Storage-only fields would leak into the audit trail.

Snapshotting `RuleResponse` means history tracks **what the API contract returned at write time**. SO can grow internal fields without those appearing in history unless you deliberately promote them onto the domain type and through the transform.

---

## Future SO migration: what actually happens

When a new attribute is added on the persistence layer, outcome depends on whether it is domain-visible.

### A) Persistence-only field

Example: add `internal_shard_hint` to SO attrs via a new model version + backfill.

| Layer | Effect |
|--|--|
| SO docs | Migrated / backfilled |
| `RuleResponse` | Unchanged (field not added) |
| Read transform | Does not map the field → never appears on domain rule |
| New change-history entries | Same snapshot shape as before (field absent) |
| Old change-history entries | Untouched |

SO-only evolution does not change the history contract. Fine when the field can be recomputed on write or is irrelevant to audit/restore.

### B) Domain-visible field

The field should appear on API responses and in history. You must update:

1. SO schema + model version (+ migration fixture)
2. `@kbn/alerting-v2-schemas` (`RuleResponse`, and create/update if clients set it)
3. **Both** transforms — today only SO ← create/update body and SO → `RuleResponse` exist; there is **no** `RuleResponse` → SO reverse map yet (needed for restore)

Then:

| Layer | Effect |
|--|--|
| New mutations | New snapshots include the field **if** the read transform maps it |
| Old snapshots | Still lack it — history is not backfilled |
| Readers / restore / diff | Must tolerate mixed snapshot generations (defaults for missing keys) |

There is **no** automatic “replay this SO migration into `.kibana_change_history`.”

### Discipline checklist

| Layer | SO-only attr | Domain-visible attr |
|--|--|--|
| Model version + SO schema | Yes | Yes |
| `RuleResponse` / API schemas | No | Yes |
| Write transform / builders | Set default on create/update | Both directions |
| Read transform (`…ToRuleApiResponse`) | Leave unmapped | Must add field to explicit map |
| Change-history snapshot shape | Unchanged | New entries gain field; old ones don’t |
| History consumers / restore | — | Handle optional / missing on older sequences |

`transformRuleSoAttributesToRuleApiResponse` is an **explicit field list**. Adding a field to SO + `RuleResponse` schemas but forgetting the map silently drops it from API and history. TS does not force the map to stay complete for optional fields.

---

## Restore from delete (planned)

Planned use case: recreate a deleted rule SO from a change-history snapshot (same id).

Intended flow:

```
history entry (prefer last config; see sequence notes)
  → object.snapshot (RuleResponse-shaped)
  → strip API-only / non-restorable fields
  → RuleSavedObjectAttributes (or create body)
  → create SO with options.id = snapshot.id
  → seed metadata.version so object.sequence stays monotonic
  → emit lifecycle event (ideally rule_restore / overridden action)
```

### What to strip before recreate

| Field | Action |
|--|--|
| `version` (OCC string) | Drop — never reuse; create gets a new OCC token |
| `id` | Pass as create `options.id`, not as an attribute |
| `createdAt` / `updatedAt` / `*By` | Product choice: preserve vs “restored now by X” |

Keep rule content. Treat `metadata.version` as sequence seed input, not as something to copy blindly without a policy.

### Sequence / `metadata.version`

On delete today, the emitted snapshot gets a **bumped** `metadata.version` that is written to history only — the SO is gone. That sequence is already “consumed” in the timeline for `object.id`.

On recreate with the same id:

- Starting at `1` again breaks monotonic `object.sequence` for that id (delete/create entries interleave badly when sorted by sequence).
- Safer: seed create from `max(sequence for this object.id)` (or from the delete entry’s sequence), then let the restore write be `N+1`.

`CreateRuleParams` today has no initial-version option (`options?: { id?: string }` only).

### Which snapshot

Usually restore **content** from the last pre-delete config (or from the delete snapshot’s content — today delete carries last attrs + bumped version). Treat the delete entry’s sequence as already used; do not reuse it as the restored SO’s persisted counter without an explicit policy.

### Mixed-generation snapshots

An old `RuleResponse` restored into today’s SO schema needs:

- Defaults for missing domain fields
- Ignore unknown/extra keys on the snapshot
- Recompute persistence-only SO fields on write (never in history)

There is **no snapshot schema / generation marker** in the logged document today — only whichever fields were present at write time.

---

## Implementation gaps

Verified against current code. These do not break today’s write path; they matter for restore, long-lived history, and contract honesty.

### 1. Snapshot type is not `RuleResponse`

`RuleChangesHistoryEntry.snapshot` is `Record<string, unknown>`. Intent is domain rule; types do not enforce it. A mistaken SO-attrs dump would compile.

### 2. Snapshots are not a uniform `RuleResponse`

Top-level OCC `version` is only set when the third argument is passed to `transformRuleSoAttributesToRuleApiResponse`:

| Path | OCC `version` in emitted rule / snapshot |
|--|--|
| create / update / upsert (single) | usually present |
| enable / disable (single) | present (`newVersion` passed) |
| bulk enable / disable | **absent** (2-arg transform) |
| delete / bulk delete | **absent** |

So “snapshot = RuleResponse” is incomplete. For restore, OCC `version` must never be re-applied anyway — prefer stopping putting it in history snapshots.

### 3. No reverse transform

There is SO ← create/update body and SO → `RuleResponse`. There is **no** `RuleResponse` → SO attrs (or create body) helper. Restore-from-delete cannot be a thin wrapper on `createRule` without inventing that map (and tests that keep both directions aligned).

### 4. No initial `metadata.version` on create

`createRule` always seeds via `getNextVersion()` → `1`. Same-id recreate after delete cannot continue the sequence without a new API (caller-supplied seed or “read max sequence from history”).

### 5. No snapshot generation marker

Consumers cannot tell which `RuleResponse` generation a document is. Defensive parsing / defaults are required forever unless a schema version is added to the logged payload (or conventions are frozen carefully).

### 6. Explicit map = easy silent drop

Domain-visible fields omitted from the hand-written read transform never reach API or history. No compile-time parity check between SO attrs and `RuleResponse` beyond “does this return type typecheck.”

### 7. Sanitization unused

`@kbn/change-history` supports `fieldsToHash` / `fieldsToRedact`. Alerting v2 passes neither. Sensitive fields on `RuleResponse` would be stored in history as-is.

### 8. Delete sequence lives only in history

Delete bumps `metadata.version` on the emitted snapshot only. History sequences can advance past anything ever persisted on an SO. Restore must treat history (not SO) as the source of truth for the next sequence.

### 9. Restore product surface missing

No `getHistory` on v2 RulesClient, no `rule_restore` action, no await/`refresh: 'wait_for'` on the fire-and-forget bus path. Needed for a UI that restores then immediately shows updated history.

---

## Mental model

```
                    ┌─────────────────────────┐
                    │  RuleSavedObjectAttrs   │  ← migrates with SO modelVersions
                    │  (storage, OCC, etc.)   │
                    └───────────┬─────────────┘
                                │ transform (explicit map)
                                ▼
                    ┌─────────────────────────┐
                    │     RuleResponse        │  ← public / domain contract
                    │  (API + event payload)  │
                    └───────────┬─────────────┘
                                │ logged (typed as Record; intended RuleResponse)
                                ▼
                    ┌─────────────────────────┐
                    │  object.snapshot        │  ← append-only; never SO-migrated
                    │  object.sequence        │     = metadata.version
                    └───────────┬─────────────┘
                                │ restore (planned; reverse map not built)
                                ▼
                    ┌─────────────────────────┐
                    │  new SO (same id)       │  ← seed sequence; strip OCC
                    └─────────────────────────┘
```

**SO migrations change storage. They do not rewrite history. History follows the API-shaped rule across time; each entry is a point-in-time snapshot. Restore recreates storage from that snapshot — it does not replay SO migrations.**
