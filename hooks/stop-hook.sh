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

LOG_FILE=".claude/dual-review-loop.log"
STATE_FILE=".claude/dual-review-loop.state.json"
LOCK_DIR=".claude/dual-review-loop.lock"
INFLIGHT_FILE=".claude/dual-review-loop.inflight"
REVIEWS_DIR=".claude/reviews"
IDLE_TIMEOUT_SECONDS=$((24 * 3600))
PHANTOM_GRACE_SECONDS=600   # if hook fires within 10min of last inject, assume continuation
# v1: plan-mode only (legacy). v2: adds `mode` field + cumulative gates +
# task mode. Both accepted so v1 in-flight loops do not break when the hook is
# upgraded ahead of the command (codex dual review high #2 — atomic migration).
SCHEMA_VERSIONS_OK="v1 v2"

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE" 2>/dev/null
}

approve() {
  printf '{"decision":"approve"}\n'
  # release lock if we hold it
  rmdir "$LOCK_DIR" 2>/dev/null || true
  exit 0
}

# Cleanup state + approve (terminal: loop ends here)
cleanup_and_approve() {
  log "$1"
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null || true
  printf '{"decision":"approve"}\n'
  exit 0
}

# Soft pause: do not inject this turn, but keep state for user-driven resume
soft_pause() {
  log "SOFT-PAUSE: $1 (state preserved)"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  printf '{"decision":"approve"}\n'
  exit 0
}

# Hard fail-open: error path, clean everything
fail_open() {
  log "FAIL-OPEN: $1"
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null || true
  printf '{"decision":"approve"}\n'
  exit 0
}

trap 'log "ERR trap fired (line $LINENO)"; rm -f "$INFLIGHT_FILE" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

HOOK_INPUT=$(cat 2>/dev/null || echo "")

# Gate 0: state file exists?
[ -f "$STATE_FILE" ] || approve

# Gate 0.5: jq available?
command -v jq >/dev/null 2>&1 || fail_open "jq not on PATH"

# Gate 12 (early): acquire lock via mkdir (atomic)
mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "lock held by another hook instance; soft-pause"
  soft_pause "lock contention"
fi

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
MODE=$(jq -r '.mode // "plan"' "$STATE_FILE")
MAX_FILES=$(jq -r '.max_files // 999999' "$STATE_FILE")
MAX_LOC=$(jq -r '.max_loc // 999999' "$STATE_FILE")
MAX_REVIEWS=$(jq -r '.max_reviews // 999999' "$STATE_FILE")
CUM_FILES=$(jq -r '.cum_files_changed // 0' "$STATE_FILE")
CUM_LOC=$(jq -r '.cum_loc_changed // 0' "$STATE_FILE")
CUM_REVIEWS=$(jq -r '.cum_reviews // 0' "$STATE_FILE")
CONSEC_FAIL=$(jq -r '.consecutive_same_failure // 0' "$STATE_FILE")

NOW_EPOCH=$(date +%s)

# Gate 2: schema (accept any version in SCHEMA_VERSIONS_OK)
case " $SCHEMA_VERSIONS_OK " in
  *" $SCHEMA "*) ;;
  *) fail_open "schema mismatch (got=$SCHEMA expected one of: $SCHEMA_VERSIONS_OK)" ;;
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
# If we've already injected at least once, the previous user-turn must contain our sentinel.
# Sentinel: "[dual-review-loop iter <N>" — appears at top of every injection.
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
  # Strategy B: transcript sentinel check (more reliable when available)
  if [ "$CONTINUATION" -eq 0 ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    if grep -qF "[dual-review-loop iter $LAST_INJECTED_ITER" "$TRANSCRIPT_PATH" 2>/dev/null; then
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

# Gate 7: in-flight marker — previous iter not yet finalized
if [ -f "$INFLIGHT_FILE" ]; then
  INFLIGHT_ITER=$(cat "$INFLIGHT_FILE" 2>/dev/null || echo "?")
  log "in-flight marker present (iter=$INFLIGHT_ITER) — previous iter incomplete, fail-open without iter++"
  # Keep state; just don't inject. Marker stays so a debugger can see it.
  rmdir "$LOCK_DIR" 2>/dev/null || true
  printf '{"decision":"approve","systemMessage":"dual-review-loop: previous iter (%s) still in-flight; not advancing"}\n' "$INFLIGHT_ITER"
  exit 0
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

# Gates 10c-f: cumulative caps (v2; v1 state defaults to 999999/0 so no-op).
if [ "$CUM_FILES" -ge "$MAX_FILES" ]; then
  cleanup_and_approve "max_files reached ($CUM_FILES >= $MAX_FILES)"
fi
if [ "$CUM_LOC" -ge "$MAX_LOC" ]; then
  cleanup_and_approve "max_loc reached ($CUM_LOC >= $MAX_LOC)"
fi
if [ "$CUM_REVIEWS" -ge "$MAX_REVIEWS" ]; then
  cleanup_and_approve "max_reviews reached ($CUM_REVIEWS >= $MAX_REVIEWS)"
fi
if [ "$CONSEC_FAIL" -ge 2 ]; then
  cleanup_and_approve "same verify failure $CONSEC_FAIL times in a row"
fi

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

# Atomic state update — hook owns ALL state fields
TEMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXX" 2>/dev/null)" || fail_open "mktemp failed"
jq --argjson next "$NEXT_ITER" \
   --argjson now "$NOW_EPOCH" \
   --arg brief "$NEXT_BRIEF_PATH" \
   '.iteration = $next
    | .last_iter_at_epoch = $now
    | .last_injected_at_epoch = $now
    | .last_injected_iter = $next
    | .last_brief_path = $brief' \
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
9. Update state cumulative counters (cum_files_changed / cum_loc_changed / cum_reviews / consecutive_same_failure) BEFORE this hook re-fires, otherwise budget caps cannot fire. Use jq temp+mv on .claude/dual-review-loop.state.json.
10. After commit lands: delete the in-flight marker (rm \($inflight)).
11. Stop. The hook will re-fire for the next iter or terminate naturally.

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
rmdir "$LOCK_DIR" 2>/dev/null || true
exit 0
