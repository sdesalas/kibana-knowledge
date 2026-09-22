# Prebuilt install via `SPECIFIC_RULES` writes the right rule, wrong version when filtering by tag.

- **Date:** 2026-09-14
- **Area:** Security Solution — Detection Engine / prebuilt rule installation
- **Seen on:** `http://localhost:5605/kbn` (PR [#275695](https://github.com/elastic/kibana/pull/275695) smoke test)
- **Status:** Reproduced. Code-path confirmed. Unrelated to the import rewrite.
- **Raised by:** @banderror on [#275695](https://github.com/elastic/kibana/pull/275695#issuecomment-5663697131) — AWS-tagged prebuilt rules show as ready to upgrade the moment you install them.

---

## Summary

Installing selected prebuilt rules through `POST /internal/detection_engine/prebuilt_rules/installation/_perform` (`mode: SPECIFIC_RULES`) can persist an **older asset version** of the correct `rule_id`. The Rule Updates tab then immediately offers an upgrade to the real latest.

Detected while [reviewing](https://github.com/elastic/kibana/pull/275695#issuecomment-5663697131) PR [#275695](https://github.com/elastic/kibana/pull/275695).

This issue shows up when the Add Rules table is filtered by a tag that the **newest** asset no longer has. Recent AWS rules renamed `Data Source: AWS` → `Platform: AWS` on the latest version. Filter by the old tag, install, and you get the previous version.

`ALL_RULES` does not have this bug — it installs from unfiltered `fetchLatestVersions()`.

---

## Symptom

1. Add Elastic Rules → filter by tag `Data Source: AWS` (or any tag the latest asset dropped / renamed).
2. Install one or many matching rules (`SPECIFIC_RULES`).
3. Those rules appear under **Rule updates** at once. Installed version is N, target is N+1 (or a larger jump like 318 → 418).

On 5605 after reproducing: **140** prebuilt rules installed, **27** to upgrade. Every upgradeable rule was AWS. All 27 were created around `2026-09-14T14:23Z`.

---

## What’s going on

Two layers. Either one would be enough to ship a stale version; together they make it reliable.

### 1. `_review` with a tag filter returns “latest version that still matches the filter”

`installation/_review` builds KQL from the table filter and passes it into `fetchLatestVersions({ filter })`. That filter is applied **before** the terms + `top_hits` aggregation that picks the latest version.

So if rule X has:

| version | tags |
|---|---|
| 9 | `Data Source: AWS`, `Data Source: AWS S3` |
| 10 | `Platform: AWS`, `Service: AWS S3` |

…a filter of `Data Source: AWS` never sees v10. `top_hits` returns v9. The table shows v9. The UI posts `{ rule_id, version: 9 }`.

### 2. `_perform` `SPECIFIC_RULES` trusts the client version

The handler **does** fetch latest versions, but only to decide “is this `rule_id` installable?” It never checks that `rule.version` is that latest. Then it queues the request body as-is and loads that exact asset SO (`security-rule:{ruleId}_{version}`).

```85:106:x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts
      request.body.rules.forEach((rule) => {
        if (installedRuleIds.has(rule.rule_id)) { /* skip */ }
        if (!installableRuleIds.has(rule.rule_id)) { /* error */ }
        ruleInstallQueue.push(rule); // requested version, not latest
      });
```

Status / upgrade review call `fetchLatestVersions()` **without** the tag filter, so they see v10. Instant upgrade.

The Add Rules table is not inventing a version — it forwards `_review.rules[].version`:

```218:219:x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management_ui/components/rules_table/add_prebuilt_rules_table/add_prebuilt_rules_table_context.tsx
        await installSpecificRulesRequest({
          rules: [{ rule_id: ruleId, version: rule.version }],
```

---

## Live check (5605)

Three rules sampled from the 27. Installed version matches the last asset that still has `Data Source: AWS`. Latest asset renamed the tag and was not installed.

| rule_id | name | installed | latest | last matching-tag asset | latest-asset tags |
|---|---|---|---|---|---|
| `d488f026-7907-4f56-ad51-742feb3db01c` | AWS S3 Bucket Replicated to Another Account | 9 | 10 | v9 `Data Source: AWS` | `Platform: AWS`, `Service: AWS S3` |
| `a60326d7-dca7-4fb7-93eb-1ca03a1febbd` | AWS IAM Assume Role Policy Update | 318 | 418 | v318 `Data Source: AWS` | `Platform: AWS`, `Service: AWS IAM` |
| `bb3ac0e3-2c9c-4069-a26d-75ca6a6e547b` | AWS Lambda Function Deletion | 1 | 2 | v1 `Data Source: AWS` | `Platform: AWS`, `Service: AWS Lambda` |

Same pattern on the rest of the upgrade list (CloudWatch, EC2, EventBridge, RDS, S3, STS, WAF, …). Most are off by one. IAM Assume Role is 318 → 418 because the package skipped those intermediate numbers.

---

## Relevant code

| Piece | Path |
|---|---|
| Install handler (trusts request version) | `…/prebuilt_rules/api/perform_rule_installation/perform_rule_installation_handler.ts` |
| Review handler (passes table KQL into latest-version fetch) | `…/prebuilt_rules/api/review_rule_installation/review_rule_installation_handler.ts` |
| Installable versions + filter | `…/prebuilt_rules/logic/get_installable_rules_for_review.ts` |
| Latest-version agg (filter first, then `top_hits`) | `…/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_latest_versions.ts` |
| Exact-version asset load | `…/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client/methods/fetch_assets_by_version.ts` |
| UI posts `_review` version | `…/add_prebuilt_rules_table/add_prebuilt_rules_table_context.tsx` |
| Upgrade = `installed.version < latest.version` | `…/prebuilt_rules/logic/utils.ts` (`getPossibleUpgrades`) |
| Status (unfiltered latest) | `…/prebuilt_rules/api/get_prebuilt_rules_status/get_prebuilt_rules_status_route.ts` |

---

## What is *not* the bug

- **Import create path (#275695).** Overwrite / export / re-import does not change these versions. The gap is already on the installed prebuilt rule.
- **`ALL_RULES`.** Uses unfiltered `fetchLatestVersions()` and installs those specifiers.
- **Package missing / `ensureLatestRulesPackageInstalled`.** All four historical assets were already on disk; `_perform` just picked the filtered one.

---

## Fix direction (not done)

Two complementary fixes. Do both if this becomes a ticket.

1. **`_review`:** resolve latest version **per `rule_id` first**, then apply the tag / search filter to that latest asset only. A rule whose newest version dropped the tag should not appear in that filtered install list — and should not contribute an older matching version.
2. **`_perform` `SPECIFIC_RULES`:** if the requested version is not the current latest, either replace it with latest or reject it. Today any existing historical asset is installable as long as the `rule_id` is not already installed.

A test that would have caught this: two assets for one `rule_id`, only the older one tagged `Data Source: AWS`; `_review` + `_perform` with that tag filter; assert the installed rule is the latest (or that the rule is not offered at all).
