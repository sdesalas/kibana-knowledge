# PR Review: #302149 — [Security Solution][Threat Intelligence] Show only the latest copy of indicators from integration transforms

**PR:** [elastic/kibana#302149](https://github.com/elastic/kibana/pull/302149) by @kelvtanv
**Created Date: 2026-11-06**

**Scale:** Small. About 30 lines of production code across 5 files (one shared `must_not` clause wired into four queries). The other ~950 lines are tests and fixtures. Local checkout matches PR head `fb6e32b`, CI green.

**Ownership (team: `@elastic/security-detection-engineering`)**
- **Your team's files (1):** `common/cti/constants.ts` — adds `IOC_TRANSFORM_SOURCE_QUERY`. Additive only, nothing existing changes.
- **Other teams' files:**
  - `public/threat_intelligence/**`, Scout specs under `test/scout/{flyout,overview}`, Cypress `investigations/threat_intelligence/indicators.cy.ts` (`@elastic/security-investigations`)
  - `server/search_strategy/security_solution/factory/cti/**` (`@elastic/security-solution` catch-all)
  - `kbn-scout-security` page objects (`@elastic/appex-qa`, `@elastic/security-engineering-productivity`)
  - `es_archives/ti_indicators_data_transform/*` (`@elastic/security-engineering-productivity`)
- **Unowned:** none

DE is on the hook for one constants file. The real DE exposure is indirect — indicator match rules aren't touched, and they're where the remaining duplicates live (see "What this means for detection engineering").

---

### Context / Motivation

Customer escalation on 9.5.5 ([elastic/sdh-security-team#1870](https://github.com/elastic/sdh-security-team/issues/1870)), tracked as [#302120](https://github.com/elastic/kibana/issues/302120), superseding [#228955](https://github.com/elastic/kibana/issues/228955).

TI integrations with a latest transform store every indicator twice: every ingested version in the raw `logs-ti_*` data stream (label `"true"`), plus one active copy in a `*_latest` index (label `"false"`). Both match `logs-ti_*`. From the issue:

> The integration dashboards and the prebuilt indicator match rules already exclude the raw copies with `NOT labels.is_ioc_transform_source: "true"`. Three Security views don't, so they show the same indicator several times.

The issue also hands DE a follow-up:

> Detection Engineering (@elastic/security-detection-engineering): new custom indicator match rules default to `logs-ti_*` with `@timestamp >= "now-30d/d"` and no transform filter, so they can match the same indicator more than once. Shared for their own follow-up; not a blocker for this issue.

### Summary

Adds the same `must_not` clause (either `labels.is_ioc_transform_source` or `labels.is_transform_source` equals `"true"`) to four read-only queries: the Intelligence page table/chart, the Intelligence page total count, the flyout's investigation-time enrichment search, and the Overview per-feed counts. Excluding `"true"` rather than requiring `"false"` keeps unlabeled indicators (custom indices, integrations without a transform).

Matches the issue, with one deliberate extension: the issue only mentions `labels.is_ioc_transform_source`. The second commit (`a31340f`) adds `labels.is_transform_source` for Google TI, Flashpoint, GreyNoise and Cyware. Indicator match rule execution is not touched.

### Files touched

- **Shared clause** — `common/cti/constants.ts`: the one DSL constant every query reuses, so they can't drift.
- **Intelligence page (client-side queries)** — `get_indicator_query_params.ts` (table + bar chart, added as a negated filter to `buildEsQuery`) and `use_total_count.tsx` (count query, added as `must_not`).
- **Server search strategies** — `event_enrichment/query.ts` (flyout investigation-time enrichments and the insights counts in legacy and v2 flyouts) and `threat_intel_source/query.threat_intel_source.dsl.ts` (Overview per-feed aggregation).
- **Tests** — unit tests per query; new Scout spec for the flyout v2 TI tool; extended Overview Scout spec; new Cypress block plus an es_archive for the Intelligence page (ESS only). Each seeds 2 raw + 1 latest per label + 1 unlabeled and expects 3.

### What this means for detection engineering

1. **Indicator match rules still see duplicates.** `create_threat_signals.ts` imports from the same constants file but only uses `THREAT_PIT_KEEP_ALIVE`. Custom IM rules default to `DEFAULT_THREAT_MATCH_QUERY = '@timestamp >= "now-30d/d"'` (`common/constants.ts:95`) with no transform filter, so they still match raw + latest copies and write several enrichments per indicator onto the alert.
2. **Those duplicates survive in the flyout.** `filterDuplicateEnrichments` (`flyout_v2/.../threat_intelligence_helpers.ts:84`) groups by `matched.id` + `matched.field` and prefers rule enrichments. `matched.id` is the indicator doc `_id` (`event_enrichment/helpers.ts:76`), so stored rule enrichments pointing at raw copies stay. For IM alerts from rules without the filter, the "one enrichment per indicator" promise doesn't hold. The new flyout Scout spec uses a custom query rule, so it doesn't cover this. Not a bug in this PR — but customers may still see dupes on IM alerts until DE does the follow-up.
3. **Pre-existing bug in our own API docs.** `patch_rule_route.schema.yaml:80` has an example threat query with `not labels.is_ioc_transform_source:"false"` — backwards (drops latest, keeps raw). The update example (`update_rule_route.schema.yaml:109`) has it right with `"true"`. Both flow into the bundled OpenAPI docs. Came in with [#212367](https://github.com/elastic/kibana/pull/212367). The issue mentions replying to the SDH with "the corrected filter direction", so someone may have copied this. Neither example covers `labels.is_transform_source`.
4. **DE now owns the label list.** The constant lives in `common/cti`, which CODEOWNERS gives to DE. When Integrations converge the two labels, the change lands on us. Reasonable spot since `common/cti` is already shared between TI and DE, just worth knowing.

### Assumptions

- The label contract holds across `ti_*` packages: `"true"` on raw, `"false"` on latest, absent elsewhere. The issue lists Integrations confirming this as a dependency; the PR doesn't say whether that happened.
- `labels.is_transform_source: "true"` on non-TI data doesn't matter. The Intelligence page reads the default Security data view (`logs-*`), but `THREAT_QUERY_BASE` scopes to `event.type: indicator`. The enrichment and Overview queries only hit the threat indices.
- The latest transform is running and its index is healthy. If it isn't, raw copies are now hidden and nothing replaces them.
- `term` on a `constant_keyword` is cheap (rewritten at index level), so no perf cost.

### Risks

1. ~~**Stopped or failing transform makes indicators vanish silently.** Before, raw copies would still show. Now all three views depend on the latest index being current, with no hint to the user when it isn't.~~ (LOW PRIORITY) — mostly goes stale rather than vanishing, and prebuilt IM rules already depend on the transform the same way. See Follow-up 1.
2. **IM-alert duplicates remain** (see DE point 2). The customer who escalated may still see repeated enrichments on IM alerts and read it as "not fixed".
3. **Counts drop and expired indicators disappear after upgrade.** Intended and in the release note, but expect support questions, especially on a patch backport (9.5.6).
4. **Old latest indices after package upgrades** still carry `"false"` and keep duplicating. Acknowledged, owned by Integrations.

### Open questions

- Did Integrations confirm the label contract? Any `ti_*` package using a third label name, or a transform with no label at all?
- Is there a DE follow-up issue for IM rules (default threat query, rule creation UI, maybe prebuilt rules for the `is_transform_source` packages)? Note IM `threat_query` is KQL, so it can't reuse this DSL constant as-is.
- ~~Do the prebuilt IM rules for Google TI / Flashpoint / GreyNoise / Cyware exclude `labels.is_transform_source`, or only `labels.is_ioc_transform_source`? The PR description says prebuilt rules "already exclude the raw copies" but doesn't say which label. Needs a check in `elastic/detection-rules`.~~ (ANSWERED — only `is_ioc_transform_source`; Integrations fixing it, see follow-up 2)
- Is the backwards `"false"` example in `patch_rule_route.schema.yaml` connected to the SDH's "corrected filter direction"? Either way, worth a small DE fix.
- Was the flyout checked on an indicator match alert, not just a custom query alert?

### Notes for your codebase map

- TI integrations with a latest transform dual-write every indicator: raw data stream (label `"true"`) and `*_latest` index (label `"false"`). Two label names in use: `labels.is_ioc_transform_source` and `labels.is_transform_source`.
- Investigation-time enrichment is the `event_enrichment` search strategy. It queries `securitySolution:defaultThreatIndex` over a default 30-day window. The flyout merges its results with enrichments stored on the alert by IM rules, deduped by `matched.id` (indicator `_id`) + `matched.field`, preferring the stored ones.
- The Intelligence page reads the default Security data view, not `defaultThreatIndex` (since [#138882](https://github.com/elastic/kibana/pull/138882)).
- `common/cti` is DE-owned but mostly consumed by investigations/TI code. IM rule execution only pulls `THREAT_PIT_KEEP_ALIVE` from it.
- IM rules default to `threat_query: '@timestamp >= "now-30d/d"'` with no transform filter.

### Follow-up Review Activities

**1. Risk 1 — what happens when the latest transform stops or fails**

Read the transform configs in `elastic/integrations` (ThreatConnect, AbuseCH malware, Google TI domain IOC, Flashpoint) and Fleet's transform install code. The risk is real but narrower than first stated: the usual outcome is a frozen latest index (stale data), not an empty one. And the dependency isn't new — the prebuilt IM rules and the integration dashboards already filter out raw copies, so they rely on the transform in exactly the same way. The PR just brings these three views in line with them.

- **Transforms retry forever.** All four configs set `settings.num_failure_retries: -1`, so a transform hitting errors keeps retrying and never moves to `failed`. The latest index stays as it was at the last good checkpoint.
- **A frozen latest index goes stale in three ways:** no new indicators show up (they sit only in the hidden raw copies); existing ones slowly fall outside the time range (the flyout enrichment looks back 30 days by default, `DEFAULT_EVENT_ENRICHMENT_FROM = 'now-30d'`); and expired ones stick around, because `retention_policy` (`deleted_at` + `max_age: 1m` for ThreatConnect/AbuseCH, `max_age: 30d` for Google TI/Flashpoint) only runs while the transform runs. Before the PR, raw copies would have filled the gap.
- **The one case that really empties the views: a deferred install.** If the installing user can't start the transform, Fleet creates it but doesn't start it and marks the asset `deferred` (`fleet/.../transform/install.ts:775`, `:1021`). The latest index stays empty, so that package's indicators disappear from all three views. Fleet flags it on the integration page (`deferred_assets_section.tsx`). Security shows nothing.
- **Auth breakage is limited to some packages.** Google TI sets `_meta.run_as_kibana_system: false`, so its transform runs on an API key tied to the installing user. If that key is revoked or the user loses privileges, the transform errors (and freezes as above). ThreatConnect, AbuseCH and Flashpoint run as `kibana_system` (default for trusted sources, `install.ts:359`), so they don't have this problem.
- **Normal lag is small.** `frequency: 30s` plus `sync.time.delay: 120s` means a new indicator takes about 2–2.5 minutes to reach the latest index. Before the PR, the raw copy showed up right away. Not worth worrying about.
- **No transform health signal in Security.** Nothing under `public/threat_intelligence` checks transform state. The only places to see it are Stack Management → Transforms, the Fleet deferred-assets warning, and the opt-in Transform health rule type (`transform/server/lib/alerting/transform_health_rule_type`).

Suggested asks for the author (not blockers): add a troubleshooting line to the Intelligence page docs update ("if indicators are missing or stale, check the integration's transform health"), and consider a follow-up to show transform health or deferred-install state on the Intelligence page.

**2. Verifying the "IM rules still produce duplicate enrichments" claim (and looking for tickets)**

Dug into the claim posted on the PR ([discussion_r4491011159](https://github.com/elastic/kibana/pull/302149#discussion_r4491011159)). It holds for custom IM rules. For prebuilt rules, the gap is real, but Integrations already has it covered.

- **Rule execution confirmed.** `buildEnrichments` (`enrich_signal_threat_matches.ts:24`) emits one enrichment per matched threat hit, with `matched.id = threatHit._id`. Nothing dedupes by indicator value. Raw versions + latest copy means N enrichments per indicator on one alert. The alert count isn't inflated, just the enrichments.
- **New finding: duplicates eat the 200-match cap.** `addMatchedQueryToMaps` (`get_signal_id_to_matched_queries_map.ts:76`) stops at `MAX_NUMBER_OF_SIGNAL_MATCHES = 200` per alert, and duplicates count toward it. A high-churn feed could push distinct indicator matches off the alert. They also inflate the threat search the rule pages through, so it costs perf too.
- **Rule form defaults confirmed.** The new-rule form pre-fills `threatIndex` from `securitySolution:defaultThreatIndex` (`logs-ti_*`, `rule_creation/index.tsx:135`) and `threatQueryBar` with `@timestamp >= "now-30d/d"` (`public/detection_engine/common/utils.ts:52`). There's no transform filter. Changing the default only helps new rules, not existing ones.
- **Flyout confirmed, both versions.** The legacy flyout reuses the v2 components (`flyout/document_details/right/components/insights_section.tsx`, `left/tabs/insights_tab.tsx`), so `filterDuplicateEnrichments` applies to both. "Threat matches detected" counts `matched.type: indicator_match_rule` enrichments stored on the alert. It was inflated before this PR and stays inflated after. This PR doesn't make it worse.
- **Prebuilt rules only exclude one label.** All 5 rules in `elastic/detection-rules/rules/threat_intel/` (address, email, hash, registry, url) use `not labels.is_ioc_transform_source:"true"` only. Flashpoint, GreyNoise, Cyware and GTI raw docs carry `event.module: ti_*`, `event.category: threat` and `threat.indicator.*`, so they match the prebuilt rules today.
- **Tickets found:**
  - [elastic/integrations#22147](https://github.com/elastic/integrations/issues/22147) (open, bug): documents exactly the prebuilt-rule gap for those 4 packages.
  - [elastic/integrations#22249](https://github.com/elastic/integrations/pull/22249) (open PR, CI green): adds `labels.is_ioc_transform_source` to those 4 packages, keeps `is_transform_source` as deprecated. Old backing indices keep matching until they age out of the 30-day window. Once it ships, the prebuilt rules are fixed without any change in `detection-rules`.
  - [elastic/integrations#22149](https://github.com/elastic/integrations/issues/22149): GTI's bundled rules + the built-in IM rules produce duplicate alerts when both are enabled (docs fix in #22249).
  - [elastic/security-team#6368](https://github.com/elastic/security-team/issues/6368) (closed 2023): original epic that moved prebuilt IM rules onto active-IOC indices. Background only.
  - **Nothing found for custom IM rules** in kibana, detection-rules or security-team. Searches covered label names, "indicator match" + duplicate/transform, and the #302120 timeline.
- **Caveat:** GitHub issue search returned 0 hits for `is_ioc_transform_source` in kibana even though #302120 contains it, so search on underscored tokens is unreliable. Absence of a ticket is likely but not certain.

**3. Why the transform-source filter is repeated in tests, and where it could be shared**

The tests spell out the filter object instead of importing `IOC_TRANSFORM_SOURCE_QUERY`. That looks deliberate, and it's the stronger choice: importing the constant would compare it to itself, so flipping `'true'` to `'false'` or dropping a label would still pass. It also matches the existing `expectedDsl` in `query.threat_intel_source.dsl.test.ts`, which is a hand-written object. The cost is that the filter lives in five test files plus the constant.

The filter object is written out in these five test files (paths under `x-pack/solutions/security/plugins/security_solution/`):

| File | Where | How |
|---|---|---|
| `public/threat_intelligence/modules/indicators/utils/get_indicator_query_params.test.ts` | L12 | local `const transformSourceExclusion` |
| `public/threat_intelligence/modules/indicators/hooks/use_total_count.test.tsx` | ~L55 | inline in `toHaveBeenCalledWith` |
| `server/search_strategy/security_solution/factory/cti/event_enrichment/query.test.ts` | ~L44 | inline in `toEqual` |
| `server/search_strategy/security_solution/factory/cti/event_enrichment/response.test.ts` | ~L56 | inline in the expected request |
| `server/search_strategy/security_solution/factory/cti/threat_intel_source/query.threat_intel_source.dsl.test.ts` | L23 | local `const transformSourceExclusion` |

- **Where to share it:** `common/search_strategy/security_solution/cti/index.mock.ts`. It's already the shared CTI test-data file (`buildEventEnrichmentRequestOptionsMock` and friends). Both `event_enrichment` tests already import from it, and so do some `public/flyout_v2` tests. Since it's under `common/`, the `public/` and `server/` tests can both use it. CODEOWNERS puts it under the general `@elastic/security-solution` catch-all, so no new team gets pulled into the review.
- **Suggested shape:**

  ```ts
  export const transformSourceExclusionMock = {
    bool: {
      should: [
        { term: { 'labels.is_ioc_transform_source': 'true' } },
        { term: { 'labels.is_transform_source': 'true' } },
      ],
      minimum_should_match: 1,
    },
  };
  ```

- **Keep it a literal**, not `= IOC_TRANSFORM_SOURCE_QUERY`. Then if someone changes the real constant, the tests still catch it, and when the labels change you only update two places instead of six.
- The two `not.toContain('labels.is_ioc_transform_source')` checks in `query.test.ts` and `get_indicator_query_params.test.ts` only use the label names as strings, so they can stay as they are.

**4. Review comments posted on the PR (by @sdesalas, 2026-11-06)**

Posted two comment threads on the PR. No replies from the author yet.

- **[DE follow-up for indicator match rules](https://github.com/elastic/kibana/pull/302149#discussion_r4490983270)** on `common/cti/constants.ts` L68. Quoted the line from [#302120](https://github.com/elastic/kibana/issues/302120) that hands custom IM rules to `@elastic/security-detection-engineering`, and asked @kelvtanv whether DE needs to do extra work to close this, and whether a ticket should be opened since none exists yet.
  - [Follow-up reply in the same thread](https://github.com/elastic/kibana/pull/302149#discussion_r4491011159) adding the supporting notes: custom IM rules default to `@timestamp >= "now-30d/d"` with no transform filter; `filterDuplicateEnrichments` keeps stored rule enrichments that point at raw copies; the new flyout Scout spec uses a custom query rule so doesn't cover IM alerts; not a bug in this PR, but customers may still see dupes on IM alerts until DE follows up.
- **[Share the repeated test filter](https://github.com/elastic/kibana/pull/302149#discussion_r4491139696)** on `query.threat_intel_source.dsl.test.ts` L32. Pointed out the filter object is repeated across tests and suggested exporting it once from `common/search_strategy/security_solution/cti/index.mock.ts`. Explicitly advised against importing from `cti/constants.ts` so the tests keep validating the real constant (see Follow-up 3).
