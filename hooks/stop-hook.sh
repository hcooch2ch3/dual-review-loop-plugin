#!/usr/bin/env bash
# dual-review-loop — Stop hook
#
# Re-injects "process next task" prompt while a loop is active AND the previous
# stop was a continuation of our injection (not a fresh user prompt).
# Defaults to fail-open on any error: NEVER trap the user.
#
# State file:   <project-root>/.claude/dual-review-loop.state.json
# Lock dir:     <project-root>/.claude/dual-review-loop.lock        (mkdir-atomic)
# Inflight:     <project-root>/.claude/dual-review-loop.inflight   (sentinel for in-progress iter)
# Log file:     <project-root>/.claude/dual-review-loop.log
# Briefs:       <project-root>/.claude/reviews/iter-NNN.md
#
# Gates (each fails-open with approve; some also cleanup state):
#   0   state file missing
#   0.5 jq missing
#   1   JSON parse fails
#   2   schema mismatch
#   3   active != true
#   4   session_id mismatch (phantom defense, cross-session)
#   5   phantom defense (same-session): hook didn't inject the previous turn
#   6   idle timeout exceeded (24h default)
#   7   in-flight marker present (mid-iter, do not re-fire)
#   8   plan_path missing/relative
#   9   plan has no unfinished tasks (AND no uncommitted changes)
#   10  max_iterations reached
#   10b max_minutes reached (wall-clock cap)
#   11  Open Questions in previous brief
#   12  lock not acquired (another hook instance running)
#
# Otherwise: lock + iter++ + compute next brief path + write inflight marker +
# atomic state write + emit {"decision":"block","reason":<jq-built prompt>}.

set -u

# Anchor every path + git call to a stable repo root rather than the hook's
# cwd (which can drift in multi-repo Claude Code sessions). We resolve from
# `git rev-parse --show-toplevel` once, falling back to cwd when not in a
# git repo. All subsequent git calls use `git -C "$REPO_ROOT"`.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

LOG_FILE="$REPO_ROOT/.claude/dual-review-loop.log"
STATE_FILE="$REPO_ROOT/.claude/dual-review-loop.state.json"
LOCK_DIR="$REPO_ROOT/.claude/dual-review-loop.lock"
# Lock ownership. Only the invocation whose `mkdir "$LOCK_DIR"` succeeded may
# remove it. Before this flag existed every exit path ran an unconditional
# `rmdir`, so an instance that LOST the race deleted the winner's lock and
# mutual exclusion collapsed (dual review: defect G).
LOCK_HELD=0
INFLIGHT_FILE="$REPO_ROOT/.claude/dual-review-loop.inflight"
REVIEWS_DIR="$REPO_ROOT/.claude/reviews"
IDLE_TIMEOUT_SECONDS=$((24 * 3600))
PHANTOM_GRACE_SECONDS=600   # if hook fires within 10min of last inject, assume continuation
# v1: plan-mode only (legacy). v2: adds `mode` field + cumulative gates +
# task mode. Both accepted so v1 in-flight loops do not break when the hook is
# upgraded ahead of the command (codex dual review high #2 — atomic migration).
SCHEMA_VERSIONS_OK="v1 v2"

# Release the lock only if this invocation acquired it. Never returns
# non-zero: the ERR trap fires on any failing simple command even though only
# `set -u` is active, so a helper on the exit path must not re-enter it.
release_lock() {
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
  return 0
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE" 2>/dev/null
}

approve() {
  printf '{"decision":"approve"}\n'
  # release lock if we hold it
  release_lock
  exit 0
}

# Cleanup state + approve (terminal: loop ends here)
cleanup_and_approve() {
  log "$1"
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  release_lock
  printf '{"decision":"approve"}\n'
  exit 0
}

# Soft pause: do not inject this turn, but keep state for user-driven resume.
# Optional 2nd arg = user-facing systemMessage (surfaced in Claude Code UI so
# the user actually sees how to recover; without it the pause is silent and
# users can't tell why their loop stopped advancing).
soft_pause() {
  log "SOFT-PAUSE: $1 (state preserved)"
  release_lock
  if [ "$#" -ge 2 ] && [ -n "$2" ]; then
    jq -n --arg m "$2" '{"decision":"approve","systemMessage":$m}' 2>/dev/null \
      || printf '{"decision":"approve"}\n'
  else
    printf '{"decision":"approve"}\n'
  fi
  exit 0
}

# Hard fail-open: error path, clean everything
fail_open() {
  log "FAIL-OPEN: $1"
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  release_lock
  printf '{"decision":"approve"}\n'
  exit 0
}

trap 'log "ERR trap fired (line $LINENO)"; rm -f "$INFLIGHT_FILE" 2>/dev/null; release_lock; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

HOOK_INPUT=$(cat 2>/dev/null || echo "")

# Gate 0: state file exists?
[ -f "$STATE_FILE" ] || approve

# Gate 0.5: jq available?
command -v jq >/dev/null 2>&1 || fail_open "jq not on PATH"

# Gate 12 (early): acquire lock via mkdir (atomic)
mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "lock held by another hook instance; soft-pause"
  # Recovery hint. Until ownership tracking landed, this path's unconditional
  # rmdir doubled as the only stale-lock cleanup: a hard-killed instance left
  # the dir behind and the next loser cleared it. A non-owner must not delete
  # the lock, so an orphan is now permanent and the user has to clear it —
  # say so rather than pausing silently forever.
  soft_pause "lock contention" \
    "dual-review-loop: another hook instance holds the lock, so this turn did not advance. If no other loop is running, the lock is stale — remove it with: rmdir .claude/dual-review-loop.lock"
fi
LOCK_HELD=1

# Gate 1: JSON parses?
if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  fail_open "state file is not valid JSON"
fi

SCHEMA=$(jq -r '.schema // ""' "$STATE_FILE")
ACTIVE=$(jq -r '.active // false' "$STATE_FILE")
PLAN_PATH=$(jq -r '.plan_path // ""' "$STATE_FILE")
ITERATION=$(jq -r '.iteration // 0' "$STATE_FILE")
MAX_ITERATIONS=$(jq -r '.max_iterations // 20' "$STATE_FILE")
MAX_MINUTES=$(jq -r '.max_minutes // 30' "$STATE_FILE")
SESSION_ID_STATE=$(jq -r '.session_id // ""' "$STATE_FILE")
STARTED_AT=$(jq -r '.started_at_epoch // 0' "$STATE_FILE")
LAST_ITER_AT=$(jq -r '.last_iter_at_epoch // 0' "$STATE_FILE")
LAST_INJECTED_AT=$(jq -r '.last_injected_at_epoch // 0' "$STATE_FILE")
LAST_INJECTED_ITER=$(jq -r '.last_injected_iter // 0' "$STATE_FILE")
LAST_BRIEF_PATH=$(jq -r '.last_brief_path // ""' "$STATE_FILE")

# v2 fields (default to "plan mode + Infinity gates" so v1 state is byte-equivalent).
# Cumulative cap fields are hook-OWNED — computed from git diff + filesystem,
# not trusted from prompt-driven state updates (dual review #8 high #1).
MODE=$(jq -r '.mode // "plan"' "$STATE_FILE")
MAX_FILES=$(jq -r '.max_files // 999999' "$STATE_FILE")
MAX_LOC=$(jq -r '.max_loc // 999999' "$STATE_FILE")
MAX_REVIEWS=$(jq -r '.max_reviews // 999999' "$STATE_FILE")
STARTED_AT_SHA=$(jq -r '.started_at_sha // ""' "$STATE_FILE")
# HEAD recorded when the current in-flight iter was injected (hook-owned).
# Gate 7 uses it as ground truth for "did this iter's commit land?" so marker
# clearing no longer depends on the LLM running the prompt's `rm` step. Empty
# for v1 / upgraded-mid-flight state → Gate 7 cannot detect → never false-advances.
INFLIGHT_BASE_SHA=$(jq -r '.inflight_base_sha // ""' "$STATE_FILE")

NOW_EPOCH=$(date +%s)

# Gate 2: schema (accept any version in SCHEMA_VERSIONS_OK)
case " $SCHEMA_VERSIONS_OK " in
  *" $SCHEMA "*) ;;
  # Preserve state on mismatch (could be a future-schema downgrade by an
  # older hook). fail_open here would nuke the user's loop; soft-pause lets
  # them downgrade/upgrade manually instead.
  *) soft_pause "schema mismatch (got=$SCHEMA expected one of: $SCHEMA_VERSIONS_OK) — state preserved; downgrade hook or cancel manually" \
       "dual-review-loop paused: state schema '$SCHEMA' unknown. To resume: install a hook supporting this schema, OR run /dual-review-loop:cancel-loop (or rm $STATE_FILE) to start over." ;;
esac

# Gate 3: active
[ "$ACTIVE" = "true" ] || cleanup_and_approve "state.active != true"

# Gate 4: cross-session phantom defense
SESSION_ID_HOOK=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$SESSION_ID_STATE" ] || fail_open "state.session_id empty"
if [ -n "$SESSION_ID_HOOK" ] && [ "$SESSION_ID_HOOK" != "$SESSION_ID_STATE" ]; then
  soft_pause "different session ($SESSION_ID_HOOK != $SESSION_ID_STATE)"
fi

# Gate 5: same-session phantom defense
# If we've already injected at least once, the previous user-turn must contain
# our sentinel. Sentinels (mode-aware):
#   plan: "[dual-review-loop iter <N>"
#   task: "[dual-review-loop task iter <N>"
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
if [ "$LAST_INJECTED_ITER" -gt 0 ]; then
  CONTINUATION=0
  # Strategy A: time window — if injection was very recent, assume continuation
  if [ "$LAST_INJECTED_AT" -gt 0 ]; then
    GAP=$((NOW_EPOCH - LAST_INJECTED_AT))
    if [ "$GAP" -lt "$PHANTOM_GRACE_SECONDS" ]; then
      CONTINUATION=1
    fi
  fi
  # Strategy B: transcript sentinel check. Mode-pinned (no cross-mode escape)
  # and digit-anchored ("iter 1" must not match "iter 10/11/...").
  # We still scan the whole transcript (parsing JSONL last-user-message safely
  # across schema variants is brittle); the digit anchor + mode pin + iter#
  # equality together make stale matches structurally rare. Hook-owned counter
  # advances LAST_INJECTED_ITER each fire, so once iter advances the old
  # sentinel for iter N stops matching iter N+1's check.
  if [ "$CONTINUATION" -eq 0 ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Anchor uses ([^0-9]|$) so end-of-line / end-of-file also terminates
    # the iter# (bare `[^0-9]` would fail to match if a future format change
    # ever drops the trailing `/MAX]` suffix that today's format guarantees).
    case "$MODE" in
      task) SENTINEL_RE="\[dual-review-loop task iter ${LAST_INJECTED_ITER}([^0-9]|\$)" ;;
      *)    SENTINEL_RE="\[dual-review-loop iter ${LAST_INJECTED_ITER}([^0-9]|\$)" ;;
    esac
    if grep -qE "$SENTINEL_RE" "$TRANSCRIPT_PATH" 2>/dev/null; then
      CONTINUATION=1
    fi
  fi
  if [ "$CONTINUATION" -eq 0 ]; then
    soft_pause "no continuation signal (last_injected_iter=$LAST_INJECTED_ITER, gap=${GAP:-?}s) — user likely took control"
  fi
fi

# Gate 6: idle timeout
LAST_ACT=$LAST_ITER_AT
[ "$LAST_ACT" -eq 0 ] && LAST_ACT=$STARTED_AT
if [ "$((NOW_EPOCH - LAST_ACT))" -gt "$IDLE_TIMEOUT_SECONDS" ]; then
  cleanup_and_approve "idle timeout (>${IDLE_TIMEOUT_SECONDS}s)"
fi

# Gate 7: in-flight marker — previous iter not yet finalized.
# UNION completion detection (dual review #11): the marker is hook-created but
# was historically LLM-cleared (prompt step 9 `rm inflight`). When the LLM
# never reached that step — plan mode blocking the commit being the canonical
# case, also early stops / errors — the marker stayed and this gate became a
# permanent dead-end (no advance, no re-inject) → frozen loop.
# Now we advance when EITHER signal says the iter is done:
#   (a) marker absent      → LLM cleared it (normal path, incl. legitimate
#                            no-op iters that commit nothing; see task §6), OR
#   (b) marker present BUT  → hook proves via git the commit landed
#       commit landed         (HEAD moved forward past inflight_base_sha).
# Soft-pause ONLY when the marker is present AND no commit landed. The git
# backstop makes recovery auto-resume the moment a commit lands (Claude's or a
# manual one) — the old manual `rm .inflight` recovery step is no longer needed.
if [ -f "$INFLIGHT_FILE" ]; then
  INFLIGHT_ITER=$(cat "$INFLIGHT_FILE" 2>/dev/null || echo "?")
  COMMIT_LANDED=0
  if [ -n "$INFLIGHT_BASE_SHA" ]; then
    CUR_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$CUR_HEAD" ] && [ "$CUR_HEAD" != "$INFLIGHT_BASE_SHA" ]; then
      # HEAD moved. Confirm FORWARD motion (base is an ancestor of HEAD) so an
      # unrelated reset/checkout doesn't read as a completed iter. Note:
      # `merge-base --is-ancestor` exits 1 on a normal "not an ancestor" answer
      # — it MUST stay inside this `if` or the ERR trap (top of file) would fire.
      if git -C "$REPO_ROOT" merge-base --is-ancestor "$INFLIGHT_BASE_SHA" "$CUR_HEAD" 2>/dev/null; then
        COMMIT_LANDED=1
      fi
    fi
  fi
  if [ "$COMMIT_LANDED" -eq 1 ]; then
    log "in-flight iter $INFLIGHT_ITER: commit landed (HEAD $CUR_HEAD past base $INFLIGHT_BASE_SHA) — clearing marker, advancing"
    rm -f "$INFLIGHT_FILE" 2>/dev/null || true
    # Fall through to the normal advance path below (gates 8-11 + iter++).
  else
    # Marker present, no commit detected. Don't inject (no fighting plan mode).
    # The recovery advice MUST differ by whether the git backstop is armed: when
    # inflight_base_sha is empty (legacy v1 / non-git / upgraded mid-flight) we
    # genuinely cannot auto-detect a landed commit, so manual recovery is still
    # required and we must NOT claim auto-resume or "no commit since base"
    # (dual review #11: Codex C2/C3 + code-reviewer P2 — over-promising message).
    if [ -n "$INFLIGHT_BASE_SHA" ]; then
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} has not committed yet (plan mode can block commits, or it stopped early). It auto-resumes the moment a commit lands — exit plan mode and let it finish. If this iteration legitimately produced no commit, run /dual-review-loop:cancel-loop (or rm .claude/dual-review-loop.inflight)."
    else
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} is in-flight but completion can't be auto-detected (no baseline SHA — legacy state or non-git repo). If the work already committed, rm .claude/dual-review-loop.inflight to resume; otherwise run /dual-review-loop:cancel-loop."
    fi
    log "in-flight marker present (iter=$INFLIGHT_ITER) — no commit detected; not advancing (base_sha=${INFLIGHT_BASE_SHA:-<none>})"
    # Keep state + marker so the next fire / a debugger can still see it.
    release_lock
    jq -n --arg m "$PAUSE_MSG" '{"decision":"approve","systemMessage":$m}' 2>/dev/null \
      || printf '{"decision":"approve","systemMessage":"dual-review-loop: previous iter still in-flight; not advancing"}\n'
    exit 0
  fi
fi

# Mode dispatch: plan/task share gates 10-11 + state update; gates 8-9
# differ (plan inspects plan_path checkboxes; task validates task_description).
# Unknown mode fails open so a corrupted state never traps the user.
TASK_DESCRIPTION=""
TASK_LOG_PATH=""

case "$MODE" in
  plan)
    # Gate 8 (plan): plan_path absolute + exists
    case "$PLAN_PATH" in
      /*) ;;
      *)  fail_open "plan_path not absolute: $PLAN_PATH" ;;
    esac
    [ -f "$PLAN_PATH" ] || fail_open "plan_path missing: $PLAN_PATH"

    # Gate 9 (plan): plan has unfinished tasks? (also check working tree
    # clean to avoid premature completion)
    UNFINISHED=$(grep -cE '^([-*+]|[0-9]+\.) \[ \]' "$PLAN_PATH" 2>/dev/null | head -1)
    UNFINISHED=${UNFINISHED:-0}
    if [ "$UNFINISHED" -eq 0 ] 2>/dev/null; then
      # No unfinished tasks. But if working tree has uncommitted changes,
      # the last iter's commit may not have landed yet — don't declare done.
      PLAN_DIR=$(dirname "$PLAN_PATH")
      if git -C "$PLAN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        DIRTY=$(git -C "$PLAN_DIR" status --porcelain 2>/dev/null | head -1)
        if [ -n "$DIRTY" ]; then
          log "no unfinished tasks but working tree dirty — soft-pause for manual commit"
          soft_pause "no unfinished tasks but uncommitted changes present"
        fi
      fi
      cleanup_and_approve "all tasks complete after $ITERATION iterations"
    fi
    ;;
  task)
    # Gate 8 (task): task_description present + within length bounds
    TASK_DESCRIPTION=$(jq -r '.task_description // ""' "$STATE_FILE")
    if [ -z "$TASK_DESCRIPTION" ]; then
      fail_open "task_description empty in state"
    fi
    TASK_DESC_LEN=${#TASK_DESCRIPTION}
    if [ "$TASK_DESC_LEN" -gt 2000 ]; then
      fail_open "task_description too long ($TASK_DESC_LEN chars; max 2000)"
    fi
    # Gate 9 (task): task log path read (best-effort — log existence is the
    # command's responsibility, hook only references it in the inject prompt
    # so the LLM can read prior iter context).
    TASK_LOG_PATH=$(jq -r '.task_log_path // ""' "$STATE_FILE")
    ;;
  *)
    fail_open "unknown mode in state: $MODE"
    ;;
esac

# Gate 10: max_iterations
if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  cleanup_and_approve "max_iterations reached ($ITERATION >= $MAX_ITERATIONS)"
fi

# Gate 10b: max_minutes (wall-clock cap since started_at_epoch)
if [ "$MAX_MINUTES" -gt 0 ] && [ "$STARTED_AT" -gt 0 ]; then
  ELAPSED_SEC=$(( NOW_EPOCH - STARTED_AT ))
  CAP_SEC=$(( MAX_MINUTES * 60 ))
  if [ "$ELAPSED_SEC" -ge "$CAP_SEC" ]; then
    cleanup_and_approve "max_minutes reached (${ELAPSED_SEC}s >= ${CAP_SEC}s / ${MAX_MINUTES}min cap)"
  fi
fi

# Gates 10c-e: cumulative caps. Hook-computed from git + filesystem so the
# LLM cannot bypass them by skipping a counter-update step (dual review #8
# Critical/I1). v1 state has no started_at_sha → cum_files/loc stay 0 → no
# enforcement (v1 default 999999 max also keeps this no-op for legacy state).
CUM_FILES=0
CUM_LOC=0
CUM_REVIEWS=0
if [ -n "$STARTED_AT_SHA" ] && git -C "$REPO_ROOT" cat-file -e "$STARTED_AT_SHA" 2>/dev/null; then
  # Baseline SHA still resolvable in this repo (rebase/squash-merge could have
  # orphaned it; in that case we soft-pause below rather than silently treat
  # the run as 0-LOC and bypass budget caps).
  if STATS=$(git -C "$REPO_ROOT" diff --shortstat "$STARTED_AT_SHA" HEAD 2>/dev/null); then
    # Parse "N files changed, X insertions(+), Y deletions(-)" (each piece optional).
    FILES_TOK=$(printf '%s' "$STATS" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' | head -1)
    INS_TOK=$(printf '%s' "$STATS"  | grep -oE '[0-9]+ insertions?'    | grep -oE '[0-9]+' | head -1)
    DEL_TOK=$(printf '%s' "$STATS"  | grep -oE '[0-9]+ deletions?'     | grep -oE '[0-9]+' | head -1)
    CUM_FILES=${FILES_TOK:-0}
    CUM_LOC=$(( ${INS_TOK:-0} + ${DEL_TOK:-0} ))
  fi
elif [ -n "$STARTED_AT_SHA" ]; then
  # SHA exists in state but not in repo (rebase / squash-merge dropped it).
  # Silently leaving CUM_*=0 would disable budget caps; soft-pause for the
  # user to decide (re-baseline by editing state, or cancel cleanly).
  soft_pause "started_at_sha=$STARTED_AT_SHA no longer resolvable (rebase?) — cumulative caps cannot be enforced; resolve manually or cancel" \
    "dual-review-loop paused: baseline commit $STARTED_AT_SHA was lost (rebase/squash/gc). To resume: edit '.started_at_sha' in $STATE_FILE to current HEAD (jq + temp+mv), OR run /dual-review-loop:cancel-loop. (The 'do not edit state' rule applies to hook-owned counter fields, not this recovery edit.)"
fi
# Review-count gate: count files written **after** loop start so prior runs'
# briefs don't pre-exhaust max_reviews. Hook records reviews_baseline on its
# first fire (when iteration was still 0); subsequent fires use that.
REVIEWS_BASELINE=$(jq -r '.reviews_baseline // -1' "$STATE_FILE")
CUR_REVIEWS_COUNT=$(ls "$REVIEWS_DIR"/iter-*.md 2>/dev/null | wc -l | tr -d ' ')
CUR_REVIEWS_COUNT=${CUR_REVIEWS_COUNT:-0}
if [ "$REVIEWS_BASELINE" = "-1" ]; then
  REVIEWS_BASELINE=$CUR_REVIEWS_COUNT
fi
CUM_REVIEWS=$(( CUR_REVIEWS_COUNT - REVIEWS_BASELINE ))
# Negative delta means briefs were deleted under us. Just clamping to 0 would
# silently disarm max_reviews until the count climbs back above the old
# baseline. Re-baseline instead so the cap stays meaningful.
if [ "$CUM_REVIEWS" -lt 0 ]; then
  log "reviews_baseline re-init: count $CUR_REVIEWS_COUNT < baseline $REVIEWS_BASELINE (briefs deleted)"
  REVIEWS_BASELINE=$CUR_REVIEWS_COUNT
  CUM_REVIEWS=0
fi

if [ "$CUM_FILES" -ge "$MAX_FILES" ]; then
  cleanup_and_approve "max_files reached ($CUM_FILES >= $MAX_FILES)"
fi
if [ "$CUM_LOC" -ge "$MAX_LOC" ]; then
  cleanup_and_approve "max_loc reached ($CUM_LOC >= $MAX_LOC)"
fi
if [ "$CUM_REVIEWS" -ge "$MAX_REVIEWS" ]; then
  cleanup_and_approve "max_reviews reached ($CUM_REVIEWS >= $MAX_REVIEWS)"
fi
# (consecutive_same_failure gate removed in dual review #8 — fingerprint
# was undefined across iters; max_iterations is the hard stop on stuck verify.)

# Gate 11: Open Questions in previous brief?
# Prefer last_brief_path; fallback to transcript scan.
OPEN_Q_FOUND=0
if [ -n "$LAST_BRIEF_PATH" ] && [ -f "$LAST_BRIEF_PATH" ]; then
  if awk '
    /^## Open Questions[[:space:]]*$/ { in_oq=1; next }
    /^## / { in_oq=0 }
    in_oq && /^- / { found=1; exit }
    END { exit !found }
  ' "$LAST_BRIEF_PATH" 2>/dev/null; then
    OPEN_Q_FOUND=1
  fi
elif [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Fallback: search last assistant message text for Open Questions heading + non-empty body
  LAST_ASSISTANT=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [ -n "$LAST_ASSISTANT" ]; then
    BODY=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.content | map(select(.type=="text")) | map(.text) | join("\n")' 2>/dev/null)
    if printf '%s' "$BODY" | awk '
      /^## Open Questions[[:space:]]*$/ { in_oq=1; next }
      /^## / { in_oq=0 }
      in_oq && /^- / { found=1; exit }
      END { exit !found }
    ' 2>/dev/null; then
      OPEN_Q_FOUND=1
    fi
  fi
fi

if [ "$OPEN_Q_FOUND" -eq 1 ]; then
  cleanup_and_approve "Open Questions detected in last brief — user decision needed"
fi

# All gates passed — prepare to inject next iteration
NEXT_ITER=$((ITERATION + 1))
ITER_PADDED=$(printf '%03d' "$NEXT_ITER")
NEXT_BRIEF_PATH="${REVIEWS_DIR}/iter-${ITER_PADDED}.md"
mkdir -p "$REVIEWS_DIR" 2>/dev/null

# HEAD at the moment we inject iter NEXT_ITER (before the LLM does any work).
# Gate 7 on the NEXT fire compares HEAD against this to detect whether the
# iter's commit landed — hook-owned completion signal, no LLM-`rm` dependence.
# Empty when not a git repo → Gate 7 falls back to the marker-only path.
NEXT_INFLIGHT_BASE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")

# Atomic state update — hook owns ALL state fields
TEMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXX" 2>/dev/null)" || fail_open "mktemp failed"
jq --argjson next "$NEXT_ITER" \
   --argjson now "$NOW_EPOCH" \
   --argjson baseline "$REVIEWS_BASELINE" \
   --arg brief "$NEXT_BRIEF_PATH" \
   --arg inflightbase "$NEXT_INFLIGHT_BASE_SHA" \
   '.iteration = $next
    | .last_iter_at_epoch = $now
    | .last_injected_at_epoch = $now
    | .last_injected_iter = $next
    | .last_brief_path = $brief
    | .reviews_baseline = $baseline
    | .inflight_base_sha = $inflightbase' \
   "$STATE_FILE" > "$TEMP_FILE" 2>/dev/null

if [ ! -s "$TEMP_FILE" ]; then
  rm -f "$TEMP_FILE"
  fail_open "jq state update produced empty file"
fi
mv "$TEMP_FILE" "$STATE_FILE" 2>/dev/null || { rm -f "$TEMP_FILE"; fail_open "atomic mv failed"; }

# Write in-flight marker (Claude removes it after step 7 commit)
printf '%s\n' "$NEXT_ITER" > "$INFLIGHT_FILE" 2>/dev/null || true

log "iter $NEXT_ITER → injecting (brief target: $NEXT_BRIEF_PATH)"

# Build REASON via jq to safely escape any shell special chars.
# Two prompt shapes — plan (checkbox-driven) vs task (free-form inline).
# IMPORTANT: task prompts must NOT contain the token "ralph" / "RALPH" — that
# brand collides with another plugin family and could cross-trigger their
# stop hook. Sentinel format is "[dual-review-loop iter N/M]" (plan) or
# "[dual-review-loop task iter N/M]" (task); a token-blacklist regression
# test pins this.
case "$MODE" in
  plan)
    REASON=$(jq -nr \
      --argjson iter "$NEXT_ITER" \
      --argjson max "$MAX_ITERATIONS" \
      --arg plan "$PLAN_PATH" \
      --arg brief "$NEXT_BRIEF_PATH" \
      --arg inflight "$INFLIGHT_FILE" '
"[dual-review-loop iter \($iter)/\($max)]

Plan: \($plan)

Process exactly ONE next unfinished task from the plan checkbox list:

1. Pick the first \"- [ ]\" (or \"* [ ]\" / \"+ [ ]\" / \"N. [ ]\") item in \($plan)
2. Execute it (make code changes, run tests, etc.)
3. Invoke the dual-review skill programmatically. Include this block in your dispatch prompt:
     dual-review-invocation:
       mode: programmatic
       execution_mode: wait
       caller: dual-review-loop
       scope:
         type: working-tree
       meta_review: false
4. Read the dual-review synthesis brief. Save it verbatim to: \($brief)
5. Apply auto-fixes per policy:
   - Every item under \"## ✅ Accept — 양쪽 독립 합치\" (Tier 1)
   - Items under \"## ✅ Accept — 단일 리뷰어, 기술적으로 타당\" with Severity ≥ Important
   - Skip Minor items (log to commit footer)
   - If \"## Open Questions\" non-empty: STOP, report to user. Do NOT continue.
6. Re-verify (re-run task tests / verify command)
7. Flip the plan checkbox \"- [ ]\" → \"- [x]\" for the task you just completed.
8. Atomic commit: code changes + plan checkbox flip + deferred-minor footer.
9. After commit lands: delete the in-flight marker (rm \($inflight)). This signals the hook that this iter is done.
10. Stop. The hook will re-fire for the next iter or terminate naturally.

Do NOT manually edit .claude/dual-review-loop.state.json — the hook owns it.
To cancel: rm .claude/dual-review-loop.state.json (or run /dual-review-loop:cancel-loop)."')
    SYSTEM_MSG="dual-review-loop plan iter ${NEXT_ITER}/${MAX_ITERATIONS}"
    ;;
  task)
    REASON=$(jq -nr \
      --argjson iter "$NEXT_ITER" \
      --argjson max "$MAX_ITERATIONS" \
      --argjson max_files "$MAX_FILES" \
      --argjson max_loc "$MAX_LOC" \
      --argjson max_reviews "$MAX_REVIEWS" \
      --arg task "$TASK_DESCRIPTION" \
      --arg log "$TASK_LOG_PATH" \
      --arg brief "$NEXT_BRIEF_PATH" \
      --arg inflight "$INFLIGHT_FILE" '
"[dual-review-loop task iter \($iter)/\($max)]

Task: \($task)

Process exactly ONE next concrete sub-step that advances this task:

1. Decide one next sub-step — bias toward smaller, reviewable units (single file / single concept). If the task is now complete, do NOT invent more work; run /dual-review-loop:cancel-loop instead.
2. Execute it (make code changes, run tests, etc.)
3. Invoke the dual-review skill programmatically. Include this block in your dispatch prompt:
     dual-review-invocation:
       mode: programmatic
       execution_mode: wait
       caller: dual-review-loop
       scope:
         type: working-tree
       meta_review: false
4. Read the dual-review synthesis brief. Save it verbatim to: \($brief)
5. Apply auto-fixes per policy:
   - Every item under \"## ✅ Accept — 양쪽 독립 합치\" (Tier 1)
   - Items under \"## ✅ Accept — 단일 리뷰어, 기술적으로 타당\" with Severity ≥ Important
   - Skip Minor items (log to commit footer or task log)
   - If \"## Open Questions\" non-empty: STOP, report to user. Do NOT continue.
6. Re-verify (re-run task tests / verify command)
7. Append an iteration entry to the task log: \($log)
8. Atomic commit: code changes + task log append + deferred-minor footer.
9. After commit lands: delete the in-flight marker (rm \($inflight)).
10. Stop. The hook will re-fire for the next iter or terminate naturally.

Budget caps (hook gates): max_files=\($max_files), max_loc=\($max_loc), max_reviews=\($max_reviews). Going over any → loop ends.

Do NOT manually edit .claude/dual-review-loop.state.json — the hook owns iteration/timestamp fields.
To cancel: rm .claude/dual-review-loop.state.json (or run /dual-review-loop:cancel-loop)."')
    SYSTEM_MSG="dual-review-loop task iter ${NEXT_ITER}/${MAX_ITERATIONS}"
    ;;
esac

jq -n --arg r "$REASON" --arg s "$SYSTEM_MSG" \
  '{"decision":"block","reason":$r,"systemMessage":$s}' 2>/dev/null || \
  fail_open "final JSON emit failed"

# Release lock; inflight stays until Claude removes it
release_lock
exit 0
