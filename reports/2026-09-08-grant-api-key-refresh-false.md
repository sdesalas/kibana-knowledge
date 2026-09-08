# Grant API key `refresh=false` vs `bulkCreateRules` / TM

**Date:** 2026-09-08  
**Focus:** `rulesClient.bulkCreateRules` (enabled-rule create / import create path). Not `bulkUpdateRules`.  
**Context:** Local grant timing + whether we still need [elastic/elasticsearch#157410](https://github.com/elastic/elasticsearch/pull/157410) (`_bulk_grant`).  
**Related:** [elastic/kibana#273675](https://github.com/elastic/kibana/issues/273675).

**Comments this note cross-checks:**

- [jfreden, 2026-08-26](https://github.com/elastic/elasticsearch/pull/157410#issuecomment-5422425331) — `refresh=false` is enough; TM fires after the 1s auto-refresh; parallel `_grant` @ 50 workers is 14× vs sequential, `_bulk_grant` 72×.
- [sdesalas, 2026-09-08](https://github.com/elastic/elasticsearch/pull/157410#issuecomment-5587922201) — we already `pMap` 50; first TM run is jittered over 5m; auth is GET so we may not need `_bulk_grant` at all.

---

## Summary

- `bulkCreateRules` grants keys 50-wide via `pMap` → `createAPIKey` → `grantAsInternalUser` → ES `grantApiKey`. Kibana never sends `refresh`.
- ES default when omitted: stateful `refresh=wait_for` (`WAIT_UNTIL`, ~1s), serverless `refresh=true` (`IMMEDIATE`).
- Local probe (`:5605`, 1000 enabled rules, create-path import): **24.12s → 6.28s** after `refresh=false` (3.8×).
- Both comments hold. Stronger than “wait 1s”: **API key auth is a realtime GET by id**, so the key works as soon as grant returns. Search visibility is what refresh is for; TM does not search for the key.
- First run on a multi-rule `bulkSchedule` is jittered to `min(interval, 5m)` — typically 5–10s+ before anyone authenticates with the new key. GET still covers the unlucky 1ms jitter draw.

---

## `bulkCreateRules` grant path

```
bulkCreateRules.runBatch
  → pMap(prepareRule, { concurrency: API_KEY_GENERATE_CONCURRENCY })  // 50
    → createNewAPIKeySet  (only if data.enabled)
      → resolveRuleAPIKey → context.createAPIKey(name)
        → securityService.authc.apiKeys.grantAsInternalUser(...)
          → clusterClient.asInternalUser.security.grantApiKey(params)   // no refresh
  → invalidate orphaned keys
  → bulkScheduleTask(enabledRules)   // TM, see below
  → bulkCreateRulesSo
```

`pMap` site (the one linked in the 2026-09-08 comment):

```283:300:x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts
  await withSpan({ name: 'bulkCreateRules.runBatch.pMap.prepareRule', type: 'rules' }, () =>
    pMap(
      batch,
      async ({ id, rule }) => {
        const { prepared, error } = await prepareRule({ ... });
        ...
      },
      { concurrency: API_KEY_GENERATE_CONCURRENCY }
    )
  );
```

`API_KEY_GENERATE_CONCURRENCY = 50` in `alerting/.../rules_client/common/constants.ts`.

Disabled rules skip grant (`prepareRule` only calls `createNewAPIKeySet` when `data.enabled`).

Factory does not pass `refresh`:

```ts
// alerting/.../rules_client_factory.ts
await securityService.authc.apiKeys.grantAsInternalUser(request, {
  name,
  role_descriptors: {},
  metadata: { managed: true, kibana: { type: 'alerting_rule' } },
});
```

JS client: `refresh` is an optional query param on `SecurityGrantApiKeyRequest`. Omitted → not sent.

---

## ES default when `refresh` is omitted

`RestGrantApiKeyAction.innerPrepareRequest`:

```java
final String refresh = request.param("refresh");
if (refresh != null) {
    grantRequest.setRefreshPolicy(WriteRequest.RefreshPolicy.parse(refresh));
} else {
    grantRequest.setRefreshPolicy(ApiKeyService.defaultCreateDocRefreshPolicy(settings));
}
```

```
// ApiKeyService.defaultCreateDocRefreshPolicy
Stateful:   WAIT_UNTIL  → refresh=wait_for   (block until next auto-refresh, ~1s)
Serverless: IMMEDIATE   → refresh=true       (force refresh now)
```

ES comment: the wait is so the key doc is **visible in searches** when grant returns. Stateful auto-refresh is ~1s so `WAIT_UNTIL` beats `IMMEDIATE`. Serverless auto-refresh is ≥10s, so they force `IMMEDIATE`.

`refresh=false` (`NONE`) is not the default.

---

## Local experiment (2026-09-08)

Working-tree only, not staged:

```ts
// security/.../authentication/api_keys/api_keys.ts  grantAsInternalUser
this.clusterClient.asInternalUser.security.grantApiKey({
  ...params,
  refresh: false,
});
```

Shared grant helper (also hits enable / update). Measured path: **create** — `parallel_import_rules.sh` delete-then-import of `1000enabled-rules.ndjson`, `overwrite=true`, on `:5605` (create-path branch). Ignore `:5606` (main).

| Run | `:5605` import |
| --- | --- |
| Before (`wait_for` default) | **24.119467s** |
| After (`refresh=false`) | **6.280938s** |

**3.8×** (24.12 / 6.28). Full HTTP times, not isolated grant spans. Grant wait is the thing that moved.

### jfreden’s grant-only numbers (not this run)

From [elasticsearch#157410#issuecomment-5422425331](https://github.com/elastic/elasticsearch/pull/157410#issuecomment-5422425331). 1000 keys, localhost, `refresh=false`. **Grant API only** — not `rules/_import`.

| Scenario | Time | vs sequential |
| --- | --- | --- |
| Sequential `_grant` | ~12s | 1× |
| Parallel `_grant` × 50 workers | 0.884s | 14× |
| `_bulk_grant` 5 × 200 | 0.166s | 72× |

Kibana already does the middle row’s shape (50-wide `pMap`). It still uses default `wait_for`. `refresh=false` is the cheap half of that 14×. `_bulk_grant` is the remaining HTTP/round-trip cut.

---

## Comment check

### jfreden (5422425331)

> I set `refresh=false`, since it's not needed in a bulk create. The bulk created keys aren't actually used until a TaskManager task fires, which is well after the 1-second auto-refresh.

**Conclusion: true. Mechanism: only partly true.**

TM will not fail. Not because we must wait 1s — because **auth never needed the refresh**.

### sdesalas (5587922201)

> Simply call the existing endpoint with `refresh=false` in parallel (`pMap()` 50 keys at a time) … Tasks get scheduled at random within 5 minute span (when bulk created) … more like 5–10s … I don't think we actually need to bulk grant at all.

> A key granted with `refresh=false` is usable as soon as the grant returns, not after 1s. This is what Task Manager really cares about, not being able to search the key.

**Also true**, with one jitter nuance below.

### Auth is GET, not search

```java
// ApiKeyService.loadApiKeyDoc
final GetRequest getRequest = client.prepareGet(SECURITY_MAIN_ALIAS, docId)
    .setFetchSource(true)
    .request();
```

`GetRequest.realtime` defaults to `true`. GET can read the doc from the translog **before** the next refresh. Task runner decrypts the rule SO `apiKey` and authenticates with that id+secret. Usable as soon as grant returns.

Refresh only matters for query/list API keys, invalidate-by-query, anything that **searches** `.security`. TM does not do that.

### First TM fire on bulk create

`bulkCreateRules` → `bulkScheduleTask` → `taskManager.bulkSchedule`. Alerting does **not** set `runAt`. TM does:

```ts
// task_manager/.../task_scheduling.ts  bulkSchedule
if (enabled) {
  // Run now if there is only a single task.
  // Otherwise add jitter to avoid them firing together.
  scheduling =
    arr.length === 1
      ? { runAt: new Date(), scheduledAt: new Date() }
      : addJitter(modifiedTask.schedule?.interval) ?? {};
}
```

```ts
const addJitter = (interval?: string) => {
  const now = Date.now();
  const maximumOffsetTimestamp = now + 1000 * 60 * 5; // 5 minutes
  const taskIntervalInMs = parseIntervalAsMillisecond(interval);
  const maximumRunAt = Math.min(now + taskIntervalInMs, maximumOffsetTimestamp);
  const runAt = new Date(now + Math.floor(Math.random() * (maximumRunAt - now) + 1));
  return { runAt, scheduledAt: runAt };
};
```

So for a **multi-rule** create (the import case):

- `runAt` is random in `[now+1ms, now + min(interval, 5m)]`.
- 1m SIEM rules: first fire somewhere in the next **1 minute**.
- 5m+ intervals: first fire somewhere in the next **5 minutes**.
- Then TM still has to persist the task SO and claim on the next poll (default 3–5s).

That is the “random within 5 minute span” / “more like 5–10s” in the 2026-09-08 comment. Typical, yes.

**Nuance:** jitter’s lower bound is 1ms. One task in a 1000-rule batch can be scheduled almost immediately; plus poll, that can still be inside a few seconds. The GET argument is what makes that safe, not the 5m cap.

**Single-rule** `bulkSchedule` (`arr.length === 1`) sets `runAt = now`. Rare for import. Still fine: GET.

### Serverless

“1 second” is **stateful only**. Serverless auto-refresh is ≥10s. Auth still works immediately via GET. Search would lag.

---

## Implications for `#157410`

For `bulkCreateRules` / import create of enabled rules:

1. Sending `refresh=false` on the existing grant is safe for TM.
2. That is most of the grant-wait cost; Kibana already parallelises at 50.
3. `_bulk_grant` is still faster (one HTTP call per 200 vs 50 calls), but it is not required to make `refresh=false` correct.
4. Do not use `refresh=false` if something in the same request must **search** for the new keys.

A proper Kibana change would pass `refresh` through `grantAsInternalUser` (or only from alerting `createAPIKey` / `createNewAPIKeySet`) instead of hard-coding it in `APIKeys`. The 2026-09-08 edit is a local timing probe.

---

## Files

| What | Where |
| --- | --- |
| `pMap` 50 + `prepareRule` | `alerting/.../bulk_create/bulk_create_rules.ts` |
| Grant if enabled | `alerting/.../bulk_create/utils.ts` `prepareRule` |
| Key mint | `alerting/.../rules_client/lib/create_new_api_key_set.ts` |
| `createAPIKey` → grant | `alerting/.../rules_client_factory.ts` |
| ES grant call | `security/.../authentication/api_keys/api_keys.ts` |
| TM jitter | `task_manager/.../task_scheduling.ts` `bulkSchedule` / `addJitter` |
| ES REST default refresh | `elasticsearch/.../RestGrantApiKeyAction.java` |
| ES policy + auth GET | `elasticsearch/.../ApiKeyService.java` (`defaultCreateDocRefreshPolicy`, `loadApiKeyDoc`) |
