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

# Collation is pinned PER COMMAND, never exported.
#
# The reason to pin it: glibc gives punctuation near-ignored primary weight
# under a UTF-8 locale, so `gate10-…` vs `gate10b-…` can sort in a DIFFERENT
# order than under C. The golden would then diff on Linux with no semantic
# change, which trains reviewers to reflexively --update. BSD collation happens
# to match C, which is exactly why macOS-only testing cannot see it.
#
# The reason NOT to export it: the hook inherits the environment we run it in
# and pins no locale of its own (`grep -c 'LC_ALL\|LANG=' hooks/stop-hook.sh`
# → 0). Exporting would run the subject under test in a locale its users do not
# have, so a locale-sensitive path — the hook parses English `git diff
# --shortstat` tokens to compute the cumulative caps — could pass here while
# failing in production. Harness determinism must not be bought by changing the
# subject's environment.
#
# Make the throwaway git repos hermetic. Without this the developer's global
# config leaks in: `core.excludesFile` containing .claude/ silently flips the
# gate09b row, `commit.gpgsign` can block on pinentry and hang the suite, and
# `core.hooksPath` runs their pre-commit hooks inside our temp repo.
#
# Accepted trade-off: this DOES reach the hook's own git calls, so a user whose
# global config matters (e.g. a global excludesFile covering .claude/) sees
# behaviour these fixtures do not reproduce. Determinism wins for a golden
# baseline; gate09a/gate09b encode both sides of that particular case anyway.
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
  local tmp rc; tmp=$(mktemp -d "${TMPDIR:-/tmp}/drl-matrix-$1.XXXXXX") \
    || { echo "FATAL: mktemp failed" >&2; exit 2; }
  (
    set -e
    cd "$tmp"
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
  rc=$?
  # The subshell is deliberately NOT the left operand of `||`: bash suppresses
  # errexit there, so a failed `git init` would still return success and the
  # caller would silently run a gate case against a non-repo directory.
  [ "$rc" -eq 0 ] || { echo "FATAL: setup_repo $1 failed (rc=$rc)" >&2; exit 2; }
  git -C "$tmp" rev-parse HEAD >/dev/null 2>&1 \
    || { echo "FATAL: setup_repo $1 produced no HEAD" >&2; exit 2; }
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
    | LC_ALL=C sed -e "s|$real|<TMP>|g" -e "s|$tmp|<TMP>|g" -e "s|$HOME|<HOME>|g" \
          -e 's|^\[[0-9TZ:-]*\] ||' \
          -e 's|gap=[0-9]*s|gap=<N>s|g' \
          -e 's|reached ([0-9]*s|reached (<N>s|g' \
          -e 's|(line [0-9]*)|(line <N>)|g' \
          -e 's|[0-9a-f]\{40\}|<SHA>|g' \
    | LC_ALL=C tr '\n' ' ' | LC_ALL=C sed -e 's/  */ /g' -e 's/ $//'
}

# Fingerprint the injected prompt instead of freezing it.
# The prompt is multi-KB; putting it in the golden would make every wording
# tweak an enormous diff and train reviewers to blind---update, destroying the
# signal. Two things about it are contractual and cheap to pin:
#   1. the first line, which is the sentinel Gate 5 Strategy B greps for. Break
#      its format and every real loop soft-pauses after iter 1, silently.
#   2. how many OCCURRENCES of the Open Questions enforcement literal are
#      present (grep -o | wc -l, not grep -c, which counts matching LINES). Release A
#      edits that literal in the hook's two prompt arms; dropping one is
#      otherwise invisible here.
reason_fingerprint() {
  local r=$1
  [ -n "$r" ] || { printf '%s' "-"; return; }
  local first count
  first=$(printf '%s' "$r" | sed -n '1p')
  count=$(printf '%s' "$r" | grep -o 'non-empty: STOP' | wc -l | tr -d ' ')
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

# Gate 5 grace boundary — pins PHANTOM_GRACE_SECONDS from both sides.
# Measured: widening the constant 600 -> 86400 left the whole suite GREEN,
# because gate05 uses a year-2001 timestamp (any grace under ~25 years gives an
# identical row) and inflight-gate7 T2 uses gap 0 (any grace above 0 does too).
# The entire interval between was untested. Widening is the DANGEROUS direction:
# it re-arms the phantom-defense bypass and lets the hook re-inject into a
# session the user has explicitly taken over.
# These two rows sit 60s either side of the boundary, so moving the constant in
# either direction flips one of them.
t=$(setup_repo g5in)
write_state "$(base_state "$t" | jq '.last_injected_iter=1 | .last_injected_at_epoch=(.last_injected_at_epoch-540)')" "$t"
observe "gate05a-grace-inside" "$t"

t=$(setup_repo g5out)
write_state "$(base_state "$t" | jq '.last_injected_iter=1 | .last_injected_at_epoch=(.last_injected_at_epoch-660)')" "$t"
observe "gate05b-grace-outside" "$t"

# Gate 6 — idle beyond IDLE_TIMEOUT (last_injected_iter=0 skips Gate 5)
t=$(setup_repo g6)
write_state "$(base_state "$t" | jq '.last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000')" "$t"
observe "gate06-idle-timeout" "$t"

# Idle-GC boundary rows. The GC judgement has two inputs — staleness and the
# in-flight marker — and before these rows existed only two of the four corners
# were covered (gate06 = stale + no marker, gate07 = fresh + marker), so the
# marker's effect on GC was untested in both directions.
#
# 6b is the one that shows defect B: a state that is BOTH long-dead and owned by
# a vanished session. Gate 4 pauses on session mismatch and the GC sits after it,
# so the dead state is preserved forever and every later fire pauses again. That
# is the field baseline's most frequent event (214 fires / 58%). Running the GC
# before the defensive gates is what makes this row flip to a deletion.
#
# 6c/6d bracket the marker lease. An UNCONDITIONAL in-flight exemption would
# recreate defect B in a new form — a marker left behind by a crashed instance
# would protect a dead state forever — so the exemption has to expire. The two
# rows sit either side of that expiry, which is why they must disagree: if they
# ever read the same, the lease has stopped being a bound.
t=$(setup_repo g6b)
write_state "$(base_state "$t" | jq '.session_id="vanished-session"
  | .last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000
  | .last_injected_at_epoch=1000000000')" "$t"
observe "gate06b-stale-crosssession" "$t"

# Stale, but an in-flight marker written within the lease window: the loop was
# mid-iteration recently, so the GC must leave it alone and let Gate 7 handle it.
t=$(setup_repo g6c)
write_state "$(base_state "$t" | jq '.last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000')" "$t"
printf '1
' > "$t/.claude/dual-review-loop.inflight"
observe "gate06c-stale-marker-fresh-lease" "$t"

# Same shape, but the marker's lease has expired — nothing here is alive, so the
# exemption must not apply and the state is collected.
t=$(setup_repo g6d)
write_state "$(base_state "$t" | jq '.last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000
  | .last_injected_at_epoch=1000000000')" "$t"
printf '1
' > "$t/.claude/dual-review-loop.inflight"
observe "gate06d-stale-marker-expired-lease" "$t"

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
# The dirt here is a MODIFIED TRACKED SOURCE FILE, not the plugin's own state.
# .claude/ is gitignored on purpose: if the fixture relied on the untracked
# state file to dirty the tree, an implementation that merely noticed plugin
# metadata — or special-cased `.claude` — would pass while still declaring
# completion over uncommitted USER code. gate09b already covers the
# plugin-metadata case; this row must fail for a different reason.
t=$(setup_repo g9c gitignore)
printf 'user source, committed\n' > "$t/src.txt"
(cd "$t" && git add src.txt && git commit -qm "add source")
printf 'user source, MODIFIED and uncommitted\n' > "$t/src.txt"
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
    echo "#   gate11-open-questions   now: state=N and an EMPTY systemMessage — a"
    echo "#                           genuine question deletes the state silently, so"
    echo "#                           the user cannot resume after answering it."
    echo "#                           after Release A: decision=approve, state=N"
    echo "#                           (UNCHANGED), marker removed, and a NON-EMPTY"
    echo "#                           systemMessage naming the brief and the bullet."
    echo "#                           Terminal cleanup is deliberately KEPT in A;"
    echo "#                           resumability needs the Release C resume path"
    echo "#                           and is out of scope until then. Do not expect"
    echo "#                           state=Y here or a correct A reads as partial."
    echo "#   gate11n1-none-bullet    now: STOPS on a '- 없음' placeholder — the"
    echo "#                           false positive measured at 77% of briefs"
    echo "#                           after a fix: decision=block (advances)"
    echo "#   gate11n2-h3-heading     now: decision=block — ADVANCES past a real"
    echo "#                           question under a '###' heading (the regex demands"
    echo "#                           exactly '## ')."
    echo "#                           after a fix: identical to gate11-open-questions,"
    echo "#                           i.e. approve / state=N / non-empty systemMessage."
    echo "#   gate11n3-star-bullet    now: decision=block — ADVANCES past a real"
    echo "#                           question on a '*' bullet, though '*' IS a list"
    echo "#                           marker elsewhere in the same file."
    echo "#                           after a fix: same as gate11n2 above."
    echo "#   gate01-bad-json         now: state=N — a merely CORRUPT file (killed"
    echo "#                           editor save, disk-full) is deleted, discarding"
    echo "#                           a recoverable iteration count and baseline SHA"
    echo "#   gate03-inactive         now: fine. Becomes a defect if a pause ever"
    echo "#                           sets active=false — this row is then the"
    echo "#                           silent-deletion path on the next fire."
    echo "#   gate10b-max-minutes     now: state=N — the wall-clock cap deletes"
    echo "#                           state rather than pausing it"
    echo "#   gate10-max-iterations   now: state=N — same class as gate10b. If a fix"
    echo "#                           converts cap-termination to a pause, expect TWO"
    echo "#                           diffs here, not one."
    echo "#   gate06-idle-timeout     now: state=N and an EMPTY systemMessage — 24h of"
    echo "#                           idleness deletes the loop silently. This is the"
    echo "#                           exact hazard midflight M5 guards against, frozen"
    echo "#                           here as if acceptable."
    echo "#   gate08-plan-relative    now: state=N — a recoverable CONFIGURATION error"
    echo "#                           destroys state, same class as gate01. (A plan"
    echo "#                           path that is absolute but missing takes the same"
    echo "#                           fail_open branch and has no row at all.)"
    echo "#   gate06b-stale-crosssession  now: state=Y — a state that is BOTH long"
    echo "#                           past the idle timeout AND owned by a session that"
    echo "#                           no longer exists is PRESERVED, because Gate 4"
    echo "#                           pauses on session mismatch and the idle GC sits"
    echo "#                           behind it. The dead state never gets collected and"
    echo "#                           every later fire pauses again — 214 fires / 58% of"
    echo "#                           the field baseline."
    echo "#                           after a fix: state=N, log = idle timeout"
    echo "#   gate06c-stale-marker-fresh-lease  now: state=N — an in-flight marker"
    echo "#                           gives no protection at all, so a loop that was"
    echo "#                           mid-iteration is collected rather than handed to"
    echo "#                           Gate 7."
    echo "#                           after a fix: state=Y (exempt while the lease holds)"
    echo "#   gate06d-stale-marker-expired-lease  now AND after a fix: state=N."
    echo "#                           Deliberately unchanged. It is the other side of"
    echo "#                           6c: once the lease expires the marker stops"
    echo "#                           excusing the state. If 6c and 6d ever agree, the"
    echo "#                           exemption has stopped being bounded and defect B"
    echo "#                           is back in a new form."
    echo "#   gate09b-dirty-blocks    PARTLY FIXED (B-3) — the pause now carries a"
    echo "#                           systemMessage naming the gitignore patterns, so"
    echo "#                           it is no longer silent. Completion is still"
    echo "#                           unreachable while an untracked state file or"
    echo "#                           brief keeps the tree dirty: that is the correct"
    echo "#                           refusal, and the guidance in commands/ + README"
    echo "#                           is what stops a compliant repo from hitting it."
    echo "#   gate09c-plan-outside-repo  FIXED (B-3) — no longer a frozen defect."
    echo "#                           It used to declare 'all tasks complete' and"
    echo "#                           delete state over a DIRTY repo, because Gate 9"
    echo "#                           checked dirname(plan_path) instead of REPO_ROOT"
    echo "#                           and a plan at the /plan default is outside any"
    echo "#                           repo, skipping the check entirely. Now pins the"
    echo "#                           repaired behaviour: SOFT-PAUSE, state=Y"
    echo "#                           active=true. Reverting to state=N here means"
    echo "#                           the repo-scope fix regressed."
    echo "#   gate04-session-mismatch now: active=true after a CROSS-SESSION pause and"
    echo "#                           an EMPTY systemMessage, so the state stays armed"
    echo "#                           and the user sees a turn end with no explanation."
    echo "#                           This is the field baseline's single most frequent"
    echo "#                           event (214 fires / 58%)."
    echo "#                           after a fix: active=false, non-empty message."
    echo "#   gate05-no-continuation  now: same shape as gate04, but this is a"
    echo "#                           SAME-session pause — the user may well intend to"
    echo "#                           resume. Do NOT fold it in with gate04: disarming"
    echo "#                           it would kill a loop its owner still wants."
    echo "#                           after a fix: message only; active stays true."
    echo "#   gate12-lock-held        FIXED (B-2b) — no longer a frozen defect. It now"
    echo "#                           pins the repaired behaviour: lock=Y, because a"
    echo "#                           non-owner must not rmdir, plus a systemMessage"
    echo "#                           telling the user how to clear a stale lock (the"
    echo "#                           deleted rmdir was also the only stale-lock"
    echo "#                           cleanup). If this row returns to lock=N,"
    echo "#                           ownership tracking has regressed."
    echo "#                           NOTE, measured: simply deleting the rmdir from"
    echo "#                           soft_pause() flips SIX rows — gate02, gate04,"
    echo "#                           gate05, gate05b, gate09b, gate12 — because five"
    echo "#                           of them legitimately acquire the lock and would"
    echo "#                           then leak it. Those five reading lock=N is what"
    echo "#                           proves owner paths still release rather than leak."
    echo "#"
    echo "# Do not read this file as a specification. A diff here is a question"
    echo "# (\"did I mean to change this?\"), not automatically a failure. Regenerating"
    echo "# with --update is how you ACCEPT a delta — walk the rows above first."
    echo "#"
    echo "# Columns (6, pipe-separated):"
    echo "#   1 label  2 decision  3 state/active/marker(value)/lock/iter"
    echo "#   4 reason fingerprint (sentinel line + enforcement-clause count)"
    echo "#   5 systemMessage  6 log tail"
    echo "# Regenerate: bash tests/gate-matrix.test.sh --update"
  } > "$GOLDEN"
  cat "$ACTUAL" >> "$GOLDEN"
  echo "== gate matrix: GOLDEN WRITTEN ($(grep -cv '^#' "$GOLDEN" | tr -d ' ') rows) =="
  echo "   $GOLDEN"
  echo "   Walk the known-defect rows in its header, then commit it."
  if [ "$MISSING_GOLDEN" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then
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
LC_ALL=C grep -v '^#' "$GOLDEN" > "$EXPECTED"

if LC_ALL=C diff -u "$EXPECTED" "$ACTUAL"; then
  echo "  ✓ all $(wc -l < "$EXPECTED" | tr -d ' ') gate observations unchanged"
  exit 0
fi
echo ""
echo "  ✗ FAIL: gate behaviour changed. Every line above must be an INTENDED delta."
echo "    If intended: bash tests/gate-matrix.test.sh --update, then commit the golden."
exit 1
