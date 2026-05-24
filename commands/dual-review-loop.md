---
description: Start an auto-iteration loop that processes a plan's checkbox tasks with dual-review as verifier
argument-hint: "<plan-path> [--max-iters N]"
---

# /dual-review-loop

Start the dual-review-loop. Each iteration:
1. Pick next unfinished `- [ ]` task from the plan
2. Execute it
3. Run `dual-review` (programmatic mode)
4. Auto-apply Accept (≥ Important) findings
5. Stop on Open Questions OR atomic-commit + flip checkbox + advance

## Implementation Steps

When the user invokes this command:

### 1. Parse arguments

Required: `<plan-path>` — absolute path to a markdown file with `- [ ]` checkbox tasks.
Optional: `--max-iters N` (default: 20).

If `<plan-path>` is relative or not provided: prompt user once via AskUserQuestion for the absolute path. Reject `~/...` — require fully expanded path (or expand it server-side).

### 2. Pre-flight checks

- File at `<plan-path>` exists.
- Plan contains at least one `^([-*+]|[0-9]+\. ) \[ \]` line.
- `<cwd>/.claude/dual-review-loop.state.json` does NOT already exist (refuse to start a second concurrent loop in the same project).
- `dual-review` skill is installed at `~/.claude/skills/dual-review/SKILL.md` (warn if missing — caller should install first).
- `jq` is on PATH (required by the stop hook).

### 3. Create state file (atomic write)

```json
{
  "schema": "v1",
  "active": true,
  "plan_path": "<absolute plan path>",
  "iteration": 0,
  "max_iterations": <max_iters>,
  "session_id": "<from current Claude Code session>",
  "pid": <current claude process pid>,
  "started_at_epoch": <now>,
  "last_iter_at_epoch": <now>,
  "last_brief_path": ""
}
```

Path: `<cwd>/.claude/dual-review-loop.state.json` (create `.claude/` dir if missing).
Write via temp + mv for atomicity.

Add `.claude/dual-review-loop.*` to `.gitignore` if missing (don't commit state/log/lock files).

### 4. Emit start brief

```
🔄 dual-review-loop started
  plan: <plan-path>
  unfinished tasks: <count>
  max iterations: <N>
  session: <session_id>
  state file: .claude/dual-review-loop.state.json

  Cancel anytime: /dual-review-loop:cancel
  Or: rm .claude/dual-review-loop.state.json
```

### 5. Start the first iteration

Immediately proceed to execute the first unfinished task per the workflow:
- pick first `- [ ]`
- execute
- invoke dual-review programmatically (caller=dual-review-loop, mode=programmatic, execution_mode=wait, scope.type=working-tree, meta_review=false)
- read brief, save to `.claude/reviews/iter-001.md`
- apply per policy (auto-apply Tier 1 + Tier 2 ≥ Important; skip Minor; STOP on Open Questions)
- (hook owns state.last_brief_path — do not edit state file from inside the iter)
- re-verify (run task tests/verify cmd if any)
- flip checkbox `- [ ]` → `- [x]` for completed task
- atomic commit (code + plan + deferred-minor footer)
- STOP (the stop hook will re-trigger with the next iter brief, or terminate)

### 6. Constraints

- This is the apply/commit side. `dual-review` SKILL remains review-only.
- Never `git revert` automatically — escalate.
- Never `--no-verify` or force push.
- Korean commit message body per project convention.
- Skip the iteration if Execute produces no changes (no-op task); flip checkbox manually and advance via state update + plan edit.

## Anti-patterns

- Batching multiple tasks in one iteration → defeats per-task review
- Auto-applying Minor items → scope drift
- Continuing past Open Questions silently
- Mixing English/Korean in commit messages

## See also

- `/dual-review-loop:cancel` — stop the loop
- `~/.claude/skills/dual-review/SKILL.md` — the verifier
