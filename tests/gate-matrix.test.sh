#!/usr/bin/env bash
# dual-review-loop — gate regression matrix (golden file)
#
# Run: bash tests/gate-matrix.test.sh            # compare against golden
#      bash tests/gate-matrix.test.sh --update    # (re)write the golden
#
# WHY THIS EXISTS
# The only pre-existing test covers Gate 7. Gates 0-6 and 8-12 had no coverage,
# yet planned work reorders them (inserting an idle-GC between Gate 2 and Gate 4).
# Reordering is the change most likely to break an untested gate. This file
# freezes every gate's observable behaviour BEFORE such a change, so the diff
# afterwards shows only the intended delta.
#
# WHY SIX OBSERVED FIELDS AND NOT `.decision`
# Measured: Gates 0, 1, 3, 4 and 12 all emit exactly {"decision":"approve"}.
# Keying a golden on decision alone cannot tell them apart — a regression that
# made Gate 4 (preserve state) behave like Gate 3 (delete state) would produce
# an empty diff. The discriminators are the log line (distinct per gate) and
# whether the state file / in-flight marker survived.
#
# Golden record: label | decision | systemMessage | state | marker | log_tail
# Machine-specific values (tmpdir paths, timestamps, home dir) are normalised.

set -u

# Pin collation and locale-sensitive tool behaviour. glibc gives punctuation
# near-ignored primary weight under a UTF-8 locale, so `gate10-…` vs
# `gate10b-…` can sort in a DIFFERENT order than under C — the golden would
# then diff on Linux with no semantic change, which trains reviewers to
# reflexively --update. BSD collation happens to match C, which is exactly why
# macOS-only testing cannot see this.
export LC_ALL=C

# Make the throwaway git repos hermetic. Without this the developer's global
# config leaks in: `core.excludesFile` containing .claude/ silently flips the
# gate09b row, `commit.gpgsign` can block on pinentry and hang the suite, and
# `core.hooksPath` runs their pre-commit hooks inside our temp repo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
GOLDEN="$(cd "$(dirname "$0")" && pwd)/fixtures/gate-matrix.golden"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

ACTUAL=$(mktemp "${TMPDIR:-/tmp}/drl-matrix.XXXXXX")
trap 'rm -f "$ACTUAL"' EXIT

# ---------------------------------------------------------------- helpers

# $2 = "gitignore" to add `.claude/` to .gitignore (keeps the tree clean, which
# Gate 9's completion path requires). Omit it to reproduce a user repo that
# never gitignored the plugin's own files — the plugin's state file and briefs
# then keep the tree permanently dirty. Both cases are golden rows.
setup_repo() {
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-matrix-$1.XXXXXX")
  (
    cd "$tmp" || exit 1
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '# plan\n\n- [ ] do something\n' > plan.md
    if [ "${2:-}" = "gitignore" ]; then
      printf '.claude/\n' > .gitignore
      git add .gitignore
    fi
    git add plan.md
    git commit -qm initial
    mkdir -p .claude
  )
  echo "$tmp"
}

# Fully-primed state: every gate before the one under test is set to PASS.
# Callers override single fields with jq to steer execution to one gate.
base_state() {
  local tmp=$1 now; now=$(date +%s)
  local base; base=$(git -C "$tmp" rev-parse HEAD)
  jq -n \
    --arg plan "$tmp/plan.md" \
    --argjson now "$now" \
    --arg base "$base" \
    '{
      schema:"v2", mode:"plan", active:true,
      plan_path:$plan,
      iteration:1, max_iterations:20, max_minutes:0,
      max_files:999999, max_loc:999999, max_reviews:999999,
      session_id:"test-session",
      started_at_epoch:$now, last_iter_at_epoch:$now,
      last_injected_at_epoch:$now, last_injected_iter:0,
      started_at_sha:$base, inflight_base_sha:$base,
      last_brief_path:"", reviews_baseline:0
    }'
}

write_state() { printf '%s' "$1" > "$2/.claude/dual-review-loop.state.json"; }

# Normalise everything machine-specific so the golden is portable.
# Each of these bit us when the golden was first generated:
#   - tmpdir path: mktemp yields /var/folders/... but the hook resolves its root
#     via `git rev-parse --show-toplevel`, which returns the /private/var/...
#     realpath on macOS. Both spellings must be replaced.
#   - `gap=<seconds>`: derived from wall-clock, changes every second.
#   - commit SHAs: a fresh repo per run means a fresh SHA every run.
#   - `max_minutes reached (<elapsed>s ...)`: the test seeds started_at_epoch
#     relative to its OWN `date +%s`; the hook then takes its own reading. If a
#     second boundary falls between the two, elapsed shifts by one. Measured:
#     without this rule the suite failed 19 runs out of 20.
# Without these the comparison run could never pass.
norm() {
  local s=$1 tmp=$2 real=$3
  printf '%s' "$s" \
    | sed -e "s|$real|<TMP>|g" -e "s|$tmp|<TMP>|g" -e "s|$HOME|<HOME>|g" \
          -e 's|^\[[0-9TZ:-]*\] ||' \
          -e 's|gap=[0-9]*s|gap=<N>s|g' \
          -e 's|reached ([0-9]*s|reached (<N>s|g' \
          -e 's|(line [0-9]*)|(line <N>)|g' \
          -e 's|[0-9a-f]\{40\}|<SHA>|g' \
    | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//'
}

# Fingerprint the injected prompt instead of freezing it.
# The prompt is multi-KB; putting it in the golden would make every wording
# tweak an enormous diff and train reviewers to blind---update, destroying the
# signal. Two things about it are contractual and cheap to pin:
#   1. the first line, which is the sentinel Gate 5 Strategy B greps for. Break
#      its format and every real loop soft-pauses after iter 1, silently.
#   2. how many times the Open Questions enforcement literal appears. Release A
#      edits that literal in the hook's two prompt arms; dropping one is
#      otherwise invisible here.
reason_fingerprint() {
  local r=$1
  [ -n "$r" ] || { printf '%s' "-"; return; }
  local first count
  first=$(printf '%s' "$r" | sed -n '1p')
  count=$(printf '%s' "$r" | grep -c 'non-empty: STOP' || true)
  printf 'sentinel="%s" enforce=%s' "$first" "$count"
}

# Fire the hook once and emit one golden record.
observe() {
  local label=$1 tmp=$2
  local real; real=$(cd "$tmp" && pwd -P)
  : > "$tmp/.claude/dual-review-loop.log"
  local out
  out=$(printf '{"session_id":"test-session","transcript_path":"","hook_event_name":"Stop"}' \
        | (cd "$tmp" && bash "$HOOK" 2>/dev/null))
  local dec msg logline state marker active lock iters mk sf reason fp
  sf="$tmp/.claude/dual-review-loop.state.json"
  dec=$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)
  msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)
  fp=$(reason_fingerprint "$reason")
  logline=$(tail -1 "$tmp/.claude/dual-review-loop.log" 2>/dev/null || echo "")
  state=$([ -f "$sf" ] && echo Y || echo N)
  marker=$([ -f "$tmp/.claude/dual-review-loop.inflight" ] && echo Y || echo N)
  # lock survival. A hook that FAILED to acquire the lock must not delete it —
  # soft_pause()'s unconditional rmdir does exactly that today, so the loser of
  # the race removes the winner's lock and mutual exclusion is gone. Without
  # this column that defect is invisible; so is a lock leaked on an owner path.
  lock=$([ -d "$tmp/.claude/dual-review-loop.lock" ] && echo Y || echo N)
  # `active` is observed separately from file existence: a pause that DISARMS a
  # state leaves the file in place, so existence alone cannot see it.
  # iteration/last_injected_iter + marker contents catch a broken atomic state
  # update — dropping `.iteration = $next` still emits "iter 2" and writes a
  # marker, so output alone passes while state silently stays behind.
  if [ -f "$sf" ]; then
    active=$(jq -r 'if has("active") then (.active|tostring) else "-" end' "$sf" 2>/dev/null || echo "?")
    iters=$(jq -r '"\(.iteration // "-")/\(.last_injected_iter // "-")"' "$sf" 2>/dev/null || echo "?/?")
  else
    active="-"; iters="-/-"
  fi
  mk=$([ -f "$tmp/.claude/dual-review-loop.inflight" ] \
        && tr -d '\n' < "$tmp/.claude/dual-review-loop.inflight" || echo "-")
  printf '%-26s | %-7s | state=%s active=%-5s marker=%s(%s) lock=%s iter=%s | %s | %s | %s\n' \
    "$label" "$dec" "$state" "$active" "$marker" "$mk" "$lock" "$iters" \
    "$(norm "$fp" "$tmp" "$real")" \
    "$(norm "$msg" "$tmp" "$real")" "$(norm "$logline" "$tmp" "$real")" >> "$ACTUAL"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- cases

# Gate 0 — no state file at all
t=$(setup_repo g0); observe "gate00-no-state" "$t"

# Gate 1 — state file is not valid JSON
t=$(setup_repo g1); echo 'not json at all' > "$t/.claude/dual-review-loop.state.json"
observe "gate01-bad-json" "$t"

# Gate 2 — schema outside SCHEMA_VERSIONS_OK (must PRESERVE state)
t=$(setup_repo g2); write_state "$(base_state "$t" | jq '.schema="v9"')" "$t"
observe "gate02-schema-unknown" "$t"

# Gate 3 — active != true
t=$(setup_repo g3); write_state "$(base_state "$t" | jq '.active=false')" "$t"
observe "gate03-inactive" "$t"

# Gate 4 — hook session != state session (must PRESERVE state)
t=$(setup_repo g4); write_state "$(base_state "$t" | jq '.session_id="other-session"')" "$t"
observe "gate04-session-mismatch" "$t"

# Gate 5 — previously injected, no continuation signal (stale inject, no transcript)
t=$(setup_repo g5)
write_state "$(base_state "$t" | jq '.last_injected_iter=1 | .last_injected_at_epoch=1000000000')" "$t"
observe "gate05-no-continuation" "$t"

# Gate 6 — idle beyond IDLE_TIMEOUT (last_injected_iter=0 skips Gate 5)
t=$(setup_repo g6)
write_state "$(base_state "$t" | jq '.last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000')" "$t"
observe "gate06-idle-timeout" "$t"

# Gate 7 — in-flight marker present, HEAD unmoved from inflight_base_sha
t=$(setup_repo g7); write_state "$(base_state "$t")" "$t"
printf '1\n' > "$t/.claude/dual-review-loop.inflight"
observe "gate07-inflight-nocommit" "$t"

# Gate 8 — plan_path not absolute
t=$(setup_repo g8); write_state "$(base_state "$t" | jq '.plan_path="relative/plan.md"')" "$t"
observe "gate08-plan-relative" "$t"

# Gate 9a — no unfinished checkboxes AND a clean tree → completion.
# The gitignore matters: without it the plugin's own state file under .claude/
# leaves the tree dirty and this path is unreachable (see gate09b).
t=$(setup_repo g9a gitignore)
printf '# plan\n\n- [x] done\n' > "$t/plan.md"
(cd "$t" && git add plan.md && git commit -qm done)
write_state "$(base_state "$t")" "$t"
observe "gate09a-all-complete" "$t"

# Gate 9b — same, but the repo never gitignored .claude/, so the plugin's OWN
# state file keeps the tree dirty and completion is replaced by a soft-pause.
# This is the finish-line trap: it is not only briefs that dirty the tree.
t=$(setup_repo g9b)
printf '# plan\n\n- [x] done\n' > "$t/plan.md"
(cd "$t" && git add plan.md && git commit -qm done)
write_state "$(base_state "$t")" "$t"
observe "gate09b-dirty-blocks" "$t"

# Gate 9c — plan file lives OUTSIDE any git repo (the `/plan` default location).
# Gate 9's dirty check runs `git -C $(dirname "$PLAN_PATH")`, not against
# REPO_ROOT. When the plan is outside a repo that command fails, the check is
# SKIPPED, and completion is declared even though the real repo tree is dirty.
# Verified: without this row, rescoping PLAN_DIR to REPO_ROOT produces zero
# golden diff — i.e. the matrix could not see that fix land at all.
t=$(setup_repo g9c)                     # deliberately no gitignore -> dirty tree
outside=$(mktemp -d "${TMPDIR:-/tmp}/drl-matrix-outside.XXXXXX")
printf '# plan\n\n- [x] done\n' > "$outside/plan.md"
write_state "$(base_state "$t" | jq --arg p "$outside/plan.md" '.plan_path=$p')" "$t"
observe "gate09c-plan-outside-repo" "$t"
rm -rf "$outside"

# Gate 10 — iteration already at max_iterations
t=$(setup_repo g10); write_state "$(base_state "$t" | jq '.iteration=20')" "$t"
observe "gate10-max-iterations" "$t"

# Gate 10b — wall-clock cap exceeded
t=$(setup_repo g10b)
write_state "$(base_state "$t" | jq '.max_minutes=1 | .started_at_epoch=(.started_at_epoch-3600)')" "$t"
observe "gate10b-max-minutes" "$t"

# Gate 11 — previous brief carries Open Questions bullets
t=$(setup_repo g11); mkdir -p "$t/.claude/reviews"
printf '# brief\n\n## Open Questions\n- a real question\n' > "$t/.claude/reviews/iter-001.md"
write_state "$(base_state "$t" | jq --arg b "$t/.claude/reviews/iter-001.md" '.last_brief_path=$b')" "$t"
observe "gate11-open-questions" "$t"

# Gate 11 negatives — pin the POLARITY, not just that detection can succeed.
#
# Without these the only Gate 11 row is a canonical positive, which both the
# current broken awk AND a correct classifier satisfy. And the advance row sets
# last_brief_path:"" with transcript_path:"", so NEITHER awk arm runs on a
# passing row. Net effect: a rewritten regex that over-matches and fires on
# every brief still produces a fully green suite — the exact regression the
# Gate 11 work exists to prevent.
#
# Precision/recall over the labelled corpus belongs in gate11-openq.test.sh.
# These three rows only pin the I/O endpoints so a polarity flip shows up here.
brief() {   # $1=tmp  $2=heading  $3=bullet-line   -> echoes brief path
  mkdir -p "$1/.claude/reviews"
  printf '# brief\n\n%s\n%s\n' "$2" "$3" > "$1/.claude/reviews/iter-001.md"
  echo "$1/.claude/reviews/iter-001.md"
}

# 11n1 — "no blocker" placeholder bullet. TODAY: stops (the 77% false positive).
# AFTER the fix: must advance (decision=block).
t=$(setup_repo g11n1); b=$(brief "$t" '## Open Questions' '- 없음')
write_state "$(base_state "$t" | jq --arg b "$b" '.last_brief_path=$b')" "$t"
observe "gate11n1-none-bullet" "$t"

# 11n2 — real question under a `###` heading. TODAY: passes (false negative,
# the heading regex demands exactly `## `). AFTER the fix: must stop.
t=$(setup_repo g11n2); b=$(brief "$t" '### Open Questions' '- **Q1 — a real question**')
write_state "$(base_state "$t" | jq --arg b "$b" '.last_brief_path=$b')" "$t"
observe "gate11n2-h3-heading" "$t"

# 11n3 — real question with a `*` bullet. TODAY: passes (false negative, only
# `^- ` counts) even though the same file treats `*` as a list marker
# elsewhere. AFTER the fix: must stop.
t=$(setup_repo g11n3); b=$(brief "$t" '## Open Questions' '* **Q1 — a real question**')
write_state "$(base_state "$t" | jq --arg b "$b" '.last_brief_path=$b')" "$t"
observe "gate11n3-star-bullet" "$t"

# Gate 12 — lock directory already held
t=$(setup_repo g12); write_state "$(base_state "$t")" "$t"
mkdir -p "$t/.claude/dual-review-loop.lock"
observe "gate12-lock-held" "$t"

# ADVANCE — every gate passes; the hook must inject the next iteration.
# This is the most important row: it is the only one that proves the happy path
# still works after a gate reordering.
t=$(setup_repo adv); write_state "$(base_state "$t")" "$t"
observe "advance-inject" "$t"

# ---------------------------------------------------------------- verdict

LC_ALL=C sort -o "$ACTUAL" "$ACTUAL"

# A MISSING golden must not report success. Auto-generating one and exiting 0
# is a true false-PASS vector: forget `git add tests/fixtures/`, or land these
# tests on a branch that drops the fixture, and run-all.sh prints ALL GREEN
# while the "regression test" silently records whatever the (possibly already
# broken) hook does. --update is an explicit human act and exits 0; a missing
# golden is an infrastructure error and exits 2.
MISSING_GOLDEN=0
[ -f "$GOLDEN" ] || MISSING_GOLDEN=1

if [ "$UPDATE" -eq 1 ] || [ "$MISSING_GOLDEN" -eq 1 ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  {
    echo "# gate-matrix golden — RECORDS CURRENT BEHAVIOUR, NOT DESIRED BEHAVIOUR."
    echo "#"
    echo "# Several rows deliberately freeze KNOWN DEFECTS so that fixing them shows up"
    echo "# as an intended diff rather than passing unnoticed. Each is listed with the"
    echo "# delta a correct fix SHOULD produce, so a reviewer can tell an expected"
    echo "# change from a regression without re-deriving it:"
    echo "#"
    echo "#   gate11-open-questions   now: state=N (a genuine question deletes the"
    echo "#                           state, so the user cannot resume after answering)"
    echo "#                           after a fix: state=Y with a systemMessage"
    echo "#   gate11n1-none-bullet    now: STOPS on a '- 없음' placeholder — the"
    echo "#                           false positive measured at 77% of briefs"
    echo "#                           after a fix: decision=block (advances)"
    echo "#   gate11n2-h3-heading     now: ADVANCES past a real question under a"
    echo "#                           '###' heading (regex demands exactly '## ')"
    echo "#                           after a fix: approve, state deleted/paused"
    echo "#   gate11n3-star-bullet    now: ADVANCES past a real question on a '*'"
    echo "#                           bullet, though '*' is a list marker elsewhere"
    echo "#                           in the same file. after a fix: stops"
    echo "#   gate01-bad-json         now: state=N — a merely CORRUPT file (killed"
    echo "#                           editor save, disk-full) is deleted, discarding"
    echo "#                           a recoverable iteration count and baseline SHA"
    echo "#   gate04 / gate05         also: systemMessage is EMPTY, so the user sees"
    echo "#                           a turn end with no explanation. These are the"
    echo "#                           two most frequent events in the field baseline"
    echo "#                           (214 fires / 58%)."
    echo "#   gate03-inactive         now: fine. Becomes a defect if a pause ever"
    echo "#                           sets active=false — this row is then the"
    echo "#                           silent-deletion path on the next fire."
    echo "#   gate10b-max-minutes     now: state=N — the wall-clock cap deletes"
    echo "#                           state rather than pausing it"
    echo "#   gate09b-dirty-blocks    now: completion unreachable because an untracked"
    echo "#                           state file / brief keeps the tree dirty"
    echo "#                           after a fix: gitignore guidance covers .claude/"
    echo "#   gate09c-plan-outside-repo  now: 'all tasks complete' + state deleted even"
    echo "#                           though the real repo tree is DIRTY — Gate 9 checks"
    echo "#                           dirname(plan_path), not the repo root"
    echo "#                           after a fix: SOFT-PAUSE, state=Y active=true"
    echo "#   gate04 / gate05         now: active=true after a takeover pause, so the"
    echo "#                           state stays armed and can be resurrected later"
    echo "#                           after a fix: active=false on takeover pauses only"
    echo "#   gate12-lock-held        now: lock=N — this invocation FAILED to acquire"
    echo "#                           the lock and then deleted the holder's lock,"
    echo "#                           destroying mutual exclusion"
    echo "#                           after a fix: lock=Y (a non-owner must not rmdir)"
    echo "#"
    echo "# Do not read this file as a specification. A diff here is a question"
    echo "# (\"did I mean to change this?\"), not automatically a failure. Regenerating"
    echo "# with --update is how you ACCEPT a delta — walk the rows above first."
    echo "#"
    echo "# Columns: label | decision | state/active/marker(value)/lock/iteration |"
    echo "#          systemMessage | log tail"
    echo "# Regenerate: bash tests/gate-matrix.test.sh --update"
  } > "$GOLDEN"
  cat "$ACTUAL" >> "$GOLDEN"
  echo "== gate matrix: GOLDEN WRITTEN ($(grep -cv '^#' "$GOLDEN" | tr -d ' ') rows) =="
  echo "   $GOLDEN"
  echo "   Walk the known-defect rows in its header, then commit it."
  if [ "$MISSING_GOLDEN" -eq 1 ]; then
    echo ""
    echo "  ✗ the golden was MISSING and has been generated from the CURRENT hook."
    echo "    That is not a passing test — nothing was compared. If this is the"
    echo "    first run, review and 'git add tests/fixtures/'. If it is not, the"
    echo "    committed fixture has gone missing and that is the real failure."
    exit 2
  fi
  exit 0
fi

echo "== gate matrix: comparing against golden =="
EXPECTED=$(mktemp "${TMPDIR:-/tmp}/drl-expected.XXXXXX")
trap 'rm -f "$ACTUAL" "$EXPECTED"' EXIT
grep -v '^#' "$GOLDEN" > "$EXPECTED"

if diff -u "$EXPECTED" "$ACTUAL"; then
  echo "  ✓ all $(wc -l < "$EXPECTED" | tr -d ' ') gate observations unchanged"
  exit 0
fi
echo ""
echo "  ✗ FAIL: gate behaviour changed. Every line above must be an INTENDED delta."
echo "    If intended: bash tests/gate-matrix.test.sh --update, then commit the golden."
exit 1
