#!/usr/bin/env bash
# Regression test for Gate 7 (in-flight marker) completion detection.
#
# Bug history: the in-flight marker is hook-created (stop-hook.sh) but was
# historically LLM-cleared (prompt step 9 `rm inflight`). When the LLM never
# reached that step — plan mode blocking the commit being the canonical case,
# but also early stops / errors / forgetfulness — the marker stayed and Gate 7
# became a permanent dead-end (neither advance nor re-inject) → frozen loop.
#
# Fix: UNION completion detection. Advance when the marker is absent (LLM
# cleared it, incl. legitimate no-op iters) OR the hook can prove via git that
# the iter's commit landed (HEAD moved forward past inflight_base_sha). Only
# soft-pause when the marker is present AND no commit landed.
#
# These cases pin that behavior:
#   T1 no-commit   : marker present, HEAD == base  → approve, NO advance (soft-pause)
#   T2 commit-landed: marker present, HEAD moved fwd → advance (decision:block), marker cleared
#   T3 marker-absent: no marker                     → advance (decision:block)
#
# Run: bash tests/inflight-gate7.test.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }

# Build an isolated temp git repo with a primed dual-review-loop state.
# Args: $1 = scenario tag (used for tmpdir name only)
# Echoes the tmpdir path.
setup_repo() {
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-gate7-$1.XXXXXX")
  (
    cd "$tmp" || exit 1
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '# plan\n\n- [ ] do something\n' > plan.md
    git add plan.md
    git commit -qm "initial"
    mkdir -p .claude
  )
  echo "$tmp"
}

# Write state.json into $1 with base_sha=$2 and (optional) inflight iter marker=$3.
# All gates 0-6 are primed to PASS so execution reaches Gate 7:
#   schema v2 / active / session match / recent inject (continuation strategy A)
write_state() {
  local tmp=$1 base_sha=$2 marker_iter=${3:-}
  local now; now=$(date +%s)
  jq -n \
    --arg plan "$tmp/plan.md" \
    --argjson now "$now" \
    --arg base "$base_sha" \
    '{
      schema:"v2", mode:"plan", active:true,
      plan_path:$plan,
      iteration:1, max_iterations:20, max_minutes:0,
      max_files:999999, max_loc:999999, max_reviews:999999,
      session_id:"test-session",
      started_at_epoch:$now, last_iter_at_epoch:$now,
      last_injected_at_epoch:$now, last_injected_iter:1,
      started_at_sha:$base, inflight_base_sha:$base,
      last_brief_path:"", reviews_baseline:0
    }' > "$tmp/.claude/dual-review-loop.state.json"
  if [ -n "$marker_iter" ]; then
    printf '%s\n' "$marker_iter" > "$tmp/.claude/dual-review-loop.inflight"
  fi
}

run_hook() {
  local tmp=$1
  printf '{"session_id":"test-session","transcript_path":"","hook_event_name":"Stop"}' \
    | (cd "$tmp" && bash "$HOOK" 2>/dev/null)
}

decision() { printf '%s' "$1" | jq -r '.decision // ""' 2>/dev/null; }

echo "== Gate 7 in-flight completion detection =="

# ---- T1: marker present, no commit since base → soft-pause (no advance) ----
echo "T1 no-commit (marker present, HEAD == base):"
tmp=$(setup_repo t1)
head=$(cd "$tmp" && git rev-parse HEAD)
write_state "$tmp" "$head" "1"        # base == current HEAD: no commit happened
out=$(run_hook "$tmp")
d=$(decision "$out")
[ "$d" = "approve" ] && ok "decision=approve (did not advance)" || fail "expected approve, got '$d' :: $out"
[ -f "$tmp/.claude/dual-review-loop.inflight" ] && ok "marker preserved" || fail "marker should be preserved on no-commit"
rm -rf "$tmp"

# ---- T2: marker present, a commit landed since base → advance + clear marker ----
echo "T2 commit-landed (marker present, HEAD moved forward):"
tmp=$(setup_repo t2)
base=$(cd "$tmp" && git rev-parse HEAD)
write_state "$tmp" "$base" "1"
( cd "$tmp" && echo "more" >> plan.md && git commit -qam "iter 1 work" )  # HEAD moves past base
out=$(run_hook "$tmp")
d=$(decision "$out")
[ "$d" = "block" ] && ok "decision=block (advanced to next iter)" || fail "expected block (advance), got '$d' :: $out"
# On advance the hook re-writes the marker for the NEW iter (2), not delete it:
# the stale iter-1 marker must not survive unchanged.
marker_now=$(cat "$tmp/.claude/dual-review-loop.inflight" 2>/dev/null || echo "")
[ "$marker_now" = "2" ] && ok "marker rolled to next iter (2)" || fail "marker should hold next iter '2', got '$marker_now'"
rm -rf "$tmp"

# ---- T3: marker absent → advance (normal LLM-rm / no-op path) ----
echo "T3 marker-absent:"
tmp=$(setup_repo t3)
head=$(cd "$tmp" && git rev-parse HEAD)
write_state "$tmp" "$head" ""         # no marker file
out=$(run_hook "$tmp")
d=$(decision "$out")
[ "$d" = "block" ] && ok "decision=block (advanced)" || fail "expected block, got '$d' :: $out"
rm -rf "$tmp"

# ---- T4: empty inflight_base_sha (v1/legacy/non-git) + marker → soft-pause ----
# Git backstop disarmed → must NOT false-advance; marker preserved.
echo "T4 empty-base (legacy/non-git, marker present):"
tmp=$(setup_repo t4)
write_state "$tmp" "" "1"             # base_sha empty even though repo has commits
out=$(run_hook "$tmp")
d=$(decision "$out")
[ "$d" = "approve" ] && ok "decision=approve (no false advance without base)" || fail "expected approve, got '$d' :: $out"
[ -f "$tmp/.claude/dual-review-loop.inflight" ] && ok "marker preserved" || fail "marker should be preserved"
rm -rf "$tmp"

# ---- T5: HEAD moved BACKWARD (reset/checkout) + marker → soft-pause ----
# base is a descendant of HEAD (not an ancestor) → is-ancestor false → no advance.
echo "T5 head-moved-backward (marker present):"
tmp=$(setup_repo t5)
a=$(cd "$tmp" && git rev-parse HEAD)                       # commit A
( cd "$tmp" && echo x >> plan.md && git commit -qam "B" )  # commit B (descendant of A)
b=$(cd "$tmp" && git rev-parse HEAD)
write_state "$tmp" "$b" "1"                                # base = B
( cd "$tmp" && git reset --hard -q "$a" )                  # HEAD back to A; B is NOT ancestor of A
out=$(run_hook "$tmp")
d=$(decision "$out")
[ "$d" = "approve" ] && ok "decision=approve (backward move not treated as completion)" || fail "expected approve, got '$d' :: $out"
rm -rf "$tmp"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
