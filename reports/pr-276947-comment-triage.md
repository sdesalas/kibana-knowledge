# PR #276947 comment triage — Rule versioning / change history

**PR:** [elastic/kibana#276947](https://github.com/elastic/kibana/pull/276947) — *[Alerting V2] Rule versioning using change history datastream*  
**Author:** @adcoelho  
**Branch checked:** `alerting-v2-rule-versioning` @ `0e75b2bd`  
**Date:** 2026-07-30  

**Method:** All 61 review threads fetched via GraphQL. Each claim verified against current code — GitHub’s resolved/unresolved flag was **not** trusted.

**Counts (by verification, not GH flags):** ~35 clearly addressed · ~10 not addressed · ~8 unsure / trap / deferred

---

## Themes (comments grouped)

Themes below are the recurring concerns raised by multiple people (or the same concern resurfacing across AI + human reviews). Status is **verified against code**, not GitHub resolve state.

Sorted by number of related review threads (most discussed first).

### 1. Scout / test coverage for change history (9 threads)

**Status: Addressed in spirit; placement mismatch**

> **@sdesalas** ([T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799)):
>
> We should find a way to check change histories have been added correctly here. Also in the update/upsert rule integration tests. Making sure to check not just the action but the payload shape as well.

Antonio claimed additions on create/update specs ([dcbd1e8](https://github.com/elastic/kibana/pull/276947/commits/dcbd1e8a52b9066379ba6edfe4b1376c59b80c21)). Actual coverage lives in a dedicated `rule_history.spec.ts` (+ helper service). Create/update route specs themselves have **no** `ruleChangesHistory` assertions.

Also: unit tests for the service ([T3](https://github.com/elastic/kibana/pull/276947#discussion_r3543390267)) — done. SO fixture population ([T4](https://github.com/elastic/kibana/pull/276947#discussion_r3550676521) / [T13](https://github.com/elastic/kibana/pull/276947#discussion_r3569240016) / [T20](https://github.com/elastic/kibana/pull/276947#discussion_r3594114175) / [T38](https://github.com/elastic/kibana/pull/276947#discussion_r3636984133)) — done. Scout helper duplication into `@kbn/scout` ([T52](https://github.com/elastic/kibana/pull/276947#discussion_r3672726512)) — not done, nit.

**Related threads:** [T3](https://github.com/elastic/kibana/pull/276947#discussion_r3543390267), [T4](https://github.com/elastic/kibana/pull/276947#discussion_r3550676521), [T13](https://github.com/elastic/kibana/pull/276947#discussion_r3569240016), [T20](https://github.com/elastic/kibana/pull/276947#discussion_r3594114175), [T38](https://github.com/elastic/kibana/pull/276947#discussion_r3636984133), [T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799), [T49](https://github.com/elastic/kibana/pull/276947#discussion_r3665159790), [T50](https://github.com/elastic/kibana/pull/276947#discussion_r3665161685), [T52](https://github.com/elastic/kibana/pull/276947#discussion_r3672726512)

---

### 2. SO model-version / backfill correctness (9 threads)

**Status: Addressed**

AI repeatedly flagged unpopulated fixtures and backfill writing `version` at the wrong nesting level (root vs `metadata.version`). Current `rule_model_versions.ts` backfills `metadata: { ...doc.attributes.metadata, version: 1 }`; fixture matches.

Human review landed on the same area — field placement and schema file versioning:

> **@cnasikas** ([T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383)):
>
> Ok, we discussed with @darnautov, and to also address Mike's concerns, we think that it would be clearer if we do `metadata.version` for the integer and have the top-level version for the SO OCC. Also, should this be non-optional, now that we backfill the SOs with data?

> **@cnasikas** ([T22](https://github.com/elastic/kibana/pull/276947#discussion_r3595687974)):
>
> I know it is not related to this PR, but it feels weird that we jump from v1 to v3 directly without a v2. So we either rename this as v2 (which is basically the second version of our rule SO) or create a v2 file. I lean towards renaming to `v2.ts` because model versions are not a 1-1 mapping with the rule SO schema.

**Related threads:** [T4](https://github.com/elastic/kibana/pull/276947#discussion_r3550676521), [T13](https://github.com/elastic/kibana/pull/276947#discussion_r3569240016), [T20](https://github.com/elastic/kibana/pull/276947#discussion_r3594114175), [T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383), [T22](https://github.com/elastic/kibana/pull/276947#discussion_r3595687974), [T37](https://github.com/elastic/kibana/pull/276947#discussion_r3636984115), [T38](https://github.com/elastic/kibana/pull/276947#discussion_r3636984133), [T39](https://github.com/elastic/kibana/pull/276947#discussion_r3637179604), [T40](https://github.com/elastic/kibana/pull/276947#discussion_r3637179622) (tsconfig comma)

---

### 3. Where does the monotonic counter live? (SO vs change-history index) (6 threads)

**Status: Addressed (design consensus — keep on SO as `metadata.version`)**  
**GH note:** [T6](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029) still shows unresolved even though Christos later agreed.

Raised by @cnasikas (initially against storing on SO), @maximpn (wanted the number exposed), later settled with @darnautov onto `metadata.version`.

> **@cnasikas** ([T6](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029)):
>
> I don't think we need this stored on the rule SO. The information is on the rule history index, which is the source of truth. There can be a race condition with reading the version from the rule history and writing it back, but the timestamp will resolve the ties. Also, the same race conditions can happen with the `changeHistorySequence` in the rule SO. Lastly, it is harder to sync two sources instead of one.

Antonio argued SO + OCC is the only way to guarantee unique sequence; Christos later agreed offline. Field evolved: `changeHistorySequence` → `revision` → **`metadata.version`**.

> **@cnasikas** ([T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383)):
>
> Ok, we discussed with @darnautov, and to also address Mike's concerns, we think that it would be clearer if we do `metadata.version` for the integer and have the top-level version for the SO OCC. Also, should this be non-optional, now that we backfill the SOs with data?

**Related threads:** [T6](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029), [T7](https://github.com/elastic/kibana/pull/276947#discussion_r3551261619), [T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383), [T35](https://github.com/elastic/kibana/pull/276947#discussion_r3623363300), [T37](https://github.com/elastic/kibana/pull/276947#discussion_r3636984115), [T39](https://github.com/elastic/kibana/pull/276947#discussion_r3637179604)

---

### 4. Misc naming / hygiene (open nits) (6 threads)

**Status: Mixed**

| Item | Status |
|------|--------|
| [T15](https://github.com/elastic/kibana/pull/276947#discussion_r3583335407) “Changes” plural naming | Addressed |
| [T27](https://github.com/elastic/kibana/pull/276947#discussion_r3622900822) avoid cast — **resolved on GH but cast still in code** | Not addressed |
| [T25](https://github.com/elastic/kibana/pull/276947#discussion_r3621923173) nested logger? — explained correctly, GH still open | Addressed (explanation) |
| [T60](https://github.com/elastic/kibana/pull/276947#discussion_r3681310489) rename `RULE_CHANGES_HISTORY_MAPPINGS` (confused with ES mappings) | Not addressed |
| [T61](https://github.com/elastic/kibana/pull/276947#discussion_r3681376772) what does `serverFields` mean? | Not addressed (unanswered) |
| [T58](https://github.com/elastic/kibana/pull/276947#discussion_r3681177724) docstring | Not addressed |

### 5. Enable/disable self-heal vs no-op (single vs bulk) (5 threads)

**Status: Partially addressed — single restored; bulk still skips ([T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059) open)**

Raised by AI (multiple times), @cnasikas, @sdesalas, @adcoelho.

> **AI** ([T5](https://github.com/elastic/kibana/pull/276947#discussion_r3550850123) / [T42](https://github.com/elastic/kibana/pull/276947#discussion_r3637550266)):
>
> This early-return drops a previously-deliberate self-heal path. The prior code documented that re-enabling an already-enabled rule was *intentionally not short-circuited* because it re-ensured the executor task…

> **@cnasikas** ([T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059)):
>
> What is the reason we changed the existing behavior? Was it intended to re-enable the rule to recover from a bad execution state? Same for disable.

> **@sdesalas** ([T34 reply](https://github.com/elastic/kibana/pull/276947#discussion_r3665490131)):
>
> My take here would be to update the bulk logic to mirror single enable (allowing the update). Currently in V1, bulk enabling an already enabled rule will still update the SO.

**Code today:** single `enableRule`/`disableRule` self-heal is back. `executeBulkEnable` still `continue`s on already-enabled rules — Steven’s ask not done.

**Related threads:** [T1](https://github.com/elastic/kibana/pull/276947#discussion_r3543316512) (author note, later reverted), [T5](https://github.com/elastic/kibana/pull/276947#discussion_r3550850123), [T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059), [T42](https://github.com/elastic/kibana/pull/276947#discussion_r3637550266), [T45](https://github.com/elastic/kibana/pull/276947#discussion_r3657535521)

---

### 6. Change-history `@timestamp` (especially deletes) (5 threads)

**Status: Addressed in code**  
**GH trap:** [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460) / [T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480) / [T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103) still open with stale AI text referencing `timestamp: rule.updatedAt ?? rule.createdAt` — that code is gone.

Raised by @maximpn, @sdesalas, AI (×3).

> **@maximpn** ([T19](https://github.com/elastic/kibana/pull/276947#discussion_r3585278875)):
>
> Capturing the change's timestamp here is technically wrong. Sorting by this timestamp may result in the wrong changes order (not reflecting real writes order). We should capture the real rule's SO write timestamp or right after that…

> **@sdesalas** ([T46](https://github.com/elastic/kibana/pull/276947#discussion_r3657808923)):
>
> When **deleting a rule** this should [be] the timestamp when the rule was **confirmed deleted**, not when it was created / updated. Since that could be many days ago.
>
> Since we're using `rule.version` to track the `object.sequence` … we can simply use `new Date()` (which happens inside the underlying `logRuleChanges()` call) … and not complicate ourselves further.
>
> …since we're using `rule.version` and OCC, *timestamp sorting becomes secondary*…

**Code today:** subscriber does not pass `timestamp` → `logRuleChanges` defaults to `new Date()`. Delete-path AI suggestions to stamp `updatedAt` on the snapshot are moot.

**Related threads:** [T19](https://github.com/elastic/kibana/pull/276947#discussion_r3585278875), [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460), [T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480), [T46](https://github.com/elastic/kibana/pull/276947#discussion_r3657808923), [T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103)

---

### 7. V1↔V2 history continuity (`module` / `dataset` / `objectType`) (5 threads)

**Status: Addressed via design decision (intentional break; parked on #797)**  
Constants unchanged: `alerting-v2` / `rules` / `alerting_rule`.

> **@sdesalas** ([T56](https://github.com/elastic/kibana/pull/276947#discussion_r3673550150)):
>
> Should be `alerting` to make sure we dont have a cut-off in histories once we move to `V2`…

> **@cnasikas** (reply): *We would like to avoid any mixing of v1 with v2… Losing history is acceptable IMO.*

> **@sdesalas** ([T57](https://github.com/elastic/kibana/pull/276947#discussion_r3673587328)):
>
> Same here. `alerting_rule` != `alert`. … As soon as we move the histories will get wiped out.

> **@sdesalas** ([T55](https://github.com/elastic/kibana/pull/276947#discussion_r3673539683)):
>
> Not really a constant. This should differentiate between `security`, `observability` and `stack` rules.
>
> If we pile them all together … customers will not be able to separate the rules they care about…

Christos: no solution split at storage level in V2 yet. Steven later accepted V1 history can stay on the old SO until deleted (migration model).

**Related threads:** [T11](https://github.com/elastic/kibana/pull/276947#discussion_r3551320646) (module rename to `alerting-v2` — done), [T54](https://github.com/elastic/kibana/pull/276947#discussion_r3673526512) (context), [T55](https://github.com/elastic/kibana/pull/276947#discussion_r3673539683), [T56](https://github.com/elastic/kibana/pull/276947#discussion_r3673550150), [T57](https://github.com/elastic/kibana/pull/276947#discussion_r3673587328)

---

### 8. Naming: `version` vs V1 `revision` / `version` (3 threads)

**Status: Not addressed (open question from Maxim today)**

V1 has two numbers with different semantics. V2 collapsed “any SO change” into a single `metadata.version`. Maxim wants an explicit decision.

> **@maximpn** ([T59](https://github.com/elastic/kibana/pull/276947#discussion_r3681296701)):
>
> I just wanna double check on the naming v2 vs v1. Alerting v1 has two rule bound numbers tracking rule content changes
>
> - `revision` - user edits monotonically increasing tracking integer number. It gets bumped upon rule content change by a user. Snooze/unsnooze and enable/disable don't affect this number.
> - `version` - external source content version monotonically increasing tracking integer number. It mostly makes sense in the scope of Security Prebuilt Detection Rules…
>
> On top of that rule changes history would benefit from having a monotonically increasing tracking integer number for any rule change including snooze/unsnooze and enable/disable.
>
> …I'd recommend to consider one of the following options…
>
> - Stick to Alerting v1 `revision` and `version` naming and behavior…
> - Make naming much more verbose. Something like `user_version` and `author_version`…

Also a docstring nit on the same field:

> **@maximpn** ([T58](https://github.com/elastic/kibana/pull/276947#discussion_r3681177724)):
>
> nit: `'Monotonically increasing integer number representing a rule configuration version…'`

**Related threads:** [T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383) (chose `metadata.version`), [T58](https://github.com/elastic/kibana/pull/276947#discussion_r3681177724), [T59](https://github.com/elastic/kibana/pull/276947#discussion_r3681296701)

---

### 9. Decouple RulesClient from change-history; emit domain model (3 threads)

**Status: Addressed**  
**GH note:** [T8](https://github.com/elastic/kibana/pull/276947#discussion_r3551285868) still unresolved.

Raised by @cnasikas, @maximpn.

> **@cnasikas** ([T8](https://github.com/elastic/kibana/pull/276947#discussion_r3551285868)):
>
> We shouldn't couple any change history logic into the rules client. The rules client will emit a rule (same as it is returned on the API…) and the `RuleChangeHistorySubscriber` will transform the schema as it likes.

> **@maximpn** ([T14](https://github.com/elastic/kibana/pull/276947#discussion_r3583319395)):
>
> Ideally we shouldn't capture Rule Saved Object's snapshot and lean towards domain models in changes history.
>
> Saved Object have migrations support but changes history is append only. Consequently lower in the abstraction logic data structure snapshot is captured more effort will be required to provide backwards compatibility.

Also [T12](https://github.com/elastic/kibana/pull/276947#discussion_r3551338280) (publisher should be agnostic). Current code: RulesClient has zero change-history imports; subscriber logs `RuleResponse`.

**Related threads:** [T8](https://github.com/elastic/kibana/pull/276947#discussion_r3551285868), [T12](https://github.com/elastic/kibana/pull/276947#discussion_r3551338280), [T14](https://github.com/elastic/kibana/pull/276947#discussion_r3583319395)

---

### 10. Seed / override create `version` on delete→recreate (2 threads)

**Status: Not addressed (deferred to [rna-program#797](https://github.com/elastic/rna-program/issues/797))**

Raised by @maximpn, AI reviewer, @sdesalas (with detection-rules upgrade path context).

> **@maximpn** ([T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809)):
>
> From the consumer's side it'd be great when the starting sequence number could be passed in rule create params. It covers the case when a rule has to be re-created. And ofc the number should be available for consumers as a readonly field.

> **AI** ([T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261)):
>
> `createRule` always seeds the version counter from `getNextVersion()` → `1`, independent of any history for this `id`. … a delete-then-recreate of the same id resets `object.sequence` to `1` while the earlier change-history entries for that `object.id` … remain … producing a non-monotonic, misordered timeline…

> **@sdesalas** ([T41 reply](https://github.com/elastic/kibana/pull/276947#discussion_r3647075822)):
>
> My suggestion: Let the caller pass its own `version` (-> `object.sequence`) same as we did with `revision`.
>
> Want to recreate with an `id`? You're in charge of versioning if you want to do something fancy… Kick that can up the road to the consumer (so long as this information is also available to them on read).

Later you noted V2 may not need delete→recreate at all (no rule types). Still: `CreateRuleParams` has no seed field; create always starts at `1`.

**Related threads:** [T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809), [T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261)

---

### 11. `RuleChangesHistoryScope` type / “scope” naming vs V1 (2 threads)

**Status: Not addressed (no reply, type still present)**

> **@sdesalas** ([T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805)):
>
> These are all hard-coded values so I'm a bit confused why `RuleChangesHistoryScope` type exists. Just creates more cognitive load that was not necessary.
>
> Besides the meaning of `scope` in V1 is somewhat different. The V1 change history service is "scoped" to a single `KibanaRequest` via `asScoped()` … I would consider leaving this option open.

Earlier Maxim had asked about unused scoped methods ([T17](https://github.com/elastic/kibana/pull/276947#discussion_r3583399312)) — those were removed, but the `Scope` type remained as a hardcoded struct of module/dataset/objectType.

**Related threads:** [T17](https://github.com/elastic/kibana/pull/276947#discussion_r3583399312), [T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805)

---

### 12. Consumer overrides: action / metadata / refresh / await (1 thread)

**Status: Not addressed (deferred to #797 by agreement)**

Raised by @sdesalas; @cnasikas prefers dedicated RulesClient methods over passthrough options.

> **@sdesalas** ([T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272)):
>
> It should be possible to override the change history `action` when calling any of the rules client methods such as `createRule()` or `updateRule()`.
>
> To give an example, even though the default action on V1 `createRule()` is `rule_create`, the Detection Rules Client overrides it for certain actions such as `rule_install` or `rule_duplicate`…
>
> We also need callers to provide change history `metadata` such as the `metadata.bulkCount` or the `metadata.originalRuleSoId`… And to be able to override `refresh` (ie `refresh: 'wait_for'`) - and await the call (which is not being done here due to fire-and-forget bus)…

Christos: start simple; prefer `duplicateRule` / `installRule` methods later. Steven: still prefers passing `action` for security flexibility. Ticketed on #797.

**Related threads:** [T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272)

---

---

## Addressed (verified)

| Thread | Who | Ask | Evidence |
|--------|-----|-----|----------|
| [T3](https://github.com/elastic/kibana/pull/276947#discussion_r3543390267) | AI | Unit-test change-history service | `rule_changes_history_service.test.ts` |
| [T4](https://github.com/elastic/kibana/pull/276947#discussion_r3550676521) / [T13](https://github.com/elastic/kibana/pull/276947#discussion_r3569240016) / [T20](https://github.com/elastic/kibana/pull/276947#discussion_r3594114175) / [T38](https://github.com/elastic/kibana/pull/276947#discussion_r3636984133) | AI | Populate SO migration fixture | Real docs + `metadata.version: 1` in `10.3.0.json` |
| [T5](https://github.com/elastic/kibana/pull/276947#discussion_r3550850123) / [T42](https://github.com/elastic/kibana/pull/276947#discussion_r3637550266) | AI | Restore enable/disable self-heal (single) | Not short-circuited; schedules/removes tasks |
| [T6](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029) | cnasikas | (initial) don’t store counter on SO | Consensus reversed → keep on SO; **GH still unresolved** |
| [T7](https://github.com/elastic/kibana/pull/276947#discussion_r3551261619) | cnasikas | Fetch version from history service | Deferred by author of comment; SO is SoT |
| [T8](https://github.com/elastic/kibana/pull/276947#discussion_r3551285868) | cnasikas | Decouple RulesClient | No change-history imports; **GH still unresolved** |
| [T9](https://github.com/elastic/kibana/pull/276947#discussion_r3551292106) | cnasikas | Use `userProfile.getCurrent` shape | Subscriber does |
| [T10](https://github.com/elastic/kibana/pull/276947#discussion_r3551303135) / [T24](https://github.com/elastic/kibana/pull/276947#discussion_r3621660096) | cnasikas | DI + `createChangeHistoryClient` | Both exist |
| [T11](https://github.com/elastic/kibana/pull/276947#discussion_r3551320646) | cnasikas | Module `alerting-v2` | Constants match |
| [T12](https://github.com/elastic/kibana/pull/276947#discussion_r3551338280) / [T14](https://github.com/elastic/kibana/pull/276947#discussion_r3583319395) | cnasikas / maximpn | Domain model snapshot | `RuleResponse` logged |
| [T15](https://github.com/elastic/kibana/pull/276947#discussion_r3583335407) | maximpn | “Changes” naming | `RuleChangesHistory*` |
| [T16](https://github.com/elastic/kibana/pull/276947#discussion_r3583383832) / [T17](https://github.com/elastic/kibana/pull/276947#discussion_r3583399312) | maximpn | Drop `isEnabled` / unused scope method | Gone |
| [T19](https://github.com/elastic/kibana/pull/276947#discussion_r3585278875) / [T46](https://github.com/elastic/kibana/pull/276947#discussion_r3657808923) | maximpn / sdesalas | Timestamp defaults | No timestamp passed → `new Date()` |
| [T21](https://github.com/elastic/kibana/pull/276947#discussion_r3595652383) / [T22](https://github.com/elastic/kibana/pull/276947#discussion_r3595687974) | cnasikas | `metadata.version` + schema v2 file | Done |
| [T23](https://github.com/elastic/kibana/pull/276947#discussion_r3596056367) | AI | Empty update gaps sequence vs event | Always emits `ruleUpdated` |
| [T25](https://github.com/elastic/kibana/pull/276947#discussion_r3621923173) | cnasikas | Nested logger? | Explanation correct; **GH still unresolved** |
| [T26](https://github.com/elastic/kibana/pull/276947#discussion_r3622528241) | cnasikas | ResourceManager init `optional: true` | Done |
| [T29](https://github.com/elastic/kibana/pull/276947#discussion_r3623170980) / [T30](https://github.com/elastic/kibana/pull/276947#discussion_r3623218440) / [T33](https://github.com/elastic/kibana/pull/276947#discussion_r3623282161) / [T35](https://github.com/elastic/kibana/pull/276947#discussion_r3623363300) / [T36](https://github.com/elastic/kibana/pull/276947#discussion_r3623480127) | cnasikas | Small cleanups | Done |
| [T37](https://github.com/elastic/kibana/pull/276947#discussion_r3636984115) / [T39](https://github.com/elastic/kibana/pull/276947#discussion_r3637179604) | AI | Backfill nested path | Fixed |
| [T40](https://github.com/elastic/kibana/pull/276947#discussion_r3637179622) | AI | tsconfig comma | Fixed |
| [T45](https://github.com/elastic/kibana/pull/276947#discussion_r3657535521) | sdesalas | Empty PATCH check | Accepted after explanation |
| [T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799)–[T50](https://github.com/elastic/kibana/pull/276947#discussion_r3665161685) | sdesalas | Scout history assertions | In `rule_history.spec.ts` (see unsure) |
| [T55](https://github.com/elastic/kibana/pull/276947#discussion_r3673539683)–[T57](https://github.com/elastic/kibana/pull/276947#discussion_r3673587328) | sdesalas | Continuity constants | Closed as intentional / #797 |

---

## Not addressed (verified)

| Thread | Who | Ask | Why still open |
|--------|-----|-----|----------------|
| [T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809) / [T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261) | maximpn / AI (+ sdesalas) | Seed create `version` | Always starts at `1`; no param; deferred #797 |
| [T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059) | cnasikas (+ sdesalas) | Bulk enable/disable mirror single self-heal | Bulk still skips already-enabled/disabled |
| [T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) | sdesalas | Override action / metadata / refresh / await | Deferred #797 by agreement — **not in diff** |
| [T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805) | sdesalas | Drop / rethink `RuleChangesHistoryScope` | No reply; type still hardcoded |
| [T58](https://github.com/elastic/kibana/pull/276947#discussion_r3681177724) | maximpn | Docstring nit | Schema still says “Strictly increasing…” |
| [T59](https://github.com/elastic/kibana/pull/276947#discussion_r3681296701) | maximpn | `version` vs V1 naming | Needs a written decision |
| [T60](https://github.com/elastic/kibana/pull/276947#discussion_r3681310489) | maximpn | Rename mappings constant | Still `RULE_CHANGES_HISTORY_MAPPINGS` |
| [T61](https://github.com/elastic/kibana/pull/276947#discussion_r3681376772) | maximpn | What is `serverFields`? | Unanswered |
| [T27](https://github.com/elastic/kibana/pull/276947#discussion_r3622900822) | cnasikas | Avoid cast | **Resolved on GH; cast still present** |
| [T52](https://github.com/elastic/kibana/pull/276947#discussion_r3672726512) | AI | Share Scout system-indices helper | Local third copy remains (nit) |

---

## Unsure / traps

| Thread | Why uncertain |
|--------|----------------|
| [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460) / [T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480) / [T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103) | **Stale AI.** Claim delete uses `rule.updatedAt` for `@timestamp`. Code no longer passes timestamp. Safe to resolve; don’t “fix” by stamping delete snapshots. |
| [T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799)–[T50](https://github.com/elastic/kibana/pull/276947#discussion_r3665161685) | Coverage exists in `rule_history.spec.ts`, **not** inline in create/update specs as requested. Intent met; claim location wrong. |
| [T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809) / [T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261) / [T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) / [T55](https://github.com/elastic/kibana/pull/276947#discussion_r3673539683)–[T57](https://github.com/elastic/kibana/pull/276947#discussion_r3673587328) | Conversation closed or ticketed ≠ implemented. Treat as accepted deferral, not “done.” |
| [T1](https://github.com/elastic/kibana/pull/276947#discussion_r3543316512) / [T2](https://github.com/elastic/kibana/pull/276947#discussion_r3543334606) | Author self-notes. [T1](https://github.com/elastic/kibana/pull/276947#discussion_r3543316512)’s short-circuit was later reverted. |
| [T28](https://github.com/elastic/kibana/pull/276947#discussion_r3622927788) / [T32](https://github.com/elastic/kibana/pull/276947#discussion_r3623245204) / [T54](https://github.com/elastic/kibana/pull/276947#discussion_r3673526512) | Informational / answered; no code ask. |

---

## Priority punch list (human attention)

1. **[T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059)** — bulk enable/disable still skip; your ask to match single self-heal is open.
2. **[T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805)** — `RuleChangesHistoryScope` comment: no reply, no code change.
3. **[T58](https://github.com/elastic/kibana/pull/276947#discussion_r3681177724)–[T61](https://github.com/elastic/kibana/pull/276947#discussion_r3681376772)** — Maxim’s comments from today (especially [T59](https://github.com/elastic/kibana/pull/276947#discussion_r3681296701) naming).
4. **[T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809) / [T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261) + [T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272)** — deferred to #797; fine if intentional, don’t mark done.
5. **[T27](https://github.com/elastic/kibana/pull/276947#discussion_r3622900822)** — marked resolved, cast still present (nit).
6. **Do not chase [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460) / [T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480) / [T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103)** — outdated; timestamp already defaults to `new Date()`.

---

## GH resolve-flag mismatches (skeptical checklist)

| Thread | GH flag | Reality |
|--------|---------|---------|
| [T6](https://github.com/elastic/kibana/pull/276947#discussion_r3550935029), [T8](https://github.com/elastic/kibana/pull/276947#discussion_r3551285868), [T25](https://github.com/elastic/kibana/pull/276947#discussion_r3621923173) | Unresolved | Addressed in code / consensus |
| [T27](https://github.com/elastic/kibana/pull/276947#discussion_r3622900822) | Resolved | Cast still in code |
| [T43](https://github.com/elastic/kibana/pull/276947#discussion_r3639230460), [T44](https://github.com/elastic/kibana/pull/276947#discussion_r3639230480), [T51](https://github.com/elastic/kibana/pull/276947#discussion_r3672423103) | Unresolved | Stale; timestamp path already fixed |
| [T34](https://github.com/elastic/kibana/pull/276947#discussion_r3623322059), [T53](https://github.com/elastic/kibana/pull/276947#discussion_r3673436805) | Unresolved | Correctly open |
| [T18](https://github.com/elastic/kibana/pull/276947#discussion_r3585246809), [T41](https://github.com/elastic/kibana/pull/276947#discussion_r3637550261), [T47](https://github.com/elastic/kibana/pull/276947#discussion_r3659296272) | Unresolved / deferred | Correctly not implemented |
| [T48](https://github.com/elastic/kibana/pull/276947#discussion_r3665151799)–[T50](https://github.com/elastic/kibana/pull/276947#discussion_r3665161685) | Resolved | Coverage exists, wrong file location vs claim |
