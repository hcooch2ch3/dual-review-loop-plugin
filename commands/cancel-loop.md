---
description: Cancel the active dual-review-loop (plan or task mode) in the current project; immediate stop on next hook fire
---

# /dual-review-loop:cancel-loop

Stop the dual-review-loop running in the current project. Works for both
plan mode (`/dual-review-loop:dual-review-loop`) and task mode
(`/dual-review-loop:dual-review-task`).

## Implementation

When invoked:

1. Check if `<cwd>/.claude/dual-review-loop.state.json` exists.
2. If yes:
   - Read `mode` (defaults to `"plan"` when absent — v1 state) and
     `task_log_path` for the brief output.
   - Delete the state file (`rm .claude/dual-review-loop.state.json`) +
     the lock **directory** (`rmdir .claude/dual-review-loop.lock` — it
     is created with `mkdir` for atomicity, so `rm` would fail) +
     the in-flight marker file (`rm .claude/dual-review-loop.inflight`).
     All three are best-effort; ignore "not present" errors.
   - **Do NOT delete the task log** (`.claude/dual-review-loop/task-*.log.md`)
     — it is the post-mortem artifact. Mention its path in the brief so
     the user can read it.
3. Log to `.claude/dual-review-loop.log`: `cancelled (<mode> mode) by user at <timestamp>`.
4. Emit:
   ```
   ✓ dual-review-loop cancelled (<mode> mode)
     iter <N> was in progress.
     last brief: <last_brief_path>
     task log preserved at: <task_log_path>      # task mode only
   ```
5. If no state file: emit "no active loop in this project" and exit.

Cancel takes effect at the next Stop hook fire (the very next time the
current Claude session attempts to stop). To make it immediate: nothing
further needed — the agent will exit on its current turn.

## Notes

- Does NOT undo any commits made by previous iterations (forward-fix only constitution).
- Does NOT affect other projects' loops (state file is project-local).
- Mode-agnostic: works on v1 (legacy plan-only) and v2 (plan or task) state files.
- Task log preserved on purpose — if accumulated logs become noise, remove
  `.claude/dual-review-loop/` manually (or add it to `.gitignore`).
- If hook still misfires after cancel: state file removal is the canonical
  defense; remove `.claude/dual-review-loop.state.json` manually if needed.
