# Alerting Framework — ChangeTrackingService Initialization

## Overview

`ChangeTrackingService` is an optional service in the alerting plugin that logs rule change history to a dedicated data stream. It is gated behind a config flag that defaults to `false`.

## Config Flag

```
xpack.alerting.ruleChangeTracking.enabled   (default: false)
xpack.alerting.ruleChangeTracking.scope     (default: ['security'])
```

Defined in `x-pack/platform/plugins/shared/alerting/server/config.ts` lines 87–90.

Scope is an array of rule type solutions: `'security' | 'observability' | 'stack' | 'all'`.

## Plugin Lifecycle

### Constructor
`ChangeTrackingService` is instantiated only if the flag is enabled:

```typescript
// plugin.ts ~line 275
if (this.config.ruleChangeTracking.enabled) {
  this.changeTrackingService = new ChangeTrackingService(this.logger, this.kibanaVersion);
}
```

### setup()
Rule types register their solutions. For each registered rule type, if its solution is in scope, the service registers a `ChangeHistoryClient` for that solution:

```typescript
// plugin.ts ~line 574
if (this.changeTrackingService) {
  const { scope } = this.config.ruleChangeTracking;
  if (scope.includes('all') || scope.includes(ruleType.solution)) {
    this.changeTrackingService.register(ruleType.solution);
  }
}
```

### start()
Initialization is called fire-and-forget — `start()` is synchronous and does not await this:

```typescript
// plugin.ts ~line 658
changeTrackingService?.initialize(core.elasticsearch.client.asInternalUser);
```

`ChangeTrackingService.initialize()` is also not async — it internally fires `void this.initializeAll()`:

```typescript
// change_tracking/index.ts ~line 98
initialize(elasticsearchClient: ElasticsearchClient) {
  void this.initializeAll(elasticsearchClient).catch((err) => this.logger.error(err));
}
```

## Data Stream

`ChangeHistoryClient` (from `@kbn/change-history`) creates a hidden data stream:
- Dataset: `alerting-rules`
- Created via `DataStreamClient.initialize()` with `lazyCreation: false`
- One client per solution module (security, observability, stack)

The data stream name follows the pattern `.ds-*alerting-rules*`.

## isInitialized() Signal

The only observable completion signal is:

```typescript
// ChangeTrackingService
isInitialized(module: RuleTypeSolution): boolean {
  return !!this.clients[module]?.isInitialized();
}

// ChangeHistoryClient
isInitialized(): boolean {
  return !!this.client;  // set after DataStreamClient.initialize() resolves
}
```

There is no event, observable, or promise exposed at the plugin level. External callers must poll.

## FTR Testing Pattern

The alerting FTR suite already tests async startup initialization (index templates, component templates, data streams) using `retry.try()`:

```typescript
// Wait for data stream to appear
await retry.try(async () => {
  const result = await es.indices.getDataStream({ name: '.ds-*alerting-rules*' });
  expect(result.data_streams.length).to.eql(1);
});
```

Reference: `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group4/alerts_as_data/install_resources.ts`

For the **disabled** case, no retry is needed — a direct check immediately after startup is sufficient since the data stream will never be created.

## FTR Config Pattern

The common FTR config factory is at:
`x-pack/platform/test/alerting_api_integration/common/config.ts`

It accepts a `CreateTestConfigOptions` object and maps options to `--xpack.alerting.*` CLI args. To add `ruleChangeTracking.enabled`, add it to `CreateTestConfigOptions` and wire it as a CLI arg:

```typescript
// In CreateTestConfigOptions:
ruleChangeTrackingEnabled?: boolean;

// In serverArgs:
...(ruleChangeTrackingEnabled ? [`--xpack.alerting.ruleChangeTracking.enabled=true`] : []),
```

## Relevant Files

| File | Purpose |
|------|---------|
| `x-pack/platform/plugins/shared/alerting/server/plugin.ts` | Plugin lifecycle, where service is constructed/started |
| `x-pack/platform/plugins/shared/alerting/server/config.ts` | Config schema and defaults |
| `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/change_tracking/index.ts` | ChangeTrackingService implementation |
| `x-pack/platform/test/alerting_api_integration/common/config.ts` | FTR config factory |
| `x-pack/platform/test/alerting_api_integration/spaces_only/tests/alerting/group4/alerts_as_data/install_resources.ts` | Reference FTR test for startup resource initialization |