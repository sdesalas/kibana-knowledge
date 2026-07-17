# ML jobs upgrade modal gates all prebuilt rule upgrades

**Date:** 2026-07-17  
**Area:** Security Solution — Detection Engine / Rule Management UI  
**Status:** Code-path confirmed; matches known open bug  
**Related:**
- [kibana#239884](https://github.com/elastic/kibana/issues/239884) — open product bug: modal on every prebuilt upgrade when legacy ML jobs exist (no rule-type check)
- [sdh-security-team#1698](https://github.com/elastic/sdh-security-team/issues/1698) — closed SDH; confirmed same as #239884
- [#128334](https://github.com/elastic/kibana/pull/128334) — original V1/V2 → V3 gate (8.3)
- [#255339](https://github.com/elastic/kibana/pull/255339) — expanded `affectedJobIds` for V3 → `_ea` (9.4)

---

## Summary

Upgrading prebuilt detection rules from the **Rule updates** tab shows a blocking confirmation modal about outdated ML jobs whenever **any** job in `affectedJobIds` is still installed — including when the rules being upgraded are not ML rules.

Clicking **Load rules** continues that one upgrade action; Cancel / X abandons it. There is no dismiss persistence — the next upgrade click shows the modal again. Reports of the page “not updating” are consistent with waiting on this gate (upgrade does not proceed until **Load rules**).

In 9.4, `affectedJobIds` was expanded to include stock V3 (non-EA) Security ML jobs, while the modal copy still describes the older V1/V2 → V3 migration. Anyone with those V3 jobs installed will hit this on every upgrade.

---

## Prior reports / eng confirmation

### [kibana#239884](https://github.com/elastic/kibana/issues/239884) (OPEN)

> When there exist one or more legacy ML jobs in the system, we show the "ML rule updates may override your existing rules" modal on every prebuilt rule upgrade, even if the upgraded rule is not an ML rule. There are no checks for the current prebuilt rule being upgraded.

Asks for product input; ideal fix called out as removing the modal / automating required ML job installation.

Same behavior has also been confirmed in prior support triage as matching #239884: non-ML rules are still gated; environments without leftover affected jobs do not see the modal. No need for a duplicate engineering ticket — track / fix via #239884.

---

## How this can surface

Typical Rule Updates experience when the gate fires:

- Modal title: **ML rule updates may override your existing rules**
- Body still describes the old V1/V2 → V3 migration + **ML job compatibility** docs link
- Actions: **Cancel** / red **Load rules**
- An “Affected jobs” list appears under the copy

Because the modal is passed the full installed security-jobs list (not `legacyJobsInstalled`), that list can look like ordinary Security ML jobs — for example `auth_*`, `high_count_*`, or other current module jobs — mixed with (or above) the allowlisted legacy / V3-non-EA IDs that actually triggered the gate. A short / scrolled view of the list can make it seem like unrelated jobs are “affected.”

So in practice this may look like:

1. **Any leftover allowlisted job** still installed → modal on every upgrade action, including non-ML rules.
2. **Misleading job list** → visible rows are mostly current jobs; the real trigger may be further down or easy to miss.
3. **Wrong remediation** → stopping/deleting the visible current jobs does not clear the gate; only removing IDs in `affectedJobIds` does.
4. **Env A vs env B** → one deployment shows the modal and another does not, if only one still has allowlisted job configs in Elasticsearch.

---

## Key findings (high confidence)

1. **Trigger is installed jobs, not rule type.**  
   `confirmLegacyMLJobs()` runs before every upgrade path in `use_prebuilt_rules_upgrade.tsx`. The modal opens if `jobs.filter(job => affectedJobIds.includes(job.id)).length > 0`.

2. **No persistence.**  
   **Load rules** only continues that upgrade action. Each later upgrade action re-checks and re-prompts.

3. **List widened in 9.4 without updating UX.**  
   [#255339](https://github.com/elastic/kibana/pull/255339) added all V3 non-EA job IDs to `affectedJobIds`. Modal text still says users are running V1/V2 jobs and that “new V3 jobs” have been released.

4. **Affected-jobs list in the modal is misleading.**  
   Hook filters `legacyJobsInstalled` for the show/hide decision, but passes full `jobs` into the modal — so current jobs (e.g. `auth_*`, `high_count_*`) can appear under “Affected jobs” even though they are not on the allowlist.

---

## Relevant code

| Piece | Path |
|---|---|
| Gate on every upgrade | `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_management/hooks/use_prebuilt_rules_upgrade.tsx` |
| Modal hook / condition | `.../upgrade_prebuilt_rules_table/use_ml_jobs_upgrade_modal/use_ml_jobs_upgrade_modal.tsx` |
| Modal UI + job list | `.../use_ml_jobs_upgrade_modal/ml_jobs_upgrade_modal.tsx` |
| Stale V1/V2 copy | `.../use_ml_jobs_upgrade_modal/translations.tsx` |
| Job ID allowlist | `x-pack/solutions/security/plugins/security_solution/common/machine_learning/affected_job_ids.ts` |
| Related dismissible callout (same list) | `.../ml_job_compatibility_callout/index.tsx` |

Condition:

```ts
const legacyJobsInstalled = jobs.filter((job) => affectedJobIds.includes(job.id));
// ...
if (legacyJobsInstalled.length > 0) {
  return confirmLegacyMLJobs(); // shows modal
}
return true;
```

---

## Local reproduction steps

Requires a Kibana build that includes [#255339](https://github.com/elastic/kibana/pull/255339) (9.4+) for the modal to treat V3 non-EA jobs as affected. The gate itself is older (V1/V2 leftovers also trigger it).

### How to get affected jobs locally

These are **not** Fleet / EPR packages. Job definitions ship as **Kibana ML data recognizer modules** (`security_linux` / `security_windows` under the ML plugin).

On **current main**, those modules only install `*_ea` job IDs — and those are **not** in `affectedJobIds`. A fresh install of Security ML jobs on today’s Kibana will **not** trigger the modal.

To get an affected job ID installed:

1. **Realistic path:** run a **pre-#255339 / pre-9.4** Kibana, install a Security ML job from the ML popover (e.g. `v3_rare_process_by_host_linux_ecs`), then either test Rule Updates there, or upgrade Kibana against the same Elasticsearch so the old job config remains.
2. **V1/V2 leftovers:** same idea but much older Kibana — those modules have been gone for years; only upgrade leftovers trigger that path.
3. **Quick hack:** create any anomaly detection job whose `id` matches a string in `affectedJobIds`. The modal only checks installed job IDs.

### Setup

1. Start a local Security stack (`yarn es` + `yarn start`, or serverless equivalent) that can see at least one installed job from `affectedJobIds` (see above).
2. Confirm the job exists under **Stack Management → Machine Learning → Anomaly Detection Jobs** (or Security ML popover), e.g.:
   - V3 non-EA: `v3_rare_process_by_host_linux_ecs`
   - V1/V2 leftover: `v2_rare_process_by_host_linux_ecs` / `rare_process_by_host_linux_ecs`
3. In **Security → Rules → Detection rules (SIEM)**:
   - Install a package of Elastic prebuilt rules (or ensure some are already installed).
   - Leave some rules with available updates (or bump/wait until the Rule updates tab shows upgradeable rules). Prefer including **non-ML** rules among the upgradeable set.

### Reproduce

1. Go to **Rules → Rule updates** (upgrade prebuilt rules table).
2. Select one or more **non-ML** upgradeable rules.
3. Click upgrade / update.
4. **Expected (current behavior):** modal appears:
   - Title: “ML rule updates may override your existing rules”
   - Body mentions V3 / V1/V2 jobs (copy may not match which jobs you installed)
   - Lists installed security jobs under “Affected jobs”
5. Confirm (“Load rules”) — upgrade proceeds for that action.
6. Immediately upgrade another selection (or the same remaining rules).
7. **Expected:** modal appears **again**.

### Control (modal should not show)

1. Identify jobs whose IDs are actually in `affectedJobIds` (scroll the full modal list — do not trust only the first visible rows).
2. Stop and delete those allowlisted jobs (or migrate fully to `*_ea` jobs and remove the old ones). Deleting unrelated `auth_*` / `high_count_*` jobs will not clear the gate.
3. Retry an upgrade of non-ML rules.
4. **Expected:** no ML upgrade modal; upgrade runs without that prompt.

---

## Impact

- Friction scales with number of upgrade actions (batch size), not with whether rules are ML-related.
- Large upgrade queues (hundreds/thousands of prebuilt rules) require clicking **Load rules** repeatedly unless everything is upgraded in one action.
- On 9.4+, environments that still run stock V3 Security ML jobs are newly in-scope for this gate, even if they never had V1/V2 jobs.
- Misleading “Affected jobs” list makes remediation harder (easy to delete the wrong jobs).

---

## Suggested product fixes (for detection-engineering)

1. Do not gate non-ML rule upgrades on this modal (or only show when upgrading rules that reference affected jobs).
2. Add dismiss / once-per-session (or once-per-version) persistence — the related callout already uses `CallOutSwitcher`.
3. Update modal copy for the V3 → `_ea` migration, or split lists/messages by generation.
4. Pass `legacyJobsInstalled` into the modal list, not the full `jobs` array.

---

## Open for local verification

- [ ] Confirm end-to-end on local 9.4+ with only a V3 non-EA job installed
- [ ] Confirm bulk “upgrade all” shows the modal once per action (not once per rule)
- [ ] Confirm deleting only allowlisted jobs (not the visible `auth_*` ones) removes the prompt
- [ ] On local repro, confirm the modal list can include non-allowlisted jobs alongside the true trigger ID(s)