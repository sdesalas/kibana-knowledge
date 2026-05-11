# PR Review: #265775
**[@kbn/change-history] Rename stream to .kibana_change_history; snapshots-only schema and API**

**Scale:** Substantive — breaking API changes to a shared platform package, touching types, mappings, client logic, tests, and docs.

---

## Ownership (team: `@elastic/security-detection-rule-management`)

- **Your team's files (8):** all files under `x-pack/platform/packages/shared/kbn-change-history/` — squarely in scope.
- **Unowned:** `api_docs/kbn_change_history.devdocs.json`, `api_docs/kbn_change_history.mdx` — generated files, no CODEOWNERS entry.

---

## Summary

Cleans up `@kbn/change-history` before GA: renames the data stream from `.kibana-change-history` to `.kibana_change_history` (dash → underscore), strips the diff-computation subsystem entirely (removing `object.diff`, `object.index`, `ObjectChange.before`, and all related types), and renames `ObjectChange.after` to `snapshot` to match the stored field name. The package now does one thing: record post-change snapshots. The PR description matches the diff accurately. The feature flag `FLAGS.FEATURE_ENABLED` remains `false`, so this is still dead code in production.

---

## Files touched

| Group | Files | Why modified |
|---|---|---|
| Core API | `src/types.ts`, `src/client.ts` | Removed diff types, renamed `after` → `snapshot`, removed `fieldsToIgnore` |
| Schema | `src/mappings.ts`, `src/constants.ts` | Stream name rename, removed `object.index` / `object.diff` mappings |
| Utilities | `src/utils.ts`, `src/utils.test.ts` | Removed `defaultDiffCalculation`; `hashFields` unchanged |
| Tests | `integration_tests/client.test.ts` | Updated to use `snapshot` field, removed diff-related assertions |
| Docs | `README.md`, `api_docs/*` | Reflects schema changes; api_docs regenerated with build script |

---

## Flow trace

1. Caller constructs `ChangeHistoryClient({ module, dataset, logger, kibanaVersion })` — validates no `|` in module/dataset.
2. During plugin `start()`, calls `client.initialize(esClient)` — creates the hidden data stream `.kibana_change_history` via `DataStreamClient.initialize`.
3. After a rule change, caller calls `client.log(change, opts)` → delegates to `logBulk([change], opts)`.
4. `logBulk` iterates changes; for each: computes `hash = sha256(JSON.stringify(change.snapshot))` **before** hashing, then runs `hashFields(change.snapshot, opts.fieldsToHash)` to replace sensitive string fields with SHA-256 digests.
5. Builds a `ChangeHistoryDocument` with `event.id = uuidv7()`, writes it to the data stream via `client.create(request)` — scoped to the Kibana space.
6. On read: `getHistory(spaceId, objectType, objectId)` queries with `bool.filter` on `event.module`, `event.dataset`, `object.type`, `object.id`; sorts by `object.sequence desc`, `@timestamp desc`, `event.id desc`.

---

## Assumptions

- **No production data in the old stream name.** The rename from `.kibana-change-history` to `.kibana_change_history` is not a migration — ES won't carry old documents forward. Safe only because `FEATURE_ENABLED = false` means no production writes ever happened under the old name. Any dev/testing environments that ran `initialize()` with the old name will have a leftover stream to clean up manually.
- **No active consumers of the removed types.** `ChangeHistoryDiff`, `ChangeHistoryDiffOptions`, `ChangeHistoryFieldsToIgnore`, `ObjectChange.before/after`, and `fieldsToIgnore` were all removed as breaking changes. Confirmed safe: `grep` shows zero TS consumers of `@kbn/change-history` outside the package itself.
- **Partial bulk failures are silently dropped.** `DataStreamClient.create` handles partial ES bulk errors internally without throwing (confirmed by integration test at line 295). Items that fail indexing (e.g. wrong `sequence` type) are lost without surfacing to the caller. The `logBulk` wrapper only throws on total failure.
- **`object.hash` is computed pre-hashing.** Hash at line 186 of `client.ts` is SHA256 of the original snapshot, before `hashFields` masks sensitive fields. This is intentional — the hash tracks real content changes, not the masked representation.
- **Mappings are still `v1`.** If `DataStreamClient` performs version checks on existing data streams, running this against a dev cluster with a prior `v1` stream at the old name could cause issues. With `lazyCreation: false`, it will attempt creation and likely succeed since the old stream name is different.

---

## Risks

1. **Data stream name mismatch on dev clusters** — Anyone who ran `initialize()` against the old `.kibana-change-history` stream has an orphaned stream. Low severity since the feature is gated, but the stream exists on disk and will accumulate until cleaned. No cleanup step is provided.
2. **`FEATURE_ENABLED = false` is a manual gate, not a config flag** — The constant is mutated directly in tests (`FLAGS.FEATURE_ENABLED = true` in `beforeAll`). This works, but it means enabling the feature in production requires a code change, not a config change. If the release plan involves a feature flag service (e.g. kibana.yml flag), that wiring isn't in this PR.
3. **ILM policy unresolved** — `client.ts:110` has an open `TODO`: `// TODO: What about ILM policy (defaults to none = keep forever)`. Data written to this stream will never roll off without manual ILM. That's a pre-existing issue, not introduced here, but it's getting closer to GA without being resolved.
4. **Silent partial failures in `logBulk`** — As noted above, items that fail indexing (e.g. a bad runtime `sequence` value) are silently dropped. The caller has no way to know which changes were persisted. For a security audit trail, this trade-off deserves explicit acknowledgment.

---

## Open questions

1. **Stream migration on GA**: When `FEATURE_ENABLED` is flipped to `true`, is there a plan to migrate or redirect any data from the old `.kibana-change-history` stream name (from dev environments)? Or is the assumption that dev environments just need manual cleanup?
2. **`FEATURE_ENABLED` gate**: Is this intended to stay as a code-level constant, or will it be replaced by a Kibana feature flag / experimental config before GA? The `remove this after GA` comment suggests the flag goes away entirely — is that the plan?
3. **ILM policy**: Was the ILM TODO explicitly deferred to a follow-up issue? Without a retention policy, this stream grows unbounded.
4. **Partial failure behavior in `logBulk`**: Is it intentional that the caller can't distinguish "all changes saved" from "some changes dropped silently"? For an audit history feature this feels like it should at least log a warning with the count of dropped items.
5. **`object.hash` semantics**: The hash is computed from the pre-hashing snapshot (line 186). Is that documented anywhere for consumers? A consumer comparing hashes across snapshots where `fieldsToHash` changed between writes would see hash changes that don't reflect actual object changes.

---

## Notes for your codebase map

- `@kbn/change-history` is a pre-GA platform package with no active consumers; `FLAGS.FEATURE_ENABLED = false` gates all initialization.
- The package writes to a single hidden data stream `.kibana_change_history`; each client instance is scoped by `(module, dataset)` and queries are further scoped by Kibana space.
- `DataStreamClient` (from `@kbn/data-streams`) handles the actual ES data stream lifecycle; `ChangeHistoryClient` is a thin domain wrapper.
- `hashFields` in `utils.ts` flattens the snapshot, replaces matching string-valued paths with SHA-256 digests, then unflattens — without mutating the original.
- Bulk partial failures are silently absorbed by the underlying `DataStreamClient.create` — see integration test at line 269 in `client.test.ts` for the confirmed behavior.
- The `SEPARATOR_CHAR = '|'` in `constants.ts` is validated at construction time to prevent module/dataset values from polluting scoped queries.