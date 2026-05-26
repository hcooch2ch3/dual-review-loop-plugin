# dual-review-loop

Claude Code plugin. Auto-iterate work under `dual-review` verification, auto-apply high-confidence findings, atomic-commit. Two modes:

- **plan mode** (`/dual-review-loop:dual-review-loop`) — iterate a plan file's `- [ ]` checkbox tasks.
- **task mode** (`/dual-review-loop:dual-review-task`) — iterate a free-form inline task; you decompose one sub-step per iteration.

Companion to [dual-review](https://github.com/hcooch2ch3/dual-review).

> ⚠️ Currently requires Korean-language `dual-review` output (the stop hook detects Accept/Reject sections by Korean headings). English support is not yet implemented — see Prerequisites.

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- `jq`, `git` on PATH
- [`dual-review`](https://github.com/hcooch2ch3/dual-review) skill installed at `~/.claude/skills/dual-review/`
- At least one reviewer backend that `dual-review` can dispatch:
  - `superpowers:code-reviewer` + `codex:adversarial-review` (preferred), or
  - `oh-my-claudecode:critic` (fallback)
- **Korean-language `dual-review` output.** The stop hook detects Accept/Reject sections by their Korean headings (`## ✅ Accept — 양쪽 독립 합치` etc.). If you fork `dual-review` to emit English, you must also update the corresponding `grep`/`awk` patterns in `hooks/stop-hook.sh`.

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

Cancel preserves the task log (post-mortem artifact). Add `.claude/dual-review-loop/` to `.gitignore` to keep logs out of git history.

## Known issues

- **Plan mode blocks commits mid-loop** — if Claude Code's plan mode is active when the loop tries to commit, iteration freezes (inflight marker never cleared). Recovery: exit plan mode, manually `git commit`, then `rm .claude/dual-review-loop.inflight`. Hook resumes on next stop.
- **Forward-fix only** — never `git revert` automatically. Wrong commit must be fixed forward.
- **One concurrent loop per project** — state file existence gate.

## Architecture (quick reference)

- `hooks/stop-hook.sh` — gates the loop on Claude Code stop event. Fail-open invariant. Schema v1 (plan-only legacy) and v2 (mode + cumulative gates) both accepted.
- `commands/dual-review-loop.md` — `/dual-review-loop:dual-review-loop <plan>` (plan mode)
- `commands/dual-review-task.md` — `/dual-review-loop:dual-review-task "<task>"` (task mode)
- `commands/cancel-loop.md` — `/dual-review-loop:cancel-loop` (mode-agnostic)
- State: `.claude/dual-review-loop.state.json` (project-local JSON, atomic temp+mv). Single file across both modes; `mode` field discriminates.
- Task log: `.claude/dual-review-loop/task-<session_id>.log.md` (task mode only; preserved across cancel for post-mortem)
- In-flight marker: `.claude/dual-review-loop.inflight` (Claude deletes after commit)
- Lock: `.claude/dual-review-loop.lock` (mkdir-atomic)
- Logs: `.claude/dual-review-loop.log`

Patterns adapted from [`anthropics/claude-code` `ralph-wiggum` plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) (minimal self-referential loop) and [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) (fail-open ERR trap, project-local state).

## License

MIT — see [LICENSE](./LICENSE).
