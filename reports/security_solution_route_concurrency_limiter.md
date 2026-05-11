# Security Solution route concurrency limiter

How the `security_solution` plugin caps concurrent requests on a subset of its
HTTP routes, and which routes opt in.

## Mechanism

A single global `onPreAuth` handler is registered at plugin setup
(`registerLimitedConcurrencyRoutes`). For every incoming request it:

1. Looks at the request's route tags for one starting with the prefix
   `siem:limitedConcurrency` (formed by `LIMITED_CONCURRENCY_ROUTE_TAG_PREFIX`).
2. Parses the trailing `:<N>` as the max in-flight count for that route.
3. Keeps a per-route-path `MaxCounter` in an in-memory `Map` (one process,
   not cluster-wide).
4. If the counter is already at max, **synchronously responds `429 Too Many
   Requests`** with the body `Too Many Requests` — before auth, before the
   handler runs, before any work is done.
5. Otherwise increments the counter, lets the request proceed, and decrements
   when `request.events.completed$` fires (also on abort).

Helper for declaring the tag on a route:

```ts
// x-pack/solutions/security/plugins/security_solution/server/utils/route_limited_concurrency_tag.ts
export const routeLimitedConcurrencyTag = (maxConcurrency: number) =>
  [LIMITED_CONCURRENCY_ROUTE_TAG_PREFIX, maxConcurrency].join(':');
```

Wire-up on a route:

```ts
router.versioned.post({
  path: SOME_URL,
  options: {
    tags: [routeLimitedConcurrencyTag(1)], // → '429' on 2nd concurrent call
  },
})
```

Key files:

- `server/routes/limited_concurrency.ts` — the limiter (counter, preAuth, 429).
- `server/utils/route_limited_concurrency_tag.ts` — tag builder helper.
- `common/constants.ts` — `LIMITED_CONCURRENCY_ROUTE_TAG_PREFIX = 'siem:limitedConcurrency'`.

### Caveats

- **Per-process**, not cluster-wide. A multi-node Kibana deployment gets `N × cap` global
  concurrency.
- **Per route path** (`request.route.path`), not per user/space/tenant. One
  noisy caller starves everyone else on that route.
- **No queueing.** Over-limit callers get an immediate 429; there's no fair
  scheduling, no retry-after header.
- **Counter never resets explicitly.** If `completed$` never fires for some
  reason (extremely unlikely with Hapi/Kibana), the slot leaks for the
  lifetime of the process.

## Which routes opt in

| Route                                  | Path                                                                       | Max concurrency | Constant / source                                                                                          |
|----------------------------------------|----------------------------------------------------------------------------|-----------------|------------------------------------------------------------------------------------------------------------|
| **Perform prebuilt rule installation** | `POST /internal/detection_engine/prebuilt_rules/installation/_perform`     | **1**           | `PREBUILT_RULES_OPERATION_CONCURRENCY` — `prebuilt_rules/api/perform_rule_installation/perform_rule_installation_route.ts` |
| **Perform prebuilt rule upgrade**      | `POST /internal/detection_engine/prebuilt_rules/upgrade/_perform`          | **1**           | `PREBUILT_RULES_OPERATION_CONCURRENCY` — `prebuilt_rules/api/perform_rule_upgrade/perform_rule_upgrade_route.ts`            |
| Review prebuilt rule upgrade           | `POST /internal/detection_engine/prebuilt_rules/upgrade/_review`           | 3               | `PREBUILT_RULES_UPGRADE_REVIEW_CONCURRENCY` — `prebuilt_rules/api/review_rule_upgrade/review_rule_upgrade_route.ts`         |
| Review prebuilt rule installation      | `POST /internal/detection_engine/prebuilt_rules/installation/_review`      | 5               | `PREBUILT_RULES_INSTALLATION_REVIEW_CONCURRENCY` — `prebuilt_rules/api/review_rule_installation/review_rule_installation_route.ts` |
| Bulk actions on rules                  | `POST /api/detection_engine/rules/_bulk_action`                            | 5               | `MAX_ROUTE_CONCURRENCY` — `rule_management/api/rules/bulk_actions/route.ts`                                |
| Rule preview                           | `POST /internal/detection_engine/rules/preview`                            | 10              | `MAX_ROUTE_CONCURRENCY` — `rule_preview/api/preview_rules/route.ts`                                        |
| **Import rules (.ndjson upload)**      | `POST /api/detection_engine/rules/_import`                                 | **no limit**    | No `routeLimitedConcurrencyTag` on the route options — the pre-auth handler passes through.                |

All concurrency values are defined here:

- `server/lib/detection_engine/prebuilt_rules/constants.ts` — `PREBUILT_RULES_OPERATION_CONCURRENCY`, `PREBUILT_RULES_UPGRADE_REVIEW_CONCURRENCY`, `PREBUILT_RULES_INSTALLATION_REVIEW_CONCURRENCY`.
- The two `MAX_ROUTE_CONCURRENCY` are local consts inside their respective route files.

## Notes specific to `rules/_import`

- The endpoint itself has **no per-route concurrency cap**. The pre-auth
  limiter only acts on tagged routes, and the `_import` route does not include
  the `siem:limitedConcurrency:<N>` tag.
- Practical caps still apply per request: `maxRuleImportPayloadBytes` (10 MiB
  default), `maxRuleImportExportSize` (10,000 rules default), and an idle
  socket timeout of `RULE_MANAGEMENT_IMPORT_EXPORT_SOCKET_TIMEOUT_MS` (1 hour).
- Internally each request chunks rules in groups of 50
  (`CHUNK_PARSED_OBJECT_SIZE = 50`) and calls `bulkCreateRules` per chunk, so
  the unbounded-concurrency behavior modeled in
  `bulk_create_rules_batching_flow.md` applies **per request** and stacks
  across concurrent requests.
- If we wanted `_import` to behave like the prebuilt `_perform` endpoints (one
  at a time, 429 on overlap), the change is a single-line addition:
  `tags: [routeLimitedConcurrencyTag(1)]` on the route options.
