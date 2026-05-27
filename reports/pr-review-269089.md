# PR #269089 — Add find-security-rules skill for the agent builder

**Author:** @nkhristinin
**Base:** `main` ← `find-rules-skill`
**State:** OPEN, draft (label: `release_note:feature`, `backport:skip`)
**Linked issues:** none declared

**Scale:** Substantive — ~2000 lines net add across 13 files, new skill registration, new public Agent Builder skill ID, plus a small change to a shared `common/` constants file owned by `security-detection-rule-management`.

## Ownership (team: `@elastic/security-detection-rule-management`)

CODEOWNERS rules that match files in this PR:

- `/x-pack/solutions/security/plugins/security_solution/server/agent_builder` → **`@elastic/security-solution`** (umbrella owner — i.e. *not* a team-specific owner)
- `/x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management` → **`@elastic/security-detection-rule-management`**
- `/x-pack/platform/packages/shared/agent-builder/agent-builder-server` → **`@elastic/workchat-eng`**
- `/x-pack/platform/packages/shared/agent-builder/kbn-evals-suite-agent-builder` → **`@elastic/workchat-eng`**

Bucketed:

- **Your team's files (1):** `x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management/rule_fields.ts` — *focus review effort here*. This file is the source of truth for KQL field constants used across the rule-management codebase.
- **Other teams' files (10):** Most of the actual skill, fixtures, and eval suite are owned by `@elastic/security-solution` (umbrella) and `@elastic/workchat-eng`. They consume `convertRulesFilterToKQL`, `convertRuleTagsToKQL`, `findRules`, and `RULE_PARAMS_FIELDS` — rule-management-owned APIs.
- **Unowned:** none.

You are not the accountable code-owner for most of this PR, but the new skill is **a long-lived consumer of rule-management's KQL/filter utilities**. The biggest review value here is making sure the skill's filter-building stays consistent with how rule-management itself builds filters, and that the new `PARAMS_*` constants don't drift from the rest of the codebase.

## Summary

Adds a new built-in Agent Builder skill, `find-security-rules`, that lets the AI Assistant answer rule-discovery questions ("list/sort/count detection rules"). The skill exposes two new inline tools (`security.find_rules`, `security.discover_rule_tags`) and references the existing `security.alerts` registry tool for noisy-rules queries. Internally `security.find_rules` builds a KQL filter from flat parameters, mostly delegating to the existing `convertRulesFilterToKQL` and adding clauses for parameters that helper doesn't support (severity, tags-as-OR, MITRE technique, ruleId, excludeTags). `security.discover_rule_tags` runs a `findRules` aggregation on the `tags` field with size 1000 and returns the buckets.

Stated intent in the PR description matches the diff well — there's no significant divergence. The PR also adds a `common/.../rule_fields.ts` change (two new field-name constants) that is a single-file, low-risk export addition.

## Files touched

**Rule-management-owned (your team's only file):**
- `x-pack/.../rule_management/rule_fields.ts` — adds `PARAMS_SEVERITY_FIELD = 'alert.attributes.params.severity'` and `PARAMS_RULE_ID_FIELD = 'alert.attributes.params.ruleId'` to the existing constants. Pure additive.

**New skill (security_solution agent-builder, `@elastic/security-solution`):**
- `server/agent_builder/skills/find_rules/find_rules_skill.ts` — skill manifest with prompt content (~80 lines of LLM instructions) and registers two inline tools + one registry tool.
- `server/agent_builder/skills/find_rules/find_rules_tool.ts` — `security.find_rules` schema, `buildToolFilter`, and handler.
- `server/agent_builder/skills/find_rules/discover_rule_tags_tool.ts` — `security.discover_rule_tags` empty-args tool that runs an aggregation through `findRules`.
- `server/agent_builder/skills/find_rules/index.ts` — barrel.
- `server/agent_builder/skills/index.ts`, `register_skills.ts` — wire the new skill into Agent Builder.

**Allow-list (workchat-eng):**
- `agent-builder-server/allow_lists.ts` — adds `'find-security-rules'` to `AGENT_BUILDER_BUILTIN_SKILLS`. This is the gate that forces a workchat-eng review for any new built-in skill.

**Tests / fixtures / evals (workchat-eng on packages, security-solution on plugin tests):**
- `find_rules_skill.test.ts` — 566 lines of unit tests (filter shape, schema, tool handler, prompt-content assertions).
- `kbn-evals-suite-agent-builder/evals/security/find_rules.spec.ts` — 437 lines, three eval describes (rule-discovery, distractor routing, multi-turn).
- `kbn-evals-suite-agent-builder/evals/security/find_rules_fixtures.ts` — 425 lines, seeds 10 detection rules + 50 synthetic alerts via the public `_bulk_action` API and ES bulk into `.internal.alerts-security.alerts-default-000001`.
- `kbn-evals-suite-agent-builder/moon.yml`, `tsconfig.json` — adds `@kbn/test` dependency for `KbnClient`.

## Flow trace (rule-discovery happy path)

User asks AI Assistant *"List all enabled detection rules tagged with MITRE."*

1. Agent Builder receives the message; the security agent's prompt routing matches `find-security-rules` because the skill's `description` and `content` advertise rule discovery and explicitly de-route alert-triage / rule-edit / threat-hunting / V2-rule queries.
2. Per the skill prompt, the model first calls `security.discover_rule_tags` with `{}`.
3. `createDiscoverRuleTagsInlineTool` calls `findRules({ rulesClient, perPage: 0, page: 1, aggregations: { by_field: { terms: { field: TAGS_FIELD, size: 1000 } } } })`. This runs `rulesClient.find` on the alerting saved-objects, scoped through `enrichFilterWithRuleTypeMapping(undefined)` (which adds the `siem.*` rule-type filter — see `find_rules.ts:59`).
4. The bucket list is returned with `truncated: otherDocCount > 0`. Note: 1000 is *not* the same cap that the existing `readTags` API uses — that uses `EXPECTED_MAX_TAGS = 65536`. The unit test asserts `EXPECTED_MAX_TAGS` for the size, but the production code hard-codes `1000`. **See Risks → "Tag aggregation cap mismatch" below.**
5. Model picks "MITRE" from the buckets and calls `security.find_rules` with `{ enabled: true, tags: ['MITRE'] }`.
6. `buildToolFilter` calls `convertRulesFilterToKQL({ enabled: true })` (gives `alert.attributes.enabled: true`), then appends a tags clause built locally as `alert.attributes.tags: "MITRE"`. Multi-tag values are OR'd with parens — different from `convertRuleTagsToKQL`, which AND's tags. This is intentional (acknowledged in a comment) but worth confirming.
7. `findRules` runs the query through `enrichFilterWithRuleTypeMapping` (constrains to SIEM rule types) and `enrichFilterWithRuleIds` (no-op when no `ruleIds` passed).
8. Results map through `summarizeRule`, which reads `params.rule_id ?? params.ruleId` and `params.risk_score ?? params.riskScore`. The `??` pair handles both the snake_case API shape and the camelCase Alerting-framework SO shape — see Open questions.
9. The handler builds a one-line message that lists rule names inline (potentially many, see "Risks → Token budget").
10. Agent Builder returns the result; the model summarizes per the skill's rendering prompt.

## Assumptions

- **Field constants match SO storage.** `PARAMS_SEVERITY_FIELD = 'alert.attributes.params.severity'` and `PARAMS_RULE_ID_FIELD = 'alert.attributes.params.ruleId'` assume the alerting saved-object stores `params.severity` and `params.ruleId` (camelCase) — verified against existing usage (`read_rules.ts`, `get_rule_by_rule_id.ts`, `prebuilt_rule_objects_client.ts`), so this matches established convention.
- **Rule SO fields available in alerting params.** The test mock at `find_rules_skill.test.ts:357` confirms the production rule shape uses `params.ruleId` (camelCase from the Alerting framework's automatic camelization), but `summarizeRule` reads `params.rule_id ?? params.ruleId` — meaning *both* are tolerated. That suggests the author was unsure, or wanted to support both raw API responses and SO reads. Worth confirming whether one branch is dead code.
- **Tag values are unique enough that 1000 is the effective ceiling in practice.** `discover_rule_tags_tool.ts` hard-codes `GROUP_BY_TERMS_SIZE = 1000`. The existing rule-management `readTags` uses 65536. With a few thousand prebuilt rules each carrying ~5–10 tags, 1000 buckets *probably* covers most installations, but enterprises with many custom rules + tags could exceed it. The truncation hint is real, but the cap is much lower than the existing tool.
- **Eval fixtures don't collide with real rules.** `seedFindRulesFixtures` deletes "leftover fixtures from crashed runs" by matching rule **name**, then creates new ones. If a user/customer happens to have a rule named "Suspicious PowerShell Execution" in a non-isolated cluster, the eval suite will delete it. This runs against serverless test envs per the tags, so probably fine, but the assumption is "this only ever runs against ephemeral clusters".
- **Direct ES write to `.internal.alerts-security.alerts-default-000001`.** `find_rules_fixtures.ts` writes synthetic alert docs straight into the internal alerts index by name. This bypasses the alerts-as-data write APIs, hard-codes the index name (no abstraction over rollover or DLM), and assumes a particular space (`default`). If the index name pattern ever changes, the fixture silently breaks.
- **The Alerting `find` API supports arbitrary `aggs`.** Confirmed via `find_rules_schemas.ts` — `aggs: schema.maybe(schema.recordOf(schema.string(), schema.any()))`. Good.
- **Read-only contract.** The skill prompt repeatedly tells the model the skill is read-only, but there's no programmatic enforcement — the tools don't physically forbid mutations because they don't *do* any mutations. The contract is held by tool surface area (find + aggregate only), which is the right design.

## Risks

Ordered by severity.

1. **Tag aggregation cap mismatch (medium).** `discover_rule_tags_tool.ts` uses `size: 1000`, but the unit test for the same handler asserts `size: EXPECTED_MAX_TAGS` (= 65536). Either:
   - the test is wrong (asserts a constant the production code doesn't use), or
   - the production code should be using `EXPECTED_MAX_TAGS` like the existing `readTags` does for consistency.

   I lean toward the second: this is a divergence from the rule-management convention without a stated reason, and the test indicates the author *intended* to use the constant. **This is the single most important thing to verify with the author** — and it lives squarely in your team's domain because the existing `readTags` is rule-management-owned. (Check `find_rules_skill.test.ts:566` `expect(...size).toBe(EXPECTED_MAX_TAGS)` vs `discover_rule_tags_tool.ts:14` `const GROUP_BY_TERMS_SIZE = 1000`.)
2. **Token-budget blow-up on truncated results (medium).** `find_rules_tool.ts:226` builds a message that inlines every rule name returned (`Found ${total} detection rules: ${ruleNames}.`). With `perPage` capped at 100, that's up to ~100 rule names plus the structured `rules` array — the model receives both the formatted message and the array. For a "show me all rules" query, this can balloon the tool result and hit context limits. The skill prompt tells the model to default to `perPage: 10`, but a user can override it.
3. **`summarizeRule` dual-shape fallback (low–medium).** Reading both `params.rule_id` and `params.ruleId` (and same for risk_score) suggests uncertainty about the shape. Existing rule-management code that reads from `rulesClient.find` consistently uses camelCase (`params.ruleId`, `params.riskScore`) — see `read_rules.ts`. If the snake_case branch is never hit in practice, the fallback is harmless dead code; if it *is* hit somewhere, that's a clue that the alerting framework param-rewriting isn't always applied — worth understanding either way.
4. **Eval fixture cleanup is by name, not by tag/marker (low).** If any rule with a fixture name pre-exists (real customer data, another test suite's leftovers), it will be deleted in `seedFindRulesFixtures`. A safer pattern would be to tag fixture rules with something like `["__fixture-find-rules-eval__"]` and clean up by tag, not name. Low risk in practice (this only runs in test envs) but it's a footgun.
5. **`SECURITY_ALERTS_TOOL_ID` is exposed via `getRegistryTools` but the skill's content tells the model to use it for noisy-rules queries (low).** The alerts tool is owned and tested elsewhere (`alerts_tool.ts`); coupling here is just a registry reference, but it means breaking changes to the alerts tool's response shape will propagate to this skill's "noisy rules" flow without test coverage in this PR.
6. **Distractor eval has 6 examples and an expectedly low Factuality score (low).** The PR description acknowledges Factuality 0.16 on distractors. The eval is checking that the agent routes *away* from the find-rules skill — a useful check — but the metric chosen for scoring (Factuality on a vague intent statement) is not actually measuring routing. This is more an observation than a risk: the routing assertion is implicit and the score is noise.
7. **No explicit feature flag (low).** The skill is registered unconditionally in `register_skills.ts` (unlike `pciComplianceAgentBuilder` which gates on `experimentalFeatures`). If the skill misbehaves in production, the only way to disable it is to remove it from the allow-list and redeploy. Worth asking whether this is intentional (the team may have decided the skill is mature enough), but contrast with the PCI compliance skill in the same file.

## Open questions

These are real questions a thoughtful reviewer would want answered, not formalities.

1. **Tag aggregation cap.** Why is `GROUP_BY_TERMS_SIZE = 1000` instead of `EXPECTED_MAX_TAGS` (65536) like `readTags` uses? The unit test asserts the latter — was the production constant changed late and the test missed? **This will fail in CI as written**, since `expect(...size).toBe(EXPECTED_MAX_TAGS)` will see `1000`, not `65536`. (Worth double-checking against the author's local test runs — it's the kind of thing a `--ci` run would have caught.)
2. **`PARAMS_RULE_ID_FIELD` placement.** `rule_fields.ts` already exports a `RULE_PARAMS_FIELDS` const-record. The new constants (`PARAMS_SEVERITY_FIELD`, `PARAMS_RULE_ID_FIELD`) sit alongside it as standalone exports rather than getting added to that record. The existing convention isn't perfectly consistent (top-level `PARAMS_TYPE_FIELD`, `PARAMS_IMMUTABLE_FIELD` are also standalones), so this is fine, but you may want them inside `RULE_PARAMS_FIELDS` for discoverability — your call as the file's owner.
3. **Why are tags OR'd in `buildToolFilter` but AND'd in `convertRuleTagsToKQL`?** The PR comment acknowledges the divergence. The semantic question is: when the user says "rules tagged with MITRE and Custom", does the skill correctly disambiguate? Currently `tags: ["MITRE", "Custom"]` returns rules with *either* tag (OR), and the skill prompt explicitly tells the model "Tags are OR-ed". That seems fine for "MITRE-tagged or Custom-tagged" queries, but a user asking "rules tagged BOTH MITRE AND Custom" has no parameter to express that. Was that omission deliberate?
4. **`summarizeRule` dual snake/camel fallback.** Where is the snake_case branch reachable? Is it leftover from an earlier iteration that read raw API output, or is there a real code path?
5. **Direct write to `.internal.alerts-security.alerts-default-000001`.** Is there an existing test helper for seeding alerts that wraps this? Bypassing the public alerts-as-data path means the fixture won't cover the actual ingest pipeline, and hard-coding the partition name (`-000001`) is fragile if Kibana ever changes how the security alerts data stream is bootstrapped.
6. **Multi-turn eval fragility.** `find_rules.spec.ts:412–451` checks `turn2.steps` for a tool call with `tool_id === 'security.find_rules'` whose params include the substring `"medium"`. If the agent decides to call `security.find_rules` once with `severity: ["medium", "critical"]` to satisfy both turns, the assertion still passes — but if the agent re-issues the same prior call without `medium` (genuine bug), and *also* makes a generic call that happens to mention "medium" in another arg (e.g. a `searchTerm`), the test could pass falsely. Substring matches on JSON are brittle.

## Notes for your codebase map

- **Detection-rule field constants** live in `common/detection_engine/rule_management/rule_fields.ts`. New consumers (like the AI Assistant skill) are starting to import from this file directly rather than going through query helpers — your team's surface area as a "shared library" provider is growing.
- **`convertRulesFilterToKQL`** is the canonical filter-builder, but **doesn't cover everything** — severity, MITRE technique IDs, OR'd tags, and per-rule ruleId filters all need to be hand-rolled by callers. This is the second major external consumer (after the rule-management UI) building filters via a mix of "delegate where possible, hand-roll where not". Worth considering whether the helper should grow first-class params for these to keep the contract centralized.
- **Agent Builder built-in skills** are gated by a hand-maintained allow-list in `agent-builder-server/allow_lists.ts` — adding a skill ID there forces a code review from `@elastic/workchat-eng`. This is a well-defined cross-team handshake that you'll see again on any future security-solution → agent-builder integration.
- **Alerting `rulesClient.find` accepts arbitrary `aggs`** via the schema (`find_rules_schemas.ts`), and our `findRules` helper passes them through. Useful pattern for read-only analytics tools that want to avoid spinning up a separate ES query path.
- **Detection rules' alerting params are stored camelCase** (`params.ruleId`, `params.riskScore`) regardless of the snake_case wire/API format. Code reading from `rulesClient.find` should use camelCase; raw API response handlers may use snake_case. The dual-fallback pattern in this PR is a workaround for this ambiguity rather than a clear convention.
- **Security alerts test fixtures sometimes write directly to `.internal.alerts-security.alerts-default-000001`.** When you see this pattern, it's an indicator the test is bypassing the alerts-as-data pipeline — useful to flag in reviews because it's brittle to data-stream changes.
