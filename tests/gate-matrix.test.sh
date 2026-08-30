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

# 6c/6d straddle the lease boundary at +/-1h, DERIVED from the hook's own
# constant. An earlier version set only `last_injected_at_epoch` apart (now vs
# year-2001) and left the other timestamp stale — two problems. First, the hook
# writes `last_iter_at_epoch` and `last_injected_at_epoch` to the same value on
# every inject, so that state is unreachable in practice. Second, and worse: ANY
# lease between 24h and ~25 years produced an identical matrix, so widening the
# constant to 10 years — removing the bound entirely — left the whole suite
# green. Measured. That is the hole the gate05a/gate05b pair was built to close
# for PHANTOM_GRACE_SECONDS; it was not carried over here. Deriving from the hook
# means moving the constant in either direction flips a row.
# FIXED offsets, deliberately NOT derived from the hook. Deriving them was the
# first attempt and it is self-defeating: fixtures computed from the constant
# move with it, so the rows stay green for ANY value and detect nothing —
# verified, a 10-year lease left the matrix fully green. gate05a/gate05b pin
# PHANTOM_GRACE_SECONDS the right way, with literals 60s either side of 600.
# 47h/49h bracket the documented 48h. Change the constant and one of these flips;
# that is the whole job. (docs-consistency.test.sh separately asserts the docs
# quote whatever the hook actually says, so the two checks cover both directions.)
INSIDE=$(( 47 * 3600 ))
OUTSIDE=$(( 49 * 3600 ))

# Marker present, age just INSIDE the lease: exempt from collection and handed to
# Gate 7, which can still recover it.
t=$(setup_repo g6c)
write_state "$(base_state "$t" | jq --argjson age "$INSIDE" \
  '.last_iter_at_epoch=(.last_iter_at_epoch-$age)
   | .started_at_epoch=(.started_at_epoch-$age)
   | .last_injected_at_epoch=(.last_injected_at_epoch-$age)')" "$t"
printf '1' > "$t/.claude/dual-review-loop.inflight"
observe "gate06c-marker-inside-lease" "$t"

# Same shape, 2h older — just OUTSIDE the lease. The marker stops excusing the
# state and it is collected. 6c and 6d must always disagree.
t=$(setup_repo g6d)
write_state "$(base_state "$t" | jq --argjson age "$OUTSIDE" \
  '.last_iter_at_epoch=(.last_iter_at_epoch-$age)
   | .started_at_epoch=(.started_at_epoch-$age)
   | .last_injected_at_epoch=(.last_injected_at_epoch-$age)')" "$t"
printf '1' > "$t/.claude/dual-review-loop.inflight"
observe "gate06d-marker-outside-lease" "$t"

# A marker timestamped in the FUTURE (clock skew, bad RTC, a state file copied
# between machines) must NOT earn an exemption. A one-sided `age < lease` test
# passes for every negative age, granting a PERMANENT exemption and recreating
# exactly the immortal state the GC exists to collect.
t=$(setup_repo g6f)
write_state "$(base_state "$t" | jq \
  '.last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000
   | .last_injected_at_epoch=(.last_injected_at_epoch+315360000)')" "$t"
printf '1' > "$t/.claude/dual-review-loop.inflight"
observe "gate06f-marker-future-dated" "$t"

# Stale + SAME session + no continuation signal. Before the GC moved ahead of the
# defensive gates this was a Gate 5 soft-pause that PRESERVED state; the GC now
# reaches it first and deletes. That is a deliberate call — 24h with no iteration
# is idle by any reading — but it is a real behaviour change on the very gate
# whose golden note warns against disarming same-session pauses, so it gets a row
# rather than passing unrecorded.
t=$(setup_repo g6e)
write_state "$(base_state "$t" | jq '.last_injected_iter=1
  | .last_iter_at_epoch=1000000000 | .started_at_epoch=1000000000
  | .last_injected_at_epoch=1000000000')" "$t"
observe "gate06e-stale-same-session" "$t"

# Gate 7 — in-flight marker present, HEAD unmoved from inflight_base_sha
t=$(setup_repo g7); write_state "$(base_state "$t")" "$t"
printf '1\n' > "$t/.claude/dual-review-loop.inflight"
observe "gate07-inflight-nocommit" "$t"

# Gate 7 + Gate 11 together — the combination that had no row, and is the most
# likely real stop. The injected prompt tells the model to STOP on Open Questions
# at step 5, which is BEFORE the commit at step 8 and the marker removal at step
# 9. So an obedient model leaves exactly this state behind: marker set, nothing
# committed, brief holding a disagreement. Gate 7 sits ahead of Gate 11 and used
# to answer for it — naming plan mode as the cause and advising the user to let
# the iteration finish, i.e. to continue past the disagreement. These two rows
# pin that Gate 7 now asks the brief first.
t=$(setup_repo g7oq); write_state "$(base_state "$t" | jq --arg b "$t/.claude/reviews/iter-001.md" '.last_brief_path=$b')" "$t"
mkdir -p "$t/.claude/reviews"
printf '## Open Questions\n- A says drop the index, B says keep it\n' > "$t/.claude/reviews/iter-001.md"
printf '1\n' > "$t/.claude/dual-review-loop.inflight"
observe "gate07-inflight-open-question" "$t"

# Same, with the heading the terminal detector deliberately does not match. The
# loop must not terminate on it (that was a measured regression) and must not
# walk past it either.
t=$(setup_repo g7amb); write_state "$(base_state "$t" | jq --arg b "$t/.claude/reviews/iter-001.md" '.last_brief_path=$b')" "$t"
mkdir -p "$t/.claude/reviews"
printf '## Open Questions (unscored)\n- A says drop the index, B says keep it\n' > "$t/.claude/reviews/iter-001.md"
printf '1\n' > "$t/.claude/dual-review-loop.inflight"
observe "gate07-inflight-ambiguous-heading" "$t"

# Gate 11 third state on its own — no marker, so Gate 7 is not involved. Pins
# that an Open-Questions-shaped heading the detector cannot act on PAUSES
# (state=Y) rather than advancing in silence, and rather than terminating.
t=$(setup_repo g11amb); write_state "$(base_state "$t" | jq --arg b "$t/.claude/reviews/iter-001.md" '.last_brief_path=$b')" "$t"
mkdir -p "$t/.claude/reviews"
printf '## Open Questions (진짜 결정 필요)\n1. soft_pause 두 곳을 넣을 것인가\n' > "$t/.claude/reviews/iter-001.md"
observe "gate11-ambiguous-heading" "$t"

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

# Gate 13 — the computed brief path is already occupied.
#
# `iteration` lives in a hand-seeded state file, so it can be rewound: re-seeding
# after a terminal gate sets it back to 0 and iter-001.md gets targeted a second
# time. The injected prompt says "Save it verbatim to <path>", so an executor
# following it destroys the earlier brief. Observed in the field — two
# "iter 1 → injecting" log lines an hour apart, both naming iter-001.md.
#
# The observable is the path in the log tail. The collision warning is logged
# too, but `observe` keeps only the last line and the warning precedes the
# injection line.
t=$(setup_repo g13 gitignore); mkdir -p "$t/.claude/reviews"
printf '# an earlier brief that must survive\n' > "$t/.claude/reviews/iter-001.md"
write_state "$(base_state "$t" | jq '.iteration=0')" "$t"
observe "gate13-brief-path-collision" "$t"

# Gate 12 — TWO distinct cases the single old row conflated.
#
# The old fixture pre-created a bare lock dir and called it "contention", but a
# directory with no live holder is an ORPHAN. The golden then pinned
# soft-pause-forever as correct for it. That mattered: this gate precedes every
# other gate including the idle GC, so one orphan wedged the loop permanently and
# the state could never be collected — and the only row covering stale locks
# certified that as intended. Splitting them makes the outcomes distinguishable.
#
# Contention: lock created just now, so a live holder is plausible and standing
# down is right. The lock must SURVIVE — a non-owner must never rmdir.
t=$(setup_repo g12); write_state "$(base_state "$t")" "$t"
mkdir -p "$t/.claude/dual-review-loop.lock"
observe "gate12-lock-contention" "$t"

# Orphan: the lock predates any possible live holder (a lock is held for the
# lifetime of ONE hook invocation — seconds). It must be RECLAIMED and the hook
# must proceed, not pause. `touch -t` with a fixed past stamp is POSIX and avoids
# the date(1) portability split between BSD and GNU.
t=$(setup_repo g12o); write_state "$(base_state "$t")" "$t"
mkdir -p "$t/.claude/dual-review-loop.lock"
touch -t 200101010000 "$t/.claude/dual-review-loop.lock"
observe "gate12-lock-orphan-reclaimed" "$t"

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
    echo "#   gate11-open-questions   PARTLY FIXED (A-3) — the stop now names the brief"
    echo "#                           and quotes the bullet that caused it. state=N is"
    echo "#                           UNCHANGED and still the defect: a genuine question"
    echo "#                           deletes the state, so the user cannot resume after"
    echo "#                           answering it. Terminal cleanup is deliberately KEPT"
    echo "#                           in A; resumability needs the Release C resume path."
    echo "#                           Do not expect state=Y here."
    echo "#   gate11n1-none-bullet    FIXED (A-3) — a placeholder bullet no longer stops"
    echo "#                           the loop. The old note here claimed 77% of briefs;"
    echo "#                           that figure did not reproduce and is dropped rather"
    echo "#                           than restated. The number that matters is stops"
    echo "#                           REMOVED, measured at change time over every"
    echo "#                           iter-NNN.md brief on the machine: 6 removed, all"
    echo "#                           six verified by eye as '(none)' placeholders, and"
    echo "#                           0 real questions newly skipped RELATIVE TO THE"
    echo "#                           PREVIOUS REGEX. That delta is the whole claim. The"
    echo "#                           old regex also demanded a bare heading and a"
    echo "#                           -/*/+ bullet, so sections with numbered or prose"
    echo "#                           bodies were skipped by BOTH versions and do not"
    echo "#                           show up in the comparison at all. Dual review"
    echo "#                           found one such brief written FOR THIS REPO whose"
    echo "#                           two blocking decisions the detector still walks"
    echo "#                           past. Do not read this line as coverage."
    echo "#   gate11n2-h3-heading     FIXED (A-3) — '###' headings are read, and a"
    echo "#                           sub-heading nested inside the section no longer"
    echo "#                           closes it."
    echo "#   gate11n3-star-bullet    FIXED (A-3) — '*' and '+' are list markers too."
    echo "#                           Indented bullets are deliberately NOT matched: a"
    echo "#                           note nested under a placeholder would re-stop."
    echo "#                           TWO decisions here are load-bearing and measured."
    echo "#                           (1) The trailing anchor on the heading STAYS."
    echo "#                           Removing it starts stopping on '(unscored)' and"
    echo "#                           '→ 해소됨' headings — reviewers using the section"
    echo "#                           for their own notes. That collision is semantic."
    echo "#                           (2) An h1 does NOT close the section, matching the"
    echo "#                           rule replaced. Treating a stray '# note' as a"
    echo "#                           boundary skips the question under it; over-stopping"
    echo "#                           is the safe side. Fenced blocks are skipped"
    echo "#                           whole, so a '#' inside one is quoted material"
    echo "#                           rather than a boundary — measured as a skipped"
    echo "#                           question before the fence rule existed."
    echo "#                           tests/gate11-openq.test.sh pins all of it."
    echo "#   gate01-bad-json         PARTLY FIXED (A-1) — fail_open now explains"
    echo "#                           itself instead of ending the turn in silence."
    echo "#                           Deleting a merely CORRUPT file (killed editor"
    echo "#                           save, disk-full) is STILL the defect: it discards"
    echo "#                           a recoverable iteration count and baseline SHA."
    echo "#                           Note this row moves via fail_open, which has 13"
    echo "#                           call sites — not via cleanup_and_approve."
    echo "#   gate07-inflight-open-question / -ambiguous-heading  the combination that"
    echo "#                           had no row and is the most likely real stop. The"
    echo "#                           prompt says STOP on Open Questions at step 5, the"
    echo "#                           commit is step 8 and clearing the marker step 9 —"
    echo "#                           so an OBEDIENT model lands exactly here. Gate 7"
    echo "#                           sits ahead of Gate 11 and used to answer for it,"
    echo "#                           naming plan mode and advising the user to let the"
    echo "#                           iteration finish, i.e. to continue past a"
    echo "#                           disagreement. Both rows must name the disagreement."
    echo "#                           If either reverts to the plan-mode wording, the"
    echo "#                           gate has stopped consulting the brief."
    echo "#   gate11-ambiguous-heading  the third classifier state. state=Y is the whole"
    echo "#                           point: an Open-Questions-shaped heading the"
    echo "#                           detector cannot act on PAUSES with state preserved."
    echo "#                           It must not terminate (that was a measured"
    echo "#                           regression on reviewers own notes) and must not"
    echo "#                           advance (that is the silence the gate exists to"
    echo "#                           prevent). state=N here means someone made it"
    echo "#                           terminal; no row at all means it went back to"
    echo "#                           advancing."
    echo "#   NOT IN THIS FILE        The ERR-trap exits have no rows and cannot get"
    echo "#                           one: observe() drives the hook THROUGH gates, and"
    echo "#                           a trap fires BETWEEN them. A state file that is"
    echo "#                           valid JSON but not an object, malformed hook"
    echo "#                           stdin, and an unwritable .claude all used to exit"
    echo "#                           silently there — and the trap also deleted the"
    echo "#                           in-flight marker, so the next fire read the"
    echo "#                           unfinished iteration as complete. Those live in"
    echo "#                           tests/silent-exit.test.sh. If you are counting"
    echo "#                           exit paths, count that file too."
    echo "#   gate03-inactive         FIXED (A-1) — carries a message. It was the"
    echo "#                           silent-deletion path a pause setting"
    echo "#                           active=false would land on; it now explains"
    echo "#                           itself if that ever happens."
    echo "#   gate10b-max-minutes     PARTLY FIXED (A-1) — the cap now names itself"
    echo "#                           and says how to continue. state=N is UNCHANGED"
    echo "#                           and still the defect: the cap DELETES state"
    echo "#                           rather than pausing it. That second diff belongs"
    echo "#                           to Release C, not here."
    echo "#   gate10-max-iterations   PARTLY FIXED (A-1) — same class as gate10b, same"
    echo "#                           half done. Expect the deletion diff at C."
    echo "#   gate06-idle-timeout     PARTLY FIXED (A-1) — the row now carries a full"
    echo "#                           message naming the 24h idleness, so the collection"
    echo "#                           is no longer silent. state=N is UNCHANGED and is"
    echo "#                           still the frozen half: the timeout DELETES rather"
    echo "#                           than pauses. Same class as gate10/10b; the deletion"
    echo "#                           diff belongs to Release C."
    echo "#                           (This note itself was stale for one release — it"
    echo "#                           still claimed an EMPTY message after the row had"
    echo "#                           gained one. Nothing catches that: the comparison"
    echo "#                           strips ^# lines, so these annotations are"
    echo "#                           unverifiable by construction. Read them as prose"
    echo "#                           that needs reviewing like code, not as assertions.)"
    echo "#   gate08-plan-relative    PARTLY FIXED (A-1) — carries a message now, via"
    echo "#                           fail_open. A recoverable CONFIGURATION error"
    echo "#                           still DESTROYS state, same class as gate01. (A"
    echo "#                           plan path that is absolute but missing takes the"
    echo "#                           same branch and has no row at all.)"
    echo "#   gate06b-stale-crosssession  FIXED (B-1) — no longer a frozen defect."
    echo "#                           A state both past the idle timeout AND owned by a"
    echo "#                           vanished session used to be PRESERVED, because"
    echo "#                           Gate 4 pauses on session mismatch and the GC sat"
    echo "#                           behind it: never collected, paused again on every"
    echo "#                           fire, 214 fires / 58% of the field baseline. Now"
    echo "#                           pins the repaired behaviour: state=N, log = idle"
    echo "#                           timeout. Back to state=Y and the GC has fallen"
    echo "#                           behind the defensive gates again."
    echo "#   gate06c/06d-marker-inside/outside-lease  the lease boundary, +/-1h,"
    echo "#                           derived from MARKER_LEASE_SECONDS. They must"
    echo "#                           always DISAGREE: 6c state=Y, 6d state=N. If they"
    echo "#                           ever read the same the exemption has stopped"
    echo "#                           being bounded, which is defect B in a new form."
    echo "#                           Their predecessors set only last_injected_at"
    echo "#                           apart and did NOT straddle anything: a lease of"
    echo "#                           10 years left the whole suite green. Measured."
    echo "#   gate06e-stale-same-session  state=N. RECORDS A BEHAVIOUR CHANGE, not a"
    echo "#                           defect. Before the GC moved ahead of the"
    echo "#                           defensive gates this was a Gate 5 soft-pause that"
    echo "#                           PRESERVED state. Deliberate — 24h with no"
    echo "#                           iteration is idle — but see the gate05 note"
    echo "#                           below, which warns against disarming"
    echo "#                           same-session pauses. Deletion is stronger than"
    echo "#                           disarming, so the two notes must be read together."
    echo "#   gate06f-marker-future-dated  state=N. A marker timestamped in the FUTURE"
    echo "#                           earns no exemption. A one-sided age<lease test"
    echo "#                           passes for every negative age and grants a"
    echo "#                           permanent exemption; clock skew alone reaches it."
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
    echo "#   gate04-session-mismatch PARTLY FIXED (A-1) — the pause now names the"
    echo "#                           other session and how to resume. This was the"
    echo "#                           field baseline's single most frequent event"
    echo "#                           (214 fires / 58%) and it said nothing."
    echo "#                           active=true is UNCHANGED. The prescribed fix"
    echo "#                           (active=false) is DEFERRED to Release C with the"
    echo "#                           resume path, not withdrawn — disarming without a"
    echo "#                           way back is a worse trade than the noise."
    echo "#   gate05-no-continuation  FIXED (A-1) — message added, active stays true,"
    echo "#                           which is exactly what this row asked for. Do NOT"
    echo "#                           fold it in with gate04: disarming a SAME-session"
    echo "#                           pause would kill a loop its owner still wants."
    echo "#                           gate05b-grace-outside moves with it — same call"
    echo "#                           site, and it is easy to leave out of a count."
    echo "#   gate12-lock-contention  lock=Y — a non-owner must never rmdir. If this"
    echo "#                           returns to lock=N, ownership tracking regressed."
    echo "#   gate12-lock-orphan-reclaimed  decision=block — the loop ADVANCES. A lock"
    echo "#                           with no possible live holder is reclaimed rather"
    echo "#                           than pausing forever. This pair replaces a single"
    echo "#                           row that conflated the two: it pre-created a bare"
    echo "#                           lock dir, labelled it contention, and pinned"
    echo "#                           soft-pause-forever as correct. Because this gate"
    echo "#                           precedes EVERY other gate including the idle GC,"
    echo "#                           that made one orphaned lock wedge the loop"
    echo "#                           permanently — state could never be collected —"
    echo "#                           and the only row covering stale locks certified"
    echo "#                           it as intended. If this row becomes approve/"
    echo "#                           state=Y, the deadlock is back."
    echo "#                           NOTE, measured: simply deleting the rmdir from"
    echo "#                           soft_pause() flips SIX rows — gate02, gate04,"
    echo "#                           gate05, gate05b, gate09b, gate12 — because five"
    echo "#                           of them legitimately acquire the lock and would"
    echo "#                           then leak it. Those five reading lock=N is what"
    echo "#                           proves owner paths still release rather than leak."
    echo "#   gate13-brief-path-collision  the brief number is derived from a"
    echo "#                           hand-seeded counter, so it can be rewound and name"
    echo "#                           a file that already holds the previous iteration's"
    echo "#                           evidence. The injected prompt says to write there"
    echo "#                           verbatim, so a collision is silent data loss. Pins"
    echo "#                           the skip to the first free name: if the log tail"
    echo "#                           names iter-001 again, the overwrite is back."
    echo "#                           Not covered here: the exhausted-window refusal"
    echo "#                           (soft_pause, state preserved) and the >999"
    echo "#                           boundary — both need a directory the matrix does"
    echo "#                           not build, and are driven directly instead."
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
