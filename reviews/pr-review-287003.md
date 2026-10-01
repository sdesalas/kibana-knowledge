# PR Review: #287003 — [Security Solution] Treat 404 errors as idempotent success in rule bulk delete method

**PR:** [elastic/kibana#287003](https://github.com/elastic/kibana/pull/287003) by @jr-araque

**Scale:** Small PR.

Related: [#276452](https://github.com/elastic/kibana/issues/276452) (this bug), [#257234](https://github.com/elastic/kibana/issues/257234) (optimize bulk rule deletion), [#264906](https://github.com/elastic/kibana/issues/264906) (bulk-ops epic). Slack: [DEX thread](https://elastic.slack.com/archives/C0B6959RC7K/p1787668321843139).

---

### Context / Motivation

MSSP users doing high-volume bulk rule management (offboarding a space, wiping a large rule set) reported that `POST /api/detection_engine/rules/_bulk_action` with `delete` sometimes returns HTTP 500 even though the rules are gone. Clients trust the error, retry, and fire extra find-rules calls, which adds load.

From [#276452](https://github.com/elastic/kibana/issues/276452):

> The bulk rule deletion action (`_bulk_action` with the delete action) intermittently responds with an HTTP 500 error **even though the targeted rules are actually deleted successfully**.

> Because the failure is spurious, the API response cannot be trusted: integrations that treat the 500 as a real failure end up retrying the operation and/or issuing follow-up "find rules" requests to verify the real state.

The first version of this PR treated 404s as success inside Alerting's `bulkDeleteWithOCC`. Steven pushed back on that in the [DEX thread](https://elastic.slack.com/archives/C0B6959RC7K/p1787668321843139):

> I think alerting framework is doing correctly to return the `errors` bucket with `404` along with other types of errors.
>
> I would put the fix inside `security_solution` and how we interpret that `404`. So _we_ take it out of the `errors` bucket ourselves and we dont footgun in the process with a `500`.

Maxim agreed. Reinaldo moved the remapping into the bulk-actions route. Steven then asked to put it on the domain client instead of a route util:

> I like the approach much better now since its all inside our business domain, but maybe we can inline instead of create a new util and 2 interfaces. Or better even add the logic to `detectionRulesClient.bulkDeleteRules`. So we end up with 10 lines instead of 30.

Latest commit (`3459f0a`) does that: `bulkDeleteRules` now takes full rule objects, remaps per-rule 404s to the `rules` bucket, and the route just forwards the result. Steven confirmed:

> Yep, something along those lines. I think `detectionRulesClient` should 'own' the bit that treats 404s as 'already deleted' and excludes them from the output. Rather than the route or alerting framework.

The PR description still describes the previous (route-level) version of the fix.

---

### Validating the issue — does this PR address it?

**The concern is technically valid. The PR addresses the Alerting-layer 404-after-delete race correctly. It does not cover a second 500 path in Security Solution's own fetch step.**

- **Where the problem manifests** — Detection `_bulk_action` delete fetches rules, then calls `detectionRulesClient.bulkDeleteRules`, which chunks ids and calls Alerting `rulesClient.bulkDeleteRules`. Alerting PIT-finds, then `savedObjectsClient.bulkDelete`. If another request already deleted those SOs, each status is a 404, pushed into Alerting's `errors`. The Detection route copies those into `buildBulkResponse`, which returns HTTP 500 whenever `errors.length > 0` (`bulk_actions_response.ts`), with message "Bulk edit failed".
- **Why the old approach was a problem** — Delete's goal state is "rule is gone." A 404 on delete means that state is already reached. Reporting it as a failure made clients retry and re-query.
- **How the PR fixes it** — `detectionRulesClient.bulkDeleteRules` now takes the fetched rule objects. For each Alerting error with `status === 404` whose id is in that set, it moves the original rule into `rules` and drops the error. The route then sees an empty `errors` array and returns HTTP 200. Alerting is unchanged.
- **Residual caveat** — The route fetches rules *before* calling `bulkDeleteRules` (`fetchRulesByQueryOrIds`). If the second request uses `ids` and the first already deleted them, that fetch still records "Rule not found" and `buildBulkResponse` still 500s. Query-based full-space deletes (the MSSP offboarding case, and the gist repro) skip that: the query just returns fewer hits. The race this PR fixes is the one where both fetches succeeded and both then hit Alerting `bulkDelete`.

---

### Summary

`detectionRulesClient.bulkDeleteRules` now takes full rule objects instead of ids. After each Alerting chunk, a per-rule 404 is treated as "already deleted": the original rule is counted in `rules`, not `errors`. The bulk-actions route passes `rules` through and still 500s on any remaining error. Alerting is untouched. Stated intent matches the diff; the PR description still talks about doing this in the route, which is no longer true.

---

### Files touched

- **Domain method** (`methods/bulk_delete_rules.ts`) — the actual fix. Builds `rulesById` from the input, remaps 404s, leaves other errors alone. Also the `no-continue` lint failure (see Risks).
- **Client wrapper + interface** (`detection_rules_client.ts`, `detection_rules_client_interface.ts`) — `BulkDeleteRulesArgs.ruleIds` becomes `rules: RuleAlertType[]`. Only caller is the bulk-actions route.
- **Route** (`bulk_actions/route.ts`) — passes `{ rules }` instead of mapping to ids first.
- **Route tests** (`route.test.ts`) — two new delete-action cases. Both mock `detectionRulesClient.bulkDeleteRules` wholesale, so they never hit the 404 loop.
- **Change-tracking tests** (`detection_rules_client.change_tracking.test.ts`) — updated for the new signature; still only assert `bulkCount`.

---

### Flow trace

1. Client calls `POST /api/detection_engine/rules/_bulk_action` with `action: delete` (query `""` in the MSSP case).
2. Route fetches matching rules (`fetchRulesByQueryOrIds`), then `detectionRulesClient.bulkDeleteRules({ rules })`.
3. That derives ids, chunks at 1000, and calls Alerting `rulesClient.bulkDeleteRules`.
4. Alerting OCC: PIT-find decrypted rules, `untrackRuleAlerts` + `softDeleteGaps` on the found set, then `bulkDeleteRulesSo`. Per-rule 404 stays in Alerting `errors`. Task removal / API-key invalidation / `logRuleChanges` only run for SO-delete successes.
5. Detection `bulkDeleteRules`: success ids from `result.rules`; 404s whose id is in `rulesById` are appended from the original fetched objects; anything else stays in `errors`.
6. Route: `errors.push(...bulkDeleteResult.errors)`, `deleted = bulkDeleteResult.rules`.
7. `buildBulkResponse`: empty `errors` → HTTP 200; non-empty → HTTP 500, unchanged.

---

### Assumptions

- A 404 from `savedObjectsClient.bulkDelete` after a successful PIT find means the SO is already gone (concurrent delete, or deleted between find and delete). Saved Objects also maps "not in this namespace" and "index missing" to 404; both are unlikely here because the PIT finder already loaded the docs in `context.namespace`.
- The request that actually deleted the SO also ran task removal and API-key invalidation. The 404 branch in Alerting still skips those; this PR does not change that.
- `retryIfBulkOperationConflicts` only retries 409. 404s are not retried; Detection now treats them as success, so they never surface as HTTP 500.
- Query-based Detection bulk delete is the MSSP case. Ids-based fetch 404s are out of scope.
- `error.rule.id` matches `RuleAlertType.id` (the SO id). Alerting sets `rule.id` from `status.id` on the bulkDelete result, so this holds for the race this PR cares about.
- `IDetectionRulesClient.bulkDeleteRules` has no other callers. Confirmed in-tree: only the bulk-actions route.

---

### Risks

1. **Explicit-ID deletes are not fully idempotent.** If request B fetches the same ids after request A has deleted them, `bulkGetRules` reports `"Rule not found"` and the route returns HTTP 500 before reaching this PR's 404 handling. Replaying an explicit-ID delete after it completes therefore still fails, which matters for the client retry scenario and makes the PR's idempotency narrower than its title suggests.
2. **The 404→deleted loop is untested.** Route tests mock `detectionRulesClient.bulkDeleteRules` and return a pre-resolved `{ rules, errors: [] }`. `change_tracking.test.ts` only checks `bulkCount`. Reverting the loop would not fail any test in this PR. Claude Reviewer already flagged this; Steven +1'd it ([discussion](https://github.com/elastic/kibana/pull/287003#discussion_r4026128981)).
3. **Cleanup skip on 404 is unchanged.** If the winner deletes the SO and then fails before `tryToRemoveTasks` / `bulkMarkApiKeysForInvalidation`, the loser will not pick that cleanup up. Pre-existing Alerting behaviour, not introduced here. `untrackRuleAlerts` / `softDeleteGaps` still ran on the PIT set before `bulkDelete`.
4. **PR description and "how to test" are stale.** They still say the route remaps 404s, and that checking out `route.ts` from `main` makes the new 404 test fail. After `3459f0a` that test would still pass, because it never calls the real method.

---

### Open questions

1. Worth a direct unit test on `methods/bulk_delete_rules.ts` that feeds a 404 `BulkOperationError` and asserts the rule moves into `rules` (plus a non-404 stays in `errors`, plus the defensive "404 id not in input" case)? That's the comment already +1'd on the PR.
2. Should ids-based overlapping deletes also count fetch-time "Rule not found" as success? Out of scope for the query-based MSSP case, but it is still a 500 path for `ids`.
3. Should the PR description be updated to match `3459f0a` (client owns the remapping, not the route)?

---

### Notes for your codebase map

- Detection bulk delete is a thin wrapper: chunk 1000 → Alerting `rulesClient.bulkDeleteRules` → pass `errors`/`rules` to `buildBulkResponse`. Any non-empty `errors` is HTTP 500 with "Bulk edit failed", including for delete.
- `IDetectionRulesClient` is the right place for Detection-specific interpretation of Alerting's per-rule statuses. Alerting reports what happened; Detection decides whether a 404-on-delete is a failure.
- Alerting bulk delete is find-then-delete (PIT finder, then `bulkDelete`). 404s are a TOCTOU product of that, not a thrown exception. `retryIfBulkOperationConflicts` only retries 409.
- Because 404s stay in Alerting's `errors` bucket, `logRuleChanges` only fires on the winning request. Putting the remapping in Detection (rather than Alerting) avoids a duplicate `ruleDelete` history event.
- Saved Objects `bulkDelete` 404 is `createGenericNotFoundError` (missing doc, missing from namespace, or missing index).
- Kibana eslint bans `continue` (`no-continue`).

---

### Follow-up Review Activities

1. **Expanded the residual caveat (ids-based fetch 404).** Delete is two steps in `route.ts`: look up rules, then delete them. Fetch errors are copied into the handler `errors` array *before* `bulkDeleteRules` runs. `buildBulkResponse` 500s whenever that array is non-empty. Lookup splits in `fetchRulesByQueryOrIds`: `ids` goes through `bulkGetRules` and turns a 404 into `"Rule not found"`; `query` goes through `findRules` and always returns `errors: []` (missing rules just aren't in the hit list). The existing route test `"ids params can't be fetched"` locks the 500. So a concurrent `ids` delete still 500s at fetch time; a concurrent `query` delete (MSSP offboarding) does not, and is the race this PR actually fixes (both lookups succeed, then Alerting `bulkDelete` 404s).

2. **Confirmed Risk 1 against a live local Kibana at PR commit `3459f0a`.** Sequential `POST /api/detection_engine/rules/_bulk_action` requests with `action: "delete"` and explicit saved-object `ids` produced:
   - A random nonexistent ID returned HTTP 500 with `"Rule not found"`.
   - Deleting the installed rule returned HTTP 200 and one successful deletion.
   - Immediately deleting that same ID again returned HTTP 500 with `"Rule not found"`.
   - Repeating the same request after five seconds also returned HTTP 500.

   This confirms explicit-ID delete is not idempotent once the rule is missing; the failure is deterministic and occurs in the pre-delete fetch path, not only in an overlapping-request race.

3. **Implemented the proposed actionable error contract locally.** `fetchRulesByQueryOrIds` now represents missing-ID lookup failures as Boom 404 errors for both partial and all-missing `bulkGetRules` outcomes. Because the helper is shared, this applies consistently to every explicit-ID bulk action. The overall bulk response remains HTTP 500, while each normalized `"Rule not found"` entry carries `status_code: 404`. Route coverage passes for partial and all-missing cases (`40/40` tests), and lint passes.
