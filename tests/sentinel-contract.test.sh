#!/usr/bin/env bash
# dual-review-loop — injected-prompt contract (sentinel format + token blacklist)
#
# Run: bash tests/sentinel-contract.test.sh
#
# WHY THIS FILE EXISTS
# hooks/stop-hook.sh carries this comment above its prompt builders:
#
#   "IMPORTANT: task prompts must NOT contain the token "ralph" / "RALPH" ...
#    Sentinel format is "[dual-review-loop iter N/M]" (plan) or
#    "[dual-review-loop task iter N/M]" (task); a token-blacklist regression
#    test pins this."
#
# That test did not exist. `grep -rn 'ralph\|blacklist' tests/` returned nothing,
# so the comment asserted a guarantee nothing enforced. This file is that test.
#
# It is load-bearing for two separate reasons:
#   1. Gate 5 Strategy B greps the transcript for the sentinel. The string only
#      appears there because it is the first line of the injected prompt. Break
#      the format and every real loop soft-pauses after iter 1 — silently, with
#      no error, on the path the field logs show is the normal rhythm.
#   2. Planned work rewrites both prompt literals wholesale. A reformatted
#      header (brackets dropped, wording changed, moved below a preamble) kills
#      the only recovery path out of a Gate 7 pause.
#
# It is also the only coverage of TASK mode anywhere in the suite; every other
# fixture is plan mode.

set -u
# LC_ALL is applied per command, never exported — the hook inherits our
# environment and pins no locale of its own, so exporting would run the subject
# under test in a locale its users do not have. See gate-matrix.test.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }

# NOTE on the subshell: it must NOT be the left operand of `||`. Bash suppresses
# errexit for any command in an AND-OR list other than the last, INCLUDING a
# subshell that sets `set -e` itself. Measured: `( set -e; false; echo X ) || \
# return 1` prints X and returns 0 — a failed `git init` would be followed by a
# successful `mkdir` and setup would report success, handing the caller a
# non-repo directory. Run it standalone and inspect $? afterwards.
setup_repo() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-sentinel-$1.XXXXXX") || return 1
  (
    set -e
    cd "$tmp"
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '.claude/\n' > .gitignore
    printf '# plan\n\n- [ ] do something\n' > plan.md
    git add .gitignore plan.md
    git commit -qm initial
    mkdir -p .claude
  )
  rc=$?
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; return 1; }
  # Prove the fixture is what the caller expects before handing it over.
  git -C "$tmp" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  git -C "$tmp" rev-parse HEAD >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  echo "$tmp"
}

# Emit the injected prompt for one mode. Echoes the raw .reason string.
reason_for_mode() {
  local tmp=$1 mode=$2 now base
  now=$(date +%s); base=$(git -C "$tmp" rev-parse HEAD)
  jq -n --arg plan "$tmp/plan.md" --argjson now "$now" --arg base "$base" --arg mode "$mode" '{
    schema:"v2", mode:$mode, active:true, plan_path:$plan,
    task_description:"a free-form task for the task-mode prompt",
    task_log_path:"\($plan | sub("plan.md$";"tasklog.md"))",
    iteration:1, max_iterations:20, max_minutes:0,
    max_files:999999, max_loc:999999, max_reviews:999999,
    session_id:"test-session",
    started_at_epoch:$now, last_iter_at_epoch:$now,
    last_injected_at_epoch:$now, last_injected_iter:0,
    started_at_sha:$base, inflight_base_sha:$base,
    last_brief_path:"", reviews_baseline:0
  }' > "$tmp/.claude/dual-review-loop.state.json"
  printf '{"session_id":"test-session","transcript_path":"","hook_event_name":"Stop"}' \
    | (cd "$tmp" && bash "$HOOK" 2>/dev/null) | jq -r '.reason // ""' 2>/dev/null
}

echo "== injected-prompt contract =="

for mode in plan task; do
  t=$(setup_repo "$mode") || { fail "$mode: repo setup failed"; continue; }
  reason=$(reason_for_mode "$t" "$mode")

  if [ -z "$reason" ]; then
    fail "$mode: hook emitted no .reason (did it advance at all?)"
    rm -rf "$t"; continue
  fi

  # 1. First line must be the sentinel, in the exact shape Gate 5 greps for.
  #    The regex here mirrors SENTINEL_RE in the hook: mode-pinned, and the
  #    iteration digit must be terminated so "iter 1" cannot match "iter 10".
  first=$(printf '%s' "$reason" | sed -n '1p')
  case "$mode" in
    plan) want='^\[dual-review-loop iter [0-9]\{1,\}/[0-9]\{1,\}\]$' ;;
    task) want='^\[dual-review-loop task iter [0-9]\{1,\}/[0-9]\{1,\}\]$' ;;
  esac
  if printf '%s' "$first" | grep -q "$want"; then
    ok "$mode: first line is the Gate 5 sentinel — $first"
  else
    fail "$mode: first line does not match the sentinel Gate 5 greps: '$first'"
  fi

  # 2. The digit anchor must actually work: the sentinel for iteration N must
  #    match a search for N, and must NOT match a search for a longer number
  #    that merely starts with N (the "iter 1 vs iter 10" trap the hook's
  #    comment calls out). N is read from the emitted sentinel — the hook has
  #    already advanced 1 -> 2 by the time it injects, so hardcoding 1 here was
  #    wrong and this assertion caught it.
  n=$(printf '%s' "$first" | sed -n 's|.*iter \([0-9]\{1,\}\)/.*|\1|p')
  if [ -z "$n" ]; then
    fail "$mode: could not read the iteration number out of '$first'"
  else
    if printf '%s' "$first" | grep -qE "\[dual-review-loop( task)? iter ${n}([^0-9]|\$)"; then
      ok "$mode: digit-anchored match succeeds for its own iteration ($n)"
    else
      fail "$mode: digit-anchored search failed against its own sentinel (n=$n)"
    fi
    if printf '%s' "$first" | grep -qE "\[dual-review-loop( task)? iter ${n}9([^0-9]|\$)"; then
      fail "$mode: sentinel for iter $n also matches iter ${n}9 — anchor is broken"
    else
      ok "$mode: sentinel for iter $n does not match iter ${n}9"
    fi
  fi

  # 3. Token blacklist. The 'ralph' brand belongs to another plugin family whose
  #    Stop hook could cross-trigger on it.
  if printf '%s' "$reason" | grep -qi 'ralph'; then
    fail "$mode: prompt contains the forbidden token 'ralph'"
  else
    ok "$mode: prompt is free of the 'ralph' token"
  fi

  # 4. Mode cross-contamination: a plan prompt must not carry the task sentinel
  #    and vice versa, or Gate 5's mode pin silently matches the wrong loop.
  if [ "$mode" = plan ] && printf '%s' "$first" | grep -q 'task iter'; then
    fail "plan: prompt carries the task sentinel"
  elif [ "$mode" = task ] && ! printf '%s' "$first" | grep -q 'task iter'; then
    fail "task: prompt lacks the task sentinel"
  else
    ok "$mode: sentinel is mode-correct"
  fi

  # 5. The Open Questions enforcement literal must be present. Planned work
  #    edits it in both arms; dropping it from one lets the LLM run past a STOP
  #    condition in that mode only.
  # Matching the bare phrase was vacuous — a clause telling the model to IGNORE
  # Open Questions would have satisfied it. Require the mandatory instruction.
  if printf '%s' "$reason" | grep -q 'Open Questions" non-empty: STOP'; then
    ok "$mode: prompt carries the mandatory Open Questions STOP clause"
  else
    fail "$mode: prompt lost or weakened the Open Questions STOP clause"
  fi
  if printf '%s' "$reason" | grep -q 'Do NOT continue'; then
    ok "$mode: STOP clause still forbids continuing"
  else
    fail "$mode: STOP clause no longer forbids continuing"
  fi

  rm -rf "$t"
done

# ---------------------------------------------------------------------------
# ROUND TRIP — feed the emitted sentinel back through the REAL Gate 5.
#
# Everything above pins the PRODUCER (the emitted prompt) against a regex this
# file re-types itself. That is not the contract. The contract is that Gate 5
# Strategy B can find the sentinel in a transcript — and its `SENTINEL_RE` lives
# in the hook, not here. Measured: replacing the hook's literal with
# `\[XX-dual-review-loop…` left the entire suite GREEN, because no test in the
# repo ever passed a non-empty transcript_path. A hand-copied mirror cannot
# detect drift in the thing it mirrors.
#
# This also repairs the vacuous digit-anchor assertion above: testing `iter N`
# against a string this file built is provably true either way. The anchor only
# means something when the hook's own grep evaluates it.
# ---------------------------------------------------------------------------

roundtrip_state() {   # $1=tmp $2=injected_iter $3=age_seconds
  local tmp=$1 iter=$2 age=$3 now base
  now=$(date +%s); base=$(git -C "$tmp" rev-parse HEAD)
  jq -n --arg plan "$tmp/plan.md" --argjson now "$now" --arg base "$base" \
        --argjson iter "$iter" --argjson age "$age" '{
    schema:"v2", mode:"plan", active:true, plan_path:$plan,
    iteration:$iter, max_iterations:20, max_minutes:0,
    max_files:999999, max_loc:999999, max_reviews:999999,
    session_id:"test-session",
    started_at_epoch:($now-$age), last_iter_at_epoch:($now-$age),
    last_injected_at_epoch:($now-$age), last_injected_iter:$iter,
    started_at_sha:$base, inflight_base_sha:$base,
    last_brief_path:"", reviews_baseline:0
  }' > "$tmp/.claude/dual-review-loop.state.json"
}

fire_with_transcript() {   # $1=tmp $2=transcript_path -> echoes decision
  jq -n --arg tp "$2" '{session_id:"test-session", transcript_path:$tp, hook_event_name:"Stop"}' \
    | (cd "$1" && bash "$HOOK" 2>/dev/null) | jq -r '.decision // ""' 2>/dev/null
}

echo ""
echo "-- round trip through the hook's own SENTINEL_RE --"

t=$(setup_repo roundtrip) || { fail "roundtrip: repo setup failed"; t=""; }
if [ -n "$t" ]; then
  sentinel=$(reason_for_mode "$t" plan | sed -n '1p')
  n=$(printf '%s' "$sentinel" | sed -n 's|.*iter \([0-9]\{1,\}\)/.*|\1|p')
  # AGE must sit in the window where Strategy B alone decides:
  #   > PHANTOM_GRACE_SECONDS (600)  so Strategy A's time window cannot answer
  #   < IDLE_TIMEOUT_SECONDS (86400) so Gate 6 does not reap the state first.
  # The first draft used 100000 and the positive case failed — Gate 5 passed
  # and Gate 6 then killed the loop on idle, which reads exactly like a broken
  # consumer. Keep this inside both bounds.
  AGE=3600
  rm -f "$t/.claude/dual-review-loop.inflight"

  # positive: a transcript carrying this exact sentinel must resume the loop.
  printf 'noise\n%s\nmore noise\n' "$sentinel" > "$t/transcript.txt"
  roundtrip_state "$t" "$n" "$AGE"
  d=$(fire_with_transcript "$t" "$t/transcript.txt")
  if [ "$d" = "block" ]; then
    ok "round trip: hook's own SENTINEL_RE finds the emitted sentinel (iter $n)"
  else
    fail "round trip: hook did NOT recognise its own sentinel (decision=$d) — Gate 5 consumer is broken"
  fi
  rm -f "$t/.claude/dual-review-loop.inflight"

  # negative: iter N must not be satisfied by a longer number starting with N.
  # This exercises the real ([^0-9]|$) anchor rather than a copy of it.
  printf 'noise\n[dual-review-loop iter %s0/20]\n' "$n" > "$t/transcript.txt"
  roundtrip_state "$t" "$n" "$AGE"
  d=$(fire_with_transcript "$t" "$t/transcript.txt")
  if [ "$d" = "approve" ]; then
    ok "round trip: iter ${n}0 in the transcript does not satisfy iter $n"
  else
    fail "round trip: digit anchor is broken in the hook — iter ${n}0 matched iter $n (decision=$d)"
  fi
  rm -f "$t/.claude/dual-review-loop.inflight"

  # negative: a task-mode sentinel must not satisfy a plan-mode loop.
  printf 'noise\n[dual-review-loop task iter %s/20]\n' "$n" > "$t/transcript.txt"
  roundtrip_state "$t" "$n" "$AGE"
  d=$(fire_with_transcript "$t" "$t/transcript.txt")
  if [ "$d" = "approve" ]; then
    ok "round trip: a task sentinel does not satisfy a plan loop (mode pin holds)"
  else
    fail "round trip: mode pin is broken — task sentinel resumed a plan loop (decision=$d)"
  fi

  rm -rf "$t"
fi

echo ""
echo "== sentinel contract: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
