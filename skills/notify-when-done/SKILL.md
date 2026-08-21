---
name: notify-when-done
description: Speak an out-loud notification via macOS `say` + `afplay` when the current task finishes. Use when the user asks to be notified, told, pinged, or alerted when the task/build/run is done, or says things like "let me know when this is finished", "notify me when done", or "tell me when it's ready".
---

# Notify When Done

Announce out loud that the current task has finished by running this skill's `scripts/notify.sh`. It renders speech with `say` and plays it quietly with `afplay` (modern voices ignore `say`'s inline volume markup).

## When this skill triggers

The user asks to be notified when the current task completes, e.g.:
- "notify me when the task is finished"
- "let me know when this is done"
- "tell me / ping me when the build is ready"

## Must run outside the sandbox

**Playback produces no sound inside the sandbox.** Always run the script with full permissions (outside the sandbox). A real, audible run takes a few seconds; an instant return means it was blocked.

**Allowlisting the script avoids the approval prompt.** The script is one command, so `say` / `afplay` inside it inherit that environment — you do not allowlist those binaries, and you must not chain or wrap the script (`bash …`, `~`, `$HOME` all miss the prefix match). Without the allowlist, the full-permissions escalation gets flagged by auto-review; surface the prompt rather than silently giving up.

## One-time setup

Allowlist the script path (prefix match on the command as typed):

**Claude Code** — in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(/Users/sdesalas/.claude/skills/notify-when-done/scripts/notify.sh *)"]
  }
}
```

**Cursor** — in `~/.cursor/permissions.json`:

```json
{
  "terminalAllowlist": ["/Users/sdesalas/.claude/skills/notify-when-done/scripts/notify.sh"]
}
```

## How to notify

Run this as the last step, once the task is actually complete. Use the absolute path — no `~`, no `$HOME`, no `bash` wrapper:

```bash
/Users/sdesalas/.claude/skills/notify-when-done/scripts/notify.sh "Your task is finished."
```

- **Default voice is `Rishi`.** Override only if the user asks: `-v Daniel`.
- **Default volume is `0.10`.** Do not play through `say` yourself.
- Keep the spoken message short and specific — say *what* finished.
- If the task failed, say so plainly: `"The task failed. Please check the output."`

## Include the location (directory + branch)

Always mention *where* the finished work lives (directory name and/or git branch). Inline it as a literal string — no shell expansion:

```bash
/Users/sdesalas/.claude/skills/notify-when-done/scripts/notify.sh "Your PR review task on bulk import create is ready on kibana-6th."
```

Phrase it naturally, describing the task and ending with the location:
- "Your PR review task on bulk import create is ready on kibana-6th."
- "I have finished the error handling for change tracking on alerting framework, check out kibana-main."

## Choosing a different voice

Only override the default if the user asks. List installed voices with `say -v '?'`. Handy English options: Rishi (Indian, default), Daniel (British), Karen (Australian), Moira (Irish), Tessa (South African), Samantha (US).

## Notes

- Fire the notification only when the work is genuinely done, not before.
- Do the actual task first; the notify call is the final step, not a substitute for finishing.
