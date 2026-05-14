# CODEOWNERS Quick Wins — Reducing PR Review Load on `@elastic/security-detection-rule-management`

## Baseline (files owned)

Output of `./analyse_codeowners.py @elastic/security-detection-rule-management`:

```
Fully owned (only this team): 1900
Shared with other teams:       357
Total owned:                  2257
```

The team currently appears as an owner on **53 lines** in `.github/CODEOWNERS`. Most are legitimately core (rule management server/public/api, prebuilt rules, rule monitoring, MITRE picker, fleet integrations, OpenAPI docs for detection APIs, rule_management cypress / api integration suites, etc.). The candidates below are entries that put the team on the review hook for code that is **not** part of the team's chartered business area.

## PR review savings — last 6 months

```
Commits on main:                                                  9668
PRs that pinged @elastic/security-detection-rule-management:       192   (32.0/mo)

If ALL 15 candidates were dropped:
  PRs still pinged (team-essential file touched):                  144   (24.0/mo)
  PRs no longer pinged (only candidate-path files):                 48    (8.0/mo)
  Review-load reduction:                                           25.0%
```

| Tier | Candidate | CODEOWNERS line(s) | Files | PRs touched (6mo) | Uniquely freed (6mo) | Uniquely freed (/mo) |
| ---- | --------- | ------------------ | ----: | ----------------: | --------------------: | ---------------------: |
| 1 | `kbn-rule-data-utils` | 644 | 20 | 12 | 12 | **2.0** |
| 1 | `server/routes` | 2722 | 5 | 11 | 7 | **1.2** |
| 1 | `kbn-openapi-generator` | 624 | 46 | 9 | 4 | 0.7 |
| 1 | `kbn-change-history` | 1015 | 16 | 6 | 4 | 0.7 |
| 1 | `kbn-securitysolution-utils` | 1335 | 37 | 3 | 3 | 0.5 |
| 1 | `detections_response/utils` (test helpers) | 2724 | 41 | 12 | 3 | 0.5 |
| 1 | `common/test` (ESS roles fixture) | 2716 | 2 | 5 | 3 | 0.5 |
| 1 | `kbn-openapi-bundler` | 622 | 111 | 2 | 2 | 0.3 |
| 1 | `kbn-zod-helpers` | 721 | 35 | 4 | 2 | 0.3 |
| 1 | `kbn-openapi-common` (paired with bundler/generator) | 623 | 14 | 3 | 0 | 0.0 |
| 2 | `components/links_to_docs` | 3005 | 5 | 3 | 2 | 0.3 |
| 2 | `components/ml_popover` | 3006 | 41 | 3 | 1 | 0.2 |
| 2 | `components/missing_privileges` | 3007 | 11 | 2 | 1 | 0.2 |
| 2 | `components/popover_items` | 3008 | 2 | 1 | 1 | 0.2 |
| 3 | `alerting/.../change_tracking` | 2530 | 5 | 3 | 1 | 0.2 |
| | **Totals (de-duplicated)** | **15 lines** | **~391** | — | **48** | **8.0** |

> Per-row "uniquely freed" sums to more than the deduplicated total because some PRs touch multiple candidates — e.g. several `kbn-change-history` PRs also touched `alerting/.../change_tracking`, so dropping either one alone wouldn't free the PR, but dropping both does. See [PR references — per candidate](#pr-references--per-candidate) at the end of this document.

---

## Tier 1 — Recommended removals (sorted by biggest wins)

Platform packages we incidentally own, plus the cross-team paths surfaced by the discovery pass. All low-risk: every removal falls back to a sensible co-owner (or the plugin default `@elastic/security-solution`). Ordered by PRs uniquely freed per month, biggest first.

### 1. `@kbn/rule-data-utils` (★ biggest single win)

- **Line:** L644
- **Files removed:** 20
- **Current owners:** `@elastic/security-detection-rule-management @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team`
- **Fallback after removal:** three remaining co-owners.
- **PRs uniquely freed in 6 months:** **12** (2.0/mo)

Shared 4 ways for ECS rule-data field names. Detection-engine, response-ops, and actionable-obs-team between them cover both the runtime alerting consumers and the schema/field-name source-of-truth. The 12 PRs over 6 months reflect response-ops and observability churn that has no rule-management content.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -641,3 +641,3 @@
-src/platform/packages/shared/kbn-rule-data-utils @elastic/security-detection-rule-management @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team
+src/platform/packages/shared/kbn-rule-data-utils @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team
```

### 2. `server/routes` (★ second-biggest win)

- **Line:** L2722
- **Files affected:** 5 (`index.ts`, `jest.config.js`, `limited_concurrency.ts`, `data_generator/**`)
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **7** (1.2/mo)

This is the security_solution plugin's top-level route-registry directory — 5 files of routing manifest, not a domain folder. Every new route added by ANY security_solution sub-team (entity-analytics, attacks/alerts, cases, on-week experiments, microsoft defender, etc.) touches this folder and pings all 3 co-owners. The team's review value-add here is nil; detection-engine and threat-hunting cover it perfectly well between them.

Sample PRs from the last 6 months that pinged rule-management purely via this line:
- `#258440` — *[Entity Analytics] Deprecate asset criticality APIs and update privilege check*
- `#250690` — *Case templates schema and Saved Object definition*
- `#249438` — *[OnWeek] Data generation for events, alerts, attacks, and cases*
- `#244178` — *[Security Solutions] Adds serverless Trial Companion*
- `#243495` — *[Entity Store] Enrich Entity Store Usage telemetry event*

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2719,3 +2719,3 @@
-/x-pack/solutions/security/plugins/security_solution/server/routes @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/plugins/security_solution/server/routes @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 3. `@kbn/openapi-generator`

- **Line:** L624
- **Files removed:** 46
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none (package-level fallback only)
- **PRs uniquely freed in 6 months:** **4** (0.7/mo)

Lives under `src/platform/packages/shared/` (platform tier, intentionally cross-team). Consumers outside rule-management include siem_migrations, entity_analytics, timeline, and many `.gen.ts` files maintained by other teams. The team's actual interest is the *output* (`*.gen.ts` files and bundled OpenAPI specs under `common/api/detection_engine/**`), which is owned via the more specific paths at L2990-2994.

> Drop this together with `kbn-openapi-bundler` (L622) and `kbn-openapi-common` (L623) — see entries #8 and #10 below. They're a logically inseparable toolchain.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -622,3 +622,0 @@
-src/platform/packages/shared/kbn-openapi-bundler @elastic/security-detection-rule-management
-src/platform/packages/shared/kbn-openapi-common @elastic/security-detection-rule-management
-src/platform/packages/shared/kbn-openapi-generator @elastic/security-detection-rule-management
```

### 4. `@kbn/change-history`

- **Line:** L1015
- **Files removed:** 16
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **4** (0.7/mo)

README explicitly describes it as "solution-agnostic … use it from any plugin or module that needs audit-style history." 6 of the package's PRs in 6 months were stream/schema renames, ILM-policy work, and `@kbn/data-streams` space-support changes — all platform churn from teams outside ours.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -1012,3 +1012,3 @@
-x-pack/platform/packages/shared/kbn-change-history @elastic/security-detection-rule-management
```

### 5. `@kbn/securitysolution-utils`

- **Line:** L1335
- **Files removed:** 37
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management`
- **Fallback after removal:** `@elastic/security-detection-engine`
- **PRs uniquely freed in 6 months:** **3** (0.5/mo)

Generic date/duration utilities used by exceptions, endpoint forms (defend-workflows), blocklist, lists package, timeline export, esql rule type, etc. Detection-engine is already co-owner and is the broader detection-stack steward.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -1332,3 +1332,3 @@
-x-pack/solutions/security/packages/kbn-securitysolution-utils @elastic/security-detection-engine @elastic/security-detection-rule-management
+x-pack/solutions/security/packages/kbn-securitysolution-utils @elastic/security-detection-engine
```

### 6. `detections_response/utils` (api integration test helpers)

- **Line:** L2724
- **Files affected:** 41
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management`
- **Fallback after removal:** `@elastic/security-detection-engine`
- **PRs uniquely freed in 6 months:** **3** (0.5/mo)

Shared test utilities under `security_solution_api_integration/test_suites/detections_response/utils/` (actions, alerts, connectors, count_down_es, event_log, exception_list_and_item, …). Touched constantly by every detection-response team. The actually-rule-management-specific test suite lives at `test_suites/detections_response/rules_management/` (L3002) and stays ours.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2721,3 +2721,3 @@
-x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils @elastic/security-detection-engine @elastic/security-detection-rule-management
+x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils @elastic/security-detection-engine
```

### 7. `common/test` (ESS roles fixture)

- **Line:** L2716
- **Files affected:** 2 (`ess_roles.json`, `index.ts`)
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **3** (0.5/mo)

A 2-file shared RBAC fixture (`ess_roles.json` + barrel). Every cross-team Security Solution RBAC change pings all 3 co-owners. Detection-engine + threat-hunting are an appropriate pair without us.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2713,3 +2713,3 @@
-/x-pack/solutions/security/plugins/security_solution/common/test @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/plugins/security_solution/common/test @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 8. `@kbn/openapi-bundler`

- **Line:** L622
- **Files removed:** 111
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

Drop together with `kbn-openapi-generator` and `kbn-openapi-common` — see entry #3. Diff is shown there.

### 9. `@kbn/zod-helpers`

- **Line:** L721
- **Files removed:** 35
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

Generic Zod schema/validation helpers. Used by siem_migrations rule/dashboard generators, entity_analytics routes, lead-generation routes, watchlist routes, timeline APIs, plus rule-management's own usage.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -718,3 +718,3 @@
-src/platform/packages/shared/kbn-zod-helpers @elastic/security-detection-rule-management
```

### 10. `@kbn/openapi-common`

- **Line:** L623
- **Files removed:** 14
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **0** (0.0/mo)

On its own this had 0 uniquely-freed PRs over 6 months — its 3 raw PR touches were always paired with team-core code. Listed here only because dropping `kbn-openapi-bundler` and `kbn-openapi-generator` without also dropping `-common` would leave the team owning a logically inseparable subset of the same toolchain. Drop all three together; the ROI argument rests on the bundler + generator. Diff is shown under entry #3.

---

## Tier 2 — Generic Security Solution UI components/hooks (low-medium ROI)

These all live under `public/common/components/**` — by convention, shared building blocks for the whole `security_solution` plugin. Removing rule-management ownership lets each line fall back to the plugin default `@elastic/security-solution` (L1351).

Four of the original UI candidates have been **dropped** because they produced no observable signal over 6 months:

| Dropped candidate | 6mo PRs touched | 6mo uniquely freed | Reason for dropping |
| ----------------- | ---------------: | -------------------: | ------------------- |
| `public/common/components/callouts` (L2718) | 1 | 0 | One PR in 6mo; not worth the line edit |
| `public/common/components/health_truncate_text` (L3004) | 1 | 0 | Same |
| `public/common/hooks/use_form_with_warnings` (L3009) | 0 | 0 | Totally inert in the sample window |

Remaining UI candidates (low impact but ~free to land), sorted by biggest wins:

### 11. `public/common/components/links_to_docs`

- **Line:** L3005, **5 files**, sole owner today, fallback to `@elastic/security-solution`.
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -3002,3 +3002,3 @@
-/x-pack/solutions/security/plugins/security_solution/public/common/components/links_to_docs @elastic/security-detection-rule-management
```

### 12-14. `ml_popover`, `missing_privileges`, `popover_items`

- **Lines:** L3006, L3007, L3008, **54 files total**, sole owner today, fallback to `@elastic/security-solution`.
- **PRs uniquely freed in 6 months:** 1 + 1 + 1 = **3** (0.5/mo combined)
- `ml_popover` is the largest single file group (41 files) and is also used by `entity_analytics/.../pad_ml_popover` — if the team prefers to keep visibility, it can be shared with `@elastic/security-entity-analytics` instead of removed.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -3003,3 +3003,0 @@
-/x-pack/solutions/security/plugins/security_solution/public/common/components/ml_popover @elastic/security-detection-rule-management
-/x-pack/solutions/security/plugins/security_solution/public/common/components/missing_privileges @elastic/security-detection-rule-management
-/x-pack/solutions/security/plugins/security_solution/public/common/components/popover_items @elastic/security-detection-rule-management
```

---

## Tier 3 — Debatable

### 15. `alerting/.../rules_client/lib/change_tracking`

- **Line:** L2530
- **Files removed:** 5
- **Current owner:** sole — `@elastic/security-detection-rule-management` (this line **overrides** the alerting plugin default of `@elastic/response-ops` at L1146)
- **Fallback after removal:** `@elastic/response-ops`
- **PRs uniquely freed in 6 months:** **1** (0.2/mo)

The line exists because rule-management originally landed change-tracking inside response-ops's plugin for prebuilt-rule customization. Volume is low, but removing the override puts response-ops in charge of code that lives inside their plugin — which is the right boundary.

> **Alternative — share rather than remove:** if losing default-reviewer status feels uncomfortable, the line can be rewritten to share ownership (`… @elastic/security-detection-rule-management @elastic/response-ops`). That *increases* PR ping volume on the team though, so it's listed as an alternative only.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2527,3 +2527,3 @@
-/x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking @elastic/security-detection-rule-management
```

---

## What we keep (and the discovery pass confirms it)

The discovery pass also surfaces the team's *high-traffic* lines that should NOT be candidates — the team's actual chartered code. The fact that all of these legitimately core lines rank above almost everything in the candidate list is reassuring: the proposed removals are not gutting the team's review surface, just trimming the periphery.

| Line | Pattern | PRs (6mo) | Uniquely freed | Charter fit |
| ---: | ------- | --------: | --------------: | ----------- |
| 3014 | `public/detection_engine/rule_management_ui` | 51 | 16 | ✓ rule table/page |
| 3013 | `public/detection_engine/rule_management` | 27 | 5 | ✓ rule management |
| 3012 | `public/detection_engine/rule_details_ui` | 21 | 3 | ✓ rule details |
| 3017 | `public/detection_engine/common` | 21 | 2 | ✓ shared rule engine UI |
| 3018 | `public/rules` | 12 | 2 | ✓ rules pages |
| 3015 | `public/detection_engine/rule_monitoring` | 9 | 1 | ✓ rule monitoring |
| 3022 | `server/lib/detection_engine/rule_management` | 25 | 3 | ✓ rule management server |
| 3023 | `server/lib/detection_engine/rule_monitoring` | 14 | 6 | ✓ rule monitoring server |
| 3021 | `server/lib/detection_engine/prebuilt_rules` | 18 | 3 | ✓ prebuilt rules |
| 3002 | `api_integration/.../rules_management` | 34 | 8 | ✓ rule mgmt API integration tests |
| 2998 | `cypress/.../rule_management` | 23 | 7 | ✓ rule mgmt cypress |
| 2993 | `common/api/.../rule_management` | 15 | 0 | ✓ rule management API |
| 2994 | `common/api/.../rule_monitoring` | 11 | 0 | ✓ rule monitoring API |
| 2992 | `common/api/.../prebuilt_rules` | 10 | 0 | ✓ prebuilt rules API |
| 2680 | `docs/openapi/ess/security_solution_detections_api_*` | 17 | 0 | ✓ detection API docs |
| 2676 | `docs/openapi/serverless/security_solution_detections_api_*` | 16 | 0 | ✓ detection API docs |
| 3000 | `test_plans/.../prebuilt_rules` | 5 | 2 | ✓ prebuilt rule test plans |
| 3430 | `.buildkite/.../security_solution_codegen.sh` | 1 | 1 | ✓ our codegen CI |
| 3026 | `scripts/openapi` | 2 | 1 | ✓ our codegen scripts |
| 2999 | `rfcs/detection_response` | 1 | 1 | ✓ detection-response RFCs |

---

## Summary

| Tier | Candidate | Line | Files dropped | Uniquely freed /mo | Risk |
| ---- | --------- | ---- | ------------: | -----------------: | ---- |
| 1 | `kbn-rule-data-utils` (drop us; 3 co-owners stay) | 644 | 20 | **2.0** | Low |
| 1 | `server/routes` (drop us; 2 co-owners stay) | 2722 | 5 | **1.2** | Low |
| 1 | `kbn-openapi-generator` | 624 | 46 | 0.7 | Low |
| 1 | `kbn-change-history` | 1015 | 16 | 0.7 | Low |
| 1 | `kbn-securitysolution-utils` | 1335 | 37 | 0.5 | Low |
| 1 | `detections_response/utils` (drop us; detection-engine stays) | 2724 | 41 | 0.5 | Low |
| 1 | `common/test` (drop us; 2 co-owners stay) | 2716 | 2 | 0.5 | Low |
| 1 | `kbn-openapi-bundler` | 622 | 111 | 0.3 | Low |
| 1 | `kbn-zod-helpers` | 721 | 35 | 0.3 | Low |
| 1 | `kbn-openapi-common` (paired with bundler/generator) | 623 | 14 | 0.0 | Low |
| 2 | `components/links_to_docs` | 3005 | 5 | 0.3 | Low |
| 2 | `components/ml_popover` | 3006 | 41 | 0.2 | Medium — consider sharing |
| 2 | `components/missing_privileges` | 3007 | 11 | 0.2 | Low |
| 2 | `components/popover_items` | 3008 | 2 | 0.2 | Low |
| 3 | `alerting/.../change_tracking` | 2530 | 5 | 0.2 | Medium — coordinate w/ response-ops |
| | **Total** | **15 lines** | **~391 files** | **8.0/mo (= 48 PRs / 6mo, 25% of team review load)** | |

## Suggested rollout

1. **PR 1 — Tier 1** (10 lines, ~327 files, ~5.7 freed PRs/mo). Low risk, biggest single drop. The `server/routes` line is the most strategic — it removes the team from cross-team route-wiring noise that has no business pinging us.
2. **PR 2 — Tier 2** (4 lines, ~59 files, ~0.9 freed PRs/mo). Generic UI building blocks. Easy to revert per-component if anyone misses visibility.
3. **PR 3 — Tier 3** (1 line, 5 files, ~0.2 freed PRs/mo). Coordinate with `@elastic/response-ops` as a courtesy heads-up; they become sole steward of `change_tracking/**`.

## How to verify after applying

```bash
# Number-of-files snapshot
./analyse_codeowners.py @elastic/security-detection-rule-management

# Replay of last 6 months of PRs
python3 analyse_pr_savings.py
```

Expected delta on the file snapshot: `Total owned` drops from **2257** → **~1866** files.
Expected delta on the 6-month PR replay: monthly review pings drop from **32.0/mo → 24.0/mo** (–25%).

---

## PR references — per candidate

Every PR from the last 6 months that touched each candidate path. ★ marks PRs *uniquely freed* by dropping that single line (i.e. the candidate is the only reason the team got pinged). Unmarked rows are PRs that touched the candidate but also touched team-essential or another-candidate code — they don't free the team's review by themselves. Sorted in the same order as the per-candidate breakdown table above (biggest wins first).

### 1. `kbn-rule-data-utils` (L644)

- ★ [#266332](https://github.com/elastic/kibana/pull/266332) — [ResponseOps][PerAlertSnooze] Add alert severity field to alert documents
- ★ [#264156](https://github.com/elastic/kibana/pull/264156) — [Observability] Move rule locators from observability plugin to triggersActionsUi
- ★ [#257995](https://github.com/elastic/kibana/pull/257995) — [Unified Rules] rules url path updates, redirect for obs rules
- ★ [#256727](https://github.com/elastic/kibana/pull/256727) — [Security Solution] Remove deprecated security-detections-response team from the codebase
- ★ [#255442](https://github.com/elastic/kibana/pull/255442) — [Security Solution] [Attacks/Alerts] Flyout: Move attack transform functions
- ★ [#250493](https://github.com/elastic/kibana/pull/250493) — [Unified Rules] Reroute users to new rules app
- ★ [#246656](https://github.com/elastic/kibana/pull/246656) — Add new alert status "delayed"
- ★ [#248931](https://github.com/elastic/kibana/pull/248931) — [Unified Rules] Details and Create Pages
- ★ [#245373](https://github.com/elastic/kibana/pull/245373) — Expose alert rule templates in 'create rule' UI
- ★ [#246096](https://github.com/elastic/kibana/pull/246096) — Update codeowners for new actionable observability team
- ★ [#242125](https://github.com/elastic/kibana/pull/242125) — [Alerts] Add name of Maintenance Window in alert documents
- ★ [#240996](https://github.com/elastic/kibana/pull/240996) — [OBX-UX-MGMT] Store Alert Muted Status Directly in Alert Documents

### 2. `server/routes` (L2722)

- ★ [#261285](https://github.com/elastic/kibana/pull/261285) — SIEM Readiness Serverless Fixes
- ★ [#258440](https://github.com/elastic/kibana/pull/258440) — [Entity Analytics] Deprecate asset criticality APIs and update privilege check
- ★ [#255214](https://github.com/elastic/kibana/pull/255214) — [Security Solution] remove enabled microsoftDefenderEndpointDataInAnalyzerEnabled feature flag
- ★ [#250690](https://github.com/elastic/kibana/pull/250690) — Case templates schema and Saved Object definition
- ★ [#249438](https://github.com/elastic/kibana/pull/249438) — [OnWeek] Data generation for events, alerts, attacks, and cases
- ★ [#244178](https://github.com/elastic/kibana/pull/244178) — [Security Solutions] Adds serverless Trial Companion
- ★ [#243495](https://github.com/elastic/kibana/pull/243495) — [Entity Store] Enrich Entity Store Usage telemetry event
- &nbsp;&nbsp;[#258891](https://github.com/elastic/kibana/pull/258891) — [Security Solution] Create an initialization endpoint and migrate the list index creation flow
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4
- &nbsp;&nbsp;[#247068](https://github.com/elastic/kibana/pull/247068) — [Security Solution][Attacks/Alerts][Setup and miscellaneous] Unified Alerts Management Endpoints (#247065)
- &nbsp;&nbsp;[#243361](https://github.com/elastic/kibana/pull/243361) — [Security Solution] Query unified alerts route

### 3. `kbn-openapi-generator` (L624)

- ★ [#265634](https://github.com/elastic/kibana/pull/265634) — [Security Solution] Adds Inbox plugin
- ★ [#258186](https://github.com/elastic/kibana/pull/258186) — Update remainder kbn-zod/v3 to kbn-zod/v4
- ★ [#253568](https://github.com/elastic/kibana/pull/253568) — [Security][OpenAPI generator] add `experimentallyImportZodV4`
- ★ [#250723](https://github.com/elastic/kibana/pull/250723) — [OpenAPI] Do not generate imports for local references
- &nbsp;&nbsp;[#264125](https://github.com/elastic/kibana/pull/264125) — [Security Solution] Make kbn-openapi-generator producing lazy loaded Zod schemas
- &nbsp;&nbsp;[#244637](https://github.com/elastic/kibana/pull/244637) — [Detections & Response] RBAC - Add Detection Alerts kibana feature
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4
- &nbsp;&nbsp;[#250857](https://github.com/elastic/kibana/pull/250857) — [OpenAPI generator] add `transformSchemaName` config options
- &nbsp;&nbsp;[#248570](https://github.com/elastic/kibana/pull/248570) — [DOCS] Fix OpenAPI linting error in detection_engine

### 4. `kbn-change-history` (L1015)

- ★ [#268894](https://github.com/elastic/kibana/pull/268894) — [Security Solution] Add ILM policy for the change history index
- ★ [#268740](https://github.com/elastic/kibana/pull/268740) — [Security Solution] Rename transaction.id to span.id in @kbn/change-history
- ★ [#259737](https://github.com/elastic/kibana/pull/259737) — [kbn-data-streams] Add explicit 'default' space support
- ★ [#256385](https://github.com/elastic/kibana/pull/256385) — [SecuritySolution] Create '@kbn/change-history' package
- &nbsp;&nbsp;[#265775](https://github.com/elastic/kibana/pull/265775) — [@kbn/change-history] Rename stream to .kibana_change_history; snapshots-only schema and API
- &nbsp;&nbsp;[#261981](https://github.com/elastic/kibana/pull/261981) — [Security Solution] Add core alerting framework capability to support rule change histories

### 5. `kbn-securitysolution-utils` (L1335)

- ★ [#254703](https://github.com/elastic/kibana/pull/254703) — [Security Solution][Detection Engine] Automatically inject metadata _id into ES|QL detection rules
- ★ [#254689](https://github.com/elastic/kibana/pull/254689) — [ES|QL] `@elastic/esql` package installation
- ★ [#246669](https://github.com/elastic/kibana/pull/246669) — [ES|QL] Rename @kbn/esql-ast to @kbn/esql-language

### 6. `detections_response/utils` test helpers (L2724)

- ★ [#262662](https://github.com/elastic/kibana/pull/262662) — [Security Solution] Add alerts_suppressed_count metrics tests for all rule types
- ★ [#255922](https://github.com/elastic/kibana/pull/255922) — [ResponseOps][Connectors] Support user defined unique connector ID in connect creation form
- ★ [#259917](https://github.com/elastic/kibana/pull/259917) — [Security Solution] Add "alerts_candidate_count" rule execution metric
- &nbsp;&nbsp;[#266690](https://github.com/elastic/kibana/pull/266690) — [Security Solution] Migrate install prebuilt rules & detections assets setup to initialization framework - UI
- &nbsp;&nbsp;[#263662](https://github.com/elastic/kibana/pull/263662) — [Security Solution] Prebuilt rule deprecation workflow automated tests
- &nbsp;&nbsp;[#250131](https://github.com/elastic/kibana/pull/250131) — [Security Solution] Rules managment RBAC subfeatures
- &nbsp;&nbsp;[#244637](https://github.com/elastic/kibana/pull/244637) — [Detections & Response] RBAC - Add Detection Alerts kibana feature
- &nbsp;&nbsp;[#245722](https://github.com/elastic/kibana/pull/245722) — [Security Solution] Rules exceptions subfeatures
- &nbsp;&nbsp;[#248259](https://github.com/elastic/kibana/pull/248259) — [Security Solution] Installation review pagination: Frontend
- &nbsp;&nbsp;[#247375](https://github.com/elastic/kibana/pull/247375) — [Security Solution] Installation review pagination: Backend
- &nbsp;&nbsp;[#244287](https://github.com/elastic/kibana/pull/244287) — Use `allowSingleOrDouble`, allow `snake_case` in destructured variables
- &nbsp;&nbsp;[#239690](https://github.com/elastic/kibana/pull/239690) — Clean up tsconfig references in Kibana

### 7. `common/test` ESS roles fixture (L2716)

- ★ [#250929](https://github.com/elastic/kibana/pull/250929) — updates the rulesV1 feature references to rulesV2
- ★ [#246125](https://github.com/elastic/kibana/pull/246125) — [Security Solution] Fix Entity Analytics Dashboard Enablement Test and Add Scout Implementation
- ★ [#245576](https://github.com/elastic/kibana/pull/245576) — [Security Solution] Update Security Roles with new Rules RBAC permissions
- &nbsp;&nbsp;[#250131](https://github.com/elastic/kibana/pull/250131) — [Security Solution] Rules managment RBAC subfeatures
- &nbsp;&nbsp;[#245722](https://github.com/elastic/kibana/pull/245722) — [Security Solution] Rules exceptions subfeatures

### 8. `kbn-openapi-bundler` (L622)

- ★ [#258544](https://github.com/elastic/kibana/pull/258544) — [OpenAPI] Dedupe merged tags by name
- ★ [#249485](https://github.com/elastic/kibana/pull/249485) — [OAS]: Restrict mapping key prefixing only to Discriminator Object Mapping

### 9. `kbn-zod-helpers` (L721)

- ★ [#263354](https://github.com/elastic/kibana/pull/263354) — [Zod Helper][OAS Docs] Fix OAS docs generation for routes using buildRouteValidationWithZod
- ★ [#256329](https://github.com/elastic/kibana/pull/256329) — [Security Solution] Zod v4 Migration for Detection Engine
- &nbsp;&nbsp;[#258854](https://github.com/elastic/kibana/pull/258854) — Upgrade zod to real v4
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4

### 10. `kbn-openapi-common` (L623)

- &nbsp;&nbsp;[#264125](https://github.com/elastic/kibana/pull/264125) — [Security Solution] Make kbn-openapi-generator producing lazy loaded Zod schemas
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4
- &nbsp;&nbsp;[#239690](https://github.com/elastic/kibana/pull/239690) — Clean up tsconfig references in Kibana

### 11. `components/links_to_docs` (L3005)

- ★ [#258466](https://github.com/elastic/kibana/pull/258466) — [DOCS][SECURITY]: Update detection engine UI links to docs
- ★ [#251767](https://github.com/elastic/kibana/pull/251767) — [DOCS][Detection Engine]: Updates doc link to detection reqs page
- &nbsp;&nbsp;[#243176](https://github.com/elastic/kibana/pull/243176) — Fix several doc links in security solution

### 12. `components/ml_popover` (L3006)

- ★ [#244032](https://github.com/elastic/kibana/pull/244032) — Update EUI to 109.2.0
- &nbsp;&nbsp;[#238060](https://github.com/elastic/kibana/pull/238060) — [ML] `@kbn/ml-common-types` & `@kbn/ml-server-schemas`
- &nbsp;&nbsp;[#255637](https://github.com/elastic/kibana/pull/255637) — Replace deprecated EUI icons in files owned by @elastic/security-detection-rule-management

### 13. `components/missing_privileges` (L3007)

- ★ [#266523](https://github.com/elastic/kibana/pull/266523) — [Entity Analytics] EA homepage privileges banner (#17084)
- &nbsp;&nbsp;[#244926](https://github.com/elastic/kibana/pull/244926) — [Security Solution][Attacks/Alerts][Setup and miscellaneous] Attacks indices RBAC (#243079)

### 14. `components/popover_items` (L3008)

- ★ [#258853](https://github.com/elastic/kibana/pull/258853) — [Security Solution][Attacks] Align AssigneesBadge with TagsBadge (popover + stop propagation)

### 15. `alerting/.../change_tracking` (L2530)

- ★ [#266096](https://github.com/elastic/kibana/pull/266096) — [Security Solution] Add request-scoped change tracking client to the alerting framework
- &nbsp;&nbsp;[#265775](https://github.com/elastic/kibana/pull/265775) — [@kbn/change-history] Rename stream to .kibana_change_history; snapshots-only schema and API
- &nbsp;&nbsp;[#261981](https://github.com/elastic/kibana/pull/261981) — [Security Solution] Add core alerting framework capability to support rule change histories
