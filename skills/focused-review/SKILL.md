---
name: focused-review
description: Do a review pass focused on a specific angle (architecture, type hygiene, memory, performance, rbac, error handling, test coverage, over-engineering, clean code, solution integration, api contract, security, gating, concurrency, observability, documentation, dead code, i18n). Use when the user says "focused review", "/focused-review", or asks for a targeted pass over a diff or specific code. Accepts an argument naming the focus area — e.g. `/focused-review architecture`, `/focused-review performance`.
---

# Focused Review

A single-lens pass over a diff, a file, or a specific code region. Standard PR review casts a wide net — this skill picks one angle and applies it thoroughly, catching a class of issues that get lost in a general sweep.

Each focus area below is intentionally abstract: a principle, not a checklist. Interpret it against the code in front of you. The examples are illustrative — the class of issue that fits the focus — not an exhaustive rulebook. Every PR is different; the focus tells you which lens to look through, not what you'll see.

## When this skill triggers

- `/focused-review <focus>` — apply the named focus.
- `focused review` or `do a focused review on <focus>` — same.
- Also triggers when the user asks to "do a pass focused on X" over an existing review or diff.

## How to interpret the argument

Match the user's phrase (fuzzy, case-insensitive) to one of the focus areas below. Accept plurals, hyphens, and near-synonyms:

| User says                                                                    | Matches              |
| ---------------------------------------------------------------------------- | -------------------- |
| `architecture`, `scope`, `layering`, `boundaries`, `drive-by`, `scope creep` | architecture         |
| `type hygiene`, `types`, `type safety`, `typing`, `cross-plugin coupling`    | type-hygiene         |
| `memory`, `memory consumption`, `heap`, `resource`                           | memory               |
| `performance`, `perf`, `n+1`, `algorithmic`, `hot path`, `slow`              | performance          |
| `rbac`, `authz`, `authorization`, `access control`, `privileges`             | rbac                 |
| `error handling`, `errors`, `failure modes`                                  | error-handling       |
| `test coverage`, `tests`, `mocks`, `coverage`, `test organisation`           | test-coverage        |
| `over-engineering`, `over engineered`, `defensive`, `complexity`             | over-engineering     |
| `clean code`, `readability`, `naming`, `comments`, `simplicity`, `style`     | clean-code           |
| `solution integration`, `integration`, `framework`, `primitives`, `dependency` | solution-integration |
| `api contract`, `api`, `response shape`, `public`, `schema`, `migration`     | api-contract         |
| `security`, `hardening`, `injection`, `xss`, `input validation`              | security             |
| `gating`, `feature flag`, `license`, `flag`                                  | gating               |
| `concurrency`, `race`, `parallel`, `ordering`                                | concurrency          |
| `observability`, `logging`, `apm`, `spans`                                   | observability        |
| `documentation`, `docs`, `jsdoc`, `readme`                                   | documentation        |
| `dead code`, `orphaned`, `unused`, `unreachable`                             | dead-code            |
| `i18n`, `translation`, `translations`, `localization`, `l10n`                | i18n                 |

If the user gives multiple foci (`/focused-review types and memory`), run each in turn as separate sections. If no focus is given, ask which one they want — don't run all of them by default.

## Operating context

- The skill runs inside the checked-out repo. Read surrounding code directly rather than asking the user to paste it.
- Keep the output tight: bullets of concrete findings, file:line references, and one-line justifications. No prose padding.
- If a PR review document is active in the session, also update it in place — see [Output](#output).

---

## architecture

**Principle:** Changes should respect module boundaries, layering, and the PR's stated scope. A change is an architecture concern when responsibilities land in the wrong module, dependency direction inverts, single-use abstractions appear without payoff, duplicated patterns aren't factored out, or unrelated drive-by changes ride along with the main feature. See the dex-dev-skills [architecture-reviewer role](https://github.com/elastic/dex-dev-skills/blob/main/skills/dex-review-code/references/roles/architecture-reviewer.md) for the wider lens this focus draws on.

**Look for:**
- New responsibilities placed in a module they don't belong in because that module was already open in the diff.
- Dependencies pointing the wrong way (data → UI, common → server, package → plugin) or introducing cycles.
- Heavy dependencies pulled into a lightweight module.
- Single-use abstractions ("might need this later") without a second caller — or inline duplication of a pattern that already has a helper.
- Drive-by fixes / refactors unrelated to the PR's stated goal; silent behavior changes that will surprise a `git blame` reader.
- New code shape that doesn't match sibling modules in the same plugin/domain.

*Examples:*
- A rule-scheduling helper placed in a `common/` package so the UI can import it, dragging server-domain logic into a bundle the browser has to load — the direction should be server → common, not common ← server.
- A "cleanup" that generalises a two-key normaliser into an all-keys one, silently changing the wire format for downstream consumers.

---

## type-hygiene

**Principle:** Types should be canonical, consistent with siblings, and structurally safe at boundaries — including boundaries between plugins or teams where a shape you own becomes another team's contract. A change is a type-hygiene concern when it introduces a bespoke shape where a shared one exists, breaks a convention nearby, relies on structural compatibility that could silently drift, or leaks consumer-specific naming into a type owned by a wider audience.

**Look for:**
- Bespoke or anonymous types where a canonical one is exported from a nearby module or framework.
- Divergence from the shape used by sibling functions on the same interface.
- Structural-compatibility silences: two arrays / objects treated as interchangeable because they happen to overlap today.
- Fields added to shared / cross-plugin / cross-team types whose naming leaks the caller's domain into the shared shape.
- Missing return types on exported functions; casts that suppress rather than resolve a narrowing failure.

*Examples:*
- Two look-alike interfaces defined in separate files that are structurally equivalent today but will drift as one side grows a field.
- A consumer-specific field name added to a type owned by another plugin or team, leaking the caller's domain into the shared contract.

---

## memory

**Principle:** Peak resource usage should be bounded and predictable, not proportional to input size or unknowable at review time. A change is a memory concern when it introduces an unbounded input, retains data past its useful life, or scales resource cost with something the caller can't control.

**Look for:**
- Inputs whose size grows with usage over time, with no bound near the entry point.
- Retention of large intermediates past the point they're needed (closures, arrays, cached lookups).
- Parallel / concurrent structures whose in-flight footprint isn't obvious at a glance.
- Constants that encode a memory/throughput trade-off but aren't documented as such.

*Examples:*
- A fetch whose input list grows with data over time (all rules, all users, all documents) with no cap at the handler.
- A chunk size constant chosen without a comment explaining the memory/throughput trade-off behind that specific number.

---

## performance

**Principle:** Cost should scale predictably with input size, and hot-path work should be deliberate. A change is a performance concern when it introduces work that grows non-linearly with user-controlled input, moves heavyweight computation onto a request path, holds resources open beyond their useful life, or leaves independent async work strictly sequential when parallelism was available.

**Look for:**
- Nested loops over user-controlled or system-scaled inputs; linear searches inside loops that could be hash lookups; sorts inside hot paths.
- N+1 query patterns — per-row fetches inside iteration.
- Missing pagination or upper bounds on result sets that can grow with data.
- Sequential `await`s where independent operations could run under `Promise.all`; user-driven fan-out that isn't bounded.
- Hot-path allocations: `JSON.parse` of large strings, deep clones, unnecessary object creation inside tight loops.
- Lifecycle leaks: subscriptions, intervals, event listeners, open handles not cleaned up when their owner disposes.
- Caches whose invalidation story isn't obvious.

*Examples:*
- A per-rule enrichment step that fetches its threat-intel document from ES once per rule with no batching.
- A React effect that subscribes to a stream on mount but only cleans up on one of two exit paths, leaking the subscription on the other.

---

## rbac

**Principle:** Access control should be enforced server-side, symmetric across read/write paths for the same resource, and preserved when internal callers reach for "unsecured" primitives. A change is an RBAC concern when the effective privilege boundary shifts as a side effect of the diff — a new path bypasses an existing check, a check moves from route to service, or a client-side gate stands in for a missing server-side one.

**Look for:**
- New routes/handlers whose required privilege differs from siblings on the same resource without a rationale.
- Client-side gating without a matching server-side check (or vice versa).
- Use of `unsecuredSavedObjectsClient` or equivalent authz-skipping primitives — is the caller re-establishing the check?
- Trust-model shifts: a path that used to require a resource to exist now falls back to a snapshot / cache for authz info.
- Read and write privileges on the same resource asymmetric by accident rather than by design.

*Examples:*
- A new mutation whose route declares `RULES_API_ALL` while a sibling mutation on the same resource only requires `RULES_API_READ`.
- A "get history for a deleted rule" fallback that reads the latest snapshot with an unsecured client and uses the snapshot's own fields to drive the authorization check.

---

## error-handling

**Principle:** Every failure mode should have an intentional outcome — surfaced, translated, or swallowed on purpose. A change is an error-handling concern when a failure can silently change shape as it crosses layers, or when partial failure leaves the system in a state the caller can't reason about.

**Look for:**
- Layer boundaries where "throw" and "returns errors" meet — check which side wins.
- Whole-request-fails-fast operations mixed with per-item-partial-success operations.
- Errors that lose identifying information (status code, cause, entity id) when re-wrapped.
- Partial-persistence windows: what state survives when the middle of an operation throws?
- Missing `await` on a fallible async call — the error becomes an unhandled rejection instead of a caught failure.

*Examples:*
- A bulk primitive that returns `{errors, results}` wrapped by a caller whose only failure path is a `catch` — per-item errors get silently discarded.
- A chunked write where one bad chunk throws mid-way and leaves earlier chunks committed with no compensating rollback.

---

## test-coverage

**Principle:** Tests should exercise the behavior they claim to cover, with realistic mocks, coverage that reaches the interesting branch, and a structure a future maintainer can navigate. A change is a test-coverage concern when the test passes for reasons other than the code being correct, when the interesting branch isn't asserted, when new behavior lands without a test, or when the suite's organisation has decayed enough that the reader can't see what's covered and what isn't.

**Look for:**
- Mocks whose return values are placeholders / matchers rather than realistic data.
- Assertions on call shape without also asserting on returned or persisted results.
- Coverage that stops short of the boundary the code actually operates on (edge sizes, empty inputs, error paths).
- Setup that makes success and failure indistinguishable (empty error arrays, identical inputs across cases).
- New behavior without a test; bug fixes without a regression test.
- Suite organisation that has drifted: `describe` blocks that no longer group related tests, dead helpers left behind by earlier refactors, near-duplicate tests testing the same thing three ways, a single mega-file that a folder split would clarify.
- Integration-vs-unit split: a unit test that mocks the entire framework needs an integration test compensating — is one there?

*Examples:*
- Using an asymmetric matcher (`expect.any(String)`) as *return data* from a mock — downstream lookups against a matcher object silently return `undefined`.
- A test file whose top-level `describe` still names an API endpoint that was renamed six months ago, containing tests scattered across unrelated concerns because nobody re-titled or re-organised after the rename.

---

## over-engineering

**Principle:** Code should be as simple as the problem allows; defensive branches, guards, and abstractions must justify their cost in reading effort. A change is an over-engineering concern when guards handle cases the write path never produces, error handling absorbs failures instead of surfacing them, abstractions serialize a single caller, or complexity is added "just in case" without a plausible triggering case.

**Look for:**
- Type guards that check for shapes the write path is incapable of producing.
- `try/catch` blocks whose enclosed calls can't throw, or whose catch branch just re-logs and returns.
- Helpers that handle `Date | number | null | string` when the caller only ever supplies `string`.
- Cached / memoised functions used exactly once, or caches keyed on values that already deduplicate upstream.
- Abstractions with a single caller and no plausible second one.
- Null-safety chains (`x?.y?.z?.a`) where the shape guarantees non-null after a step or two.
- Ask on every guard: "what code path produces the value this guard catches?" If none exists, the guard is over-engineering.

*Examples:*
- A hydration helper accepting `Date | number | string | null` and returning `Date | null`, when the only writer serialises to `string` and the reader casts the result to `Date` afterward.
- A wrapper around a primitive that already provides the same caching / validation the wrapper claims to add — the outer layer just adds indirection.

---

## clean-code

**Principle:** Code should be readable by the next engineer without effort — meaningful names, small functions, deliberate simplicity, and comments that explain *why*, not *what*. Style should follow the repo's conventions rather than the writer's preferences. A change is a clean-code concern when a reader has to mentally execute the code to understand it, when names lie, when function size or nesting exceeds what the logic needs, or when the code drifts from the surrounding style.

Kibana-specific style rules (from `.cursor/rules/code-style-guidelines.mdc`):
- Prefer short one-or-two-word names; avoid three-plus-word names unless intent is genuinely unclear.
- Don't echo the enclosing method/file name in a variable (`createdRules` inside `createRule()` — just `rules`).
- Keep comments to a minimum, one line each, only where they explain non-obvious intent — never narrate what the code does.
- Do not rename existing variables or functions unless explicitly asked to.

**Look for:**
- Names that mislead — variables named for their type instead of their role, boolean names that don't read naturally in a conditional.
- Functions over ~30 lines or with deep nesting where early returns / extraction would flatten the flow.
- "Clever" one-liners that require mental execution to understand.
- Comments that narrate *what* the code does rather than *why*; hedged multi-paragraph comments where one sentence would do.
- Magic numbers or strings referenced more than once without a name.
- New code whose shape doesn't match sibling files in the same folder (import order, section ordering, helper placement).
- Redundant null checks / defensive branches the shape already guarantees against.

*Examples:*
- A function called `processData` that neither processes nor operates on anything specifically shaped like data — the name conveys no intent.
- A five-line comment describing what a well-named function already says in its signature, immediately above the function definition.

---

## solution-integration

**Principle:** When a change delegates to a framework primitive, a platform service, or another plugin, the caller must understand and respect the actual contract of what it's calling — not the assumed one. A change is a solution-integration concern when the caller's error handling, batching, ownership, or state assumptions depend on behavior of a dependency that hasn't been verified against the source.

**Look for:**
- Assumptions about what a framework / platform method throws vs returns — verify against the source, not the name or docstring.
- Reliance on framework-internal defaults (batch sizes, retry counts, chunk boundaries) as if they were guarantees.
- Cleanup / rollback responsibilities: which side owns compensating action when the dependency partially succeeds?
- Authorization or validation primitives used with the wrong semantics (e.g. treating a check-primitive as if it enforces).
- ID / correlation-key handling: does the dependency echo caller-supplied IDs back? Does the caller's tracking logic assume so?

*Examples:*
- A method that "throws on failure" per its name but actually returns per-row errors after the pre-validation stage — caller's catch never fires for the interesting case.
- A caller wrapping a primitive in its own cleanup logic that duplicates (or races with) the primitive's own rollback path.

---

## api-contract

**Principle:** The externally-visible surface — request shape, response shape, status codes, persisted-data schema — should change deliberately and safely, not as a side effect of internal refactors. The persistence layer is part of the contract: stored data outlives the code that wrote it, and old rows must remain readable after schema migrations. A change is an api-contract concern when a diff to internal code alters what a consumer sees, or when a persisted shape changes without a story for the data that's already out there.

**Look for:**
- Fields added to shared / common types that flow through to responses without a route-file change.
- Response shape assembled by spreading a lower-layer type into an upper-layer typed container.
- Persisted-data changes (SO attributes, task params, index docs, data-stream fields) without a migration, model version bump, or backwards-compat story for existing rows.
- Persisting raw storage-layer shapes where an application-layer type would decouple the stored form from future schema migrations.
- Behavior differences when a feature flag is on vs off.

*Examples:*
- A new field on an internal result type spread into a response body, silently becoming part of the public shape.
- Snapshotting raw saved-object attributes into a long-lived index so that a later SO migration silently breaks readback of old snapshots.

---

## security

**Principle:** Any input crossing a trust boundary is potentially hostile; defensive posture is the caller's responsibility, not the callee's. A change is a security concern when it accepts, transforms, persists, or executes input from a lower-trust boundary without a validation, sanitization, or containment step commensurate with what happens next.

**Look for:**
- Query construction (Elasticsearch DSL, SQL, shell, regex) built from user input via template concatenation rather than parameterised primitives.
- User input flowing into filesystem calls, child processes, or crypto primitives without normalization / allowlisting.
- Secret handling: values that look like credentials logged or serialized (even at `debug`), or written to storage without the encrypted-SO wrapper.
- Rendering paths that inject HTML/JSX from partially-trusted content (`dangerouslySetInnerHTML`, raw markdown of user text without a sanitizer).
- Regex patterns applied to user input that risk catastrophic backtracking (ReDoS).
- Deserialization of externally-sourced JSON / YAML / tar into a typed shape without runtime validation.
- New dependencies — reputable? pinned? postinstall scripts?

*Examples:*
- An Elasticsearch `bool.filter` clause built with `` `field:${userInput}` `` — the underlying client escapes strings but the *shape* is still under the caller's control.
- A `debug`-level log line that includes the full rule attributes on write failure, including the raw `apiKey` before it's hashed.

---

## gating

**Principle:** Feature-flag + license + RBAC gating should agree end-to-end and enforce the strictest of the three at every entry point. A change is a gating concern when client-side and server-side gates diverge, when a layer of gating is skipped, or when an upstream dependency (framework flag, feature registration) isn't checked alongside the surface flag.

**Look for:**
- Client-side gate present without a matching server-side gate (or vice versa) — off-by-one gating a URL-hitting user can bypass.
- Multi-layer gating (flag + license + RBAC) inconsistent across sibling entry points.
- Upstream flag dependencies not documented or checked — a surface flag that only works when a framework-level flag is also on.
- Routes conditionally *registered* under a flag vs conditionally checked inside the handler; both work, but the pattern should match siblings.
- License-tier tests missing when the code has a license-dependent path.

*Examples:*
- One kebab-menu entry gated on `flagEnabled` while sibling entries also check `canReadRules` — the outlier is either a bug or an undocumented deviation.
- A feature that quietly requires two feature flags to be on simultaneously (surface + underlying framework), with only the surface flag advertised.

---

## concurrency

**Principle:** Side effects and shared state should behave correctly under out-of-order execution, partial failure, and retry. A change is a concurrency concern when its correctness depends on ordering, exclusivity, or a happens-before relationship that isn't enforced by the code.

**Look for:**
- Shared mutable state touched by multiple concurrent callers.
- Ordering assumptions that the underlying primitive doesn't guarantee.
- Side effects that aren't idempotent — retry after partial success produces duplicates, orphans, or half-states.
- Cleanup paths whose correctness depends on the order of thrown errors.

*Examples:*
- A "request-scoped" cache or memoiser that actually lives at module scope and leaks state between requests.
- Parallel side effects where partial failure leaves orphans — e.g. a task scheduled without its owning saved object, or vice versa.

---

## observability

**Principle:** An operator should be able to diagnose a failure from the signals the code already emits — logs, spans, metrics, audit events. A change is an observability concern when it removes, coarsens, or fragments signals a downstream consumer relies on.

**Look for:**
- Debug / info logging removed without an equivalent APM span or metric taking over.
- Spans that wrap a whole operation and lose per-item outcomes inside.
- Error paths that log the message but not the entity id / correlation key.
- Audit or metric events left in a partial state (start-without-end, unknown outcome).
- Log-level choices that quietly demote diagnosis-worthy failures — write failures at `debug`, per-item errors at `trace`.

*Examples:*
- A refactor that collapses per-item info logs into a single wrapper span, so on-call can see "operation failed" but not which item.
- An error log that reads "conflict" repeatedly without the entity id / correlation key needed to find the offending row.

---

## documentation

**Principle:** Public-facing documentation — READMEs, JSDoc on exported surface, architecture notes — should stay in sync with the code and explain intent a reader can't infer from names alone. A change is a documentation concern when a public surface changes without a docs update, when a JSDoc block on an exported symbol drifts from the code it describes, or when a README's stated behavior no longer matches the module.

*Line-level code comments are handled by the `clean-code` focus.*

**Look for:**
- Public surface changes (route, exported type, plugin contract, CLI flag) without a corresponding README / docs update.
- JSDoc on exported functions that lists parameter types (redundant with TypeScript) but adds no intent.
- JSDoc `@throws` / `@returns` that describes different behavior than the code — the docstring lies.
- README code samples that no longer compile against the current export surface.
- Missing README sections for capabilities the module exposes (e.g. no "backwards-compat" note on a persistence module).
- Documentation duplicated across multiple locations where drift will inevitably follow.

*Examples:*
- A `@returns` JSDoc describing a `boolean` return where the function now returns `Promise<{ ok: boolean; error?: string }>`.
- A public plugin contract growing a new setup method with no README section explaining when consumers would call it.

---

## dead-code

**Principle:** Every symbol, branch, and file touched by a diff should be reachable and used. A change is a dead-code concern when the diff leaves behind exports nothing imports, functions nothing calls, branches nothing enters, imports nothing uses, or commented-out blocks nothing runs.

**Look for:**
- New exports without a corresponding import somewhere else.
- Unused imports, unused function parameters, unused local variables.
- Branches whose predicate the enclosing shape can never make true.
- Files or folders left behind by a rename / move.
- Commented-out code blocks — history is in git; commented code is noise.
- Translation entries with no reader (see `i18n` for the mirror concern).
- Helpers moved into a new module without removing the original location.

*Examples:*
- An exported translation constant declared and exported but imported nowhere — remnant of an earlier UI iteration where the constant had a caller.
- A conditional branch inside a discriminated-union handler that matches a variant the type system already rules out at that position.

---

## i18n

**Principle:** User-facing strings should route through the codebase's i18n layer, use stable message ids that reflect the current UI shape, and stay in sync with their translation entries. A change is an i18n concern when a new user-facing string bypasses the layer, when an existing id no longer matches its constant / callsite, or when a message id lands orphaned (declared but never referenced, or referenced but never declared).

Kibana-specific: use `i18n.translate` in server / imperative code and `FormattedMessage` in React components; namespace ids under `xpack.<plugin>.<area>.<key>`; use `values` for interpolation rather than string concatenation. Run `node scripts/i18n_check --fix` to catch drift. See the `kibana-i18n` skill for the full pattern.

**Look for:**
- Hard-coded user-visible strings in JSX / server responses / toast messages that skip `i18n.translate` / `FormattedMessage`.
- Constant names that don't match their i18n id (e.g. `ACTION_LABEL_UPGRADED` bound to `actionLabelUpdated`) — the id is the contract, the constant is a local, but the mismatch is a smell.
- Placeholder interpolation via template strings inside the translated text instead of `values` — breaks translator context.
- Orphaned translation exports: declared and exported but no consumer.
- Translations added without running `i18n_check` to catch missing / stale entries.
- Plurals handled with `if (n === 1)` instead of an ICU `plural` block.

*Examples:*
- A new confirmation toast added as a plain string literal in a React component, escaping the plugin's `translations.ts`.
- A translation constant `WARNING_LABEL` bound to an i18n id that describes an error state — either the constant name or the id was updated after a UI change and the other wasn't.

---

## Output

Behavior depends on whether a PR review document is active in the session.

### When a PR review document is active

If there is an active `pr-review-<n>.md` in the session (created by the `pr-review` skill), update it in place *as well as* printing the standalone summary in chat:

1. **Append a new numbered entry to `Review activities`.** One tight paragraph naming the focus area, summarising the pass in one line, and listing the concrete findings — with cross-references to every Risks / Open questions entry you added, resolved, or updated (e.g. "raised as Risk #7", "resolved Risk #3", "answered Open question #2"). Also note non-findings worth recording ("checked X, Y, Z — clean").
2. **New findings → new entries.** Add risk-shaped findings to `Risks` following the existing numbering and severity language. Add surfaced uncertainties to `Open questions`, phrased as questions the PR author could answer.
3. **Resolved risks / answered questions → strike through with a pointer.** If the focused pass resolves an existing risk or answers an open question, wrap the original text in `~~...~~` and append `**Resolved — see activity #N.**` (or `**Answered — see activity #N.**`, or `**Dropped — <one-line reason>**` if the finding turns out to be a non-issue). Keep the numbering intact so earlier cross-references stay accurate.
4. **Severity changed → edit in place and flag.** If the pass shows an existing risk has grown or shrunk in severity, edit the risk's text in place to reflect the new reading — prefix with a marker like `(Downgraded to nit)`, `(Escalated to blocker)`, or `(Minor — lowest severity)` — and add a pointer to the new activity. Don't move the risk in the list unless the user explicitly asks.
5. **Never renumber, reorder, or rewrite untouched entries.** Preserve the document's structure and voice; append, strike, or edit-in-place with pointers only.

Then print the standalone summary below in chat so the user sees what changed without having to re-open the file.

### Standalone output shape

```
# Focused review: <focus-name(s)>

<one-line context: what file/PR/diff this is applied to>

## Findings

- **[<severity>] <file:line>** — <concrete finding, one line>
- ...

## Non-findings *(optional)*

Places you checked that were fine, if worth noting for the user's confidence.
```

Severities: `blocker`, `should-fix`, `nit`. Use them sparingly — most findings will be `should-fix` or `nit`.

## Anti-patterns

- Running all focus areas at once because "more coverage is better". Each focus is a distinct lens; mixing them produces the same noise as a general review.
- Treating the examples in each focus area as a checklist. They illustrate the *class* of concern; the actual finding will look different every time.
- Repeating the general PR-review sections (Summary, Files touched, etc). This skill is *only* the focused pass.
- Padding with observations that aren't in the focus area. If you notice something outside the focus, note it briefly at the end under "Out of focus" — don't derail the pass.
- Rewriting or renumbering existing entries in an active PR review document. Append new activities and add new risks / questions; edit existing entries only in place with a pointer to the new activity.
