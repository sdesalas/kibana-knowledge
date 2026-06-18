# PR Review: #273561 — Store rule change history snapshots as rule domain

**PR:** [elastic/kibana#273561](https://github.com/elastic/kibana/pull/273561)

**Scale:** Substantive — touches the write path, read path, types, constants, and 12 test files across the alerting change-tracking subsystem.

---

## Context (Slack thread summary)

The Kibana Core team flagged ([thread](https://elastic.slack.com/archives/C09QUB06E4Q/p1781605664145989)) that storing raw `RawRule` SO attributes as snapshots is a **blocker**:

> *"I think this would be a blocker, otherwise alerting team can never again write any saved object migrations without breaking snapshot history. The rule domain shape is tied to the API, we can't change that without breaking the API, but we still want to be able to independently evolve the on-disk schema."*

Maxim's original reason for using `RawRule` was twofold:

> *"Saved Object data has platform managed fields which Security Solution doesn't manage like rule snoozing. Currently we don't display the diff for snoozing but thinking about that for the future. Security Rules could be updated via Alerting API. In particular API key could be updated and we wanna track that. Customers have multiple issues due to rule's API key renewed and they can't see that."*

The Kibana Core team suggested using `Rule` with the `apiKey` replaced by a hash. Maxim's resolution was to use `RuleDomain` instead, which keeps `apiKey` and `uiamApiKey` (unlike the public `Rule` type which strips them):

> *"`RuleDomain` compared to `Rule` has `apiKey` and `uiamApiKey`. Besides that these two are identical. We'd like to track API key changes."*

The Kibana Core team also raised a **second, separate concern** ([thread](https://elastic.slack.com/archives/C09QUB06E4Q/p1781607358813989)) about the denylist approach to secret hashing:

> *"I have a separate concern about the way we're redacting secrets with denylist instead of an allowlist. The source of truth for what fields are encrypted lives inside saved objects, so we can't be sure our list will stay in sync. But right now if a new encrypted field gets added my reading of the code is that it will get silently surfaced to the UI through snapshots? I think we should rather add a utility function to encrypted saved objects that allows a caller to redact secrets instead of the default behavior that strips them. That way the fields getting redacted is always in sync with the source of truth."*

This PR deliberately defers that; it's flagged as a follow-up.

---

## SO migration concern — is it valid? Does this PR address it?

**The concern is technically valid. The PR addresses it correctly.**

### Where snapshots are stored

Snapshots are persisted in an Elasticsearch data stream (`.kibana_change_history`), completely separate from the `.kibana*` saved object indices. SO migrations only operate on the SO indices — they **never touch this data stream**. So whenever the alerting team runs a SO migration, existing history documents sit untouched with whatever field names they were written with.

### Why the old approach was a blocker

The old snapshot stored `RawRule` attributes as-is. When reading back, the code called `transformRuleAttributesToRuleDomain(snapshot.attributes, ...)` to reconstruct the rule — a function written against the **current** `RawRule` schema.

If a SO migration renames a field (e.g. model version 12 added `snoozedInstances`; future ones could restructure existing fields), that function gets updated to expect the new name. But every snapshot written before the migration still carries the old name. Result: the read fails silently for every old history entry — no error, history just disappears.

### How the PR fixes it

The fix is to move the expensive schema transformation to **write time** and store the already-transformed `RuleDomain` instead of raw `RawRule`.

| | Old | New |
|---|---|---|
| **Write** | Store `RawRule` (coupled to SO schema version N) | Call `transformRuleAttributesToRuleDomain` → serialize `RuleDomain` |
| **Read** | Call `transformRuleAttributesToRuleDomain` (expects current schema) | Hydrate dates → call `transformRuleDomainToRule` (schema-agnostic) |

`RuleDomain` field names are defined by the application contract, not the on-disk SO schema. Even if a future SO migration renames `RawRule.apiKey` to `RawRule.encodedApiKey`, the `RuleDomain` interface keeps `apiKey` — the transform happened once at write time and old snapshots remain readable forever.

`transformRuleDomainToRule` (the only transform left on the read path) is a simple shape conversion — it knows nothing about the SO schema and can't be broken by SO migrations.

### One residual caveat

`RuleDomain` could itself change in a breaking way, which would cause the same problem one level up. In practice the alerting platform team treats `RuleDomain` as a stable API contract (the public `Rule` type is derived from it), so it changes far more slowly and carefully than the raw SO schema — a much easier guarantee to maintain.

---

## Summary

Snapshots written to the rule change history index previously stored the raw saved object shape (`{ attributes: RawRule, references: [] }`), which is coupled to the on-disk schema. This PR changes that to `RuleChangeHistorySnapshot` — a stable application-layer representation derived from `RuleDomain`, with runtime-only fields stripped and dates serialized as strings.

The practical win: future alerting saved object schema migrations won't silently break stored history. As a side effect, reading a snapshot back no longer needs `RuleTypeRegistry` — the snapshot already holds everything needed, so reconstruction reduces to parsing dates and calling `transformRuleDomainToRule`.

---

## Field coverage: what's present, changed, and missing

### API keys

All present and correctly handled:
- `apiKey` — in snapshot, hashed before storage ✅
- `uiamApiKey` — in snapshot, hashed before storage ✅
- `apiKeyOwner` — present ✅
- `apiKeyCreatedByUser` — present ✅

One field is lost: **`meta.versionApiKeyLastmodified`** — exists on `RawRule.meta` (v1 schema) but `transformRuleAttributesToRuleDomain` never maps it, so it doesn't appear in `RuleDomain` at all. Maxim called it out in the Slack thread as potentially useful — it tracks when the API key version was last changed. Old snapshots would have had it; new ones won't.

### References / actions

The old and new formats represent the same data differently:

**Old (RawRule):** actions carry an opaque `actionRef` (e.g. `"action_0"`) and the actual connector UUID lives in the separate `references` array.

**New (RuleDomain snapshot):** `injectReferencesIntoActions` is called at write time, resolving `actionRef → connector UUID` directly into `action.id`. The raw `references` array is gone but connector IDs are actually *more* readable — they're directly in `actions[].id` rather than requiring a join.

Same resolution happens for `params` (via `injectReferencesIntoParams`) and `artifacts` (via `transformRawArtifactsToDomainArtifacts`). No reference data is lost, the indirection is just eliminated.

### Fields intentionally stripped by `serializeRuleDomain`

These existed in old `RawRule` snapshots and are now explicitly excluded:

| Field | Reason |
|---|---|
| `monitoring` | Runtime execution metrics, not user config |
| `executionStatus` | Last execution result, not user config |
| `lastRun` | Runtime outcome, not user config |
| `nextRun` | Computed scheduling state |
| `running` | Ephemeral flag |
| `lastEnabledAt` | Operational timestamp |
| `activeSnoozes` | Computed from `snoozeSchedule` |
| `isSnoozedUntil` | Computed from `snoozeSchedule` |
| `viewInAppRelativeUrl` | Computed from ruleType, never stored |
| `scheduledTaskId` | Platform-internal task reference |
| `mutedInstanceIds` | Per-alert mutes — see below |

`snoozeSchedule` and `snoozedInstances` (v12) are both **present** in the new snapshot.

### `mutedInstanceIds` — worth flagging

`mutedInstanceIds` holds the per-alert grouping keys a user has explicitly muted (often the entity itself — host name, user, query group value). Muting suppresses actions/notifications for that specific alert while the rule keeps running. It's a deliberate human action, not runtime state — which is what sets it apart from the other stripped fields.

From a business-audit angle this is the one stripped field that genuinely matters: "alerts for host X were silenced by user Y on date Z" is forensically relevant if that entity is later involved in an incident. Note the inconsistency — `muteAll` (whole-rule mute) is **retained** in the snapshot, but `mutedInstanceIds` (the more targeted, easier-to-miss per-alert mute) is stripped.

**Important caveat:** keeping the field alone wouldn't deliver an audit trail today. Muting does **not** trigger a snapshot — `mute_instance`, `unmute_alert`, `mute_all`, `unmute_all` are absent from the `logRuleChanges` callers (only create/update/delete/snooze/unsnooze/bulk_*/update_api_key are). So `mutedInstanceIds` would only get captured incidentally when some other tracked op snapshots the rule, with no event explaining the mute and no `updatedBy` tied to it. Mute/unmute *are* already in Kibana's security audit log (`RuleAuditAction.MUTE_ALERT`), a separate retention-limited stream.

**Future direction:** we'll likely want to capture muting/unmuting in rule history. When we do, it's a deliberate two-part change — (1) stop stripping `mutedInstanceIds` from the snapshot, and (2) add the mute/unmute methods to the `logRuleChanges` callers. At that point storing the field makes sense. For *this* PR's scope nothing is lost (mutes don't snapshot anyway), so it's a known gap, not an accidental omission.

### Summary table

| Field | Old format | New format | Impact |
|---|---|---|---|
| `meta.versionApiKeyLastmodified` | present | **lost** | Minor — tracks API key version, not the key value |
| `typeVersion` | present | lost | None — platform-internal |
| `mutedInstanceIds` | present | stripped | Per-alert mutes untracked — but mutes don't snapshot today anyway; future feature needs field + `logRuleChanges` wiring |
| Operational fields (`monitoring`, `executionStatus`, etc.) | present | stripped | Intentional — not user config |
| Connector UUIDs | indirect (actionRef + references) | baked into `actions[].id` | Improved — more readable |

---

## Files touched

**Core logic (4 files):**
- `log_rule_changes.ts` — write path; now calls `transformRuleAttributesToRuleDomain` before snapshotting and introduces `serializeRuleDomain` to strip operational fields and serialize dates.
- `rules_client/lib/change_tracking/types.ts` — replaces `RuleSnapshot` (SO-coupled) with `RuleChangeHistorySnapshot` (typed `Omit<RuleDomain>` with `createdAt`/`updatedAt` as `string`).
- `rules_client/lib/change_tracking/constants.ts` — removes the `attributes.` nesting from `ALERTING_RULE_CHANGE_HISTORY_SENSITIVE_FIELDS` to match the now-flat snapshot shape.
- `rules_client/methods/get_rule_history.ts` — read path; drops `RuleTypeRegistry` dependency, adds `isRuleDomainSnapshot` type guard and `hydrateDateFields` helper.

**Test files (12 files):** Bulk operations, create, delete, snooze/unsnooze, update-api-key tests update snapshot assertions from `{ attributes: ..., references: [] }` to `expect.objectContaining({ id, name, ... })`.

---

## Flow trace

**Write path (snapshot creation):**

1. A rule operation (create/update/delete/bulk-edit etc.) calls `logRuleChanges({ ruleSOs, rulesClientContext, changesContext })`.
2. For each `ruleSO`, the rule type is resolved from `ruleTypeRegistry`.
3. **[new]** `transformRuleAttributesToRuleDomain(ruleSO.attributes, { id, logger, ruleType, references }, isSystemAction)` produces a `RuleDomain` — the stable application-layer object including `apiKey` and `uiamApiKey`.
4. **[new]** `serializeRuleDomain(ruleDomain)` destructure-strips operational fields (`monitoring`, `executionStatus`, `lastRun`, `nextRun`, `running`, `lastEnabledAt`, `activeSnoozes`, `isSnoozedUntil`, `viewInAppRelativeUrl`, `scheduledTaskId`, `mutedInstanceIds`) and serializes `createdAt`/`updatedAt` to ISO strings → `RuleChangeHistorySnapshot`.
5. The snapshot is pushed to `changes` and forwarded to `changeTrackingService.logBulk`.
6. `ChangeTrackingService` calls `@kbn/change-history` with `fieldsToHash: { apiKey: true, uiamApiKey: true }` — the library hashes those values in place before writing to the index.

**Read path (snapshot hydration):**

1. `getRuleHistory` fetches raw history documents from `@kbn/change-history`.
2. For each item, `hydrateRuleSnapshot(item.object, context.logger)` is called.
3. **[new]** `isRuleDomainSnapshot(snapshot)` checks that the snapshot has the expected flat shape (`id`, `name`, `enabled`, `alertTypeId`, `consumer`, `schedule`, `revision`, `muteAll`, `actions`, `tags`, `params`). Returns `undefined` for anything that doesn't match.
4. **[new]** `hydrateDateFields` parses `createdAt`/`updatedAt` back from ISO strings to `Date` objects.
5. The rebuilt rule domain is passed to `transformRuleDomainToRule`, which strips `apiKey`/`uiamApiKey` and returns a `SanitizedRule` for the API response.

---

## Assumptions

- **`RuleDomain` stability** — the core premise. Enforced by convention (alerting platform team owns the transform), verified with the Kibana Core team. Not enforced by code: if `RuleDomain` ever changes shape in a breaking way, old snapshots face the same problem one level up.
- **`isSystemAction` always present** — confirmed: `isSystemAction: (actionId: string) => boolean` is a required field on `RulesClientContext` (`rules_client/types.ts:114`). All 10 callers of `logRuleChanges` pass the full context, so this is safe.
- **`transformRuleAttributesToRuleDomain` won't throw on valid SOs** — plausible: the SO schema validates on write so stored attributes should always be well-formed. The `try/catch` is a fallback for schema drift or corrupt documents, not an expected code path.
- **No existing history in the wild** — the feature has never shipped. There are no old-format snapshots anywhere to worry about. `isRuleDomainSnapshot` rejecting the old format is a clean break, not a data migration concern.
- **`mutedInstanceIds` absence is benign** — the security solution's `RuleResponse` schema (the UI/API contract) does not include `mutedInstanceIds`. `normalizeCommonRuleFields()` never maps it. Absence in a hydrated history snapshot won't cause runtime errors or UI breakage.
- **`RuleAttributesToEncrypt` and `ALERTING_RULE_CHANGE_HISTORY_SENSITIVE_FIELDS` stay in sync** — currently true (`['apiKey', 'uiamApiKey']` matches `{ apiKey: true, uiamApiKey: true }`), but there is no programmatic enforcement. This is the deferred Kibana Core team concern.

---

## Risks

**Medium:**
- **`total` count overstates actual items when snapshots fail hydration.** `getRuleHistory` filters out any item where `hydrateRuleSnapshot` returns `undefined`, but returns `{ ...result, items: itemsRule }` — spreading `result.total` unchanged from the raw ES response. If any document ever fails `isRuleDomainSnapshot` (corrupt doc, future format change), the caller receives a `total` higher than the actual item count on that page. Pagination breaks: callers fetch the next page expecting more results but get fewer or nothing. Not a problem today (no data in the index), but structurally fragile.
- **`hydrateDateFields` null propagates silently through a type cast.** `hydrateDateField` returns `null` if the value is not a string, number, or Date. The result is spread onto the snapshot and cast `as RuleDomain` without a guard. In practice `createdAt`/`updatedAt` are always ISO strings written by `serializeRuleDomain`, so null is unreachable — but the type system doesn't enforce this. The cast hides it from the compiler.
- **Write failures logged at `debug` rather than `warn`.** If `transformRuleAttributesToRuleDomain` throws on a malformed SO, the change is silently dropped. For an audit/compliance feature `warn` is more appropriate — a missing change event is worse than a noisy log line.

**Low:**
- **`fieldsToHash` denylist drift (deferred).** If a new encrypted field is added to the rule SO and not added to `ALERTING_RULE_CHANGE_HISTORY_SENSITIVE_FIELDS`, it will be stored in plaintext. Currently `apiKey` and `uiamApiKey` are the only encrypted fields and the constant matches — but this is not enforced by code.

---

## Open questions

1. **`total` / `items` mismatch**: Should `getRuleHistory` adjust `total` to reflect the number of successfully hydrated items, or is it intentional to return the raw ES count? Right now any failed hydration creates a gap the caller can't account for.

2. **`meta.versionApiKeyLastmodified`**: Maxim flagged this in the Slack thread as potentially useful for auditing API key rotations. It exists on `RawRule.meta` but is never mapped into `RuleDomain`. Should it be included in the snapshot separately?

3. **`mutedInstanceIds` exclusion**: Per-alert mute changes won't appear in history (`snoozeSchedule` is tracked, `mutedInstanceIds` is stripped, and the mute/unmute methods don't call `logRuleChanges` anyway). No UI breakage. Intentional for now — but capturing mute/unmute in rule history is a likely future feature, at which point the field should be retained *and* the mute methods wired into `logRuleChanges`. Track as a follow-up.

4. **Kibana Core team concern (follow-up scope)**: Is there a ticket for the ESO-based secret hashing approach? The denylist is currently correct but fragile — needs a clear owner before this ships.

---

## README recommendations (`kbn-change-history`)

Worth adding a short **Snapshot backwards/forwards compatibility** section. For example:

> **Snapshot backwards/forwards compatibility**
>
> Since `object.snapshot` is stored unmapped in an ES data stream that storage-layer migrations never touch, it is recommended that callers store an application-layer type rather than a raw on-disk format. Storing raw storage attributes means any future schema migration may require a compensating storage-layer transform to keep old snapshots readable. See [#273561](https://github.com/elastic/kibana/pull/273561) for a concrete example.

---

## Review activities

1. **Verified Kibana Core's SO schema migration concern.** Dug into where snapshots are stored (ES data stream `.kibana_change_history`, not SO indices), how alerting SO model versions work, and how the old `RawRule`-on-read approach would break on a field rename. Confirmed the concern is valid and the PR addresses it correctly by moving `transformRuleAttributesToRuleDomain` to write time.

2. **Checked `bulkCreateRules` change tracking wiring.** Found the method wasn't in this branch when the PR was written — it landed in #269340 on `upstream/main`. Once this branch is rebased, `bulk_create_rules.test.ts` snapshot assertions will fail because they still use the old `{ attributes: RawRule, references: [] }` shape. The fix is the same mechanical update applied to all other bulk operation tests in this PR. Not a blocker, but surfaces on rebase.

3. **Verified `mutedInstanceIds` absence is safe.** Checked the security solution's `RuleResponse` schema (`rule_schemas.gen.ts`) — `mutedInstanceIds` is not in `SharedResponseProps` or any rule type schema, so stripping it from history snapshots causes no runtime errors or UI breakage.

4. **Traced the `apiKey` hashing code path end-to-end.** Confirmed: raw `apiKey` does not appear in the stored snapshot. Hashing is injected centrally in `ChangeTrackingService.logBulk` (`service.ts:154`) via `fieldsToHash: ALERTING_RULE_CHANGE_HISTORY_SENSITIVE_FIELDS` — callers including `log_rule_changes.ts` cannot accidentally bypass it. The stored `object.snapshot.apiKey` holds the SHA-256 digest; `object.fields.hashed` records which paths were hashed. Tested locally and confirmed.

5. **`object.hash` includes the raw apiKey before hashing.** In `client.ts:205`, `object.hash` is computed as `sha256(JSON.stringify(change.snapshot))` from the full original snapshot before `hashFields` replaces sensitive values. Not exploitable in practice (high-entropy keys, full-snapshot input), but worth noting: `object.hash` is not a fingerprint of the hashed form alone.

6. **Follow-up ticket for `apiKeyHash` only needed if switching to `Rule`.** The current `RuleDomain` snapshot already carries `apiKey`/`uiamApiKey` (hashed before storage), so API key change tracking works without any additional typed field. A ticket would only be needed if the snapshot type is changed to the public `Rule` type, which strips those fields entirely.

7. **Reviewed `kbn-change-history` README for completeness.** Identified a missing section on snapshot backwards/forwards compatibility — see README recommendations above.

8. **Answered Christos Nasikas's `RuleDomain` vs `Rule` review comment.** Pulled the PR comments and read both type definitions (`types/rule.ts`) plus `transformRuleDomainToRule`. Confirmed the two types are identical except `RuleDomain` carries `apiKey`/`uiamApiKey` and `Rule` strips them — the transform exists purely for that. The reason to store `RuleDomain` (not `Rule`) in the data stream is API-key change tracking: storing `Rule` would drop the keys before they could be hashed/diffed. Keys are hashed before write and stripped on read, which is why the write/read asymmetry is intentional.

9. **Checked whether the stripped operational fields are used by observability/stack alerting UIs.** Confirmed several (`executionStatus`, `lastRun`, `nextRun`, `monitoring`, `mutedInstanceIds`) are consumed by the o11y rule details page and stack alerting UIs — e.g. `observability/public/pages/rule_details/rule_details.tsx` drives its health badge off `executionStatus`. But those UIs read the *live* rule via the standard rules-client APIs, never from change-history snapshots. `getRuleHistory` is currently only wired into the security solution rule management route — no o11y/stack consumer. So stripping these fields can't affect any UI that displays or manages a live rule.

10. **Deep-dived `mutedInstanceIds` contents and audit relevance.** It holds the per-alert grouping keys a user explicitly muted (often the monitored entity — host, user, group value); muting suppresses notifications while the rule keeps running. It's a deliberate human action, so it has genuine business-audit value, and there's an inconsistency: `muteAll` is retained in the snapshot but per-alert `mutedInstanceIds` is stripped. Key finding: muting doesn't trigger a snapshot at all — `mute_instance`/`unmute_alert`/`mute_all`/`unmute_all` are absent from the `logRuleChanges` callers — so keeping the field alone wouldn't produce an audit trail today. Capturing mute/unmute in rule history is a likely future feature requiring both retaining the field and wiring the mute methods into `logRuleChanges`. Mutes are already recorded in Kibana's security audit log (`RuleAuditAction.MUTE_ALERT`), a separate retention-limited stream.

11. **Traced per-alert muting end-to-end to confirm `mutedInstanceIds` is unused by security.** `rulesClient.muteInstance` has one production caller — the alerting `mute_alert` route — which backs the shared `response-ops` alerts-table `MuteAlertAction` (used by o11y/ML/stack). In the UI it's reached from exactly two places: the shared alerts-table row "Mute" action and the stack rule-details alert-instance list (`with_bulk_rule_api_operations.tsx` → `rule.tsx`). Security uses a *custom* `ActionsCell` (`RowAction`) with no mute action, its detection rules client never mutes, and its rule-management UI only *reads* `muteAll` for snooze display (`fetchRulesSnoozeSettings`). So `mutedInstanceIds` is only ever populated for o11y/ML/stack rules, never security — deferring its history tracking costs security nothing.

12. **Reviewed the `get_rule_history.ts` read-path rewrite against `main`.** Most of the diff is justified and is a genuine simplification: storing `RuleChangeHistorySnapshot` instead of raw `RawRule` removes the `RuleTypeRegistry` lookup and `transformRuleAttributesToRuleDomain` from the read path (also a correctness win — old entries no longer vanish when a rule type is unregistered), which is why the helper param narrows from `context` to `context.logger`. The genuinely over-built parts: (a) the date hydration helpers (`hydrateDateField`/`hydrateDateFields`) handle `Date`/`number`/`null` cases the write path never emits and drive the `as RuleDomain` cast — inline `new Date(...)` instead; (b) the `try/catch` is now near-vestigial since `new Date()` and `transformRuleDomainToRule` (pure field copy) don't throw; (c) `isRuleDomainSnapshot` checks ~10 top-level primitives but not nested `actions`/`params`, giving false thoroughness — and since `transformRuleDomainToRule` can't throw and there's no old-format data, a minimal non-null-object + `id` check is enough. The guard is conceptually needed only because `@kbn/change-history` returns `snapshot` as untyped `Record<string, unknown>`.

---

## Notes for your codebase map

- **`RuleDomain` vs `Rule`**: `RuleDomain` includes sensitive fields (`apiKey`, `uiamApiKey`) that the public `Rule` type strips via `transformRuleDomainToRule`. Anything that needs to hash/compare sensitive fields must work at the `RuleDomain` layer.
- **`ALERTING_RULE_CHANGE_HISTORY_SENSITIVE_FIELDS`** in `constants.ts` is passed as `fieldsToHash` to `@kbn/change-history` — a path-based denylist, not tied to ESO registration. Keep it in sync with `RuleAttributesToEncrypt` in `saved_objects/index.ts`.
- **`serializeRuleDomain`** removes fields by destructuring them out with `_`-prefixed names and spreading the rest. TypeScript enforces that you name every field you discard, which prevents silent omissions.
- **`isRuleDomainSnapshot`** is a hand-written type guard — no schema library. It checks ~10 primitive fields but not deep shapes (e.g. individual action structure). Enough to tell old-format snapshots from new ones.
- **`RuleTypeRegistry` was removed from the read path** — previously needed to resolve the rule type before reconstructing a snapshot. Snapshots now carry enough context on their own, reducing the number of dependencies the caller needs.
- **Change history feature flag**: `xpack.alerting.ruleChangeTracking.enabled` + `ruleChangesHistoryEnabled` experimental flag. Both must be on for any of this code to run.
