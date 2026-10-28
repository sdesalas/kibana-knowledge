# CODEOWNERS Quick Wins — Reducing PR Review Load on `@elastic/security-detection-rule-management`

> **Update (Jun 2026).** Re-run after fixing a CODEOWNERS-matching bug in `analyse_pr_savings.py` that mis-attributed Cypress shared-common files (`cypress/fixtures`, `cypress/objects`, `cypress/screens/common`, `cypress/support`, `cypress/helpers`) to `@elastic/security-engineering-productivity`. The bug treated `/cypress/*` as recursive when CODEOWNERS' single-`*` stops at slashes. With the fix, the baseline file count and PR-ping numbers below are slightly higher than the original run, and four new Cypress / test-config candidates surface inside Tier 1 (entries #4, #11, #12, #13).
>
> Also added based on team feedback: the report now distinguishes **Pattern 1** (shared-common folders we incidentally co-own — the focus of all Tier 1/2/3 entries below) from **Pattern 2** (de-facto another-team integrations sitting inside our chartered folders, e.g. alerts-table embed on Rule Details, AI assistant in Rule Creation, agent-builder hooks, CPS additions to alert docs). Pattern 2 requires a different methodology (adding *more specific* CODEOWNERS lines to carve out sub-paths inside chartered code) and is sketched in the new "Pattern 2 backlog" section at the end of this document.

## Related PRs

- [elastic/kibana#274430 — \[Detection Engineering\] update codeowners](https://github.com/elastic/kibana/pull/274430) — consolidates `@elastic/security-detections-response`, `@elastic/security-detection-rule-management`, and `@elastic/security-detection-engine` into the new `@elastic/security-detection-engineering` team.

## Baseline (files owned)

Output of `./analyse_codeowners.py @elastic/security-detection-rule-management`:

```
Fully owned (only this team): ~1960
Shared with other teams:       ~365
Total owned:                  2324
```

The team currently appears as an owner on **53 lines** in `.github/CODEOWNERS`. Most are legitimately core (rule management server/public/api, prebuilt rules, rule monitoring, MITRE picker, fleet integrations, OpenAPI docs for detection APIs, rule_management cypress / api integration suites, etc.). The candidates below are entries that put the team on the review hook for code that is **not** part of the team's chartered business area.

## PR review savings — last 6 months

```
Commits on main:                                                 10155
PRs that pinged @elastic/security-detection-rule-management:       213   (35.5/mo)

If ALL 19 candidates were dropped:
  PRs still pinged (team-essential file touched):                  153   (25.5/mo)
  PRs no longer pinged (only candidate-path files):                 60   (10.0/mo)
  Review-load reduction:                                           28.2%
```

| Tier | Candidate | CODEOWNERS line(s) | Files | PRs touched (6mo) | Uniquely freed (6mo) | Uniquely freed (/mo) |
| ---- | --------- | ------------------ | ----: | ----------------: | --------------------: | ---------------------: |
| 1 | `kbn-rule-data-utils` | 654 | 20 | 14 | 13 | **2.2** |
| 1 | `server/routes` | 2878 | 5 | 12 | 9 | **1.5** |
| 1 | `kbn-change-history` | 1029 | 16 | 9 | 5 | 0.8 |
| 1 | `cypress/support` | 2867 | 5 | 5 | **5** | **0.8** |
| 1 | `kbn-openapi-generator` | 634 | 46 | 9 | 4 | 0.7 |
| 1 | `detections_response/utils` (test helpers) | 2880 | 41 | 14 | 4 | 0.7 |
| 1 | `kbn-securitysolution-utils` | 1362 | 37 | 3 | 3 | 0.5 |
| 1 | `common/test` (ESS roles fixture) | 2872 | 2 | 5 | 3 | 0.5 |
| 1 | `kbn-openapi-bundler` | 632 | 111 | 3 | 2 | 0.3 |
| 1 | `kbn-zod-helpers` | 732 | 35 | 4 | 2 | 0.3 |
| 1 | `cypress/screens/common` | 2866 | 5 | 4 | 1 | 0.2 |
| 1 | `cypress/objects` | 2865 | 4 | 4 | 1 | 0.2 |
| 1 | `detections_response/telemetry` (api integration) | 2881 | 5 | 4 | 1 | 0.2 |
| 1 | `kbn-openapi-common` (paired with bundler/generator) | 633 | 14 | 2 | 0 | 0.0 |
| 2 | `components/links_to_docs` | 3130 | 5 | 2 | 2 | 0.3 |
| 2 | `components/missing_privileges` | 3132 | 11 | 2 | 1 | 0.2 |
| 2 | `components/popover_items` | 3133 | 2 | 1 | 1 | 0.2 |
| 2 | `components/ml_popover` | 3131 | 41 | 3 | 0 | 0.0 |
| 3 | `alerting/.../change_tracking` | 2645 | 5 | 4 | 1 | 0.2 |
| | **Totals (de-duplicated)** | **19 lines** | **~410** | — | **60** | **10.0** |

> Per-row "uniquely freed" sums to more than the deduplicated total because some PRs touch multiple candidates — e.g. several `kbn-change-history` PRs also touched `alerting/.../change_tracking`, so dropping either one alone wouldn't free the PR, but dropping both does. See [PR references — per candidate](#pr-references--per-candidate) at the end of this document.

---

## Tier 1 — Recommended removals (sorted by biggest wins)

Platform packages we incidentally own, plus the cross-team paths surfaced by the discovery pass and by team feedback. All low-risk: every removal falls back to a sensible co-owner (or the plugin default `@elastic/security-solution`). Ordered by PRs uniquely freed per month, biggest first.

### 1. `@kbn/rule-data-utils` (★ biggest single win)

- **Line:** L654
- **Files removed:** 20
- **Current owners:** `@elastic/security-detection-rule-management @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team`
- **Fallback after removal:** three remaining co-owners.
- **PRs uniquely freed in 6 months:** **13** (2.2/mo)

Shared 4 ways for ECS rule-data field names. Detection-engine, response-ops, and actionable-obs-team between them cover both the runtime alerting consumers and the schema/field-name source-of-truth. The 13 PRs over 6 months reflect response-ops and observability churn that has no rule-management content.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -654,1 +654,1 @@
-src/platform/packages/shared/kbn-rule-data-utils @elastic/security-detection-rule-management @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team
+src/platform/packages/shared/kbn-rule-data-utils @elastic/security-detection-engine @elastic/response-ops @elastic/actionable-obs-team
```

### 2. `server/routes` (★ second-biggest win)

- **Line:** L2878
- **Files affected:** 5 (`index.ts`, `jest.config.js`, `limited_concurrency.ts`, `data_generator/**`)
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **9** (1.5/mo)

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
@@ -2878,1 +2878,1 @@
-/x-pack/solutions/security/plugins/security_solution/server/routes @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/plugins/security_solution/server/routes @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 3. `@kbn/change-history`

- **Line:** L1029
- **Files removed:** 16
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **5** (0.8/mo)

README explicitly describes it as "solution-agnostic … use it from any plugin or module that needs audit-style history." Several of the package's PRs in 6 months were stream/schema renames, ILM-policy work, and `@kbn/data-streams` space-support changes — all platform churn from teams outside ours.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -1029,1 +1029,0 @@
-x-pack/platform/packages/shared/kbn-change-history @elastic/security-detection-rule-management
```

### 4. `cypress/support` (★ surfaced by team feedback)

- **Line:** L2867
- **Files affected:** 5
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **5** (0.8/mo)

Cross-cutting Cypress test-runner support (commands, auth wiring, custom hooks). Surfaced after fixing a CODEOWNERS-matching bug in `analyse_pr_savings.py` that previously mis-attributed this and other Cypress shared-common files to `@elastic/security-engineering-productivity`. Every PR over 6 months that touched only this line — without touching any other rule-management-owned code — is generic test-infra churn:

- `#260570` — *[Security & Observability] Add AI Agent announcement modal with opt-out to classic assistant*
- `#261873` — *fix(serverless,tests): switch Security Cypress tests to use UIAM authentication*
- `#259074` — *Add `kbn/test-saml-auth` package*
- `#237977` — *Update cypress (main)*
- `#257396` — *[Security Solution] Fix alert assignment cypress tests: add fallback logic when resolving the authenticated user's fullname*

None of these need rule-management eyes.

```diff
@@ -2867,1 +2867,1 @@
-/x-pack/solutions/security/test/security_solution_cypress/cypress/support @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/test/security_solution_cypress/cypress/support @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 5. `@kbn/openapi-generator`

- **Line:** L634
- **Files removed:** 46
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none (package-level fallback only)
- **PRs uniquely freed in 6 months:** **4** (0.7/mo)

Lives under `src/platform/packages/shared/` (platform tier, intentionally cross-team). Consumers outside rule-management include siem_migrations, entity_analytics, timeline, and many `.gen.ts` files maintained by other teams. The team's actual interest is the *output* (`*.gen.ts` files and bundled OpenAPI specs under `common/api/detection_engine/**`), which is owned via the more specific paths.

> Drop this together with `kbn-openapi-bundler` (entry #9) and `kbn-openapi-common` (entry #14) — they're a logically inseparable toolchain.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -632,3 +632,0 @@
-src/platform/packages/shared/kbn-openapi-bundler @elastic/security-detection-rule-management
-src/platform/packages/shared/kbn-openapi-common @elastic/security-detection-rule-management
-src/platform/packages/shared/kbn-openapi-generator @elastic/security-detection-rule-management
```

### 6. `detections_response/utils` (api integration test helpers)

- **Line:** L2880
- **Files affected:** 41
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management`
- **Fallback after removal:** `@elastic/security-detection-engine`
- **PRs uniquely freed in 6 months:** **4** (0.7/mo)

Shared test utilities under `security_solution_api_integration/test_suites/detections_response/utils/` (actions, alerts, connectors, count_down_es, event_log, exception_list_and_item, …). Touched constantly by every detection-response team. The actually-rule-management-specific test suite lives at `test_suites/detections_response/rules_management/` and stays ours.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2880,1 +2880,1 @@
-x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils @elastic/security-detection-engine @elastic/security-detection-rule-management
+x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/utils @elastic/security-detection-engine
```

### 7. `@kbn/securitysolution-utils`

- **Line:** L1362
- **Files removed:** 37
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management`
- **Fallback after removal:** `@elastic/security-detection-engine`
- **PRs uniquely freed in 6 months:** **3** (0.5/mo)

Generic date/duration utilities used by exceptions, endpoint forms (defend-workflows), blocklist, lists package, timeline export, esql rule type, etc. Detection-engine is already co-owner and is the broader detection-stack steward.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -1362,1 +1362,1 @@
-x-pack/solutions/security/packages/kbn-securitysolution-utils @elastic/security-detection-engine @elastic/security-detection-rule-management
+x-pack/solutions/security/packages/kbn-securitysolution-utils @elastic/security-detection-engine
```

### 8. `common/test` (ESS roles fixture)

- **Line:** L2872
- **Files affected:** 2 (`ess_roles.json`, `index.ts`)
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **3** (0.5/mo)

A 2-file shared RBAC fixture (`ess_roles.json` + barrel). Every cross-team Security Solution RBAC change pings all 3 co-owners. Detection-engine + threat-hunting are an appropriate pair without us.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2872,1 +2872,1 @@
-/x-pack/solutions/security/plugins/security_solution/common/test @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/plugins/security_solution/common/test @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 9. `@kbn/openapi-bundler`

- **Line:** L632
- **Files removed:** 111
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

Drop together with `kbn-openapi-generator` (#5) and `kbn-openapi-common` (#14) — see entry #5 for the combined diff.

### 10. `@kbn/zod-helpers`

- **Line:** L732
- **Files removed:** 35
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

Generic Zod schema/validation helpers. Used by siem_migrations rule/dashboard generators, entity_analytics routes, lead-generation routes, watchlist routes, timeline APIs, plus rule-management's own usage.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -732,1 +732,0 @@
-src/platform/packages/shared/kbn-zod-helpers @elastic/security-detection-rule-management
```

### 11. `cypress/screens/common` (★ surfaced by team feedback)

- **Line:** L2866
- **Files affected:** 5
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting`
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **1** (0.2/mo)

Shared screen/page selectors (`controls.ts`, `data_grid.ts`, `filter_group.ts`, `page.ts`, `toast.ts`). The one uniquely-freed PR is `#245588 — [Controls Anywhere] Feature Branch`. Lower volume than `cypress/support` (#4), but mechanically the same change and same justification.

```diff
@@ -2866,1 +2866,1 @@
-/x-pack/solutions/security/test/security_solution_cypress/cypress/screens/common @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/test/security_solution_cypress/cypress/screens/common @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 12. `cypress/objects` (★ surfaced by team feedback)

- **Line:** L2865
- **Files affected:** 4
- **Current owners:** same 3-way as #11
- **Fallback after removal:** detection-engine + threat-hunting
- **PRs uniquely freed in 6 months:** **1** (0.2/mo)

Shared Cypress test-data fixtures (rule objects, exception objects, etc.). Same justification; drop together with `cypress/support` (#4) and `cypress/screens/common` (#11).

```diff
@@ -2865,1 +2865,1 @@
-/x-pack/solutions/security/test/security_solution_cypress/cypress/objects @elastic/security-detection-engine @elastic/security-detection-rule-management @elastic/security-threat-hunting
+/x-pack/solutions/security/test/security_solution_cypress/cypress/objects @elastic/security-detection-engine @elastic/security-threat-hunting
```

### 13. `detections_response/telemetry` (api integration) (★ surfaced by team feedback)

- **Line:** L2881
- **Files affected:** ~5
- **Current owners:** `@elastic/security-detection-engine @elastic/security-detection-rule-management`
- **Fallback after removal:** `@elastic/security-detection-engine`
- **PRs uniquely freed in 6 months:** **1** (0.2/mo)

Cross-team API-integration telemetry tests. The single uniquely-freed PR is `#265100 — [Security Solution] Fix flaky rule telemetry tests`. Low volume on its own, but pairs naturally with `detections_response/utils` (#6) so the team's footprint in the detection-response api-integration suite is consistent.

```diff
@@ -2881,1 +2881,1 @@
-x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/telemetry @elastic/security-detection-engine @elastic/security-detection-rule-management
+x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/telemetry @elastic/security-detection-engine
```

### 14. `@kbn/openapi-common`

- **Line:** L633
- **Files removed:** 14
- **Current owner:** sole — `@elastic/security-detection-rule-management`
- **Fallback after removal:** none
- **PRs uniquely freed in 6 months:** **0** (0.0/mo)

On its own this had 0 uniquely-freed PRs over 6 months — its 2 raw PR touches were always paired with team-core code. Listed here only because dropping `kbn-openapi-bundler` and `kbn-openapi-generator` without also dropping `-common` would leave the team owning a logically inseparable subset of the same toolchain. Drop all three together; the ROI argument rests on the bundler + generator. Diff is shown under entry #5.

---

### Tier 1 candidates considered and dropped (0 uniquely-freed PRs in 6mo window)

Surfaced by the team-feedback re-run; held to the same "≥ 1 uniquely-freed PR / 6mo" bar as the rest of Tier 1.

| Dropped candidate | 6mo PRs touched | 6mo uniquely freed | Reason for dropping |
| ----------------- | ---------------: | -------------------: | ------------------- |
| `cypress/fixtures` (L2863) | 0 | 0 | Inert in 6mo window |
| `cypress/helpers` (L2864) | 1 | 0 | One PR (#263662), always co-touched with chartered code |
| `server/utils` (L2879) | 0 | 0 | Inert |
| `detections_response/user_roles` (L2882) | 0 | 0 | Inert |
| `api_integration/sources` (L2883) | 0 | 0 | Inert |
| `api_integration/services/detections_response` (L2884) | 1 | 0 | One PR (#251166), co-touched |

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

### 15. `public/common/components/links_to_docs`

- **Line:** L3130, **5 files**, sole owner today, fallback to `@elastic/security-solution`.
- **PRs uniquely freed in 6 months:** **2** (0.3/mo)

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -3130,1 +3130,0 @@
-/x-pack/solutions/security/plugins/security_solution/public/common/components/links_to_docs @elastic/security-detection-rule-management
```

### 16-18. `missing_privileges`, `popover_items`, `ml_popover`

- **Lines:** L3132, L3133, L3131, **54 files total**, sole owner today, fallback to `@elastic/security-solution`.
- **PRs uniquely freed in 6 months:** 1 + 1 + 0 = **2** (0.3/mo combined). `ml_popover` had 0 uniquely-freed PRs in the latest run.
- `ml_popover` is the largest single file group (41 files) and is also used by `entity_analytics/.../pad_ml_popover` — if the team prefers to keep visibility, it can be shared with `@elastic/security-entity-analytics` instead of removed.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -3131,3 +3131,0 @@
-/x-pack/solutions/security/plugins/security_solution/public/common/components/ml_popover @elastic/security-detection-rule-management
-/x-pack/solutions/security/plugins/security_solution/public/common/components/missing_privileges @elastic/security-detection-rule-management
-/x-pack/solutions/security/plugins/security_solution/public/common/components/popover_items @elastic/security-detection-rule-management
```

---

## Tier 3 — Debatable

### 19. `alerting/.../rules_client/lib/change_tracking`

- **Line:** L2645
- **Files removed:** 5
- **Current owner:** sole — `@elastic/security-detection-rule-management` (this line **overrides** the alerting plugin default of `@elastic/response-ops` at L1146)
- **Fallback after removal:** `@elastic/response-ops`
- **PRs uniquely freed in 6 months:** **1** (0.2/mo)

The line exists because rule-management originally landed change-tracking inside response-ops's plugin for prebuilt-rule customization. Volume is low, but removing the override puts response-ops in charge of code that lives inside their plugin — which is the right boundary.

> **Alternative — share rather than remove:** if losing default-reviewer status feels uncomfortable, the line can be rewritten to share ownership (`… @elastic/security-detection-rule-management @elastic/response-ops`). That *increases* PR ping volume on the team though, so it's listed as an alternative only.

```diff
--- a/.github/CODEOWNERS
+++ b/.github/CODEOWNERS
@@ -2645,1 +2645,0 @@
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
| 1 | `kbn-rule-data-utils` (drop us; 3 co-owners stay) | 654 | 20 | **2.2** | Low |
| 1 | `server/routes` (drop us; 2 co-owners stay) | 2878 | 5 | **1.5** | Low |
| 1 | `kbn-change-history` | 1029 | 16 | 0.8 | Low |
| 1 | `cypress/support` (drop us; 2 co-owners stay) | 2867 | 5 | **0.8** | Low |
| 1 | `kbn-openapi-generator` | 634 | 46 | 0.7 | Low |
| 1 | `detections_response/utils` (drop us; detection-engine stays) | 2880 | 41 | 0.7 | Low |
| 1 | `kbn-securitysolution-utils` | 1362 | 37 | 0.5 | Low |
| 1 | `common/test` (drop us; 2 co-owners stay) | 2872 | 2 | 0.5 | Low |
| 1 | `kbn-openapi-bundler` | 632 | 111 | 0.3 | Low |
| 1 | `kbn-zod-helpers` | 732 | 35 | 0.3 | Low |
| 1 | `cypress/screens/common` (drop us; 2 co-owners stay) | 2866 | 5 | 0.2 | Low |
| 1 | `cypress/objects` (drop us; 2 co-owners stay) | 2865 | 4 | 0.2 | Low |
| 1 | `detections_response/telemetry` (drop us; detection-engine stays) | 2881 | 5 | 0.2 | Low |
| 1 | `kbn-openapi-common` (paired with bundler/generator) | 633 | 14 | 0.0 | Low |
| 2 | `components/links_to_docs` | 3130 | 5 | 0.3 | Low |
| 2 | `components/missing_privileges` | 3132 | 11 | 0.2 | Low |
| 2 | `components/popover_items` | 3133 | 2 | 0.2 | Low |
| 2 | `components/ml_popover` | 3131 | 41 | 0.0 | Medium — consider sharing |
| 3 | `alerting/.../change_tracking` | 2645 | 5 | 0.2 | Medium — coordinate w/ response-ops |
| | **Total** | **19 lines** | **~410 files** | **10.0/mo (= 60 PRs / 6mo, 28.2% of team review load)** | |

## Suggested rollout

1. **PR 1 — Tier 1** (14 lines, ~346 files, ~9.1 freed PRs/mo). Low risk, biggest single drop. The `server/routes` and `kbn-rule-data-utils` lines together are the most strategic — they remove the team from cross-team route-wiring and ECS-rule-data noise that has no business pinging us. The four Cypress / API-integration shared-commons entries (#4, #11, #12, #13) and the OpenAPI toolchain (#5, #9, #14) are also bundled in here.
2. **PR 2 — Tier 2** (4 lines, ~59 files, ~0.7 freed PRs/mo). Generic UI building blocks. Easy to revert per-component if anyone misses visibility. `ml_popover` had 0 uniquely-freed PRs in the latest window — keep or drop is a judgement call.
3. **PR 3 — Tier 3** (1 line, 5 files, ~0.2 freed PRs/mo). Coordinate with `@elastic/response-ops` as a courtesy heads-up; they become sole steward of `change_tracking/**`.

## How to verify after applying

```bash
# Number-of-files snapshot
./analyse_codeowners.py @elastic/security-detection-rule-management

# Replay of last 6 months of PRs (requires KIBANA_REPO env var if the script
# lives outside the kibana checkout, e.g. in a knowledge folder).
KIBANA_REPO=/path/to/kibana python3 analyse_pr_savings.py
```

Expected delta on the file snapshot: `Total owned` drops from **2324** → **~1914** files.
Expected delta on the 6-month PR replay: monthly review pings drop from **35.5/mo → 25.5/mo** (–28.2%).

---

## Pattern 2 backlog — carve-outs inside chartered folders (separate workstream)

The Pattern-1 analysis above can only flag CODEOWNERS lines that *as a whole* don't belong to the team. It cannot see the second class of irrelevant pings called out by team feedback: PRs that modify code *inside* a chartered folder, but where the actual content is de-facto owned by another team (alerts-table integration on the Rule Details page, AI assistant in Rule Creation, agent-builder hooks, CPS additions to alert documents, etc.). These PRs are counted as "team-essential touched" by `analyse_pr_savings.py` and actively *hidden* from the candidate discovery — they're unavoidable given the current CODEOWNERS structure.

Addressing Pattern 2 requires the opposite of what the rest of this document does: **adding more-specific CODEOWNERS lines that carve out a sub-path inside a chartered line and reassign it to the de-facto owner.** Below is the starting backlog identified via codebase inspection of the team's chartered Detection Engine folders. Each entry needs a quick conversation with the named team to confirm they accept ownership before landing.

| Sub-path inside chartered code | Files | De-facto owner | Notes |
| ------------------------------ | ----- | -------------- | ----- |
| `public/detection_engine/rule_creation_ui/components/ai_assistant/` | 1 | `@elastic/security-genai` (verify) | AI-assistant integration into rule-creation UI |
| `public/detection_engine/rule_creation_ui/components/add_rule_attachment_to_chat_button/` | 2 | `@elastic/security-genai` (verify) | "Attach rule to chat" affordance |
| `public/detection_engine/rule_creation_ui/pages/rule_creation/hooks/use_agent_builder_rule_creation.tsx` | 1 | Agent-builder team (verify) | Agent-builder rule creation entry |
| `public/detection_engine/rule_details_ui/pages/rule_details/index.tsx` (partial) | 1 | `@elastic/security-threat-hunting` (alerts-table integration only) | Imports `AlertsTable`, `GroupedAlertsTable`, `AlertsTableFilterGroup` from `public/detections/components/alerts_table` (owned by threat-hunting at L3003). A whole-file carve-out is too coarse; consider splitting `index.tsx` into a rule-details shell + alerts-table-integration sub-component owned by threat-hunting. |
| Other CPS integrations | TBD | `@elastic/security-cloud-security` (verify) | Confirmed at least one Pattern-2 PR: `#266495 — [Security Solution][CPS] Adding CPS Data to Alert Document and Event Log` — pinged the team via `detections_response/utils` (already a Pattern-1 candidate) and other paths. Need a fresh sweep of the team's chartered server-side folders for CPS-prefixed files / imports from `@kbn/cloud-security-posture-plugin`. |

### Suggested methodology to quantify Pattern 2 before acting

The `analyse_pr_savings.py` script can be extended to flag Pattern-2 PRs distinctly:

1. For each PR in the 6-month window that pinged the team and is **not** "uniquely freed" by any candidate, look at the touched chartered files.
2. Cross-reference with the PR's `requested_teams` / primary `Team:*` label via the GitHub API. If the rule-management team isn't the primary owner of the PR's intent, flag it as a Pattern-2 candidate.
3. Group those Pattern-2-flagged PRs by which chartered files they touched. Sub-paths that appear repeatedly across PRs led by other teams become carve-out candidates.

This requires API access (not just local git log) and isn't a trivial extension, but it'd produce a data-backed Pattern-2 candidate list comparable to the Pattern-1 entries above. Without it, Pattern 2 has to be addressed by hand-curation + spot-checks against recent PR history.

---

## PR references — per candidate

Every PR from the last 6 months that touched each candidate path. ★ marks PRs *uniquely freed* by dropping that single line (i.e. the candidate is the only reason the team got pinged). Unmarked rows are PRs that touched the candidate but also touched team-essential or another-candidate code — they don't free the team's review by themselves. Sorted in the same order as the per-candidate breakdown table above (biggest wins first).

### 1. `kbn-rule-data-utils` (L654)

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

### 2. `server/routes` (L2878)

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

### 3. `kbn-change-history` (L1029)

- ★ [#268894](https://github.com/elastic/kibana/pull/268894) — [Security Solution] Add ILM policy for the change history index
- ★ [#268740](https://github.com/elastic/kibana/pull/268740) — [Security Solution] Rename transaction.id to span.id in @kbn/change-history
- ★ [#259737](https://github.com/elastic/kibana/pull/259737) — [kbn-data-streams] Add explicit 'default' space support
- ★ [#256385](https://github.com/elastic/kibana/pull/256385) — [SecuritySolution] Create '@kbn/change-history' package
- &nbsp;&nbsp;[#265775](https://github.com/elastic/kibana/pull/265775) — [@kbn/change-history] Rename stream to .kibana_change_history; snapshots-only schema and API
- &nbsp;&nbsp;[#261981](https://github.com/elastic/kibana/pull/261981) — [Security Solution] Add core alerting framework capability to support rule change histories

### 4. `cypress/support` (L2867)

- ★ [#260570](https://github.com/elastic/kibana/pull/260570) — [Security & Observability] Add AI Agent announcement modal with opt-out to classic assistant
- ★ [#261873](https://github.com/elastic/kibana/pull/261873) — fix(serverless,tests): switch Security Cypress tests to use UIAM authentication
- ★ [#259074](https://github.com/elastic/kibana/pull/259074) — Add `kbn/test-saml-auth` package
- ★ [#237977](https://github.com/elastic/kibana/pull/237977) — Update cypress (main)
- ★ [#257396](https://github.com/elastic/kibana/pull/257396) — [Security Solution] Fix alert assignment cypress tests: add fallback logic when resolving the authenticated user's fullname

### 5. `kbn-openapi-generator` (L634)

- ★ [#265634](https://github.com/elastic/kibana/pull/265634) — [Security Solution] Adds Inbox plugin
- ★ [#258186](https://github.com/elastic/kibana/pull/258186) — Update remainder kbn-zod/v3 to kbn-zod/v4
- ★ [#253568](https://github.com/elastic/kibana/pull/253568) — [Security][OpenAPI generator] add `experimentallyImportZodV4`
- ★ [#250723](https://github.com/elastic/kibana/pull/250723) — [OpenAPI] Do not generate imports for local references
- &nbsp;&nbsp;[#264125](https://github.com/elastic/kibana/pull/264125) — [Security Solution] Make kbn-openapi-generator producing lazy loaded Zod schemas
- &nbsp;&nbsp;[#244637](https://github.com/elastic/kibana/pull/244637) — [Detections & Response] RBAC - Add Detection Alerts kibana feature
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4
- &nbsp;&nbsp;[#250857](https://github.com/elastic/kibana/pull/250857) — [OpenAPI generator] add `transformSchemaName` config options
- &nbsp;&nbsp;[#248570](https://github.com/elastic/kibana/pull/248570) — [DOCS] Fix OpenAPI linting error in detection_engine

### 6. `detections_response/utils` test helpers (L2880)

- ★ [#262662](https://github.com/elastic/kibana/pull/262662) — [Security Solution] Add alerts_suppressed_count metrics tests for all rule types
- ★ [#255922](https://github.com/elastic/kibana/pull/255922) — [ResponseOps][Connectors] Support user defined unique connector ID in connect creation form
- ★ [#259917](https://github.com/elastic/kibana/pull/259917) — [Security Solution] Add "alerts_candidate_count" rule execution metric
- &nbsp;&nbsp;[#266495](https://github.com/elastic/kibana/pull/266495) — [Security Solution][CPS] Adding CPS Data to Alert Document and Event Log
- &nbsp;&nbsp;[#266690](https://github.com/elastic/kibana/pull/266690) — [Security Solution] Migrate install prebuilt rules & detections assets setup to initialization framework - UI
- &nbsp;&nbsp;[#263662](https://github.com/elastic/kibana/pull/263662) — [Security Solution] Prebuilt rule deprecation workflow automated tests
- &nbsp;&nbsp;[#250131](https://github.com/elastic/kibana/pull/250131) — [Security Solution] Rules managment RBAC subfeatures
- &nbsp;&nbsp;[#244637](https://github.com/elastic/kibana/pull/244637) — [Detections & Response] RBAC - Add Detection Alerts kibana feature
- &nbsp;&nbsp;[#245722](https://github.com/elastic/kibana/pull/245722) — [Security Solution] Rules exceptions subfeatures
- &nbsp;&nbsp;[#248259](https://github.com/elastic/kibana/pull/248259) — [Security Solution] Installation review pagination: Frontend
- &nbsp;&nbsp;[#247375](https://github.com/elastic/kibana/pull/247375) — [Security Solution] Installation review pagination: Backend
- &nbsp;&nbsp;[#244287](https://github.com/elastic/kibana/pull/244287) — Use `allowSingleOrDouble`, allow `snake_case` in destructured variables

### 7. `kbn-securitysolution-utils` (L1362)

- ★ [#254703](https://github.com/elastic/kibana/pull/254703) — [Security Solution][Detection Engine] Automatically inject metadata _id into ES|QL detection rules
- ★ [#254689](https://github.com/elastic/kibana/pull/254689) — [ES|QL] `@elastic/esql` package installation
- ★ [#246669](https://github.com/elastic/kibana/pull/246669) — [ES|QL] Rename @kbn/esql-ast to @kbn/esql-language

### 8. `common/test` ESS roles fixture (L2872)

- ★ [#250929](https://github.com/elastic/kibana/pull/250929) — updates the rulesV1 feature references to rulesV2
- ★ [#246125](https://github.com/elastic/kibana/pull/246125) — [Security Solution] Fix Entity Analytics Dashboard Enablement Test and Add Scout Implementation
- ★ [#245576](https://github.com/elastic/kibana/pull/245576) — [Security Solution] Update Security Roles with new Rules RBAC permissions
- &nbsp;&nbsp;[#250131](https://github.com/elastic/kibana/pull/250131) — [Security Solution] Rules managment RBAC subfeatures
- &nbsp;&nbsp;[#245722](https://github.com/elastic/kibana/pull/245722) — [Security Solution] Rules exceptions subfeatures

### 9. `kbn-openapi-bundler` (L632)

- ★ [#258544](https://github.com/elastic/kibana/pull/258544) — [OpenAPI] Dedupe merged tags by name
- ★ [#249485](https://github.com/elastic/kibana/pull/249485) — [OAS]: Restrict mapping key prefixing only to Discriminator Object Mapping

### 10. `kbn-zod-helpers` (L732)

- ★ [#263354](https://github.com/elastic/kibana/pull/263354) — [Zod Helper][OAS Docs] Fix OAS docs generation for routes using buildRouteValidationWithZod
- ★ [#256329](https://github.com/elastic/kibana/pull/256329) — [Security Solution] Zod v4 Migration for Detection Engine
- &nbsp;&nbsp;[#258854](https://github.com/elastic/kibana/pull/258854) — Upgrade zod to real v4
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4

### 11. `cypress/screens/common` (L2866)

- &nbsp;&nbsp;[#260949](https://github.com/elastic/kibana/pull/260949) — Upgrade EUI to v116.0.0
- &nbsp;&nbsp;[#250131](https://github.com/elastic/kibana/pull/250131) — [Security Solution] Rules managment RBAC subfeatures
- ★ [#245588](https://github.com/elastic/kibana/pull/245588) — [Controls Anywhere] Feature Branch
- &nbsp;&nbsp;[#239634](https://github.com/elastic/kibana/pull/239634) — [Detection Engine] Extracts Rules/Alerts/Exceptions permission to new Rules feature privileges

### 12. `cypress/objects` (L2865)

- &nbsp;&nbsp;[#263687](https://github.com/elastic/kibana/pull/263687) — [EDR Workflows][Serverless] Enable Endpoint exceptions move feature flag
- &nbsp;&nbsp;[#255339](https://github.com/elastic/kibana/pull/255339) — [ML] Update Security ML jobs to use entity analytics fields for host and user fields
- &nbsp;&nbsp;[#247674](https://github.com/elastic/kibana/pull/247674) — [Security Solution][Detection Engine] adds AI rule creation
- ★ [#238869](https://github.com/elastic/kibana/pull/238869) — [Cases] IBM Resilient form improvements

### 13. `detections_response/telemetry` (L2881)

- ★ [#265100](https://github.com/elastic/kibana/pull/265100) — [Security Solution] Fix flaky rule telemetry tests
- &nbsp;&nbsp;[#261814](https://github.com/elastic/kibana/pull/261814) — [Security Solution][Detection Engine] Add missing telemetry for AI rule creation
- &nbsp;&nbsp;[#248644](https://github.com/elastic/kibana/pull/248644) — [Defend Workflows] Remove deprecated endpoint list constants and replace with ENDPOINT_ARTIFACT_LISTS
- &nbsp;&nbsp;[#244287](https://github.com/elastic/kibana/pull/244287) — Use `allowSingleOrDouble`, allow `snake_case` in destructured variables

### 14. `kbn-openapi-common` (L633)

- &nbsp;&nbsp;[#264125](https://github.com/elastic/kibana/pull/264125) — [Security Solution] Make kbn-openapi-generator producing lazy loaded Zod schemas
- &nbsp;&nbsp;[#252702](https://github.com/elastic/kibana/pull/252702) — Upgrade to Zod v4

### 15. `components/links_to_docs` (L3130)

- ★ [#258466](https://github.com/elastic/kibana/pull/258466) — [DOCS][SECURITY]: Update detection engine UI links to docs
- ★ [#251767](https://github.com/elastic/kibana/pull/251767) — [DOCS][Detection Engine]: Updates doc link to detection reqs page
- &nbsp;&nbsp;[#243176](https://github.com/elastic/kibana/pull/243176) — Fix several doc links in security solution

### 16. `components/missing_privileges` (L3132)

- ★ [#266523](https://github.com/elastic/kibana/pull/266523) — [Entity Analytics] EA homepage privileges banner (#17084)
- &nbsp;&nbsp;[#244926](https://github.com/elastic/kibana/pull/244926) — [Security Solution][Attacks/Alerts][Setup and miscellaneous] Attacks indices RBAC (#243079)

### 17. `components/popover_items` (L3133)

- ★ [#258853](https://github.com/elastic/kibana/pull/258853) — [Security Solution][Attacks] Align AssigneesBadge with TagsBadge (popover + stop propagation)

### 18. `components/ml_popover` (L3131)

- &nbsp;&nbsp;[#270551](https://github.com/elastic/kibana/pull/270551) — fix(a11y): add aria-label/aria-labelledby to EuiPopover/EuiModal components in @elastic/security-solution
- &nbsp;&nbsp;[#238060](https://github.com/elastic/kibana/pull/238060) — [ML] `@kbn/ml-common-types` & `@kbn/ml-server-schemas`
- &nbsp;&nbsp;[#255637](https://github.com/elastic/kibana/pull/255637) — Replace deprecated EUI icons in files owned by @elastic/security-detection-rule-management

### 19. `alerting/.../change_tracking` (L2645)

- ★ [#266096](https://github.com/elastic/kibana/pull/266096) — [Security Solution] Add request-scoped change tracking client to the alerting framework
- &nbsp;&nbsp;[#268724](https://github.com/elastic/kibana/pull/268724) — [Security Solution] Implement Rule Changes History API
- &nbsp;&nbsp;[#265775](https://github.com/elastic/kibana/pull/265775) — [@kbn/change-history] Rename stream to .kibana_change_history; snapshots-only schema and API
- &nbsp;&nbsp;[#261981](https://github.com/elastic/kibana/pull/261981) — [Security Solution] Add core alerting framework capability to support rule change histories
