# Bootstrap fails: missing `kibanaReact` in plugin manifests

- **Date:** 2026-09-14
- **Seen on:** `main` after pull (optimizer, `yarn kbn bootstrap`)
- **Caused by:** [#289852](https://github.com/elastic/kibana/pull/289852) (`observabilityAlerting` missing `kibanaReact`) and [#289402](https://github.com/elastic/kibana/pull/289402) (Nightshift, same miss via `@kbn/workflows-ui`)

`yarn kbn bootstrap` dies in webpack. Two plugins import `@kbn/kibana-react-plugin/public` without listing `kibanaReact` in `requiredPlugins` / `requiredBundles`. Optimizer treats that as a compile error, so bootstrap never finishes.

---

## Console (`start-bootstrap`)

```
info [283/285] initial bundle builds complete
ERROR webpack compile errors
   │ERROR [observabilityAlerting] build
       │ERROR Optimizations failure.
       │
       │          ERROR in ./public/application/breadcrumbs.ts 10:0-70
       │          Module not found: Error: import [@kbn/kibana-react-plugin/public] references a public export of the [kibanaReact] bundle, but that bundle is not in the "requiredPlugins" or "requiredBundles" list in the plugin manifest [/Users/sdesalas/Code/sdesalas/kibana-2nd/x-pack/solutions/observability/plugins/observability_alerting/kibana.jsonc]
       │
       │          ERROR in /Users/sdesalas/Code/sdesalas/kibana-2nd/x-pack/solutions/observability/plugins/observability_alerting/kibana.jsonc
       │          Bundle for [observabilityAlerting] lists [alertingVTwo] as a required bundle, but does not use it. Please remove it.
       │
       │          webpack 5.96.1 compiled with 2 errors in 16743 ms
   │ERROR [nightshiftInvestigations] build
       │ERROR Optimizations failure.
       │
       │          ERROR in ../../../../../src/platform/packages/shared/kbn-workflows-ui/src/api/use_workflows_api.ts 11:0-60
       │          Module not found: Error: import [@kbn/kibana-react-plugin/public] references a public export of the [kibanaReact] bundle, but that bundle is not in the "requiredPlugins" or "requiredBundles" list in the plugin manifest [/Users/sdesalas/Code/sdesalas/kibana-2nd/x-pack/platform/plugins/shared/nightshift_investigations/kibana.jsonc]
       │           @ ../../../../../src/platform/packages/shared/kbn-workflows-ui/src/api/index.ts
       │           @ ../../../packages/shared/kbn-investigation-output/src/use_investigation_state.ts
       │           @ ./public/components/investigation_detail_flyout.tsx
       │
       │          webpack 5.96.1 compiled with 9 errors in 108742 ms
ERROR webpack issue
```

---

## What’s going on

The alerting-shaped one is **RNA / Alerting v2**, not ResponseOps platform alerting. Owner: Dominique Clarke. Nightshift is a second, separate miss (via `@kbn/workflows-ui`) — not RNA. Nightshift repeats that same `kibanaReact` miss from eight other `@kbn/workflows-ui` files.

| Plugin | Owner | Author | PR | Commit |
|---|---|---|---|---|
| `observabilityAlerting` | `@elastic/rna-project-team` | Dominique Clarke | [#289852](https://github.com/elastic/kibana/pull/289852) | [`674ae0832925`](https://github.com/elastic/kibana/commit/674ae0832925b5c4b2513b618af14ecf24327b34) |
| `nightshiftInvestigations` | Nightshift | Jason Rhodes | [#289402](https://github.com/elastic/kibana/pull/289402) | [`c0034f7c9676`](https://github.com/elastic/kibana/commit/c0034f7c9676be0893ba79420fe9095a049e636b) |

`observabilityAlerting` imports `kibanaReact` from `breadcrumbs.ts` (`reactRouterNavigate`) but does not list it in the manifest. The same manifest listed `alertingVTwo` as a required plugin **and** a required bundle; optimizer then said the bundle is unused. Nightshift does not import `kibanaReact` itself — `@kbn/workflows-ui` does, pulled in through the investigation flyout.

Jest does not need these bundles. `yarn start` does.

---

## Fix

Add `kibanaReact` to `requiredPlugins`. Drop the unused `alertingVTwo` bundle. Locally this unblocked bootstrap (second `start-bootstrap` succeeded).

```diff
--- a/x-pack/solutions/observability/plugins/observability_alerting/kibana.jsonc
+++ b/x-pack/solutions/observability/plugins/observability_alerting/kibana.jsonc
@@ -9,8 +9,8 @@
     "id": "observabilityAlerting",
     "browser": true,
     "server": false,
-    "requiredPlugins": ["alertingVTwo", "triggersActionsUi"],
+    "requiredPlugins": ["alertingVTwo", "kibanaReact", "triggersActionsUi"],
     "optionalPlugins": [],
-    "requiredBundles": ["alertingVTwo"]
+    "requiredBundles": []
   }
 }
```

```diff
--- a/x-pack/platform/plugins/shared/nightshift_investigations/kibana.jsonc
+++ b/x-pack/platform/plugins/shared/nightshift_investigations/kibana.jsonc
@@ -11,6 +11,7 @@
     "configPath": ["xpack", "nightshift_investigations"],
     "requiredPlugins": [
+      "kibanaReact",
       "taskManager"
     ],
```
