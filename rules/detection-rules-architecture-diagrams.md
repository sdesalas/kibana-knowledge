# Detection Rules Architecture Diagrams

This document provides visual representations of the Detection Rules architecture in Kibana's Security Solution.

## Plugin Initialization Flow

This diagram shows how the three main plugins initialize during Kibana startup, progressing through Setup and Start phases.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              KIBANA STARTUP SEQUENCE                                     │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────┐         ┌─────────────────────┐         ┌─────────────────────┐
  │   ALERTING PLUGIN   │         │  RULE REGISTRY      │         │ SECURITY SOLUTION   │
  │   (Platform Layer)  │         │  PLUGIN             │         │ PLUGIN              │
  └──────────┬──────────┘         └──────────┬──────────┘         └──────────┬──────────┘
             │                               │                               │
             ▼                               ▼                               ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────┐
  │                                    SETUP PHASE                                        │
  └──────────────────────────────────────────────────────────────────────────────────────┘
             │                               │                               │
             ▼                               ▼                               ▼
  ┌─────────────────────┐         ┌─────────────────────┐         ┌─────────────────────┐
  │ • RuleTypeRegistry  │         │ • RuleDataService   │         │ • createConfig()    │
  │ • RulesClientFactory│         │   .initializeIndex()│         │ • initSavedObjects()│
  │ • AlertsService     │◄────────│ • Persistence       │◄────────│ • initUiSettings()  │
  │ • TaskRunnerFactory │         │   RuleTypeWrapper   │         │ • ProductFeatures   │
  └─────────┬───────────┘         └─────────────────────┘         │   .setup()          │
            │                                                      └──────────┬──────────┘
            │                                                                 │
            │    ┌────────────────────────────────────────────────────────────┘
            │    │
            ▼    ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────┐
  │                         DETECTION RULE TYPES REGISTRATION                             │
  │                                                                                       │
  │   plugins.alerting.registerType(                                                      │
  │     createSecurityRuleTypeWrapper(securityRuleTypeOptions)(                           │
  │       createPersistenceRuleTypeWrapper({ ruleDataClient, logger })(                   │
  │         create*AlertType()  ──────────────────────────────────────┐                   │
  │       )                                                           │                   │
  │     )                                                             ▼                   │
  │   )                                                    ┌─────────────────────┐        │
  │                                                        │ Rule Types:         │        │
  │                                                        │ • siem.eqlRule      │        │
  │                                                        │ • siem.esqlRule     │        │
  │                                                        │ • siem.queryRule    │        │
  │                                                        │ • siem.savedQueryRule│       │
  │                                                        │ • siem.mlRule       │        │
  │                                                        │ • siem.thresholdRule│        │
  │                                                        │ • siem.indicatorRule│        │
  │                                                        │ • siem.newTermsRule │        │
  │                                                        └─────────────────────┘        │
  └──────────────────────────────────────────────────────────────────────────────────────┘
             │                               │                               │
             ▼                               ▼                               ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────┐
  │                                    START PHASE                                        │
  └──────────────────────────────────────────────────────────────────────────────────────┘
             │                               │                               │
             ▼                               ▼                               ▼
  ┌─────────────────────┐         ┌─────────────────────┐         ┌─────────────────────┐
  │ • RulesClient       │         │ • RuleDataClient    │         │ • ruleMonitoring    │
  │   Factory ready     │         │   (read/write)      │         │   .start()          │
  │ • Task Manager      │         │                     │         │ • licenseService    │
  │   schedules rules   │         │                     │         │   .start()          │
  │ • AlertsService     │         │                     │         │ • endpointService   │
  │   ready to write    │         │                     │         │   .start()          │
  └─────────────────────┘         └─────────────────────┘         └─────────────────────┘
```

### Explanation

**Setup Phase** - Plugins register their capabilities and rule types:
- The **Alerting Plugin** creates the `RuleTypeRegistry` where all rule types are registered
- The **Rule Registry Plugin** provides the `createPersistenceRuleTypeWrapper` for alerts-as-data
- The **Security Solution Plugin** wraps each rule type with `createSecurityRuleTypeWrapper` and registers them

**Start Phase** - Services become operational:
- `RulesClient` factory is ready to create per-request clients
- `Task Manager` begins scheduling rule executions
- Security services (monitoring, licensing, endpoint) start running

### Key Files

| Component | File Path |
|-----------|-----------|
| Alerting Plugin | `x-pack/platform/plugins/shared/alerting/server/plugin.ts` |
| Rule Type Registry | `x-pack/platform/plugins/shared/alerting/server/rule_type_registry.ts` |
| Rules Client Factory | `x-pack/platform/plugins/shared/alerting/server/rules_client_factory.ts` |
| Alerts Service | `x-pack/platform/plugins/shared/alerting/server/alerts_service/alerts_service.ts` |
| Rule Registry Plugin | `x-pack/platform/plugins/shared/rule_registry/server/plugin.ts` |
| Persistence Wrapper | `x-pack/platform/plugins/shared/rule_registry/server/utils/create_persistence_rule_type_wrapper.ts` |
| Security Solution Plugin | `x-pack/solutions/security/plugins/security_solution/server/plugin.ts` |
| Security Rule Type Wrapper | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` |
| Rule Type Creators | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/` |
| Config Creation | `x-pack/solutions/security/plugins/security_solution/server/config.ts` |
| Saved Objects Init | `x-pack/solutions/security/plugins/security_solution/server/saved_objects.ts` |

---

## Rules Client Hierarchy & Request Flow

This diagram illustrates how an HTTP request flows through the system when creating or updating a detection rule, showing the layered architecture from API routes to database persistence.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                  API REQUEST FLOW                                        │
└─────────────────────────────────────────────────────────────────────────────────────────┘

                              ┌─────────────────────────┐
                              │      HTTP Request       │
                              │  (Create/Update Rule)   │
                              └───────────┬─────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              SECURITY SOLUTION ROUTES                                    │
│                                                                                          │
│   x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/      │
│   rule_management/api/rules/                                                             │
│                                                                                          │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐        │
│   │ create_rule/   │  │ update_rule/   │  │ patch_rule/    │  │ delete_rule/   │        │
│   │ route.ts       │  │ route.ts       │  │ route.ts       │  │ route.ts       │        │
│   └───────┬────────┘  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘        │
│           │                   │                   │                   │                  │
└───────────┼───────────────────┼───────────────────┼───────────────────┼──────────────────┘
            │                   │                   │                   │
            └───────────────────┴─────────┬─────────┴───────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                            DETECTION RULES CLIENT                                        │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │  IDetectionRulesClient (detection_rules_client_interface.ts)                    │   │
│   │                                                                                 │   │
│   │  Created per-request in RequestContextFactory with:                             │   │
│   │  • rulesClient (from Alerting)      • mlAuthz                                   │   │
│   │  • actionsClient                    • productFeaturesService                    │   │
│   │  • savedObjectsClient               • license                                   │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                          │                                               │
│   ┌──────────────────────────────────────┼──────────────────────────────────────────┐   │
│   │                            METHODS (methods/)                                    │   │
│   │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │   │
│   │  │ create_rule  │ │ update_rule  │ │ patch_rule   │ │ delete_rule  │            │   │
│   │  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘            │   │
│   │         │                │                │                │                    │   │
│   │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │   │
│   │  │ import_rule  │ │ import_rules │ │upgrade_pre..│ │revert_pre..  │            │   │
│   │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘            │   │
│   └─────────────────────────────────────┬───────────────────────────────────────────┘   │
│                                         │                                                │
│   ┌─────────────────────────────────────┼───────────────────────────────────────────┐   │
│   │                          CONVERTERS (converters/)                                │   │
│   │                                     │                                            │   │
│   │  ┌─────────────────────────────────────────────────────────────────────────┐    │   │
│   │  │  convertRuleResponseToAlertingRule()                                     │    │   │
│   │  │  • Transforms RuleCreateProps → Alerting Rule format                     │    │   │
│   │  │  • Snake_case → camelCase                                                │    │   │
│   │  │  • Maps rule type to alertTypeId                                         │    │   │
│   │  └─────────────────────────────────────────────────────────────────────────┘    │   │
│   │  ┌─────────────────────────────────────────────────────────────────────────┐    │   │
│   │  │  convertAlertingRuleToRuleResponse()                                     │    │   │
│   │  │  • Transforms Alerting Rule → RuleResponse                               │    │   │
│   │  │  • CamelCase → snake_case                                                │    │   │
│   │  │  • Validates with Zod schema                                             │    │   │
│   │  └─────────────────────────────────────────────────────────────────────────┘    │   │
│   └─────────────────────────────────────┬───────────────────────────────────────────┘   │
│                                         │                                                │
└─────────────────────────────────────────┼────────────────────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                         ALERTING FRAMEWORK - RULES CLIENT                                │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │  RulesClient (x-pack/platform/plugins/shared/alerting/server/rules_client/)     │   │
│   │                                                                                 │   │
│   │  Created by RulesClientFactory for each request with:                           │   │
│   │  • savedObjectsClient                • auditLogger                              │   │
│   │  • authorization                     • ruleTypeRegistry                         │   │
│   │  • taskManager                       • encryptedSavedObjectsClient              │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                          │                                               │
│   ┌──────────────────────────────────────┼──────────────────────────────────────────┐   │
│   │                              OPERATIONS                                          │   │
│   │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │   │
│   │  │  create()    │ │  update()    │ │  delete()    │ │   find()     │            │   │
│   │  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘            │   │
│   │         │                │                │                │                    │   │
│   │         └────────────────┴────────────────┴────────────────┘                    │   │
│   └──────────────────────────────────────┬──────────────────────────────────────────┘   │
│                                          │                                               │
└──────────────────────────────────────────┼───────────────────────────────────────────────┘
                                           │
                       ┌───────────────────┼───────────────────┐
                       ▼                   ▼                   ▼
            ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
            │  Saved Objects  │  │  Task Manager   │  │  Event Log      │
            │  (type: alert)  │  │  (scheduling)   │  │  (audit trail)  │
            └─────────────────┘  └─────────────────┘  └─────────────────┘
```

### Explanation

**Security Solution Routes** - API endpoints that receive HTTP requests for rule operations. Each route handler:
1. Extracts and validates request parameters
2. Gets the `IDetectionRulesClient` from the request context
3. Calls the appropriate method on the client

**Detection Rules Client** - A per-request service that provides security-specific rule management:
- Created in `RequestContextFactory` with all necessary dependencies
- Uses **converters** to transform between API format (snake_case) and Alerting format (camelCase)
- Delegates actual persistence to the Alerting Framework's `RulesClient`

**Alerting Framework RulesClient** - The core persistence layer:
- Stores rules as Saved Objects of type `alert`
- Schedules rule execution via Task Manager
- Logs operations to Event Log for audit trail

### Key Files

| Component | File Path |
|-----------|-----------|
| Create Rule Route | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/create_rule/route.ts` |
| Update Rule Route | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/update_rule/route.ts` |
| Patch Rule Route | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/patch_rule/route.ts` |
| Delete Rule Route | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/delete_rule/route.ts` |
| Detection Rules Client Interface | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client_interface.ts` |
| Detection Rules Client Implementation | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts` |
| Create Rule Method | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/create_rule.ts` |
| Update Rule Method | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/methods/update_rule.ts` |
| Convert to Alerting Format | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/converters/convert_rule_response_to_alerting_rule.ts` |
| Convert to API Format | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/converters/convert_alerting_rule_to_rule_response.ts` |
| Alerting RulesClient | `x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts` |
| Request Context Factory | `x-pack/solutions/security/plugins/security_solution/server/request_context_factory.ts` |

---

## Rule Execution Architecture

This diagram shows the runtime flow when a detection rule executes, from Task Manager scheduling through to alert persistence in Elasticsearch.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              RULE EXECUTION FLOW                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              TASK MANAGER                                            │
  │                                                                                      │
  │   Schedules rule execution based on rule.schedule.interval (e.g., "5m", "1h")       │
  │   Maintains execution state and handles retries                                      │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              TASK RUNNER                                             │
  │   (x-pack/platform/plugins/shared/alerting/server/task_runner/)                     │
  │                                                                                      │
  │   • Loads rule configuration from Saved Objects                                      │
  │   • Validates rule state and API key                                                 │
  │   • Invokes rule type executor                                                       │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                     PERSISTENCE RULE TYPE WRAPPER                                    │
  │   (x-pack/platform/plugins/shared/rule_registry/server/utils/                       │
  │    create_persistence_rule_type_wrapper.ts)                                          │
  │                                                                                      │
  │   • Provides alertWithPersistence() service                                          │
  │   • Writes alerts to Elasticsearch via RuleDataClient                                │
  │   • Handles alert augmentation (timestamps, rule fields)                             │
  │   • Manages bulk indexing operations                                                 │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                     SECURITY RULE TYPE WRAPPER                                       │
  │   (x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/ │
  │    rule_types/create_security_rule_type_wrapper.ts)                                  │
  │                                                                                      │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                      PRE-EXECUTION                                           │   │
  │   │  • Data View resolution (getInputIndex)                                      │   │
  │   │  • Privilege check (checkPrivilegesFromEsClient)                             │   │
  │   │  • Timestamp validation (hasTimestampFields)                                 │   │
  │   │  • Frozen indices check (checkForFrozenIndices) [non-serverless]             │   │
  │   │  • Gap detection (getRuleRangeTuples)                                        │   │
  │   │  • Exception list loading (getExceptions, buildExceptionFilter)              │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                        │                                             │
  │                                        ▼                                             │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                      FOR EACH TIME TUPLE                                     │   │
  │   │                                                                              │   │
  │   │    ┌──────────────────────────────────────────────────────────────────┐     │   │
  │   │    │              DETECTION RULE EXECUTOR                              │     │   │
  │   │    │                                                                   │     │   │
  │   │    │  Specific to rule type:                                           │     │   │
  │   │    │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐    │     │   │
  │   │    │  │  EQL    │ │  ESQL   │ │  Query  │ │Threshold│ │   ML    │    │     │   │
  │   │    │  │Executor │ │Executor │ │Executor │ │Executor │ │Executor │    │     │   │
  │   │    │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘    │     │   │
  │   │    │       │           │           │           │           │          │     │   │
  │   │    │       └───────────┴───────────┴───────────┴───────────┘          │     │   │
  │   │    │                               │                                   │     │   │
  │   │    │                               ▼                                   │     │   │
  │   │    │              ┌────────────────────────────────┐                  │     │   │
  │   │    │              │     Elasticsearch Query        │                  │     │   │
  │   │    │              │     (via scopedClusterClient)  │                  │     │   │
  │   │    │              └────────────────────────────────┘                  │     │   │
  │   │    │                               │                                   │     │   │
  │   │    │                               ▼                                   │     │   │
  │   │    │              ┌────────────────────────────────┐                  │     │   │
  │   │    │              │   Process Results → Alerts     │                  │     │   │
  │   │    │              │   Apply Alert Suppression      │                  │     │   │
  │   │    │              └────────────────────────────────┘                  │     │   │
  │   │    └──────────────────────────────────────────────────────────────────┘     │   │
  │   │                                                                              │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                        │                                             │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                      POST-EXECUTION                                          │   │
  │   │  • Log status change (ruleExecutionLogger)                                   │   │
  │   │  • Send telemetry (sendAlertSuppressionTelemetryEvent)                       │   │
  │   │  • Store gap information (if storeGapsInEventLogEnabled)                     │   │
  │   │  • Aggregate warnings/errors                                                 │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                      │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              ALERTS PERSISTENCE                                      │
  │                                                                                      │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                         Elasticsearch Indices                                │   │
  │   │                                                                              │   │
  │   │   Primary:    .alerts-security.alerts-<namespace>                            │   │
  │   │   Secondary:  .siem-signals-<namespace> (backwards compatibility alias)      │   │
  │   │   Preview:    .preview.alerts-security.alerts-<namespace>                    │   │
  │   │                                                                              │   │
  │   │   Field Mappings:                                                            │   │
  │   │   ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐               │   │
  │   │   │technicalRuleMap │ │  alertsFieldMap │ │  rulesFieldMap  │               │   │
  │   │   │ (framework)     │ │  (9.3.0)        │ │  (8.0.0)        │               │   │
  │   │   └────────┬────────┘ └────────┬────────┘ └────────┬────────┘               │   │
  │   │            │                   │                   │                         │   │
  │   │            └───────────────────┴───────────────────┘                         │   │
  │   │                                │                                              │   │
  │   │                                ▼                                              │   │
  │   │                    securityRuleTypeFieldMap                                   │   │
  │   │                                                                              │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                      │
  └──────────────────────────────────────────────────────────────────────────────────────┘
```

### Explanation

**Task Manager** - Kibana's background task scheduling system:
- Schedules rule execution based on the rule's `schedule.interval` setting
- Maintains execution state and handles retries on failure

**Task Runner** - Loads and executes rules:
- Retrieves rule configuration from Saved Objects
- Validates API keys and rule state
- Invokes the registered rule type executor

**Persistence Rule Type Wrapper** - From Rule Registry plugin:
- Provides `alertWithPersistence()` service to rule executors
- Handles bulk indexing of alerts to Elasticsearch
- Augments alerts with common fields (timestamps, rule metadata)

**Security Rule Type Wrapper** - Security-specific logic layer:
- **Pre-execution**: Validates data views, checks privileges, detects gaps, loads exception lists
- **Per-tuple execution**: Runs the detection query for each time range
- **Post-execution**: Logs status, sends telemetry, records gaps

**Detection Rule Executors** - Type-specific query execution:
- Each rule type (EQL, ESQL, Query, etc.) has its own executor
- Performs the actual Elasticsearch search
- Processes results and applies alert suppression

**Alerts Persistence** - Final storage layer:
- Primary index: `.alerts-security.alerts-<namespace>`
- Secondary alias: `.siem-signals-<namespace>` (backwards compatibility)
- Field mappings combine framework, alert, and rule-specific fields

### Key Files

| Component | File Path |
|-----------|-----------|
| Task Manager Plugin | `x-pack/platform/plugins/shared/task_manager/server/plugin.ts` |
| Task Runner | `x-pack/platform/plugins/shared/alerting/server/task_runner/task_runner.ts` |
| Persistence Wrapper | `x-pack/platform/plugins/shared/rule_registry/server/utils/create_persistence_rule_type_wrapper.ts` |
| Security Rule Type Wrapper | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` |
| EQL Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/eql/create_eql_alert_type.ts` |
| ESQL Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/esql/create_esql_alert_type.ts` |
| Query Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/query/create_query_alert_type.ts` |
| Threshold Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/threshold/create_threshold_alert_type.ts` |
| ML Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/ml/create_ml_alert_type.ts` |
| Indicator Match Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/indicator_match/create_indicator_match_alert_type.ts` |
| New Terms Executor | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/new_terms/create_new_terms_alert_type.ts` |
| Gap Detection Utils | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/utils/utils.ts` |
| Exception List Loading | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/utils/get_list_client.ts` |
| Alerts Field Map (9.3.0) | `x-pack/solutions/security/plugins/security_solution/common/field_maps/9.3.0/` |
| Rules Field Map (8.0.0) | `x-pack/solutions/security/plugins/security_solution/common/field_maps/8.0.0/rules.ts` |
| Security Field Map | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` (securityRuleTypeFieldMap) |

---

## Component Dependencies Diagram

This diagram shows the dependency relationships between components in the Detection Rules system, illustrating how the Detection Rules Client depends on various services and how data flows to Elasticsearch.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                            COMPONENT DEPENDENCIES                                        │
└─────────────────────────────────────────────────────────────────────────────────────────┘

                           ┌────────────────────────┐
                           │    DETECTION RULES     │
                           │        CLIENT          │
                           │  (IDetectionRulesClient)│
                           └───────────┬────────────┘
                                       │
           ┌───────────────────────────┼───────────────────────────┐
           │                           │                           │
           ▼                           ▼                           ▼
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│    RulesClient      │    │   ActionsClient     │    │ SavedObjectsClient  │
│  (from Alerting)    │    │ (from Actions)      │    │   (from Core)       │
│                     │    │                     │    │                     │
│ • create()          │    │ • getAll()          │    │ • find()            │
│ • update()          │    │ • get()             │    │ • get()             │
│ • delete()          │    │ • isActionTypeEnabled│   │ • create()          │
│ • find()            │    │   ()                │    │                     │
└──────────┬──────────┘    └─────────────────────┘    └──────────┬──────────┘
           │                                                      │
           │                                                      │
           ▼                                                      ▼
┌─────────────────────┐                               ┌─────────────────────┐
│   Task Manager      │                               │  Prebuilt Rule      │
│                     │                               │  Assets Client      │
│ • Schedule rules    │                               │                     │
│ • Execute on time   │                               │ • getLatestAssets() │
│ • Handle retries    │                               │ • getAssetsByVersion│
└──────────┬──────────┘                               │   ()                │
           │                                          └─────────────────────┘
           │
           ▼
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│  RuleTypeRegistry   │◄───│ SecurityRuleType    │◄───│  PersistenceRule    │
│                     │    │    Wrapper          │    │   TypeWrapper       │
│ • Registered types: │    │                     │    │                     │
│   - siem.eqlRule    │    │ • Exception lists   │    │ • alertWithPersist- │
│   - siem.esqlRule   │    │ • Gap detection     │    │   ence()            │
│   - siem.queryRule  │    │ • Privilege checks  │    │ • Bulk indexing     │
│   - siem.mlRule     │    │ • Validation        │    │                     │
│   - etc.            │    │ • Telemetry         │    │                     │
└─────────────────────┘    └─────────────────────┘    └──────────┬──────────┘
                                                                  │
                                                                  ▼
                                                      ┌─────────────────────┐
                                                      │   RuleDataClient    │
                                                      │                     │
                                                      │ • getWriter()       │
                                                      │ • getReader()       │
                                                      │ • indexNameWith-    │
                                                      │   Namespace()       │
                                                      └──────────┬──────────┘
                                                                 │
                                                                 ▼
                                                      ┌─────────────────────┐
                                                      │   Elasticsearch     │
                                                      │                     │
                                                      │ .alerts-security.   │
                                                      │   alerts-*          │
                                                      └─────────────────────┘

Additional Dependencies:
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                          │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐              │
│  │     MlAuthz         │  │ ProductFeatures     │  │     ILicense        │              │
│  │                     │  │    Service          │  │                     │              │
│  │ • ML job validation │  │                     │  │ • License level     │              │
│  │ • Authorization     │  │ • Feature flags     │  │   checks            │              │
│  │   checks            │  │ • Capability checks │  │ • Prebuilt rule     │              │
│  │                     │  │                     │  │   customization     │              │
│  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘              │
│                                                                                          │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐              │
│  │  Lists Plugin       │  │   Event Log         │  │    Licensing        │              │
│  │                     │  │                     │  │                     │              │
│  │ • Exception lists   │  │ • Rule execution    │  │ • License observable│              │
│  │ • List items        │  │   logs              │  │ • Feature usage     │              │
│  │                     │  │ • Gap storage       │  │                     │              │
│  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘              │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Explanation

**Detection Rules Client (IDetectionRulesClient)** - The main entry point for rule management operations. It depends on:

**Primary Dependencies:**
- **RulesClient** (Alerting) - Core CRUD operations for rules stored as Saved Objects
- **ActionsClient** (Actions) - Manages rule actions and connectors
- **SavedObjectsClient** (Core) - Direct access to prebuilt rule assets

**Task & Registry Layer:**
- **Task Manager** - Schedules and executes rules on their configured intervals
- **RuleTypeRegistry** - Contains all registered rule types with their executors
- **Prebuilt Rule Assets Client** - Accesses prebuilt rule packages for upgrades/reversions

**Wrapper Chain:**
- **SecurityRuleType Wrapper** - Adds exception handling, gap detection, privilege checks, telemetry
- **PersistenceRuleType Wrapper** - Provides alerts-as-data persistence via `alertWithPersistence()`
- **RuleDataClient** - Reads/writes alerts to Elasticsearch indices

**Additional Dependencies:**
- **MlAuthz** - Authorizes ML job access for machine learning rules
- **ProductFeaturesService** - Checks feature flags and tier capabilities
- **ILicense** - Verifies license level for features like prebuilt rule customization
- **Lists Plugin** - Provides exception lists that exclude events from alerting
- **Event Log** - Records rule execution history and gap information
- **Licensing** - Observes license changes and enables/disables features

### Key Files

| Component | File Path |
|-----------|-----------|
| Detection Rules Client | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/logic/detection_rules_client/detection_rules_client.ts` |
| RulesClient (Alerting) | `x-pack/platform/plugins/shared/alerting/server/rules_client/rules_client.ts` |
| ActionsClient | `x-pack/platform/plugins/shared/actions/server/actions_client/actions_client.ts` |
| Task Manager | `x-pack/platform/plugins/shared/task_manager/server/plugin.ts` |
| Rule Type Registry | `x-pack/platform/plugins/shared/alerting/server/rule_type_registry.ts` |
| Prebuilt Rule Assets Client | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/prebuilt_rules/logic/rule_assets/prebuilt_rule_assets_client.ts` |
| Security Rule Type Wrapper | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` |
| Persistence Rule Type Wrapper | `x-pack/platform/plugins/shared/rule_registry/server/utils/create_persistence_rule_type_wrapper.ts` |
| Rule Data Client | `x-pack/platform/plugins/shared/rule_registry/server/rule_data_client/rule_data_client.ts` |
| MlAuthz | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/machine_learning/authz.ts` |
| Product Features Service | `x-pack/solutions/security/plugins/security_solution/server/lib/product_features_service/product_features_service.ts` |
| Lists Plugin | `x-pack/platform/plugins/shared/lists/server/plugin.ts` |
| Event Log Plugin | `x-pack/platform/plugins/shared/event_log/server/plugin.ts` |
| Licensing Plugin | `x-pack/platform/plugins/shared/licensing/server/plugin.ts` |

---

## Feature Flags Architecture

This diagram shows how experimental feature flags flow through the Security Solution, from configuration to usage in both server and client code.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           FEATURE FLAGS CONFIGURATION                                    │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              kibana.yml                                              │
  │                                                                                      │
  │   xpack.securitySolution.enableExperimental:                                         │
  │     - extendedRuleExecutionLoggingEnabled                                            │
  │     - bulkFillRuleGapsEnabled                                                        │
  │     - disable:esqlRulesDisabled    # Use "disable:" prefix to disable a feature     │
  │                                                                                      │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                      FEATURE FLAG DEFINITIONS                                        │
  │   (x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts)
  │                                                                                      │
  │   export const allowedExperimentalValues = Object.freeze({                           │
  │     // Detection Rules Feature Flags                                                 │
  │     extendedRuleExecutionLoggingEnabled: false,  // Rule execution logging           │
  │     esqlRulesDisabled: false,                    // ES|QL rule type                  │
  │     storeGapsInEventLogEnabled: true,            // Gap detection storage            │
  │     bulkFillRuleGapsEnabled: true,               // Bulk gap fill operations         │
  │     endpointExceptionsMovedUnderManagement: false,                                   │
  │                                                                                      │
  │     // Other Security Features                                                       │
  │     siemMigrationsDisabled: false,               // SIEM migrations                  │
  │     entityStoreDisabled: false,                  // Entity Store                     │
  │     assistantModelEvaluation: false,             // AI Assistant                     │
  │     // ... more flags                                                                │
  │   });                                                                                │
  │                                                                                      │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                         CONFIG PARSING (Plugin Initialization)                       │
  │   (x-pack/solutions/security/plugins/security_solution/server/config.ts)            │
  │                                                                                      │
  │   export const createConfig = (context: PluginInitializerContext): ConfigType => {  │
  │     const pluginConfig = context.config.get<TypeOf<typeof configSchema>>();         │
  │                                                                                      │
  │     const { invalid, features: experimentalFeatures } =                              │
  │       parseExperimentalConfigValue(pluginConfig.enableExperimental);                 │
  │                                                                                      │
  │     if (invalid.length) {                                                            │
  │       logger.warn(`Unsupported values detected...`);                                 │
  │     }                                                                                │
  │                                                                                      │
  │     return { ...pluginConfig, experimentalFeatures, settings };                      │
  │   };                                                                                 │
  │                                                                                      │
  └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │
                    ┌─────────────────────┴─────────────────────┐
                    │                                           │
                    ▼                                           ▼
┌───────────────────────────────────────────┐   ┌───────────────────────────────────────────┐
│           SERVER-SIDE ACCESS              │   │           CLIENT-SIDE ACCESS              │
└───────────────────────────────────────────┘   └───────────────────────────────────────────┘
                    │                                           │
                    ▼                                           ▼
┌───────────────────────────────────────────┐   ┌───────────────────────────────────────────┐
│                                           │   │                                           │
│  Plugin Constructor:                      │   │  ExperimentalFeaturesService:             │
│  ┌─────────────────────────────────────┐  │   │  ┌─────────────────────────────────────┐  │
│  │ this.config = createConfig(context);│  │   │  │ ExperimentalFeaturesService.init({ │  │
│  │ this.config.experimentalFeatures    │  │   │  │   experimentalFeatures              │  │
│  │   .someFeatureFlag                  │  │   │  │ });                                 │  │
│  └─────────────────────────────────────┘  │   │  │                                     │  │
│                                           │   │  │ // Static access                    │  │
│  Request Context:                         │   │  │ ExperimentalFeaturesService.get()   │  │
│  ┌─────────────────────────────────────┐  │   │  │   .someFeatureFlag                  │  │
│  │ securityContext                     │  │   │  └─────────────────────────────────────┘  │
│  │   .experimentalFeatures             │  │   │                                           │
│  │   .someFeatureFlag                  │  │   │  React Hook:                              │
│  └─────────────────────────────────────┘  │   │  ┌─────────────────────────────────────┐  │
│                                           │   │  │ const isEnabled =                   │  │
│  Rule Execution:                          │   │  │   useIsExperimentalFeatureEnabled(  │  │
│  ┌─────────────────────────────────────┐  │   │  │     'someFeatureFlag'               │  │
│  │ // In security rule type wrapper    │  │   │  │   );                                │  │
│  │ experimentalFeatures                │  │   │  │                                     │  │
│  │   .storeGapsInEventLogEnabled       │  │   │  │ // Use in components                │  │
│  │                                     │  │   │  │ {isEnabled && <Feature />}          │  │
│  └─────────────────────────────────────┘  │   │  └─────────────────────────────────────┘  │
│                                           │   │                                           │
└───────────────────────────────────────────┘   └───────────────────────────────────────────┘
                    │                                           │
                    ▼                                           ▼
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                              FEATURE FLAG USAGE EXAMPLES                                  │
│                                                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│   │  RULE TYPE REGISTRATION (plugin.ts setup)                                        │    │
│   │                                                                                  │    │
│   │  if (!experimentalFeatures.esqlRulesDisabled) {                                  │    │
│   │    plugins.alerting.registerType(                                                │    │
│   │      securityRuleTypeWrapper(createEsqlAlertType())                              │    │
│   │    );                                                                            │    │
│   │  }                                                                               │    │
│   └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│   │  RULE EXECUTION (create_security_rule_type_wrapper.ts)                           │    │
│   │                                                                                  │    │
│   │  await ruleExecutionLogger.logStatusChange({                                     │    │
│   │    metrics: {                                                                    │    │
│   │      gapRange: experimentalFeatures.storeGapsInEventLogEnabled ? gap : undefined │    │
│   │    }                                                                             │    │
│   │  });                                                                             │    │
│   └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐    │
│   │  CLIENT UI (React component)                                                     │    │
│   │                                                                                  │    │
│   │  const RuleDetails = () => {                                                     │    │
│   │    const showLogs = useIsExperimentalFeatureEnabled(                             │    │
│   │      'extendedRuleExecutionLoggingEnabled'                                       │    │
│   │    );                                                                            │    │
│   │    return showLogs ? <ExecutionLogsTable /> : null;                              │    │
│   │  };                                                                              │    │
│   └─────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                           │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### Explanation

**Configuration Flow:**
1. **kibana.yml** - Operators configure feature flags in the Kibana configuration file
2. **Feature Flag Definitions** - Default values are defined in `allowedExperimentalValues` object
3. **Config Parsing** - During plugin initialization, `createConfig()` merges config with defaults
4. **Distribution** - Parsed features are available on both server and client

**Server-Side Access Patterns:**
- **Plugin Constructor**: Direct access via `this.config.experimentalFeatures`
- **Request Context**: Access via security context in route handlers
- **Rule Execution**: Passed to wrappers and executors via options

**Client-Side Access Patterns:**
- **ExperimentalFeaturesService**: Static service for imperative access
- **useIsExperimentalFeatureEnabled Hook**: React hook for component rendering

**Key Detection Rules Feature Flags:**

| Flag | Default | Purpose |
|------|---------|---------|
| `extendedRuleExecutionLoggingEnabled` | `false` | Enables detailed rule execution logging to Event Log |
| `esqlRulesDisabled` | `false` | When `true`, disables ES\|QL rule type registration |
| `storeGapsInEventLogEnabled` | `true` | Stores execution gaps in Event Log for analysis |
| `bulkFillRuleGapsEnabled` | `true` | Enables bulk operations to fill execution gaps |
| `endpointExceptionsMovedUnderManagement` | `false` | Moves Endpoint exceptions to Management section |
| `siemMigrationsDisabled` | `false` | Disables SIEM migrations feature |
| `entityStoreDisabled` | `false` | Disables Entity Store engine routes |

### Key Files

| Component | File Path |
|-----------|-----------|
| Feature Flag Definitions | `x-pack/solutions/security/plugins/security_solution/common/experimental_features.ts` |
| Config Schema & Parsing | `x-pack/solutions/security/plugins/security_solution/server/config.ts` |
| Plugin (Server) | `x-pack/solutions/security/plugins/security_solution/server/plugin.ts` |
| Client-Side Service | `x-pack/solutions/security/plugins/security_solution/public/common/experimental_features_service.ts` |
| React Hook | `x-pack/solutions/security/plugins/security_solution/public/common/hooks/use_experimental_features.ts` |
| Redux Store (Client State) | `x-pack/solutions/security/plugins/security_solution/public/common/store/store.ts` |
| Security Rule Type Wrapper | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` |
| Rule Execution Logger | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_monitoring/logic/rule_execution_log/` |
| Product Features Service | `x-pack/solutions/security/plugins/security_solution/server/lib/product_features_service/product_features_service.ts` |

### Examples in Codebase

#### Server-Side Examples

| Feature Flag | Example Usage | File Path |
|--------------|---------------|-----------|
| `esqlRulesDisabled` | Conditionally registers ES\|QL rule type | `x-pack/solutions/security/plugins/security_solution/server/plugin.ts` |
| `esqlRulesDisabled` | Conditionally enables ES\|QL preview | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_preview/api/preview_rules/route.ts` |
| `storeGapsInEventLogEnabled` | Controls gap storage in rule execution | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_types/create_security_rule_type_wrapper.ts` |
| `extendedRuleExecutionLoggingEnabled` | Fetches extended rule execution settings | `x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_monitoring/logic/rule_execution_log/execution_settings/fetch_rule_execution_settings.ts` |
| `endpointExceptionsMovedUnderManagement` | Controls exception handling in manifest manager | `x-pack/solutions/security/plugins/security_solution/server/endpoint/services/artifacts/manifest_manager/manifest_manager.ts` |
| `endpointExceptionsMovedUnderManagement` | Validates exceptions pre-create | `x-pack/solutions/security/plugins/security_solution/server/lists_integration/endpoint/handlers/exceptions_pre_create_handler.ts` |
| `endpointExceptionsMovedUnderManagement` | Validates exceptions pre-update | `x-pack/solutions/security/plugins/security_solution/server/lists_integration/endpoint/handlers/exceptions_pre_update_handler.ts` |

#### Client-Side Examples (React Hook)

| Feature Flag | Example Usage | File Path |
|--------------|---------------|-----------|
| Various | Rule details page with feature checks | `x-pack/solutions/security/plugins/security_solution/public/detection_engine/rule_details_ui/pages/rule_details/index.tsx` |
| Various | Detection response page | `x-pack/solutions/security/plugins/security_solution/public/overview/pages/detection_response.tsx` |
| Various | Overview page feature gates | `x-pack/solutions/security/plugins/security_solution/public/overview/pages/overview.tsx` |
| `siemMigrationsDisabled` | SIEM migrations dropdown | `x-pack/solutions/security/plugins/security_solution/public/siem_migrations/rules/components/migration_source_step/migration_source_dropdown.tsx` |
| Various | Trusted apps list | `x-pack/solutions/security/plugins/security_solution/public/management/pages/trusted_apps/view/trusted_apps_list.tsx` |
| Various | Timelines open timeline index | `x-pack/solutions/security/plugins/security_solution/public/timelines/components/open_timeline/index.tsx` |

#### Client-Side Examples (ExperimentalFeaturesService)

| Feature Flag | Example Usage | File Path |
|--------------|---------------|-----------|
| Various | Rule migrations service | `x-pack/solutions/security/plugins/security_solution/public/siem_migrations/rules/service/rule_migrations_service.ts` |
| Various | Dashboard migrations service | `x-pack/solutions/security/plugins/security_solution/public/siem_migrations/dashboards/service/dashboard_migrations_service.ts` |
| Various | Endpoint responder commands | `x-pack/solutions/security/plugins/security_solution/public/management/components/endpoint_responder/lib/console_commands_definition.ts` |
| Various | Onboarding context | `x-pack/solutions/security/plugins/security_solution/public/onboarding/components/onboarding_context.tsx` |
| Various | Redux store initialization | `x-pack/solutions/security/plugins/security_solution/public/common/store/store.ts` |
