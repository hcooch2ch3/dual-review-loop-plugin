---
description: Cancel the active dual-review-loop in the current project (immediate stop on next hook fire)
---

# /dual-review-loop:cancel

Stop the dual-review-loop running in the current project.

## Implementation

When invoked:

1. Check if `<cwd>/.claude/dual-review-loop.state.json` exists.
2. If yes: delete it + `dual-review-loop.lock` (if present).
3. Log to `.claude/dual-review-loop.log`: `cancelled by user at <timestamp>`.
4. Emit:
   ```
   ✓ dual-review-loop cancelled
     iter <N> was in progress.
     last brief: <last_brief_path>
   ```
5. If no state file: emit "no active loop in this project" and exit.

Cancel takes effect at the next Stop hook fire (the very next time the current Claude session attempts to stop). To make it immediate: nothing further needed — the agent will exit on its current turn.

## Notes

- Does NOT undo any commits made by previous iterations (forward-fix only constitution).
- Does NOT affect other projects' loops (state file is project-local).
- If hook still misfires after cancel: state file removal is the canonical defense; remove `.claude/dual-review-loop.state.json` manually if needed.
