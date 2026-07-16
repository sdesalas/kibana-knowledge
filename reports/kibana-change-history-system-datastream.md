# `.kibana_change_history` — Missing SystemDataStreamDescriptor

**Date:** 2026-07-16  
**Severity:** SEV4  
**Status:** Active incident

---

## Summary

`.kibana_change_history` is a data stream that went live on serverless with Workflows GA (2026-07-15). It is currently caught by the broad `KIBANA_INDEX_DESCRIPTOR` pattern (`.kibana_*`) in `KibanaPlugin.java`, which registers it as a **system index** — not a **system data stream**. On serverless, Elasticsearch enforces a stricter separation: a data stream name matching a system index pattern without a corresponding `SystemDataStreamDescriptor` causes errors. Stateful/local deployments don't enforce this and appear fine.

---

## Links

### Incident
- **Incident channel:** [#incident-3371-kibana-change-history-not-registered-as-systemdatastream-in-elasti](https://elastic.slack.com/archives/C0BHNM44YER)
- **Rootly:** https://root.ly/i5vu1c
- **PagerDuty:** https://elastic.pagerduty.com/incidents/Q2FNVJW7GAPA0K

### Slack threads
- **Main discussion thread (kbn/change-history):** https://elastic.slack.com/archives/C09QUB06E4Q/p1783672107920349
- **Older thread on converting normal data streams → system data streams:** https://elastic.slack.com/archives/C8UUBNASY/p1736443827421949
- **First error report (serverless):** https://elastic.slack.com/archives/C05NJL80DB8/p1783671431524999
- **After ILM→DLM change error:** https://elastic.slack.com/archives/C0D8P2XK5/p1784190187562909

### Elasticsearch
- **PR #145822 — same problem, same fix, applied to workflows data streams** (`.workflows-events` and `.workflows-execution-data-stream-logs`): https://github.com/elastic/elasticsearch/pull/145822 — commit [`dc7fae0`](https://github.com/elastic/elasticsearch/commit/dc7fae0c169c0ae9a6d6d5eaffc4be3ccef49811)
- **PR #121392 — "Converting an Existing Data Stream to a System DataStream is Broken" (MERGED, v8.18/v8.19/v9.0/v9.1):** https://github.com/elastic/elasticsearch/pull/121392
- **`KibanaPlugin.java` (where the fix lives):** [`modules/kibana/src/main/java/org/elasticsearch/kibana/KibanaPlugin.java`](https://github.com/elastic/elasticsearch/blob/main/modules/kibana/src/main/java/org/elasticsearch/kibana/KibanaPlugin.java#L86)

---

## Root Cause

`KIBANA_INDEX_DESCRIPTOR` uses pattern `.kibana_*`, which incidentally matches `.kibana_change_history`. This registers the data stream as a system **index**, not a system **data stream**. ES serverless rejects this at runtime.

Yngrid diagnosed this in the incident thread:

> *"essentially we need to declare this system dataStream in es — it's not enough to just use a system pattern for the name, if it's a system dataStream es expects a SystemDataStreamDescriptor as well"*
>
> *"essentially `SystemDataStreamDescriptor` doesn't allow to create the shell for the system dataStream and you would need to declare mappings also there"*

The template file already exists locally at:
```
modules/kibana/src/main/resources/org/elasticsearch/kibana/kibana-change-history.json
```
It defines the composable index template with mappings for `user`, `event`, `object`, `span`, `tags`, `metadata`, `kibana.space_ids`, and `service.version`.

It works fine locally because stateful ES doesn't enforce the system index vs system data stream distinction at runtime. Rudolf confirmed the live-on-serverless complication:

> *"This is live on serverless correct? IIRC it's far from trivial to change a system index into a datastream once it's live"*

Yngrid confirmed it went live the previous Tuesday. Yngrid also found this open issue about the conversion problem: https://github.com/elastic/elasticsearch/pull/121392

---

## Why PR #145822 is the exact precedent

PR #145822 solved the **identical problem** for two workflows data streams (`.workflows-events` and `.workflows-execution-data-stream-logs`). Those streams were also caught by an overly broad system index pattern. The fix:

1. Added a `SystemDataStreamDescriptor` for each stream using a composable template loaded from a JSON resource file.
2. Tightened the system index pattern to explicitly exclude the data stream names using complement syntax (e.g. `.workflows~(-events*|-execution-data-stream-logs*)`).

The resulting code in `KibanaPlugin.java` — `workflowsEventsSystemDataStreamDescriptor()` and `workflowsExecutionDataStreamLogsSystemDataStreamDescriptor()` — is the direct template for the change history fix. Yngrid confirmed:

> *"the only one available as of now is `workflowsExecutionDataStreamLogsSystemDataStreamDescriptor` — but currently it's all messy, because the mappings are in both places `es` and `kibana`"*

> *"I wouldn't trust the commit, just take the current picture as guide — because iirc we needed some feedback loops for workflows"*

So use the **current code in `KibanaPlugin.java`** as the template, not the raw commit diff.

---

## Conversion Risk (Open Question)

Because `.kibana_change_history` has been live on serverless since ~2026-07-15, there are likely existing backing indices already written as a data stream but **currently registered under the `.kibana_*` system index pattern**. Adding a `SystemDataStreamDescriptor` retroactively means ES must re-classify those as a system data stream rather than a system index — and this is a known problem area.

Rudolf flagged this immediately in the discussion:

> *"This is live on serverless correct? IIRC it's far from trivial to change a system index into a datastream once it's live"*

Yngrid then found a directly relevant open issue:

> *"Found this one: [Converting an Existing Data Stream to a System DataStream is Broken](https://github.com/elastic/elasticsearch/pull/121392)"*

The key questions that need answers from the ES team (Arpad / Mary were pulled into the incident for exactly this):

1. Is it safe to add a `SystemDataStreamDescriptor` for a data stream that is already live on serverless and currently matched by a `SystemIndexDescriptor` pattern?
2. Will ES handle the re-registration cleanly on next cluster restart / upgrade, or will it conflict with the existing backing indices?
3. Is there a migration step needed, or does the descriptor addition alone resolve it?

Until these are confirmed, the conversion approach carries risk on existing serverless projects. Rudolf also asked whether the feature could be disabled while this is resolved:

> *"can we disable it?"*

This remains an open option if the conversion turns out to be unsafe without a migration path.

---

## Fix Required

Add a `SystemDataStreamDescriptor` for `.kibana_change_history` in `KibanaPlugin.java`, modelled on `workflowsEventsSystemDataStreamDescriptor()`:

1. Add constants for the data stream name, template resource, version variable, and mappings version.
2. Add a `changeHistorySystemDataStreamDescriptor()` method that loads `kibana-change-history.json` and returns a `SystemDataStreamDescriptor` with `Type.EXTERNAL`.
3. Register it in `getSystemDataStreamDescriptors()`.
4. Exclude `.kibana_change_history*` from `KIBANA_INDEX_DESCRIPTOR` (pattern `.kibana_*`) using complement syntax — same trick as `WORKFLOWS_SYSTEM_INDEX_PATTERN` excludes `.workflows-events*` and `.workflows-execution-data-stream-logs*`.

Must land **before BC3** to be effective on serverless. Steven flagged the timing:

> *"Only thing is that it would have to land in `elasticsearch` before BC3"*

Must stay a system data stream (not demoted to hidden). Rudolf on why:

> *"It needs to be a system ds/index because it stores potentially sensitive info that not all users should have access to. Otherwise you can see changes from other users on saved objects in other spaces."*
