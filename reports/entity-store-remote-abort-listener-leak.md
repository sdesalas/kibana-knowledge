# Entity Store — remote logs extraction AbortSignal listener not removed

**Date:** 2026-08-05
**Owner:** Entity Analytics (`@elastic/security-entity-analytics`)
**Files:**
- Bug: `x-pack/solutions/security/plugins/entity_store/server/domain/logs_extraction/remote/remote_logs_extraction_client.ts`
- Correct pattern: `x-pack/solutions/security/plugins/entity_store/server/domain/logs_extraction/logs_extraction_client.ts`
- Same correct pattern elsewhere: `server/tasks/entity_maintainers/execution.ts`

**Introduced:** [elastic/kibana#266307](https://github.com/elastic/kibana/pull/266307) (CCS log-slice pagination, merged 2026-04-29) — `removeEventListener` deleted during refactor and never restored. Carried into the unified remote client by [elastic/kibana#268007](https://github.com/elastic/kibana/pull/268007) (CPS).

**Prior art on that PR:** Macroscope flagged the missing remove as 🟠 High. Author ([@romulets](https://github.com/romulets)) dismissed it — *“This is not a functional bug, it's a log message being leaked. The complexity of cleaning on a try catch is not worth it.”* — and the thread was resolved without a fix. This report is a rediscovery, not a first finding.

---

## TL;DR

`RemoteLogsExtractionClient.runLogsPaginationOuterLoop` registers an `abort` listener on the task `AbortSignal` and never removes it. The local extraction path and entity-maintainer runner both remove in `finally` (local also attaches once per sub-window — it just cleans up each time).

Real hygiene bug / asymmetry with the local path. **Heap impact is small** under Task Manager’s per-run `AbortController` and a tiny closure. Still worth a one-line/`finally` fix plus a regression test, especially since the [introducing PR knowingly left it](https://github.com/elastic/kibana/pull/266307#discussion_r3161348695).

---

## Claim (source)

Observation from Hannah Brooks (DEX — finder only):

> In `remote_logs_extraction_client.ts` we add an `onAbort` listener to the `AbortSignal` on every iteration but never remove it. Each listener captures a reference to the extraction client so those objects stay in heap. The non-CCS path (`logs_extraction_client.ts`) already has the fix of removal.

Code review confirms the missing remove. Nuances:

1. **“Every iteration”** — `addEventListener` runs once per `runLogsPaginationOuterLoop` call (once per **sub-window** in `doExtractToUpdates`’s `while`), not once per inner log-slice `do…while` iteration.
2. **Closure contents are small** — `onAbort` closes over `this`, `type`, `totalCount`, `totalPages`, and module-level `entityStoreMetrics`. It does **not** close over probe/ESQL result pages or ingested entity batches.
3. **Client retention via `this`** — technically true, but the client is already held for the whole task run by `LogsExtractionClient` / the factory. This listener does not create a meaningful long-lived pin beyond the signal’s lifetime.

---

## Code comparison

### Remote (bug)

```358:368:x-pack/solutions/security/plugins/entity_store/server/domain/logs_extraction/remote/remote_logs_extraction_client.ts
    const onAbort = () => {
      this.logger.info(
        `Aborting logs extraction, entities extracted until abort: ${totalCount}, in ${totalPages} pages`
      );
      entityStoreMetrics.extractionTaskAborted.add(1, {
        entity_type: type,
        namespace: this.namespace,
        remote: true,
      });
    };
    signal?.addEventListener('abort', onAbort);
```

No `removeEventListener` / `finally` in this file. Every return path leaves the listener registered.

### Local (correct cleanup; same attach cadence)

Local attaches inside `runMainExtractionLoop`, which `runMainPath` calls **once per sub-window** — same frequency as remote. Difference is the `finally`:

```546:546:x-pack/solutions/security/plugins/entity_store/server/domain/logs_extraction/logs_extraction_client.ts
    opts?.signal?.addEventListener('abort', onAbort);
```

```656:658:x-pack/solutions/security/plugins/entity_store/server/domain/logs_extraction/logs_extraction_client.ts
    } finally {
      opts?.signal?.removeEventListener('abort', onAbort);
    }
```

### Maintainer runner (also correct)

`server/tasks/entity_maintainers/execution.ts` adds in `try` and removes in `finally` (~L260 / ~L313).

---

## Call path & how often listeners are added

```
Task Manager createTaskRunner({ signal })
  → extract_entity_task.runTask({ signal })
    → LogsExtractionClient.extractLogs(type, { signal })
      → Promise.all([
          runMainPath(...),                          // per sub-window: add + finally remove
          remoteLogsExtractionClient.extractToUpdates({ signal })
        ])
          → doExtractToUpdates
            → while (hasNextPage)                    // sub-windows (maxTimeWindowSize, default 15m)
                 runLogsPaginationOuterLoop(...)     // ADD listener, never remove
                   → do { probe + entity pages } while (!isLastLogsPage)
```

Defaults (global state constants):
- `frequency` = `1m`
- `lookbackPeriod` = `3h`
- `maxTimeWindowSize` = `15m`
- `maxLogsPerWindow` = `100_000`
- Lag cutoff at `1.5 × lookbackPeriod` (`MAX_LAG_LOOKBACK_FACTOR`)

| Scope | Listeners added |
|---|---|
| Per log-slice (`do…while`) | 0 extra (listener is outside that loop) |
| Per sub-window (`runLogsPaginationOuterLoop`) | **+1**, retained until signal dies |
| Per `extractToUpdates` / task run | **N** ≈ number of sub-windows (often 1 in steady state; on the order of tens if catching up within lag cutoff, not unbounded) |
| Force remote API (`force_remote_extract_to_updates`) | **0** — no `signal` passed |

---

## AbortSignal lifetime

Task Manager allocates a **fresh** controller per execution:

```452:457:x-pack/platform/plugins/shared/task_manager/server/task_running/task_runner.ts
          const abortController = new AbortController();

          this.task = definition.createTaskRunner({
            taskInstance: sanitizedTaskInstance,
            fakeRequest,
            signal: abortController.signal,
```

Cancel wraps `abortController.abort()`. Caveat: `this.task = undefined` only runs on `cancel()`, not after a successful run — so the wrapped `cancel` (closing over that run’s controller) can outlive the run until the `TaskRunner` is dropped or `this.task` is overwritten. That is still not a process-lifetime accumulator, but the “GC immediately when run returns” story is slightly softer than “controller is function-local and gone.”

This is **not** the classic long-lived shared `AbortSignal` that piles listeners forever across unrelated work.

---

## Memory impact

| Factor | Assessment |
|---|---|
| Missing `removeEventListener` | **Confirmed bug** |
| Asymmetry with local + maintainers | **Confirmed** (local attaches per sub-window too; it removes) |
| Listener per log-slice iteration | **Overstated** — once per outer-loop / sub-window |
| Listener retains large log/entity payloads | **No** — small bindings + `this` |
| Client pin via `this` | Redundant with normal task-run lifetime of the client |
| Cross-task-run accumulation | Unlikely as a forever-leak; TM gives a new controller per run |
| Intra-run stacking | Real but small (N modest under defaults + lag cutoff) |
| Known on intro PR | Yes — flagged High, dismissed as non-functional |

**Bottom line:** Fix the asymmetry. Don’t treat this as a major heap-growth driver; the expensive remote-path cost under high volume is still the working set (capped docs, entity pages, ESQL responses).

---

## How the bug was introduced

In [#266307](https://github.com/elastic/kibana/pull/266307), CCS extraction was split into probe + outer/inner pagination. The old single-pass client had:

```ts
abortController?.signal.removeEventListener('abort', onAbort);
```

after the entity pagination loop. The refactor **deleted** that line and moved `addEventListener` into the new outer loop without a matching `finally`. Local extraction kept cleanup.

Macroscope review on that PR already described the exact failure mode (listener never removed on normal completion; closure over counters). It was consciously not fixed.

[#268007](https://github.com/elastic/kibana/pull/268007) later folded CCS/CPS into `remote_logs_extraction_client.ts` and preserved the broken pattern.

[#279282](https://github.com/elastic/kibana/pull/279282) (Task Manager: pass `AbortSignal` instead of `AbortController`) mechanically rewrote `abortController.signal` → `signal` on both paths; local kept remove, remote still had none.

---

## Suggested fix

Mirror the local client: wrap the outer-loop body in `try/finally` and always remove.

```ts
const onAbort = () => { /* unchanged */ };
signal?.addEventListener('abort', onAbort);
try {
  // existing do…while log-slice loop
  // ...
  return { ... };
} finally {
  signal?.removeEventListener('abort', onAbort);
}
```

Optional:
- `{ once: true }` on add **and** still remove in `finally` for the non-abort completion path (`once` only auto-removes after fire).
- Hoist the listener to `doExtractToUpdates` (one add/remove per extract) so sub-windows share one registration — same optional cleanup on the local side if desired for symmetry.

---

## Test gaps

`remote_logs_extraction_client.test.ts` covers abort **behavior** (ESQL rejects with `AbortError` → error result) but does **not** assert listener cleanup.

Suggested tests:
1. Run `extractToUpdates` to successful completion with a signal; assert `removeEventListener` for the same handler (or that a later `abort()` does not fire side effects).
2. Early return via `maxLogsPerWindow` cap — cleanup still runs.
3. Abort mid-extraction — cleanup still runs.

---

## Ownership / who to ping
| | |
|---|---|
| Owning team | Entity Analytics — `@elastic/security-entity-analytics` |
| CODEOWNERS path | `x-pack/solutions/security/plugins/entity_store` |
| Original CCS pagination + dismissal | Rômulo Farias (#266307) |
| CPS remote unification | Or Ouziel / @orouz (#268007) |
| TM signal API change | Lucia Petracca (#279282) — mechanical; not the root cause |
---

## Related Kibana issues (search 2026-08-05)

**No open Kibana issue tracks this specific remote `onAbort` cleanup gap.** Closest prior art is the same *class* of bug (abort listeners piled on a reused/long-lived `AbortSignal`), already closed elsewhere:

| Issue | State | Relevance |
|---|---|---|
| [#65051](https://github.com/elastic/kibana/issues/65051) `[Search] Memory leaks caused by AbortController` | Closed | Classic: subscribe to abort without cleanup / already-aborted handling |
| [#126089](https://github.com/elastic/kibana/issues/126089) `[Alerting] Possible EventTarget memory leak detected` | Closed | **Closest pattern** — same abort signal reused across searches; handlers not cleaned → `MaxListenersExceededWarning` |
| [#126081](https://github.com/elastic/kibana/issues/126081) `[Security Solution] Possible EventTarget memory leak detected` | Closed | Downstream symptom of #126089 |
| [#131343](https://github.com/elastic/kibana/issues/131343), [#132571](https://github.com/elastic/kibana/issues/132571), [#132574](https://github.com/elastic/kibana/issues/132574) | Closed | Same `EventTarget` / `MaxListenersExceededWarning` family (async search / TSVB / dashboard) |
| [#261549](https://github.com/elastic/kibana/issues/261549) `[Entity Store] [META] Improve Performance under load` | Open | Same product area / load pain; about ES heap + extraction volume, **not** abort-listener hygiene |
| [#269263](https://github.com/elastic/kibana/issues/269263) hard cap on logs per window | Closed | Mitigation for volume, orthogonal to listener cleanup |

Also: the bug was discussed only on [PR #266307](https://github.com/elastic/kibana/pull/266307) review (Macroscope High → dismissed), never promoted to an issue.

---

## Checklist

- [ ] Add `try/finally` + `removeEventListener` in `runLogsPaginationOuterLoop`
- [ ] Unit test: successful completion removes listener
- [ ] Unit test: cap early-return removes listener
- [ ] Unit test: abort mid-extraction removes listener
- [ ] (Optional) Hoist listener to `doExtractToUpdates` so sub-windows share one registration
- [ ] (Optional) Audit other entity_store `addEventListener('abort'` call sites — currently only remote is missing remove
- [ ] (Optional) File a small Kibana issue — none exists today for this gap
