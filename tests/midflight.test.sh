#!/usr/bin/env bash
# dual-review-loop — mid-flight upgrade contract
#
# Run: bash tests/midflight.test.sh
#
# THE CONTRACT
# A loop can be running when the hook is upgraded underneath it. Every change
# must leave an in-flight legacy state either WORKING or SAFELY STOPPED.
# A silent termination that deletes the user's state is forbidden.
#
# This repo has been burned by this twice — see the "atomic migration" comment
# in hooks/stop-hook.sh and the schema-drift entry in README.md. The rule was
# written down but never checked. This file checks it.
#
# These assertions are deliberately written BEFORE the planned changes land.
# Several pass trivially today; that is the point — they must STILL pass after
# an idle-GC is inserted and after new optional state fields are introduced.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }

setup_repo() {
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-midflight-$1.XXXXXX")
  (
    cd "$tmp" || exit 1
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '.claude/\n' > .gitignore
    printf '# plan\n\n- [ ] do something\n' > plan.md
    git add .gitignore plan.md
    git commit -qm initial
    mkdir -p .claude
  )
  echo "$tmp"
}

run_hook() {
  printf '{"session_id":"test-session","transcript_path":"","hook_event_name":"Stop"}' \
    | (cd "$1" && bash "$HOOK" 2>/dev/null)
}

decision()    { printf '%s' "$1" | jq -r '.decision // ""' 2>/dev/null; }
state_alive() { [ -f "$1/.claude/dual-review-loop.state.json" ] && echo Y || echo N; }

echo "== mid-flight upgrade contract =="

# ---- M1: v1 state (no mode / no cumulative caps / no SHAs) must still run ----
# v1 predates `mode`, the max_* fields and started_at_sha. The hook defaults
# mode to "plan" and the caps to Infinity, so a v1 loop must keep advancing.
t=$(setup_repo m1); now=$(date +%s)
jq -n --arg plan "$t/plan.md" --argjson now "$now" '{
  schema:"v1", active:true, plan_path:$plan,
  iteration:1, max_iterations:20, max_minutes:0,
  session_id:"test-session",
  started_at_epoch:$now, last_iter_at_epoch:$now,
  last_injected_at_epoch:$now, last_injected_iter:0,
  last_brief_path:""
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
if [ "$(decision "$out")" = "block" ]; then
  ok "M1 v1 state still advances (no silent termination)"
else
  fail "M1 v1 state did not advance: decision=$(decision "$out")"
fi
rm -rf "$t"

# ---- M2: v2 state advances (baseline) ----
t=$(setup_repo m2); now=$(date +%s); base=$(git -C "$t" rev-parse HEAD)
jq -n --arg plan "$t/plan.md" --argjson now "$now" --arg base "$base" '{
  schema:"v2", mode:"plan", active:true, plan_path:$plan,
  iteration:1, max_iterations:20, max_minutes:0,
  max_files:999999, max_loc:999999, max_reviews:999999,
  session_id:"test-session",
  started_at_epoch:$now, last_iter_at_epoch:$now,
  last_injected_at_epoch:$now, last_injected_iter:0,
  started_at_sha:$base, inflight_base_sha:$base,
  last_brief_path:"", reviews_baseline:0
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
[ "$(decision "$out")" = "block" ] \
  && ok "M2 v2 state advances (baseline)" \
  || fail "M2 v2 state did not advance: decision=$(decision "$out")"
rm -rf "$t"

# ---- M3: future OPTIONAL fields absent AND state is STALE -> still advances ----
# Releases B and C introduce last_seen_at_epoch and resume_token as additive
# optional fields. State written by an older command lacks them.
#
# The staleness matters and the first version of this case lacked it: with fresh
# timestamps M3 was byte-identical to M2 and therefore measured nothing. A wrong
# `last_seen_at_epoch // NOW` fallback (which would exempt every legacy state
# from reaping forever) and a wrong `// 0` fallback (which would reap every
# legacy state immediately) BOTH pass when the timestamps are current. 12h old
# is stale enough to separate them while staying inside the 24h idle timeout.
t=$(setup_repo m3); base=$(git -C "$t" rev-parse HEAD)
stale=$(( $(date +%s) - 12*3600 ))
jq -n --arg plan "$t/plan.md" --argjson stale "$stale" --arg base "$base" '{
  schema:"v2", mode:"plan", active:true, plan_path:$plan,
  iteration:1, max_iterations:20, max_minutes:0,
  max_files:999999, max_loc:999999, max_reviews:999999,
  session_id:"test-session",
  started_at_epoch:$stale, last_iter_at_epoch:$stale,
  last_injected_at_epoch:$stale, last_injected_iter:0,
  started_at_sha:$base, inflight_base_sha:$base,
  last_brief_path:"", reviews_baseline:0
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
if [ "$(decision "$out")" = "block" ] && [ "$(state_alive "$t")" = "Y" ]; then
  ok "M3 stale legacy state, no optional fields -> advances, not reaped"
else
  fail "M3 stale legacy state broke: decision=$(decision "$out") state=$(state_alive "$t")"
fi
rm -rf "$t"

# ---- M4: FUTURE schema must be PRESERVED, not deleted ----
# Gate 2 deliberately soft-pauses instead of failing open, so a user who
# downgrades the hook does not lose a running loop. README documents this.
t=$(setup_repo m4); now=$(date +%s)
jq -n --arg plan "$t/plan.md" --argjson now "$now" '{
  schema:"v9", mode:"plan", active:true, plan_path:$plan,
  iteration:3, max_iterations:20, max_minutes:0,
  session_id:"test-session",
  started_at_epoch:$now, last_iter_at_epoch:$now,
  last_injected_at_epoch:$now, last_injected_iter:0
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
if [ "$(decision "$out")" = "approve" ] && [ "$(state_alive "$t")" = "Y" ]; then
  ok "M4 future schema: state PRESERVED (soft-pause, not deleted)"
else
  fail "M4 future schema lost state: decision=$(decision "$out") state=$(state_alive "$t")"
fi
rm -rf "$t"

# ---- M5: future schema with RENAMED timestamp fields must NOT be reaped ----
# This is the trap an idle-GC placed before Gate 2 would fall into: every
# timestamp read uses `// 0`, so unknown field names resolve to epoch 0 and
# `now - 0 > IDLE_TIMEOUT` is ALWAYS true. A GC there would delete every
# future-schema state on first sight. Release B must keep this passing.
t=$(setup_repo m5)
jq -n --arg plan "$t/plan.md" '{
  schema:"v9", mode:"plan", active:true, plan_path:$plan,
  iteration:3, max_iterations:20, max_minutes:0,
  session_id:"test-session",
  lastActivityAt:"2026-08-26T00:00:00Z",
  startedAt:"2026-08-26T00:00:00Z"
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
if [ "$(state_alive "$t")" = "Y" ]; then
  ok "M5 future schema w/ renamed timestamps: NOT reaped"
else
  fail "M5 future schema was deleted — GC ran before schema acceptance"
fi
rm -rf "$t"

# ---- M6: lowering a hook FALLBACK constant must not execute a running loop ----
# State written by an older command may omit max_iterations entirely. If a
# future change lowers the hook's `// 20` fallback to a smaller number, every
# in-flight loop already past it is terminated AND its state deleted on the
# next fire. iteration=9 here is above the 8 that was once proposed.
t=$(setup_repo m6); now=$(date +%s); base=$(git -C "$t" rev-parse HEAD)
jq -n --arg plan "$t/plan.md" --argjson now "$now" --arg base "$base" '{
  schema:"v2", mode:"plan", active:true, plan_path:$plan,
  iteration:9, max_minutes:0,
  session_id:"test-session",
  started_at_epoch:$now, last_iter_at_epoch:$now,
  last_injected_at_epoch:$now, last_injected_iter:0,
  started_at_sha:$base, inflight_base_sha:$base,
  last_brief_path:"", reviews_baseline:0
}' > "$t/.claude/dual-review-loop.state.json"
out=$(run_hook "$t")
if [ "$(decision "$out")" = "block" ]; then
  ok "M6 iteration=9 with absent max_iterations -> not terminated"
else
  fail "M6 in-flight loop at iteration 9 was terminated: decision=$(decision "$out") state=$(state_alive "$t")"
fi
rm -rf "$t"

echo ""
echo "== mid-flight: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
