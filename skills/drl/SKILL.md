---
name: drl
description: Start an auto-iteration loop that processes a plan's checkbox tasks with dual-review as verifier
argument-hint: "<plan-path> [--max-iters N] [--max-minutes M]"
disable-model-invocation: true
---

# /drl

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
- `--max-minutes M` (default: 0 = disabled) — optional wall-clock cap since loop
  start; hook stops when `(now - started_at) ≥ M`. Off by default because it
  measures elapsed time, not work done: the clock keeps running while the loop
  is paused waiting for you, and firing it DELETES loop state rather than
  pausing. `--max-iters` is the cap that binds.

If user passes unrecognized flags, surface them in the start brief (Section 4) as `Unrecognized flags ignored: <list>` and continue. For other SKILL inputs (`max_reviews`, `max_files`, `max_loc`, `apply_threshold`, etc.) see the dual-review-loop SKILL inputs table; not exposed as flags by default (and not hook-enforced).

If `<plan-path>` is relative or not provided: prompt user once via AskUserQuestion for the absolute path. Reject `~/...` — require fully expanded path (or expand it server-side).

### 2. Pre-flight checks

- File at `<plan-path>` exists.
- Plan contains at least one `^([-*+]|[0-9]+\. ) \[ \]` line.
- `<cwd>/.claude/dual-review-loop.state.json` does NOT already exist (refuse to start a second concurrent loop in the same project). This check is mode-agnostic: if a `task`-mode loop is in progress, this plan-mode invocation refuses (and vice versa via `/drl-task`).
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
  "session_id": "<from current Claude Code session>",
  "started_at_epoch": <now>,
  "started_at_sha": "<git rev-parse HEAD of the project repo (or empty if not a git repo)>",
  "last_iter_at_epoch": <now>,
  "last_brief_path": ""
}
```

`inflight_base_sha` and `reviews_baseline` are hook-owned: the hook writes them
into the state file on its own fires, and a hand-written value corrupts the
in-flight backstop and the review-budget baseline respectively — so never seed
them here. The one field that must be correct is `session_id`; the hook
fail-opens on an empty one and soft-pauses the loop when it does not match the
session the Stop hook fired in.

Schema v2 (was v1) adds `mode` (`"plan"` here, `"task"` for `/drl-task`), cumulative gate fields (`max_*`), and `started_at_sha` (used by the hook as a git diff baseline to compute changed-files/LOC counters automatically — no LLM trust). Defaults above (999999) keep plan-mode behaviour identical to v1; the cumulative caps only fire if a caller explicitly lowers them.

`max_iterations` and `max_minutes` are enforced by the stop hook (Gates 10/10b).
`max_iterations` is the binding cap; `max_minutes` defaults to 0 (disabled). Cumulative caps (Gates 10c–e) are enforced by the hook computing `git diff --shortstat <started_at_sha> HEAD` and counting `.claude/reviews/iter-*.md` files — these gates are hook-owned, not command-owned. The hook also enforces a hard 24h idle timeout — except that an in-flight marker
defers collection to 48h, so a loop that stopped mid-iteration can survive up to
48h before it is reaped.

Path: `<cwd>/.claude/dual-review-loop.state.json` (create `.claude/` dir if missing).
Write via temp + mv for atomicity.

Add all three patterns to `.gitignore` if missing — `.claude/dual-review-loop.*`
(state/log/lock), `.claude/dual-review-loop/` (task logs) and `.claude/reviews/`
(iteration briefs). They are three distinct paths: the first does not match the
second (no dot after `loop`) and neither matches the third. Any of them left
untracked keeps the working tree dirty, and Gate 9 refuses to declare
`all tasks complete` over a dirty tree — so a repo missing these never finishes.

### 4. Emit start brief

```
🔄 dual-review-loop started (plan mode)
  plan: <plan-path>
  unfinished tasks: <count>
  max iterations: <N>
  max minutes: <M> (wall-clock; hook stops at elapsed ≥ M*60s)
  session: <session_id>
  state file: .claude/dual-review-loop.state.json

  Cancel anytime: /drl-cancel
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

- `/drl-task` — free-form inline task sibling (no plan file)
- `/drl-cancel` — stop the loop
- `~/.claude/skills/dual-review/SKILL.md` — the verifier
