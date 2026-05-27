# PR #270446 — Instrument `DetectionRulesClient` with change tracking (v2)

- **Author:** @maximpn (`@elastic/security-detection-rule-management`)
- **Base:** `main` ← `changes-history/instrument-detections-rule-client`
- **Size at this revision:** 47 files, +1,267 / −293
- **State:** Open, REVIEW_REQUIRED. CI on `a9c7db5` flaky-passed (1 Jest flake + 1 Scout obs + 2 Defend Workflows Cypress flakes). 1 prior approval (`@jcger`).
- **HEAD commit reviewed:** `a9c7db5b75f` — "add default rule_install change tracking action"
- **Linked issue:** [#262502](https://github.com/elastic/kibana/issues/262502)
- **Last review baseline:** `b732fc3` (the first round of comments).

> This report supersedes the previous one. It tracks which v1 findings were addressed, what's new since `b732fc3`, and what is still pending.

---

## 1. Summary of changes since last review

| Commit | Subject | Addresses |
| --- | --- | --- |
| `b1fbdee` | Tighten `RuleChangeTrackingMetadata` shape | v1 Open Q (shape of `metadata`) |
| `be788a0` | Fix `rulesToInstall.length` → `rulesToUpdate.length` in legacy upgrade path | v1 Risk #1 |
| `386ed46` | Add `ruleDuplicate` instrumentation in bulk-actions route | v1 Risk: dead `ruleDuplicate` enum |
| `53bf6d4` | Instrument `rulesClient.delete()` in the alerting layer | v1 Follow-up: singular delete not logged |
| `ff494139` | Revert `exceptions_duplicate`, keep follow-up as plain `rule_update` | v1 design pushback on two-step duplication |
| `9450beca` | Stop setting `action: ruleInstall` in handlers/legacy install (DRC owns it now) | v1 Risk #3 (handler-defined action fragility) |
| `c9c3ed7` | Type-check fixes | — |
| `a9c7db5` | DRC's `createPrebuiltRule` hard-codes `action: ruleInstall` | v1 Risk #3 (final form) |

Net effect: every concrete bug flagged in v1 has been addressed in-PR. Two design choices remain open (see §3).

---

## 2. v1 findings → current status

| v1 finding | Status | Evidence |
| --- | --- | --- |
| **Risk #1** — `legacy_create_prepackaged_rules.ts` upgrade path used `rulesToInstall.length` for upgrade `bulkCount` | ✅ **Fixed** | `legacy_create_prepackaged_rules.ts:93-97` now uses `rulesToUpdate.length` |
| **Risk #2** — `importRule` overwrite branch dropped `bulkCount` | ✅ **Fixed** | `methods/import_rule.ts:74` now `{ action: ruleImport, ...changeTracking }` |
| **Risk #3** — `createPrebuiltRule` relied on every handler to inject `action: ruleInstall` | ✅ **Fixed** at the DRC layer | `detection_rules_client.ts:118-121` hard-codes the action; callers' `CreatePrebuiltRuleArgs.changeTracking` is narrowed to `<never>` (i.e. they cannot override `action`) |
| Stale `ruleSOs.length` fallback comments in alerting tests | ⚠️ **Not addressed in this PR** | Test comments remain; they no longer reflect runtime behaviour |
| `ruleDuplicate` enum was dead code | ✅ **Resolved** | `bulk_actions/route.ts:333-339` now passes `{ action: ruleDuplicate, metadata: { bulkCount: rules.length, originalRuleSoId: rule.id } }`. New `originalRuleSoId` field landed in `RuleChangeTrackingMetadata` to support this. |
| Two-step bulk-duplicate (rule create + exception update) emits two history entries | ✅ **Confirmed-by-design** | Second step intentionally falls through to `rule_update` (`bulk_actions/route.ts:365-369`). Author acknowledged the UX concern as out-of-scope. |
| Singular `deleteRule` not logged anywhere | ✅ **Fixed** | Alerting's `delete/delete_rule.ts:139-146` now calls `logRuleChanges` with `RuleChangeTrackingAction.ruleDelete`. `ruleDelete` was added to the alerting enum. The DRC's `deleteRule(args)` still does not accept `changeTracking` — the action is hard-coded inside alerting. |
| `metadata` shape was a `Record<string, unknown>` | ✅ **Tightened** | `kbn-alerting-types/rule_types.ts:34-44` now declares `RuleChangeTrackingMetadata` with named fields `bulkCount` + `originalRuleSoId`. Per-domain expansion will require alerting-types changes (intentional, per agreed direction). |
| `isEmptyObject` helper too narrow per `@jcger` | ✅ **Reworked** | `log_rule_changes.ts:81` now uses `every(metadata, isUndefined)` (lodash), which guards against partially-undefined objects. |

---

## 3. New findings on the latest revision

### 3.1 Redundant `bulkCount` computation outside `createPrebuiltRules` *(my inline comments on `a9c7db5`)*

`createPrebuiltRules` itself now provides a default `bulkCount: rules.length` (`logic/rule_objects/create_prebuilt_rules.ts:34-36`). At the same time, **all four** of its callers compute and pass `bulkCount` explicitly:

| Caller | Sets `bulkCount` as | Chunks before calling? | Redundant? |
| --- | --- | --- | --- |
| `perform_rule_installation_handler.ts:113-117` | `ruleInstallQueue.length` (pre-loop snapshot) | **Yes**, BATCH_SIZE=100 | **No** — required for correctness when chunked |
| `legacy_create_prepackaged_rules.ts:75-79` | `rulesToInstall.length` | No | Yes (equals `rules.length` inside wrapper) |
| `install_endpoint_security_prebuilt_rule.ts:85-89` | `ruleAssetsToInstall.length` (always 1) | No | Yes |
| `install_promotion_rules.ts:98-102` | `promotionRulesToInstall.length` | No | Yes |

**Recommendation:** keep the wrapper default (it's the safety net) and remove the redundant per-caller `installChangeTracking` blocks in the three non-chunked sites. Or remove the wrapper default and require all callers to set it. Either way is cleaner than today's "both, and the caller wins" pattern, which is what triggered my "are we duplicating?" comment.

Not a blocker — it's a soft design / consistency issue. I'd lean toward dropping the wrapper default so the API behaviour is always explicit at the call site.

### 3.2 `deleteRule` in DRC vs. alerting — instrumentation asymmetry

After `53bf6d4`, the situation is:

- **DRC's `deleteRule(args)`** — args is `{ ruleId }`, with **no `changeTracking` parameter**. The action and metadata cannot be set by callers.
- **DRC's `bulkDeleteRules(args)`** — args accepts `changeTracking?: SecurityRuleChangeTracking<never>` (no domain-specific action, but `metadata` can be passed).
- **Alerting's `rulesClient.delete()`** — hard-codes `action: ruleDelete` inside `application/rule/methods/delete/delete_rule.ts:142-144`. The public `delete()` signature does not accept `changeTracking`.

Result: deletes are now always logged with `rule_delete`, including those issued via `DELETE /api/detection_engine/rules`. ✅

Side-effect: the singular-delete path cannot ever record `bulkCount` (always missing). UI-side this is fine — every UI delete flow already routes through `bulkDeleteRules`. Direct API consumers of singular `DELETE` won't be able to attach a bulk count even if they perform a logical bulk operation client-side. Worth surfacing in the API docs once they exist, but **not** a blocker.

### 3.3 `bulkDeleteRules` `<never>` typing

`BulkDeleteRulesArgs.changeTracking?: SecurityRuleChangeTracking<never>` (`detection_rules_client_interface.ts:65-68`) effectively forbids overriding the action — alerting always logs `ruleDelete`. This is the right call for now; no security-specific delete actions are needed yet (`ruleUninstall` may be one to add later, in a separate PR if/when we surface "remove prebuilt rule" as a distinct UX).

### 3.4 Bulk duplicate produces two history entries per rule

Confirmed by reading `bulk_actions/route.ts:298-377` again on this HEAD:

1. `rulesClient.create(..., changeTracking: { action: ruleDuplicate, metadata: { bulkCount, originalRuleSoId } })` — emits a `rule_duplicate` entry.
2. If exceptions are to be duplicated, a follow-up `rulesClient.update(..., changeTracking: { metadata: { bulkCount } })` — emits a `rule_update` entry (no explicit action, falls through to alerting default).

So a single duplication of 5 rules with exception duplication enabled produces **5 `rule_duplicate` + 5 `rule_update`** entries. Author and I both agreed in-thread that the cleanup belongs in a separate PR re-shaping rule duplication to a one-step backend op. Not a blocker for this PR.

### 3.5 New integration test coverage

A meaningful integration suite landed at `x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/rule_management/trial_license_complete_tier/change_tracking.ts` (+503 lines, replacing the older `rule_history.ts` which was −233). Worth a focused walkthrough during review: action-coverage matrix, `bulkCount` assertions, prebuilt vs. custom rule scenarios.

I haven't audited it line-by-line yet — flagging as a self-followup for the next pass.

---

## 4. Follow-up checklist

**In-PR (should land before merge):**

- [ ] Pick a direction for §3.1 — either remove the wrapper default in `createPrebuiltRules` or remove the redundant `installChangeTracking` in the three non-chunked callers. Current "both, caller wins" is harmless but confusing.
- [ ] Audit the new `change_tracking.ts` integration test (§3.5) — does it cover at minimum: `rule_install`, `rule_upgrade`, `rule_revert`, `rule_import` (create + overwrite branches), `rule_duplicate`, `rule_delete`, `rule_update`, `rule_create`, and `bulkCount` correctness for chunked vs non-chunked paths?
- [ ] Optional: clean up stale comments in `create_rule.test.ts:4995`, `snooze_rule.test.ts:246`, `unsnooze_rule.test.ts:226`, `update_rule_api_key.test.ts:626` that still mention a non-existent "fall back to ruleSOs.length" behaviour. Trivial.

**Follow-up PR (#262502 next items, per author's reply on `create_rule.ts:59`):**

- [ ] Route bulk `enable` / `disable` through DRC for consistency, or document why they keep their pre-existing self-logged `totalNumOfRules`.
- [ ] Add `bulkEdit` to `IDetectionRulesClient` and route the two existing sinks in `logic/bulk_actions/bulk_edit_rules.ts` through it. Today bulk edit bypasses DRC entirely (still `rule_update` with `bulkCount` from alerting defaults — semantically fine, just structurally inconsistent).
- [ ] SIEM migrations `installCustomRules` — pass `changeTracking: { action: ruleInstall, metadata: { bulkCount } }` (or a dedicated `ruleMigrateInstall` action). Currently logs as plain `rule_create`.
- [ ] Reshape bulk-duplicate to a single backend op so the follow-up exception update no longer leaks a spurious `rule_update` per rule (§3.4).
- [ ] Consider whether `originalRuleSoId` on `RuleChangeTrackingMetadata` should be generalised (`derivedFromSoId`?) so it can also describe other clone-like flows (e.g. revert restoring from a target version).

---

## 5. Open questions

1. **§3.1 design:** which way does the team prefer — caller-side or wrapper-side `bulkCount`? My preference: caller-side, explicit, no wrapper default. Worth a quick decision before merging.
2. **§3.4 UX:** is the "duplicate-with-exceptions → 2 history entries" pattern acceptable to product? If users will see the per-rule history in 8.x onward, the spurious `rule_update` may be confusing.
3. **`bulkCount` on `import_rules`:** `import_rules/route.ts` passes `validatedResponseActionsRules.length` (per v1). That's the count *after* validation filtering, not the user's attempted count. Still worth confirming with the author whether this matches the desired UX, especially when some rows fail validation.
4. **Integration test gating:** is `change_tracking.ts` part of any CI lane that runs by default on this PR? Several jobs were red on earlier commits — worth confirming the test is actually exercised on the green build of `a9c7db5`.

---

## 6. Recommended review approach

Given the scope and that all v1 bugs are fixed:

1. Quick scan of `change_tracking.ts` integration test to confirm coverage matches the action enum.
2. Decide on §3.1 (small style call, not blocking).
3. Approve, defer §4 follow-ups to #262502.

The PR is in good shape. The hardening that happened between `b732fc3` and `a9c7db5` is exactly what we asked for in v1, and the new typing (`<never>` constraints, `RuleChangeTrackingMetadata`) makes future regressions much harder.
