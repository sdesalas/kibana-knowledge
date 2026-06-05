# Phase A2 review

**Subject:** Phase A2 (`preValidate.ensureAuthorized`) in
`x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_create/bulk_create_rules.ts`,
lines ~215–243.

**Question:** should we replace the per-pair loop with one
`bulkEnsureAuthorized` call?

## Reasons to use `bulkEnsureAuthorized`

- One ES privileges call instead of one per `(ruleTypeId, consumer)` pair.
  A 1000-rule prebuilt install hits ~8 Security Solution rule types, all under
  the `siem` consumer, so we'd save ~9 calls — ~50 ms in ECH.
- A bit less code: the loop becomes one call with one APM span.
- Lines up with how the rest of the alerting bulk methods do auth.

## Reasons to keep `ensureAuthorized` in a loop

### 1. `bulkEnsureAuthorized` doesn't return enough info

When `bulkEnsureAuthorized` fails it throws a single forbidden error with
every pair joined into one message — there's no way to tell which pair
caused the failure. That's by design: it was built as a defence-in-depth
backstop, not as a primary authz check.

Every other caller is fine with that because they pre-filter the input
first. Bulk edit / disable / enable / delete, backfill, untrack, mute,
gaps all do the same thing:

1. Take the caller's KQL filter.
2. AND it with `getAuthorizationFilter` so the find only returns rules the
   user is allowed to see.
3. Aggregate the `(alertTypeId, consumer)` pairs from that filtered result.
4. Hand those pairs to `bulkEnsureAuthorized`.

By step 4, user-level authz has already happened in the filter. The bulk
call only fires for super-user paths that skip RBAC (see the comment at
`_ensureAuthorized:296–304`), and a coarse failure is fine there — if it
trips, something is genuinely wrong.

`bulkCreate` has none of that pre-filtering. The caller posts pairs
straight in the request body, and Phase A2 is the only authz step. We
need to know *which* pair failed so we can write a per-rule audit event
and a per-rule entry in `errors[]`. `bulkEnsureAuthorized` can't tell us.
The right fit would be a new non-throwing `bulkCheckAuthorized` that
returns the per-pair result — not this one.

### 2. Partial-failures handled better with single `ensureAuthorized`

If a request mixes one disallowed pair, the per-pair loop handles it
cleanly: the unauthorised rules land in `errors[]` and the rest go through.
`bulkEnsureAuthorized` would fail the whole batch instead.

Nothing in the type system or route layer prevents a mixed request — a
misconfigured caller or an unusual feature-privilege combination can
produce one. In practice Kibana's feature-privilege model funnels real
callers (prebuilt install, security import, gap fill) through a single
consumer, so it basically never happens. Worth flagging as a behavioural
difference, but not something to design around on its own — #1 makes the
call either way.

### 3. The perf win is small relative to everything else in the request

That ~50 ms sits next to in-memory validation, `bulkSchedule`, `bulkCreate`,
`bulkEnable`, and API key minting — easily the smallest term in the budget.

### 4. We'd lose per-rule audit detail

`_ensureAuthorized` only looks at `hasAllRequested` and throws a single
forbidden error with all pairs joined together. Today we emit one
`CREATE { savedObject, error }` audit event per rejected rule. After the
swap that becomes one batch-level entry with no rule attribution.
