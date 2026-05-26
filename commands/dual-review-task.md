---
description: Start an auto-iteration loop that processes a free-form task with dual-review as verifier (no plan file needed)
argument-hint: "\"<task description>\" [--max-iters N] [--max-minutes M] [--max-files N] [--max-loc N] [--max-reviews N]"
---

# /dual-review-loop:dual-review-task

Start the dual-review-loop in **task mode**. Same iteration shape as
`/dual-review-loop:dual-review-loop`, but the unit of work is a free-form
inline task description instead of a plan file's checkboxes. Each iteration:

1. Decompose the task into one next concrete sub-step (you decide)
2. Execute it
3. Run `dual-review` (programmatic mode)
4. Auto-apply Accept (≥ Important) findings
5. Stop on Open Questions / budget cap, otherwise atomic-commit +
   append the sub-step to the task log + advance

## Implementation Steps

When the user invokes this command:

### 1. Parse arguments

Required: `<task description>` — quoted free-form text (1 – 2000 chars).
The character cap is a stop-hook safety: longer descriptions risk polluting
the re-injected prompt and crowding out context for actual work.

Optional budget flags (all enforced by the stop hook):
- `--max-iters N` (default: 20) — hard cap on iterations
- `--max-minutes M` (default: 30) — wall-clock cap since loop start
- `--max-files N` (default: 30) — cumulative changed files cap
- `--max-loc N` (default: 1500) — cumulative changed LOC cap
- `--max-reviews N` (default: 15) — cumulative dual-review invocations cap

If user passes unrecognized flags, surface them in the start brief
(Section 4) as `Unrecognized flags ignored: <list>` and continue.

If `<task description>` is empty or omitted: prompt user once via
AskUserQuestion. Reject descriptions outside `1 ≤ len ≤ 2000`.

### 2. Pre-flight checks

- `<cwd>/.claude/dual-review-loop.state.json` does NOT already exist.
  This check is **mode-agnostic**: if a `plan`-mode loop is in progress in
  the same cwd, this task-mode invocation refuses (and vice versa).
- `dual-review` skill is installed at `~/.claude/skills/dual-review/SKILL.md`
  (warn if missing — caller should install first).
- `jq` is on PATH (required by the stop hook).
- Working tree status snapshot: warn (not refuse) if dirty — user may be
  resuming after a manual interrupt.

### 3. Create state file (atomic write)

```json
{
  "schema": "v2",
  "mode": "task",
  "active": true,
  "task_description": "<inline task text>",
  "task_log_path": ".claude/dual-review-loop/task-<session_id>.log.md",
  "iteration": 0,
  "max_iterations": <max_iters>,
  "max_minutes": <max_minutes>,
  "max_files": <max_files>,
  "max_loc": <max_loc>,
  "max_reviews": <max_reviews>,
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

Path: `<cwd>/.claude/dual-review-loop.state.json` (create `.claude/` if missing).
Write via temp + mv for atomicity.

### 3.1 Initialize the task log

Path: `.claude/dual-review-loop/task-<session_id>.log.md` (session-scoped so
prior cancelled-session logs cannot contaminate this run). `task_log_path`
in state points at this file.

Initial contents (truncate-and-write on start):

```markdown
# dual-review-loop task log

Started: <ISO8601>
Session: <session_id>
Task: <task description>

---
```

Append-only thereafter: one block per iteration with the brief summary
(see §5 step 8).

**Cancel-loop preserves this file** (it is the post-mortem artifact for
"why did this stop?"). Recommend adding `.claude/dual-review-loop/` to
`.gitignore`; print a one-line tip if the path is not ignored.

### 4. Emit start brief

```
🔄 dual-review-loop started (task mode)
  task: <first 80 chars of description>...
  max iterations: <N>
  max minutes: <M> (wall-clock; hook stops at elapsed ≥ M*60s)
  max files: <N>; max loc: <N>; max reviews: <N>
  session: <session_id>
  state file: .claude/dual-review-loop.state.json
  log: .claude/dual-review-loop/task-<session_id>.log.md

  Cancel anytime: /dual-review-loop:cancel-loop
  Or: rm .claude/dual-review-loop.state.json
```

### 5. Start the first iteration

Immediately proceed to execute the first sub-step per the workflow:

1. Decide one next concrete sub-step that advances the task description.
   Bias toward smaller, reviewable units (single file / single concept).
2. Execute it (make code changes, run tests, etc.).
3. Invoke the `dual-review` skill programmatically. Include this block in
   your dispatch prompt:

   ```
   dual-review-invocation:
     mode: programmatic
     execution_mode: wait
     caller: dual-review-loop
     scope:
       type: working-tree
     meta_review: false
   ```

4. Read the dual-review synthesis brief. Save it verbatim to:
   `.claude/reviews/iter-<NNN>.md` (NNN = 3-digit zero-padded iteration).

5. Apply auto-fixes per policy (same as plan mode):
   - Every item under `## ✅ Accept — 양쪽 독립 합치` (Tier 1)
   - Items under `## ✅ Accept — 단일 리뷰어, 기술적으로 타당` with
     Severity ≥ Important
   - Skip Minor items (log to commit footer or task log)
   - If `## Open Questions` non-empty: STOP, report to user. Do NOT continue.

6. Re-verify (re-run task tests / verify command).

7. Append a brief entry to the task log file (§3.1):

   ```markdown
   ## Iteration <N>: <sub-step subject>

   - Sub-step: <one-line description of what you did>
   - Dual-review verdict: Accept(both)=<n> / Accept(single)=<n> / Minor=<n> / Open=<n>
   - Applied: <list>
   - Deferred (Minor): <list>
   - Verify after: <pass | fail summary>
   - Commit: <short SHA> <message line>
   - Files changed (this iter): <n>; LOC delta: +<n>/-<n>; reviews so far: <n>
   - Next: <one-line plan for next iter or "DONE">
   ```

8. Atomic commit: code changes + task log append + deferred-minor footer.
   Korean commit message body per project convention.

9. Update state counters BEFORE the hook re-fires:
   - `cum_files_changed += <files changed this iter>`
   - `cum_loc_changed += <+added + -removed>`
   - `cum_reviews += 1`
   - If verify fingerprint matches previous iter's: `consecutive_same_failure += 1`
     else reset to 0.
   - Write via temp + mv for atomicity.

10. Stop. The hook re-fires for the next iter or terminates naturally
    (budget cap, Open Questions, idle timeout).

### 6. Constraints

- Apply/commit side; `dual-review` SKILL remains review-only.
- Never `git revert` automatically — escalate to user.
- Never `--no-verify` or force-push.
- One atomic commit per iteration. Skip the commit if the iteration
  produced no changes (no-op sub-step); still log the iter to the task log
  with `Result: noop` and advance.

### 7. Stop conditions

The stop hook (`hooks/stop-hook.sh`) gates:
- `iteration ≥ max_iterations` → Gate 10
- wall-clock `≥ max_minutes` → Gate 10b
- `cum_files_changed ≥ max_files` → Gate 10c
- `cum_loc_changed ≥ max_loc` → Gate 10d
- `cum_reviews ≥ max_reviews` → Gate 10e
- `consecutive_same_failure ≥ 2` → Gate 10f
- Open Questions in last brief → Gate 11
- Idle > 24h → Gate 6
- User runs `/dual-review-loop:cancel-loop` or removes state file.

## Anti-patterns

- Bundling multiple sub-steps in one iter → defeats per-iter review.
- Auto-applying Minor items → scope drift.
- Continuing past Open Questions silently.
- Editing `.claude/dual-review-loop.state.json` manually (hook owns it).
- Naming or referring to this loop as "ralph" inside injected prompts —
  the hook (T4) explicitly does not use that token; respect that.

## See also

- `/dual-review-loop:dual-review-loop` — plan-checkbox driven sibling
- `/dual-review-loop:cancel-loop` — stop either mode
- `~/.claude/skills/dual-review/SKILL.md` — the verifier
