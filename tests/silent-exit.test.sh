#!/usr/bin/env bash
# The exit paths that still emit a bare approve after the message work.
#
# WHY THIS FILE EXISTS
# The change that forced a message on every non-user-requested exit routed the
# enforcement through cleanup_and_approve / fail_open / soft_pause. The ERR trap
# is not one of those — it prints its own approve and was never touched. Dual
# review found three reachable triggers for it, and the golden cannot see any of
# them: observe() drives the hook through gates, and a trap fires *between*
# gates. So this file drives the hook until something detonates, and asserts on
# what the user is left holding.
#
# The second assertion per case is the one that matters more than the message.
# The ERR trap used to `rm -f` the in-flight marker. Gate 7 treats an absent
# marker as "the LLM cleared it — the iteration finished", so a trap firing
# mid-run made the NEXT fire advance over work that never committed. A silent
# error turned into a false completion. Losing the message is a bad turn; losing
# the marker is a lost iteration.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  ✗ FAIL: %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# A repo with a state file, an armed in-flight marker, and a HEAD that has NOT
# moved past inflight_base_sha. That combination means Gate 7 would soft-pause
# if we ever reached it — so if a case reports the marker gone, the trap took it.
setup() {  # setup <state-json-literal> -> prints repo path
  local t state="$1"
  t=$(mktemp -d "${TMPDIR:-/tmp}/drl-silent.XXXXXX") || return 1
  (
    set -e
    cd "$t"
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '.claude/\n' > .gitignore
    printf '# plan\n\n- [ ] do something\n' > plan.md
    git add -A && git commit -qm initial
    mkdir -p .claude
  ) >/dev/null 2>&1 || return 1
  printf '%s' "$state" > "$t/.claude/dual-review-loop.state.json"
  printf '1' > "$t/.claude/dual-review-loop.inflight"
  printf '%s' "$t"
}

# Run the hook once. Sets OUT / MSG / MARKER / LOGTAIL in the caller's scope.
fire() {  # fire <repo> [stdin-json]
  local t="$1" stdin="${2:-{\"session_id\":\"s\",\"transcript_path\":\"\",\"hook_event_name\":\"Stop\"}}"
  OUT=$(printf '%s' "$stdin" | (cd "$t" && bash "$HOOK" 2>"$t/stderr.txt"))
  ERRTXT=$(cat "$t/stderr.txt" 2>/dev/null || echo "")
  MSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null || echo "")
  if [ -f "$t/.claude/dual-review-loop.inflight" ]; then MARKER=present; else MARKER=DELETED; fi
  LOGTAIL=$(tail -3 "$t/.claude/dual-review-loop.log" 2>/dev/null || echo "")
}

# A case is only meaningful if it actually reached the path we think it did.
# Without this guard a hook that fail-opens at Gate 0 passes every assertion
# below while proving nothing — the exact failure jq-missing.test.sh documents.
reached_trap() { case "$LOGTAIL" in *"ERR trap fired"*) return 0 ;; *) return 1 ;; esac; }

echo "== silent exit paths =="

# --- 1. Valid JSON that is not an object -----------------------------------
# Gate 1 tests `jq -e .`, which only asks "does this parse and is it truthy".
# `[]`, `123` and `"str"` all pass, then the very next line does
# `jq -r '.schema // ""'` on an array and detonates. The sibling case — a file
# that does not parse at all — gets the full fail_open message. So the MORE
# corrupt file explains itself and the LESS corrupt one does not.
for lit in '[]' '123' '"corrupted"'; do
  t=$(setup "$lit") || { echo "FATAL: setup"; exit 2; }
  fire "$t"
  [ -f "$t/.claude/dual-review-loop.state.json" ] && STATE=present || STATE=DELETED
  label="non-object state $lit"

  if [ -z "$OUT" ]; then
    bad "$label" "EMPTY stdout — Claude Code sees no decision and the turn hangs"
  else
    [ -n "$MSG" ] && ok "$label: user is told what happened" \
                  || bad "$label: user is told what happened" "silent approve: [$OUT]"

    # And told the RIGHT thing. Once the ERR trap carries a generic message, a
    # regressed Gate 1 still produces *a* message — so asserting non-empty alone
    # cannot see the gate disappear. The specific message names the state file;
    # the trap's fallback says only "internal error". Pin the specific one, or
    # this case silently degrades into a test of the trap.
    case "$MSG" in
      *"state file"*) ok "$label: the message names the state file, not a generic internal error" ;;
      *) bad "$label: the message names the state file" "got=[$MSG] — this looks like the ERR-trap fallback, i.e. Gate 1 stopped catching it" ;;
    esac

    # The half-cleared state is the thing to forbid, not deletion as such.
    # A TERMINAL exit (fail_open) clears the state file and the marker together
    # and says so; a NON-TERMINAL one (the ERR trap) keeps both. What must never
    # happen is one without the other: a marker left behind with no state strands
    # the next fire, and — the case that actually shipped — a marker deleted with
    # the state intact makes Gate 7 read "the iteration finished" and inject over
    # work that never committed.
    if [ "$STATE" = "$MARKER" ]; then
      ok "$label: state and in-flight marker agree ($STATE)"
    else
      bad "$label: state and in-flight marker agree" "state=$STATE marker=$MARKER — a half-cleared exit"
    fi
  fi
  rm -rf "$t"
done

# --- 2. Malformed hook stdin ------------------------------------------------
# The hook reads its own stdin with `jq -r '.session_id // ""' 2>/dev/null` as a
# top-level simple command. jq exits non-zero on a parse error, so the trap
# fires. Note the hook already uses `|| echo ""` for this exact hazard elsewhere;
# these two sites were missed.
VALID_STATE=$(jq -n --argjson now "$(date +%s)" \
  '{schema:"v2",mode:"plan",active:true,plan_path:"plan.md",iteration:1,
    max_iterations:20,max_minutes:0,max_files:999999,max_loc:999999,
    max_reviews:999999,session_id:"s",started_at_epoch:$now,
    last_iter_at_epoch:$now,last_injected_at_epoch:$now,last_injected_iter:0,
    started_at_sha:"",inflight_base_sha:"",last_brief_path:"",reviews_baseline:0}')

for stdin in 'this is not json' '{"session_id":"s"' '[1,2,3]'; do
  t=$(setup "$VALID_STATE") || { echo "FATAL: setup"; exit 2; }
  fire "$t" "$stdin"
  label="malformed stdin $(printf '%s' "$stdin" | head -c 18)"
  if [ -z "$OUT" ]; then
    bad "$label" "EMPTY stdout — Claude Code sees no decision and the turn hangs"
  else
    [ -n "$MSG" ] && ok "$label: user is told what happened" \
                  || bad "$label: user is told what happened" "silent approve: [$OUT]"
    [ "$MARKER" = present ] && ok "$label: in-flight marker survives" \
                            || bad "$label: in-flight marker survives" "marker deleted"

    # Unparseable stdin is not an internal error — it means "the CLI told us
    # nothing about the session", and the hook's own default for that is to skip
    # the cross-session check and carry on. Asserting only "some message" cannot
    # see the guard disappear, because the ERR trap now answers with a message
    # too; what distinguishes them is that the trap's says "internal error".
    case "$MSG" in
      *"internal error"*) bad "$label: handled as missing input, not as a crash" "got the ERR-trap message — the read lost its || echo \"\" guard" ;;
      *) ok "$label: handled as missing input, not as a crash" ;;
    esac
  fi
  rm -rf "$t"
done

# --- 3. soft_pause called with no message -----------------------------------
# cleanup_and_approve and fail_open make silence structurally impossible and log
# a BUG line naming themselves. soft_pause takes a bare-approve branch instead.
# Every current call site passes a message, so this is latent — but it is latent
# in exactly the shape the neighbouring comment calls unacceptable, and the
# call sites that will grow are soft_pause's. Extract the function and call it
# with one argument, the way a future call site would.
sp=$(mktemp -d "${TMPDIR:-/tmp}/drl-sp.XXXXXX")
sed -n '/^soft_pause()/,/^}/p' "$HOOK" > "$sp/fn.sh"
OUT=$( (
  set -u
  DECISION_EMITTED=0
  LOG_FILE="$sp/log"
  log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
  release_lock() { :; }
  # shellcheck disable=SC1090
  . "$sp/fn.sh"
  soft_pause "some new pause site nobody gave a message"
) 2>/dev/null )
SPMSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null || echo "")
SPLOG=$(cat "$sp/log" 2>/dev/null || echo "")
rm -rf "$sp"

[ -n "$OUT" ] && ok "soft_pause with one arg: does not die under set -u" \
              || bad "soft_pause with one arg: does not die under set -u" "EMPTY stdout"
[ -n "$SPMSG" ] && ok "soft_pause with one arg: still tells the user something" \
                || bad "soft_pause with one arg: still tells the user something" "silent approve: [$OUT]"
case "$SPLOG" in
  *BUG*) ok "soft_pause with one arg: leaves a BUG line naming itself" ;;
  *) bad "soft_pause with one arg: leaves a BUG line naming itself" "log=[$SPLOG]" ;;
esac

# --- 3b. The ERR trap, in isolation -----------------------------------------
# Every input that used to reach this trap is now caught by a gate ahead of it,
# which is the fix — and it also means no end-to-end case exercises the trap any
# more. Measured: with the trap's message deleted and its `rm -f` restored, every
# other assertion in this file still passed. So drive the trap directly, the way
# the soft_pause case does, or its two properties are pinned by nothing.
tp=$(mktemp -d "${TMPDIR:-/tmp}/drl-trap.XXXXXX")
TRAPLINE=$(grep -n "^trap .*' ERR$" "$HOOK" | head -1 | cut -d: -f1)
if [ -z "$TRAPLINE" ]; then
  bad "ERR trap can be located" "no 'trap ... ERR' line — anchor changed, this case is not running"
else
  ok "ERR trap can be located"
  printf '1' > "$tp/marker"
  sed -n "${TRAPLINE}p" "$HOOK" > "$tp/trap.sh"
  TOUT=$( (
    set -u
    DECISION_EMITTED=0
    INFLIGHT_FILE="$tp/marker"
    LOG_FILE="$tp/log"
    log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
    release_lock() { :; }
    # shellcheck disable=SC1090
    . "$tp/trap.sh"
    false            # any unguarded non-zero command reaches the trap
    printf 'TRAP-DID-NOT-FIRE'
  ) 2>/dev/null )
  TMSG=$(printf '%s' "$TOUT" | jq -r '.systemMessage // ""' 2>/dev/null || echo "")
  [ -f "$tp/marker" ] && TMARK=present || TMARK=DELETED

  case "$TOUT" in
    *TRAP-DID-NOT-FIRE*) bad "ERR trap fires on an unguarded failure" "it did not fire; the rest of this case proves nothing" ;;
    "") bad "ERR trap fires on an unguarded failure" "EMPTY stdout" ;;
    *) ok "ERR trap fires on an unguarded failure" ;;
  esac
  [ -n "$TMSG" ] && ok "ERR trap: the user is told the loop hit an internal error" \
                 || bad "ERR trap: the user is told the loop hit an internal error" "silent approve: [$TOUT]"
  # The one that cost an iteration. The marker is half of Gate 7's completion
  # evidence; deleting it here makes the NEXT fire read unfinished work as done.
  [ "$TMARK" = present ] && ok "ERR trap: leaves the in-flight marker alone" \
                         || bad "ERR trap: leaves the in-flight marker alone" "trap deleted it — the next fire would advance over uncommitted work"
fi
rm -rf "$tp"

# --- 3c. No fire may report an unbound variable -----------------------------
# This script runs under `set -u`, and its worst failure is an abort AFTER
# DECISION_EMITTED is set: the EXIT trap then suppresses its own fallback and
# stdout comes out empty. Every such abort begins as an "unbound variable" line
# on stderr, so that line is the early warning for the whole class — including
# the cases where it is currently survivable.
#
# Measured: `oq_suffix` reads OQ_VERDICT and was interpolated into the Gate 3
# message, which fires SIXTEEN LINES before oq_classify assigns it. The message
# still printed (the failure is confined to the command substitution) so every
# assertion in this suite stayed green while every fire on an inactive loop
# wrote "OQ_VERDICT: unbound variable" to stderr. A survivable instance of a
# fatal class is still worth failing on.
for lit in "$VALID_STATE" "$(printf '%s' "$VALID_STATE" | jq '.active=false')" "$(printf '%s' "$VALID_STATE" | jq '.iteration=99999')"; do
  t=$(setup "$lit") || { echo "FATAL: setup"; exit 2; }
  fire "$t"
  label="stderr is clean ($(printf '%s' "$lit" | jq -r 'if .active == false then "inactive" elif .iteration > 999 then "past cap" else "normal" end' 2>/dev/null))"
  case "$ERRTXT" in
    *"unbound variable"*)
      bad "$label" "$(printf '%s' "$ERRTXT" | head -1) — a set -u abort in a spot where it happens to be survivable" ;;
    *) ok "$label" ;;
  esac
  rm -rf "$t"
done

# --- 4. The two `case "$MODE"` blocks must list the same modes ---------------
# This is structural rather than behavioural, and it is the only shape that can
# catch the failure. The worst outcome in this file is EMPTY stdout — Claude Code
# receives no decision, the turn hangs, and the log cheerfully records success.
# The way to produce it is not exotic: add a mode to the gate near the top and
# forget the inject-time case at the bottom, and REASON/SYSTEM_MSG stay unset
# while `set -u` aborts the shell after DECISION_EMITTED is already 1, so the
# EXIT trap suppresses its own fail-open.
#
# The inject-time case now has a `*)` arm, so an unknown mode fail-opens instead.
# This assertion guards the arm itself, and the parity that made the omission
# survivable in the first place. Driving it end-to-end is impossible without
# mutating the hook, because the earlier gate rejects any mode the inject-time
# case would not recognise — that non-local coupling IS the finding.
# Exactly two spaces of indent, so the nested `case "$PLAN_PATH"` inside the
# plan arm (six spaces) is not mistaken for a mode. `^esac` at column 0 ends the
# block; a nested esac is indented and does not.
modes_at() {  # modes_at <line-of-case-statement>
  awk -v start="$1" '
    NR > start && /^esac/ { exit }
    NR > start && /^  [a-z*][a-z*|]*\)/ { sub(/\).*$/, ""); sub(/^  /, ""); print }
  ' "$HOOK" | sort | tr '\n' ' '
}
CASE_LINES=$(grep -n '^case "\$MODE" in' "$HOOK" | cut -d: -f1)
CASE_COUNT=$(printf '%s\n' "$CASE_LINES" | grep -c . || true)
if [ "$CASE_COUNT" -lt 2 ]; then
  bad "two mode dispatches exist" "found $CASE_COUNT — anchor changed, this check is not running"
else
  ok "two mode dispatches exist"
  FIRST=$(printf '%s\n' "$CASE_LINES" | head -1)
  LAST=$(printf '%s\n' "$CASE_LINES" | tail -1)
  M1=$(modes_at "$FIRST"); M2=$(modes_at "$LAST")
  case "$M2" in
    *"*"*) ok "the inject-time dispatch has a catch-all arm" ;;
    *) bad "the inject-time dispatch has a catch-all arm" "arms=[$M2] — an unlisted mode leaves REASON unset and stdout EMPTY" ;;
  esac
  if [ "$M1" = "$M2" ]; then
    ok "both dispatches list the same modes ($M1)"
  else
    bad "both dispatches list the same modes" "gate=[$M1] inject=[$M2] — adding a mode to one and not the other is how stdout goes empty"
  fi
fi

echo ""
echo "== silent exit: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
