#!/usr/bin/env bash
# The terminal path that runs without jq.
#
# This file used to open by calling it "the one terminal path that cannot carry a
# message", because fail_open builds its systemMessage with jq. That was wrong,
# and dual review said so: only the REASON string needs jq to interpolate. The
# fallback message is a constant, and a static systemMessage via bare printf was
# already proven elsewhere in the hook. It matters because this path also deletes
# the state file — a transient PATH glitch used to destroy a loop with no output
# at all.
#
# So the bar here is now higher than "valid JSON": empty stdout hangs the turn,
# malformed JSON cannot be parsed, and a bare approve leaves the user with a
# deleted loop and no idea why.
#
# ⚠️ A state file is required. Gate 0 ("state file missing") precedes the jq gate,
# so without one this test exits at Gate 0 and proves nothing about jq at all —
# an earlier draft did exactly that and passed against a hook with the jq gate
# deleted outright. The log assertion below is what makes that impossible: it
# fails unless FAIL-OPEN actually ran.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to BUILD the fixture"; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/drl-nojq.XXXXXX") || { echo "FATAL: mktemp"; exit 2; }
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
jq -n --arg plan "$t/plan.md" --arg base "$base" --argjson now "$now" \
  '{schema:"v2",mode:"plan",active:true,plan_path:$plan,iteration:1,
    max_iterations:20,max_minutes:0,max_files:999999,max_loc:999999,
    max_reviews:999999,session_id:"s",
    started_at_epoch:$now,last_iter_at_epoch:$now,
    last_injected_at_epoch:$now,last_injected_iter:0,
    started_at_sha:$base,inflight_base_sha:$base,
    last_brief_path:"",reviews_baseline:0}' \
  > "$t/.claude/dual-review-loop.state.json"

# A PATH with everything the hook uses EXCEPT jq. Listing only what it needs
# would make this fixture drift as the hook changes; symlinking the tools it
# actually calls keeps the one removal deliberate.
mkdir -p "$t/bin"
for c in awk bash basename cat date dirname env find git grep head ls mkdir \
         mktemp mv printf rm rmdir sed sort tail tr uniq wc; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$t/bin/$c"
done

out=$(printf '{"session_id":"s","transcript_path":"","hook_event_name":"Stop"}' \
      | (cd "$t" && PATH="$t/bin" bash "$HOOK" 2>/dev/null))
rc=$?
logline=$(tail -1 "$t/.claude/dual-review-loop.log" 2>/dev/null || echo "")
rm -rf "$t"

fail=0
echo "== jq missing =="

# The guard that makes the rest mean anything: prove we reached the jq gate.
case "$logline" in
  *"jq not on PATH"*) printf '  ✓ %-34s\n' "reached the jq gate" ;;
  *) printf '  ✗ %-34s log=[%s]\n' "reached the jq gate" "$logline"; fail=1 ;;
esac

[ -n "$out" ] \
  && printf '  ✓ %-34s\n' "stdout is non-empty" \
  || { printf '  ✗ %-34s the turn would hang\n' "stdout is non-empty"; fail=1; }

case "$out" in
  *'"decision"'*'"approve"'*) printf '  ✓ %-34s\n' "emits an approve decision" ;;
  *) printf '  ✗ %-34s got=[%s]\n' "emits an approve decision" "$out"; fail=1 ;;
esac

[ "$rc" -eq 0 ] \
  && printf '  ✓ %-34s\n' "hook exits 0" \
  || { printf '  ✗ %-34s got=%s\n' "hook exits 0" "$rc"; fail=1; }

# The assertion this file was missing. Without it the fallback can lose its
# message and every other check here stays green — measured.
msg=$(printf '%s' "$out" | sed -n 's/.*"systemMessage":"\([^"]*\)".*/\1/p')
[ -n "$msg" ] \
  && printf '  ✓ %-34s\n' "carries a user-facing message" \
  || { printf '  ✗ %-34s got=[%s] — this path DELETES the state file, so a bare approve loses the loop silently\n' "carries a user-facing message" "$out"; fail=1; }

echo ""
[ "$fail" -eq 0 ] && echo "== jq missing: 5 passed, 0 failed ==" || echo "== jq missing: FAILED =="
exit "$fail"
