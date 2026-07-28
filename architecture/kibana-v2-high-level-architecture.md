# Alerting v2 — High-Level Architecture and Testing

Scan date: 2026-07-27
Kibana repo path: /Users/sdesalas/Code/sdesalas/kibana-4th (branch `alerting-v2-rule-versioning`, near upstream/main)
Primary source: `x-pack/platform/plugins/shared/alerting_v2/` — the plugin's own READMEs (`README.md`, `server/README.md`) are maintained and current; trust them over older notes.

## Identity

- Path: `x-pack/platform/plugins/shared/alerting_v2`
- Plugin id `alertingVTwo`, module `@kbn/alerting-v2-plugin`, owner `@elastic/rna-project-team`
- Platform group, shared visibility, config under `xpack.alerting_v2` (enabled by default)
- The ground-up "RNA" rewrite of alerting: **ES|QL-first and append-only**, in contrast to v1 alerting's rule-type-registry + mutable alert documents model.

## The mental model

**Rule definitions are still stored as Saved Objects** (`alerting_rule` SO type in `.kibana_alerting_cases` - instead of `alert` for V1).

Everything else revolves around two append-only data streams: `.rule-events` (what rule execution produced) and `.alert-actions` (what users and the dispatcher did about it). Nothing in those streams is updated in place — state is derived by reading history.

The server is organized as five cooperating planes:

| Plane | Owns | Code |
|---|---|---|
| Control | APIs, saved objects, privileges, UI, startup wiring | `public/`, `server/routes/`, `server/saved_objects/`, `server/setup/` |
| Evaluation | Running rules, turning ES\|QL results into rule events | `server/lib/rule_executor/` |
| Lifecycle | Turning alert events into episode state transitions | `server/lib/director/` |
| Delivery | Matching, grouping, throttling, delivering notifications | `server/lib/dispatcher/` |
| Persistence | Data streams, mappings, ES\|QL views | `server/resources/` |

## Core domain concepts

- **Rule** — a saved object (`alerting_rule`) defining an ES|QL query, a schedule, grouping fields, and a kind: `signal` (stateless, fire-and-forget events) or `alert` (stateful, gets lifecycle tracking). Managed via `lib/rules_client/` with optimistic concurrency on the SO version token.
- **Rule event** — immutable output document per evaluated row/outcome, written to `.rule-events` with `type`, `status` (`breached`/`recovered`/`no_data`), `group_hash`, the flattened row `data`, and `rule.version`.
- **Series** — the per-rule stream of events sharing a `group_hash`; the stable identity used to detect recoveries and correlate state over time.
- **Episode** — the lifecycle container for an alert series (one breach-to-recovery cycle), with statuses `inactive → pending → active → recovering`. Assigned by the director; a series can have many episodes over time.
- **Notification policy** — a separate saved object (`alerting_action_policy`), *not* embedded in the rule. KQL matcher + grouping + throttling + destinations; one policy can match episodes from many rules in a space.
- **Alert action** — append-only doc in `.alert-actions`: user actions (ack, snooze) and dispatcher outcomes (fired, suppressed, throttled, notified). This is the dispatcher's durable memory.

## Action policies & notification delivery

Naming: the SO type and API/UI call it **action policy** (`alerting_action_policy`); some docs say "notification policy". Same thing.

An action policy is the **notification/routing config, decoupled from the rule** — unlike v1 alerting, where actions are wired onto the rule. One policy can match episodes from many rules in a space. Evaluated by the dispatcher, not the rule executor. Schema: `saved_objects/schemas/action_policy_saved_object_attributes/v1.ts`.

| Field | Role |
|---|---|
| `matcher` | KQL selecting which alert episodes this policy applies to (null = broad match) |
| `destinations` | Where to send — **`{ type: 'workflow', id }` only** (1–20) |
| `groupingMode` + `groupBy` | Bundle matched alerts into one notification: `per_episode` / `all` / `per_field` |
| `throttle` | Rate-limit: `on_status_change` / `per_status_interval` / `time_interval` / `every_time` + `interval` |
| `snoozedUntil` | Mute until a timestamp |
| `auth` | `{ apiKey, owner, createdByUser }` — credentials the dispatcher delivers under (SO is ESO-encrypted) |

### Delivery model — connectors are indirect

**A policy cannot dispatch to an email/Jira/connector directly.** The only destination type is `workflow`; the dispatcher explicitly skips anything else (`dispatch_step.ts:85`, `if (destination.type !== 'workflow') continue`). On a match it triggers a workflow execution under the policy's API key (`dispatch_step.ts:90`).

```
alert episode → action policy (match + group + throttle) → workflow → connector step (email / Jira / Slack / …)
```

Email, Jira, etc. happen **inside the triggered workflow**, via the workflows system's own connectors (`workflowsManagement` / `workflowsExtensions`). alerting_v2 deliberately stays out of the connector business and delegates all delivery to workflows. To make a v2 alert send an email or open a ticket: build a workflow that does it, then point the policy's `destinations[].id` at that workflow.

## Execution flow

1. Each enabled rule gets its own Task Manager task; the task runner feeds the rule executor pipeline (`lib/rule_executor/`), a streaming step pipeline: execute the ES|QL query → detect data presence → create alert events → create recovery events → create no-data events → `DirectorStep` (alert rules only) → persist the batch to `.rule-events`.
2. The **director** (`lib/director/`) enriches alert events with `episode.*` fields by reading the last known state per `group_hash` and applying a transition strategy. It never dispatches anything.
3. The **dispatcher** (`lib/dispatcher/`) runs on its own fixed-interval task, decoupled from rule execution: reads candidate episodes from `.rule-events`, reads suppression/throttle history from `.alert-actions`, evaluates policies, dispatches eligible groups, and writes outcomes back to `.alert-actions`.

## Wiring and cross-cutting pieces

- **Inversify DI throughout** — all wiring lives in `server/setup/bind_*.ts` (services, routes, tasks, executor/dispatcher steps in execution order, events). Tokens are `Symbol.for(...)`-based `ServiceIdentifier`s.
- **Domain event bus** (`lib/events/`) — a fire-and-forget in-process bus (`setImmediate` dispatch, error-isolated handlers). The `RulesClient` publishes rule-lifecycle events (`rule.created/updated/enabled/disabled/deleted`); subscribers project them to **workflow triggers** (via `workflowsExtensions`) and — as of PR #276947 (in review at scan date) — to the **rule change history** subscriber writing snapshots to `.kibana_change_history` via `@kbn/change-history`, ordered by the `metadata.version` counter.
- **Resources** (`server/resources/`) — data stream definitions (`.rule-events`, `.alert-actions`) and ES|QL views, provisioned at start via a `ResourceManager` that supports optional resources; there's a `reset_resources` dev route.
- **Routes** (`server/routes/`) — `rules`, `action_policies`, `alert_actions`, `execution_history`, `suggestions`, built on a shared `base_alerting_route` with typed error codes.
- **Saved objects** — `alerting_rule`, `alerting_action_policy`, `alerting_api_key_pending_invalidation` (API keys are invalidated by a background task in `lib/tasks/`; encrypted via ESO).
- **Config guardrails** — `rules.minimumScheduleInterval` (default 1m, floor tied to the schema minimum so FTR can relax it), `rules.run.alerts.max` (default/cap 10k per run), plus a cluster-wide runs-per-minute cap.
- **Public side** — management UI (rule list/details/create flyout, episodes, policies), with the rule form and schemas living in shared packages: `@kbn/alerting-v2-rule-form` and `@kbn/alerting-v2-schemas` (the zod source of truth for API contracts). There's also `agent_builder` integration on both sides for AI-assisted flows.

## Ownership boundaries (from the plugin docs)

- The rule executor owns event materialization, recovery/no-data semantics, and persistence to `.rule-events`.
- The director owns episode state, transition strategies, and episode ids — never notifications.
- The dispatcher owns matching/grouping/throttling/delivery and the `.alert-actions` log — never re-running queries or inferring recoveries.
- The resources layer owns datastream definitions, mappings, ES|QL views, and versioned schema evolution.

## Contribution rules of thumb

Change the smallest owning subsystem; don't make the dispatcher understand execution internals (belongs in the executor) or the director send notifications (belongs in the dispatcher). New stored fields mean updating `resources/` definitions plus all readers/writers. Each subsystem has its own detailed README (`rule_executor`, `director`, `dispatcher`, `resources`).

## API endpoints

Everything under `/api/alerting/v2/...`; path constants in `@kbn/alerting-v2-constants` (`index.ts`).

**Rules** (`/api/alerting/v2/rules`)

| Method | Path | Purpose |
|---|---|---|
| POST | `/rules` | Create a rule |
| GET | `/rules` | List / find rules |
| GET | `/rules/{id}` | Get one rule |
| PATCH | `/rules/{id}` | Partial update (bumps `metadata.version`) |
| PUT | `/rules/{id}` | Upsert (create-or-replace by id) |
| DELETE | `/rules/{id}` | Delete a rule |
| GET | `/rules/_tags` | Distinct rule tags |
| POST | `/rules/_bulk_get` | Bulk get by ids |
| POST | `/rules/_bulk_delete` | Bulk delete by ids |
| POST | `/rules/_bulk_enable` | Bulk enable by ids |
| POST | `/rules/_bulk_disable` | Bulk disable by ids |
| POST | `/rules/_delete_by_query` | Delete matching a query |
| POST | `/rules/_enable_by_query` | Enable matching a query |
| POST | `/rules/_disable_by_query` | Disable matching a query |

**Action policies** (`/api/alerting/v2/action_policies`)

| Method | Path | Purpose |
|---|---|---|
| POST | `/action_policies` | Create a policy |
| GET | `/action_policies` | List policies |
| GET | `/action_policies/{id}` | Get one policy |
| PATCH | `/action_policies/{id}` | Partial update |
| PUT | `/action_policies/{id}` | Replace |
| DELETE | `/action_policies/{id}` | Delete |
| POST | `/action_policies/_bulk` | Bulk create |
| POST | `/action_policies/{id}/_enable` | Enable |
| POST | `/action_policies/{id}/_disable` | Disable |
| POST | `/action_policies/{id}/_snooze` | Snooze |
| POST | `/action_policies/{id}/_unsnooze` | Un-snooze |
| POST | `/action_policies/{id}/_update_api_key` | Rotate the policy API key |
| POST | `/action_policies/_match_for_rule` | Preview which policies match a rule |
| GET | `/action_policies/suggestions/tags` | Tag suggestions |
| GET | `/action_policies/suggestions/data_fields` | Data-field suggestions |
| GET | `/action_policies/execution_history` | Dispatch execution history |
| GET | `/action_policies/execution_history/_count_since` | Count of dispatches since a point |

**Alert actions** (`/api/alerting/v2/alerts`) — user actions on an alert episode by `group_hash`

| Method | Path | Purpose |
|---|---|---|
| POST | `/alerts/_bulk_action` | Apply an action to many alerts |
| POST | `/alerts/{group_hash}/_ack` · `_unack` | Acknowledge / un-acknowledge |
| POST | `/alerts/{group_hash}/_activate` · `_deactivate` | Activate / deactivate |
| POST | `/alerts/{group_hash}/_snooze` · `_unsnooze` | Snooze / un-snooze |
| POST | `/alerts/{group_hash}/_assign` | Assign |
| POST | `/alerts/{group_hash}/_tag` | Tag |

**Execution history & suggestions**

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/alerting/v2/execution_history/rules` | Rule execution history |
| POST | `/internal/action_policies/suggestions/values` | Matcher value suggestions (internal) |
| POST | `/internal/alerting/v2/user_profiles/_suggest` | User-profile suggestions (internal) |

## Manual testing

There is no dedicated manual-testing doc in the plugin; assembled from settings/config/routes.

### 1. Enable it — the whole thing is behind an Advanced Setting

The plugin loads by default (`xpack.alerting_v2.enabled: true` at config level), but the APIs and UI are gated behind an **experimental Advanced Setting defaulting to `false`**: `alerting:v2:enabled` (`server/settings/advanced_settings.ts:31`, id constant in `@kbn/alerting-v2-constants`).

- UI: Stack Management → Advanced Settings → search "Alerting V2" → toggle on → reload the page (`requiresPageReload`)
- API: `POST kbn:/internal/kibana/settings/alerting:v2:enabled {"value": true}`
- yml: `uiSettings.globalOverrides."alerting:v2:enabled": true` (global-scope setting; overriding pins it in the UI)

### 2. Make rules run fast enough to watch

Default minimum schedule is 1m, but the config floor is deliberately relaxed (same lever the functional tests use — `server/config.ts`, floor tied to `MIN_SCHEDULE_INTERVAL` from `@kbn/alerting-v2-schemas`). In `config/kibana.dev.yml`:

```yaml
xpack.alerting_v2.rules.minimumScheduleInterval: '5s'
```

Then a rule with `schedule.every: 5s` gives a feedback loop of seconds.

### 3. Drive it

- **UI:** after enabling, an **Alerting V2 section appears in Stack Management** with four apps: Rules, Action Policies, Episodes, Execution History (`common/management_apps.ts`).
- **API:** see the [API endpoints](#api-endpoints) section (e.g. `PATCH /api/alerting/v2/rules/{id}` for a partial rule update).

### 4. Where things are stored

| What | Index / stream | Notes |
|---|---|---|
| Rule definition | `.kibana_alerting_cases` (SO type `alerting_rule`) | `server/saved_objects/index.ts:46`; shared with `alerting_action_policy` + `alerting_api_key_pending_invalidation` |
| Rule run output | `.rule-events` | breached/recovered/no_data events; `episode.*` for alert rules |
| Dispatcher + user actions | `.alert-actions` | match/throttle/notify outcomes, ack/snooze |
| Change history | `.kibana_change_history` | rule snapshots, ordered by `object.sequence` (PR #276947) |
| Executor task | `.kibana_task_manager` | one per enabled rule; task id = rule id + space |

```bash
# adjust ES port to your local setup (default 9200)
curl -sk -u elastic:changeme -H 'x-elastic-product-origin: kibana' \
  -H 'Content-Type: application/json' \
  'http://localhost:9200/.kibana_alerting_cases/_search' \
  -d '{"query": {"term": {"type": "alerting_rule"}}}'
```

Example dev hit (confirmed live 2026-07-27 — note `metadata.version: 3` and `typeMigrationVersion: "10.3.0"`, the model version 3 from PR #276947):

```json
{
  "_index": ".kibana_alerting_cases_9.6.0_001",
  "_id": "alerting_rule:7e510d96-9986-455f-8db0-72438235ba6b",
  "_source": {
    "alerting_rule": {
      "kind": "alert",
      "metadata": {
        "name": "Test Rule — High Error Span Count",
        "description": "A test rule that fires when the number of error-status spans exceeds 5 in the last 5 minutes, grouped by service.",
        "tags": ["test", "errors", "otel", "agent-builder-assisted"],
        "version": 3
      },
      "time_field": "@timestamp",
      "schedule": { "every": "1m", "lookback": "5m" },
      "query": {
        "format": "composed",
        "base": "FROM traces-agent_builder.otel-default | WHERE status.code == \"ERROR\" | STATS error_count = COUNT(*) BY service.name",
        "breach": { "segment": "WHERE error_count > 5" },
        "recovery": { "segment": "WHERE error_count <= 5" }
      },
      "recovery_strategy": "query",
      "state_transition": { "pending_count": 2, "recovering_count": 2 },
      "grouping": { "fields": ["service.name"] },
      "enabled": true,
      "createdBy": "u_mGBROF_q5bmFCATbLXAcCwKa0k8JvONAwSruelyKA5E_0",
      "createdAt": "2026-07-27T09:14:33.880Z",
      "updatedBy": "u_mGBROF_q5bmFCATbLXAcCwKa0k8JvONAwSruelyKA5E_0",
      "updatedAt": "2026-07-27T09:16:41.153Z"
    },
    "type": "alerting_rule",
    "references": [],
    "managed": false,
    "namespaces": ["default"],
    "coreMigrationVersion": "8.8.0",
    "typeMigrationVersion": "10.3.0"
  }
}
```

### 5. Dev conveniences

- `server/routes/reset_resources_route.ts` — endpoint to blow away and re-provision the data streams/views when local state is mangled
- Scout suites under `test/scout_alerting_v2/{api,ui}` double as living documentation of request/response shapes for cribbing manual curls

Gap worth a docs PR: the plugin READMEs are thorough but have no "manual testing / local dev" section.

## Related

- WIP PR — rule versioning via change history: https://github.com/elastic/kibana/pull/276947