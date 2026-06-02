# PR #269089 — Add find-security-rules skill for the agent builder

**Author:** @nkhristinin
**Base:** `main` ← `find-rules-skill`
**State:** OPEN, draft (label: `release_note:feature`, `backport:skip`)
**Last updated:** 2026-06-01 (review refreshed)
**Linked issues:** none declared

**Scale:** Substantive — ~2357 lines net add across 13 files (up from ~2076 at first review). Adds a new built-in Agent Builder skill, plus a small change to a shared `common/` constants file owned by `security-detection-rule-management`.

## What changed since the first review

Three recent commits land the things that mattered:

1. **`c22723f` — "use EXPECTED_MAX_TAGS"** — `discover_rule_tags_tool.ts` now uses the shared `EXPECTED_MAX_TAGS = 65536` constant for the terms-aggregation `size`, matching the existing `readTags` helper. The unit test that previously contradicted the production code (`size: EXPECTED_MAX_TAGS`) now agrees with both. **Risk #1 from the prior review is fully resolved.**
2. **`9f7c466` — "updates for mitre"** — adds a structured `mitreTactic` parameter to `findRulesSchema` (accepts either `TA####` IDs or display names). `buildToolFilter` routes to `RULE_PARAMS_FIELDS.TACTIC_ID` for ID-shaped input and `RULE_PARAMS_FIELDS.TACTIC_NAME` otherwise. The skill prompt grows a new `## MITRE ATT&CK Routing` section with a 14-tactic ID/name table and a priority order: technique ID → tactic ID → tactic name → `searchTerm`. The skill explicitly forbids putting MITRE intent into the `tags` filter, even when `Tactic: …`-shaped tag values surface in `discover_rule_tags`.
3. **`b285d6c` — "skill refactor for multitern"** — strengthens the discovery contract: the prompt and the tool description now both require `security.discover_rule_tags` to be called **in the same turn, immediately before** every `security.find_rules` call — no longer skipped on follow-up turns. Tests reflect this ("fresh `security.discover_rule_tags`").

Several merges from `main` (May 21–Jun 1) make up the remainder of the additions but don't touch the skill itself.

## Ownership (team: `@elastic/security-detection-rule-management`)

CODEOWNERS rules that match files in this PR (unchanged from prior review):

- `/x-pack/solutions/security/plugins/security_solution/server/agent_builder` → **`@elastic/security-solution`** (umbrella owner)
- `/x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management` → **`@elastic/security-detection-rule-management`**
- `/x-pack/platform/packages/shared/agent-builder/agent-builder-server` → **`@elastic/workchat-eng`**
- `/x-pack/platform/packages/shared/agent-builder/kbn-evals-suite-agent-builder` → **`@elastic/workchat-eng`**

Bucketed:

- **Your team's files (1):** `x-pack/solutions/security/plugins/security_solution/common/detection_engine/rule_management/rule_fields.ts` — *focus review effort here*. Two new field-name constants (`PARAMS_SEVERITY_FIELD`, `PARAMS_RULE_ID_FIELD`).
- **Other teams' files (12):** Skill, fixtures, eval suite, and skill-allow-list entry are owned by `@elastic/security-solution` (umbrella) and `@elastic/workchat-eng`.
- **Unowned:** none.

The skill is now an even bigger consumer of rule-management's KQL/filter utilities — it pulls in `convertRulesFilterToKQL`, `convertRuleTagsToKQL`, `findRules`, `RULE_PARAMS_FIELDS` (now using `TACTIC_ID` and `TACTIC_NAME`), and `EXPECTED_MAX_TAGS`. The biggest review value remains making sure the skill's filter-building stays consistent with how rule-management itself builds filters.

## Summary

Adds a new built-in Agent Builder skill, `find-security-rules`, that lets the AI Assistant answer rule-discovery questions ("list/sort/count detection rules"). The skill exposes two new inline tools (`security.find_rules`, `security.discover_rule_tags`) and references the existing `security.alerts` registry tool for noisy-rules queries. Internally `security.find_rules` builds a KQL filter from flat parameters, mostly delegating to the existing `convertRulesFilterToKQL` and adding clauses for parameters that helper doesn't support (severity, tags-as-OR, MITRE technique/tactic, ruleId, excludeTags). `security.discover_rule_tags` runs a `findRules` aggregation on the `tags` field with `size: EXPECTED_MAX_TAGS` (65536) and returns the buckets.

Stated intent in the PR description matches the diff — except the description still doesn't mention the `mitreTactic` parameter that the skill now exposes. Minor doc drift, not a substantive divergence.

## Files touched

**Rule-management-owned (your team's only file):**
- `x-pack/.../rule_management/rule_fields.ts` — adds `PARAMS_SEVERITY_FIELD = 'alert.attributes.params.severity'` and `PARAMS_RULE_ID_FIELD = 'alert.attributes.params.ruleId'` to the existing constants. Pure additive. *(Unchanged since first review.)*

**New skill (security_solution agent-builder, `@elastic/security-solution`):**
- `find_rules_skill.ts` (now 166 lines, was 134) — skill manifest with prompt content (~120 lines). Adds the MITRE routing section, 14-tactic table, and the new "fresh discovery every turn" rule.
- `find_rules_tool.ts` (now 296 lines, was 278) — `security.find_rules` schema, `buildToolFilter`, and handler. Adds `mitreTactic` parameter.
- `discover_rule_tags_tool.ts` (105 lines) — now imports `EXPECTED_MAX_TAGS` from rule-management constants instead of hard-coding `1000`.
- `find_rules/index.ts`, `skills/index.ts`, `register_skills.ts` — barrel and wiring (unchanged).

**Allow-list (workchat-eng):**
- `agent-builder-server/allow_lists.ts` — adds `'find-security-rules'` to `AGENT_BUILDER_BUILTIN_SKILLS`. Unchanged.

**Tests / fixtures / evals:**
- `find_rules_skill.test.ts` (623 lines, was 566) — adds `mitreTactic` filter tests, the canonical-tactic-table-in-content test, and asserts `EXPECTED_MAX_TAGS` for the discovery aggregation size (now matches production).
- `find_rules.spec.ts` (559 lines, was 437) — adds eval cases that exercise the MITRE tactic routing path and the fresh-discovery-every-turn behavior.
- `find_rules_fixtures.ts` (478 lines, was 425) — adds more seeded rules / threat metadata to support the new MITRE-routed examples.
- `moon.yml`, `tsconfig.json` — `@kbn/test` dependency. Unchanged.

## Flow trace (rule-discovery happy path with MITRE)

User asks AI Assistant *"Show me detection rules for Defense Evasion."*

1. Agent Builder routes to `find-security-rules` based on the skill's description and content.
2. Per the (newly stricter) skill prompt, the model calls `security.discover_rule_tags` with `{}` — required even on first turn, but more importantly required *every* turn.
3. `createDiscoverRuleTagsInlineTool` calls `findRules({ rulesClient, perPage: 0, page: 1, aggregations: { by_field: { terms: { field: TAGS_FIELD, size: EXPECTED_MAX_TAGS } } } })`. This now uses the same cap as the existing rule-management `readTags` API.
4. Buckets returned. The model sees a `Tactic: Defense Evasion` value in the bucket list, but the skill prompt explicitly tells it: **"Do not put a `Tactic: ...` or `Technique: ...` value into the `tags` filter for a MITRE query, even if it appears in the discover result."**
5. Per priority order, the model maps "Defense Evasion" → `TA0005` (from the table in the prompt) and calls `security.find_rules` with `{ mitreTactic: "TA0005" }`.
6. `buildToolFilter` sees `params.mitreTactic = "TA0005"`, the `/^TA\d{4}$/i` regex matches, and emits `alert.attributes.params.threat.tactic.id: "TA0005"`. (For a free-form name like "Initial Access" it would route to `RULE_PARAMS_FIELDS.TACTIC_NAME`.)
7. The query runs through `enrichFilterWithRuleTypeMapping` (constrains to SIEM rule types).
8. Results map through `summarizeRule` (still uses dual `params.rule_id ?? params.ruleId` / `params.risk_score ?? params.riskScore`).
9. Handler builds a one-line message that inlines every rule name returned (still — see Risks).
10. Agent Builder returns the result; the model summarizes per the skill's rendering prompt.

The structured-tactic path is the right design for MITRE: rule tag coverage is acknowledged-inconsistent (some rules only have the structured `threat[]` field), so going through `RULE_PARAMS_FIELDS.TACTIC_ID/NAME` instead of free-text tags will catch more rules.

## Assumptions

- **Field constants match SO storage.** `PARAMS_SEVERITY_FIELD = 'alert.attributes.params.severity'`, `PARAMS_RULE_ID_FIELD = 'alert.attributes.params.ruleId'`, plus the existing `RULE_PARAMS_FIELDS.TACTIC_ID/NAME` (newly used by this PR) all assume the alerting saved-object stores camelCase params. Verified against existing usage (`read_rules.ts`, `get_rule_by_rule_id.ts`).
- **MITRE tactic IDs are stable across the rule corpus.** The 14-tactic table in the prompt is hand-maintained against MITRE Enterprise ATT&CK. If MITRE deprecates or renames a tactic, the prompt and the structured field both go stale at the same time. Acceptable for now (the IDs have been stable for years), but worth noting.
- **The `/^TA\d{4}$/i` regex correctly disambiguates ID vs name.** A user-supplied free-form value like `"ta1234"` would match the regex and route to `TACTIC_ID` even though no such tactic exists. Low risk in practice (the model is told to use values from the canonical table) but the ID branch will silently produce no results rather than fall back to a name search.
- **Tag values are unique enough that 65536 buckets is more than enough.** Now using the same cap as the existing `readTags` helper, so this assumption is shared across the codebase rather than skill-local.
- **Eval fixtures don't collide with real rules.** Same as before: `seedFindRulesFixtures` deletes "leftover fixtures from crashed runs" by matching rule **name**. Fine for ephemeral test envs, brittle anywhere else.
- **Direct ES write to `.internal.alerts-security.alerts-default-000001`.** Still hard-codes the partition name and bypasses the alerts-as-data write APIs. Unchanged.
- **The Alerting `find` API supports arbitrary `aggs`.** Confirmed via `find_rules_schemas.ts`. Unchanged.
- **"Discover every turn" doesn't blow the latency budget.** Each `security.find_rules` call is now preceded by a `discover_rule_tags` aggregation in the same turn, even when it's a follow-up. That's an extra ES round-trip per turn versus the previous "skip on follow-up" design. The author judged the consistency-vs-latency trade in favor of consistency. Worth confirming the skill's eval Latency numbers are still acceptable (the PR description notes Latency is trace-based and not reported).

## Risks

Ordered by severity. Risk numbers preserved from the prior review where applicable.

1. **~~Tag aggregation cap mismatch~~ — RESOLVED.** Production now uses `EXPECTED_MAX_TAGS`.
2. **Token-budget blow-up on truncated results (medium, unchanged).** `find_rules_tool.ts` still inlines every rule name into the result message *and* returns the full `rules` array. With `perPage` capped at 100, that's up to ~100 rule names duplicated between the formatted message and the structured array. The skill prompt defaults to `perPage: 10` and tells the model not to raise it, but a user can override.
3. **`summarizeRule` dual snake/camel fallback (low–medium, unchanged).** Still reads both `params.rule_id` / `params.ruleId` (and same for risk_score). Existing rule-management code consistently uses camelCase from `rulesClient.find` — the snake_case branch is most likely dead code. Worth pruning or commenting.
4. **`mitreTactic` ID-vs-name routing has no fallback (new, low).** If the model passes a tactic name that doesn't match the canonical table (e.g. typo, MITRE version drift), `buildToolFilter` emits `tactic.name: "<bad-value>"` which silently returns zero results. The `buildNoResultsHint` path doesn't currently distinguish "filter included MITRE values" from generic empties — a `discover_rule_tags`-style hint when `mitreTactic` is present and yields zero rules would help, but the no-results path is already chatty. Minor.
5. **Eval fixture cleanup is by name, not by tag/marker (low, unchanged).** Same footgun in test envs — fixture naming can collide with real rules.
6. **Direct write to `.internal.alerts-security.alerts-default-000001` (low, unchanged).** Bypasses alerts-as-data; hard-coded partition name.
7. **No feature flag (low, unchanged).** Skill is registered unconditionally in `register_skills.ts`. Contrasts with `pciComplianceAgentBuilder` in the same file.
8. **"Discover every turn" amplifies any failure in `discover_rule_tags` (new, low).** The skill's prompt now conditions every `find_rules` call on a preceding discovery call. The discovery handler does have try/catch + error result, but the skill prompt doesn't tell the model what to do when discovery returns a `ToolResultType.error` — it just says "always call it before find_rules". A degraded discovery (e.g. a transient ES error) could produce confusing model output if the prompt's contract is read literally. Worth confirming the model handles that gracefully in evals.

## Open questions

1. **`mitreTactic` regex strictness.** The regex `/^TA\d{4}$/i` accepts any 4-digit suffix, not just the 14 canonical tactics. Was that deliberate (forward-compat with future MITRE additions) or an oversight? A `z.enum([...14 IDs])` would catch typos at the schema layer. Same question for the display-name path: any non-empty string is accepted and routed to `tactic.name`.
2. **`PARAMS_RULE_ID_FIELD` placement (unchanged).** New constants sit alongside the existing `RULE_PARAMS_FIELDS` record rather than inside it. Existing convention isn't perfectly consistent, so this is fine, but worth a call from the file's owner.
3. **Why are tags OR'd in `buildToolFilter` but AND'd in `convertRuleTagsToKQL`?** Acknowledged in a comment, but the schema gives users no way to express "tagged with BOTH X AND Y". Was the omission deliberate?
4. **`summarizeRule` dual snake/camel fallback (unchanged).** Where is the snake_case branch reachable? Now that the rest of the code uses camelCase consistently, this looks like leftover defensive code from an earlier iteration.
5. **Direct write to `.internal.alerts-security.alerts-default-000001` (unchanged).** Is there an existing test helper for seeding alerts that wraps this?
6. **Latency impact of "discover every turn".** The PR description's eval table doesn't include Latency or Token counts (trace-based). With the new "fresh discovery every turn" rule, the average turn now does 2+ `findRules` calls instead of 1. Has anyone measured the impact on conversational latency in practice?
7. **Multi-turn eval fragility (unchanged).** The substring match on `"medium"` in the multi-turn turn-2 assertion is still brittle — a `searchTerm: "medium"` would falsely satisfy it.

## Notes for your codebase map

- **`RULE_PARAMS_FIELDS.TACTIC_ID` / `TACTIC_NAME`** are now used outside the rule-management UI for the first time (by this skill). If the value of those constants ever changes, the AI Assistant's MITRE routing breaks silently.
- **`EXPECTED_MAX_TAGS`** has gained a second consumer (the Agent Builder skill). It's effectively now a public contract from `lib/detection_engine/rule_management/constants` — worth treating it that way in future refactors.
- **Detection-rule field constants** in `common/.../rule_fields.ts` continue to grow new top-level exports rather than being added to the `RULE_PARAMS_FIELDS` record. Convention is mixed; there's no single source of truth for "where do I put a new field constant".
- **`convertRulesFilterToKQL`** still doesn't cover severity, MITRE technique/tactic, OR'd tags, or per-rule `ruleId`. Two consumers now hand-roll those clauses (the rule-management UI and this skill). Worth considering first-class params if a third consumer appears.
- **Agent Builder skills can mandate same-turn tool-call ordering through prompt design.** The "always call discover before find, every turn" pattern is enforced in two places (skill `content` + `find_rules` tool description) — there's no programmatic gate, just doubled-down prompt constraints. Useful pattern to recognize when reading other Agent Builder skills.
- **`summarizeRule`'s dual snake/camel fallback** is a tell that someone wasn't sure whether `rulesClient.find` returns API-shape or SO-shape params. The Alerting framework camelizes them at the SO layer — code reading from `rulesClient.find` should standardize on camelCase.
