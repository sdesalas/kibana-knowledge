# Rule updates: concurrent requests silently overwrite each other

**Date**: 2026-07-06
**Related issue**: https://github.com/elastic/kibana/issues/276282
**Reported by**: Patrick Borgonovi (issue), Steven de Salas (this report)

**API endpoints affected**:

- `POST /internal/detection_engine/rules/{ruleId}/history/{changeId}/_restore` — restore from history (the endpoint in the bug report)
- `PUT /api/detection_engine/rules` — normal rule edit
- `POST /internal/detection_engine/prebuilt_rules/revert` — revert a customized prebuilt rule to its base version
- `POST /internal/detection_engine/prebuilt_rules/upgrade/_perform` — apply a pending prebuilt rule upgrade

---

## The problem in #276282 (restore from history)

When two requests hit the `_restore` endpoint on the same rule at nearly the same moment — two operators, a double-click, or two tabs — Kibana lets both requests succeed. Whichever write finishes second wins, but both operators get a green "success" toast. Depending on which past revisions they chose, this shows up in one of two ways:

- **Same past revision picked twice**: the rule's history ends up with two `rule_restore` entries at the **same revision number**, one of which shows "No visible field changes" in the diff pane.
- **Different past revisions picked**: the second write silently overwrites the first. The operator who lost the race has no signal that their choice was thrown away.

Once concurrency gets higher (roughly 5+ simultaneous requests), a different symptom appears: some requests come back with a raw Elasticsearch error mentioning `seqNo` and `primary_term`. The security_solution restore route has a conflict modal on the front end that expects a specific 409 shape (`{ message, attributes: { revision } }`) — the raw ES error doesn't match it, so the modal cannot render properly.

### Why it happens

The restore endpoint's server code follows this shape:

1. **Read** the current rule from Elasticsearch.
2. **Check** that the caller's expected revision matches what we just read.
3. **Compute** the new rule state (apply the chosen historical snapshot on top of the current rule).
4. **Write** the new state via `rulesClient.update()`.

The check in step 2 lives in `restore_rule_from_history.ts:65-70`:

```65:70:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/restore_rule_from_history.ts
  if (existingRule != null && existingRule.revision !== currentRuleRevision) {
    throw new RuleConcurrencyError(
      'Someone has updated the rule already. Please provide the latest rule revision.',
      existingRule.revision
    );
  }
```

The problem is that steps 2 and 4 are not linked. Two concurrent callers can both read the same starting revision, both pass the check, both build a new state, and both call `rulesClient.update`. The revision guard is well-intentioned but happens in the wrong place.

`rulesClient.update()` has its own conflict handling inside `updateWithOCC`: it loads a fresh copy of the rule, computes the payload, and writes with the Elasticsearch document version it just read. If Elasticsearch rejects the write because the version has moved on, `retryIfConflicts` catches the error, waits 100ms, and retries. That's `retry_if_conflicts.ts:29-54` and `update_rule.ts:373-385`.

The retry sounds like it should fix the race, but it doesn't. Two things happen:

**1. The caller's stale payload is re-applied on top of the winner's write.** On retry, `updateWithOCC` reloads the rule (now with the winner's content), but the caller's `data` argument is unchanged — it was computed back at step 3 from the stale read. `incrementRevision` compares that payload to the freshly-loaded rule:

```13:42:x-pack/platform/plugins/shared/alerting/server/rules_client/lib/increment_revision.ts
export function incrementRevision<Params extends RuleTypeParams>({
  originalRule,
  updateRuleData,
  updatedParams,
}: {
  originalRule: RawRule;
  updateRuleData: UpdateRuleData<Params>;
  updatedParams: RuleTypeParams;
}): number {
  // Diff root level attrs
  for (const [field, value] of Object.entries(updateRuleData).filter(([key]) => key !== 'params')) {
    if (
      !fieldsToExcludeFromRevisionUpdates.has(field) &&
      !isEqual(value, get(originalRule, field))
    ) {
      return originalRule.revision + 1;
    }
  }

  // Diff rule params
  for (const [field, value] of Object.entries(updatedParams)) {
    if (
      !fieldsToExcludeFromRevisionUpdates.has(field) &&
      !isEqual(value, get(originalRule.params, field))
    ) {
      return originalRule.revision + 1;
    }
  }
  return originalRule.revision;
}
```

If the loser's payload is identical to what the winner just wrote (both restored to the same past revision), `incrementRevision` returns the same revision. The SO gets re-written, `logRuleChanges` is called unconditionally, and a second change-tracking entry lands at the same revision number. That's the exact "two entries at rev=2, second one shows No visible field changes" pattern from the bug report.

If the loser's payload differs (they picked different past revisions), revision does get bumped and the loser's version becomes final — but both requests still return 200 OK. That's the silent-overwrite half.

**2. The retry budget is small** (2 retries at 100ms each — see the constants in `retry_if_conflicts.ts:20-26`). Once concurrency pushes past that, the raw Elasticsearch conflict error bubbles up through the alerting layer and out the route handler untranslated. That's the raw-ES-error leak at 5+ concurrent writers.

## The same shape shows up in three other flows

Three other rule-writing endpoints follow the same check-then-write shape and end up calling the same `rulesClient.update`, so they inherit the same retry-and-overwrite behaviour. What differs between them is which *visible* symptoms surface. Here's what actually breaks in each.

### `PUT /api/detection_engine/rules` — normal rule edit

**Handler**: `update_rule.ts` — calls `rulesClient.update` on line 119.

**Schema**: `update_rule_route.gen.ts` — has no `revision` field. The client cannot send one.

The pre-write revision check doesn't exist here at all. Concurrent PUTs are always last-writer-wins.

Concrete symptoms:

- **Silent overwrite** on every concurrent edit. Two people saving the same rule from two tabs, or a script racing the UI, and the last save wins with no 409. No warning, no signal.
- **No "duplicate revision" symptom** — because two concurrent PUTs almost always carry *different* payloads (each is a full rule replacement built from a different starting form state), `incrementRevision` bumps revision on both writes. History gets two consecutive entries, neither is duplicate. Not the same visible bug as restore, but still user data loss.
- **Raw ES 409 leak at high concurrency** — same mechanism as restore.

Reality check: standard HTTP PUT semantics are last-writer-wins unless the client sends `If-Match`. So this isn't a hole in an existing capability — it's an existing capability that never offered optimistic concurrency to begin with. The fix here is different in nature: it's *adding* an `expected_revision` field to the request body, which is a public API surface change on a versioned route.

### `POST /internal/detection_engine/prebuilt_rules/revert`

**Handler**: `revert_prebuilt_rule_handler.ts:106-114` (revision check), `revert_prebuilt_rule.ts:52` (write).

Same check-then-write shape as restore. The check compares against a rule loaded via `getRuleById` a few lines up; the write goes through `revertPrebuiltRules` → `rulesClient.update`.

Concrete symptoms:

- **Same-target concurrency** — two concurrent reverts of the same rule both target the same base version. Both payloads are almost identical (base content is fixed; actions come from the same loaded rev). `incrementRevision` sees no diff on the retry, revision doesn't bump, but `logRuleChanges` still writes a second `rule_revert` entry at the same revision. Same duplicate-entry symptom as restore, under a different action label.
- **Cross-flow interleave (revert vs edit)** — user A edits the rule (say, removes action B). User B reverts concurrently, holding a stale copy with actions [A, B]. `revertPrebuiltRule` preserves `existingRule.actions` from *its own* stale read (`revert_prebuilt_rule.ts:46-48`), so user B's write puts action B back. A's action-removal is silently reverted. This one hurts because the preserved-actions merge is asymmetric to the direction of the update.
- **Raw ES 409 leak at high concurrency** — same mechanism.

Front end (`use_revert_prebuilt_rule.ts:39-45`) has minimal 409 handling — just a warning toast (`RULE_REVERT_FAILED_CONCURRENCY_MESSAGE`). No modal, no "revert anyway" UX.

### `POST /internal/detection_engine/prebuilt_rules/upgrade/_perform`

**Handler**: `perform_rule_upgrade_handler.ts:168-177` (revision check), `upgrade_prebuilt_rule.ts:93` (write).

Same shape again. The comment on the check even claims the property it does not actually hold ("no update slipped in since the user reviewed the list").

Concrete symptoms:

- **Same-target concurrency** — same as revert. Two concurrent upgrades to the same target version, identical payloads, `incrementRevision` sees no diff on retry, duplicate `rule_upgrade` entries at the same revision.
- **Cross-flow interleave (upgrade vs edit)** — same shape as revert. `upgradePrebuiltRule` preserves actions from its stale read (`upgrade_prebuilt_rule.ts:87-89`); any concurrent action removal by another user gets undone.
- **Bulk mode never checks revision** — the check on line 169 is gated by `targetRule.revision != null`. When the client uses `mode: ALL_RULES` (the "upgrade everything" flow), no revision is sent, so no check runs at all. Any interleaved edit during a bulk upgrade is silently overwritten regardless of timing.
- **Raw ES 409 leak at high concurrency** — same mechanism.

Front end has no concurrency-conflict UX at all. The word "conflict" in the upgrade code refers to 3-way merge conflicts (base vs current vs target), which is a different concept.

## What the UI currently expects for a 409

Only restore has proper conflict UX. `use_rule_restore_from_history.ts:63-86` reads:

- HTTP status `409`
- `error.body.attributes.revision` — the current server-side revision

If it gets that shape, it opens `RuleRestoreConflictModal` with "Cancel / Review changes / Restore anyway" options. The "Restore anyway" button re-fires the mutation using `currentRevision` from the 409 response — the loser opts in explicitly.

The shape matches the existing `RuleConcurrencyError` (`utils.ts:101-106`), which the route handler at `restore_rule_from_history/route.ts:65-68` converts to `response.conflict({ body: { message, attributes: { revision } } })`. So the plumbing is already correct — it just doesn't fire in the racy case because the check runs before the write.

Revert has a warning toast on 409. Upgrade has nothing. PUT has nothing. If we want restore-quality UX on the other flows, that's separate UI work; the server-side fix that stops silent overwrites is independent of the UI story.

## Fix options

Two realistic options. Both need the same underlying property: the concurrency check has to happen **atomically with the write** so no other request can slip in between.

### Option A — `expectedRevision` parameter on `rulesClient.update` (recommended)

Add an optional `expectedRevision?: number` to `UpdateRuleParams` (in `@kbn/alerting-plugin/server`). Inside `updateWithOCC`, immediately after `getDecryptedRuleSo`, compare `originalRuleSavedObject.attributes.revision` to `expectedRevision`. If they don't match, throw a new domain error (e.g. `RuleRevisionConflictError`) with the current revision on it.

Because that new error is not an Elasticsearch `isConflictError`, `retryIfConflicts` doesn't catch it (see `retry_if_conflicts.ts:38-41`). It bubbles straight up to the route.

**Blast radius**:

- `UpdateRuleParams` is a public type on `@kbn/alerting-plugin/server`. Adding an optional field is backward compatible.
- Current external callers of `rulesClient.update` outside the four flows in question: `x-pack/solutions/observability/plugins/synthetics/server/routes/default_alerts/default_alert_service.ts` (one call site, wouldn't pass the field, unchanged).
- Restore, revert, upgrade: drop their pre-write revision check and pass `expectedRevision` on the update call. Small.
- PUT rule: needs a request body schema addition (`revision?: number`) and forward to `expectedRevision`. New API surface, but optional. UI can opt in later — pre-existing clients that omit it keep today's last-writer-wins behaviour.

**Pros**: closes the race at the actual write point. Fixes all three symptoms of the bug in one code path. Reuses the existing 409 shape the UI already understands. Uses `revision`, which the UI already knows about and displays.

**Cons**: `revision` is a *content-aware* counter — `incrementRevision` only bumps it when content changes. That means two clients that both restore to the same past revision (Scenario A) will each hold the same `expectedRevision` and both writes will pass the guard by that measure alone. Option A fixes this indirectly because the second writer's guard passes but the alerting-plugin's own SO OCC catches it and `retryIfConflicts` no longer swallows it (because the domain error was thrown before the retry loop got its chance) — but only *if* we also make the second write's `incrementRevision` result actually differ from the winner's. In practice this works because the second writer's payload is applied on top of the winner's fresh state and either matches (giving `no_change: true`) or produces a different revision. Worth confirming in tests.

Introduces a security-adjacent concept (`revision` as a client-pinnable version) into a generic alerting API. `revision` already lives on `RawRule` so it isn't a *new* domain concept, but Option A does make it a first-class part of the mutation contract.

### Option B — Thread the SavedObject `version` end-to-end (true OCC)

Every SavedObject has a `version` string (a base64-encoded `_seq_no` + `_primary_term` composite). It's the actual Elasticsearch optimistic-concurrency token. `updateWithOCC` already uses it internally on line 373-385 of `update_rule.ts` — it grabs `version` from the freshly-loaded SO and passes it to `createRuleSo` with `overwrite: true`, and Elasticsearch rejects the write if the version has moved on.

The idea here is to lift that token out of the alerting plugin and thread it up to the UI: every rule read response includes `version`, the UI stores it, and every rule mutation request echoes it back. `rulesClient.update` accepts a caller-supplied `version` and uses it instead of the one it would have loaded itself. That gives true end-to-end OCC — any change at any layer (from another user, from bulk actions, from a background task) invalidates the token.

**Blast radius**:

- **Alerting plugin**: `UpdateRuleParams` gains `version?: string`. `updateWithOCC` uses the caller-supplied `version` (when present) instead of the freshly-loaded one when calling `createRuleSo`. `retryIfConflicts` must be disabled when a caller-supplied version is present (retry can't succeed with a stale token). Raw `SavedObjectsErrorHelpers.isConflictError` needs translating into a domain 409 (`{ message, attributes: { revision } }`) — that requires reloading the rule to fetch the current revision for the error body.
- **RuleResponse schema**: gains a `version` field (already exists on the SO but is not currently exposed in `RuleResponse`). Every GET/find/search endpoint that returns a rule needs to include it. This is many files.
- **Front end**: every place that holds a rule needs to store and echo `version`. Rule edit form, rule details page, prebuilt rules table, restore flyout, upgrade flyout. Also React Query cache entries and hooks that fetch and mutate rules.
- **Every mutation request schema**: PUT rule, restore, revert, upgrade _perform. All four gain `version?: string` in the request body.
- **Existing `revision` field on `RuleResponse`**: keep it — it's what the UI displays to users. `version` is machine-only.
- **Non-security callers of `rulesClient.update`** (synthetics): unaffected, they don't pass the new field.

**Pros**: This is what optimistic concurrency actually looks like. Every write is checked against the exact state the caller last observed, not against a domain-level counter that may or may not track the change the caller cares about. Also handles the case where a rule is mutated by a path that *doesn't* bump `revision` (e.g. actions-only edits via `bulkEditRuleParamsWithReadAuth`, background API-key rotations) — `version` bumps for those, `revision` doesn't. No `revision` gets tangled up in the alerting API contract as a client-pinnable value.

**Cons**: Much more complex to implement. Touches the alerting plugin, the RuleResponse schema, the security_solution request schemas, and every front-end place that reads or mutates a rule. Bigger PR, more review surface, more places to get wrong. Also: `version` is a Kibana-core concept that most UI code doesn't currently touch, so we'd be establishing a new pattern (albeit one Kibana core already documents via `SavedObject.version`).

Also: `version` bumps on writes that users don't care about (e.g. rule-execution-status updates on every rule run). If we surface `version` to the UI without care, a user opens a rule, waits five minutes without touching anything, and their edit gets rejected because the rule ran twice in the meantime and its `version` changed. Option B needs some care about *which* writes bump `version` — either by using `mapped_params`-style write partitions, or by having a separate "content version" concept that only bumps on content edits (which is basically `revision` again).

### Recommendation

Option A for the immediate fix. It closes the bug with a small, contained change and lines up with the UI contract that already exists.

Option B is the "right" long-term shape — full end-to-end OCC using the SO's actual version token — but it is a larger investment and needs some design work around which writes should invalidate a UI-held token. Worth doing later, not today.

## Open questions before implementing

- **PUT rule schema change** — adding `revision?: number` to `UpdateRuleRequestBody` is a public API surface change on a versioned route. Needs approval / docs update / decision on whether it will ever become required.
- **Bulk upgrade with `mode: ALL_RULES`** — the current per-rule revision check is skipped when the client doesn't send a revision. If we push `expectedRevision` down into `rulesClient.update`, we need to decide: does bulk mode omit the guard entirely (honest: "bulk = best-effort"), or does the handler load current revisions right before writing to make the check tight anyway?
- **UI for revert and upgrade** — restore has a proper modal, revert has a toast, upgrade has nothing. A server-side fix will start producing 409s these UIs don't handle gracefully today. Either they degrade to a plain error toast (acceptable-ish), or we do a follow-up to give them the same modal treatment as restore.
- **Where does `RuleRevisionConflictError` live?** — needs to be thrown from inside the alerting plugin and caught in security_solution routes. Simplest is re-exporting the class from `@kbn/alerting-plugin/server`; alternative is a well-known `code` on an existing error class.
- **Test coverage** — `detection_rules_client.restore_rule_from_history.test.ts` exists but I did not verify whether it currently mocks `rulesClient.update` in a way that would still pass with the new param. Same for the other three flows. Worth a look before scoping the PR.
