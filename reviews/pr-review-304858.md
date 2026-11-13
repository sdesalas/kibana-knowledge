# PR Review: #304858 — [Security Solution] Skip Endpoint authz when rule has no response actions on bulk write

**PR:** [elastic/kibana#304858](https://github.com/elastic/kibana/pull/304858) by @sdesalas
**Created Date: 2026-11-13**

**Scale:** Small, but it touches authz, so I traced the risky parts in full.

### Summary

Two changes, both from [#298458](https://github.com/elastic/kibana/issues/298458):

1. `authorizeResponseActions` returns early when neither the new params nor the previous params have response actions, so `getEndpointAuthz` (Fleet → ES `_has_privileges`) is never called for those rules.
2. `EndpointAppContextService.getEndpointAuthz` now caches its promise per `KibanaRequest` in a `WeakMap`, and drops the entry if it rejects.

The diff matches the issue's "basic fix" plus its suggested "larger fix". It doesn't go beyond either one.

### Files touched

- **Detection Engine authorizer** (`@elastic/security-detection-engineering`): `authorize_rule_response_actions.ts` and its test. This is the Security rule-type params authorizer that Alerting calls on every create, update, bulk create, bulk update, bulk edit and enable.
- **Endpoint service** (`@elastic/security-defend-workflows`): `endpoint_app_context_services.ts` and its test. This is the shared singleton behind about 20 `getEndpointAuthz` callers: endpoint routes, Agent Builder tools, search strategies, exceptions import and the request context. The cache affects all of them, not just rule import.

### Flow trace (rule import, overwrite)

1. `import_rules/route.ts` calls `ctx.securitySolution.getEndpointAuthz()`. That goes through `request_context_factory.ts` to `endpointAppContextService.getEndpointAuthz(request)`. **Cache miss**, which means one ES `_has_privileges` call.
2. The route goes on to the Alerting `bulkCreateRules` / `bulkUpdateRules`. The rules client was built by `getRulesClientWithRequest(request)` with the **same `KibanaRequest` instance**, because core's `ContextContainer.createHandler` passes the same request object to the context providers and the handler.
3. For each rule, `prepareRule` / `prepareUpdate` calls `authorizeRuleTypeParams`, which calls `createSecurityRuleParamsAuthorizer().authorize`.
4. Inside `authorizeResponseActions`:
   - If the rule has no response actions on either side, it returns early. No authz lookup at all.
   - Otherwise it calls `getEndpointAuthz(request)` and gets a **cache hit** (the promise primed in step 1), then runs `validateRuleResponseActions` as before.
5. `authorizeReadAuthParamFields` runs as before. It has its own early return.

Net result: the import path makes at most one `_has_privileges` call per HTTP request, whether or not the rules have response actions.

### Assumptions

- **The early return matches the validator's.** `validateRuleResponseActions` already returns when both `response_actions` and `existingRule.params.responseActions` are null or empty. The new check is the same condition, just moved before the `await getEndpointAuthz`. Verified in `rule_response_actions_validators.ts` (lines 193–199).
- **One `KibanaRequest` means one user with fixed privileges.** The cache has no TTL and is only cleared when the request object is garbage-collected. That holds for normal HTTP requests. I checked the riskiest long-lived case, Agent Builder's human-in-the-loop (HITL) confirmation. `run_tool.ts` returns the confirmation prompt and the round ends, so the confirmed action runs on a new request and gets a fresh authz check.
- **Nobody mutates the returned `EndpointAuthz`.** Callers now share one object per request. A grep for assignments found only the test mock (`mocks.ts` `Object.assign`), which works on its own object.
- **Rejections aren't sticky.** The `.catch` deletes the key. Nothing else can set a new promise under that key in the meantime, because `get` keeps returning the pending one until it settles. `EndpointAppContentServicesNotStartedError` is thrown inside an async function, so it also becomes a rejection and isn't cached.

### Risks

1. **Temporary debug probes are still in your working tree.** Both files have uncommitted `console.log('[authzProbe] …')` lines. `authorize_rule_response_actions.ts` also has `require('fs').appendFileSync('/tmp/authz-probe.log', …)`. They're not in the PR, but one `git commit -a` would put them there.
2. **The cache's blast radius is the whole Endpoint service, not just rule import.** Every `getEndpointAuthz` caller now shares a per-request result. I think that's fine (see Assumptions), but it's code owned by Defend Workflows, so they should explicitly agree.
3. **The latest commit hasn't had a full Buildkite run.** The "Build succeeded, but was flaky" bot comment is for `67f870e`. HEAD is `af83dfc`. The PR is still a draft.
4. **The PR description over-credits the early return for the import path.** Because the route already primes the cache (flow trace step 1), the cache alone would cut import to one `_has_privileges` call. The early return mostly helps paths with no route-level pre-call, like the generic Alerting rule APIs. Not a code bug, but it changes how the manual-test expectations read.

### Open questions

- **The manual-test breakpoints won't show ES calls.** The breakpoint sits on the first line of the public `getEndpointAuthz`, so it hits on cache hits too. To show actual privilege lookups, put it (or the probe) in `resolveEndpointAuthz`.
- **The manual-test steps don't match the test run.** Steps are numbered 1, 2, 3, 4, 4, 6 (two 4s, no 5). Step 10's "19 hits" assumes one rule gets skipped as unchanged, which matched your main run. Steps 12 and 13 were ambiguous in that run (see `.knowledge/test-runs/2026-11-12T1756…/SUMMARY.md`).
- **Concurrent sharing isn't tested.** The cache tests `await` the calls one after another. A `Promise.all([get(req), get(req)])` test with `fromRequest` called once would pin down the in-flight sharing the issue called out for `pMap`.
- **Should the cache live in the service or the authorizer?** The issue suggested the service, and it does help the other callers. Worth a quick yes from Defend Workflows.
- **Minor:** the comment in `getEndpointAuthz` is two lines, and "delete on rejection" just repeats what the code does. Your own style rule would cut it to one line.

### Notes for your codebase map

- Request handler context providers and the route handler get the **same `KibanaRequest` instance** (`ContextContainer.createHandler`). That makes a `WeakMap<KibanaRequest, …>` a reliable per-request cache across the route and the rules client.
- `request_context_factory.ts` already memoized `getEndpointAuthz` per context. The service-level cache now does the same thing for code that calls the service directly, like the Alerting authorizer.
- Alerting's `authorizeRuleTypeParams` runs on create, update, bulk create, bulk update, bulk edit, enable and bulk enable. Any cost in the Security authorizer is multiplied by the number of rules on all of those paths.
- Agent Builder HITL confirmations end the round and resume on a new request, so per-request caches don't carry authz across a confirmation.

### Follow-up Review Activities

1. **WeakMap false-hit risk** — Checked whether `authzCache = WeakMap<KibanaRequest, Promise<EndpointAuthz>>` can return another user's privileges.
   - WeakMap keys by object identity (`===`), not by user id / headers / path.
   - Router creates one `CoreKibanaRequest` per Hapi request (`route.ts` → `CoreKibanaRequest.from`) and passes that same instance into context + handler (`ContextContainer.createHandler`).
   - `CoreKibanaRequest.from` always `new`s — no pooling or reuse across HTTP requests.
   - Different wrappers for the same raw request would be **cache misses** (extra ES calls), not false hits.
   - Auth is fixed for the lifetime of that request object; Agent Builder HITL resumes on a new request.
   - Same pattern already used by osquery (`check_response_action_authz.ts`).
   - Verdict: false hits would need a reused/mutated `KibanaRequest` for a different user, which core doesn't do. Residual risk is theoretical mid-request auth mutation on the same object — not something Kibana does today.
