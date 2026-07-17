# Rule Details Page: "Update Rule" Silently Fails When Legacy ML Jobs Are Installed

**Date:** 2026-07-17
**Related issue:** [#239884](https://github.com/elastic/kibana/issues/239884)
**Slack thread:** [#security-detection-engineering-team](https://elastic.slack.com/archives/C0B7YAUDDB5/p1784225323593619)

---

## Summary

When a user has legacy ML jobs installed and tries to upgrade a prebuilt rule **from the rule details page**, clicking the "Update rule" button in the upgrade flyout silently does nothing — the button appears to respond but the rule is never updated, and no error is shown.

The same action from the **Rules Management → Rule Updates tab** works correctly (the ML jobs modal appears, the user clicks through, and the rule is upgraded).

---

## User Impact

- Users with legacy ML jobs installed cannot upgrade individual prebuilt rules from the rule details page.
- There is no error message — the UX gives no indication that the upgrade failed or why.
- The workaround is to use the Rule Updates tab in Rules Management instead.

---

## Root Cause

The bug is a missing modal render in `RuleUpdateCallout`.

### How the upgrade flow works

The upgrade logic lives in `use_prebuilt_rules_upgrade.tsx`. It returns three pieces of UI that must all be rendered together:

| Return value | Purpose |
|---|---|
| `rulePreviewFlyout` | The flyout showing the rule diff with an "Update rule" button |
| `confirmLegacyMlJobsUpgradeModal` | Modal asking the user to acknowledge legacy ML jobs before upgrading |
| `upgradeConflictsModal` | Modal asking the user how to resolve field conflicts |

When the user clicks "Update rule", the code calls `confirmLegacyMLJobs()` from `use_ml_jobs_upgrade_modal.tsx`. This uses `useAsyncConfirmation` — it shows the modal and returns a Promise that only resolves when the user clicks a button inside that modal. If the modal is never mounted in the DOM, the Promise hangs forever and the upgrade never proceeds.

### Where the Rule Updates tab gets it right

`upgrade_prebuilt_rules_table_context.tsx` (lines 247–248) renders all three:

```tsx
{confirmLegacyMlJobsUpgradeModal}
{upgradeConflictsModal}
```

### Where the rule details page gets it wrong

`rule_update_callout.tsx` calls `usePrebuiltRulesUpgrade` and only renders:

```tsx
{rulePreviewFlyout}
```

`confirmLegacyMlJobsUpgradeModal` and `upgradeConflictsModal` are returned from the hook but thrown away — never rendered. So when the ML jobs check fires, the modal never appears, the Promise never resolves, and the upgrade silently stalls.

### Relevant files

| File | Role |
|---|---|
| `rule_management/components/rule_details/rule_update_callout.tsx` | **Bug is here** — missing modal renders |
| `rule_management/hooks/use_prebuilt_rules_upgrade.tsx` | Returns the three UI pieces; `upgradeRulesToResolved` / `upgradeRulesToTarget` both await `confirmLegacyMLJobs()` |
| `rule_management_ui/…/upgrade_prebuilt_rules_table/use_ml_jobs_upgrade_modal/use_ml_jobs_upgrade_modal.tsx` | `confirmLegacyMLJobs()` — shows modal, returns Promise |
| `rule_management_ui/…/rules_table/rules_table/use_async_confirmation.ts` | Promise that only resolves on `confirm()` / `cancel()` button callbacks |
| `rule_management_ui/…/upgrade_prebuilt_rules_table/upgrade_prebuilt_rules_table_context.tsx` | Correctly renders all three modals (lines 247–248) |

---

## Repro Steps

### Prerequisites

1. Kibana running against an Elasticsearch cluster (local or cloud).
2. At least one legacy ML job installed — any job whose ID is in the `affectedJobIds` allowlist (see [`affected_job_ids.ts`](https://github.com/elastic/kibana/blob/main/x-pack/solutions/security/plugins/security_solution/common/machine_learning/affected_job_ids.ts)). Legacy IDs to look for:
   - `v2_*` (e.g. `v2_rare_process_by_host_linux_ecs`)
   - Bare `linux_*` / `windows_*` / `rare_process_*` (V1, no prefix)
   - `v3_*` **without** `_ea` suffix (added to the list in 9.4)
3. At least one prebuilt rule with an available update.

### To install a legacy ML job for testing

Via the ML UI or Dev Tools:
```
PUT _ml/anomaly_detectors/v2_rare_process_by_host_linux_ecs
{ "description": "test legacy job", "analysis_config": { "bucket_span": "15m", "detectors": [{"function":"rare","by_field_name":"process.name","partition_field_name":"host.name"}], "influencers": [] }, "data_description": { "time_field": "@timestamp" } }
```

### Steps to reproduce

1. Navigate to **Security → Rules → Detection rules**.
2. Open the **Rule Updates** tab — confirm at least one rule is listed for upgrade.
3. Click on a rule name to open the rule details page (or navigate directly to a rule that has an update).
4. On the rule details page, find the blue info callout: _"This prebuilt rule has an update available"_.
5. Click the link in the callout (e.g. **"Review and update"**). The rule update flyout opens showing the diff.
6. Click the **"Update rule"** button in the flyout footer.

### Expected result

Either:
- The ML jobs acknowledgement modal appears (consistent with the Rule Updates tab experience), or
- If the modal is intentionally suppressed on single-rule upgrades, the rule is updated and a success toast is shown.

### Actual result

Nothing happens. The flyout may close (or not), but the rule is not updated. No toast, no error, no modal.

### Confirming the upgrade did not occur

Go back to the Rule Updates tab — the rule is still listed as needing an update.

---

## Notes

- This bug only manifests when `legacyJobsInstalled.length > 0` (i.e. at least one installed job ID is in `affectedJobIds`). Without legacy jobs the upgrade proceeds normally.
- The `upgradeConflictsModal` is also missing from the render, which may cause similar silent failures when upgrading rules with field conflicts from the rule details page.
- Issue #239884 tracks the broader problem (modal fires on non-ML rules, no dismiss, misleading job list). This is a distinct sub-bug: the modal is required but never shown, causing a silent hang.

---

## Likely Fix

Add the two missing modal renders to `rule_update_callout.tsx`:

```tsx
// In RuleUpdateCalloutComponent, destructure the extra modals:
const { upgradeReviewResponse, rulePreviewFlyout, openRulePreview,
        confirmLegacyMlJobsUpgradeModal, upgradeConflictsModal } = usePrebuiltRulesUpgrade(…);

// And render them alongside rulePreviewFlyout:
{rulePreviewFlyout}
{confirmLegacyMlJobsUpgradeModal}
{upgradeConflictsModal}
```

**Note:** this still leaves the underlying UX problem from #239884 (modal fires on non-ML rules, no dismiss). But it at least makes the rule details page behave consistently with the Rule Updates tab.
