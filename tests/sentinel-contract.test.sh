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
export LC_ALL=C
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }

setup_repo() {
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-sentinel-$1.XXXXXX") || return 1
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
  ) || return 1
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
  if printf '%s' "$reason" | grep -q 'Open Questions'; then
    ok "$mode: prompt carries the Open Questions enforcement clause"
  else
    fail "$mode: prompt lost the Open Questions enforcement clause"
  fi

  rm -rf "$t"
done

echo ""
echo "== sentinel contract: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
