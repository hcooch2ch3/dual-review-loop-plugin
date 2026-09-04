# dual-review-loop

Claude Code plugin. Auto-iterate work under `dual-review` verification, auto-apply high-confidence findings, atomic-commit. Two modes:

- **plan mode** (`/drl`) — iterate a plan file's `- [ ]` checkbox tasks.
- **task mode** (`/drl-task`) — iterate a free-form inline task; you decompose one sub-step per iteration.

Companion to [dual-review](https://github.com/hcooch2ch3/dual-review).

> ⚠️ Currently requires Korean-language `dual-review` output. The injected iteration prompt instructs the LLM to apply Accept findings using Korean headings (`## ✅ Accept — 양쪽 독립 합치` etc.); English support is not yet implemented — see Prerequisites.

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- `jq`, `git` on PATH
- [`dual-review`](https://github.com/hcooch2ch3/dual-review) skill installed at `~/.claude/skills/dual-review/`
- At least one reviewer backend that `dual-review` can dispatch:
  - `superpowers:code-reviewer` + `codex:adversarial-review` (preferred), or
  - `oh-my-claudecode:critic` (fallback)
- **Korean-language `dual-review` output.** The injected iteration prompt names Accept buckets by their Korean headings (`## ✅ Accept — 양쪽 독립 합치`, `## ✅ Accept — 단일 리뷰어, 기술적으로 타당`, `## Open Questions`). The hook itself only parses `## Open Questions` (English heading) for the early-stop gate; the rest live inside the prompt body. If you fork `dual-review` to emit English Accept headings, update the prompt strings in `skills/drl/SKILL.md` and `skills/drl-task/SKILL.md` accordingly.

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
/drl /abs/path/plan.md [--max-iters N] [--max-minutes M]
```

Task mode — iterate a free-form task description (no plan file):
```
/drl-task "<task description>" [--max-iters N] [--max-minutes M] [--max-files N] [--max-loc N] [--max-reviews N]
```

Cancel either mode:
```
/drl-cancel
```

> **Renamed in v2.0.0.** These shipped as plugin *commands* until v1.2.0, and Claude Code
> resolves a plugin command only under its full prefix — `/dual-review-loop:dual-review-loop`,
> `/dual-review-loop:dual-review-task`, `/dual-review-loop:cancel-loop`. They are plugin
> *skills* now, so the short names above work as typed. The old names are gone.

Defaults: `--max-iters 20`, `--max-minutes 0`. Both hook-enforced (Gates 10, 10b).

**`--max-iters` is the cap that binds.** The wall-clock cap ships disabled: at a
measured 9–14 min per iteration, 20 iterations need 3–5 hours, and Gate 10b counts
elapsed time since loop start — including every minute the loop sits paused waiting
for you — then DELETES loop state when it fires. Any finite default small enough to
be useful was small enough to kill a healthy loop. Pass `--max-minutes M` explicitly
if you want a hard wall-clock stop. Abandoned loops are still collected by the 24h
idle gate (Gate 6), which measures idleness rather than elapsed time. One exception:
a loop holding an in-flight marker (it stopped mid-iteration) is given 48h instead,
so a run that is merely waiting on you is not reaped out from under you. The lease is
bounded on purpose — a marker left behind by a killed instance must not protect a dead
loop forever.

Task mode also enforces cumulative caps: `--max-files 30`, `--max-loc 1500`,
`--max-reviews 15` (Gates 10c–e). Plan mode defaults these to "Infinity" so they
don't fire unless explicitly lowered.

**The cumulative caps reset when a loop ends.** They are measured from
`started_at_sha` and `reviews_baseline`, both of which live in the state file,
and every terminal stop deletes that file. So a run that ends on an open question
and is restarted re-baselines to the current `HEAD` and counts from zero again.
Plan mode does not care (its defaults are effectively Infinity), but in task mode
this is the difference between a budget and a suggestion: a task capped at
`--max-loc 200` that stops on three reviewer disagreements can legitimately spend
600 across the three runs. The cap bounds one run, not one task — budget
accordingly, or check `git diff --shortstat` against where you actually started
before launching the next one. (Carrying the baseline across a stop is a resume
feature; it is not in this release.)

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
- **The hook does not validate the brief's schema — it anchors on one heading** — Gate 11 reads a brief looking for `## Open Questions` and nothing else. Extra top-level sections, a missing Accept section, a renamed Reject section: none of it is checked here. Observed in the first real run — a loop wrote two extra top-level sections (`## 리뷰어 근거 요약`, `## 적용 결과`) and nothing noticed, because the model was both producer and consumer of its own brief. That is by design in this repo: schema enforcement belongs to whatever produces the brief, and a hook that refused briefs on shape would stop loops over formatting. If you rely on brief schema, enforce it in the caller — **do not assume a green loop means the briefs were well-formed.**
- **English briefs: one narrow shape is missed** — the placeholder rule that lets a brief write `None. Both reviewers agreed.` on one line also swallows a real question that *opens* with a placeholder word: `- None of the reviewers agree on X`, `- None so far, but A and B split.`, `- N/A, though B disputes the order` all advance. Korean is protected by its grammar (`없다고 …` does not match); English is not. Two closures were measured and both lose — a question-mark rule adds two false *terminations* on the real corpus, and excluding `none of` outright would stop on `None of these are blocking`. Measured at **0 occurrences across 144 English briefs** (of 420 total), so it is documented rather than fixed. If it matters to you, put the disagreement in its own sentence: `- A says drop the index, B says keep it.` Everything else is language-neutral — placeholders (`None`, `N/A`, `No open questions`) and ordinary questions both classify correctly in English, and every message the hook prints is already English.
- **Forward-fix only** — never `git revert` automatically. Wrong commit must be fixed forward.
- **One concurrent loop per project** — state file existence gate. Mode-agnostic: a task-mode loop refuses plan-mode start and vice versa.
- **Downgrading the plugin mid-loop** — schema v2 state (mode/cumulative fields, task mode) is rejected by pre-task-mode v1 hooks (older releases), which fail-open and delete the state file. Current v2 hook does the opposite on an unknown schema (e.g., a future v3 state seen by a v2 hook): `soft_pause` with a `systemMessage` telling you to upgrade the hook or run `/drl-cancel`. If you must downgrade to a pre-v2 hook while a loop is running: cancel first, or accept the loss. Forward upgrades (v1 state running, hook upgraded to v2) are safe — the new hook defaults `mode=plan` and treats absent cumulative fields as Infinity.
- **The loop only watches the repo it started in** — the hook resolves one `REPO_ROOT` (`git rev-parse --show-toplevel`, from its own working directory) and pins every git call to it. Work that commits into a **different repo** — a sibling checkout, a nested repo, a submodule — is invisible: the in-flight backstop sees no forward `HEAD` motion, so the loop never auto-advances (it soft-pauses with "iter `<N>` has not committed yet"), and `git diff --shortstat` measures 0 changed files, so `max_files` and `max_loc` count nothing. Those caps then read as generous when they are simply blind. Run the loop in the repo whose commits it is supposed to see, one loop per repo.
- **`## Open Questions` signals reviewer disagreement, and it has three outcomes** — Gate 11 ends the loop when a brief's `## Open Questions` section holds a real item, because a disagreement between the two reviewers is the one thing the loop must not resolve on its own. Items may be `-`/`*`/`+` bullets or numbered (`1.`, `1)`); placeholders (`none`, `n/a`, `없음`, `없다`, including `없다.` followed by a reason on the same line) do not count, and fenced blocks are skipped so a brief may quote an example safely. **This gate is deliberately fail-closed: anything Open-Questions-shaped that the loop cannot read as a decision pauses it, with state preserved, rather than advancing.** That covers a heading which *begins with* the phrase but is not exactly `## Open Questions` (`## Open Questions (unscored)`, `## Open Questions [DEGRADED]`, `## ❓ Open Questions`) and a body under an exact heading that is prose, a table, a blockquote, or an orphaned indented item — anything the item detector structurally cannot see. Suffixed headings do **not** terminate the loop (reviewers use them for their own notes, and terminating on them was measured as a regression); they hold it and name what they saw. Rename to anything not beginning with `Open Questions` and the loop resumes; rename to exactly `## Open Questions` with top-level bullets and the loop ends and hands you the decision. Until then the message repeats each turn and at 24h the loop is collected, with a message saying it was held rather than idle. Headings that merely mention the phrase (`## No Open Questions`, `### Task 3: Open Questions …`) are not matched, and a note indented under a top-level item is not treated as a new question. Measured on 410 real briefs — every `~/.claude/projects/*/plans/*.md` plus every `**/.claude/reviews/*.md` under `~/Desktop`, which is the selection rule so the number is checkable rather than asserted — **87 terminate, 62 pause**. There are three outcomes to weigh, not two: a false pause costs one rename, a false *terminate* deletes the state file and re-baselines the task-mode budgets, and a missed disagreement is a wrong commit. The pause rate is the deliberate cost of keeping the third one rare.

### Recovery: loop is paused, hook isn't advancing

The hook `soft_pause`s (state preserved, no inject) in several scenarios. The Claude Code UI shows a `systemMessage` for the recoverable ones. Common cases:

- **"baseline commit `<sha>` was lost (rebase/squash/gc)"** — your `started_at_sha` was orphaned by a rebase or `git gc`. Cumulative caps (`max_files` / `max_loc`) can't be enforced. To resume: edit `.started_at_sha` in `.claude/dual-review-loop.state.json` to current `HEAD` (jq + temp+mv) and the next stop fire continues. Or run `/drl-cancel` to abandon the run. (The "do not edit state" rule applies to hook-owned counter fields, not this recovery edit; `started_at_sha` is command-owned.)
- **"state schema `<x>` unknown"** — see the downgrade note above. Install a hook that supports the schema, or cancel.
- **Manual deletion of `.claude/reviews/iter-*.md` mid-run** — the `max_reviews` gate uses a hook-tracked baseline. Deleting briefs causes a "reviews_baseline re-init" log entry on the next fire (baseline drops to the new count); the cap stays meaningful. No user action needed, just be aware that manually rm'd briefs reset the budget window.
- **"iter `<N>` has not committed yet" / "completion can't be auto-detected"** — the previous iteration's in-flight marker is still present and no commit has landed since it was injected. If a commit *did* land but the loop didn't advance, the baseline SHA was probably missing (legacy/non-git state) — `rm .claude/dual-review-loop.inflight` to resume. Otherwise exit plan mode and let the iteration commit (it auto-resumes), or `/drl-cancel`.
- **"another hook instance holds the lock"** — two hook fires overlapped and this one
  stood down. Normally self-correcting. If it repeats with no other loop running, the
  lock is stale (an instance was killed before it could release):
  a lock with no possible live holder is reclaimed automatically after 10 minutes,
  and the pause message prints the absolute path if you want to clear it sooner:
  `rmdir .claude/dual-review-loop.lock`. The hook never removes a lock it did not
  acquire — a non-owner deleting one destroys mutual exclusion — so the reclaim is
  gated on an age no live holder can reach (a lock is held for the lifetime of one
  hook invocation, i.e. seconds).
- **"every task in the plan is complete, but the working tree still has uncommitted
  changes"** — Gate 9 refuses to declare completion over a dirty tree, since the last
  iteration's commit may not have landed. Commit or stash, and the loop finishes on the
  next turn. If the dirt is plugin artifacts, add the three ignore patterns (see Use).
- **Different session / no-continuation signal** — these pauses are expected and stay
  silent (second-session resume is intentional; user takeover stops the loop). If a loop
  seems stuck without a `systemMessage`, check `.claude/dual-review-loop.log` for the
  last `SOFT-PAUSE:` line.

## Stop-hook block budget

Claude Code caps how many times a Stop hook may block, via
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default **8**). Beyond that the block is overridden
and the turn ends.

**Two observations that do not agree. Both are recorded here because the disagreement
is the useful part.**

*Probe, CLI 2.1.221, headless `claude -p`, single registered Stop hook, a throwaway hook
that always blocked and did no work between blocks:* the hook fired 9 times per user
turn — blocks 1–8 honoured, the 9th overridden — and the count reset on the next turn.

*Real run, same CLI version, this plugin's hook, a 10-task plan:* the loop injected
**9 times inside a single headless invocation** and ran to `all tasks complete` after 9
iterations, with every injected iteration doing real work (edit, dual review, commit).
No override was observed at 8.

The difference between the two is that the probe blocked with nothing in between, while
the real loop does substantial work — tool calls, subagents, commits — between blocks.
**We do not know which of those is the operative difference, and this document does not
guess.** What follows from the pair is narrower than either alone:

- Do not treat 8 as a hard iteration ceiling. A 9-iteration run completed.
- Do not treat the cap as absent either. A synthetic hook hit an override at 9.
- `--max-iters 20` has not been observed to completion. 9 has.

If your loop stops without a `systemMessage` somewhere near 8 iterations, this is the
first thing to suspect, and `.claude/dual-review-loop.log` will show the last gate that
ran.

## What a real end-to-end run confirmed

Everything else in this file is measured against fixtures or a corpus. This section is
the one place where the loop was actually driven — three runs in a throwaway repo, a
real plan, real reviewers, the real hook — because a suite that never runs the product
cannot tell you the product runs.

- **The loop completes.** Pick task, execute, dispatch two reviewers, write the
  brief, flip the checkbox, atomic commit, clear the marker, hook advances,
  terminate. Twice, unattended.
- **Gate 7 holds the line while reviewers work.** The hook fired repeatedly during
  each review and logged `no commit detected; not advancing` every time, then
  `commit landed … clearing marker, advancing` once the commit was real. The
  defence against advancing over uncommitted work is not theoretical.
- **Gate 11 stops the loop on a disagreement, and says so on screen.** A brief
  carrying a real open question terminated the run with
  `Open Questions detected in last brief — user decision needed` in the log and the
  full explanation in the user's terminal.
- **The placeholder rule earns its keep on the first real brief.** A reviewer wrote
  `- 없음 — 두 리뷰어의 판정이 … 갈린 지점이 없음` ("none — the two reviewers agreed").
  Under the whole-line placeholder anchor this project shipped two days earlier, that
  line **terminated the loop and deleted its state**, quoting the word for "none" back
  as the question needing a decision. Under the prefix anchor it correctly advances.
  The first real run would have died on its first brief.

**Not exercised even so:** the auto-apply path for Accept findings, the Minor-deferral
footer, and verify-failure retry — four reviewer runs returned zero findings on
one-line appends, and the test repo had no verify command. Those remain fixture-only.

## Message delivery: is `systemMessage` seen on a non-blocking response?

Every stop reason this plugin prints rides on `systemMessage` in a
`{"decision":"approve"}` response — a decision that does *not* block. That is
worth stating plainly because it was believed rather than measured for a while,
and if the field were dropped the messages would be inert.

**Measured** by reading the installed CLI bundle (`cli.js`), not by assumption:

- The schema takes `decision: "approve" | "block"` and `systemMessage` as
  **sibling** fields — `systemMessage` is not nested under a decision.
- The handler assigns `if (A.systemMessage) W.systemMessage = A.systemMessage`
  **outside** the decision switch, so an approve carries it just as a block does.
- The renderer is the decisive part. The two cases immediately adjacent to it
  suppress themselves for Stop hooks — `hook_stopped_continuation` and
  `hook_blocking_error` both `return null` when `hookEvent === "Stop"` — and
  `hook_system_message` does **not**. It renders as `<hookName> says: <message>`.
- `normalizeAttachmentForAPI` returns `[]` for it, so the text goes to the user
  and never back into the model's context. That is the right shape for this use.

So in the interactive CLI the channel works — and that is no longer only a reading of
the bundle. A live loop was driven end to end and the stop message appeared on screen,
prefixed exactly as the renderer builds it:

```
⎿  Stop says: dual-review-loop: stopped because the review brief has a question
   that needs your decision. Brief: …/iter-001.md. First item: …
```

**Headless is now measured too, and it splits by output format.** A throwaway Stop hook
emitting `{"decision":"approve","systemMessage":"PROBE-…"}` was run under `claude -p`, with
the hook writing a marker file so "the message is absent" could be told apart from "the hook
never fired". It fired exactly once in each run.

| mode | hook fired | message reaches the output |
|---|---|---|
| `claude -p --output-format text` | yes (1×) | **no — dropped entirely** |
| `claude -p --output-format stream-json --verbose` | yes (1×) | **yes** |

In `stream-json` it arrives as its own event, matching the interactive renderer's wording:

```json
{"type":"system","subtype":"informational","level":"notice",
 "content":"Stop says: PROBE-…"}
```

**So a loop driven headless with `--output-format text` shows the user nothing** — every stop
reason this plugin prints is invisible in that mode. That is the one configuration where
`.claude/dual-review-loop.log` is not a convenience but the only channel, and it records every
stop reason regardless of client.

## Architecture (quick reference)

- `hooks/stop-hook.sh` — gates the loop on Claude Code stop event. Fail-open invariant. Schema v1 (plan-only legacy) and v2 (mode + cumulative gates) both accepted. Run `shellcheck hooks/stop-hook.sh` and `bash tests/run-all.sh` before changing it.
- `skills/drl/SKILL.md` — `/drl <plan>` (plan mode)
- `skills/drl-task/SKILL.md` — `/drl-task "<task>"` (task mode)
- `skills/drl-cancel/SKILL.md` — `/drl-cancel` (mode-agnostic)
- All three skills set `disable-model-invocation: true` — only you start or cancel a loop. A skill is model-invocable by default, and this one commits code, so the guard is load-bearing.
  The cost: a skill carrying that guard is also hidden from Claude's own skill listing, so Claude no longer knows these exist unless a hook message names one. That is why every stop-hook message that offers a way out spells out `/drl-cancel` literally. The old `commands/` layout was visible *and* user-only; the skills layout trades the visibility for the short name.
- State: `.claude/dual-review-loop.state.json` (project-local JSON, atomic temp+mv). Single file across both modes; `mode` field discriminates.
- Task log: `.claude/dual-review-loop/task-<session_id>.log.md` (task mode only; preserved across cancel for post-mortem)
- In-flight marker: `.claude/dual-review-loop.inflight` (Claude deletes after commit; the hook also auto-clears it once it detects the iter's commit landed via git — see Known issues)
- Lock: `.claude/dual-review-loop.lock` (mkdir-atomic)
- Logs: `.claude/dual-review-loop.log`

Patterns adapted from [`anthropics/claude-code` `ralph-wiggum` plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) (minimal self-referential loop) and [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) (fail-open ERR trap, project-local state).

## License

MIT — see [LICENSE](./LICENSE).
