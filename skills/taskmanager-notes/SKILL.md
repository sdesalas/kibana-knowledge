---
name: taskmanager-notes
description: Summarize Steven's substantive work from the current conversation into dated Markdown handoff notes in /Users/sdesalas/taskmanager/inbox. Use at the end of a conversation, when Steven asks to capture, save, summarize, or update the conversation as a Task Manager inbox note, or when he invokes /taskmanager-notes. Supports repeated invocations in one conversation, including multiple runs on the same day and conversations spanning multiple days, without duplicating previously captured material.
---

# Task Manager Notes

Capture Steven's work for his PA to incorporate into the task tracker, daily log, and workstream records. Treat the inbox folder as append-only, not as a transcript archive.

## Load the policy

Read `/Users/sdesalas/taskmanager/inbox/README.md` completely before asking confirmation questions or writing a note. Follow its content, template, and writing rules. If it is unavailable, stop and tell Steven; do not invent a replacement format.

## Determine coverage

1. Review the current conversation and identify substantive work by Steven or work he explicitly directed. Exclude assistant housekeeping, exploratory dead ends with no meaningful finding, and work already captured before the latest checkpoint.
2. Search backward in the conversation for the latest assistant response containing both:
   - `Inbox note saved:`, `Inbox note updated:`, or the legacy `Incoming note saved:` / `Incoming note updated:`
   - `Taskmanager-notes checkpoint: <token>`
3. If a checkpoint exists, treat that assistant response as the coverage boundary. Capture only substantive developments after it. Reuse the conversation key and inspect the referenced note plus any later note carrying that key.
4. If the visible conversation has been compacted and the prior checkpoint response is unavailable, inspect recent files in `inbox/` for matching topics, people, IDs, links, and `taskmanager-notes` metadata. Reuse a candidate only when the match is unambiguous. Ask Steven which note to continue when two candidates are plausible.
5. If there is no earlier checkpoint, cover the complete visible conversation. Read relevant existing inbox notes before writing and omit information already recorded elsewhere.
6. If nothing substantive is new, do not write a file and do not create a checkpoint. Say that the inbox notes are already current.

Do not use a checkpoint as evidence that facts are true. It only identifies the prior coverage boundary.

## Assign work to dates and files

- Use Europe/Madrid local dates and times. Obtain the current date and time from the environment or system; do not guess.
- Assign each development to the date when the work or conversation occurred, not the file-generation date.
- When dates are visible in conversation context, split newly covered work across those dates.
- When this is the first run after a conversation spanning several days and the message-date boundaries are unavailable, ask Steven which dates the work belongs to before writing.
- On the first run for a conversation-day, create `YYYY-MM-DD-short-description.md` using a concise kebab-case topic slug.
- On another run for the same conversation and local date, append to that same file. Do not create a duplicate file merely because the skill was invoked again.
- When the conversation continues on a later local date, create a new dated file for that day's newly covered work. Reuse the same conversation key so the relationship remains discoverable.
- If newly covered material is unrelated to the existing same-day note, create a separate descriptive file rather than forcing unrelated work together.

## Confirm the story

Follow the confirmation process in the inbox README before writing:

1. Inventory every distinct newly covered task in a compact numbered list.
2. Ask about one task at a time, confirming its main **why** and concrete **outcome**. Offer short likely interpretations. Steven may answer several tasks at once; accept that without repeating questions.
3. If Steven already stated both points unambiguously, reflect the proposed why and outcome and ask for a quick confirmation rather than reopening the question.
4. Carry forward an earlier confirmed why or outcome only when the new material does not change it. Ask again when the status, evidence, motivation, ownership, or next step has materially changed.
5. Do not write until every newly covered task has sufficient confirmation. Mark facts Steven cannot resolve as explicitly unknown rather than inferring certainty.

## Write append-only notes

For a new file, use the README template and make every task section self-contained.

For a repeated run against an existing file:

- Preserve every existing line exactly.
- Append a new `## Task: <name> — update at HH:MM` section for each task with genuinely new information.
- Include the confirmed why, what newly happened, the updated outcome, next owner/action, and links. Refer briefly to earlier content instead of repeating it.
- Never silently revise an older outcome. Record the later state as an appended update.
- Avoid appending a section whose only content is that nothing changed.

Do not modify `tasks.md`, `log/`, `workstreams/`, or generated UI files as part of this skill. The inbox note is the handoff to the PA that performs those updates.

## Record a checkpoint

After all note content for this run has been written successfully:

1. Generate a conversation key on the first run in the form `inbox-YYYYMMDD-HHMMSS-<slug>` and reuse it on later runs in this conversation. Preserve an existing legacy `incoming-...` key when continuing an older note.
2. Generate a unique checkpoint token in the form `<conversation-key>-cp-YYYYMMDD-HHMMSS`.
3. Append this HTML comment to every file changed by the run:

```md
<!-- taskmanager-notes
conversation-key: inbox-YYYYMMDD-HHMMSS-short-slug
checkpoint: inbox-YYYYMMDD-HHMMSS-short-slug-cp-YYYYMMDD-HHMMSS
covered-through: short, non-sensitive opening phrase from Steven's last covered message
-->
```

Keep the marker at the end of the appended batch. Never put secrets or sensitive personal data in `covered-through`. The checkpoint token, not the phrase, is the primary identifier.

## Report completion

Finish with all changed paths and the exact checkpoint token so a later invocation can find the boundary:

```text
Inbox note saved: /absolute/path/to/note.md
Taskmanager-notes checkpoint: <token>
```

Use `Inbox note updated:` when appending to an existing file. If one run changes several dated files, list each path and state whether it was saved or updated, followed by the single shared checkpoint token.
