# bulkUpdateRules — tradeoffs

[PR #284946](https://github.com/elastic/kibana/pull/284946) · [#264894](https://github.com/elastic/kibana/issues/264894) · [#264892](https://github.com/elastic/kibana/issues/264892)

Kibana already has two ways to change many alerting rules at once:

- **Create-many** (`bulkCreateRules`) — you hand in a list of brand-new rules. It checks them, then saves them a hundred at a time.
- **Edit-many** (`bulkEditRules` / `bulkEditRulesOcc`) — you point at existing rules and apply the *same* change to all of them (for example “add this tag”). It loads them, applies that one change, then saves the whole set in a single write.

The new method, `bulkUpdateRules`, is for a third job: “here are 200 existing rules, and each one has its *own* new definition.” Typical callers: import with overwrite, and upgrading prebuilt detection rules. Every rule in the list is already in the database, but each one is being rewritten to a different body — not the same patch applied to everyone.

Christos ([#264894](https://github.com/elastic/kibana/issues/264894#issuecomment-4333902656)):

> Encrypted SO GETs: Per-rule via pMap at concurrency 50 to retrieve existing API keys (irreducible floor — each rule's API key is stored in an encrypted saved object that must be individually decrypted).
>
> Maybe we could mimic what the current `bulkEditRulesOcc` does and use the `encryptedSavedObjectsClient.createPointInTimeFinderDecryptedAsInternalUser`method and process the results in batches. We can construct a filter with the IDs by using `convertRuleIdsToKueryNode`. This should reduce the number of calls to ES.

Banderror, on sharing with bulk edit ([#264894](https://github.com/elastic/kibana/issues/264894)):

> Common infrastructure (OCC retry, bulk SO write, API key management, task schedule updates) should be shared with `bulkEdit` to avoid maintaining parallel bulk write paths — exact reuse strategy to be determined during implementation.

Banderror, on API keys when a bulk write throws ([#264892](https://github.com/elastic/kibana/issues/264892#issuecomment-4408025793)):

> When the whole `bulkCreateRulesSo` throws and we don't receive partial results, currently all api keys are being invalidated.
>
> However, `bulkCreateRulesSo` could throw in the middle of bulk indexing documents to ES, e.g. due to a network error or cluster failure. Two issues with this:
>
> 1. If it is an intermittent failure, and some rules were successfully written by the `bulkCreateRulesSo` call, invalidating their api keys might not be needed
> 2. If it's a persistent failure (network or cluster is down), the `bulkMarkApiKeysForInvalidation` call will fail too, which I'm not sure is properly handled by callers of `bulkEditRulesOcc`.
>
> I think @sdesalas might already be dealing with error handling as part of https://github.com/elastic/kibana/issues/264893, where we're considering an optimistic approach to bulk rule creation.

---

## Tradeoff: 1. Call `bulkEditRulesOcc`, or clone `bulkCreateRules` and reuse edit’s helpers?

Banderror on [#264894](https://github.com/elastic/kibana/issues/264894) asked us not to build a second way to save lots of rules. He wanted this method to share edit-many’s retry, bulk save, API-key handling, and task-schedule updates.

**Option A — Call `bulkEditRulesOcc` / `saveBulkUpdatedRules`.**

- Pros: That code already loads existing rules, creates API keys, overwrites the saved documents, and retries when two writes collide. It is what the ticket asked for, so reviewers see one write path.
- Cons: Edit-many is built for “apply this *one* change to every rule I found.” We are handing in a *different* new definition for each rule. We would still have to build each updated document ourselves, then push the pile into their save function. If that one save fails halfway, it can throw away every new API key from the whole import ([#264892](https://github.com/elastic/kibana/issues/264892)).

**Option B — Clone `bulkCreateRules` (preValidate, then write `batchSize` at a time), but reuse edit’s helpers:** `createPointInTimeFinderDecryptedAsInternalUser`, `bulkCreateRulesSo` overwrite, `createNewAPIKeySet`, `bulkMarkApiKeysForInvalidation`, `taskManager.bulkUpdateSchedules`.

- Pros: Create-many is already the “here is a list, each item is different” method. Writing 100 at a time means a failed save only risks that batch, not 2000 rules. We still use the same Elasticsearch and API-key helpers, so we are not inventing a third way to persist a rule.
- Cons: The *sequence* of steps is not the same as edit-many. The ticket asked to avoid that. Someone reading the ticket may think we ignored it.

**We picked B.** Use the same building blocks as edit-many. Do not run our “each rule has its own new body” job through a helper that assumes one shared patch. We also want to *avoid retesting* `bulk_edit_rules.ts`, and to *maximize performance and minimise memory use*. The ticket is a straightjacket, so we take it as an informed recommendation. Not gospel.

---

## Tradeoff: 2. Apply `enabled` inside `bulkUpdateRules`, or leave it to `bulkEnableRules` / `bulkDisableRules`?

`UpdateRuleData` has no `enabled` field. `updateRule` never flips it. Detection-rule import/patch/update call `toggleRuleEnabledOnUpdate` afterwards, which is `rulesClient.enableRule` / `disableRule`.

From the contract session ([stub + wire](f9c81b61-aa9a-4fc7-b304-e64b15f6d41a)): *Do not include enabling/disabling rules in logic. We'll bulk enable the ones we need to after the update batch has completed.*

**Option A — Honour a requested `enabled` change inside `bulkUpdateRules` (schedule/unschedule tasks, mint keys, authz for enable).**

- Pros: One call does update + on/off, like a naive reading of “bulk update.”
- Cons: Enable/disable is a different product path (`bulkEnableRules` / `bulkDisableRules`): Task Manager create/delete, circuit breaker, different authz. Folding it in retests that path and fights AAD/key policy (tradeoff 8). `UpdateRuleData` would have to grow an `enabled` field that `updateRule` still ignores.

**Option B — Keep `enabled: original.enabled` on the overwrite. Callers that need a flip use `bulkEnableRules` / `bulkDisableRules` after.**

- Pros: Same as `updateRule`. No TM create/delete in this method. We still rewrite the paused task’s interval when it changed (tradeoff 11), so a later enable wakes the right cadence. Import overwrite can `toggleRuleEnabledOnUpdate` (or a bulk equivalent) after the batch, which is what it already does per rule today.
- Cons: A rule imported as enabled stays in whatever state it had until that follow-up runs. That follow-up is not wired in this POC.

**We picked B.** `prepareUpdate` stamps `enabled: originalRule.enabled`. Enable/disable-after-update stays a follow-up.

---

## Tradeoff: 3. OCC 409: fail the rule, `retryIfBulkEditConflicts`, or reload-and-PUT?

We stamp the loaded SO `version` on `bulkCreateRulesSo` overwrite. If something else wrote first, Elasticsearch returns **409**.

`updateRule` already retries a couple of times ([PR #77838](https://github.com/elastic/kibana/pull/77838), `RetryForConflictsAttempts`). `bulkEditRulesOcc` uses `retryIfBulkEditConflicts` (reload, reapply the same patch, rewrite everything). We first said: stamp `version`, 409 = per-item error, no retry — because retrying means another `createNewAPIKeySet`, and a real competing save would 409 again.

Note that **most 409's come from rule background execution updating the rule.** While we are saving an import or upgrade, the runner is writing last-run status onto the same document. That is not two people editing the same rule. Without retry, import/upgrade of *running* rules would fail at random.

**Option A — Don’t retry. 409 is a per-item error.**

- Pros: No extra key creation. Simple, if collisions are rare.
- Cons: Rules that are currently running fail the import/upgrade for no good reason. That is not what `updateRule` does today.

**Option B — `retryIfBulkEditConflicts` (reapply the same patch, rewrite everything).**

- Pros: Step 9 of [#264894](https://github.com/elastic/kibana/issues/264894) asked for this.
- Cons: We are not applying one shared patch. Replaying the same bulk objects keeps the old `version`, so you 409 forever. It would also mint new keys for the whole set again.

**Option C — Reload-and-PUT for 409 rows only, like `updateRule`: invalidate the new key, wait 100ms, `loadRulesByIds` those ids, `prepareUpdate` again (fresh `version`, same `item.data`, new key), overwrite. `RetryForConflictsAttempts` (2 retries / 3 attempts). Then per-item error.**

- Pros: Survives the runner writing last-run status. Only the collided rules pay for another key. We don’t use `retryIfBulkEditConflicts`.
- Cons: Extra load and key creation for those rules. If someone really did save a competing edit in that window, last writer wins — same as `updateRule`.

**We picked C.** Stamp `version` on overwrite. On 409, invalidate the new key (the rule still has the old one), reload, rebuild, overwrite.

---

## Tradeoff: 4. Must we patch `saveBulkUpdatedRules` ([#264892](https://github.com/elastic/kibana/issues/264892)) before this ships?

[#264894](https://github.com/elastic/kibana/issues/264894) says it depends on [#264892](https://github.com/elastic/kibana/issues/264892). The problem: if `bulkCreateRulesSo` throws, we must not leave (or wipe) API keys in a way that breaks rules. The ticket as written says: if the save throws with no row-by-row result, accept `bulkMarkApiKeysForInvalidation` on all the new keys; if some rows succeeded and some failed, invalidate **new** keys for the failures and **old** keys for the successes.

Banderror later pushed back on “just accept the full throw” ([comment](https://github.com/elastic/kibana/issues/264892#issuecomment-4408025793)): Elasticsearch may have saved some rules before the throw, and if the cluster is down `bulkMarkApiKeysForInvalidation` may fail too.

**Option A — Fix `saveBulkUpdatedRules` first, then reuse it.**

- Pros: Honours the “depends on” line. One shared fix.
- Cons: We are not using that function (see tradeoff 1). This work would wait on a change Banderror is not even sure is the right fix.

**Option B — Copy that invalidate-new-on-fail / invalidate-old-on-success policy inside our `batchSize` writes. Leave `saveBulkUpdatedRules` alone.**

- Pros: The new method can ship. A throw only risks one batch of keys, not the whole import. When Elasticsearch *does* return per-row results, we already wipe new keys on failure and old keys on success, which is what the ticket asked for.
- Cons: If a save throws with no row-by-row result, we still wipe every new key in that batch — including for rules Elasticsearch may already have written. Batches shrink that from the whole import to 100 rules; they do not remove it. A later bulk operation can regenerate those keys, but in the meantime _the rule keeps the dead key_. We did not close [#264892](https://github.com/elastic/kibana/issues/264892).

**We picked B.** Copy the behaviour. Don’t wait on a patch to a helper we aren’t calling. The conditions for this bug to arise are rare and the approach mirrors existing behavior. A thorough search found no matches to existing SDHs in elastic/sdh-security-team regarding dead or invalid keys. We also mitigated the risk by reducing batch sizes but did not remove it altogether.

---

## Tradeoff: 5. Load with `getDecryptedRuleSo` per id, or with `createPointInTimeFinderDecryptedAsInternalUser`?

Each rule stores an Elasticsearch API key. It is encrypted. To retire the old key after we replace it, we have to read it first.

The ticket said: fetch each rule one at a time, 50 in parallel (`pMap` + `getDecryptedRuleSo`), because each encrypted document has to be decrypted on its own ([#264894](https://github.com/elastic/kibana/issues/264894)).

Christos disagreed: use the same paged read edit-many already uses, filtered to the ids we care about ([comment](https://github.com/elastic/kibana/issues/264894#issuecomment-4333902656)).

**Option A — `getDecryptedRuleSo` per id via `pMap` at concurrency 50** (what the ticket wrote; same as `updateRule`).

- Pros: If rule 47 is missing, we know it immediately. If decrypt fails, we can still load the document without the key (`getRuleSo`, what `updateRule` does today).
- Cons: A 2000-rule import is 2000 extra round trips. Christos’s point: we do not actually have to do it that way.

**Option B — One paged read of those ids, using `createPointInTimeFinderDecryptedAsInternalUser` with a `convertRuleIdsToKueryNode` filter** (what Christos suggested, and what edit-many already uses).

- Pros: Far fewer calls. Same load path as edit-many. If an id is not in the results, we record an error for that rule and continue.
- Cons: If decrypt fails for one document, that rule just looks missing. We do not fall back to “load it without the key.”

**We picked B.** We use that finder. We still do not call the rest of edit-many’s helper (see tradeoff 1).

---

## Tradeoff: 6. One PIT over the whole request, or `loadRulesByIds` per write batch?

`bulkEditRulesOcc` pages the finder (`perPage: 100`), holds every matching rule, then one `saveBulkUpdatedRules`. `bulkCreateRules` has nothing to load — the rules are new — and writes with `bulkCreateRulesSo` 100 at a time.

**Option A — One PIT for every id, then `createNewAPIKeySet`, then one save** (what `bulkEditRulesOcc` does).

- Pros: One read. We can refuse the whole request (`bulkEnsureAuthorized`, `validateScheduleLimit`) before anything is saved.
- Cons: Creating API keys is slow. By the time we save, the copy we loaded is old. A rule that ran in the meantime will collide with our save (OCC 409).

**Option B — Per write batch: `loadRulesByIds` → `createNewAPIKeySet` → `bulkCreateRulesSo`, then the next 100** (`bulkCreateRules` write loop, plus a load of those 100 first because they already exist).

- Pros: What we save is what we just read. Less likely to collide with a rule that is running right now. We don’t hold 2000 decrypted rules in memory.
- Cons: If the second batch fails a hard check (permissions, schedule limit), the first 100 are already saved.

**We picked B.** Load each save-batch as we go. Mirroring `bulkCreateRules`.

---

## Tradeoff: 7. One `bulkCreateRulesSo` for the whole request, or one per `batchSize`?

Creating API keys (`createNewAPIKeySet`, concurrency `API_KEY_GENERATE_CONCURRENCY` = 50) is about half the time. For 2000 enabled rules that is 40 rounds either way. Saving in batches does **not** create fewer keys and does **not** create them faster.

`bulkEditRulesOcc` creates keys as it reads, then one `saveBulkUpdatedRules` (`bulkCreateRulesSo` overwrite of the whole pile). `bulkCreateRules` calls `bulkCreateRulesSo` 100 at a time.

**Option A — One `saveBulkUpdatedRules` / `bulkCreateRulesSo` of the whole request** (what edit-many does).

- Pros: We never stop creating keys to wait for a save. If saving is the other half of the time, this finishes a bit sooner.
- Cons: If that one `bulkCreateRulesSo` throws, the catch can `bulkMarkApiKeysForInvalidation` every new key, including for rules Elasticsearch may already have stored ([#264892](https://github.com/elastic/kibana/issues/264892), [Banderror’s comment](https://github.com/elastic/kibana/issues/264892#issuecomment-4408025793)). One failure can hit the entire import.

**Option B — `bulkCreateRulesSo` per `batchSize` (default 100)** (what `bulkCreateRules` does).

- Pros: A failed save only risks those 100 new keys, not 2000. Smaller writes.
- Cons: After each save we pause key creation. More trips to Elasticsearch.

**We picked B.** Same number of keys. Batches are so one failure doesn’t take down the whole import.

---

## Tradeoff: 8. When do we call `createNewAPIKeySet`?

The ticket said: only mint a new key when `enabled` or `consumer` changes; skip it entirely for disabled rules ([#264894](https://github.com/elastic/kibana/issues/264894)).

The key is encrypted, and AAD (`RuleAttributesIncludedInAAD`) binds that blob to name, tags, params, actions, schedule, enabled, consumer, and more. Change those fields and leave the old blob in place, and Kibana will not be able to decrypt it later.

**Option A — Follow the ticket: `createNewAPIKeySet` only when `enabled` / `consumer` changes.**

- Pros: Fewer slow key-creation calls. Disabled rules stay cheap.
- Cons: Wrong. Import overwrite and prebuilt upgrade change name, query, actions, and schedule all the time. Leaving the old blob would make those rules unreadable.

**Option B — Same as `updateRule`: `createNewAPIKeySet({ shouldUpdateApiKey: original.enabled })`. Disabled rules skip it (enable later will mint).**

- Pros: Matches today’s single-rule update and edit-many. Encryption stays valid. Disabled rules skip the slow work.
- Cons: Every update of a running rule pays the slow half. 2000 enabled overwrites = 2000 new keys, same as edit-many. There is no shortcut.

**We picked B.** The ticket was wrong on this. Saving in batches does not change how many keys we create (see tradeoff 7).

---

## Tradeoff: 9. `bulkEnsureAuthorized` (throw the call), or `ensureAuthorized` per rule?

`bulkCreateRules` calls `bulkEnsureAuthorized(Create)` on the type/consumer pairs in the list. If any pair is forbidden, the whole request throws and nothing is saved. `updateRule` calls `ensureAuthorized(Update)` for that one rule — only that rule fails.

**Option A — `bulkEnsureAuthorized(Update)` on the loaded type/consumer pairs; any miss throws this `bulkUpdateRules` call.**

- Pros: Same as create-many. Simple. For detection-rule import/upgrade, mixed permissions are rare (same user, same kinds of rules).
- Cons: One forbidden pair fails every rule in *this* request. That is not the whole HTTP import: the import API already splits the file (50 rules). Earlier splits stay saved.

**Option B — `ensureAuthorized` per rule; unauthorized rules become per-item errors, the rest save.**

- Pros: Allowed rules still save.
- Cons: Half-saved imports that look like a bug. More special cases.

**We picked A.** Type/consumer pairs that are not allowed are rare. Throw the call, before writes.

---

## Tradeoff: 10. `validateScheduleLimit`: throw the call, or skip the rules that don’t fit?

Kibana limits how many rule runs per minute the cluster will take (`validateScheduleLimit`). `updateRule` only checks this when that rule is already on **and** you changed how often it runs. `bulkCreateRules` throws the whole request if the new load doesn’t fit.

**Option A — Throw this `bulkUpdateRules` call** (nothing in this batch is saved yet).

- Pros: Same as create-many. You don’t save half the batch then discover the cluster can’t take the new run rate.
- Cons: One rule with a too-aggressive interval fails the whole batch, including rules whose interval didn’t change.

**Option B — Per-item error on the rules that don’t fit, save the others.**

- Pros: The rest of the batch still saves.
- Cons: The check is about the *cluster*, not one rule. Saving some and skipping others can still leave you over the limit.

**We picked A.** Run `validateScheduleLimit` on enabled rules whose interval changed. Overflow throws the call.

---

## Tradeoff: 11. If `taskManager.bulkUpdateSchedules` fails, is the rule a failure?

After `bulkCreateRulesSo`, we call `taskManager.bulkUpdateSchedules` when the rule has a `scheduledTaskId` **and** the interval changed — on or off. Same as `updateRule` and bulk edit (`bulkUpdateTaskSchedules`). Edit-many sends *one* interval for every rule. We group by the **new** interval, because each payload can differ.

`updateRule` already saves the SO first, then talks to Task Manager, and if that fails it **logs and continues**. The rule is updated; it may keep running on the old interval until something else fixes it.

**Option A — Log and swallow. The rule stays in `successfulIds`.**

- Pros: Same as `updateRule`. We don’t fail an import because Task Manager hiccupped after a good save.
- Cons: A rule can be saved with a new interval and still *run* on the old one until the next fix.

**Option B — Treat that rule as a per-item error.**

- Pros: The caller sees that Task Manager didn’t follow.
- Cons: The SO *was* saved. The error is misleading. Callers may retry and `createNewAPIKeySet` again.

**We picked A.**

---

## Tradeoff: 12. Who chunks — `bulkUpdateRules`, `DetectionRulesClient`, or the import/upgrade callers?

The import HTTP route already splits the file into groups of 50. Inside that, `import_rules.ts` overwrite still hands the whole `toUpdate` list to one `rulesClient.bulkUpdateRules` call. Prebuilt-rule upgrade already chunks at 100. We said the *callers* should chunk, so upgrade can load only the ids in the chunk and not hold thousands in memory. We did not wire that in this pass.

**Option A — Chunk inside `bulkUpdateRules` or `DetectionRulesClient.bulkUpdateRules`.**

- Pros: Every caller gets batching. A `bulkEnsureAuthorized` / `validateScheduleLimit` throw only affects 100 rules, even if someone passes 2000 ids.
- Cons: Upgrade would still have loaded all those rules *before* calling us. It doesn’t fix the memory problem.

**Option B — Callers chunk. This method still enforces `MAX_BULK_UPDATE_BATCH_SIZE` (500) / default 100 as a backstop.**

- Pros: Upgrade can load 100, update 100, load the next 100. This method stays “save this list.”
- Cons: `import_rules.ts` overwrite does not chunk yet. If `validateScheduleLimit` throws on the second inner batch, the first batch is already saved.

**We picked B, and did not change the callers in this pass.** `DEFAULT_BULK_UPDATE_BATCH_SIZE` / `MAX_BULK_UPDATE_BATCH_SIZE` stays as a safety net.
