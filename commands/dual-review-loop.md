---
description: Start an auto-iteration loop that processes a plan's checkbox tasks with dual-review as verifier
argument-hint: "<plan-path> [--max-iters N] [--max-minutes M]"
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

Optional budget flags (both enforced by the stop hook):
- `--max-iters N` (default: 20) — hard cap on iterations
- `--max-minutes M` (default: 30) — wall-clock cap since loop start; hook stops when `(now - started_at) ≥ M`

If user passes unrecognized flags, surface them in the start brief (Section 4) as `Unrecognized flags ignored: <list>` and continue. For other SKILL inputs (`max_reviews`, `max_files`, `max_loc`, `apply_threshold`, etc.) see the dual-review-loop SKILL inputs table; not exposed as flags by default (and not hook-enforced).

If `<plan-path>` is relative or not provided: prompt user once via AskUserQuestion for the absolute path. Reject `~/...` — require fully expanded path (or expand it server-side).

### 2. Pre-flight checks

- File at `<plan-path>` exists.
- Plan contains at least one `^([-*+]|[0-9]+\. ) \[ \]` line.
- `<cwd>/.claude/dual-review-loop.state.json` does NOT already exist (refuse to start a second concurrent loop in the same project). This check is mode-agnostic: if a `task`-mode loop is in progress, this plan-mode invocation refuses (and vice versa via `/dual-review-loop:dual-review-task`).
- `dual-review` skill is installed at `~/.claude/skills/dual-review/SKILL.md` (warn if missing — caller should install first).
- `jq` is on PATH (required by the stop hook).

### 3. Create state file (atomic write)

```json
{
  "schema": "v2",
  "mode": "plan",
  "active": true,
  "plan_path": "<absolute plan path>",
  "iteration": 0,
  "max_iterations": <max_iters>,
  "max_minutes": <max_minutes>,
  "max_files": 999999,
  "max_loc": 999999,
  "max_reviews": 999999,
  "cum_files_changed": 0,
  "cum_loc_changed": 0,
  "cum_reviews": 0,
  "consecutive_same_failure": 0,
  "session_id": "<from current Claude Code session>",
  "pid": <current claude process pid>,
  "started_at_epoch": <now>,
  "last_iter_at_epoch": <now>,
  "last_brief_path": ""
}
```

Schema v2 (was v1) adds `mode` (`"plan"` here, `"task"` for `/dual-review-loop:dual-review-task`) and cumulative gate fields (`max_*` / `cum_*` / `consecutive_same_failure`). Defaults above (999999 / 0) keep plan-mode behaviour identical to v1 — the cumulative caps only fire if a caller explicitly lowers them.

Both `max_iterations` and `max_minutes` are enforced by the stop hook (Gates 10 and 10b). Cumulative caps are Gates 10c–f. The hook also enforces a hard 24h idle timeout independently.

Path: `<cwd>/.claude/dual-review-loop.state.json` (create `.claude/` dir if missing).
Write via temp + mv for atomicity.

Add `.claude/dual-review-loop.*` to `.gitignore` if missing (don't commit state/log/lock files).

### 4. Emit start brief

```
🔄 dual-review-loop started (plan mode)
  plan: <plan-path>
  unfinished tasks: <count>
  max iterations: <N>
  max minutes: <M> (wall-clock; hook stops at elapsed ≥ M*60s)
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
