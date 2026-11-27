# Auth parity: PR #304858 on baseline, 9.5 and 8.19

**Date:** 2026-11-27 · **Script:** `run_parity.py` · **Raw results:** `results.json`

## Question

PR [#304858](https://github.com/elastic/kibana/pull/304858) changed how the Alerting params authorizer resolves Endpoint authz (early return when no response actions, opt-in request-scoped cache). Backports: [#307903](https://github.com/elastic/kibana/pull/307903) (9.5), [#307975](https://github.com/elastic/kibana/pull/307975) (8.19).

Does the outward-facing authorization behavior stay the same on the backports as on the merged PR?

## Result

**Yes. All 20 cases return identical status codes on all three servers, and the error messages and counts match too.** No case differs.

## Setup

| Target | Checkout / branch | HEAD | Kibana | ES |
|---|---|---|---|---|
| baseline (merged PR) | `kibana-6th` / `skip-endpoint-authz-empty-response-actions` (main merged in) | `f7ca8fb` | `:5606/kbn` | `:9205` |
| 9.5 backport | `kibana-9.5` / `backport/9.5/pr-304858` | `bb2b996` | `:5608/kbn` | `:9207` |
| 8.19 backport | `kibana-8.19` / `backport/8.19/pr-304858` | `d140230` | `:5610/kbn` | `:9209` |

- All ES nodes on a trial license, local dev credentials for admin calls.
- Two users per server, created fresh and deleted afterwards (along with every rule on the server):
  - `parity_priv`: `minimal_all` on the Security feature plus every `_all` sub-feature (host isolation, process, file, execute, scan operations, etc.).
  - `parity_unpriv`: `minimal_all` on the Security feature only, so no response-action privileges.
- Both roles get `all` on every other non-deprecated feature, plus cluster `all` and index `*` `all`. This mirrors the setup in the PR's own manual testing.
- Security feature ID is `siemV5` on 9.x and `siemV2` on 8.19.
- Rules were sent over both the Detection Engine routes and the generic `POST /api/alerting/rule` route, which bypasses the DE routes and goes straight to the Alerting authorizer.
- The response action used is `.endpoint` `isolate`.

## Cases

Same on baseline, 9.5 and 8.19.

| Case | Status | Detail |
|---|---:|---|
| `de.create.no_actions.unpriv` | 200 | |
| `de.create.isolate.unpriv` | **403** | User is not authorized to create/update isolate response action |
| `de.create.isolate.priv` | 200 | |
| `de.patch.remove_actions.unpriv` | **403** | rule had actions, unprivileged user tries to remove them |
| `de.patch.actions_unchanged.unpriv` | **403** | rename only, rule keeps its actions (DE route still validates) |
| `de.patch.add_actions.unpriv` | **403** | |
| `de.patch.no_actions.unpriv` | 200 | |
| `alerting.create.isolate.unpriv` | **403** | same message, via the generic Alerting route |
| `alerting.create.isolate.priv` | 200 | |
| `alerting.create.no_actions.unpriv` | 200 | |
| `alerting.update.remove_actions.unpriv` | **403** | previous params had actions, so still checked |
| `alerting.update.actions_unchanged.unpriv` | 200 | unchanged actions are not re-authorized |
| `alerting.update.remove_actions.priv` | 200 | |
| `bulk.enable.with_actions.unpriv` | 500 | `succeeded=0 failed=1` |
| `bulk.enable.no_actions.unpriv` | 200 | `succeeded=1 failed=0` |
| `import.isolate.unpriv` | 200 | `success=false`, per-rule error status 403 |
| `import.no_actions.unpriv` | 200 | `success=true` |
| `import.isolate.priv` | 200 | `success=true` |
| `endpoint.action_list.unpriv` | **403** | Endpoint authorization failure (regression check on an endpoint route) |
| `endpoint.action_list.priv` | 404 | `index_not_found_exception` |

## Reading the results

- **The authorizer still enforces.** An unprivileged user cannot create, add, or remove response actions through either route family. Removal is blocked because the previous params had actions, so the "either side has actions" early return does not let it through.
- **No-action rules skip the check.** Unprivileged writes of rules with no response actions succeed on every route, as intended.
- **Unchanged actions via the Alerting route pass.** The generic update with actions unchanged returns 200 for the unprivileged user. The DE route's `PATCH` with a rename returns 403, because the DE route runs its own validation. Both behave the same on all three servers.
- **Bulk enable of a rule with actions returns 500, not 403.** `failed=1` shows the rule was blocked. The 500 is the bulk action route's response to a failed item. It is identical on the baseline, so it is existing behavior and not something the backports introduced.
- **Import returns 200 overall.** The rejection shows up as a per-rule 403 error.
- **Endpoint routes are unaffected.** The unprivileged user gets 403. The privileged user gets 404 on all three: authorization passed, but there are no endpoint action indices on these local clusters.

## Not covered

- The privileged user removing actions through the Detection Engine route (the Alerting route is covered).
- Spaces other than default, and users with custom Kibana privilege mixes beyond the two roles above.
- Privilege revocation mid-request or mid-batch, and any check that the per-request cache is actually shared across rules in one request. This run only looks at outward status codes.
- Serverless and ECH. Everything ran on local dev servers.
- Bulk edit and bulk disable. Only bulk enable was run.

## Setup mistakes worth remembering

The first two trial runs returned 403 for every case, including the privileged user, because of the test setup rather than the code:

- A role with only the Security feature cannot write rules. Every other feature needs `all` too.
- `all` on the Security feature does not grant the response-action sub-features. Use `minimal_all` plus each `_all` sub-feature ID.

The script now handles both.

## Re-run

```bash
cd test-runs/2026-11-27T1045.authz-parity
python3 run_parity.py            # all three
python3 run_parity.py 9.5 8.19   # a subset
```

Each run deletes every detection rule on the target server and removes the `parity_*` users and roles when it finishes. Ports and feature IDs are at the top of `run_parity.py`.
