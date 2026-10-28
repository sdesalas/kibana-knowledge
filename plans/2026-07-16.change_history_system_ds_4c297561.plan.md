---
name: Change history system DS
overview: Register `.kibana_change_history` as a system data stream in KibanaPlugin (mirroring the workflows precedent), exclude it from the broad `.kibana_*` system index pattern, and update unit tests — while treating live serverless conversion as an open rollout risk for the PR description, not a blocker for the code.
todos:
  - id: plugin-descriptor
    content: Add change-history constants, SystemDataStreamDescriptor, tighten KIBANA pattern, register in getSystemDataStreamDescriptors()
    status: completed
  - id: unit-tests
    content: Update KibanaPluginTests for new pattern, DS registration, and non-overlap assertions
    status: completed
  - id: verify
    content: Run :modules:kibana:test --tests org.elasticsearch.kibana.KibanaPluginTests
    status: completed
isProject: false
---

# Register `.kibana_change_history` as System Data Stream

## Context

`.kibana_change_history` is a live serverless data stream still matched by `KIBANA_INDEX_DESCRIPTOR` (`.kibana_*`), so ES treats it as a system **index**. Serverless requires a `SystemDataStreamDescriptor`. The template resource already exists at [`modules/kibana/src/main/resources/org/elasticsearch/kibana/kibana-change-history.json`](modules/kibana/src/main/resources/org/elasticsearch/kibana/kibana-change-history.json).

Precedent: workflows descriptors in [`KibanaPlugin.java`](modules/kibana/src/main/java/org/elasticsearch/kibana/KibanaPlugin.java) (`workflowsEventsSystemDataStreamDescriptor()` / pattern `.workflows~(-events*|…)`).

Out of scope for this change: answering whether PR #121392 conversion is safe on the current serverless fleet. That stays a PR/rollout note.

## Code changes

### 1. [`KibanaPlugin.java`](modules/kibana/src/main/java/org/elasticsearch/kibana/KibanaPlugin.java)

Add constants (same style as workflows):

- `CHANGE_HISTORY_DATA_STREAM_NAME = ".kibana_change_history"`
- `CHANGE_HISTORY_COMPOSABLE_TEMPLATE_RESOURCE = "kibana-change-history.json"`
- `CHANGE_HISTORY_VERSION_VARIABLE = "kibana.change.history.version"` (matches JSON `${kibana.change.history.version}`)
- `CHANGE_HISTORY_MANAGED_INDEX_VERSION_VARIABLE = "kibana.change.history.managed.index.version"`
- `CHANGE_HISTORY_MAPPINGS_VERSION = 3` (matches template `"version": 3`)

Tighten the Kibana system index pattern so it no longer overlaps the data stream name. Per [`SystemIndexDescriptor`](server/src/main/java/org/elasticsearch/indices/SystemIndexDescriptor.java) complement syntax (sample `.system-~(other-*)`):

```java
public static final String KIBANA_SYSTEM_INDEX_PATTERN = ".kibana_~(change_history*)";
```

Use that in `KIBANA_INDEX_DESCRIPTOR` instead of `.kibana_*`. Keep `.setAliasName(".kibana")` (unioned into the automaton separately).

Add `changeHistorySystemDataStreamDescriptor()` modelled on `workflowsEventsSystemDataStreamDescriptor()`:

- Load template via existing `loadWorkflowsComposableTemplate` (reuse as-is; rename not required for the fix)
- Substitute version with `Version.CURRENT` and managed mappings version with `CHANGE_HISTORY_MAPPINGS_VERSION`
- `SystemDataStreamDescriptor.Type.EXTERNAL`, origins `KIBANA_PRODUCT_ORIGIN` / `"kibana"`, `ExecutorNames.DEFAULT_SYSTEM_DATA_STREAM_THREAD_POOLS`

Register it in `getSystemDataStreamDescriptors()` alongside the two workflows descriptors.

`cleanUpFeature` already deletes all registered system data streams — no extra work.

### 2. [`KibanaPluginTests.java`](modules/kibana/src/test/java/org/elasticsearch/kibana/KibanaPluginTests.java)

Update / add assertions mirroring workflows coverage:

- Expected Kibana index pattern → `KibanaPlugin.KIBANA_SYSTEM_INDEX_PATTERN`
- Data stream names list includes `.kibana_change_history`
- Index descriptors do **not** match `.kibana_change_history`
- Index descriptor still matches normal Kibana indices (e.g. `.kibana_1`, `.kibana_alerting_cases`)
- Existing `testKibanaFeaturePassesSystemIndicesOverlapChecks` continues to prove no index/DS pattern overlap

## Verification

```bash
./gradlew :modules:kibana:test --tests org.elasticsearch.kibana.KibanaPluginTests
```

Optionally `:modules:kibana:spotlessJavaCheck` if formatting is touched.

## PR notes (not code)

Call out in the PR body:

- Live on serverless since ~2026-07-15; conversion of an existing DS → system DS depends on #121392 being present on the fleet
- This change is the required descriptor registration; coordinated rollout / disable remains an ops decision pending ES team answers
- Must land before BC3 to be effective on serverless
