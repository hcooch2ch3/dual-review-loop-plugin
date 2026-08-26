# dual-review-loop

Claude Code plugin. Auto-iterate work under `dual-review` verification, auto-apply high-confidence findings, atomic-commit. Two modes:

- **plan mode** (`/dual-review-loop:dual-review-loop`) — iterate a plan file's `- [ ]` checkbox tasks.
- **task mode** (`/dual-review-loop:dual-review-task`) — iterate a free-form inline task; you decompose one sub-step per iteration.

Companion to [dual-review](https://github.com/hcooch2ch3/dual-review).

> ⚠️ Currently requires Korean-language `dual-review` output. The injected iteration prompt instructs the LLM to apply Accept findings using Korean headings (`## ✅ Accept — 양쪽 독립 합치` etc.); English support is not yet implemented — see Prerequisites.

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- `jq`, `git` on PATH
- [`dual-review`](https://github.com/hcooch2ch3/dual-review) skill installed at `~/.claude/skills/dual-review/`
- At least one reviewer backend that `dual-review` can dispatch:
  - `superpowers:code-reviewer` + `codex:adversarial-review` (preferred), or
  - `oh-my-claudecode:critic` (fallback)
- **Korean-language `dual-review` output.** The injected iteration prompt names Accept buckets by their Korean headings (`## ✅ Accept — 양쪽 독립 합치`, `## ✅ Accept — 단일 리뷰어, 기술적으로 타당`, `## Open Questions`). The hook itself only parses `## Open Questions` (English heading) for the early-stop gate; the rest live inside the prompt body. If you fork `dual-review` to emit English Accept headings, update the prompt strings in `commands/dual-review-loop.md` and `commands/dual-review-task.md` accordingly.

## Install

Inside Claude Code:

```
/plugin marketplace add hcooch2ch3/dual-review-loop-plugin
/plugin install dual-review-loop@dual-review-loop-plugin
```

If `/plugin install` reports `"source type your Claude Code version does not support"`, fall back to the CLI form (same operation, different code path):

```bash
claude plugin marketplace add hcooch2ch3/dual-review-loop-plugin
claude plugin install dual-review-loop@dual-review-loop-plugin
```

For local development, clone the repo and add the local path as a marketplace instead:

```
/plugin marketplace add /absolute/path/to/dual-review-loop-plugin
```

See the [Claude Code plugin docs](https://docs.claude.com/en/docs/claude-code/plugins) for details.

## Use

Plan mode — iterate `- [ ]` checkboxes in a plan file:
```
/dual-review-loop:dual-review-loop /abs/path/plan.md [--max-iters N] [--max-minutes M]
```

Task mode — iterate a free-form task description (no plan file):
```
/dual-review-loop:dual-review-task "<task description>" [--max-iters N] [--max-minutes M] [--max-files N] [--max-loc N] [--max-reviews N]
```

Cancel either mode:
```
/dual-review-loop:cancel-loop
```

Defaults: `--max-iters 20`, `--max-minutes 30`. Both hook-enforced (Gates 10, 10b). `--max-minutes 0` disables wall-clock cap (24h idle gate still applies). Task mode also enforces cumulative caps: `--max-files 30`, `--max-loc 1500`, `--max-reviews 15` (Gates 10c–f). Plan mode defaults these to "Infinity" so they don't fire unless explicitly lowered.

Cancel manually: `rm .claude/dual-review-loop.state.json` in project root.

### Which mode?

| | plan | task |
|---|---|---|
| Input | plan file with `- [ ]` checkboxes | inline `"<task description>"` |
| Iteration unit | one checkbox at a time, executed in order | one sub-step you decide each iter |
| State of progress | checkbox flip on the plan file | append-only iteration log at `.claude/dual-review-loop/task-<session>.log.md` |
| Use when | requirements are pre-decomposed into steps | task is one paragraph; LLM should figure out the decomposition |

Cancel preserves the task log (post-mortem artifact). Add `.claude/dual-review-loop.*`
(state/log/lock), `.claude/dual-review-loop/` (task logs) and `.claude/reviews/`
(iteration briefs) to `.gitignore` — all three, since none of the patterns matches
the others. Beyond keeping them out of git history this is load-bearing: Gate 9
will not declare `all tasks complete` while the working tree is dirty, and
untracked plugin artifacts are enough to keep it dirty forever.

## Known issues

- **Plan mode can pause a commit (auto-recovers)** — if Claude Code's plan mode is active when the loop tries to commit, the iteration can't commit and the hook soft-pauses (it shows a `systemMessage`, no longer a silent freeze). The hook now detects completion from git ground truth: it records `HEAD` at inject time (`inflight_base_sha`) and auto-resumes the moment a commit lands past it — Claude's own or a manual one. Recovery is just "exit plan mode and let the iteration commit"; the old manual `rm .claude/dual-review-loop.inflight` step is no longer required (it stays valid as a fallback). Caveat: completion is detected by *forward HEAD motion*, not by inspecting the commit — see "consumed iteration" below.
- **An unrelated commit during a pause can consume one iteration** — because completion is detected by `HEAD` moving forward past `inflight_base_sha` (verified with `git merge-base --is-ancestor`), a commit that lands while an iteration is soft-paused — an external formatter, manual commit, unrelated automation — clears the in-flight marker and advances the counter. This is **not** data loss: in plan mode the checkbox was never flipped so the same task is re-picked next iter; in task mode it costs one `max_iterations` slot. The hook deliberately does **not** verify commit contents (a sentinel/trailer check would re-introduce the LLM-trust the hook is designed to avoid). Edge: if `inflight_base_sha` is absent (legacy v1 state, non-git repo, or a loop upgraded mid-flight) the git backstop is disarmed and the hook soft-pauses with a message saying manual `rm` is still required.
- **Forward-fix only** — never `git revert` automatically. Wrong commit must be fixed forward.
- **One concurrent loop per project** — state file existence gate. Mode-agnostic: a task-mode loop refuses plan-mode start and vice versa.
- **Downgrading the plugin mid-loop** — schema v2 state (mode/cumulative fields, task mode) is rejected by pre-task-mode v1 hooks (older releases), which fail-open and delete the state file. Current v2 hook does the opposite on an unknown schema (e.g., a future v3 state seen by a v2 hook): `soft_pause` with a `systemMessage` telling you to upgrade the hook or run `/dual-review-loop:cancel-loop`. If you must downgrade to a pre-v2 hook while a loop is running: cancel first, or accept the loss. Forward upgrades (v1 state running, hook upgraded to v2) are safe — the new hook defaults `mode=plan` and treats absent cumulative fields as Infinity.

### Recovery: loop is paused, hook isn't advancing

The hook `soft_pause`s (state preserved, no inject) in several scenarios. The Claude Code UI shows a `systemMessage` for the recoverable ones. Common cases:

- **"baseline commit `<sha>` was lost (rebase/squash/gc)"** — your `started_at_sha` was orphaned by a rebase or `git gc`. Cumulative caps (`max_files` / `max_loc`) can't be enforced. To resume: edit `.started_at_sha` in `.claude/dual-review-loop.state.json` to current `HEAD` (jq + temp+mv) and the next stop fire continues. Or run `/dual-review-loop:cancel-loop` to abandon the run. (The "do not edit state" rule applies to hook-owned counter fields, not this recovery edit; `started_at_sha` is command-owned.)
- **"state schema `<x>` unknown"** — see the downgrade note above. Install a hook that supports the schema, or cancel.
- **Manual deletion of `.claude/reviews/iter-*.md` mid-run** — the `max_reviews` gate uses a hook-tracked baseline. Deleting briefs causes a "reviews_baseline re-init" log entry on the next fire (baseline drops to the new count); the cap stays meaningful. No user action needed, just be aware that manually rm'd briefs reset the budget window.
- **"iter `<N>` has not committed yet" / "completion can't be auto-detected"** — the previous iteration's in-flight marker is still present and no commit has landed since it was injected. If a commit *did* land but the loop didn't advance, the baseline SHA was probably missing (legacy/non-git state) — `rm .claude/dual-review-loop.inflight` to resume. Otherwise exit plan mode and let the iteration commit (it auto-resumes), or `/dual-review-loop:cancel-loop`.
- **Lock contention / different session / no-continuation signal** — these silent pauses are expected (concurrent hook fires auto-recover; second-session resume is intentional; user takeover stops the loop). If a loop seems stuck without a `systemMessage`, check `.claude/dual-review-loop.log` for the last `SOFT-PAUSE:` line.

## Architecture (quick reference)

- `hooks/stop-hook.sh` — gates the loop on Claude Code stop event. Fail-open invariant. Schema v1 (plan-only legacy) and v2 (mode + cumulative gates) both accepted.
- `commands/dual-review-loop.md` — `/dual-review-loop:dual-review-loop <plan>` (plan mode)
- `commands/dual-review-task.md` — `/dual-review-loop:dual-review-task "<task>"` (task mode)
- `commands/cancel-loop.md` — `/dual-review-loop:cancel-loop` (mode-agnostic)
- State: `.claude/dual-review-loop.state.json` (project-local JSON, atomic temp+mv). Single file across both modes; `mode` field discriminates.
- Task log: `.claude/dual-review-loop/task-<session_id>.log.md` (task mode only; preserved across cancel for post-mortem)
- In-flight marker: `.claude/dual-review-loop.inflight` (Claude deletes after commit; the hook also auto-clears it once it detects the iter's commit landed via git — see Known issues)
- Lock: `.claude/dual-review-loop.lock` (mkdir-atomic)
- Logs: `.claude/dual-review-loop.log`

Patterns adapted from [`anthropics/claude-code` `ralph-wiggum` plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) (minimal self-referential loop) and [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) (fail-open ERR trap, project-local state).

## License

MIT — see [LICENSE](./LICENSE).
