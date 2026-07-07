---
name: notify-when-done
description: Speak an out-loud notification via the macOS `say` command when the current task finishes. Use when the user asks to be notified, told, pinged, or alerted when the task/build/run is done, or says things like "let me know when this is finished", "notify me when done", or "tell me when it's ready".
---

# Notify When Done

Announce out loud, using the macOS `say` command, that the current task has finished.

## When this skill triggers

The user asks to be notified when the current task completes, e.g.:
- "notify me when the task is finished"
- "let me know when this is done"
- "tell me / ping me when the build is ready"

## Must run outside the sandbox

**`say` produces no sound inside the sandbox.** The default sandbox has no audio device access, so the command exits 0 almost instantly and you get silence — it *looks* like it worked but nothing plays. Always run it with full permissions (outside the sandbox) so the audio actually reaches the speakers. A real, audible run takes a few seconds; an instant return is the tell-tale sign it was blocked.

**The allowlist avoids the approval prompt.** With `say` on the terminal allowlist (see setup below), it auto-runs outside the sandbox — no approval card. Without it, the full-permissions escalation gets flagged by auto-review as an unnecessary side effect and needs manual approval each time; in that case, surface the prompt rather than silently giving up, and only re-request when the user actually asked to be notified.

## One-time setup

Allowlist `say` so it runs without prompting. Set this up for whichever agent you use:

**Claude Code** — in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(say:*)"]
  }
}
```

**Cursor** — in `~/.cursor/permissions.json`:

```json
{
  "terminalAllowlist": ["say"]
}
```

Both are prefix matches, so they cover `say -v Rishi "..."`. This only works if the `say` call is standalone — a chained command no longer starts with `say` and won't match.

## How to notify

Run `say` as the last step, once the task is actually complete, with full permissions:

```bash
say -v Rishi "Your task is finished."
```

- **Default voice is `Rishi`** (Indian English) — it's the clearest.
- Keep the spoken message short and specific — say *what* finished, e.g. `say -v Rishi "The Kibana build has finished."`
- If the task failed, say so plainly: `say -v Rishi "The task failed. Please check the output."`

## Include the location (directory + branch)

Always mention *where* the finished work lives so it's clear which checkout/worktree it's in. Include the current directory name and/or git branch.

Inline the location directly as a literal string — you already know the directory and branch from context, so no shell expansion is needed. Keep the `say` call plain so it stays under the `Bash(say *)` allowlist:

```bash
say -v Rishi "Your PR review task on bulk import create is ready on kibana-6th."
```

Phrase it naturally, describing the task and ending with the location:
- "Your PR review task on bulk import create is ready on kibana-6th."
- "I have finished the error handling for change tracking on alerting framework, check out kibana-main."

## Choosing a different voice

Only override the default if the user asks for a specific accent/voice. List installed voices with `say -v '?'`. Handy English options:

| Voice | Accent |
|-------|--------|
| Rishi | Indian (default) |
| Daniel | British |
| Karen | Australian |
| Moira | Irish |
| Tessa | South African |
| Samantha | US |

## Notes

- Fire the notification only when the work is genuinely done, not before.
- Do the actual task first; the `say` call is the final step, not a substitute for finishing.
