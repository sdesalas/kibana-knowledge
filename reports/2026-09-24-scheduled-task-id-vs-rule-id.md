# `scheduledTaskId` vs `rule.id` — when they diverged, and when they didn’t

- **Date:** 2026-09-24
- **Area:** Alerting / Task Manager — rule scheduling
- **Context:** [Libra comment on #291560](https://github.com/elastic/kibana/pull/291560#discussion_r4095981108)
- **History source:** `kibana-main` / `kibana-9.5` (full clone). `kibana-2nd` is shallow and only goes back to 2026-05-20. Version tags from `kibana-9.5`. Backport status from PR labels and kibanamachine comments.

---

## Summary

`scheduledTaskId = rule.id` is the current create/enable convention, but it is not how alerting started.

Task Manager used to mint a random task id. That was the default from alerting’s first release (**7.3.0**, 2019) through **8.0.x**. The switch to “use the rule SO id as the task id” shipped in **8.1.0** (Nov 2021, [#117397](https://github.com/elastic/kibana/pull/117397)). It was labelled `backport:skip` and is **not** in 7.17 or 8.0.

There was no migration of existing tasks. A rule created on 7.x or 8.0 can still carry a random `scheduledTaskId` today if it was never put through the later disable cleanup.

Single `enableRule` still re-enables that leftover task id when it exists. `bulkEnableRules` used to do the same (8.6), then **8.13.0** started always writing `scheduledTaskId: rule.id` while still deciding whether to schedule by looking at the *old* id. That is the split Libra is pointing at.

Response Ops already documented the leftover as a real import/upgrade problem in [#213736](https://github.com/elastic/kibana/issues/213736) (closed): a pre-8.1 rule with a random task UUID, upgraded to 8.5+, exported and re-imported, then re-enabled, can end up with two tasks.

---

## Version table

Checked with `git describe --contains`, `git merge-base --is-ancestor` against `v7.17.29` / `v8.0.1` / `v8.4.3` / `v8.12.2`, plus PR labels and kibanamachine backport comments.

| When | First release | Backported? | What changed |
|---|---|---|---|
| Jun 2019 [#37042](https://github.com/elastic/kibana/pull/37042) | **7.3.0** (`v7.3.0` label; 7.x backport [#39416](https://github.com/elastic/kibana/pull/39416)) | Yes, to `7.x` | Alerting ships. `taskManager.schedule()` is called **without** an `id`. TM mints a random task id. `scheduledTaskId !== rule.id` is normal. |
| 11 Nov 2021 [#117397](https://github.com/elastic/kibana/pull/117397) Ying Mao | **8.1.0** (`v8.1.0~2326`; in `v8.1.0`, not in `v8.0.1` or `v7.17.29`) | **No.** `backport:skip`. Only label is `v8.1.0`. No backport PRs. | New rules schedule with `id: rule.id`. Comment: *“use the same ID for task document as the rule.”* No backfill of existing tasks. |
| 12 Sep 2022 [#139826](https://github.com/elastic/kibana/pull/139826) Ying Mao | **8.5.0** (`v8.5.0~852`; not in `v8.4.3`) | **No.** `backport:skip`. Only label is `v8.5.0`. | Disable treats mismatch as legacy: delete the old task and set `scheduledTaskId: null`. Matching ids keep the task and just disable it. Single `enableRule` re-enables the **existing** task id if it is still there. |
| 16 Nov 2022 [#144216](https://github.com/elastic/kibana/pull/144216) | **8.6.0** (`v8.6.0~484`) | **No.** `backport:skip`. Only label is `v8.6.0`. | First `bulkEnable`. If the old task exists, it **keeps** that `scheduledTaskId`. |
| 17 Jan 2024 [#174656](https://github.com/elastic/kibana/pull/174656) Ersin Erdal | **8.13.0** (`v8.13.0~1269`; not in `v8.12.2`) | **No.** `backport:skip`. Only label is `v8.13.0`. | Bulk enable switches to `bulkSchedule` and **always writes `scheduledTaskId: rule.id`**, but still asks `getShouldScheduleTask(oldId)`. This is the Libra split. |
| 22 Apr 2024 [#180796](https://github.com/elastic/kibana/pull/180796) | **8.14.0** (also labelled `v8.15.0`) | **Yes.** 8.14 backport [#181312](https://github.com/elastic/kibana/pull/181312) | Security `_bulk_action` starts calling alerting `bulkEnable` / `bulkDisable`. Not the source of the rewrite — it just puts Security on the 8.13 bulk-enable path. |

`git tag --contains` sorts alphabetically (`v8.10` before `v8.5`), so first-containing-tag lists are misleading. The versions above come from `describe --contains` plus ancestor checks.

---

## What the two enable paths do today

**`enableRule` (single, since 8.5):** if `attributes.scheduledTaskId` exists and the task is still there (and not `Unrecognized`), enable *that* id. Do not rewrite `scheduledTaskId`. Only schedule `rule.id` when the old task is missing.

**`bulkEnableRules` (since 8.13):** always persist `scheduledTaskId: rule.id`. `getShouldScheduleTask` looks at the *old* id. If that old task exists, it does **not** schedule `rule.id`, then later tries to enable the rewritten `rule.id` task — which was never created.

Official disable (single and bulk, since 8.5) still has the mismatch branch: if `scheduledTaskId !== rule.id`, delete the old task and set the field to `null`. Before 8.5, disable always nulled the field and deleted the task.

So a disabled rule that went through official `disable` / `bulkDisable` should be `scheduledTaskId: null` or `=== rule.id`. Both of those work with bulk enable.

---

## What leftover state can still exist

1. **Enabled rule created on 7.3–8.0, never disabled.** Still has a random `scheduledTaskId`. 7.17 never got [#117397](https://github.com/elastic/kibana/pull/117397) (`backport:skip`, not in `v7.17.29`). Same for 8.0 (`not in v8.0.1`). Clusters that lived on 7.17 for years and then upgraded can still have this on every rule that stayed enabled.

2. **Disabled + old id still set + old task still exists.** Official disable cleans this up. It can still appear if `enabled` became false without going through `disable` / `bulkDisable`, or via the export/re-import path in [#213736](https://github.com/elastic/kibana/issues/213736).

3. **[#213736](https://github.com/elastic/kibana/issues/213736) (Response Ops, closed).** Pre-8.1 rule, upgrade to 8.5+, export/re-import (which disables), then re-enable: a *new* `rule.id` task is created while the old random-id task can still be around. Two tasks for one rule. Same leftover family as the Libra comment.

Disable still has the `scheduledTaskId !== rule.id` branch in current `main`, so Alerting still treats mismatch as a supported existing state — not a dead code path.

---

## Relation to #291560

Overwrite `disabled → enabled` now calls `bulkEnableRules` instead of `enableRule`. That is the 8.13 bulk-enable behaviour, not a new Security rewrite.

Typical overwrite inputs after an official disable (`null` or `=== rule.id`) are fine. The Libra case is the leftover mismatch where the old task is still present. That leftover has been possible since 7.3, became a named supported state in 8.5, and has been a known import/upgrade issue since at least [#213736](https://github.com/elastic/kibana/issues/213736).

---
