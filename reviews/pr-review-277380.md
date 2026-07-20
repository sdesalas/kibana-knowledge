# PR Review: #277380 — [Security Solution] Add APM instrumentation to rule changes history read, write, and restore paths

**PR:** [elastic/kibana#277380](https://github.com/elastic/kibana/pull/277380) by @maximpn

**Scale:** Substantive by file count (17 files), but conceptually small-to-medium — it's pure APM instrumentation plus test coverage, no behavior change to the actual data paths. Standard review (no team-aware pass requested).

---

### Context / Motivation

Resolves [#277046](https://github.com/elastic/kibana/issues/277046) — the "Instrumentation / APM" checklist item for the Rule Changes History MVP. The problem the issue describes:

> Outer method-level APM spans already exist, generically, via `withSecuritySpan` on all `DetectionRulesClient` methods [...] These are not history-specific — every `DetectionRulesClient` method gets one. They don't break down where time is actually spent.

So the goal is finer-grained spans on the actual hot spots (hashing/serialization loop, ES bulk write, ES search, restore read vs. restore write), labeled by solution + action so they can be filtered in APM and fed into the load-testing work in security-team#18180. The write path matters cross-solution because `logRuleChanges` runs on the shared alerting rule-mutation path (Security, Observability, Stack), so a regression here isn't Security-only.

### Validating the issue — does this PR address it?

The concern is valid and the PR addresses it correctly. Acceptance criteria vs. what shipped:

- **Distinct write spans (hash+snapshot vs. ES write):** ✅ `change_history.log_bulk.build_documents` (`type: 'app'`) and `change_history.log_bulk.es_bulk_create` (`type: 'db'`, `subtype: 'elasticsearch'`).
- **Read span (ES search):** ✅ `change_history.get_history.es_search`.
- **Restore fetch vs. restore write:** ✅ `...fetchHistory`, `...restoreRuleState`, `...restoreDeletedRule` spans.
- **Labeled by solution + action:** ✅ `logBulk`/`getHistory` carry `spanLabels` set by the alerting service (`{ solution: module, action: 'write'|'read' }`), and the security routes/methods hardcode `{ solution: 'security', action: 'restore'|'read' }`.

### Summary

Wraps the rule-changes-history hot paths in APM spans. In the shared `kbn-change-history` client, `logBulk` and `getHistory` now emit named spans, and both accept an optional `spanLabels` bag so the caller (not the package) owns the label keys/values — keeping the package solution-agnostic. The alerting `ChangeTrackingService` fills in `spanLabels` from the rule's solution module. On the Security side, the two REST routes and the three restore sub-steps are wrapped in `withSecuritySpan`. A large new unit test file for `restoreRuleFromHistory` is added, plus span-assertion tests across the touched files.

The PR description says the `restore_rule_from_history` *client method body* was instrumented — that's slightly imprecise. The top-level `restore_rule_from_history.ts` is unchanged; instead each sub-step (`fetch_rule_with_history`, `restore_deleted_rule`, `restore_rule_state`) gets its own span. The top-level method already has a generic `withSecuritySpan` from the `DetectionRulesClient` wrapper, so this is the right call — just worth noting the description/diff mismatch.

### Files touched

- **`kbn-change-history` package** (`client.ts`, `types.ts`, `moon.yml`, `tsconfig.json`): adds the two write spans + one read span, the `spanLabels` option on both option types, and the new `@kbn/apm-utils` dependency wiring.
- **Alerting change-tracking** (`change_tracking/service.ts`, `types.ts`): populates `spanLabels` from `module`, and tightens the scoped option types to `Omit<..., 'spanLabels'>` so callers can't set it (the service owns it).
- **Security routes** (`rule_history/route.ts`, `restore_rule_from_history/route.ts`): wrap the whole handler body in `withSecuritySpan`.
- **Security restore sub-steps** (`fetch_rule_with_history.ts`, `restore_deleted_rule.ts`, `restore_rule_state.ts`): each wrapped in its own span.
- **Tests + test infra**: new `restore_rule_from_history.test.ts` (359 lines), span assertions in `client.test.ts`, both `route.test.ts`, `service.test.ts`, and a new `conflict` (409) case in the shared `test_adapters.ts` mock.

### Flow trace (write path — the cross-solution one)

1. A rule mutation on the alerting path calls into `ChangeTrackingService`.
2. Service calls `client.logBulk(changes, { ...opts, spanLabels: { solution: module, action: 'write' } })` (`service.ts:159`).
3. `logBulk` destructures `spanLabels` and opens `change_history.log_bulk.build_documents` (`type: 'app'`), running the SHA-256 + sanitize loop inside it.
4. Then opens `change_history.log_bulk.es_bulk_create` (`type: 'db'`) around `client.create(...)`, inside the existing try/catch — so an ES failure still flows to the same error handling.
5. Both spans carry the caller's labels, so APM can slice write cost by solution and by hash-vs-write.

### Assumptions

- `spanLabels` is only ever `Record<string, string>` — APM label values are primitives, so passing anything else wouldn't be meaningful; the type enforces this.
- The generic outer `withSecuritySpan` on `DetectionRulesClient` methods still exists and isn't removed elsewhere, so the new sub-spans nest under it rather than becoming orphans.
- `withSpan` degrades gracefully when APM isn't started (confirmed in `with_span.ts` — it falls back to OTel `withActiveSpan`, or just runs the callback), so this adds no hard dependency on APM being active.

### Risks

- ~~**Low, but real: wrapping the synchronous build/hash loop in an async `withSpan`.**~~ **Dismissed** — yes, `withSpan` adds a microtask + `AsyncResource` hop, but the point of this span is to surface CPU cost of hashing/serialization. That insight is worth more than the instrumentation overhead. See activity #7.
- **Cosmetic churn obscures the diff.** The route + restore-substep files show large deletions/additions purely from indenting the body inside the `withSpan` closure. I read through them — the logic is byte-for-byte identical, just re-indented. No functional change.
- ~~**(should-fix) Restore happy-path tests don't assert what gets written.**~~ **Resolved** in `ef33ab49` — happy paths now assert snapshot `params.description`, `changeTracking` metadata, and (on create) `initialRevision: revision + 1`. See activity #5.
- ~~**(nit) Change-history span tests are span-only.**~~ **Resolved** in `ef33ab49` — `logBulk`/`getHistory` tests now assert `create` document shape / `search` query shape, and suite is reorganized under top-level `initialize`/`logBulk`/`getHistory`. See activity #5. Residual nit: restore suite still titled `describe('APM spans')`.
- ~~**(should-fix, observability) APM spans don't join to the persisted change-history record.**~~ **Resolved (approach A)** in `ef33ab49` — `correlationId` is merged into both write-span labels when supplied (`client.ts:193`), so APM `labels.correlationId` ↔ doc `span.id`. High-cardinality tradeoff accepted by shipping A; approach B (real APM trace id on the doc) deferred. See activities #4–#5.
- ~~**(nit, observability) The `action` label flips mid-trace on restore.**~~ **Dismissed** — outer spans say `restore` (user intent); the leaf says `read` (what `getHistory` actually does). Both are valid; it's a semantic layering of the same key, not a bug. Not worth fixing. See activity #3 / #6.

### Open questions

- `checkConcurrency` is called between `fetchRuleWithHistory` and the restore write but gets no span, even though the issue listed it as a candidate sub-step. It's a cheap synchronous revision comparison, so skipping it is defensible — was that a deliberate "not worth a span" call?
- The new `restore_rule_from_history.test.ts` adds a lot of genuine behavioral coverage (404/409/403/no_change paths), not just span assertions — good to have, but it's broader than the PR's stated scope. Was this pre-existing coverage that was missing, or added opportunistically here? Either way it's welcome; just flagging it wasn't in the description. *(Happy-path payload assertions since added — see activity #5.)*
- ~~Is `ChangeHistoryClient.logBulk`'s core behavior covered by unit tests?~~ **Partially resolved** — `ef33ab49` added `create`/`search` shape assertions in `client.test.ts`. Hashing/sanitize/redaction depth still may only be covered end-to-end; worth a glance if you're curious, not a blocker.
- Is the instrumentation meant to be aggregate-only, or should an operator be able to pinpoint a *specific* rule's write/read/restore from APM? The spans carry `{ solution, action }` (+ `correlationId` on writes) — still no `ruleId`/`objectId`/`changeId`. That's the right call for label cardinality, and it matches the load-testing goal. Per-rule diagnosis still has to come from the surrounding transaction/logs (or now via `correlationId` → doc lookup). Worth confirming that's the intent. (See activity #3.)

### Notes for your codebase map

- `withSecuritySpan` (`security_solution/server/utils/with_security_span.ts`) is a thin wrapper over `@kbn/apm-utils`'s `withSpan` that defaults `type` to the Security `APP_ID`. Use it for Security spans; use raw `withSpan` in shared packages that must stay solution-agnostic.
- `withSpan` (`kbn-apm-utils/src/with_span.ts`) intentionally queues a microtask and runs the callback in a new `AsyncResource` context so nested spans become children, not siblings — that's why instrumenting a sync block turns it async.
- Shared packages stay solution-agnostic by taking a caller-owned `spanLabels: Record<string, string>` rather than knowing about solutions; the alerting `ChangeTrackingService` is the layer that maps `RuleTypeSolution` → the `solution` label.
- The rule-changes-history write path (`logRuleChanges` → `ChangeTrackingService` → `ChangeHistoryClient.logBulk`) is shared across Security/Observability/Stack via the alerting framework — not Security-only.

### Review activities

1. **Checked span name + label conventions against the rest of Kibana.** There's no single global span-naming standard — it's per-area: the alerting plugin (the workflow write path) uses camelCase dotted `object.method` names (`backfillClient.bulkQueue.updateGaps`, `authorization.ensureAuthorized`, `taskManager.bulkSchedule`, `preValidate.checkInMemory`); SLO uses snake+colon (`slo_burn_rate_executor:eval`); `alerting_v2` uses `dispatcher:${name}`; shared AI packages (`kbn-streams-ai`) use plain snake_case (`identify_features`, `generate_stream_description`); Fleet uses kebab (`get-package-info`); core uses spaces (`resolve capabilities`). Findings: (a) the PR's **security-side** names (`getRuleHistoryRoute`, `DetectionRulesClient.restoreRuleFromHistory.fetchHistory`) match the alerting/security camelCase `Object.method` convention — good fit. (b) the PR's **shared-package** names (`change_history.log_bulk.build_documents`, `change_history.get_history.es_search`) are snake_case, which matches the shared-package precedent set by `kbn-streams-ai` and is internally self-consistent — also fine. (c) The one real wrinkle: **both casings appear in the same trace tree**. A restore request produces `restoreRuleFromHistoryRoute` → `...fetchHistory` (camel) that bottoms out in `change_history.get_history.es_search` (snake); a write produces camelCase alerting spans wrapping `change_history.log_bulk.build_documents` (snake). Defensible (package-local vs solution-local conventions) but it's the thing that stands out in a waterfall. On **labels**: the established label key across alerting/slo/alerting_v2 is `plugin` (`{ plugin: 'alerting' }`, `{ plugin: 'slo' }`, `{ plugin: 'alerting_v2' }`). This PR introduces brand-new `solution` + `action` keys (no prior use anywhere in the repo). That's intentional per the issue's acceptance criteria (filter by solution + action), so it's a justified new convention — but these spans carry no `plugin` label, so they won't filter alongside sibling alerting spans by `plugin`, and the label `action` (`read`/`write`/`restore`) overloads two existing "action" concepts in this same domain: the change doc's ECS `event.action` (e.g. `rule_update`) and the `opts.action` passed into `logBulk`. Worth a note to the author; not a blocker.

2. **Focused review — test coverage.** Pass over the six test files touched by the PR. **Findings:** (a) *[should-fix]* the two `restore_rule_from_history.test.ts` happy paths assert `rulesClient.update`/`create` were called but not with what — the restored payload, `revision + 1`, and `changeTracking.action: ruleRestore` go unverified, so a wrong-data regression passes (raised as Risk). (b) *[nit]* `client.test.ts` `logBulk`/`getHistory` tests are span-only — they don't assert the `create` payload or the returned `{ total, items }`, even though `withSpan` is mocked passthrough and the callbacks run (raised as Risk; also fed Open question on integration coverage). (c) *[nit]* suite organisation: `client.test.ts` files `logBulk`/`getHistory` span tests under `describe('ChangeHistoryClient.initialize')`, and `restore_rule_from_history.test.ts` files behavioral 404/409/403/no_change tests under `describe('APM spans')` — both mis-title the grouping so a future reader scanning for that behavior won't find it there. **Non-findings (checked, clean):** the two `route.test.ts` 409 tests are *not* redundant — `ClientError(409)` yields `{ message, status_code: 409 }` (siemResponse path) while `RuleConcurrencyError` yields `{ message, attributes: { revision } }` (response.conflict path); both branches genuinely covered. Restore sub-methods (`restore_deleted_rule`, `restore_rule_state`, `fetch_rule_with_history`, `check_concurrency`) have no dedicated test files but are exercised transitively through `restore_rule_from_history.test.ts`, which hits their branches well — aggregate coverage is reasonable, though it concentrates all weight in the one mis-titled file. Mocks use realistic builders (`resolveRuleMock`, `getRuleMock`, `generateChangeHistoryDocument`) rather than matcher placeholders — good.

3. **Focused review — observability.** Pass over the signals the instrumentation emits, since that's the PR's whole purpose. **Findings:** (a) *[should-fix]* APM spans don't join to the persisted change-history record — the per-bulk `correlationId` lives in the doc's ECS `span.id` (a random hex, not the real span id) but isn't a span label, so there's no key to correlate a failed `es_bulk_create` span with the row it wrote; adding `correlationId` as a label (bounded, one per op) would close it (raised as Risk). (b) *[nit]* the `action` label flips `restore` → `read` mid-trace: a restore's inner history fetch goes through the change-tracking service which labels it `action: 'read'`, so `change_history.get_history.es_search` leaves are labeled `read` even under a `restore` span tree — concrete fallout of the `action`-overload from activity #1 (raised as Risk). (c) *[nit]* `change_history.log_bulk.build_documents` wraps the whole change loop, so per-change build/hash cost isn't visible, and it still emits a span when `changes` is empty — acceptable tradeoff (per-item spans would explode) but noted. (d) *[consideration]* spans carry no entity dimension (`ruleId`/`changeId`) — correct for label cardinality and fine for the aggregate load-testing goal, but per-rule diagnosis then has to come from the transaction/logs (raised as Open question). **Non-findings (checked, clean):** the write error path is well-instrumented end-to-end — `withSpan` sets the span `outcome: 'failure'` and ends it in `finally`, `logBulk` rethrows (`client.ts:253`), and the alerting service catches it and logs with `correlationId` + module + dropped count, so a failed ES write shows up as both a failed APM span *and* a correlated error log. No log/metric signals were removed by the refactor — `service.ts` trace/error logs are intact, and the route handlers had (and still have) no logging of their own. `getHistory`'s span granularity is right (wraps just the `search` call).

4. **Explored approaches for correlating spans with the persisted record (follow-up to activity #3, finding a).** Two viable directions. **(A) `correlationId` as a write-span label** — fold it into the labels inside `logBulk` (`const labels = correlationId ? { ...spanLabels, correlationId } : spanLabels`) so the doc's `span.id` and the label stay in lockstep and any caller benefits; only the write spans get it (`getHistory` has no `correlationId`). Join is APM `labels.correlationId` ↔ doc `span.id`. Small, in-scope, but adds a deliberately high-cardinality label (same concern as `ruleId`). Lighter-touch variant: add `correlationId` to the `spanLabels` object in `service.ts` instead — zero package change, but wires the doc field and the label up in two files. **(B) Put the real APM trace id on the document** — pull `agent.currentTraceIds` (`trace.id`/`transaction.id`) down into the stored doc and correlate by searching the change-history data stream for `trace.id == <trace>`; keeps high-cardinality data in ES where it belongs, and fixes the misleading `span.id` (currently a random hex). Costs a direct `elastic-apm-node` dep in `kbn-change-history` and a persisted-shape/data-stream-version change, so it's arguably its own follow-up rather than part of this instrumentation PR. **Recommendation:** A now (in scope, minimal), with B noted as the eventual ECS-correct version. **Status: undecided — reached out to the PR author; awaiting their call before proposing a change.**

5. **Re-reviewed after Maxim's feedback commit (`ef33ab49`, 2026-07-15) + subsequent main merges (HEAD `9b1356e7`).** Maxim replied to every inline comment on 2026-07-15 and asked for a second look. Verified each claimed fix against the checked-out branch:

   | Your comment | Claimed fix | In code? |
   |---|---|---|
   | Reorganize `client.test.ts` + assert `create`/`search` | Top-level `initialize`/`logBulk`/`getHistory` describes; document/query shape assertions | ✅ |
   | Assert restore `update` payload | `params.description` + `changeTracking` metadata | ✅ |
   | Assert restore `create` payload + `initialRevision + 1` | snapshot + metadata + `options.initialRevision: revision + 1` | ✅ |
   | Do something with `correlationId` on spans (approach A) | `const labels = correlationId ? { ...spanLabels, correlationId } : spanLabels` on both write spans; dedicated test | ✅ |
   | Bot: concurrency tests wrong call order | `getHistory` mocked; asserts call *then* 409 after fetchHistory span | ✅ |

   **Not addressed (and not asked for in the inline comments):** (a) restore suite still titled `describe('APM spans')` despite holding the behavioral coverage — cosmetic. (b) `action` label still flips `restore` → `read` on the inner history fetch — leftover nit from activity #3 (**dismissed in activity #6**). (c) approach B (real APM trace id on the doc) deferred, which matches what you floated. CorrelationId-as-label high-cardinality tradeoff stands as accepted by shipping A.

   Bottom line: every issue you raised on the PR is fixed in the branch. Residual items above are nits / deferred, not blockers for the feedback round.

6. **Walked the restore `action`-label flip.** Confirmed the tree: route + `fetchHistory` hardcode `action: 'restore'`; alerting `ChangeTrackingService.getHistory` always stamps `action: 'read'`; `kbn-change-history` forwards those labels onto `change_history.get_history.es_search`. Reviewer judgment: not worth fixing — outer label = user intent, leaf label = actual CRUD. Semantic layering, not a bug. Risk dismissed.

7. **Dismissed async-wrap-of-sync-build risk.** Reviewer judgment: the `build_documents` span exists specifically to expose hashing/serialization CPU cost; that insight outweighs the microtask/`AsyncResource` hop `withSpan` adds on the shared write path. Keep the span.

8. **Approved PR (review 4734693335) with a soft `label.action` question.** Posted APPROVE: prior feedback verified (correlationId, suite reorg, payload assertions); also local APM smoke-test with screenshots. Left Maxim a choice — (1) keep `labels.action` as-is (`read`/`write`/`restore`), or (2) drop it entirely — and explicitly ruled out joining it to `event.action` / change-history actions (would imply a `rule_read` etc. that doesn't exist). Rationale for (2): span/transaction already encodes the operation. Note for ourselves: that rationale is strongest on the HTTP routes; the shared write path often sits inside a generic rule-mutation transaction, where **span names** (`log_bulk.*` / `get_history.es_search` / `restore*`) do the distinguishing, not the URL. Comment has a couple typos (`and and`, `sematically`) but the logic holds.
