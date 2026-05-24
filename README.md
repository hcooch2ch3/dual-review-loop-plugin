# dual-review-loop

Claude Code plugin. Auto-iterate a plan's `- [ ]` checkbox tasks: each iteration runs `dual-review` as verifier, auto-applies high-confidence findings, atomic-commits. Companion to [dual-review](https://github.com/hcooch2ch3/dual-review).

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- `jq`, `git` on PATH
- [`dual-review`](https://github.com/hcooch2ch3/dual-review) skill installed at `~/.claude/skills/dual-review/`
- At least one reviewer backend that `dual-review` can dispatch:
  - `superpowers:code-reviewer` + `codex:adversarial-review` (preferred), or
  - `oh-my-claudecode:critic` (fallback)
- **Korean-language `dual-review` output.** The stop hook detects Accept/Reject sections by their Korean headings (`## ✅ Accept — 양쪽 독립 합치` etc.). If you fork `dual-review` to emit English, you must also update the corresponding `grep`/`awk` patterns in `hooks/stop-hook.sh`.

## Install

```bash
git clone https://github.com/hcooch2ch3/dual-review-loop-plugin.git
claude --plugin-dir ./dual-review-loop-plugin
```

## Use

```
/dual-review-loop /abs/path/plan.md [--max-iters N] [--max-minutes M]
/dual-review-loop:cancel
```

Defaults: `--max-iters 20`, `--max-minutes 30`. Both hook-enforced (Gates 10, 10b). `--max-minutes 0` disables wall-clock cap (24h idle gate still applies).

Cancel manually: `rm .claude/dual-review-loop.state.json` in project root.

## Known issues

- **Plan mode blocks commits mid-loop** — if Claude Code's plan mode is active when the loop tries to commit, iteration freezes (inflight marker never cleared). Recovery: exit plan mode, manually `git commit`, then `rm .claude/dual-review-loop.inflight`. Hook resumes on next stop.
- **Forward-fix only** — never `git revert` automatically. Wrong commit must be fixed forward.
- **One concurrent loop per project** — state file existence gate.

## Architecture (quick reference)

- `hooks/stop-hook.sh` — gates the loop on Claude Code stop event. Fail-open invariant.
- `commands/dual-review-loop.md` — `/dual-review-loop <plan>` slash command
- `commands/cancel-loop.md` — `/dual-review-loop:cancel`
- State: `.claude/dual-review-loop.state.json` (project-local JSON, atomic temp+mv)
- In-flight marker: `.claude/dual-review-loop.inflight` (Claude deletes after commit)
- Lock: `.claude/dual-review-loop.lock` (mkdir-atomic)
- Logs: `.claude/dual-review-loop.log`

Patterns adapted from [`anthropics/claude-code` `ralph-wiggum` plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) (minimal self-referential loop) and [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) (fail-open ERR trap, project-local state).

## License

MIT — see [LICENSE](./LICENSE).
