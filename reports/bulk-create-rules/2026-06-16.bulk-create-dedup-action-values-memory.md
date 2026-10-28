# Memory impact: deduplicating `addGeneratedActionValues`

Kibana has historically hit OOM during bulk rule creation — the Node heap is finite and large rule sets with actions compound quickly. Any change that increases peak memory during this flow needs to be weighed carefully.

Moving the `addGeneratedActionValues` call from `prepareRule` (B1, per-batch) to `preValidate` (A1, upfront) eliminates a redundant call per rule — saving one `uiSettings` fetch and one `buildEsQuery` per action per rule. The tradeoff is that the enriched action data now lives in the `validated` map for the entire duration of the operation, rather than being created and discarded within each `prepareRule` call where at most `API_KEY_GENERATE_CONCURRENCY` (~50) were in flight simultaneously. This means the full set of enriched actions is held in memory from A1 through the final batch — every shallow-copied data object, every generated UUID, and every serialized DSL string.

The new per-rule allocation is a shallow copy of the rule's `data` object plus new action objects containing a UUID string and (when `alertsFilter` is present) a new `alertsFilter` wrapper with a serialized DSL string. The DSL string is the dominant cost — a `JSON.stringify(buildEsQuery(...))` output that varies with filter complexity. Previously this enriched data was a throwaway local inside the A1 loop (one rule at a time, GC'd each iteration); now it accumulates for all N rules and persists through every batch in phase B. The table below estimates the net peak memory increase assuming 3 actions per rule.

| Item | Without alertsFilter | With alertsFilter |
|---|---|---|
| `{ ...rule, data }` wrapper | ~64 B | ~64 B |
| `{ ...rule.data, actions, systemActions }` spread | ~150 B | ~150 B |
| `genActions` array shell (3 elements) | ~56 B | ~56 B |
| Per-action object shell + shared refs | 3 × ~80 B = ~240 B | 3 × ~80 B = ~240 B |
| Per-action UUID string (36 chars) | 3 × ~56 B = ~168 B | 3 × ~56 B = ~168 B |
| Per-action alertsFilter + query wrapper | — | 3 × ~200 B = ~600 B |
| Per-action DSL string (500–2000 B typical) | — | 3 × ~1000 B = ~3000 B |
| `genSystemActions` array (empty) | ~40 B | ~40 B |
| **Per-rule total** | **~718 B** | **~4318 B** |
| **3K rules peak RAM increase** | **~2.1 MB** | **~12.7 MB** |
| **10K rules peak RAM increase** | **~7.0 MB** | **~42.2 MB** |
