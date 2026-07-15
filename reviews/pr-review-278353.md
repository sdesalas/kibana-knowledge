# PR Review: #278353 — [Security Solution][Serverless] Fix unresolved usernames in rule changes history

**PR:** [elastic/kibana#278353](https://github.com/elastic/kibana/pull/278353) by @maximpn

**Scale:** Small PR — one narrow behavior fix (~40 lines of real change, the rest is threading `userProfileService` through test setup and TS project refs).

**Resolves:** [#278311](https://github.com/elastic/kibana/issues/278311). Epic (internal): `security-team#12367`.

---

### Summary

Rule changes history was showing raw user identifiers (e.g. Serverless synthetic UIDs like `u_...`) instead of a human-readable name. The fix threads `coreStart.userProfile` into `DetectionRulesClient`, bulk-resolves the user IDs present in each fetched history page against Kibana user profiles, and swaps `user.name` in the response for the profile's `full_name` — falling back to the raw `user.name` when no matching profile (or no `full_name`) is found.

Stated intent matches the diff.

### Files touched

- **Response mapping (the actual fix):**
  - `methods/get_history_for_rule.ts` — bulk-resolves profiles for all `user.id`s in the page before mapping.
  - `methods/utils/map_rule_history_item.ts` — new optional `userProfilesById` arg; picks `full_name` when known.
- **Wiring:**
  - `detection_rules_client.ts` — adds `userProfileService: UserProfileServiceStart` to the client params, forwards it into `getHistoryForRule`.
  - `request_context_factory.ts` — passes `coreStart.userProfile` when creating the client.
  - `tsconfig.json` / `moon.yml` — add `@kbn/core-user-profile-server` and `-server-mocks` project refs.
- **Tests:** 11 `detection_rules_client.*.test.ts` files each get one line adding `userProfileService: userProfileServiceMock.createStart()` — required because the client's factory signature changed. Only `get_history_for_rule.test.ts` and `map_rule_history_item.test.ts` add real coverage for the new logic.

### Flow trace

`GET /internal/…/rule_history/{ruleId}` → `route.ts` → `detectionRulesClient.getHistoryForRule({ ruleId, page, perPage })` → `getHistoryForRule` runs two concurrent `rulesClient.getHistory` calls (page + oldest) → `resolveUserProfiles(userProfileService, fetchedItems)` collects `user.id`s into a `Set`, short-circuits to an empty `Map` when the set is empty, otherwise calls `userProfileService.bulkGet({ uids })` → each fetched item is mapped via `mapRuleHistoryItem(current, next, userProfilesById)` → `resolveUserName` returns `profile.user.full_name || user.name`.

Not touched: the `restoreRuleFromHistory` path — that endpoint returns a snapshot, not a user list, so no resolution needed.

### Assumptions

- `coreStart.userProfile.bulkGet` is safe to call without a `KibanaRequest`. Confirmed in `src/core/packages/user-profile/server/src/service.ts` — `UserProfileBulkGetParams` only takes `uids` (+ optional `dataPath`), unlike `getCurrent`.
- `UserProfile.user.full_name` is populated for real Serverless users. The PR description's "After" screenshot suggests this holds, but it's the whole point of the fix — if `full_name` is empty for the same synthetic Serverless users that motivated the bug, the fallback returns the raw name again and nothing visible changes.
- `bulkGet` doesn't need pagination for the returned set. History pages are `perPage <= 20` items, so at most ~20 UIDs (usually many fewer once deduped), well within any sane bulk-get limit.
- `RuleChangeHistoryDocument['user'].id` is optional (`id?: string`) — confirmed in `kbn-change-history/src/types.ts`. The `flatMap` filter and `resolveUserName`'s `user.id ? ...` guard both handle it.

### Risks

- ~~`bulkGet` failures now fail the whole rule-history endpoint. Before this PR the endpoint didn't depend on user profiles at all; now it does. If the user profile ES index is unavailable or the call throws for any reason, users see an error instead of the (previously acceptable) raw usernames. There's no `try/catch` fallback to an empty map. Not necessarily wrong — `security_solution/server/lib/timeline/routes/notes/get_notes.ts` uses the same pattern without try/catch — but worth a conscious call.~~ **Resolved** — raised as a comment to the author (see activity #3); ball is in their court.
- ~~Silent degradation on Serverless if `full_name` is empty. If the underlying issue is that synthetic Serverless users don't have a populated `full_name`, this fix does nothing for them and it's hard to tell from the response alone (the raw UID just keeps appearing). The screenshot suggests it does work; still worth confirming for the specific user types that motivated the report.~~ **Dropped** — cosmetic nit; happy path confirmed on Serverless (activity #1), and the fallback keeps the raw name in the edge case anyway.
- ~~Extra ES round-trip per page. One additional `bulkGet` per history page fetch. Small, but no cache — same user profile is refetched every request and every page. Fine at current usage.~~ **Dropped** — acceptable trade-off; the fix adds enough value to warrant one extra bounded call. A cache would add more complexity than it saves (see activity #5 for the bounded-input analysis).

### Open questions

- Should `bulkGet` errors degrade gracefully to raw names, or is failing the endpoint the right choice? The current behavior is a regression in fault tolerance vs. before the PR.
- Have you confirmed on Serverless that the synthetic users in the bug report actually have `full_name` populated in their profile? (i.e. that the "After" screenshot isn't from a different test user).
- `dataPath` isn't passed to `bulkGet`. Fine here because we only need `user.full_name` which is returned by default. Worth a comment though? Probably not — the code is short enough to speak for itself.
- Does the `restore_rule_from_history` endpoint (or the UI rendering the "restored by" info anywhere) need the same treatment, or does it already resolve names through a different path?

### Notes for your codebase map

- `DetectionRulesClient` is constructed per-request in `RequestContextFactory.getDetectionRulesClient()`, but the dependencies it receives (`coreStart.userProfile`, `actionsClient`, `rulesClient`, etc.) come from `coreStart` and are stable across the plugin lifetime.
- Rule change history documents (`RuleChangeHistoryDocument` from `@kbn/change-history`) store `user: { id?, name }` where `id` is the user *profile* UID and `name` is the login username. The UI wants a friendly display name, which lives on `UserProfile.user.full_name`.
- Pattern for resolving profiles from a batch of stored IDs: collect a `Set<string>` of UIDs, call `userProfile.bulkGet({ uids })`, build a `Map<uid, UserProfile>` for lookup during mapping. Same pattern as `security_solution/server/lib/timeline/routes/notes/get_notes.ts`.
- The 11-file test churn is a hint: `createDetectionRulesClient` params object is starting to accumulate — every new dependency requires touching every method's test. Not this PR's problem, but worth noting for future refactors.
- `@kbn/change-history` is consumed by multiple teams (at least Security and Workflows) and none get user-friendly display names by default — see activity #7. A shared resolver in the server package would fix it for everyone.

### Review activities

1. **Confirmed happy path on Serverless.** Author tested locally on Serverless — user profile lookup resolves the display name correctly. Answers the second open question above.

2. **Traced the "no profile id" case end-to-end.** Persisted docs allow `user.id?: string` (`kbn-change-history/src/types.ts:27`) — set from the optional `userProfileId` passed to `client.log` (`kbn-change-history/src/client.ts:206`). On the read side, three layers each handle a missing id:
   - `resolveUserProfiles` filters items whose `user.id` is falsy before building the `Set`, so a page of id-less items short-circuits to an empty `Map` and never calls `bulkGet`.
   - `mapRuleHistoryItem` still emits the user object with `id: undefined`; JSON serialization drops it, and the response schema (`rule_history_route.gen.ts:43`) has `id: z.string().optional()`, so that's valid.
   - `resolveUserName` guards on `user.id` — undefined id → `profile` is `undefined` → returns `user.name` (raw login). Same fallback also covers two adjacent cases: id present but profile deleted/deactivated (map miss), and id present but `full_name` empty/undefined (`||` fallback).
   Net: rows without a profile id show the raw login name, matching pre-PR behavior. No regression.

3. **Left two comments on the PR:**
   - [`request_context_factory.ts:210`](https://github.com/elastic/kibana/pull/278353#discussion_r-request_context_factory) — nit suggesting `userProfile` as a shorter parameter name; type (`UserProfileServiceStart`) preserves intent.
   - [`get_history_for_rule.ts:83`](https://github.com/elastic/kibana/pull/278353#discussion_r-get_history_for_rule) — echoed the bot's suggestion to wrap `bulkGet` in `try/catch` and fall back to an empty map, so the endpoint degrades to raw login names instead of failing. Ties directly to the first open question in this review — the author's response there will resolve it.

4. **Focused review: architecture + solution-integration.** One pass through each lens.

   **Needs action:** *none.* No new blockers, no new PR comments to leave. The one pre-existing smell called out below is not this PR's problem.

   **Checked, clean:**
   - **Placement.** *(Updated — see activity #7.)* Name resolution sits in `security_solution/detection_rules_client/methods/get_history_for_rule.ts`, one method deep. The only other consumer of `RulesClient.getHistory` inside `security_solution` is `fetch_rule_with_history.ts` (restore path, no user-name display) — so within the plugin, no sibling is being left behind. **However:** the workflows team consumes `@kbn/change-history` directly and hits the same display problem, so there is now a case for lifting the resolver into the shared package. Agreed as follow-up work rather than blocking this PR.
   - **Dependency direction.** `security_solution` → `@kbn/core-user-profile-server`. Correct direction (plugin → core). `moon.yml` and `tsconfig.json` updated symmetrically. No cycles.
   - **`bulkGet` contract.** Signature (`{ uids: Set<string>, dataPath? }`), no `KibanaRequest` needed, may return fewer items than requested (missing UIDs silently absent — `Map` lookup handles it). Throws on ES errors — already covered by the comment left on the author (activity #3).
   - **`dataPath` correctly omitted.** `full_name` sits on the always-returned `user` object, not on the optional `data` payload. No `dataPath: '*'` needed.
   - **Read-time vs write-time is the right choice.** `kbn-change-history` stores only `user.id` + login `name`. Write-time resolution would freeze names; read-time matches sibling patterns (Timeline notes, alerting-v2 assignees, cases).
   - **`coreStart.userProfile` reference is stable.** Passed once through `request_context_factory.ts` per request, but the underlying service reference is long-lived. No per-request instantiation, no leak.
   - **Out of focus.** Response schema (`rule_history_route.gen.ts:43`) already treats `user.id` as optional — no api-contract concern.

   **Noted for the codebase map, not for this PR:**
   - **DI aggregator smell.** `DetectionRulesClientParams` grows `userProfileService` for one method's benefit; 11 test files each need the mock. Pre-existing pattern; every new dependency forces edits to every method-test. Logged in "Notes for your codebase map" for a future refactor — not raising as a Risk here.

5. **Investigated whether the `bulkGet` call needs its own batching.** Answer: no, the platform already handles it and the caller's input is bounded.
   - `security` plugin's `bulkGet` internally chunks UIDs at 50 per request and runs up to 5 concurrent batches (`x-pack/platform/plugins/shared/security/server/user_profile/user_profile_service.ts:45-46`, batching loop at `:504-509`). Reason is technical: the underlying ES bulk-get-user-profile API is a GET, so URL length forces batching.
   - Caller-side upper bound: route schema caps `per_page` at 100 (`rule_history_route.gen.ts:85`), and `get_history_for_rule.ts:44` fetches `size: perPage + 1` → at most 101 unique UIDs after dedup. That's 3 batches worst case (50+50+1), one concurrent round. In practice dedup collapses this to a handful.
   - Adding another batching loop in `resolveUserProfiles` would duplicate platform work and make a bounded input look unbounded — over-engineering. Trust the `bulkGet` contract.
   - Resolves Risk #3 (dropped as acceptable — see risks section).

6. **Focused review: clean-code + over-engineering.** One pass through each lens.

   **Needs action:** *none.* Everything below is at nit level; no PR comments warranted.

   **Nits (noted but not blockers):**
   - `get_history_for_rule.ts:75` — `resolveUserProfiles` types `items` as anonymous `Array<{ user?: { id?: string } }>` rather than the canonical `RuleChangeHistoryDocument[]` that the module already imports. Structural typing works today; will silently drift if `user` gains a required field on the canonical shape. Small type-hygiene nuance riding under clean-code.
   - `map_rule_history_item.ts:20` — `userProfilesById: Map<...> = new Map()`. The only production caller (`get_history_for_rule.ts:61`) always passes the map; the default exists purely for backward-compat with earlier tests. Marginally over-engineered but cheap; removing it would churn a few tests for negligible gain.

   **Checked, clean:**
   - Helper extraction (`resolveUserName`, `resolveUserProfiles`) is right-sized. Each helper is 3–8 lines, names one concept, and reads well at the call site.
   - `profile?.user.full_name || user.name` correctly falls back for both missing profile *and* empty-string `full_name` (`||`, not `??`).
   - Empty-`uids` short-circuit in `resolveUserProfiles` is defensive but zero-cost — fine to keep as executable documentation.
   - `user.id ? userProfilesById.get(user.id) : undefined` guard is required for TypeScript narrowing (`Map<string, UserProfile>.get(undefined)` fails type-check). Not redundant.
   - `userProfilesById` naming is three words but conveys shape at the call site; renaming to `profiles` would be shorter but less self-documenting. Left alone per style rule "don't rename unless asked".
   - No dead code, no unused imports, no `try/catch` masking errors, no defensive branches for cases the write path can't produce.

7. **Slack conversation — another team hits the same problem; follow-up agreed.** Yngrid Coello (workflows team) confirmed on Slack that their consumer of `@kbn/change-history` shows the same raw-UID display issue. Quote:

   > this is also happening to us and potentially will happen to anyone using `@kbn/change-history`. Is there a way to solve this for everyone? Or at least extract some utils that can be pushed to the shared server package?

   Proposed general fix: thread `userProfileService` into `getHistory()` on `@kbn/change-history` itself, and either replace `user.name` with the resolved value or add an optional `user.full_name` on the returned document. That change would need ResponseOps approval and risks slipping today's BC window.

   Agreed plan (with Yngrid):
   - Land this PR as the Security-only fix so today's BC isn't blocked.
   - Follow up with a shared fix in `@kbn/change-history` server package.
   - Workflows picks up the shared fix once merged; Security switches off the local resolver at that point.

   Materially updates the "Placement" non-finding in activity #4 — see the in-place `(Updated — see activity #7)` marker there.

8. **Focused review: remaining lenses (api-contract, test-coverage, observability, type-hygiene, rbac, memory, performance, security, gating, concurrency, documentation, dead-code, i18n).** Sweep across everything not yet covered.

   **Needs action:** *none.* Two soft flags below worth a moment of thought, otherwise this diff is quiet across all remaining lenses.

   **Soft flags (worth thinking about, not asking for changes):**
   - **api-contract — semantic shift on `user.name`.** Response schema is unchanged (`user: { id?, name }`), but `user.name` now means "display name (`full_name` if available, else login)" rather than "login username". Route is `access: 'internal'`, so external consumers shouldn't be relying on the old semantics. Any internal consumer that was using `user.name` for correlation against auth logs (unlikely) would see a semantic drift. Worth noting in the release-note description, though `release_note:skip` is already applied.
   - **test-coverage — gaps for dedup and error paths.** `get_history_for_rule.test.ts` covers happy path + no-profile fallback. Not covered:
     - Multiple items sharing a `user.id` → assert `bulkGet` is called with a deduped `Set`.
     - Multiple distinct `user.id`s in one page → assert all uids are gathered.
     - Items without any `user.id` → assert `bulkGet` is *not* called (short-circuit).
     - `bulkGet` throws → asserts the endpoint's failure mode (relevant to Risk #1's follow-up decision).
     None are correctness gaps, since the behavior is exercised incidentally by other tests and by `map_rule_history_item.test.ts`. But if the `try/catch` fallback lands (per PR comment in activity #3), add the throw-behavior test alongside.

   **Checked, clean:**
   - **type-hygiene.** `UserProfile` (canonical) used consistently. `RuleChangeHistoryDocument['user']` typing used in `resolveUserName`. Only quirk is the anonymous shape on `resolveUserProfiles`'s `items` param, already noted as a clean-code nit in activity #6.
   - **rbac.** Route still gated by `RULES_API_READ`. `bulkGet` returns fields (`username`, `full_name`) that any authenticated user can already look up; pre-PR the endpoint already exposed the login username. No privilege escalation.
   - **memory / performance.** Input bounded (perPage ≤ 100 → ≤ 101 UIDs, deduped further). No retention, no unbounded growth. Already covered in activity #5.
   - **security.** No new user input crosses a trust boundary. UIDs come from server-controlled docs. No injection surface.
   - **gating.** `ENABLE_RULE_CHANGES_HISTORY_SETTING` gate on the route is untouched.
   - **concurrency.** Existing `Promise.all` for the two `getHistory` calls unchanged; `bulkGet` is sequential after `Promise.all` resolves, no shared mutable state.
   - **observability.** `withSecuritySpan('DetectionRulesClient.getHistoryForRule', …)` still wraps the whole flow. `bulkGet` sits inside that span without its own child span — if it becomes the slow part, an operator sees "getHistoryForRule slow" without knowing which sub-op. Minor, not worth a sub-span today.
   - **documentation.** No JSDoc added; the new helpers are short enough that names speak for themselves.
   - **dead-code / i18n.** None applicable — no user-facing strings, no orphaned exports.
