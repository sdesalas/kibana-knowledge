# PR Review: #301386 — [Detection Watch] Reuse one Investigation per gap and per rule across reviews

**PR:** [elastic/kibana#301386](https://github.com/elastic/kibana/pull/301386) by @dhurley14
**Created Date: 2026-11-26**

**Scale:** Substantive. New internal route + service, two managed review workflows rewired, attachment id scheme changed (~2.1k lines, a lot of it tests and YAML comments).

**Ownership (team: `@elastic/security-detection-engineering`)**
- **Your team's files (2):** `security_solution/public/agent_builder/attachment_types/rule/helpers.ts`, `helpers.test.ts` (shared with `@elastic/security-investigations`)
- **Other teams' files:** everything else (25 files) — `@elastic/alertzero-common-layer` (alertzero plugin, `kbn-alertzero-common`, `kbn-workflows/managed/definitions/alertzero`)
- **Unowned:** none

Only 2 DE-owned files, and they're a tiny prefix-match change. The behaviour change, though, is squarely Detection Watch (Rule Coverage + Rule Tuning), so it's worth a domain review even if you're not the accountable owner.

---

### Context / Motivation

[security-team#20386](https://github.com/elastic/security-team/issues/20386) reported that when a **Rule Coverage** proposal expires, the next sweep re-reviews the same gap and opens a brand-new Investigation every time, leaving the old one open and unlinked:

> Each sweep creates a new "Detection coverage: …" investigation per gap; the earlier ones stay `open`.

Root cause per the issue: `coverage_review.yaml` always runs `ai.conversation.create`, with nothing keyed on `ki_id`. Hunt Watch already avoids this with a deterministic find-or-create. The issue's preferred fix:

> Use the same investigation for a new sweep.

The PR takes the preferred fix, and also applies it to **Rule Tuning**, which has the same pattern (the issue only mentions Coverage).

### Validating the issue — does this PR address it?

**The concern is valid, and the PR addresses it for new subjects. Subjects reviewed before this change get one more duplicate (documented).**

- **Where the problem manifests:** on `main`, both `coverage_review.yaml` and `rule_tuning_review.yaml` start with `create_investigation: ai.conversation.create`, which mints a random id each run. The review re-runs whenever the proposal expires (coverage: indicator stays `pending`; tuning: alerts are only tagged after the gate resolves), so each expiry = a new Investigation.
- **How the PR fixes it:** `POST /internal/alertzero/investigations/find_or_create` derives `uuidv5("worker:subject:" + space|worker|subject)` (`worker_investigation_id.ts`). First call creates at that id; later calls hit "already exists", read it back, and reuse it (`find_or_create_worker_investigation.ts`). Both YAMLs swap `ai.conversation.create` for a `kibana.request` to that route.
- **Residual caveat:** reuse only happens if the existing conversation is on the Investigation template **and the calling identity owns it**. Anything else falls back to a random id — i.e. the old behaviour — with just a `warn` log. See Risk 1.

### Summary

Each Detection Watch Worker now keeps one Investigation per subject (knowledge indicator for Coverage, rule saved-object id for Tuning). Re-reviews reuse it, reopen it if closed, refresh the description, append the execution id, post a "Review resumed" note, and emit `worker_investigation_reopened` telemetry on reopen. Because fixed-id attachments (`tuned-rule`, `fp-alerts`, `coverage-rule-<id>`) already exist on a reused Investigation, each `ai.attachment.add` is now followed by a conditional `ai.attachment.update`, plus a re-add under a per-run id if the analyst deleted the card. Per-review cards (`rule-draft`, `proposed-exception`) now carry the execution id so reviews never overwrite each other. Matches the issue's intent; extends scope to Tuning.

### Files touched

- **New route + service** (`alertzero/server/routes/investigations/find_or_create_investigation.ts`, `services/investigations/find_or_create_worker_investigation.ts`, `worker_investigation_id.ts`, `register_routes.ts`, `common/constants.ts`): the actual find-or-create logic, id derivation, and route registration. Needed because a workflow step can't compute a uuidv5.
- **Route contract** (`kbn-alertzero-common/.../find_or_create_investigation_route.schema.yaml` + `.gen.ts`, `constants.ts`, `index.ts`): OpenAPI schema and generated Zod types. `workerId` is an enum of just the two detection Workers.
- **Review workflows** (`coverage_review.yaml`, `rule_tuning_review.yaml`, `rule_creation.yaml`): swap `create_investigation` for the route call, rename every `steps.create_investigation.output.conversation_id` reference, add resume/re-add attachment steps, per-run ids for drafts and exceptions.
- **Rule card UI** (`security_solution/.../attachment_types/rule/helpers.ts` + test) — *DE-owned*: `isRuleDraftAttachment` now accepts `rule-draft` **or** `rule-draft-<anything>`, since drafts now carry the execution id. All callers (`rule_inline_content.tsx`, `rules_group_renderer.tsx`) go through the helper, so nothing else needed changing.
- **Contract/telemetry tests and docs** (`*.test.ts`, `shipped_yaml_contract.*`, `telemetry/README.md`, `workers/detection.md`): pin the new step names and output paths.

### Flow trace (Rule Tuning re-review after an expired proposal)

1. Tuning sweep (`detection_rule_tuning.yaml`) launches the worker with `run-as-mode: inherit`, which launches `rule_tuning_review` per rule. Concurrency key `rule-tuning-review-{rule_uuid}`, `max: 1`, `strategy: drop`.
2. `find_or_create_investigation` (`kibana.request`) POSTs `/s/{space}/internal/alertzero/investigations/find_or_create` with `workerId`, `subjectId = inputs.rule_uuid`, title, description, `execution.id`.
3. Route requires `alertzero_write` **and** `readAgentBuilder`, gets the scoped conversation client for the request, calls `runFindOrCreateWorkerInvestigation`.
4. Service computes the uuidv5 and tries `create(id)`. On a re-review it throws "already exists".
5. Service `get`s the conversation. `whyNotReusable` checks `template_id === investigation` and `permissions.update_access_control` (owner-only per `hasConversationUpdateAccessControlAccess`). If either fails, it creates a fresh random-id Investigation and returns `created: true`.
6. Otherwise `resumeExisting` builds one `patchMetadata` (with `converse` access): `status: open` if closed, new description, appended execution id. `reopened` = was closed **and** `status` actually changed (handles a racing reopen).
7. If reopened, telemetry fires async, but only after confirming via workflows management that the execution really is a run of that Worker's review workflow.
8. Back in YAML: `post_resumed` adds the "Review resumed" note when `created != true`.
9. `attach_rule` (`tuned-rule`) fails with "already exists" → `resume_rule_attachment` updates it to a new version → if that fails with "deleted" → `readd_rule_attachment` adds `tuned-rule-{execution.id}`. Same pattern for `fp-alerts`.
10. After an applied change, `rule_attachment_written` (`data.set`) works out which card was written, and `refresh_rule_attachment` writes the post-tuning rule to it. Approve/dismiss closes the Investigation as before.

### Assumptions

- **One review per subject at a time.** The read-modify-write on `workflow_execution_ids` is only safe because of the review workflows' concurrency keys (`coverage-{ki_id}` / `rule-tuning-review-{rule_uuid}`, `max: 1`, `drop`). Verified in both YAMLs. The route itself does nothing to enforce this.
- **The `kibana.request` step calls the route as the Worker's identity.** The owner check (`update_access_control`) only works if the same identity always makes the call. Same pattern Hunt already uses for its `/internal/alertzero/hunt/*` calls, so the mechanism exists, but the identity depends on `run-as-mode: inherit` all the way up from the sweep.
- **Agent Builder error message text is stable.** The YAML branches on `error.message contains 'already exists'` and `contains 'deleted'`. Today those come from `attachment_public_client.ts:298` (`Attachment with id '…' already exists`) and `attachment_state_manager.ts:400` (`Cannot update deleted attachment "…"`).
- **`inputs.rule_uuid` is the rule's saved-object id and stays stable.** A deleted-and-reimported rule gets a new id, so a new Investigation. Probably fine.
- **`getWorkflowExecution` returns `workflowId` or `originManagedWorkflowId` matching the managed review id.** Only matters for whether the reopen telemetry fires.
- **Input bounds hold.** Title is truncated to 480 (+ prefix, < 500 max), coverage description comes from a field truncated to 2000 (< 10000 max). Checked.

### Risks

1. **The fix quietly turns itself off for a subject if the wrong identity mints the deterministic id first.** The reuse check requires the caller to *own* the conversation. The sweeps use `run-as-mode: inherit`, and the PR's own manual test plan triggers the sweep with `POST /api/workflows/workflow/.../run` as `elastic`. If that run's identity is `elastic` rather than the service account, `elastic` owns the deterministic Investigation. Every later scheduled review (as the service account) would then fail the owner check and fall back to a random id: back to one new Investigation per review, for that subject, forever, with only a `warn` log. Rotating the Worker's service account does the same to every subject the old account touched (the code comment admits this). Needs checking: who does a manual `/run` of a managed Worker sweep execute as?
2. **Resuming depends on matching error message strings.** If Agent Builder rewords either error, `resume_*` / `readd_*` silently stop running (they're all `on-failure: continue`). Then resumed reviews keep the earlier review's stale rule/alerts cards, and nothing fails or logs loudly. The workflow tests check the YAML shape, not these strings against Agent Builder.
3. **Old drafts and exceptions pile up on one Investigation.** Each review now adds `rule-draft-<exec>` / `proposed-exception-<exec>`, and earlier ones stay ("for comparison"). The rule card treats every `rule-draft-*` as an unsaved draft (`rules_group_renderer.tsx` `isUnsavedDraft`), so an analyst could see several drafts and act on a stale one from an expired review. UX risk, not a correctness bug.
4. **A reopened Investigation keeps its old `close_reason`** (e.g. `resolved`) while `status` is `open`. Anything that reads `close_reason` without checking `status` (UI badges, telemetry, list filters) could misreport. Documented in the PR, but worth checking who reads that field.
5. **Investigations opened before this change aren't adopted.** One extra duplicate per subject on upgrade. Documented in the release note; low risk.
6. **Two find-or-create implementations now differ.** Hunt's service (`services/watches/hunt/common/find_or_create_investigation.ts`) doesn't do the template or owner checks this one does. The PR leaves unifying them for later. Fine, but Hunt presumably has the "someone else pre-created the id" problem this PR guards against.

### Open questions

- When the sweep is triggered by hand (`POST /api/workflows/workflow/<sweep>/run` as `elastic`, as in the test plan), which identity does the review's `kibana.request` run as? If it's the human, does that permanently push the subject onto the random-id fallback (Risk 1)?
- Should the fallback path emit telemetry or a step output (e.g. `fallback: true`) rather than just a `warn`? Right now a subject stuck in fallback is invisible unless someone reads the Kibana logs.
- Does the workflow engine expose a structured error code for attachment steps, so the YAML could branch on that instead of `message contains '…'`? If not, is there a test pinning the Agent Builder message text these steps depend on?
- Why an internal HTTP route rather than a custom alertzero step type (the plugin already registers step types like `report_worker_outcome`)? A step type could compute the uuidv5 in process, skip the HTTP hop, and sidestep part of the "who is calling" question.
- Should earlier `rule-draft-*` / `proposed-exception-*` cards be marked as superseded, so analysts don't act on a draft from an expired review?
- Scope: the issue only covers Coverage. Was extending this to Tuning agreed with the Tuning owners, given the reopen-on-new-FPs behaviour (a rule tuned and closed earlier gets its old Investigation reopened)?

### Notes for your codebase map

- Detection Watch Workers (Coverage, Tuning) are managed workflow YAMLs under `kbn-workflows/managed/definitions/alertzero/`. A sweep launches one review workflow per subject, and a concurrency key keeps one review per subject in flight.
- "Investigations" are Agent Builder conversations on `template_id: investigation`. Status, description and execution ids live in conversation metadata, and proposals attach to them via `system-create-alertzero-proposal`.
- Workflows can't compute uuids, so deterministic ids come from internal alertzero routes called via `kibana.request` (Hunt pioneered this; this PR adds a Worker-generic version keyed on `space|worker|subject`).
- In Agent Builder, `permissions.update_access_control` is effectively "is owner" (`hasConversationUpdateAccessControlAccess` → `hasConversationOwnerAccess`).
- Attachments are versioned and can't change `origin`. Deleted attachments keep their id: `add` reports "already exists" and `update` refuses with "Cannot update deleted attachment". There's no restore from a workflow.
- Workflow step `if:` conditions can't group with parentheses, hence the `data.set` "computed flag" step pattern.

### Follow-up Review Activities

-- LEFT EMPTY INTENTIONALLY --
