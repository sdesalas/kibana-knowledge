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

Recent SDH on 9.5.5 ([elastic/sdh-security-team#1870](https://github.com/elastic/sdh-security-team/issues/1870)), tracked as [#302120](https://github.com/elastic/kibana/issues/302120), superseding [#228955](https://github.com/elastic/kibana/issues/228955).

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
2. **IM-alert duplicates remain** (see DE point 2). The customer who escalated may still see repeated enrichments on IM alerts and read it as "not fixed". Now tracked in [#304179](https://github.com/elastic/kibana/issues/304179), which only fixes rule runs after it ships, so existing alerts keep their duplicates.
3. **Counts drop and expired indicators disappear after upgrade.** Intended and in the release note, but expect support questions, especially on a patch backport (9.5.6).
4. **Old latest indices after package upgrades** still carry `"false"` and keep duplicating. Acknowledged, owned by Integrations.

### Open questions

- ~~Did Integrations confirm the label contract? Any `ti_*` package using a third label name, or a transform with no label at all?~~ (ANSWERED) — no third label; the only unlabeled transforms copy IM alerts, not indicators. See Follow-up 7.
- ~~Is there a DE follow-up issue for IM rules (default threat query, rule creation UI, maybe prebuilt rules for the `is_transform_source` packages)? Note IM `threat_query` is KQL, so it can't reuse this DSL constant as-is.~~ (ANSWERED) — [#304179](https://github.com/elastic/kibana/issues/304179), see Follow-up 5.
- ~~Do the prebuilt IM rules for Google TI / Flashpoint / GreyNoise / Cyware exclude `labels.is_transform_source`, or only `labels.is_ioc_transform_source`? The PR description says prebuilt rules "already exclude the raw copies" but doesn't say which label. Needs a check in `elastic/detection-rules`.~~ (ANSWERED — only `is_ioc_transform_source`; Integrations fixing it, see follow-up 2)
- Is the backwards `"false"` example in `patch_rule_route.schema.yaml` connected to the SDH's "corrected filter direction"? Either way, worth a small DE fix.
- ~~Was the flyout checked on an indicator match alert, not just a custom query alert?~~ (ANSWERED) — code confirms IM-alert enrichments stay duplicated, unchanged by this PR (Follow-up 2); tracked in #304179.

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

**5. Author's response and what's left (checked 2026-11-10)**

@kelvtanv replied on 2026-11-09 and pushed one commit (`5140ce0`). Both review threads are now resolved. PR head is `5140ce0`, CI green (21 passed, 8 skipped), mergeable, still `REVIEW_REQUIRED` with no approvals yet.

- **DE follow-up thread — addressed.** Kelvin [replied](https://github.com/elastic/kibana/pull/302149#discussion_r4515222489) that it's not blocking for this PR and opened [#304179](https://github.com/elastic/kibana/issues/304179) ("Indicator match rules match raw indicator copies from threat intel integration transforms"). Labelled `Team:Detection Engineering`, `bug`, unassigned. It covers:
  - duplicate enrichments on alerts, and raw copies eating into the 200-match cap per alert
  - extra threat-search work on every rule run
  - adding both label exclusions to `DEFAULT_THREAT_MATCH_QUERY`
  - deciding how to reach existing custom rules
  - handing the prebuilt rules change (add `labels.is_transform_source`) to `elastic/detection-rules`
- **Shared test mock — addressed as suggested.** `5140ce0` adds `buildTransformSourceExclusionMock()` to `common/search_strategy/security_solution/cti/index.mock.ts` as a hard-coded literal (not a re-export of `IOC_TRANSFORM_SOURCE_QUERY`), with a one-line doc comment saying why. All five test files now use it. No production code changed.
- **Still open on the PR:** one unresolved Libra bot comment (P3) on `cti_link_panel.spec.ts` L246, suggesting the transform-count scenario move from Scout UI to an API/ES-backed test. No reply from the author. Not a DE concern.
- **Not raised on the PR (DE-side, optional):**
  - The backwards `not labels.is_ioc_transform_source:"false"` example in `patch_rule_route.schema.yaml:80`. Still there on upstream main as of 2026-11-10, and not mentioned in #304179.
  - #304179's prebuilt-rules handoff may not be needed: [elastic/integrations#22249](https://github.com/elastic/integrations/pull/22249) adds `labels.is_ioc_transform_source` to the four `is_transform_source` packages (Follow-up 2). Worth a comment on #304179.
  - The transform-health troubleshooting line for the Intelligence page docs (Follow-up 1).
- **Remaining reviewer action:** approve (or not). `common/cti/constants.ts` is DE-owned, so the PR needs a DE codeowner approval. You're still listed as a requested reviewer.

**6. Ownership question raised with the team (by @sdesalas, 2026-11-10)**

Asked the team in [Slack](https://elastic.slack.com/archives/C0B6959RC7K/p1794307281817949) why [#304179](https://github.com/elastic/kibana/issues/304179) (duplicate threat matches from indicator match rules) is DE's to fix rather than Investigations'. The answer decides whether to block this PR until #304179 is fixed or handle it separately. Waiting on replies. The goal is to understand where the boundary is, not to delay the PR.

- **Working hypothesis shared with the team:** DE owns the threat matches because rule execution generates them; Investigations owns only how they're displayed. Linked [`buildEnrichments` on main @ `35ad478`](https://github.com/elastic/kibana/blob/35ad478d2858fd3bd33ba54677a23a707baa03fb/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/indicator_match/threat_mapping/enrich_signal_threat_matches.ts#L24-L71), which writes one enrichment per matched indicator doc (`matched.id = threatHit._id`, `type: indicator_match_rule`).
- **CODEOWNERS split backing it up** (paths under `x-pack/solutions/security/plugins/security_solution/`):

  | Role | Path | Owner |
  |---|---|---|
  | Produces rule-time threat matches | `server/lib/detection_engine/rule_types/indicator_match/...` | DE |
  | Defines their format (`MATCHED_*`, `ENRICHMENT_TYPES`) | `common/cti/constants.ts` | DE |
  | Rule form default threat query | `public/detection_engine/common/utils.ts` | DE |
  | Displays them | `public/flyout_v2/document`, `public/flyout/document_details`, `public/timelines/.../renderers/cti` | Investigations |
  | Flyout live lookup (fixed by this PR) | `server/search_strategy/.../cti/event_enrichment` | `@elastic/security-solution` catch-all (Investigations in practice) |

- **Counterpoint noted:** Investigations could hide duplicates in the flyout by deduping on indicator value instead of doc `_id`. That only fixes what's visible. The 200-match cap per alert and the extra threat-search cost can only be fixed in rule execution.
- **Inputs for the block-or-not decision:**
  - #302120 lists the IM-rule part as non-blocking.
  - Follow-up 2 confirmed this PR doesn't make IM-alert duplicates worse; they exist on `main` today.
  - The PR is a customer-escalated fix targeting 9.5.6 / 9.6 / 9.7 backports, so blocking delays the customer fix too.

**7. Checking the label contract across all `ti_*` transforms (2026-11-10)**

Scanned every transform under `packages/ti_*/elasticsearch/transform/` on `elastic/integrations` main (69 transforms) for its transform-source label field file.

- **Only two label names exist.** 53 transforms ship `is-ioc-transform-source-false.yml`, 12 ship `is-transform-source-false.yml`. No third variant. `IOC_TRANSFORM_SOURCE_QUERY` covers both.
- **Four transforms have no label**, and none of them hold indicators: `ti_google_threat_intelligence` `rule`, `rule_ioc_st`, `rule_vuln`, and `ti_greynoise` `rule`. They copy IM alerts (tagged GreyNoise / Google Threat Intelligence) from `.alerts-security.alerts-*` into `logs-ti_*.enriched_ioc` indices. The PR leaves them alone: no label means they're kept both before and after.
- **Aside (pre-existing, not this PR):** those `enriched_ioc` indices match `logs-ti_*`, so they may show up in the Overview per-feed counts as their own dataset. Not checked further.
- Integrations never formally confirmed the contract, but [elastic/integrations#22249](https://github.com/elastic/integrations/pull/22249) is converging on `is_ioc_transform_source`, which points the same way.

**8. Local repro + fix verification (2026-11-10)**

Ran the seed + real ES transform path below on a clean CBES stack (`ES` `http://localhost:9203`, Kibana `http://localhost:5604/kbn`). Skipped Fleet/AbuseCH — no API key, and Docker→localhost ES routing was a dead end.

- **Seed:** 2 raw docs into `logs-ti_repro.indicator` only (`constant_keyword` `labels.is_ioc_transform_source: "true"`), same sha256, `NOW` / `EARLIER` timestamps, then start transform `ti_repro_latest` into `logs-ti_repro_latest.indicator` (`"false"` via dest mapping).
- **ES sanity:** label buckets `true: 2`, `false: 1`. Unfiltered indicator count **3**; PR `must_not` filter count **1**.
- **UI on PR branch** (`kelvtanv/ti-latest-indicators` @ `5140ce0`): Intelligence → Indicators (Last 24 hours) showed **one** doc for that sha256.
- **Historical data note:** raw + latest docs stay in ES; this PR only filters at read time. Labeled historical raw copies are hidden the same way as new ones. Already-written IM-alert enrichments are unchanged (#304179).
- **Not re-checked on `main` in this pass** after the clean restart (same ES data would show 3). Earlier seed runs on `main` had already confirmed the duplicate table behaviour.

Result: local repro matches the issue; fix behaviour matches the PR. Still doesn't cover IM rule enrichments.

### Local manual test (reproduce on `main`, verify on the PR)

Skip the PR’s Fleet/credentials path. Locally: **seed raw source docs only**, let an ES **latest** transform write the `"false"` copies (same dual-write shape as `ti_*` integrations). Then check Intelligence on `main` (dupes) vs the PR branch (deduped).

**Need:** Kibana + ES (`elastic`/`changeme`). Set `ES` to your ES URL (this CBES run: `http://localhost:9203`).

#### 1. Seed source + start transform

Creates a raw index (`is_ioc_transform_source: "true"`), an empty latest dest (`"false"` via mapping), a latest transform, then indexes **only into the source**. Timestamps are generated for default “Last 24 hours”. Sync delay is `1s` (integrations use ~120s).

```bash
# --- config ---
ES=http://localhost:9203          # your local ES
AUTH=elastic:changeme
# Fresh timestamps so Intelligence "Last 24 hours" picks these up
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
EARLIER=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%S.000Z")

# --- cleanup any previous repro run (ok if these 404) ---
curl -s -u "$AUTH" -X POST "$ES/_transform/ti_repro_latest/_stop?force=true&wait_for_completion=true" >/dev/null
curl -s -u "$AUTH" -X DELETE "$ES/_transform/ti_repro_latest" >/dev/null
curl -s -u "$AUTH" -X DELETE "$ES/logs-ti_repro.indicator,logs-ti_repro_latest.indicator" >/dev/null

# --- create SOURCE index (raw copies) ---
# constant_keyword "true" = every doc in this index is a raw transform source,
# same as logs-ti_* data streams from integrations
curl -s -u "$AUTH" -H 'Content-Type: application/json' -X PUT "$ES/logs-ti_repro.indicator" -d '{
  "settings":{"number_of_shards":1,"number_of_replicas":0},
  "mappings":{"properties":{
    "@timestamp":{"type":"date"},
    "event":{"properties":{
      "category":{"type":"keyword"},"dataset":{"type":"keyword"},
      "id":{"type":"keyword"},"type":{"type":"keyword"},"ingested":{"type":"date"}
    }},
    "labels":{"properties":{"is_ioc_transform_source":{"type":"constant_keyword","value":"true"}}},
    "threat":{"properties":{"feed":{"properties":{"name":{"type":"keyword"}}},
      "indicator":{"properties":{"type":{"type":"keyword"},"first_seen":{"type":"date"},
        "file":{"properties":{"hash":{"properties":{"sha256":{"type":"keyword"}}}}}}}}}
  }}
}'

# --- create DEST index (latest copies) — leave empty; transform writes here ---
# constant_keyword "false" = docs landing here are the "active" latest copy
curl -s -u "$AUTH" -H 'Content-Type: application/json' -X PUT "$ES/logs-ti_repro_latest.indicator" -d '{
  "settings":{"number_of_shards":1,"number_of_replicas":0},
  "mappings":{"properties":{
    "@timestamp":{"type":"date"},
    "event":{"properties":{
      "category":{"type":"keyword"},"dataset":{"type":"keyword"},
      "id":{"type":"keyword"},"type":{"type":"keyword"},"ingested":{"type":"date"}
    }},
    "labels":{"properties":{"is_ioc_transform_source":{"type":"constant_keyword","value":"false"}}},
    "threat":{"properties":{"feed":{"properties":{"name":{"type":"keyword"}}},
      "indicator":{"properties":{"type":{"type":"keyword"},"first_seen":{"type":"date"},
        "file":{"properties":{"hash":{"properties":{"sha256":{"type":"keyword"}}}}}}}}}
  }}
}'

# --- index SOURCE docs only (do this BEFORE starting the transform) ---
# Two versions of the same indicator (same sha256), as if the feed re-ingested it.
# Starting the transform on an empty source checkpoints "now" and skips these.
curl -s -u "$AUTH" -H 'Content-Type: application/x-ndjson' -X POST "$ES/_bulk?refresh=wait_for" --data-binary @- <<EOF
{"index":{"_index":"logs-ti_repro.indicator","_id":"raw-1"}}
{"@timestamp":"$EARLIER","event":{"category":"threat","dataset":"ti_repro.indicator","id":"ioc-1","type":"indicator","ingested":"$EARLIER"},"threat":{"feed":{"name":"Repro Feed"},"indicator":{"type":"file","first_seen":"$EARLIER","file":{"hash":{"sha256":"5d1b6a2c0f3e4b7a9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b"}}}}}
{"index":{"_index":"logs-ti_repro.indicator","_id":"raw-2"}}
{"@timestamp":"$NOW","event":{"category":"threat","dataset":"ti_repro.indicator","id":"ioc-1","type":"indicator","ingested":"$NOW"},"threat":{"feed":{"name":"Repro Feed"},"indicator":{"type":"file","first_seen":"$EARLIER","file":{"hash":{"sha256":"5d1b6a2c0f3e4b7a9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b"}}}}}
EOF

# --- create + start the latest transform ---
# Reads source, keeps one doc per sha256 (newest @timestamp), writes to dest.
# Dest mapping stamps labels.is_ioc_transform_source:"false" on those docs.
# frequency/delay are short for local; real packages use ~30s + 120s.
curl -s -u "$AUTH" -H 'Content-Type: application/json' -X PUT "$ES/_transform/ti_repro_latest" -d '{
  "source":{"index":["logs-ti_repro.indicator"]},
  "dest":{"index":"logs-ti_repro_latest.indicator"},
  "frequency":"5s",
  "sync":{"time":{"field":"event.ingested","delay":"1s"}},
  "latest":{"unique_key":["threat.indicator.file.hash.sha256"],"sort":"@timestamp"}
}'
curl -s -u "$AUTH" -X POST "$ES/_transform/ti_repro_latest/_start"

# --- wait until the transform has written the latest copy ---
for i in 1 2 3 4 5 6; do
  LATEST=$(curl -s -u "$AUTH" "$ES/logs-ti_repro_latest.indicator/_count" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("count",0))')
  echo "latest docs=$LATEST"
  [ "$LATEST" -ge 1 ] && break
  sleep 5
done

# --- sanity check: 2 raw (true) + 1 latest (false) ---
curl -s -u "$AUTH" "$ES/logs-ti_repro*/_search?size=0" -H 'Content-Type: application/json' -d '{
  "aggs":{"by_label":{"terms":{"field":"labels.is_ioc_transform_source"}}}
}'
# expect "true": 2, "false": 1
```


#### 2. Reproduce on `main`

http://localhost:5604/kbn/app/security/threat_intelligence/indicators (Last 24 hours)

- **Bug:** sha256 `5d1b6a2c…` appears **3 times** (2 raw + 1 latest). Table shows 3, not 1.

#### 3. Verify on the PR branch

Check out `kelvtanv/ti-latest-indicators`, restart Kibana (same ES).

- **Fixed:** that sha256 appears **once** (latest only).

Cleanup:

```bash
# stop + delete the transform, then delete both indices
curl -s -u "$AUTH" -X POST "$ES/_transform/ti_repro_latest/_stop?force=true&wait_for_completion=true"
curl -s -u "$AUTH" -X DELETE "$ES/_transform/ti_repro_latest"
curl -s -u "$AUTH" -X DELETE "$ES/logs-ti_repro.indicator,logs-ti_repro_latest.indicator"
```

Does **not** cover indicator-match rule enrichments (#304179). Intelligence is enough for this PR.
