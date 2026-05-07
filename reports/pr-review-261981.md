# PR Review: #261981

**Scale:** Substantive — new service, plugin lifecycle wiring, ES data stream, multiple files.

---

## Summary

Introduces `ChangeTrackingService` as dormant infrastructure inside the alerting framework to support future rule change history recording. The service wraps `@kbn/change-history`'s `ChangeHistoryClient` (one client per solution domain: security/observability/stack) and provides `log`, `logBulk`, and `getHistory` methods. It is gated behind `xpack.alerting.ruleChangeTracking.enabled` (default `false`) so no data stream is created or written to in production until explicitly turned on. **No actual `log`/`logBulk` calls are made in this PR** — it is pure infrastructure wiring.

The stated intent (first of several PRs for rule change history) matches the diff well. The change is additive and non-breaking.

---

## Ownership

- **`/x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/`** → `@elastic/security-detection-rule-management` (newly added CODEOWNERS entry)
- **All other alerting files** → `@elastic/response-ops`
- **`kbn-change-history` package** → not shown in diff additions to CODEOWNERS

---

## Files touched

| Group | Files | Role |
|---|---|---|
| New service | `rules_client/lib/change_tracking/index.ts`, `index.test.ts` | Core of the PR — the ChangeTrackingService impl and unit tests |
| Plugin lifecycle | `plugin.ts` | Constructs service in constructor, registers modules in `registerType`, initialises ES client in `start()` |
| Config | `config.ts`, `config.test.ts` | New `ruleChangeTracking` schema block |
| Factory wiring | `rules_client_factory.ts`, `.test.ts`, `rules_client/types.ts` | Threads `changeTrackingService` into `RulesClientContext` |
| kbn-change-history | `index.ts` | Exports `FLAGS` as internal-only, for test use |
| FTR tests | `group6/change_tracking/enabled.ts`, `disabled.ts`, `config_with_change_tracking_enabled.ts` | Integration: asserts data stream created/not-created |
| CI | `.buildkite/ftr_platform_stateful_configs.yml` | Registers the new FTR config |
| CODEOWNERS | `.github/CODEOWNERS` | Assigns `change_tracking/` folder to detection-rule-management |

---

## Flow trace

When Kibana starts with `xpack.alerting.ruleChangeTracking.enabled: true`:

1. **`AlertingPlugin` constructor** — `ChangeTrackingService` instance created (`this.changeTrackingService`), no ES connection yet.
2. **`setup() > registerType()`** — for each rule type registered by any plugin, if its `solution` is in `config.ruleChangeTracking.scope` (or scope includes `'all'`), `changeTrackingService.register(ruleType.solution)` is called. This creates one `ChangeHistoryClient` per unique solution domain.
3. **`start()`** — `changeTrackingService.initialize(core.elasticsearch.client.asInternalUser)` is called. This is **fire-and-forget** (`void initializeAll(...).catch(logger.error)`). `initializeAll` iterates registered clients in sequence and calls `ChangeHistoryClient.initialize()` on each, which creates the `.kibana-change-history` data stream via `DataStreamClient`.
4. **`rulesClientFactory.initialize()`** — `changeTrackingService` is stored on the factory.
5. **Per-request `factory.create()`** — `changeTrackingService` flows into `RulesClient` constructor as `RulesClientContext.changeTrackingService`.
6. **Future PRs** — `RulesClient` methods (`create`, `update`, `delete`, etc.) will call `context.changeTrackingService?.log(...)` to record changes. Not present in this PR.

---

## Assumptions

- **Rule types are registered during `setup()`**, before `start()` is called. The `register()` calls therefore happen before `initialize()`. This ordering is correct per Kibana's plugin lifecycle contract, but any rule type registered *after* `setup()` (not currently possible, but worth noting) would be missed.
- **ES is available when `start()` fires.** If ES is temporarily unavailable at startup, `initializeAll` will log errors and the clients will remain uninitialized (`this.client` stays `undefined` in each `ChangeHistoryClient`). There is no retry mechanism — the data stream will never be created until the next Kibana restart.
- **`FLAGS.FEATURE_ENABLED` starts as `false`** in the `kbn-change-history` package. The test fixture plugin sets it to `true` during `setup()`. If another plugin or test has already cached an import of the constants module with `FEATURE_ENABLED: false`, there could be a stale-closure issue. In practice, because `FLAGS` is an object (not a primitive), mutations are visible to all importers — so this works, but it's fragile.
- **`scope: ['stack']` in the FTR enabled test** relies on at least one `stack`-solution rule type being registered (e.g. `es_query`, `index_threshold` from `@kbn/stack-alerts`). The test only checks that the data stream exists, not that any rule type was actually tracked — so this is fine as long as those rule types are present in the test server.
- **logBulk errors are non-fatal** — intentional design. Change history is observability data; a write failure must not affect rule operations.

---

## Risks

1. **No ILM policy.** The `TODO` in `client.ts` notes there's no ILM policy, meaning `.kibana-change-history` grows unbounded. Once the feature is enabled and actual writes happen, this will need addressing before GA.

2. **Silent initialization failure with no recovery.** `initialize()` is fire-and-forget. If it fails (ES unavailable, permissions issue, etc.), `changeTrackingService.isInitialized()` returns `false` forever and all subsequent `logBulk` calls silently discard data. There's no health-check, alerting, or retry. This is probably acceptable for a first PR but worth flagging to reviewers.

3. **Mutable global `FLAGS.FEATURE_ENABLED`.** Exporting a mutable object to flip a global feature flag is an unusual pattern. The `@internal` JSDoc and the note in `index.ts` about "test use only" are good guardrails, but if any production code path reaches `ChangeHistoryClient.initialize()` while `FLAGS.FEATURE_ENABLED = false`, it throws and the entire `initializeAll` for that module fails (caught and logged, so non-fatal). The test fixture plugin correctly resets it in `stop()`.

4. **Disabled FTR test uses a hardcoded 5-second `setTimeout`.** In `disabled.ts`, the test sleeps 5s before asserting the data stream *doesn't* exist. On a slow CI runner this could still be racy if initialization is still in progress. (Minor, but worth noting.)

5. **`changeTrackingService` passed twice in `start()`.** Line 658 calls `changeTrackingService?.initialize(...)` using the destructured local variable, and line 678 passes `this.changeTrackingService` to `rulesClientFactory`. Both reference the same object, so there's no bug — but it's slightly inconsistent.

---

## Open questions

1. The `RuleChangeHistoryDocument` interface declares a `rule: SanitizedRule` field (extending `ChangeHistoryDocument`), but `ChangeTrackingService.logBulk` delegates to `ChangeHistoryClient.logBulk` which only constructs a plain `ChangeHistoryDocument` — the `rule` field is never populated. Is this type intended to describe future documents, or is it already mismatched?

2. `scope` accepts `'all'` as a valid config value, but `RuleTypeSolution` (the type on `RuleTypeSolution` from `@kbn/alerting-types`) doesn't include `'all'`. The `ruleChangeTrackingSolutions` schema adds it locally. Is `'all'` meant to be part of a broader type at some point, or will it always be a config-only escape hatch?

3. No ILM policy — is there a follow-up ticket for this, or is it expected to be addressed in a later PR in this series?

4. If `initialize()` fails silently (ES unavailable at startup), is there a plan to surface this as a health-check indicator or to retry? Or is lost history at startup considered acceptable?

5. The CODEOWNERS entry assigns `change_tracking/` to `@elastic/security-detection-rule-management`, but the rest of the alerting plugin is `@elastic/response-ops`. Will response-ops need to approve changes to `plugin.ts` wiring even if the change tracking logic stays within its folder?

---

## Notes for your codebase map

- `ChangeTrackingService` lives at `alerting/server/rules_client/lib/change_tracking/` and is instantiated once per Kibana process in `AlertingPlugin`. It is solution-scoped (one `ChangeHistoryClient` per domain).
- `kbn-change-history` (`@kbn/change-history`) is the shared lower-level package. It owns the data stream name (`.kibana-change-history`), mappings, and the generic `ChangeHistoryClient`. The alerting plugin wraps it with rule-specific defaults (ignore fields, hash fields, object type).
- `FLAGS.FEATURE_ENABLED` in `kbn-change-history/src/constants.ts` is the package-level kill switch. Currently `false` — the package will throw on `initialize()` until this is flipped, which is only done in test fixtures for now.
- The `RulesClientContext` carries `changeTrackingService?: IChangeTrackingService` — callers should treat it as optional and check before calling (the `?.` pattern is already used throughout).
- `logBulk` groups changes by `module` (solution) and makes one ES bulk call per solution, sharing a single `correlationId` across the batch.
- Sensitive fields (`apiKey`, `uiamApiKey`) are SHA-256 hashed before storage. Volatile runtime fields (`executionStatus`, `monitoring`, `lastRun`, `nextRun`, `scheduledTaskId`) are excluded from the diff.
