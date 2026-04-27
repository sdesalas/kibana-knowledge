# Detection Rules Architecture in Kibana — Reviewed Summary

> Reviewed and consolidated from `.cursor/rules/detection-rules-architecture.mdc`,
> `.cursor/rules/detection-rules-architecture-diagrams.md`, and the Kibana
> codebase itself (`elastic/kibana`). All paths are repo-relative
> (root: `kibana/`).

This is a single, condensed reference for everything you need to understand
how Detection Rules work in the Kibana Security Solution: the plugin layering,
the Zod-based API schemas, the **rule management** screens and flows
(create/edit/bulk actions), the **rule response** structure, **rule exceptions**,
the **prebuilt rule** pipeline, and how rules and alerts are **persisted in
Elasticsearch**.

---

## Table of contents

- [Newcomer primer — terms and concepts you need first](#newcomer-primer--terms-and-concepts-you-need-first)
- [How to read this document](#how-to-read-this-document)

1. [The Three-Layer Stack](#1-the-three-layer-stack)
2. [Why each component exists (rationale)](#2-why-each-component-exists-rationale)
3. [Rule Types](#3-rule-types)
4. [Zod API Schemas](#4-zod-api-schemas-single-source-of-truth-for-the-shape-of-a-rule)
5. [Rule Response structure (`RuleResponse`)](#5-rule-response-structure-ruleresponse)
6. [Detection Rules Client](#6-detection-rules-client-idetectionrulesclient)
7. [Plugin Lifecycle](#7-plugin-lifecycle)
8. [Security Rule Type Wrapper](#8-the-security-rule-type-wrapper--what-it-adds-on-top-of-an-executor)
9. [Rule Management UI](#9-rule-management-ui--screens-and-flows)
10. [Bulk Actions](#10-bulk-actions)
11. [Rule Exceptions](#11-rule-exceptions)
12. [Prebuilt Detection Rules](#12-prebuilt-detection-rules)
13. [Alerts as Data](#13-alerts-as-data)
14. [Persistence in Elasticsearch (the full picture)](#14-persistence-in-elasticsearch-the-full-picture)
15. [Experimental Feature Flags](#15-experimental-feature-flags-security-solution-only)
16. [Request Flow (HTTP → ES)](#16-request-flow-http--es)
17. [Execution Flow (Task Manager → Alerts)](#17-execution-flow-task-manager--alerts)
18. [Key Files Index](#18-key-files-index)
19. [Cheat-sheet — "If I want to…"](#19-cheat-sheet--if-i-want-to)
20. [Summary](#20-summary)

---

## Newcomer primer — terms and concepts you need first

Detection rules touch a lot of Kibana's plumbing. Before the section-by-section
deep dive, here is the minimum vocabulary and mental model you need so the
rest of the document reads cleanly. Skim this once and refer back as needed.

### A. The two meanings of "alert" (this trips everyone up)

Kibana's platform was designed before "alerts" had its modern security
meaning. The result is that **the word "alert" means two completely different
things** depending on where you are in the codebase:

| Where | What "alert" means | Lives in |
|------|-------------------|----------|
| **Alerting framework** (`x-pack/platform/plugins/shared/alerting`) | A *scheduled rule* — a thing that runs on an interval and may emit notifications. The Saved Object type is literally called `'alert'` (`RULE_SAVED_OBJECT_TYPE = 'alert'`). | `.kibana_alerting_cases` |
| **Security domain** | A *security alert document* — a single suspicious thing the rule found, written to an alerts index. | `.alerts-security.alerts-<ns>` |

So when you see `RULE_SAVED_OBJECT_TYPE = 'alert'` (alerting plugin) but
`.alerts-security.alerts-...` (security indices), they are unrelated despite
both saying "alert". In this doc:
- **rule** = the configured detection rule (the `'alert'` Saved Object),
- **alert** (lowercase) = a security alert document found by the rule.

(Historically these were called *signals* — that's why the legacy index alias
is `.siem-signals-*`.)

### B. Saved Object (SO)

A **Saved Object** is Kibana's persistent JSON document stored in a
`.kibana*` Elasticsearch index, with:
- a `type` (e.g. `alert`, `security-rule`, `exception-list`, `task`),
- a stable `id`,
- attributes (the JSON body),
- references to other SOs,
- optional **encrypted attributes** (handled by Encrypted Saved Objects, ESO).

Detection-rule storage is built almost entirely on Saved Objects:
- the **runnable rule** is an `alert`-typed SO,
- the **prebuilt rule content** is a `security-rule`-typed SO,
- **rule exceptions** are `exception-list`/`exception-list-agnostic` SOs,
- the **task that schedules the rule** is a `task`-typed SO.

Saved Objects are also the unit of RBAC, sharing across spaces, import/export,
and migrations (model versions).

### C. Spaces, namespaces, and "agnostic" vs "isolated"

Kibana **spaces** are logical partitions of objects. Each SO type declares
how it interacts with spaces:
- `multiple-isolated` — a copy per space (e.g. detection rules; an exception
  list visible only in one space),
- `agnostic` — one global copy shared by every space (e.g. prebuilt rule
  assets; endpoint-wide exception lists).

Alerts indices are *space-aware*: the alias suffix is the space id
(`.alerts-security.alerts-default`).

### D. Task Manager

**Task Manager** is the platform service that runs scheduled work. Every
detection rule has a corresponding **task** SO with `taskType: 'alerting:siem.queryRule'`
(or similar). On its `schedule.interval` Task Manager picks the task up,
hands it to a **Task Runner**, which loads the rule, calls the wrapper +
executor, and persists the result. If you change a rule's interval, Task
Manager picks up the new schedule on the next poll.

### E. Encrypted Saved Objects (ESO) — and "AAD"

Some rule attributes (notably `apiKey`, `uiamApiKey`) are encrypted at rest.
**ESO** uses other rule attributes as **AAD — Additional Authenticated Data**
(an encryption term, *not* "alerts as data"). AAD prevents an attacker from
copying an encrypted blob from one rule onto another, because the surrounding
attributes are bound into the ciphertext. This is why partial updates of
AAD-included fields are restricted at the framework level.

> Two different "AAD"s appear in this doc:
> - **A**dditional **A**uthenticated **D**ata (encryption — this paragraph),
> - **A**lerts **a**s **D**ata (the alerts-indexing pattern — see §13).
> Context disambiguates them.

### F. API key and "running as the user"

When a rule runs, the executor must read the user's source indices. To do
this the alerting framework stores an **API key** generated for the rule
creator (or the last editor) and uses it to scope every ES request. This is
why detection rules respect index-level RBAC: the API key carries the user's
privileges. Lose those privileges → the rule is recorded as a **partial
failure** at run time.

### G. Fleet packages and "prebuilt rule content"

**Fleet** is Kibana's integrations & content delivery system. Elastic ships
a content package called `security_detection_engine` that contains an
inventory of detection rules, including their MITRE coverage, related
integrations, and metadata. When the user installs the package, the rule
content lands in Elasticsearch as `security-rule` Saved Objects. **None of
those rules are running yet** — they're just *available content*. The user
later "installs" specific rules, which creates the actual `alert` SOs that
Task Manager picks up.

This is why you'll see the term **prebuilt rule asset** for the content
(`security-rule`), distinct from the **rule instance** (`alert`).

### H. ECS

**Elastic Common Schema** — a shared field-naming convention
(`event.category`, `host.name`, `user.name`, …). Security alerts are written
to `.alerts-security.alerts-<ns>` using ECS-aligned fields plus a
`kibana.alert.*` envelope (rule metadata, alert state, suppression info).
This shared schema is what allows Cases, the Alerts table, the AI Assistant
and external SIEMs to consume security alerts uniformly.

### I. Query languages used by detection rules

Kibana has many query languages and detection rules use most of them. A quick
map:

| Lang | Purpose | Used by rule type |
|------|---------|-------------------|
| **KQL** (Kibana Query Language) | Friendly text query — the most common UI input | `query`, `saved_query`, `threshold`, `threat_match`, `new_terms` |
| **Lucene** | Lower-level alternative to KQL | same as above (`language: 'lucene'`) |
| **EQL** (Event Query Language) | Sequence/correlation queries (Endgame heritage) | `eql` |
| **ES\|QL** | Tabular pipe-style language | `esql` |
| **Elasticsearch DSL (JSON)** | The actual ES query format — every rule converts to this internally | all (composed in `get_filter.ts` / `get_query_filter.ts`) |
| **MITRE/Threat-mapping** | Domain-specific JSON | `threat`, `threat_mapping` fields |

### J. Two important identity fields: `id` vs `rule_id`

| Field | Set by | Purpose |
|-------|--------|---------|
| `id` | Saved Objects (UUID) | The Kibana primary key for this specific rule SO |
| `rule_id` | The rule author (or the asset) | The **stable business identity** that survives import/export and links a custom or prebuilt rule across spaces, packages, and versions |

Prebuilt rules use `(rule_id, version)` as the asset key. Three-way diff and
revert work on `rule_id`. Most APIs accept either `id` or `rule_id` for
lookups (`getRuleByIdOrRuleId`).

### K. `revision` vs `version`

| Field | Bumped when | Used for |
|-------|-------------|----------|
| `revision` | Any user write to the rule | Cache invalidation, audit, "did anything change?" |
| `version` | New prebuilt rule release ships from `elastic/detection-rules` | Selecting "upgrade target" for prebuilt rules |

### L. "Discriminated union" (Zod / TypeScript term)

A `discriminatedUnion` is a TypeScript/Zod construct where one literal field
("the discriminator") tells you which sub-shape applies. In this codebase the
discriminator is `type`:

```ts
// rough shape
RuleResponse =
  | { type: 'eql';  query: string; language: 'eql';  …EqlFields  }
  | { type: 'esql'; query: string; language: 'esql'; …EsqlFields }
  | { type: 'threshold'; threshold: { … }; …ThresholdFields }
  | …
```

Once you check `rule.type === 'threshold'`, TypeScript narrows the rule to
the threshold-only fields. Eight rule types ⇒ eight branches.

### M. Three-way diff (prebuilt rule upgrades)

Compares three versions of a rule:
- **base** — what was originally installed,
- **current** — what's installed now (possibly user-customised),
- **target** — the new version we want to upgrade to.

This is what allows the upgrade flow to *preserve* user customisations
when the upgrade doesn't conflict with them. See §11.6.

### N. Backfill and "gap"

A **gap** is a time interval the rule should have run for but didn't (Kibana
restart, Task Manager backlog, paused rule, etc.). Gaps are detected at
execution time and can be persisted to the Event Log
(`storeGapsInEventLogEnabled`). A **backfill** is an *ad-hoc* run for a chosen
historical range — implemented as an `ad_hoc_run_params` Saved Object plus a
Task Manager task. The bulk action `fill_gaps` schedules backfills for
detected gaps.

### O. The Event Log

A separate Elasticsearch data stream `.kibana-event-log-*` that stores one
document per rule execution: outcome, duration, search metrics, gap range,
warnings. The `execution_summary` field on a `RuleResponse` is **not** stored
on the rule SO — it is computed on read by aggregating these events.

### P. Alerts as Data (AAD — the indexing pattern)

A platform-wide convention: every Kibana solution writes its alerts to
`.alerts-<context>.alerts-<namespace>` indices using a shared "envelope"
namespace (`kibana.alert.*`). For Security, `<context>` is `security`. The
secondary alias `.siem-signals-<ns>` is kept for backwards compatibility
with old consumers.

### Q. RBAC primitive: `consumer`

The alerting framework attaches a **`consumer`** string to every rule
(detection rules use `consumer: 'siem'`). RBAC privileges in Kibana are
granted "for consumer X" — so a user can have access to *Observability rules*
without having access to *Security rules* even though both share the same
underlying SO type. When you see `consumer: 'siem'` in a fixture/mock, that
is what marks a rule as belonging to the Security app.

---

## How to read this document

- The codebase mixes **camelCase (internal/runtime)** and **snake_case
  (HTTP API / Zod schemas)**. The Detection Rules Client converts between
  them. If you see both `alertTypeId` *and* `type`, both `apiKey` *and*
  `api_key`, both `exceptionsList` *and* `exceptions_list` — they're the
  same field viewed from different sides.
- Every `*.gen.ts` is **auto-generated**. To change a Zod schema, edit the
  sibling `*.schema.yaml` and re-run the OpenAPI generator. Do not hand-edit
  `*.gen.ts`.
- File paths shown without the `kibana/` prefix are repo-relative.
- "**`siem.*` rule types**" refers to the alerting-framework rule type IDs
  (e.g. `siem.queryRule`). The HTTP API uses friendlier `type` literals
  (e.g. `query`). The mapping lives in
  `src/platform/packages/shared/kbn-securitysolution-rules/src/rule_type_mappings.ts`.
- When a section has a "**In plain terms**" callout, it's a short summary of
  the section in everyday language — useful when you want the gist before
  reading the dense parts.
- Diagrams use ASCII art so they render in any Markdown viewer (and in
  terminals). Boxes are components, arrows are runtime/data flow.

---

## 1. The Three-Layer Stack

> **In plain terms:** A detection rule is a Russian-doll of three concentric
> wrappers. The outer shell (Security Solution) knows what a "security rule"
> means, the middle shell (Rule Registry) knows how to bulk-write alerts to a
> custom index, and the inner core (Alerting framework) knows how to
> *schedule things* and persist them as Saved Objects. The same inner core
> powers Observability and Stack alerts; only the outer shell is
> security-specific.

Detection Rules in Kibana ride on top of two generic platform plugins.
From bottom to top:

| Layer | Plugin | Path | Responsibility |
|------|--------|------|----------------|
| 1. Generic alerting infra | `alerting` | `x-pack/platform/plugins/shared/alerting/` | Rule type registry, `RulesClient`, Task Manager scheduling, `AlertsService` (alerts-as-data writes) |
| 2. Persistence helpers | `rule_registry` | `x-pack/platform/plugins/shared/rule_registry/` | `createPersistenceRuleTypeWrapper` (bulk indexing helper `alertWithPersistence()`), `RuleDataClient`, `RuleDataService.initializeIndex()` |
| 3. Security domain | `security_solution` | `x-pack/solutions/security/plugins/security_solution/` | Detection rule types (EQL/ESQL/Query/…), `createSecurityRuleTypeWrapper`, `IDetectionRulesClient`, prebuilt rule lifecycle, Zod schemas, routes, UI |

A registered detection rule type is the composition:

```
plugins.alerting.registerType(
  createSecurityRuleTypeWrapper(securityOptions)(   // security: exceptions, gaps, privileges, telemetry
    createPersistenceRuleTypeWrapper({ ruleDataClient, logger })( // alerts-as-data persistence
      create<Type>AlertType()                       // executor (EQL/ESQL/Query/...)
    )
  )
)
```

Wrapper composition lives in
`x-pack/solutions/security/plugins/security_solution/server/plugin.ts` (setup phase) and
`.../server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts`.

### Diagram — plugin layering

```
                         ┌────────────────────────────────────────────┐
                         │        SECURITY SOLUTION (domain)          │
                         │                                            │
                         │  • Routes /api/detection_engine/rules/*    │
                         │  • IDetectionRulesClient (per request)     │
                         │  • Zod schemas (rule_schemas.gen.ts …)     │
                         │  • createSecurityRuleTypeWrapper(...)      │
                         │  • Detection executors (eql/esql/...)      │
                         │  • Prebuilt rule pipeline                  │
                         │  • UI: rule_management_ui / rule_details_ui│
                         └─────────────────┬──────────────────────────┘
                                           │ uses
                         ┌─────────────────▼──────────────────────────┐
                         │           RULE REGISTRY (platform)         │
                         │                                            │
                         │  • createPersistenceRuleTypeWrapper        │
                         │     – alertWithPersistence()               │
                         │     – bulk index alerts                    │
                         │  • RuleDataClient / RuleDataService        │
                         └─────────────────┬──────────────────────────┘
                                           │ writes via
                         ┌─────────────────▼──────────────────────────┐
                         │             ALERTING (platform)            │
                         │                                            │
                         │  • RuleTypeRegistry                        │
                         │  • RulesClient (CRUD on type 'alert' SOs)  │
                         │  • AlertsService                           │
                         │  • Task Runner / Task Manager              │
                         └────────────────────────────────────────────┘
                                           │
                                           ▼
                          .kibana_alerting_cases (rule SOs)
                          .alerts-security.alerts-<ns>  (alerts)
                          .siem-signals-<ns>            (legacy alias)
                          .kibana-event-log-*           (executions)
                          .kibana_task_manager          (scheduling)
```

---

## 2. Why each component exists (rationale)

This section explains the *intent* behind each architectural piece — what
problem it solves, why it isn't merged with its neighbours, and what would
break if it weren't there. Use this as a "design rationale" companion to the
"how" sections that follow.

### 2.1 Why three plugins instead of one

Detection Rules are not a Kibana primitive — they are a security-domain
application of a much more general capability ("schedule something in Task
Manager, run it as a user, and persist the output"). The codebase therefore
splits the responsibility into **platform** vs **solution** layers so the same
infrastructure can serve Observability, Stack Monitoring, ML, and the rest of
Kibana, while Security is free to evolve its own rule types and UX.

| Plugin | Why it exists |
|--------|---------------|
| **`alerting`** (platform) | Owns the *generic* concept of "a thing that runs on a schedule and may produce alerts": rule-type registry, `RulesClient` (CRUD on `alert` SOs), Task Manager integration, encrypted API keys, lifecycle, RBAC. Detection Rules are *one consumer* (`consumer: 'siem'`); the framework also serves Observability, ML, Stack alerts, etc. Centralising scheduling, persistence, RBAC and dry-run/preview here means each domain only writes its own *executor*. |
| **`rule_registry`** (platform) | Bridges "rules" and "alerts as data". Provides `createPersistenceRuleTypeWrapper` (for executors that produce many alerts at once and need bulk indexing into a custom index), `RuleDataClient`, and `RuleDataService.initializeIndex()` (creates index templates and aliases). It exists separately from `alerting` because not every rule produces persisted alerts — only those that need a queryable, ECS-aligned alerts index do. |
| **`security_solution`** (solution) | Owns the security domain: the eight detection rule types, executors, exceptions integration, gap detection, prebuilt rule lifecycle, MITRE coverage, the Rules table & wizard UI, telemetry, ES\|QL preview, the `IDetectionRulesClient` adapter, and the Security-specific Zod schemas. This is where "what counts as a security alert" lives. |

If we collapsed the three layers, every domain would have to re-implement
scheduling, encrypted API keys and alerts indexing — and any change to
Security's rule shape would touch the platform.

### 2.2 Why `createSecurityRuleTypeWrapper` (instead of putting logic in each executor)

Each rule type (EQL, ESQL, Threshold…) needs the **same** non-domain-specific
plumbing around its `executor`:
- resolve a data view or validate an index pattern,
- check the user's index/cluster privileges,
- validate timestamp fields and build runtime mappings for `timestamp_override`,
- compute time tuples and detect gaps,
- load and apply exception lists,
- record execution status, gap telemetry, suppression telemetry,
- format alerts for legacy alerting actions.

Without the wrapper, every `create*AlertType()` would re-implement all of the
above — and inevitably drift. The wrapper enforces *one* policy for what it
means to be a "security detection rule", and lets the eight executors focus on
exactly one thing: "given the parameters and a time range, find candidate
alerts in ES."

It is composed *outside* of `createPersistenceRuleTypeWrapper`, not inside,
because it must run **before** persistence (e.g. it short-circuits if the user
has no index privileges) and **after** persistence (gap storage, telemetry).

### 2.3 Why a separate `IDetectionRulesClient`

`RulesClient` (alerting) is a generic API in a generic vocabulary
(`alertTypeId`, `params`, camelCase, optional types, no notion of `rule_id`,
`immutable`, `rule_source`, prebuilt updates, customisation tracking, …).
`IDetectionRulesClient` is the **domain-shaped** facade on top:

- speaks `RuleCreateProps` / `RuleUpdateProps` / `RulePatchProps` /
  `RuleResponse` (snake_case, discriminated by `type`),
- knows about `rule_id` as the business identity (vs `id` as the SO id),
- enforces ML auth, prebuilt-rule rules (e.g. some fields are not
  customisable, others are), validates non-customisable update fields,
- recomputes `rule_source` (`is_customized`, `customized_fields`,
  `has_base_version`) on every write,
- contains the **mergers** for create/update/patch — the only place where
  defaults, current state and request body are blended in a single,
  testable spot,
- exposes the **RBAC read-auth-edit** branch so callers don't accidentally
  require `all` privileges for fields that should be writable with `read`.

It exists so that **routes**, **bulk actions**, and **prebuilt-rule logic**
all share one consistent write path. Otherwise these three call-sites would
each duplicate (and quietly diverge in) the same merging/validation code.

### 2.4 Why Zod schemas generated from OpenAPI

Three constraints made code-generated Zod the right answer:

1. **Public API contract**: the rules API is consumed by curl, the ECH UI,
   the Detections solution UI, the Fleet package builder, and the
   `elastic/detection-rules` repo. We need a single OpenAPI spec to publish.
2. **Server-side validation must be exhaustive**: with eight rule types and
   four operations per type (`Create`/`Update`/`Patch`/`Response`), hand-written
   `io-ts` quickly drifted from the OpenAPI doc. Generating Zod from YAML
   means a route can never accept a body the docs say is invalid.
3. **Discriminated unions on `type`**: the union of eight rule shapes is the
   *single* construct that lets TypeScript narrow rules safely throughout the
   codebase. Zod v4's `z.discriminatedUnion` produces both a validator and a
   correctly-narrowed inferred type — for free, from the spec.

This is why every `*.gen.ts` is auto-generated and every route uses
`buildRouteValidationWithZod` from `@kbn/zod-helpers/v4` — never a hand-written
validator.

### 2.5 Why split rule shapes into Create / Update / Patch / Response

Each operation has different invariants:
- **Create**: takes user input, applies defaults, must include `type`.
- **Update**: requires the full body (think PUT), but **must not** allow
  changing fields that would invalidate prior alerts (`type`, `immutable`,
  `version` for prebuilts). `validateNonCustomizableUpdateFields` enforces this.
- **Patch**: every field optional; `apply_rule_patch.ts` carefully merges arrays
  vs scalars vs nested objects.
- **Response**: the persisted shape, *plus* derived fields the user never sends
  (`id`, `revision`, `rule_source`, `execution_summary`).

Modelling them as separate Zod objects (rather than partials of one) makes the
contract explicit and prevents a Patch from accidentally being processed as a
Create.

### 2.6 Why `RuleSource` is a discriminated union

Detection rules have two very different lifecycles:
- **`internal`** rules are owned by the user and arbitrary fields are editable.
- **`external`** rules came from a Fleet content package; they have a *base
  version* somewhere we can re-fetch, may be *customised* by the user, and
  must support **revert** and **upgrade-with-3-way-diff**.

The discriminated union lets every consumer (UI, bulk actions, upgrade flow)
pattern-match on `rule_source.type` and only deal with fields that exist for
that source. `is_customized` and `customized_fields[]` enable the UI to show
"Modified" badges and gate revert; `has_base_version` flags the rare case
where the base asset has been removed (deprecated/unavailable package
version) so the UI hides "Revert".

### 2.7 Why `execution_summary` is computed, not persisted

A rule can run hundreds of times a day; persisting status on the rule SO would
mean a write per execution and contention with user edits. Instead, every
execution writes to the **Event Log** data stream (`.kibana-event-log-*`),
and `execution_summary` is computed on read by aggregating the latest events.
Benefits:
- rule SO writes stay user-driven and rare,
- the Event Log gives time-series and history "for free",
- Task Manager owns scheduling without coupling to SO writes.

### 2.8 Why a separate `security-rule` SO type for prebuilt assets

Prebuilt rule **content** and **runtime instances** have different lifecycles:

| Concern | `security-rule` SO | `alert` SO |
|---------|---------------------|-------------|
| Source of truth | The Fleet package | The user's space |
| Mutability | Immutable per `(rule_id, version)` — new versions arrive as new docs | Mutable; users edit |
| Visibility | `agnostic` — same content available in every space | `multiple-isolated` — per space |
| Searchable | Almost nothing (mapping `dynamic: false`, just `rule_id`/`version`/a few facets) | Fully searchable + RBAC |
| Encrypted | No | Yes (`apiKey`) |
| Index | `.kibana_security_solution` | `.kibana_alerting_cases` |

Storing both in one SO type would conflate "the catalogue of available rules"
with "the rules I have running"; would require encryption on inert content;
and would break the upgrade flow (we need the base version *and* the user's
current rule to coexist). The split also means the prebuilt-rules catalogue
is inert until a user explicitly installs a rule, which is good for safety
and footprint.

### 2.9 Why Fleet ships prebuilt rules

Decoupling content from code lets:
- Elastic ship rule updates **without a Kibana release** (Detection Rules team
  ships to the Fleet registry independently),
- users opt into specific versions via the Fleet integration UI,
- prebuilt content live in its own repo (`elastic/detection-rules`) with its
  own review/CI (community contributions, MITRE coverage tracking, etc.),
- packages bundle release notes / diff metadata so the upgrade UI can show
  exactly what changed.

The **bootstrap** flow (`bootstrap_prebuilt_rules`) hides this from the user —
the package is installed transparently the first time the Detections page is
opened.

### 2.10 Why three-way diffs for prebuilt rule upgrades

A user upgrading from rule v1 → v2 may have customised v1. Two-way diff
("does my current rule equal the new version?") would either:
- destroy customisations on upgrade, or
- refuse to upgrade if anything is customised.

Three-way diff `(base, current, target)` distinguishes:
- **non-conflicting**: target changed a field the user didn't touch → auto-merge,
- **identical**: user's customisation matches what target wants → no-op,
- **solvable conflict**: both changed, but in compatible ways → resolvable,
- **non-solvable conflict**: both changed incompatibly → user must choose.

This is what `calculateRuleDiff` and the **Rule Upgrade flyout** show. It's
the only safe way to deliver content updates over potentially-customised
rules.

### 2.11 Why exceptions live in a separate `lists` plugin

Exception lists are not a detection-engine-only concept:
- **Endpoint Security** uses the same `exception-list-agnostic` SOs for
  trusted apps, trusted devices, host isolation exceptions, etc.,
- **Value lists** (big lists of IPs, hashes, domains) are independently useful
  for enrichment and other features,
- the **builder UI** (`@kbn/securitysolution-list-utils`) is shared between
  detection rules, endpoint policies and shared exception management.

Putting all of this in `lists` means the SO model, mappings, RBAC, import/export
and CRUD endpoints exist **once**. Detection rules merely *reference* lists by
`{ list_id, namespace_type }` and load items at execution time.

### 2.12 Why `exceptions_list[]` references the list (rather than embedding items)

Embedding would force a rule SO update every time someone adds/removes an
exception item, breaking the principle that a rule SO is rarely written. The
indirection also lets:
- multiple rules share a `detection`-typed exception list,
- a single `rule_default` list grow per rule without touching the rule SO,
- value-list (`type: 'list'`) entries reference giant lists by id.

The cost is one extra ES round-trip at execution time, paid by the security
wrapper.

### 2.13 Why `endpoint`-typed exception lists are filtered out of regular detection rules

Endpoint exception lists target *policy enforcement* on the agent, not
ES-side filtering. Including them in a normal detection rule's exception
filter would hide events the user actually wants to see. The wrapper
explicitly drops them in `getExceptions(...)` via `ENDPOINT_ARTIFACT_LIST_IDS`
unless the rule legitimately references them.

### 2.14 Why Alerts-as-Data (and a secondary `.siem-signals` alias)

Originally, security alerts were written to `.siem-signals-<ns>`. The
**Alerts-as-Data** project unified the alert storage shape across all of
Kibana (Observability, ML, Security, …) under `.alerts-<context>.alerts-<ns>`.
The reasons:
- a single field map (`technicalRuleFieldMap` + per-domain extensions) so
  cross-domain features (Cases, Alerts table, AI Assistant) work uniformly,
- ECS alignment + ILM defaults out of the box,
- platform-level RBAC and search,
- `kibana.alert.*` namespace prevents collisions with source `event.*` fields.

The `.siem-signals-<ns>` **secondary alias** is kept for **backwards
compatibility**: existing detection-rule consumers (KQL queries, dashboards,
external SIEMs, the Cases plugin) keep working. New code should target the
canonical `.alerts-security.alerts-<ns>` alias.

### 2.15 Why `securityRuleTypeFieldMap` merges four field maps

Each layer contributes mappings:
- `technicalRuleFieldMap` — the platform's required `kibana.alert.*` envelope
  (`kibana.alert.uuid`, `kibana.alert.rule.uuid`, `kibana.alert.status`, …),
- `alertsFieldMap` — Security-specific alert fields (entities, threat fields,
  enrichment, suppression, building blocks),
- `rulesFieldMap` — denormalised rule metadata snapshot at alert time
  (`kibana.alert.rule.*` so an alert is self-describing without a rule lookup),
- `aliasesFieldMap` (`signal_aad_mapping.json`) — legacy `signal.*` aliases so
  pre-AAD queries still work against the new index.

Merging them in `create_security_rule_type_wrapper.ts` means *every* security
detection rule type writes a uniform document, regardless of executor.

### 2.16 Why `bulkEdit` is a single endpoint with discriminated payload

Three reasons:
1. **Pessimistic UX**: long-running bulk operations need a single transactional
   surface with limits, dry-run, partial success reporting, and concurrency
   throttling. Spreading actions across many endpoints would scatter that.
2. **One source of truth for limits and authorization**: `MAX_RULES_TO_BULK_EDIT`,
   `MAX_RULES_TO_PROCESS_TOTAL`, `MAX_ROUTE_CONCURRENCY`, `routeLimitedConcurrencyTag`,
   ML auth, prebuilt-rule restrictions, alert-suppression compatibility — all
   centralised.
3. **Selection-by-query**: a user filtering "all KQL rules tagged `Linux`" can
   bulk-edit hundreds of rules without the client materialising them, because
   the server resolves the query (`fetchRulesByQueryOrIds`).

The discriminated `BulkActionType` + `BulkActionEditType` payload mirrors the
rule-type discriminated union: one endpoint, exhaustive validation, type-safe
dispatch.

### 2.17 Why **dry-run** for bulk actions

Bulk operations on thousands of rules can fail per-rule for many reasons (ML
auth, immutable-rule restrictions, type incompatibilities, missing
connectors). Without dry-run the only way to learn this is by performing the
action and rolling forward — destructive and slow. The dry-run path runs the
full validation pipeline, returns per-rule failures, and gives the UI material
for a confirmation modal **before** any write.

### 2.18 Why a dedicated **Rules table page + multi-step wizard** UI

The rule definition model is high-dimensional (eight types, dozens of fields,
multiple ML/threat/data-view modes, optional alert suppression, scheduled
actions, response actions, exceptions). A single-form page would be
overwhelming. The wizard splits the complexity into:
1. **Define** — type-specific (query, threshold, ML job…),
2. **About** — name, description, severity, MITRE,
3. **Schedule** — interval/lookback,
4. **Actions** — connectors / response actions.

This matches the mental model the user already has for "what is a detection
rule", and the same wizard is reused for both **create** and **edit** so
behaviour can never diverge. The Rules table is the operational view (search,
bulk actions, status, gaps), while the wizard is the editorial view.

### 2.19 Why the UI uses `rules_table_saved_state` URL syncing

Detection engineers spend a lot of time switching between filtered table
views and individual rules; preserving filters, search, sort and pagination
in the URL means deep links and browser back/forward "just work". This is
implemented by `RulesTableContext` + `use_sync_rules_table_saved_state.ts`
and is a UX requirement specific to operational tables of this scale.

### 2.20 Why experimental feature flags are scoped to `xpack.securitySolution.*`

The alerting framework intentionally has no notion of Security flags — that
would invert the dependency. So Security keeps its own `enableExperimental`
list (`allowedExperimentalValues`), parsed at config time, surfaced server-side
via `config.experimentalFeatures` and client-side via
`useIsExperimentalFeatureEnabled`. The result:
- Security can ship work-in-progress rule types (e.g. ESQL behind
  `esqlRulesDisabled`) and gate UI affordances without a release-train tie-in,
- the `disable:` prefix lets us ship a feature default-on and still allow
  emergency disable in YAML,
- platform stays unaware of the flags.

### 2.21 Why the Event Log is the audit/observability backbone

A separate data stream (`.kibana-event-log-*`) instead of writing into the
rule SO or the alerts index gives:
- per-execution time-series (status, durations, gap ranges, search metrics),
- a single place for monitoring tooling and the **Execution log table** UI,
- decoupling: Task Manager always logs an execution event, even if the
  executor crashed before producing alerts.

This is also where `storeGapsInEventLogEnabled` writes detected gaps so they
can later drive `fill_gaps` bulk actions.

### 2.22 Why Encrypted Saved Objects (ESO) for `apiKey`

Each rule runs as a real user (via API key) so RBAC applies to the executor's
ES access. Storing the API key in the SO is a security risk; ESO encrypts
selected attributes (`apiKey`, `uiamApiKey`) at rest and uses the rest of the
SO (`RuleAttributesIncludedInAAD`) as additional authenticated data, so an
attacker can't substitute an API key into another rule. The AAD list is also
why **partial updates of those fields are dangerous** — they would invalidate
the AAD; the alerting framework therefore restricts how those fields are
mutated.

### 2.23 Why `IDetectionRulesClient` has an RBAC "read-auth-editable" branch

A few rule fields (e.g. `investigation_fields`) are *operational metadata* that
analysts with `read` privilege should be able to set. Forcing `all` privilege
for those would block on-call workflows. The `rbac_methods/` branch routes
those edits through `bulkEditRuleParamsWithReadAuth` (alerting), which checks
field-level write permissions instead of rule-level write permissions. This
exists *because* the granularity of "can edit this rule" was insufficient for
real workflows.

### 2.24 Why the Persistence Wrapper uses bulk indexing (`alertWithPersistence`)

Detection rules can produce thousands of alerts per execution (especially
threshold/EQL/IndicatorMatch). Per-alert ES round-trips would be untenable.
`createPersistenceRuleTypeWrapper` provides `alertWithPersistence()` which
buffers alerts during the executor and flushes them as a single bulk write
through `RuleDataClient`. The wrapper also handles deduplication keys
(`kibana.alert.uuid`) and rule revision tagging.

### 2.25 Why so many derived/aggregated indices?

The split between **SOs**, **alerts-as-data**, **task manager**, **event log**
and **lists/value lists** isn't accidental — each has a different read pattern:

| Index family | Read pattern | Optimised for |
|--------------|--------------|---------------|
| `.kibana_alerting_cases` (`alert` SO) | Few writes, frequent reads of metadata | Document-level RBAC, encryption, model versions |
| `.kibana_security_solution` (`security-rule`, exceptions) | Bulk install/upgrade, point reads | `dynamic: false` for prebuilt content; namespaced for exceptions |
| `.kibana_task_manager` | Continuous polling | Highly indexed, contention-tolerant |
| `.alerts-security.alerts-<ns>` | Bulk write per execution, heavy aggregations | ECS-aligned, ILM, secondary aliases |
| `.kibana-event-log-*` | Append-only, time-series | Data stream, ILM, low retention by default |
| `lists`/`list-items` (value lists) | Big O(N) value lookups | Plain ES indices for raw scale |

Trying to unify these would break at least one access pattern.

### 2.26 Why the security wrapper performs privilege checks at run time (not just at edit time)

A rule's index pattern, data view or ML job can become unreachable for the
running user after the rule was created (revoked permissions, deleted index,
data view changed, ML job moved). Checking only at create/edit time would
silently produce empty results forever. Run-time checks let the wrapper:
- record a rule status of `partial failure` with a clear reason,
- still attempt to run subsequent indices the user *can* read,
- surface this on the Rules table and Rule Details so analysts see the cause.

---

## 3. Rule Types

> **In plain terms:** There are exactly **eight** kinds of detection rules.
> They differ only in *how they ask Elasticsearch* "is something suspicious?"
> — KQL/Lucene, EQL sequences, ESQL pipes, terms-above-a-threshold, joining
> against a threat intel index, asking an ML anomaly job, looking for terms
> that haven't been seen before, or replaying a saved query. Every other
> piece of the rule (schedule, actions, exceptions, severity, …) is shared.

### When would I use which?

| Rule type | Use it when… | Typical input |
|-----------|--------------|---------------|
| `query` / `saved_query` | "Tell me whenever a document matches this filter." | KQL or Lucene over chosen indices |
| `eql` | You need *sequences* or temporal correlation, e.g. "process A spawns process B within 1m". | EQL over event indices |
| `esql` | You want an analytics-style pipeline (`FROM … | WHERE … | STATS …`) and don't need a separate index/data view (ESQL embeds the source). | ES\|QL string |
| `threshold` | "Alert when the same field value appears more than N times in the window" — e.g. brute force, port scan. | Query + `threshold.field`, `threshold.value` |
| `threat_match` | "Cross-reference my events against a threat-intel feed (IOC list)." | Query + threat index + threat mapping |
| `machine_learning` | An ML anomaly job is already trained; alert on anomaly score. | `machine_learning_job_id` + `anomaly_threshold` |
| `new_terms` | "Alert the first time a value appears for these field(s) in N days." Useful for first-seen detections. | Query + `new_terms_fields[]` + `history_window_start` |

The eight `siem.*` rule type IDs are constants shared via a platform package so
other plugins can recognise them:

```32:42:src/platform/packages/shared/kbn-securitysolution-rules/src/rule_type_constants.ts
const RULE_TYPE_PREFIX = 'siem';
export const EQL_RULE_TYPE_ID = 'siem.eqlRule';
export const ESQL_RULE_TYPE_ID = 'siem.esqlRule';
export const INDICATOR_RULE_TYPE_ID = 'siem.indicatorRule';
export const ML_RULE_TYPE_ID = 'siem.mlRule';
export const QUERY_RULE_TYPE_ID = 'siem.queryRule';
export const SAVED_QUERY_RULE_TYPE_ID = 'siem.savedQueryRule';
export const THRESHOLD_RULE_TYPE_ID = 'siem.thresholdRule';
export const NEW_TERMS_RULE_TYPE_ID = 'siem.newTermsRule';
```

Mapping from API `type` (Zod literal) to alerting rule type ID lives in
`src/platform/packages/shared/kbn-securitysolution-rules/src/rule_type_mappings.ts`.

| API `type` literal | Alerting rule type ID | Executor file |
|--------------------|----------------------|----------------|
| `eql` | `siem.eqlRule` | `server/lib/detection_engine/rule_types/eql/create_eql_alert_type.ts` |
| `esql` | `siem.esqlRule` | `.../rule_types/esql/create_esql_alert_type.ts` |
| `query` | `siem.queryRule` | `.../rule_types/query/create_query_alert_type.ts` |
| `saved_query` | `siem.savedQueryRule` | reuses `createQueryAlertType({ id: SAVED_QUERY_RULE_TYPE_ID })` |
| `threshold` | `siem.thresholdRule` | `.../rule_types/threshold/create_threshold_alert_type.ts` |
| `threat_match` | `siem.indicatorRule` | `.../rule_types/indicator_match/create_indicator_match_alert_type.ts` |
| `machine_learning` | `siem.mlRule` | `.../rule_types/ml/create_ml_alert_type.ts` |
| `new_terms` | `siem.newTermsRule` | `.../rule_types/new_terms/create_new_terms_alert_type.ts` |

> Naming note: factories are `create*AlertType()` for historical reasons but
> represent **rule types**.

All rule executors live under
`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/`.

---

## 4. Zod API Schemas (single source of truth for the shape of a rule)

> **In plain terms:** The shape of a rule isn't written in TypeScript by
> hand — it's written *once* in an OpenAPI YAML file and **code-generated**
> into Zod schemas (runtime validators with TypeScript types). The same YAML
> drives the public API docs and the server-side validators, so they can
> never drift apart. When you read the codebase, anything ending in
> `.gen.ts` is auto-generated; treat it as read-only and edit the sibling
> `.schema.yaml` instead.

Rule shapes are described as **OpenAPI YAML** that is **code-generated to Zod
v4** by `@kbn/openapi-generator`. Every `*.gen.ts` is auto-generated from the
sibling `*.schema.yaml` and uses `import { z } from '@kbn/zod/v4'`. Server
validators wrap the Zod schemas with `buildRouteValidationWithZod` from
`@kbn/zod-helpers/v4`.

### How a request becomes a typed Zod object (concrete walk-through)

A `POST /api/detection_engine/rules` with this body:

```json
{
  "type": "threshold",
  "name": "Failed logins burst",
  "description": "...",
  "severity": "medium",
  "risk_score": 47,
  "query": "event.action: \"failed_login\"",
  "threshold": { "field": ["host.name"], "value": 50 }
}
```

is processed as follows:

1. The route validator
   `buildRouteValidationWithZod(RuleCreateProps)` parses the body.
2. Zod sees `type: 'threshold'` and selects the `ThresholdRuleCreateFields`
   branch of the discriminated union. If the body doesn't match that branch,
   you get a typed validation error pointing at the offending field.
3. After parsing, TypeScript already knows the value is a
   `ThresholdRuleCreateProps` — `query` and `threshold` are guaranteed
   present, `machine_learning_job_id` is guaranteed absent.
4. The Detection Rules Client then merges defaults from
   `apply_rule_defaults.ts` (e.g. `interval: '5m'`, `from: 'now-6m'`,
   `enabled: true`) before persisting.

Locations:

- OpenAPI specs: `x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/*.schema.yaml`
- Generated Zod schemas: `*.gen.ts` next to each YAML
- Public re-exports: `.../common/api/detection_engine/model/rule_schema/index.ts`

### 4.1 Schema composition

```
common_attributes.gen.ts
└── BaseRequiredFields  (name, description, risk_score, severity)
└── BaseOptionalFields  (rule_name_override, timestamp_override, timeline_id, …, response_actions)
└── BaseDefaultableFields (version, tags, enabled, interval, from, to, actions, …, related_integrations)

specific_attributes/
├── eql_attributes.gen.ts
├── esql              (inline in rule_schemas.gen.ts)
├── threshold_attributes.gen.ts
├── threat_match_attributes.gen.ts
├── ml_attributes.gen.ts
└── new_terms_attributes.gen.ts

rule_schemas.gen.ts (combines per rule type and per operation)
```

### 4.2 The four "operation shapes" per rule type

Why four shapes per rule type instead of one? Because the same conceptual
"rule" looks different depending on what you're doing with it:

- **Create** (POST) — user input, defaults will fill in the rest.
- **Update** (PUT) — *full* replacement; some fields (e.g. `type`) may not
  legally change because that would invalidate prior alerts.
- **Patch** (PATCH) — partial update; everything optional.
- **Response** (GET / response body) — *what comes back*; includes
  server-derived fields (`id`, `revision`, `created_at`, `rule_source`,
  `execution_summary`) the client never sends.

Each gets its own Zod schema so validation errors are accurate per-operation
and the TypeScript inference is exact.

For every rule type the generator produces four Zod objects, derived via
`merge` / `partial` / `required` from the attribute groups:

| Shape | Purpose | Built from |
|-------|---------|------------|
| `<Type>RuleCreateProps` | POST body for create | `SharedCreateProps + <Type>CreateFields` |
| `<Type>RuleUpdateProps` | PUT body for full update | `SharedUpdateProps + <Type>CreateFields` |
| `<Type>RulePatchProps` | PATCH body (everything optional) | `SharedPatchProps + <Type>PatchFields` |
| `<Type>Rule` (response) | GET / response body | `SharedResponseProps + <Type>ResponseFields` |

`SharedResponseProps` adds the persistence-only fields (`id`, `rule_id`,
`immutable`, `rule_source`, `revision`, `created_at`, `updated_at`,
`execution_summary`, …) defined in `ResponseFields`.

### 4.3 The discriminated union

The eight type-specific create-field schemas are composed into a single Zod
discriminated union — this is the key type used internally:

```603:616:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/rule_schemas.gen.ts
export const TypeSpecificCreatePropsInternal = z.discriminatedUnion('type', [
  EqlRuleCreateFields,
  QueryRuleCreateFields,
  SavedQueryRuleCreateFields,
  ThresholdRuleCreateFields,
  ThreatMatchRuleCreateFields,
  MachineLearningRuleCreateFields,
  NewTermsRuleCreateFields,
  EsqlRuleCreateFields,
]);
```

The aggregated public types (also exported from the same file) are:

- `RuleCreateProps`  — union of all `<Type>RuleCreateProps`
- `RuleUpdateProps`
- `RulePatchProps`
- `RuleResponse`     — union of all `<Type>Rule`

These are the types that **routes** validate against and that the **Detection
Rules Client** consumes / returns.

### 4.4 Zod composition diagram

```
                       common_attributes.gen.ts
   ┌───────────────────────┬──────────────────────────────┐
   ▼                       ▼                              ▼
BaseRequiredFields    BaseOptionalFields        BaseDefaultableFields
   │                       │                              │
   └────────── merge ──────┴──────────────── merge ───────┘
                              │
                              ▼
                       BaseCreateProps
                              │
              ┌───────────────┼─────────────────┐
              ▼               ▼                 ▼
   SharedCreateProps   SharedUpdateProps   SharedPatchProps   SharedResponseProps
              │               │                 │                  │
              │               │                 │                  │
   per-type   ▼               ▼                 ▼                  ▼
specific_attributes/* + rule_schemas.gen.ts builds:

   <Type>RuleCreateProps   <Type>RuleUpdateProps   <Type>RulePatchProps   <Type>Rule

           └── all unioned via  z.discriminatedUnion('type', [...]) ──┘
                              │
                              ▼
       RuleCreateProps  RuleUpdateProps  RulePatchProps  RuleResponse
              │
              ▼
        validated at route boundary by
        buildRouteValidationWithZod (from @kbn/zod-helpers/v4)
```

---

## 5. Rule Response structure (`RuleResponse`)

> **In plain terms:** When you read a detection rule via the API, you always
> get back the same envelope (`RuleResponse`) regardless of which type the
> rule is. Inside the envelope are: identifying info, audit, "where it came
> from" (`rule_source`), the user-editable fields, the type-specific fields,
> and the latest execution status. Think of `RuleResponse` as the *complete
> picture* of a rule at this moment, including derived data (like
> `execution_summary`) that wasn't part of what the user originally sent.

`RuleResponse` is the single shape returned by every rule endpoint
(`POST/PUT/PATCH/GET /api/detection_engine/rules`, find, bulk action results,
prebuilt install/upgrade results). It is a discriminated union (over `type`)
of all `<Type>Rule` schemas.

### 5.1 Common fields (`SharedResponseProps = BaseResponseProps + ResponseFields`)

| Group | Fields |
|-------|--------|
| **Identity** | `id` (UUID), `rule_id` (signature/business id), `revision` (incremented on save), `version` (content version, used by prebuilts) |
| **Audit** | `created_at`, `created_by`, `updated_at`, `updated_by` |
| **Source / origin** | `immutable: boolean`, `rule_source: RuleSource` (see §4.3) |
| **Required** | `name`, `description`, `risk_score`, `severity` |
| **Defaultable** | `enabled`, `interval`, `from`, `to`, `tags`, `actions[]`, `exceptions_list[]`, `author[]`, `false_positives[]`, `references[]`, `max_signals`, `threat[]`, `setup`, `related_integrations[]`, `required_fields[]`, `risk_score_mapping[]`, `severity_mapping[]` |
| **Overrides** | `rule_name_override`, `timestamp_override`, `timestamp_override_fallback_disabled` |
| **UI hooks** | `timeline_id`, `timeline_title`, `note` (investigation guide), `building_block_type`, `investigation_fields`, `meta`, `license` |
| **Misc** | `output_index` (legacy), `namespace` (alerts-as-data ns), `throttle`, `response_actions[]`, `outcome` / `alias_*` (saved object resolve) |
| **Monitoring** | `execution_summary?: RuleExecutionSummary` (last status, metrics) |

### 5.2 Type-specific fields (selected)

| Rule type | Discriminator | Notable fields |
|-----------|--------------|----------------|
| `eql` | `type: 'eql'` | `query`, `language: 'eql'`, `index?`, `data_view_id?`, `filters?`, `event_category_override?`, `tiebreaker_field?`, `timestamp_field?`, `alert_suppression?` |
| `esql` | `type: 'esql'` | `query`, `language: 'esql'`, `alert_suppression?` (no index/data_view — ESQL embeds source) |
| `query` | `type: 'query'` | `query?`, `language?: 'kuery' \| 'lucene'`, `index?`, `data_view_id?`, `filters?`, `saved_id?`, `alert_suppression?` |
| `saved_query` | `type: 'saved_query'` | `saved_id` (required), `query?`, `language?`, `index?`, `data_view_id?`, `filters?`, `alert_suppression?` |
| `threshold` | `type: 'threshold'` | `query`, `threshold` (`{ field[], value, cardinality? }`), `index?`, `data_view_id?`, `filters?`, `saved_id?`, `language?`, `alert_suppression?` |
| `threat_match` | `type: 'threat_match'` | `query`, `threat_query`, `threat_mapping`, `threat_index`, `threat_filters?`, `threat_indicator_path?`, `threat_language?`, `concurrent_searches?`, `items_per_search?`, `index?`, `data_view_id?`, `filters?`, `saved_id?`, `language?`, `alert_suppression?` |
| `machine_learning` | `type: 'machine_learning'` | `anomaly_threshold`, `machine_learning_job_id`, `alert_suppression?` |
| `new_terms` | `type: 'new_terms'` | `query`, `new_terms_fields[]`, `history_window_start`, `index?`, `data_view_id?`, `filters?`, `language?`, `alert_suppression?` |

### 5.3 `RuleSource` — how the system tracks where the rule came from

```114:134:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/common_attributes.gen.ts
export const InternalRuleSource = z.object({
  type: z.literal('internal'),
});

export const ExternalRuleSource = z.object({
  type: z.literal('external'),
  is_customized: IsExternalRuleCustomized,
  has_base_version: ExternalRuleHasBaseVersion,
  customized_fields: ExternalRuleCustomizedFields,   // [{ field_name: string }]
});

export const RuleSource = z.discriminatedUnion('type', [ExternalRuleSource, InternalRuleSource]);
```

- **`internal`** — custom, user-created rule (`immutable: false`).
- **`external`** — installed from a Fleet content package (`immutable: true`).
  - `is_customized` flips to `true` the moment the user edits any field.
  - `has_base_version` indicates whether the original asset is still
    available in `security-rule` SOs (needed for revert / 3-way diff).
  - `customized_fields` lists the field names the user has changed.

This is computed by
`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/mergers/rule_source/calculate_rule_source.ts`
on every write to a prebuilt rule.

> **Why this matters for the UI:** the Rules table shows a **"Modified"**
> badge whenever `rule_source.type === 'external' && is_customized === true`.
> The **Revert** action only appears when `has_base_version === true`. The
> **Upgrade** flow uses `rule_source` to decide which fields to show in the
> three-way diff.

### 5.4 `execution_summary` — runtime status surfaced on the response

`execution_summary?: RuleExecutionSummary` (defined in
`common/api/detection_engine/rule_monitoring/model/execution_summary.gen.ts`)
is attached to GET/find responses. It exposes the latest execution state
(`succeeded`/`partial failure`/`failed`/`going to run`), execution metrics
(documents searched, gap, indexing duration), and timestamps. It is
**not** persisted on the rule SO — it is derived from the Event Log on read.

---

## 6. Detection Rules Client (`IDetectionRulesClient`)

> **In plain terms:** A polite Security-domain "translator" that sits in
> front of the generic Alerting Framework. Routes, bulk actions, and
> prebuilt-rule logic all talk to *this* client (in security vocabulary:
> `RuleCreateProps`, `rule_id`, `rule_source`, snake_case). The client
> handles the detection-engine-specific rules of the road (defaults,
> customisation tracking, ML auth, prebuilt rule restrictions) and then
> hands a translated payload to `RulesClient` (the generic alerting client,
> which speaks `alertTypeId`, camelCase, and knows nothing about Security).
> Without this client, every route would have to repeat the same
> translation/validation logic.

A per-request adapter that hides the Alerting Framework from Security Solution
callers. Created by the `RequestContextFactory`.

```typescript
interface IDetectionRulesClient {
  getRuleCustomizationStatus(): PrebuiltRulesCustomizationStatus;
  createCustomRule(args: CreateCustomRuleArgs): Promise<RuleResponse>;
  createPrebuiltRule(args: CreatePrebuiltRuleArgs): Promise<RuleResponse>;
  updateRule(args: UpdateRuleArgs): Promise<RuleResponse>;
  patchRule(args: PatchRuleArgs): Promise<RuleResponse>;
  deleteRule(args: DeleteRuleArgs): Promise<void>;
  upgradePrebuiltRule(args: UpgradePrebuiltRuleArgs): Promise<RuleResponse>;
  revertPrebuiltRule(args: RevertPrebuiltRuleArgs): Promise<RuleResponse>;
  importRule(args: ImportRuleArgs): Promise<RuleResponse>;
  importRules(args: ImportRulesArgs): Promise<Array<RuleResponse | RuleImportErrorObject>>;
}
```

Key files:

- Interface: `.../detection_rules_client/detection_rules_client_interface.ts`
- Implementation: `.../detection_rules_client/detection_rules_client.ts`
- Methods: `.../detection_rules_client/methods/{create_rule,update_rule,patch_rule,delete_rule,import_rule,upgrade_prebuilt_rule,revert_prebuilt_rule,restore_rule,...}.ts`
- Converters:
  - `convert_rule_response_to_alerting_rule.ts` — `RuleCreateProps` → alerting rule (snake_case → camelCase, `type` → `alertTypeId`)
  - `convert_alerting_rule_to_rule_response.ts` — alerting rule → `RuleResponse` (validates via Zod)
  - `convert_prebuilt_rule_asset_to_rule_response.ts` — for diffing
- **Mergers** (`.../detection_rules_client/mergers/`) — produce the next-state rule:
  - `apply_rule_update.ts` (PUT)
  - `apply_rule_patch.ts` (PATCH)
  - `apply_rule_defaults.ts` (CREATE)
  - `rule_source/calculate_rule_source.ts` (recomputes `is_customized` / `customized_fields` for prebuilt rules)

Dependencies injected at construction time:

| Dep | Used for |
|-----|----------|
| `RulesClient` (alerting) | actual SO persistence + scheduling |
| `ActionsClient` (actions) | validating action/connector references |
| `SavedObjectsClient` (core) | reading prebuilt rule assets via `IPrebuiltRuleAssetsClient` |
| `MlAuthz` | ML job authorization for `siem.mlRule` |
| `ProductFeaturesService` | tier/feature gating |
| `ILicense` | license-gated features (e.g. prebuilt rule customization) |

> Read operations are not (yet) on the interface. Reads use the deprecated
> `readRules()` helper plus internal `getRuleByIdOrRuleId`.

There is also an **RBAC branch** in `updateRule` (and bulk edit) that lets users
with only **read** privileges modify a small set of "read-auth-editable" fields
(notably `investigation_fields`) via `bulkEditRuleParamsWithReadAuth` —
implemented in
`.../detection_rules_client/methods/rbac_methods/update_rule_with_read_privileges.ts`.

---

## 7. Plugin Lifecycle

> **In plain terms:** Kibana plugins go through three phases — **constructor**
> (cheap, sync), **setup** (declare what you provide, register with other
> plugins), and **start** (begin doing actual work). Detection rules are
> registered with the Alerting framework *during setup*, before any HTTP
> request can arrive. Routes are also wired during setup. By the time the
> server is ready, the rule type registry already knows about
> `siem.queryRule`, `siem.eqlRule`, etc., and Task Manager can execute them.

`x-pack/solutions/security/plugins/security_solution/server/plugin.ts`

### Constructor
- Parses config via `createConfig(context)` (incl. `experimentalFeatures`, see §14).
- Instantiates: `AppClientFactory`, `ProductFeaturesService`, `SiemMigrationsService`,
  telemetry senders/receivers, `EndpointAppContextService`, rule monitoring service.

### Setup
1. `initSavedObjects()` — registers SO types: `security-rule` (prebuilt rule
   assets, see §11.1) and a few internal types.
2. `initUiSettings()`.
3. Product features setup, analytics event types.
4. `ruleMonitoringService.setup()`.
5. Registers task-manager tasks (risk scoring, entity store, manifest, response actions, …).
6. Builds the `RequestContextFactory`.
7. `ruleDataService.initializeIndex()` — creates the alerts-as-data index
   template + alias.
8. **Rule type registration** — wraps every detection rule type with
   `createSecurityRuleTypeWrapper` and registers it (see §7).
9. `initRoutes()` — wires API routes (rule_management, prebuilt_rules,
   rule_preview, signals, …).
10. Telemetry sender/receiver setup.
11. Agent Builder tools/attachments registration.

### Start
- Starts: rule monitoring, license, exception lists, manifest manager,
  endpoint services, fleet hooks (manifest task, policy migration), policy and
  telemetry watchers, response actions task, assistant tool registration.

### Stop
- Stops: telemetry senders, endpoint services, watchers, response actions task,
  SIEM migrations, workflow insights, license service.

---

## 8. The Security Rule Type Wrapper — what it adds on top of an executor

> **In plain terms:** Each rule type has an **executor** — a small function
> that says "given these params and this time range, find me candidate
> alerts in ES." The **wrapper** is the layer around it that does
> *everything else* every detection rule needs: check the user is allowed to
> read the data, find the right index/data view, validate timestamps, detect
> gaps from missed schedules, load exceptions and turn them into a `must_not`
> filter, run the executor, deduplicate/suppress alerts, write them as
> alerts-as-data, log the execution outcome, and emit telemetry. Without
> this layer, eight executors would each reinvent these wheels.

`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts`

### Three phases at a glance

```
┌── PRE-EXECUTION ──────────────────────────────────────┐
│  Resolve data view / indices                          │
│  Check ES read privileges (per-index)                 │
│  Validate timestamp fields                            │
│  Detect gaps from prior runs                          │
│  Load exception lists → buildExceptionFilter()        │
└─────────────────────────┬─────────────────────────────┘
                          ▼
┌── EXECUTION (per time tuple) ─────────────────────────┐
│  Call the wrapped executor (eql/esql/query/...)       │
│  Apply alert suppression                              │
│  alertsClient.report(...)  ──► persistence wrapper    │
│                                ──► RuleDataClient ES  │
└─────────────────────────┬─────────────────────────────┘
                          ▼
┌── POST-EXECUTION ─────────────────────────────────────┐
│  Aggregate warnings/errors → final status             │
│  Write status to Event Log                            │
│  Persist gap range (if storeGapsInEventLogEnabled)    │
│  Send telemetry                                       │
└───────────────────────────────────────────────────────┘
```

Pre-execution:
- Resolve data view (`getInputIndex`) or validate index pattern
- `checkPrivilegesFromEsClient` — index privileges check
- `hasTimestampFields` — primary + secondary timestamp validation, runtime mappings for overrides
- `checkForFrozenIndices` (non-serverless only)
- `getRuleRangeTuples` — gap detection + tuple generation from `schedule.interval` + last execution
- Load exception lists (`getExceptions`) and build exception filter (`buildExceptionFilter`)
- APM instrumentation

Per-tuple:
- Calls the wrapped detection executor (EQL/ESQL/Query/Threshold/ML/IndicatorMatch/NewTerms)
- Applies alert suppression
- Reports alerts via `alertsClient.report()` (which routes through the persistence wrapper to `RuleDataClient`)

Post-execution:
- `ruleExecutionLogger.logStatusChange(...)`
- `sendGapDetectedTelemetryEvent` / `sendAlertSuppressionTelemetryEvent`
- Persists gap range to Event Log when `storeGapsInEventLogEnabled`
- Aggregates warnings/errors into final status

The wrapper also defines `securityRuleTypeFieldMap` (see §12) and the
**alerts-as-data registration** for every detection rule type:

```524:535:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts
      alerts: {
        context: 'security',
        mappings: {
          dynamic: false,
          fieldMap: securityRuleTypeFieldMap,
        },
        useEcs: true,
        useLegacyAlerts: true,
        isSpaceAware: true,
        secondaryAlias: config.signalsIndex,        // .siem-signals (legacy)
        formatAlert: formatAlertForNotificationActions as unknown as FormatAlert<never>,
      },
```

---

## 9. Rule Management UI — screens and flows

> **In plain terms:** The UI gives detection engineers two complementary
> views: an **operational view** (the Rules table — search, filter,
> select-many, bulk actions, status, gaps) and an **editorial view** (a
> 4-step wizard that's the same for create and edit). The wizard is split
> into Define → About → Schedule → Actions because the rule model is too
> wide for one screen. Filters and pagination on the table are persisted in
> the URL so deep links and back/forward "just work".

The UI lives under
`x-pack/solutions/security/plugins/security_solution/public/detection_engine/`.

### 9.1 Surface map

| Screen / surface | Path | Backed by |
|------------------|------|-----------|
| **Rules table page** (`/rules`) — list, filter, search, row actions | `public/detection_engine/rule_management_ui/pages/rule_management/index.tsx` | `useFindRules` → `POST /api/detection_engine/rules/_find` |
| **Add Rules page** (browse/install prebuilts) | `public/detection_engine/rule_management_ui/pages/add_rules/` | Prebuilt rules API (§11.7) |
| **Rule Details page** (`/rules/id/{id}`) — overview, execution log, exceptions tabs | `public/detection_engine/rule_details_ui/pages/rule_details/index.tsx` | `useRuleWithFallback`, `useRuleDetailsTabs` |
| **Create Rule page** (`/rules/create`) — multi-step rule definition wizard | `public/detection_engine/rule_creation_ui/pages/rule_creation/index.tsx` | `useCreateRule` → `POST /api/detection_engine/rules` |
| **Edit Rule page** (`/rules/id/{id}/edit`) — same wizard prefilled | `public/detection_engine/rule_creation_ui/pages/rule_editing/index.tsx` | `useUpdateRule` → `PUT /api/detection_engine/rules` |
| **Rule Preview flyout** | `rule_management_ui/components/rules_table/use_rule_preview_flyout.tsx` | `POST /api/detection_engine/rules/preview` |
| **Bulk edit flyout** | `rule_management_ui/components/rules_table/bulk_actions/bulk_edit_flyout.tsx` | `useBulkActions` → `POST /api/detection_engine/rules/_bulk_action` |
| **Coverage overview** (MITRE coverage) | `rule_management_ui/pages/coverage_overview/` | `RULE_MANAGEMENT_COVERAGE_OVERVIEW_URL` |
| **Rule Update / Upgrade flyout** (prebuilt) | `rule_management_ui/components/rules_table/upgrade_prebuilt_rules_table/` + `use_prebuilt_rules_upgrade.tsx` | Prebuilt rules upgrade API (§11) |
| **Exceptions tab** (per rule) | `public/detection_engine/rule_exceptions/components/` | Lists plugin + `find_exception_references` |
| **Value Lists Management flyout** | `rule_management_ui/components/value_lists_management_flyout/` | Lists plugin |

### 9.2 Public client API helpers

`public/detection_engine/rule_management/api/api.ts` is the single client-side
HTTP wrapper used by all hooks. It targets the URL constants from
`common/constants.ts`:

| Constant | Path |
|----------|------|
| `DETECTION_ENGINE_RULES_URL` | `/api/detection_engine/rules` (POST/PUT/PATCH/DELETE/GET) |
| `DETECTION_ENGINE_RULES_URL_FIND` | `/api/detection_engine/rules/_find` |
| `DETECTION_ENGINE_RULES_BULK_ACTION` | `/api/detection_engine/rules/_bulk_action` |
| `DETECTION_ENGINE_RULES_PREVIEW` | `/api/detection_engine/rules/preview` |
| `DETECTION_ENGINE_RULES_IMPORT_URL` | `/api/detection_engine/rules/_import` |
| `DETECTION_ENGINE_RULES_URL_HISTORY` | `/api/detection_engine/rules/_history` |
| `RULE_MANAGEMENT_FILTERS_URL` | `/internal/detection_engine/rules/_filters` |
| `RULE_MANAGEMENT_COVERAGE_OVERVIEW_URL` | `/internal/detection_engine/rules/coverage_overview` |
| Prebuilt | `BOOTSTRAP_PREBUILT_RULES_URL`, `GET_PREBUILT_RULES_STATUS_URL`, `PERFORM_RULE_INSTALLATION_URL`, `PERFORM_RULE_UPGRADE_URL`, `REVERT_PREBUILT_RULES_URL`, `REVIEW_RULE_*` |

### 9.3 Key React state / context

- `RulesTableContext` (`rule_management_ui/components/rules_table/rules_table/rules_table_context.tsx`)
  — page-scoped state: filters, pagination, selection, sort, persisted to URL via
  `use_sync_rules_table_saved_state.ts`.
- `useFindRules` — paginated, debounced, query-aware listing with refresh.
- `useRule` / `useRuleWithFallback` — single-rule fetcher with
  fallback to query-by-`rule_id` for prebuilt navigation.

### 9.4 Diagram — Edit-rule UI flow

```
  Rules table row
        │
        ▼
  Click "Edit" / route to /rules/id/{id}/edit
        │
        ▼
  rule_creation_ui/pages/rule_editing/index.tsx
        │   useRule(id)        → GET /rules?id=...
        │   form.tsx           ← prefill from RuleResponse
        ▼
  StepDefineRule → StepAboutRule → StepScheduleRule → StepRuleActions
        │   (validators in rule_creation_ui/validators/)
        ▼
  Submit → useUpdateRule()
        │
        ▼
  PUT /api/detection_engine/rules
        │   buildRouteValidationWithZod(RuleUpdateProps)
        ▼
  IDetectionRulesClient.updateRule(...)
        │   getRuleByIdOrRuleId
        │   validateNonCustomizableUpdateFields
        │   applyRuleUpdate (mergers/)
        │   if onlyReadAuthFields → updateReadAuthEditRuleFields
        │   else                  → rulesClient.update(...)
        │   recompute rule_source (calculateRuleSource)
        ▼
  RulesClient (alerting) → SavedObjectsClient
        │
        ▼
  Refresh rule details page → execution summary picked up from Event Log
```

---

## 10. Bulk Actions

> **In plain terms:** One endpoint to do *anything* to a batch of rules —
> enable/disable hundreds, edit a tag across them, schedule a backfill,
> export, delete, duplicate, fill gaps. Selection can be by explicit id list
> or by KQL query (so you can edit "all KQL rules tagged Linux" without
> listing them client-side). Every destructive action supports **dry-run**
> first, so the UI can warn you which rules would fail (ML auth, prebuilt
> restrictions, type incompatibilities, etc.) *before* you commit.

The single bulk endpoint handles all multi-rule operations.

`POST /api/detection_engine/rules/_bulk_action` — defined in
`server/lib/detection_engine/rule_management/api/rules/bulk_actions/route.ts`,
schemas in
`common/api/detection_engine/rule_management/bulk_actions/bulk_actions_route.gen.ts`.

### 10.1 Action enum

The two enums below are the API surface. `BulkActionType` says *what kind of
operation* (enable, edit, run, …); when the operation is `'edit'`, the body
also carries one or more `BulkActionEditType` payloads describing *which
fields* to change (tags, schedule, index patterns, …).

```249:282:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/rule_management/bulk_actions/bulk_actions_route.gen.ts
export const BulkActionType = z.enum([
  'enable',
  'disable',
  'export',
  'delete',
  'duplicate',
  'edit',
  'run',         // manually run a rule for a custom backfill range
  'fill_gaps',   // schedule backfills for detected gaps
]);
…
export const BulkActionEditType = z.enum([
  'add_tags','delete_tags','set_tags',
  'add_index_patterns','delete_index_patterns','set_index_patterns',
  'set_timeline',
  'add_rule_actions','set_rule_actions',
  'set_schedule',
  'add_investigation_fields','delete_investigation_fields','set_investigation_fields',
  'delete_alert_suppression','set_alert_suppression','set_alert_suppression_for_threshold',
]);
```

### 10.2 Selection model

Bulk requests pick rules either by:

- `ids: string[]` — explicit rule UUIDs (capped at `RULES_TABLE_MAX_PAGE_SIZE`)
- or `query: string` — KQL/text query (capped at `MAX_RULES_TO_BULK_EDIT = 2000`,
  total cap `MAX_RULES_TO_PROCESS_TOTAL = 10000`)

…plus optional `gaps_range_start`, `gaps_range_end`, `gap_fill_statuses[]`
to narrow selection by rule execution gaps (used by `fill_gaps`).

`fetchRulesByQueryOrIds.ts` (same folder) materialises the rule set.

### 10.3 Server-side dispatch

The handler routes to one of several internal services:

| Action | Server module | Notes |
|--------|--------------|-------|
| `enable`/`disable` | `bulk_enable_disable_rules.ts` | Uses `rulesClient.bulkEnable/Disable` |
| `delete` | inline | `rulesClient.bulkDelete` |
| `duplicate` | `logic/actions/duplicate_rule.ts` + `duplicate_exceptions.ts` | Optionally clones associated rule-default exception list |
| `export` | `logic/export/get_export_by_object_ids.ts` | Streams NDJSON |
| `edit` | `logic/bulk_actions/bulk_edit_rules.ts` | Splits payload into attribute vs param edits, calls `rulesClient.bulkEdit` with operations from `action_to_rules_client_operation.ts`, recomputes `rule_source` |
| `run` | `bulk_schedule_rule_run.ts` (`bulkScheduleBackfill`) | Schedules an `ad_hoc_run_params` task for a chosen range |
| `fill_gaps` | `bulk_schedule_rule_gap_filling.ts` (`bulkScheduleRuleGapFilling`) | Discovers gaps from Event Log and schedules backfills |

Concurrency:
- `MAX_RULES_TO_UPDATE_IN_PARALLEL` per-rule worker pool via `initPromisePool`
- Route concurrency capped to `MAX_ROUTE_CONCURRENCY = 5` via `routeLimitedConcurrencyTag`
- Long socket timeout via `RULE_MANAGEMENT_BULK_ACTION_SOCKET_TIMEOUT_MS`

### 10.4 Dry-run

The route supports a **dry_run=true** query parameter:
- `dryRunValidateBulkEditRule` / `validateBulkDuplicateRule` are run per rule,
- no writes happen; the response shape mirrors a real run with per-rule
  `succeeded` / `skipped` / `failed` lists
- the UI surfaces this through `use_bulk_actions_dry_run.ts` and the
  `bulk_action_dry_run_confirmation.tsx` modal (with limit-error and
  duplicate-exceptions confirmation modals layered on top).

### 10.5 UI surface for bulk actions

`public/detection_engine/rule_management_ui/components/rules_table/bulk_actions/`

| File | Role |
|------|------|
| `use_bulk_actions.tsx` | Top-level menu binding for all bulk actions on selected rows |
| `use_bulk_actions_confirmation.ts` | Generic confirmation modal control |
| `use_bulk_actions_dry_run.ts` | Issues a dry-run before showing the edit form |
| `use_bulk_edit_form_flyout.ts` | Edit-flyout state machine |
| `bulk_edit_flyout.tsx` | The main flyout shown for `edit` actions |
| `forms/` | Per-edit-action form (`edit_tags`, `edit_index_patterns`, `edit_rule_actions`, `edit_schedule`, `edit_investigation_fields`, `edit_alert_suppression`, …) |
| `bulk_action_dry_run_confirmation.tsx` | Pre-flight error/warning modal |
| `bulk_action_rule_errors_list.tsx` | Toast/flyout listing per-rule failures |
| `bulk_duplicate_exceptions_confirmation.tsx` | Asks whether to copy exceptions when duplicating |
| `bulk_edit_delete_alert_suprression_confirmation.tsx` | Confirmation for destructive suppression edits |
| `bulk_manual_rule_run_limit_error_modal.tsx` | Limit error for `run` action |
| `bulk_schedule_gap_fills_rule_limit_error_modal.tsx` | Limit error for `fill_gaps` |

### 10.6 Diagram — Bulk Edit flow

```
  Rules table → select N rows → "Bulk actions" menu
        │
        ▼
  use_bulk_actions.tsx → choose "Edit ▶ Set tags / Add index patterns / …"
        │
        ▼
  use_bulk_actions_dry_run (POST _bulk_action?dry_run=true)
        │  – validates each rule (ML auth, prebuilt restrictions, type compat)
        ▼
  bulk_edit_flyout.tsx (forms/)  ← shows summary + per-rule warnings
        │
        ▼  user submits
  POST /api/detection_engine/rules/_bulk_action
        │  body: { action: 'edit', edit: [<BulkActionEditPayload>], ids|query }
        ▼
  bulk_actions/route.ts
        │  validateBulkAction        (selection / gap params)
        │  checkAlertSuppressionBulkEditSupport
        │  fetchRulesByQueryOrIds
        ▼
  bulk_edit_rules.ts
        │  splitBulkEditActions → { attributesActions, paramsActions }
        │  fetch base versions of any prebuilt rules in the set
        │  rulesClient.bulkEdit({
        │     operations: bulkEditActionToRulesClientOperation(...),
        │     paramsModifier: ruleParamsModifier(...),
        │  })
        │  recompute rule_source per edited prebuilt rule
        ▼
  buildBulkResponse(): { attributes: { results: { updated, created, deleted, skipped, …}, errors }}
        ▼
  UI toasts / `bulk_action_rule_errors_list` flyout for failures
```

---

## 11. Rule Exceptions

> **In plain terms:** An exception is a "yes-but-not-this" condition: the
> rule's query matches, but you don't want an alert because of an
> exception list entry (e.g. "ignore this hash, it's our internal tool").
> Exceptions are stored separately from rules — they live in the `lists`
> plugin as their own Saved Objects. Rules just hold *references* to lists.
> At run time, the security wrapper loads the items, turns them into an
> Elasticsearch `must_not` clause, and combines that with the rule's own
> query. Net effect: the matching documents are silently filtered out
> *before* an alert is raised.

Exceptions are conditions that **prevent a rule from raising an alert** even if
its query matches. They live in the `lists` plugin and are *referenced* by
detection rules through `exceptions_list[]`.

### Why a separate plugin? (mental model)

Three different audiences use exception lists, so the data model has to
serve all of them:

- **Detection engineers** add per-rule exceptions ("don't alert on this
  process when run by this user") via the rule details page.
- **Endpoint security** treats `endpoint_*`-typed lists as policy artefacts
  pushed to agents (trusted apps, blocklists, host-isolation exemptions).
- **Shared exception management** lets a list be reused by *many* rules.

A single `lists` plugin, two SO types, and one mapping (`combinedMappings`)
covers all three. Detection rules just point at lists and never own the items.

### 11.1 Where exception data lives

- Plugin: `x-pack/solutions/security/plugins/lists/`
- SO types (registered in `lists/server/saved_objects/exception_list.ts`):
  - **`exception-list`** — namespace-aware (`multiple-isolated`)
  - **`exception-list-agnostic`** — shared across spaces (used by Endpoint)
- Both share the same mapping file (`combinedMappings`) — the column `list_type`
  switches between "list container" (`'list'`) and "list item" (`'item'`).
- Both are persisted in the **`.kibana_security_solution`** SO index (set via
  `indexPattern: SECURITY_SOLUTION_SAVED_OBJECT_INDEX`).
- Notable mapped fields: `list_id`, `item_id`, `name`, `description`, `tags`,
  `type`, `entries` (nested: `field`, `operator`, `type`, `value`, optional
  `list` ref for value-list/big-list entries), `comments[]`, `os_types[]`,
  `expire_time`, `tie_breaker_id`, `immutable`, `version`.

### 11.2 Exception list `type` enum (where the list is used)

```687:696:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/common_attributes.gen.ts
export const ExceptionListType = z.enum([
  'detection',
  'rule_default',
  'endpoint',
  'endpoint_trusted_apps',
  'endpoint_trusted_devices',
  'endpoint_events',
  'endpoint_host_isolation_exceptions',
  'endpoint_blocklists',
]);
```

The eight values fall into two families:

| Family | Values | What detection rules do with them |
|--------|--------|------------------------------------|
| Detection-engine | `detection`, `rule_default` | Loaded by the security wrapper and turned into a `must_not` filter. |
| Endpoint | `endpoint`, `endpoint_trusted_apps`, `endpoint_trusted_devices`, `endpoint_events`, `endpoint_host_isolation_exceptions`, `endpoint_blocklists` | Endpoint-policy artefacts. **Filtered out** by `getExceptions(...)` for non-endpoint rules to avoid suppressing alerts the analyst actually wants to see. |

Two values you'll see most often:
- **`detection`** — a shared exception list, can be linked from many rules
  (lives in `exception-list` SO; created via "Shared exception list" UI).
- **`rule_default`** — the **per-rule "Rule exceptions" list** auto-created
  the first time the user adds an exception from the rule details page.
  There is at most one `rule_default` list per rule.

### 11.3 The reference on a rule (`RuleExceptionList`)

```704:719:x-pack/solutions/security/plugins/security_solution/common/api/detection_engine/model/rule_schema/common_attributes.gen.ts
export const RuleExceptionList = z.object({
  id: z.string().min(1),
  list_id: z.string().min(1),
  type: ExceptionListType,
  namespace_type: z.enum(['agnostic', 'single']),
});
```

So a `RuleResponse.exceptions_list` is an array of these references, *not* the
items themselves. The items are loaded at execution time.

### 11.4 How exceptions are applied at runtime

Loaded by the security wrapper and turned into an Elasticsearch filter:

```227:242:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/utils/utils.ts
export const getExceptions = async ({
  client,
  lists,
  shouldFilterOutEndpointExceptions,
}: { client: ExceptionListClient; lists: ListArray; shouldFilterOutEndpointExceptions: boolean; }) => {
  return withSecuritySpan('getExceptions', async () => {
    const filteredLists = shouldFilterOutEndpointExceptions
      ? lists.filter(({ list_id }) => !(ENDPOINT_ARTIFACT_LIST_IDS as readonly string[]).includes(list_id))
      : lists;
    …
    await client.findExceptionListsItemPointInTimeFinder({ … });
```

Then `buildExceptionFilter` (from `@kbn/lists-plugin/server/services/exception_lists`)
converts the items into an ES query filter that is **inverted** ("must_not") and
combined with the rule's main query in `get_filter.ts` / `get_query_filter.ts`.

### 11.5 Detection-engine-side endpoints

Routes under
`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_exceptions/api/`:

| Endpoint | URL | Purpose |
|----------|-----|---------|
| Create rule exceptions | `POST /api/detection_engine/rules/{id}/exceptions` | Adds items to a rule's `rule_default` list (creates one if needed) |
| Create shared exceptions list | `POST /api/exception_lists/_shared` (under `EXCEPTIONS_PATH`) | Creates a shared `detection` list |
| Find exception references | `GET /api/detection_engine/rules/_exceptions_referenced` | Reverse lookup: which rules reference a given exception list |

The lists plugin itself owns the bulk of the CRUD endpoints (under
`/api/exception_lists`).

### 11.6 UI

`public/detection_engine/rule_exceptions/components/rule_details/` provides the
"Rule exceptions" / "Endpoint exceptions" tabs on the rule details page.
Item editing uses the **`@kbn/securitysolution-list-utils`** builder
(`ExceptionsBuilderExceptionItem`). The flag
`endpointExceptionsMovedUnderManagement` (§14) hides the Endpoint tab from the
rule pages when set.

### 11.7 Diagram — Exception list relationship

```
                Detection rule (SO type 'alert', params.exceptionsList[])
                        │ references by { list_id, namespace_type }
                        ▼
               Exception list container (SO 'exception-list' or 'exception-list-agnostic')
                        │  list_type = 'list'
                        │
                        ├─ has many ──▶  Exception list item (same SO type)
                        │                list_type = 'item'
                        │                entries: [ { field, operator, type, value, list? } ... ]
                        │                comments[], os_types[], expire_time, tags
                        │
                        └─ may reference ──▶  Value list (big list of values)
                                              (SO type 'list', SO type 'list-item' for entries)

  At execution time:
     getExceptions(...) → buildExceptionFilter(...)  → inserted as must_not into rule's ES query
```

---

## 12. Prebuilt Detection Rules

> **In plain terms:** Two big ideas to internalise here:
> 1. **"Content" is not the same as "rules running in your space."** The Elastic
>    catalogue of curated detection rules ships through Fleet as inert
>    **content** (the `security-rule` Saved Object). Until you "install" a
>    rule, nothing is scheduled. Installation creates a real `alert` SO
>    flagged `immutable: true` plus `rule_source: { type: 'external', … }`.
> 2. **Upgrades use a three-way diff.** Because users may have customised an
>    installed prebuilt rule, upgrading is not a blind overwrite. The system
>    compares (base, current, target) per field and either auto-merges,
>    flags solvable conflicts, or asks the user to choose. This is the
>    machinery powering the Rule Upgrade flyout.
>
> Result: Elastic can ship rule updates independently of Kibana releases,
> and your customisations are preserved whenever they don't truly conflict
> with the new version.

Prebuilt rules are **immutable rules authored by Elastic**, shipped as a Fleet
package and installed by users on demand. They follow a content-pipeline
distinct from custom rules.

### 12.1 The `security-rule` saved object — the asset

Prebuilt rule **content** is stored as a separate SO type named
`security-rule` (NOT the same as the runtime `alert` SO).

```12:55:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_type.ts
export const PREBUILT_RULE_ASSETS_SO_TYPE = 'security-rule';
…
const securityRuleV3 = schema.object(
  {
    rule_id: schema.string(),
    version: schema.number(),
    name: schema.string(),
    tags: schema.maybe(schema.arrayOf(schema.string(), { maxSize: MAX_TAGS_PER_RULE })),
    severity: schema.maybe(schema.string()),
    risk_score: schema.maybe(schema.number()),
    deprecated: schema.maybe(schema.boolean()),
  },
  { unknowns: 'allow' }
);
```

Notes:
- Mapping is `dynamic: false`; only a few fields are searchable
  (`rule_id`, `version`, `name`, `tags`, `severity`, `risk_score`, `deprecated`).
- Schema model versions: V1 → V2 (queryable name/tags/severity/risk_score
  mappings) → V3 (adds `deprecated` for stub assets used to remove rules).
- `namespaceType: 'agnostic'` — assets are shared across all spaces.
- Stored in **`.kibana_security_solution`** (via `SECURITY_SOLUTION_SAVED_OBJECT_INDEX`).
- Bodies are stored raw (`unknowns: 'allow'`) and validated by the **Zod**
  `PrebuiltRuleAsset` schema when read.

### 12.2 The Zod `PrebuiltRuleAsset` schema (read-side validation)

```42:67:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/model/rule_assets/prebuilt_rule_asset.ts
export const PrebuiltAssetBaseProps = BaseCreateProps.omit(
  BASE_PROPS_REMOVED_FROM_PREBUILT_RULE_ASSET
);
…
export const PrebuiltRuleAsset = PrebuiltAssetBaseProps.and(TypeSpecificCreatePropsInternal).and(
  z.object({
    rule_id: RuleSignatureId,
    version: RuleVersion,
  })
);
```

- Derived from the **same** `BaseCreateProps + TypeSpecificCreatePropsInternal`
  used by the public `RuleCreateProps` API — guarantees a prebuilt asset is
  installable as a real rule.
- Omits user-only fields not present in the elastic/detection-rules repo:
  `actions`, `response_actions`, `throttle`, `meta`, `output_index`,
  `namespace`, `alias_*`, `outcome`.
- `rule_id` and `version` are required (the canonical identity for diffs/upgrades).

### 12.3 Distribution: Fleet package → SO assets

The bundled rules ship in the **`security_detection_engine`** Fleet package.

`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/integrations/`

| File | Purpose |
|------|---------|
| `find_latest_package_version.ts` | Fetches latest `security_detection_engine` version from the Fleet registry |
| `install_prebuilt_rules_package.ts` | Installs/updates the package — SOs are unpacked into `security-rule` |
| `ensure_latest_rules_package_installed.ts` | Bootstrap helper |
| `install_endpoint_package.ts` | Endpoint package + the special endpoint security rule |
| `install_endpoint_security_prebuilt_rule.ts` | Installs the endpoint security rule |
| `install_promotion_rules.ts` | LotL / Data Exfiltration promotion rules |
| `install_ai_prompts.ts` | AI prompts asset installation |

### 12.4 The asset client — read access

```22:36:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/index.ts
export interface IPrebuiltRuleAssetsClient {
  fetchLatestAssets: () => Promise<PrebuiltRuleAsset[]>;
  fetchLatestVersions: (args?: { ruleIds?: string[]; sort?; filter?; }) => Promise<BasicRuleInfo[]>;
  fetchAssetsByVersion(versions: RuleVersionSpecifier[]): Promise<PrebuiltRuleAsset[]>;
  fetchTagsByVersion(versions: RuleVersionSpecifier[]): Promise<string[]>;
  fetchDeprecatedRules(ruleIds?: string[]): Promise<DeprecatedPrebuiltRuleAsset[]>;
}
```

### 12.5 Write path — installing a prebuilt rule

`createPrebuiltRules` iterates assets and delegates to
`detectionRulesClient.createPrebuiltRule({ params: rule })`. The created rule
is a normal SO of type `alert`, but with `immutable: true` and
`rule_source: { type: 'external', is_customized: false, has_base_version: true, customized_fields: [] }`.

### 12.6 Three-way diff for upgrades

`x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/diff/`

`calculateRuleDiff({ current, base, target })` produces a `FullThreeWayRuleDiff`:

- **current** — `RuleResponse` of the installed rule (from the user's space)
- **base** — `PrebuiltRuleAsset` of the version originally installed
- **target** — `PrebuiltRuleAsset` of the version being upgraded to

All three are normalised to `DiffableRule` (via `convertRuleToDiffable` and
`convertPrebuiltRuleAssetToRuleResponse`). `calculateThreeWayRuleFieldsDiff`
runs per-field algorithms (simple string, keyword array, multiline text,
`data_source`, etc.) and produces a `ThreeWayDiff` per field with conflict
status (`ThreeWayDiffConflict`). This drives the **Rule Upgrade flyout** in
the UI (auto-merge vs solvable vs non-solvable).

Per-field outcomes (the four states a user sees in the upgrade UI):

| Per-field state | What happened | UI default |
|-----------------|---------------|-----------|
| **No conflict (target changed only)** | Target updated a field the user didn't touch | Auto-applied |
| **No conflict (current matches target)** | The user already happened to set the value the target wanted | No-op |
| **Solvable conflict** | Both base→current and base→target changed, but in compatible ways (e.g. concatenation, set-union) | Suggested merged value, user can accept |
| **Non-solvable conflict** | Both changed in incompatible ways (e.g. different string contents) | User must pick `current` or `target` |

### 12.7 Prebuilt rules HTTP API

Routes: `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/`

| Route folder | Purpose |
|--------------|---------|
| `bootstrap_prebuilt_rules` | Internal — installs the Fleet package and triggers initial rule install |
| `get_prebuilt_rules_status` | Counts of installed / installable / upgradeable |
| `get_prebuilt_rules_and_timelines_status` | Legacy combined status |
| `get_prebuilt_rule_base_version` | Returns the base version asset for a given installed rule |
| `install_prebuilt_rules_and_timelines` | Legacy install endpoint |
| `perform_rule_installation` | Modern install with selection/version |
| `perform_rule_upgrade` | Upgrade chosen rules to chosen target version |
| `revert_prebuilt_rule` | Revert a customised prebuilt rule back to its base version |
| `review_rule_installation` | Preview what will be installed |
| `review_rule_upgrade` | Preview the three-way diff for upgradeable rules |
| `review_rule_deprecation` | Preview deprecated stubs to be removed |

API DTOs (Zod-generated): `common/api/detection_engine/prebuilt_rules/`

### 12.8 Customization & the `rule_source` field

When prebuilt rule customization is enabled (license-gated), editing an
installed prebuilt rule sets `rule_source.is_customized = true` and lists the
edited fields in `customized_fields[]`. The rule remains `immutable: true` but
tracks divergence from base. Diff and `revertPrebuiltRule` use these flags.

### 12.9 Diagram — Prebuilt rule pipeline

```
  Fleet registry
     │
     ▼  install_prebuilt_rules_package.ts
  Fleet package "security_detection_engine"
     │ (bundled NDJSON of rule assets)
     ▼ unpacked as
  Saved Objects of type 'security-rule'  (PrebuiltRuleAsset shape, V1/V2/V3 model versions)
  in .kibana_security_solution      ────────────────────────────┐
                                                                │ read by
                                                                ▼
   IPrebuiltRuleAssetsClient.fetchLatestAssets/byVersion/...
                                                                │
                                  ┌─────────────────────────────┤
                                  ▼                             ▼
        review_rule_installation (preview)       review_rule_upgrade (3-way diff)
                                  │                             │
                                  ▼                             ▼
        perform_rule_installation                     perform_rule_upgrade
        → IDetectionRulesClient.createPrebuiltRule   → ...upgradePrebuiltRule
                                  │                             │
                                  ▼                             ▼
                          'alert' SO with                'alert' SO updated
                          immutable: true                rule_source.is_customized
                          rule_source: { type:'external',  recalculated
                                         is_customized:false }

        revert_prebuilt_rule   ─── reverts a customised rule back to base version
        review_rule_deprecation── lists deprecated stubs to remove
```

---

## 13. Alerts as Data

> **In plain terms:** When a detection rule finds something, the result is
> written as an Elasticsearch document — not pushed via a notification or
> stored on the rule itself. These alert documents live in
> `.alerts-security.alerts-<space>` indices using a shared field-naming
> convention (`kibana.alert.*` envelope + ECS source fields). This is the
> "**Alerts as Data**" pattern. It's why Cases, the Alerts table, the AI
> Assistant, and external SIEMs can all consume security alerts uniformly.
> The legacy `.siem-signals-<space>` alias still points at the same index for
> backwards compatibility with older queries and dashboards.

Detection rule alerts are written to Elasticsearch via the persistence
wrapper.

- **Primary index**: `.alerts-security.alerts-<namespace>` (e.g. `.alerts-security.alerts-default`)
- **Secondary alias**: `.siem-signals-<namespace>` (legacy, configurable via `signalsIndex`, default `.siem-signals`)
- **Preview**: `.preview.alerts-security.alerts-<namespace>` (no secondary alias on preview)
- **Context**: `security` (shared across all detection rule types)

`securityRuleTypeFieldMap` (defined in `create_security_rule_type_wrapper.ts`)
is the merged mapping registered through the rule type's `alerts.fieldMap`:

```85:90:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts
export const securityRuleTypeFieldMap = {
  ...technicalRuleFieldMap,   // from @kbn/rule-registry-plugin
  ...alertsFieldMap,          // common/field_maps/9.3.0/
  ...rulesFieldMap,           // common/field_maps/8.0.0/rules.ts
  ...aliasesFieldMap,         // signal_aad_mapping.json — legacy aliases
};
```

Why four merged maps? Each contributes a different layer of the alert document:

| Map | Comes from | Adds |
|-----|------------|------|
| `technicalRuleFieldMap` | `@kbn/rule-registry-plugin` | The platform "envelope" — `kibana.alert.uuid`, `kibana.alert.rule.uuid`, `kibana.alert.status`, `kibana.alert.workflow_status`, etc. Required for cross-domain features (Cases, Alerts table). |
| `alertsFieldMap` | `common/field_maps/9.3.0/` | Security-specific alert fields — entities, threat fields, suppression metadata, building-block markers, threshold/eql metadata. |
| `rulesFieldMap` | `common/field_maps/8.0.0/rules.ts` | A *snapshot* of the rule at alert time under `kibana.alert.rule.*` (so an alert is self-describing — you don't need a rule lookup to render it). |
| `aliasesFieldMap` | `signal_aad_mapping.json` | Field aliases from the legacy `signal.*` namespace to the new `kibana.alert.*` fields, so pre-AAD KQL queries and saved searches keep working. |

Field map locations:
- `x-pack/solutions/security/plugins/security_solution/common/field_maps/9.3.0/`
- `x-pack/solutions/security/plugins/security_solution/common/field_maps/8.0.0/rules.ts`
- `x-pack/solutions/security/plugins/security_solution/common/field_maps/index.ts`

Configuration constants: `SIGNALS_INDEX_KEY = 'signalsIndex'`,
`DEFAULT_SIGNALS_INDEX = '.siem-signals'` in
`x-pack/solutions/security/plugins/security_solution/server/config.ts`.

> **What does an alert document look like?** A minimal example:
>
> ```json
> {
>   "@timestamp": "2026-04-18T10:23:11.123Z",
>   "kibana.alert.uuid": "1c9d…",
>   "kibana.alert.status": "active",
>   "kibana.alert.rule.uuid": "<rule SO id>",
>   "kibana.alert.rule.rule_id": "<stable rule_id>",
>   "kibana.alert.rule.name": "Failed logins burst",
>   "kibana.alert.rule.severity": "medium",
>   "kibana.alert.original_event": { "...": "..." },
>   "host.name": "web-01",
>   "user.name": "alice"
> }
> ```
>
> The `kibana.alert.*` fields come from `technicalRuleFieldMap` +
> `rulesFieldMap`; everything else is ECS source data copied from the
> matching event (so the alert remains queryable with normal ECS).

---

## 14. Persistence in Elasticsearch (the full picture)

> **In plain terms:** A working detection engine writes to *six* different
> kinds of Elasticsearch storage, each tuned for a very different
> read/write pattern. It helps to keep them separate in your head:
>
> - **Rule config** (the rule itself, scheduled tasks) → `.kibana_*` SO indices
> - **Rule content catalogue** (prebuilt rule assets, exception lists) → `.kibana_security_solution`
> - **Schedules** (one per running rule) → `.kibana_task_manager`
> - **Alerts the rules find** → `.alerts-security.alerts-<space>`
> - **Execution audit / metrics** → `.kibana-event-log-*`
> - **Big value lists** referenced by exceptions → `lists` / `list-items` ES indices
>
> Each lives in its own index because each has a wildly different read
> pattern (single-doc vs bulk write, frequent vs rare, encrypted vs not,
> per-space vs space-agnostic).

There are **three distinct categories of data** persisted by the detection
engine, each in its own ES index family:

### 14.1 The "Saved Object" indices (configuration)

All Kibana SO indices live in `.kibana*`. The detection engine touches three of
them:

| SO type | Owning index alias | Visibility | Purpose |
|---------|--------------------|------------|---------|
| `alert` (constant `RULE_SAVED_OBJECT_TYPE`) | `.kibana_alerting_cases` | hidden, multi-isolated | The runnable rule (one per detection rule). Stores: `name`, `enabled`, `tags`, `alertTypeId` (`siem.queryRule`/…), `consumer` (`'siem'`), `schedule`, `actions[]`, **`params`** (the type-specific parameters: query, index, threshold, …, plus `ruleId`/`immutable`/`ruleSource`/`exceptionsList`/`maxSignals`), `apiKey` (encrypted), `notifyWhen`, `throttle`, `meta`, `mappedParams`. **Encrypted attributes**: `apiKey`, `uiamApiKey`. AAD includes most static fields (see `RuleAttributesIncludedInAAD`). |
| `security-rule` (`PREBUILT_RULE_ASSETS_SO_TYPE`) | `.kibana_security_solution` | not hidden, agnostic, model versions V1→V3 | Prebuilt rule **content** assets, one document per `(rule_id, version)`. |
| `exception-list` & `exception-list-agnostic` | `.kibana_security_solution` | not hidden, multi-isolated / agnostic | Exception list containers and items (distinguished by `list_type`). |

Plus the platform's own:

| | |
|--|--|
| `.kibana_task_manager` | Holds the `task` SO that schedules each rule run (`taskType: 'alerting:siem.queryRule'` etc.). |
| `.kibana_alerting_cases` | Also holds `ad_hoc_run_params` SOs (used by `bulk run` and `fill_gaps`). |
| `.kibana-event-log-*` data stream | Audit trail of every rule execution: outcome, duration, gaps (when `storeGapsInEventLogEnabled`), warnings/errors. Source for `execution_summary`. |

Index pattern constants:
- `MAIN_SAVED_OBJECT_INDEX = '.kibana'`
- `ALERTING_CASES_SAVED_OBJECT_INDEX = '.kibana_alerting_cases'`
- `SECURITY_SOLUTION_SAVED_OBJECT_INDEX = '.kibana_security_solution'`
- `TASK_MANAGER_SAVED_OBJECT_INDEX = '.kibana_task_manager'`

(See `src/core/packages/saved-objects/server/src/saved_objects_index_pattern.ts`.)

### 14.2 The "Alerts as Data" indices (security alerts)

Created by `RuleDataService.initializeIndex()` at setup, written to per
execution by `alertWithPersistence()` from the persistence wrapper.

| Component | Value |
|-----------|-------|
| Context | `security` |
| Index template name | `.alerts-security.alerts` |
| Backing index pattern | `.alerts-security.alerts-default-<NNNNNN>` |
| Read alias (per space) | `.alerts-security.alerts-<namespace>` |
| Secondary alias | `.siem-signals-<namespace>` (controlled by `xpack.securitySolution.signalsIndex`) |
| Preview alias | `.preview.alerts-security.alerts-<namespace>` (no secondary alias) |
| ILM | Managed by the framework; rollovers tracked via `kibana.alert.rule.execution.uuid`/`kibana.version` |
| Field map | `securityRuleTypeFieldMap` (see §12) |

### 14.3 The "Exception list value lists" indices (lists plugin)

The lists plugin can also create `lists` and `list_items` ES indices to store
**big value lists** referenced by exception items (e.g. ip ranges, hashes,
domains). These are **regular ES indices** (not SOs) — see the lists plugin
configuration for index names; they are referenced from exception-list-item
entries via `entries[].list = { id, type }`.

### 14.4 Diagram — the persistence map

```
                ┌────────────────────────────────────────────────────────────────────┐
                │                       USER ACTION (UI / API)                       │
                └───────────┬────────────────────────────────┬───────────────────────┘
                            │ create / edit rule              │ add exception
                            ▼                                  ▼
               ┌───────────────────────┐          ┌──────────────────────────────┐
               │  IDetectionRulesClient│          │ exception list client (lists)│
               └─────────┬─────────────┘          └──────────────┬───────────────┘
                         │                                       │
                         ▼                                       ▼
                  RulesClient (alerting)                exception-list[/-agnostic]
                  ┌───────────────────────┐                       │
                  │ SO type 'alert'       │                       │
                  │ params.{type, index,  │                       │
                  │   query, threshold,   │       ┌───────────────┴────────────────┐
                  │   exceptionsList,     │       │  exception-list (containers)   │
                  │   ruleSource, ...}    │       │  exception-list (items)        │
                  │ apiKey (encrypted)    │       │  list_type ∈ {'list', 'item'}  │
                  └─────────┬─────────────┘       └────────────────┬───────────────┘
                            │                                      │
                            ▼                                      ▼
            .kibana_alerting_cases               .kibana_security_solution
                            │                                      ▲
                            │ schedules                            │
                            ▼                                      │
                  Task Manager task SO                             │
                  ┌──────────────────────┐                         │
                  │ taskType:            │                         │
                  │   'alerting:siem.*'  │                         │
                  └─────────┬────────────┘                         │
                            │                                      │
                            ▼ runs                                 │
                  Task Runner → SecurityRuleTypeWrapper            │
                            │ pre-execution loads exceptions  ◀────┘
                            │  (via getExceptions / buildExceptionFilter)
                            ▼
                  Detection executor (eql/esql/query/...)
                            │ ES search
                            ▼ produces alerts via alertsClient.report()
                  Persistence wrapper → RuleDataClient
                            │
                            ▼
                  .alerts-security.alerts-<namespace>     (primary)
                  .siem-signals-<namespace>               (legacy alias)
                            │
                            ▼ post-execution audit
                  .kibana-event-log-*   (rule status, gaps, metrics)
                            │
                            ▼ surfaced as
                  RuleResponse.execution_summary  (on next read)
```

---

## 15. Experimental Feature Flags (Security-Solution-only)

> **In plain terms:** Security Solution has its own private list of "feature
> toggles" that you can flip in `kibana.yml`. They're checked by Security
> code only — the platform alerting framework knows nothing about them.
> This lets the team ship work-in-progress (e.g. ESQL rules behind a flag,
> the bulk gap-fill action, extended execution logging) and ship features
> default-on while still allowing emergency disable. There's a `disable:`
> prefix convention so you can flip a default-true flag off in YAML
> without inverting its name.

Feature flags are **scoped to the Security Solution plugin** and **not visible
to the alerting framework**. Therefore checks must happen in security code
(typically during rule type registration in `plugin.ts` or inside the security
wrapper) before delegating downstream.

- Definitions: `x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts`
  (`allowedExperimentalValues`)
- Parsed in: `.../server/config.ts` (`createConfig`)
- Configured via:

  ```yaml
  xpack.securitySolution.enableExperimental:
    - extendedRuleExecutionLoggingEnabled
    - disable:esqlRulesDisabled  # the "disable:" prefix flips a default-true flag
  ```

- Server access: `config.experimentalFeatures.<flag>` (also passed through the
  `securityContext` to route handlers and into `securityRuleTypeOptions`).
- Client access:
  - `public/common/experimental_features_service.ts` (`ExperimentalFeaturesService.get().<flag>`)
  - `public/common/hooks/use_experimental_features.ts` (`useIsExperimentalFeatureEnabled('flag')`)

Detection-rule-relevant flags:

| Flag | Default | Effect |
|------|---------|--------|
| `extendedRuleExecutionLoggingEnabled` | `false` | Writes execution logs (debug/info/error) to `.kibana-event-log-*`; UI "Execution logs" table |
| `esqlRulesDisabled` | `false` | When `true`, `siem.esqlRule` is **not** registered and ES\|QL preview is disabled |
| `storeGapsInEventLogEnabled` | `true` | Persists detected gap ranges to Event Log |
| `bulkFillRuleGapsEnabled` | `true` | Enables bulk gap-fill API (`fill_gaps` action) |
| `endpointExceptionsMovedUnderManagement` | `false` | Moves endpoint exceptions UI under Management/Assets |
| `siemMigrationsDisabled` | `false` | Disables SIEM migrations feature |
| `entityStoreDisabled` | `false` | Disables entity store routes |

---

## 16. Request Flow (HTTP → ES)

> **In plain terms:** Follow what happens when a user clicks **Save** in the
> rule editor. The request travels through six layers — versioned route →
> Zod validation → Detection Rules Client (mergers + converters) → generic
> RulesClient → SavedObjectsClient (writes the `alert` SO + encrypts the
> API key) → Task Manager (schedules the next run). On the way back out,
> the alerting rule shape is converted *back* to `RuleResponse` and an
> `execution_summary` is attached from the Event Log. Knowing this path is
> what lets you debug "why doesn't my new field appear in the response?"
> (probably missing in `convertAlertingRuleToRuleResponse`) and "why isn't
> my new field validated?" (probably missing in `*.schema.yaml`).

```
  HTTP request (POST /api/detection_engine/rules)
        │
        ▼
  Versioned route in
  …/detection_engine/rule_management/api/rules/{create|update|patch|delete|find|bulk_actions|...}/route.ts
        │  buildRouteValidationWithZod(RuleCreateProps / RuleUpdateProps / RulePatchProps)
        ▼
  IDetectionRulesClient.<method>()  (per request, from RequestContextFactory)
        │
        │  mergers/  – apply_rule_update | apply_rule_patch | apply_rule_defaults
        │              + calculate_rule_source (recompute is_customized)
        │  converters/convert_rule_response_to_alerting_rule.ts
        │     – snake_case → camelCase
        │     – type → alertTypeId via ruleTypeMappings
        │     – action/connector references resolved via ActionsClient
        ▼
  RulesClient (alerting)  → SavedObjectsClient (type: 'alert')
                          → TaskManager.schedule(...)
                          → EventLog (audit)
        │
        ▼
  Response: alerting rule → convertAlertingRuleToRuleResponse → Zod-validated RuleResponse
                          → execution_summary attached from Event Log on read
```

Key files:
- `server/lib/detection_engine/rule_management/api/rules/`
- `server/request_context_factory.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts`

---

## 17. Execution Flow (Task Manager → Alerts)

> **In plain terms:** This is the *runtime* counterpart of §16. Every
> `interval` (e.g. every 5 minutes), Task Manager finds the rule's task,
> hands it to a Task Runner, which decrypts the API key, instantiates the
> rule type wrapper chain, and calls the executor. The executor returns
> candidate alerts; the persistence wrapper bulk-writes them to the
> alerts-as-data index; the security wrapper records the outcome in the
> Event Log. Nothing in this flow is "real-time" — alerts have a latency of
> at most one rule interval, and may be delayed further if Task Manager is
> busy or if the rule is slow.

```
  TaskManager  (schedule.interval e.g. "5m")
       │
       ▼
  TaskRunner
   x-pack/platform/plugins/shared/alerting/server/task_runner/
       │
       ▼
  PersistenceRuleTypeWrapper  (provides alertWithPersistence(), bulk indexing via RuleDataClient)
   x-pack/platform/plugins/shared/rule_registry/server/utils/create_persistence_rule_type_wrapper.ts
       │
       ▼
  SecurityRuleTypeWrapper      (pre / per-tuple / post)
       │  pre-execution: data view, privileges, timestamps, frozen indices, gaps,
       │                 exceptions (getExceptions + buildExceptionFilter)
       │  per tuple → DETECTION RULE EXECUTOR (eql/esql/query/threshold/ml/indicator/new_terms)
       │              → ES query via scopedClusterClient
       │              → process results, apply alert suppression
       │              → alertsClient.report(...)
       │  post-execution: log status, telemetry, gap storage, warnings/errors
       ▼
  RuleDataClient → ES
        .alerts-security.alerts-<namespace>     (primary)
        .siem-signals-<namespace>               (legacy alias)
        .kibana-event-log-*                     (audit / execution summary)
```

---

## 18. Key Files Index

### Security Solution plugin
- Plugin entry: `x-pack/solutions/security/plugins/security_solution/server/plugin.ts`
- Plugin contract types: `.../server/plugin_contract.ts`
- Server config: `.../server/config.ts`
- Saved objects init: `.../server/saved_objects.ts`
- Constants (URLs, limits): `.../common/constants.ts`
- Experimental features: `.../common/experimental_features.ts`

### Detection rule types (executors)
- Wrapper: `.../server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts`
- Executors: `.../server/lib/detection_engine/rule_types/{eql,esql,query,threshold,ml,indicator_match,new_terms}/`
- Utils (`getExceptions`, `getInputIndex`, query builders): `.../server/lib/detection_engine/rule_types/utils/`

### Rule Management — server
- Routes: `.../server/lib/detection_engine/rule_management/api/rules/{create_rule,update_rule,patch_rule,delete_rule,read_rule,find_rules,bulk_actions,export_rules,import_rules,filters,coverage_overview,rule_history}/`
- Detection Rules Client: `.../rule_management/logic/detection_rules_client/{detection_rules_client_interface.ts, detection_rules_client.ts, methods/, converters/, mergers/, mergers/rule_source/}`
- Bulk actions logic: `.../rule_management/logic/bulk_actions/{bulk_edit_rules.ts, action_to_rules_client_operation.ts, rule_params_modifier.ts, split_bulk_edit_actions.ts, validations.ts, dry_run.ts, check_alert_suppression_bulk_edit_support.ts}`
- Other logic dirs: `actions/`, `crud/`, `detection_rules_client/`, `exceptions/`, `export/`, `history/`, `import/`, `search/`

### Rule Management — UI
- Pages: `public/detection_engine/rule_management_ui/pages/{rule_management,add_rules,coverage_overview}/`
- Rules table: `public/detection_engine/rule_management_ui/components/rules_table/`
- Bulk actions UI: `.../components/rules_table/bulk_actions/`
- Rule details: `public/detection_engine/rule_details_ui/pages/rule_details/`
- Rule create/edit wizard: `public/detection_engine/rule_creation_ui/pages/{rule_creation,rule_editing}/`
- Public client API: `public/detection_engine/rule_management/api/api.ts`
- Hooks: `public/detection_engine/rule_management/{hooks,logic}/`

### Prebuilt rules
- SO type: `.../server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_type.ts`
- Asset Zod schema: `.../prebuilt_rules/model/rule_assets/prebuilt_rule_asset.ts`
- Asset client: `.../prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/index.ts`
- Rule object writers: `.../prebuilt_rules/logic/rule_objects/{create,upgrade,revert}_prebuilt_rules.ts`
- Diff: `.../prebuilt_rules/logic/diff/calculate_rule_diff.ts` + `calculation/`
- Fleet integration: `.../prebuilt_rules/logic/integrations/`
- Routes: `.../prebuilt_rules/api/`
- Public API DTOs: `common/api/detection_engine/prebuilt_rules/`

### Rule Exceptions
- Detection-engine routes: `.../server/lib/detection_engine/rule_exceptions/api/{create_rule_exceptions, find_exception_references, create_shared_exceptions_list}/`
- Lists plugin: `x-pack/solutions/security/plugins/lists/server/`
  - SO definitions: `lists/server/saved_objects/exception_list.ts`, `lists/server/saved_objects/migrations.ts`
  - Service: `lists/server/services/exception_lists/{exception_list_client.ts, build_exception_filter.ts, ...}`
- UI: `public/detection_engine/rule_exceptions/components/rule_details/`
- Builder utils: `x-pack/solutions/security/packages/kbn-securitysolution-list-utils/`
- Endpoint exceptions UI (separate): `public/detection_engine/endpoint_exceptions/`

### Zod rule schemas
- OpenAPI specs: `common/api/detection_engine/model/rule_schema/*.schema.yaml`
- Generated Zod: `common/api/detection_engine/model/rule_schema/*.gen.ts`
- Common attributes: `.../rule_schema/common_attributes.gen.ts` (incl. `RuleSource`, `ExceptionListType`, `RuleExceptionList`)
- Specific attributes: `.../rule_schema/specific_attributes/{eql,threshold,threat_match,ml,new_terms}_attributes.gen.ts`
- Bulk actions schema: `common/api/detection_engine/rule_management/bulk_actions/bulk_actions_route.{schema.yaml,gen.ts,types.ts}`
- Exception list schema (rule-side): `common/api/detection_engine/rule_exceptions/`
- Mocks/tests: `rule_request_schema.test.ts`, `rule_response_schema.test.ts`, `*.mock.ts`
- Schedule helper (non-generated): `.../rule_schema/{rule_schedule.ts, time_duration.ts}`

### Rule type constants
- `src/platform/packages/shared/kbn-securitysolution-rules/src/rule_type_constants.ts`
- `src/platform/packages/shared/kbn-securitysolution-rules/src/rule_type_mappings.ts`

### Alerting framework (platform)
- Plugin: `x-pack/platform/plugins/shared/alerting/server/plugin.ts`
- SO registration: `.../server/saved_objects/index.ts` (`RULE_SAVED_OBJECT_TYPE = 'alert'`, `RuleAttributesToEncrypt`, `RuleAttributesIncludedInAAD`)
- RuleTypeRegistry: `.../server/rule_type_registry.ts`
- RulesClientFactory: `.../server/rules_client_factory.ts`
- RulesClient (incl. `bulkEdit`, `bulkEnable/Disable`): `.../server/rules_client/rules_client.ts`
- Task Runner: `.../server/task_runner/task_runner.ts`
- AlertsService: `.../server/alerts_service/alerts_service.ts`

### Rule registry (platform)
- Persistence wrapper: `x-pack/platform/plugins/shared/rule_registry/server/utils/create_persistence_rule_type_wrapper.ts`
- Rule data client: `.../server/rule_data_client/rule_data_client.ts`

### Field maps (alerts-as-data)
- `common/field_maps/9.3.0/` (alerts)
- `common/field_maps/8.0.0/rules.ts` (rule metadata)
- `common/field_maps/index.ts`

### SO index name constants
- `src/core/packages/saved-objects/server/src/saved_objects_index_pattern.ts`

### Other
- `@kbn/zod` v4: `src/platform/packages/shared/kbn-zod/` — every `*.gen.ts` imports from `@kbn/zod/v4`
- OpenAPI generator: `@kbn/openapi-generator` — runs over `*.schema.yaml` to emit `*.gen.ts`
- Zod route helpers: `@kbn/zod-helpers/v4` — `buildRouteValidationWithZod`

---

## 19. Cheat-sheet — "If I want to…"

| Goal | Where to look |
|------|----------------|
| Add a new detection rule type | Folder under `server/lib/detection_engine/rule_types/<type>/`; register in `plugin.ts`; add ID in `kbn-securitysolution-rules`; add Zod attributes + schemas in `common/api/detection_engine/model/rule_schema/` |
| Change a rule's API shape | Edit `*.schema.yaml`, regenerate `*.gen.ts` via OpenAPI generator, update mergers/converters/methods if needed |
| Add a new bulk action | Add to `BulkActionType` (or sub-action to `BulkActionEditType`) in `bulk_actions_route.schema.yaml`, regenerate, then dispatch in `bulk_actions/route.ts` and add UI form under `rules_table/bulk_actions/forms/` |
| Add a new prebuilt-rule API | Folder under `prebuilt_rules/api/`, register in `register_routes.ts`, add DTOs under `common/api/detection_engine/prebuilt_rules/` |
| Modify what fields participate in upgrade diffs | `prebuilt_rules/logic/diff/calculation/` and the diffable mappings |
| Change alerts-as-data fields | Field maps under `common/field_maps/`, then bump the version folder |
| Gate a feature behind a flag | Add to `allowedExperimentalValues` in `common/experimental_features.ts`; check via `experimentalFeatures.<name>` (server) or `useIsExperimentalFeatureEnabled` (client) |
| Tweak rule pre/post-execution behaviour | `create_security_rule_type_wrapper.ts` |
| Inspect what runs on each schedule tick | `x-pack/platform/plugins/shared/alerting/server/task_runner/task_runner.ts` then the wrappers above |
| Change exception evaluation | `lists/server/services/exception_lists/build_exception_filter.ts` and `rule_types/utils/{utils.ts → getExceptions, get_filter.ts, get_query_filter.ts}` |
| Add a new rule-edit field with read-only RBAC | `mergers/apply_rule_update.ts` + `methods/rbac_methods/update_rule_with_read_privileges.ts` |
| Investigate why a rule isn't firing | Rule details page → Execution log table; inspect `.kibana-event-log-*`; check `rule.params.exceptionsList` and `RuleSource.is_customized`; inspect `.alerts-security.alerts-<ns>` for documents |

---

## 20. Summary

- Detection rules are **security-domain rules** that compose three layers:
  the platform **alerting** plugin (scheduling + persistence of `alert` SOs),
  the **rule_registry** plugin (alerts-as-data persistence helper), and the
  **security_solution** plugin (executors per rule type, security wrapper,
  `IDetectionRulesClient`, prebuilt rule lifecycle, Zod schemas, routes, UI).
- The eight rule types (`eql`, `esql`, `query`, `saved_query`, `threshold`,
  `threat_match`, `machine_learning`, `new_terms`) map to `siem.*` IDs declared
  in `kbn-securitysolution-rules`.
- All wire-format shapes are **Zod v4** schemas generated from OpenAPI YAML
  (`*.schema.yaml` → `*.gen.ts`), composed from common attribute schemas plus
  type-specific attribute schemas, exposed as
  `RuleCreateProps` / `RuleUpdateProps` / `RulePatchProps` / `RuleResponse`
  unions backed by a `z.discriminatedUnion('type', […])`.
- A **`RuleResponse`** carries identity (`id`, `rule_id`, `revision`,
  `version`), audit (`created_*`, `updated_*`), origin
  (`immutable` + `rule_source` discriminated union of `internal`/`external`),
  the full set of common attributes, the type-specific fields, and a
  derived `execution_summary` from the Event Log.
- **Rule management** in the UI is centred on the rules table page
  (`rule_management_ui/pages/rule_management/`) plus a multi-step wizard
  shared between create (`rule_creation`) and edit (`rule_editing`). All
  client traffic flows through `public/detection_engine/rule_management/api/api.ts`.
- **Bulk actions** go through the single endpoint
  `POST /api/detection_engine/rules/_bulk_action` with selection by `ids` or
  `query`, supporting `enable/disable/export/delete/duplicate/edit/run/fill_gaps`
  plus a rich `BulkActionEditType` for granular field edits, with dry-run
  support and a confirmation/flyout UI under
  `rules_table/bulk_actions/`.
- **Rule exceptions** live in the **lists plugin**
  (`x-pack/solutions/security/plugins/lists/`) as `exception-list` /
  `exception-list-agnostic` SOs, both stored in `.kibana_security_solution`
  with a shared mapping switched by `list_type`. Detection rules **reference**
  them via `exceptions_list[]` (`RuleExceptionList` schema). At execution time
  the security wrapper loads items via `getExceptions` and `buildExceptionFilter`
  and inverts them into the rule's ES query.
- **Prebuilt rules** are content shipped via the Fleet package
  `security_detection_engine`, persisted as `security-rule` saved objects
  (separate from runtime `alert` SOs), validated with the Zod
  `PrebuiltRuleAsset` schema (a strict subset of `BaseCreateProps +
  TypeSpecificCreatePropsInternal`). They are installed/upgraded/reverted
  through `IDetectionRulesClient`; a three-way diff drives the upgrade UI.
- **Persistence** spans three index families: SO indices
  (`.kibana_alerting_cases` for `alert`/`ad_hoc_run_params`,
  `.kibana_security_solution` for `security-rule`/`exception-list*`,
  `.kibana_task_manager` for schedules), alerts-as-data
  (`.alerts-security.alerts-<ns>` with legacy `.siem-signals-<ns>` alias),
  and the Event Log data stream `.kibana-event-log-*` (execution audit).
- **Experimental feature flags** are scoped to `xpack.securitySolution.*` and
  are checked exclusively in security_solution code.
