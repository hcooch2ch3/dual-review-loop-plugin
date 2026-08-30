#!/usr/bin/env bash
# Gate 11's transcript fallback — the arm the gate matrix cannot reach.
#
# observe() hardcodes transcript_path:"" (gate-matrix.test.sh), so the branch that
# runs when last_brief_path is empty has never been executed by any test. Both
# arms now share oq_first_item; this drives the hook with a transcript and no
# brief so the sharing is exercised rather than asserted.
#
# Scope, stated honestly: this proves the fallback classifies correctly. It does
# NOT prove the two arms are the same code — it would pass against two identical
# copies too. What it buys is that the fallback is no longer untested at all.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

fail=0

run_case() {  # $1=label  $2=assistant text  $3=expect STOP|ADVANCE
  local t base now tr out dec want
  t=$(mktemp -d "${TMPDIR:-/tmp}/drl-tr.XXXXXX") || { echo "FATAL: mktemp"; exit 2; }
  (
    set -e
    cd "$t"
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '.claude/\n' > .gitignore
    printf '# plan\n\n- [ ] do something\n' > plan.md
    git add -A
    git commit -qm initial
    mkdir -p .claude
  ) || { echo "FATAL: setup failed"; exit 2; }

  base=$(git -C "$t" rev-parse HEAD)
  now=$(date +%s)
  tr="$t/transcript.jsonl"
  # One assistant line, shaped the way the hook's jq filter expects.
  jq -cn --arg txt "$2" \
    '{message:{role:"assistant",content:[{type:"text",text:$txt}]}}' > "$tr"

  # last_brief_path empty is what routes execution to the fallback arm.
  jq -n --arg plan "$t/plan.md" --arg base "$base" --argjson now "$now" \
    '{schema:"v2",mode:"plan",active:true,plan_path:$plan,iteration:1,
      max_iterations:20,max_minutes:0,max_files:999999,max_loc:999999,
      max_reviews:999999,session_id:"test-session",
      started_at_epoch:$now,last_iter_at_epoch:$now,
      last_injected_at_epoch:$now,last_injected_iter:0,
      started_at_sha:$base,inflight_base_sha:$base,
      last_brief_path:"",reviews_baseline:0}' \
    > "$t/.claude/dual-review-loop.state.json"

  out=$(jq -cn --arg tr "$tr" \
          '{session_id:"test-session",transcript_path:$tr,hook_event_name:"Stop"}' \
        | (cd "$t" && bash "$HOOK" 2>/dev/null))
  dec=$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)
  [ "$3" = "STOP" ] && want=approve || want=block

  if [ "$dec" = "$want" ]; then
    printf '  ✓ %-26s decision=%s\n' "$1" "$dec"
  else
    printf '  ✗ %-26s decision=%s want=%s\n' "$1" "$dec" "$want"
    fail=1
  fi
  rm -rf "$t"
}

echo "== Gate 11 transcript fallback =="

run_case "real-question"  '## Open Questions
- a real question' STOP

run_case "no-section"     '## Findings
- nothing blocking here' ADVANCE

run_case "empty-section"  '## Open Questions

## Next
- not a question' ADVANCE

echo ""
if [ "$fail" -eq 0 ]; then
  echo "== transcript arm: 3 passed, 0 failed =="
else
  echo "== transcript arm: FAILED =="
fi
exit "$fail"
