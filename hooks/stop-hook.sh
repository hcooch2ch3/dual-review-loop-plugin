#!/usr/bin/env bash
# dual-review-loop — Stop hook
#
# Re-injects "process next task" prompt while a loop is active AND the previous
# stop was a continuation of our injection (not a fresh user prompt).
# Defaults to fail-open on any error: NEVER trap the user.
#
# State file:   <project-root>/.claude/dual-review-loop.state.json
# Lock dir:     <project-root>/.claude/dual-review-loop.lock        (mkdir-atomic)
# Inflight:     <project-root>/.claude/dual-review-loop.inflight   (sentinel for in-progress iter)
# Log file:     <project-root>/.claude/dual-review-loop.log
# Briefs:       <project-root>/.claude/reviews/iter-NNN.md
#
# Gates (each fails-open with approve; some also cleanup state):
#   0   state file missing
#   0.5 jq missing
#   1   JSON parse fails
#   2   schema mismatch
#   3   active != true
#   4   session_id mismatch (phantom defense, cross-session)
#   5   phantom defense (same-session): hook didn't inject the previous turn
#   6   idle timeout exceeded (24h default) — runs early, right after Gate 3,
#       so a dead cross-session state is collected instead of paused forever.
#       An in-flight marker defers it for MARKER_LEASE_SECONDS, no longer.
#   7   in-flight marker present (mid-iter, do not re-fire)
#   8   plan_path missing/relative
#   9   plan has no unfinished tasks (AND no uncommitted changes)
#   10  max_iterations reached
#   10b max_minutes reached (wall-clock cap; default 0 = disabled)
#   11  Open Questions in previous brief
#   12  lock not acquired (another hook instance running)
#
# Otherwise: lock + iter++ + compute next brief path + write inflight marker +
# atomic state write + emit {"decision":"block","reason":<jq-built prompt>}.

set -u

# Anchor every path + git call to a stable repo root rather than the hook's
# cwd (which can drift in multi-repo Claude Code sessions). We resolve from
# `git rev-parse --show-toplevel` once, falling back to cwd when not in a
# git repo. All subsequent git calls use `git -C "$REPO_ROOT"`.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

LOG_FILE="$REPO_ROOT/.claude/dual-review-loop.log"
STATE_FILE="$REPO_ROOT/.claude/dual-review-loop.state.json"
LOCK_DIR="$REPO_ROOT/.claude/dual-review-loop.lock"
# Lock ownership. Only the invocation whose `mkdir "$LOCK_DIR"` succeeded may
# remove it. Before this flag existed every exit path ran an unconditional
# `rmdir`, so an instance that LOST the race deleted the winner's lock and
# mutual exclusion collapsed (dual review: defect G).
LOCK_HELD=0
# A lock is only ever held for the lifetime of ONE hook invocation — seconds,
# bounded by the CLI's hook timeout. So a lock dir older than this cannot have a
# live holder and is safe to reclaim. This is NOT the pid-liveness check the plan
# rejected for state GC: that risked deleting a loop that lives for hours, whereas
# a lock outliving its own process by 10 minutes is definitionally dead.
LOCK_STALE_MINUTES=10
# Set to 1 by every path that prints a decision. The EXIT trap emits a fail-open
# approve when it is still 0, so no future crash can end the turn silently.
DECISION_EMITTED=0
INFLIGHT_FILE="$REPO_ROOT/.claude/dual-review-loop.inflight"
REVIEWS_DIR="$REPO_ROOT/.claude/reviews"
IDLE_TIMEOUT_SECONDS=$((24 * 3600))
# How long an in-flight marker may postpone idle collection. This is a
# DECISION, not a derived value: it must exceed IDLE_TIMEOUT_SECONDS or the
# exemption can never apply, and it must be finite or a marker left behind by
# a crashed instance would protect a dead state forever — which is the
# immortal-state defect the GC exists to fix, in a new form.
MARKER_LEASE_SECONDS=$((48 * 3600))
PHANTOM_GRACE_SECONDS=600   # if hook fires within 10min of last inject, assume continuation
# v1: plan-mode only (legacy). v2: adds `mode` field + cumulative gates +
# task mode. Both accepted so v1 in-flight loops do not break when the hook is
# upgraded ahead of the command (codex dual review high #2 — atomic migration).
SCHEMA_VERSIONS_OK="v1 v2"

# Release the lock only if this invocation acquired it. Returns 0 unconditionally
# so a caller on an exit path never sees a failure from cleanup. (An earlier
# comment justified this by claiming a non-zero return would re-enter the ERR
# trap. That was wrong: ERR is not inherited by functions without `set -E`, which
# this hook does not set. Verified. The explicit return is kept regardless.)
release_lock() {
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
  return 0
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE" 2>/dev/null
}

approve() {
  DECISION_EMITTED=1
  printf '{"decision":"approve"}\n'
  # release lock if we hold it
  release_lock
  exit 0
}

# Cleanup state + approve (terminal: loop ends here)
# Terminal: delete state + approve. Optional 2nd arg = user-facing systemMessage.
# Deletion is the one outcome the user cannot undo and cannot see: an approve with
# no message ends the turn indistinguishably from success and from a hang. Paths
# that end a loop the user did not ask to end MUST pass a message.
cleanup_and_approve() {
  log "$1"
  DECISION_EMITTED=1
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  release_lock
  # Enforced here rather than at the call sites. A lint that reads the call sites
  # cannot see an argument that is empty after expansion, and every terminal path
  # added later would have to remember to be checked. This way a silent one is
  # impossible by construction and leaves a BUG line naming itself.
  #
  # ${2:-} and not "$2": this script runs under `set -u`, so expanding an absent
  # $2 aborts the shell — and DECISION_EMITTED is already 1 by then, so the EXIT
  # trap suppresses its own fail-open and stdout comes out EMPTY. That is worse
  # than the silence this is meant to remove.
  local msg="${2:-}"
  if [ -z "$msg" ]; then
    log "BUG: terminal path with no user message — using a generic one: $1"
    msg="dual-review-loop ended and cleared its state ($1). Nothing you committed was touched — only the plugin's own state file and marker. Start a new loop to continue."
  fi
  # The last messageless fallback in the file, and it is the one that DELETES
  # state. Its two siblings were given static messages; this one kept a bare
  # approve, so a jq failure here would clear a loop with no explanation at all.
  # No reachable trigger was found (jq is guaranteed by an earlier gate), which
  # is exactly why it is worth closing rather than arguing about.
  jq -n --arg m "$msg" '{"decision":"approve","systemMessage":$m}' 2>/dev/null \
    || printf '{"decision":"approve","systemMessage":"dual-review-loop ended and cleared its state. Nothing you committed was touched — only the plugin state file and marker. Check .claude/dual-review-loop.log for the reason, then start a new loop."}\n'
  exit 0
}

# Soft pause: do not inject this turn, but keep state for user-driven resume.
# Optional 2nd arg = user-facing systemMessage (surfaced in Claude Code UI so
# the user actually sees how to recover; without it the pause is silent and
# users can't tell why their loop stopped advancing).
soft_pause() {
  log "SOFT-PAUSE: $1 (state preserved)"
  DECISION_EMITTED=1
  release_lock
  # Same enforcement as cleanup_and_approve, and for a sharper reason. The two
  # DELETING helpers made silence structurally impossible while this one — the
  # helper that PRESERVES state — took a bare-approve branch. That inverted the
  # risk: a silent soft-pause leaves an ACTIVE loop that looks frozen, which is
  # the exact symptom this work exists to remove, and unlike its two siblings it
  # left no BUG line naming itself. The call sites that grow are this one's.
  #
  # ${2:-} and not "$2": under `set -u` an absent $2 aborts the shell, and
  # DECISION_EMITTED is already 1 by then, so the EXIT trap suppresses its own
  # fail-open and stdout comes out EMPTY.
  local msg="${2:-}"
  if [ -z "$msg" ]; then
    log "BUG: soft-pause with no user message — using a generic one: $1"
    msg="dual-review-loop paused this turn without advancing ($1). Its state is preserved, so it can pick up again; run /dual-review-loop:cancel-loop to stop it for good."
  fi
  jq -n --arg m "$msg" '{"decision":"approve","systemMessage":$m}' 2>/dev/null \
    || printf '{"decision":"approve","systemMessage":"dual-review-loop paused this turn without advancing; its state is preserved. See .claude/dual-review-loop.log."}\n'
  exit 0
}

# These two live up here with the other helpers, NOT down beside Gate 11 where
# they are mainly used. Bash resolves a function at CALL time, so a definition
# below its caller is simply not there: Gate 7 consults the brief and sat 200
# lines above the definitions, so the lookup failed, the `|| VAR=""` fallback
# swallowed it, and the gate reported "no open question" for every brief it was
# handed. Silent and total. A golden row for marker-plus-open-question is what
# surfaced it. Keep them above every caller.

# The third state.
#
# The classifier used to have two outcomes: the exact heading terminated the
# loop, everything else advanced. Dual review measured twelve near misses that
# all fell to "advance" — a suffixed heading, a decorated one, a lowercase one, a
# section whose body is prose or a table rather than a list. On a gate that
# exists so the loop cannot settle a reviewer disagreement by itself, EVERY
# ambiguity was resolving toward the loop settling it by itself.
#
# So: exact heading with a real item -> terminate (oq_first_item, unchanged).
#     Open-Questions-SHAPED but not actionable -> pause here, state preserved.
#     Anything else -> advance.
#
# This deliberately does NOT re-terminate on suffixed headings. That was measured
# as a net regression (reviewers use "(unscored)" and "→ 해소됨" for their own
# notes) and the measurement stands. Pausing is the difference: the loop stops
# and says which heading it saw, instead of walking past it in silence. Renaming
# the heading either way clears it.
#
# Prints a one-line description of what it saw; exit 0 when it saw something.
# No apostrophes in the awk program — it lives inside single quotes.
oq_ambiguous() {
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }

    /^###?[[:space:]]/ {
      head = $0
      sub(/[[:space:]]+$/, "", head)
      if (in_oq && length($1) <= level) { in_oq = 0; seen_item = 0 }
      # The exact bare heading opens a section this function inspects the BODY
      # of. Its heading is the terminal detector business; its unreadable body
      # is ours.
      if (head ~ /^###?[[:space:]]+Open Questions$/) {
        level = length($1); in_oq = 1; seen_item = 0
        next
      }
      probe = tolower(head)
      sub(/^#+[[:space:]]*/, "", probe)   # the hashes are not part of the title
      gsub(/[*_`]/, "", probe)            # emphasis is decoration
      sub(/^[^a-z]+/, "", probe)          # leading emoji, numbering, punctuation
      # The phrase must START the title, not merely appear in it. An unanchored
      # substring test paused on real documents that NEGATE the phrase
      # ("## No Open Questions", "## Resolved Open Questions") and on documents
      # merely ABOUT the feature ("### Task 3: Open Questions 판정을 …").
      if (probe ~ /^open[[:space:]]+questions/) {
        found = 1
        print head
        exit
      }
      next
    }

    # Body of an exact section. Reached only when the terminal detector already
    # answered no, so anything it CAN read is not ours to judge.
    in_oq {
      line = $0
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^[[:space:]]*$/) next

      # A top-level item is the terminal detector business.
      if (line ~ /^([-*+]|[0-9]+[.)])[[:space:]]+/) { seen_item = 1; next }
      # An INDENTED item under one is a note nested beneath it — the terminal
      # detector documents ignoring those on purpose, and pausing on them
      # re-creates the false positive that rule exists to remove. An indented
      # item with nothing above it is orphaned content, and nothing else sees it.
      if (line ~ /^[[:space:]]+([-*+]|[0-9]+[.)])[[:space:]]+/) {
        if (seen_item) next
        found = 1
        print line
        exit
      }

      probe = tolower(line)
      gsub(/[*_`]/, "", probe)
      sub(/^[[:space:]]+/, "", probe)
      # PREFIX-anchored, not whole-line. This project writes the answer as
      # "없다." followed by the reason on the same line, and a whole-line anchor
      # missed every one of them — the single largest measured source of false
      # pauses, and the reason the branch was briefly deleted outright.
      if (probe ~ /^(없다|없음|해당[[:space:]]*없음|none|no[[:space:]]+open[[:space:]]+questions|n\/a)([[:space:]]|[.,;:。]|$)/) next
      if (probe ~ /^\(none/) next
      if (probe ~ /^\(없[음다]/) next
      # A table separator carries no content of its own.
      if (probe ~ /^\|?[[:space:]]*:?-+:?[[:space:]]*(\|[[:space:]]*:?-+:?[[:space:]]*)*\|?$/) next
      found = 1
      print line
      exit
    }
    END { exit !found }
  '
}

# The text Gate 7 and Gate 11 classify, resolved ONCE from whichever source is
# available: the brief named in state, else the last assistant message in the
# transcript.
#
# These were two separate call sites, each running the detector inline. When the
# third classifier state was added it went into the brief-file arm only, so a
# brief arriving through the transcript kept the old two-outcome behaviour and an
# ambiguous heading advanced in silence — the exact thing the third state exists
# to prevent, reintroduced in the branch no golden row can see. Resolving the
# text once and classifying it in one place is what makes that class of gap
# impossible rather than merely fixed.
oq_source_text() {
  if [ -n "$LAST_BRIEF_PATH" ] && [ -f "$LAST_BRIEF_PATH" ]; then
    cat "$LAST_BRIEF_PATH" 2>/dev/null || true
    return 0
  fi
  # The transcript belongs to the session firing the hook, NOT necessarily to the
  # loop in the state file. Classifying a foreign session let the idle GC quote
  # unrelated work as "the decision in the review brief" while the same sentence
  # admitted "Brief: <none>" — a specific, checkable-sounding, false claim on a
  # path that deletes state. Only read it when the loop is this session.
  # Ownership must be PROVEN, not merely non-conflicting. The first version
  # refused the transcript only when the two ids DIFFERED, so an empty id on
  # either side — a hand-written state file, a hook input without the field —
  # read as "no conflict" and the stranger transcript was used anyway. On a gate
  # this file calls fail-closed, unknown has to resolve to "do not read".
  [ -n "$SESSION_ID_HOOK" ] && [ "$SESSION_ID_HOOK" = "$SESSION_ID_STATE" ] || return 0
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    local last
    last=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || last=""
    if [ -n "$last" ]; then
      printf '%s' "$last" \
        | jq -r '.message.content | map(select(.type=="text")) | map(.text) | join("\n")' 2>/dev/null \
        || true
    fi
  fi
  return 0
}

# Classify the brief once, into exactly the three states the gates act on.
# Sets OQ_VERDICT (stop | pause | clear) and OQ_DETAIL. Never returns non-zero:
# it runs under `set -u` with an ERR trap, and a classifier that can abort the
# shell is worse than one that says "clear".
oq_classify() {
  local txt
  txt=$(oq_source_text) || txt=""
  OQ_VERDICT=clear
  OQ_DETAIL=""
  [ -n "$txt" ] || return 0
  if OQ_DETAIL=$(printf '%s' "$txt" | oq_first_item 2>/dev/null); then
    OQ_VERDICT=stop
    return 0
  fi
  if OQ_DETAIL=$(printf '%s' "$txt" | oq_ambiguous 2>/dev/null); then
    OQ_VERDICT=pause
    return 0
  fi
  OQ_DETAIL=""
  return 0
}

# Appended to a terminal message when the loop is ending with a decision still
# unanswered in the last brief.
#
# The classification was hoisted so that BOTH readers get it — and then only two
# gates read it, while six other exits kept ending loops without it. Round-2
# review reproduced the worst one: every plan task checked off, a real
# disagreement in the brief, and the hook reporting "the loop finished" while
# deleting the state. The gate that exists to prevent that sits 140 lines below
# and is never reached. A gate that ends a loop has to say what it is ending on.
# Declared at definition time, not at first assignment. oq_classify sets these,
# but it runs after Gate 3 — whose message interpolates oq_suffix — so on an
# inactive loop the read happened before the write and `set -u` aborted the
# command substitution. That one was survivable (the message printed, minus the
# note); the same shape after DECISION_EMITTED=1 is the empty-stdout failure this
# file is built around. Give them a safe value at the point they are introduced
# and the ordering stops being load-bearing.
OQ_VERDICT=clear
OQ_DETAIL=""

oq_suffix() {
  case "$OQ_VERDICT" in
    stop)
      printf ' NOTE: the last review brief still holds an unanswered question — %s (brief: %s). Ending here does not resolve it.' \
        "$(printf '%s' "$OQ_DETAIL" | head -c 160)" "${LAST_BRIEF_PATH:-<none>}"
      ;;
    pause)
      printf ' NOTE: the last review brief has a section shaped like an open question that the loop could not read — %s (brief: %s). Worth a look before you treat this run as settled.' \
        "$(printf '%s' "$OQ_DETAIL" | head -c 160)" "${LAST_BRIEF_PATH:-<none>}"
      ;;
  esac
}

oq_first_item() {
  awk '
    # Fenced blocks are quoted material, not document structure. A brief that
    # shows an example Open Questions section inside ``` must not be read as
    # having one, and a shell comment inside a fence must not end a real section.
    # Measured: without this, "## Open Questions" followed by a ```bash block
    # containing "# rebuild the index" skipped the real question underneath it.
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }

    # The trailing anchor is load-bearing. Dropping it was measured as a net
    # regression over the real briefs: it starts stopping on
    # "## Open Questions (unscored)" and "## Open Questions → 해소됨", which are
    # reviewers using the section for their own notes. That collision is
    # semantic and no regex resolves it.
    /^###?[[:space:]]+Open Questions[[:space:]]*$/ { level = length($1); in_oq = 1; next }

    # End on an h2/h3 at the same level or shallower, so a sub-heading nested
    # inside the section does not close it. An h1 deliberately does NOT close it,
    # matching the rule this replaces: treating a stray "# note" as a boundary
    # would skip the question under it, and a skipped disagreement is the one
    # outcome this gate exists to prevent. Over-stopping is the safe side.
    /^###?[[:space:]]/ { if (length($1) <= level) in_oq = 0 }

    # Top-level list items only. Matching indented ones re-stops on a note nested
    # under a placeholder ("- 없음" then "  - but see X").
    #
    # "N." and "N)" count. They were excluded until dual review found a real
    # brief on this machine — a dual-review synthesis written FOR THIS REPO —
    # whose two blocking decisions sat under numbered bullets and were walked
    # straight past. The plan prompt further down already teaches the model that
    # "N. [ ]" is a checkbox marker alongside "- [ ]"; the detector and that
    # prompt disagreed about what a list item is, in the same file.
    #
    # No apostrophes in this awk program. It lives inside single quotes, so one
    # terminates the string and breaks the whole script — measured, right here.
    in_oq && /^([-*+]|[0-9]+[.)])[[:space:]]+/ {
      item = $0
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", item)
      sub(/[[:space:]]+$/, "", item)
      probe = tolower(item)
      if (probe ~ /^[-*+[:space:]]*$/) next                    # a thematic break
      # Placeholders are not questions. These rules only ever REMOVE stops.
      # Kept identical to the sibling classifier, ANCHOR included. These two have
      # now diverged twice: first the token list (없다 in one and not the other),
      # then the anchor (prefix in one, whole-line here). The second divergence
      # was the worse one — it TERMINATED the loop and deleted state on a bullet
      # reading "없다. 두 리뷰어가 갈린 지점이 없고…", quoting the word for "none"
      # back to the user as the question needing their decision.
      #
      # A prefix anchor is what this project actually writes: the answer is the
      # token, then the reason, on one line. Its risk is a real question that
      # merely STARTS with a placeholder token ("None of the reviewers agree") —
      # measured at 0 occurrences across 435 briefs, and stylistically opposed to
      # the "token, then why" construction. If you change this anchor, change the
      # other one in the same commit; the agreement test will tell you.
      if (probe ~ /^(없음|없다|해당[[:space:]]*없음|none|no[[:space:]]+open[[:space:]]+questions|n\/a)([[:space:]]|[.,;:。]|$)/) next
      if (probe ~ /^\(none/) next
      found = 1
      print item
      exit
    }
    END { exit !found }
  '
}


# Is this state idle-dead — past the idle timeout with nothing to excuse it?
#
# Shared by the one GC site so the judgement lives in a single place. Callers
# must only reach this with a schema the hook accepts (Gate 2); an unknown
# schema may name its timestamp fields differently, every read would fall back
# to 0, `NOW - 0 > TIMEOUT` would always be true, and the GC would delete every
# future-schema state it saw.
#
# The in-flight marker buys a bounded extension, not immunity. A state whose
# marker is still within MARKER_LEASE_SECONDS was plausibly mid-iteration, so
# it is handed to Gate 7 rather than collected. `last_injected_at_epoch` is the
# marker's clock because the hook writes both at the same moment; when it is
# absent it reads 0, the comparison is false, and there is NO exemption. That
# polarity is deliberate — it matches the behaviour before any exemption
# existed, so a legacy state is never protected by a field it does not have.
idle_dead() {  # idle_dead <now> <last_activity> <marker_path> <last_injected_at>
  [ "$(( $1 - $2 ))" -gt "$IDLE_TIMEOUT_SECONDS" ] || return 1
  if [ -f "$3" ] && [ "$4" -gt 0 ]; then
    marker_age=$(( $1 - $4 ))
    # Bounded on BOTH sides. A negative age — a marker timestamped in the future,
    # from clock skew, a bad RTC, or a state file copied between machines — is
    # always less than the lease, so a one-sided test granted a PERMANENT
    # exemption and recreated the immortal state this GC exists to prevent.
    # A future timestamp carries no evidence of liveness, so it gets no exemption,
    # matching the absent-field polarity.
    if [ "$marker_age" -ge 0 ] && [ "$marker_age" -lt "$MARKER_LEASE_SECONDS" ]; then
      return 1
    fi
  fi
  return 0
}

# Hard fail-open: error path, clean everything
fail_open() {
  log "FAIL-OPEN: $1"
  DECISION_EMITTED=1
  rm -f "$STATE_FILE" "$INFLIGHT_FILE" 2>/dev/null
  release_lock
  # Same rule as cleanup_and_approve, and these are the error exits — corrupt
  # state, an unreadable plan, a failed atomic write — so the user has even less
  # chance of guessing what happened. Thirteen call sites reached this with no
  # message at all.
  #
  # The jq-less path was documented here as unfixable, on the grounds that the
  # message is built with jq. That was wrong: the fallback message is a CONSTANT,
  # and a static systemMessage via bare printf is already proven at the in-flight
  # pause below. It matters because this path also deletes the state file — a
  # transient PATH glitch used to destroy a loop with no output whatsoever.
  #
  # Only the reason string needs jq (it interpolates $1), so the two branches say
  # different amounts. That is the honest split: specific when we can be, generic
  # when we cannot, silent never.
  # fail_open deletes state too, so it owes the same note cleanup_and_approve
  # owes. The invariant was written against one helper because that is the one
  # the reported exits happened to use.
  jq -n --arg r "$1" --arg oq "$(oq_suffix)" '{"decision":"approve","systemMessage":("dual-review-loop stopped on an error it cannot recover from (" + $r + "). Its state file and marker were cleared; nothing you committed was touched. Fix the cause and start a new loop." + $oq)}' 2>/dev/null \
    || printf '{"decision":"approve","systemMessage":"dual-review-loop stopped on an unrecoverable error and cleared its state file and marker. Nothing you committed was touched. Check .claude/dual-review-loop.log, then start a new loop."}\n'
  exit 0
}

# The trap is the one exit handler the message work did not reach, and it was
# both silent and destructive.
#
# It used to `rm -f "$INFLIGHT_FILE"`. That marker is half of Gate 7's completion
# evidence (marker + inflight_base_sha); deleting one half without the other made
# the NEXT fire read branch (a) "the LLM cleared it — iteration finished" and
# inject over work that never committed. A silent error became a false
# completion, which is the opposite of the fail-safe direction this file claims.
# Nothing the trap does needs the marker gone — release_lock is the cleanup that
# matters — so it stays.
#
# The message is a plain printf with NO jq and NO expansion inside the string:
# the trap fires precisely when something unexpected already went wrong, and a
# message that itself fails to build is worse than a generic one. $LINENO goes
# in the log, where a failure to expand it costs nothing.
trap 'log "ERR trap fired (line $LINENO)"; release_lock; printf "{\"decision\":\"approve\",\"systemMessage\":\"dual-review-loop hit an internal error and did not advance this turn. Its state and in-flight marker are untouched. See .claude/dual-review-loop.log for the line number.\"}\n"; DECISION_EMITTED=1; exit 0' ERR

# Belt and braces for the lock. Every exit path calls release_lock explicitly,
# but a hook killed mid-run (CLI hook timeout, Ctrl-C on the turn) takes none of
# them and leaves the dir behind. release_lock is idempotent, so firing it again
# here costs nothing. SIGKILL still cannot be caught — that is what the stale
# reclaim at Gate 12 is for.
trap 'if [ "$DECISION_EMITTED" -ne 1 ]; then log "FAIL-OPEN: exited without emitting a decision"; printf "{\"decision\":\"approve\"}\n"; fi; release_lock' EXIT
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM

HOOK_INPUT=$(cat 2>/dev/null || echo "")

# Gate 0: state file exists?
[ -f "$STATE_FILE" ] || approve

# Gate 0.5: jq available?
command -v jq >/dev/null 2>&1 || fail_open "jq not on PATH"

# Gate 12 (early): acquire lock via mkdir (atomic)
mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
if mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_HELD=1
else
  # Reclaim an orphan before giving up. Until ownership tracking landed, the
  # loser of the race deleted the winner's lock unconditionally — which broke
  # mutual exclusion, but incidentally cleared any lock left behind by a killed
  # instance. Removing that was right, and it removed the only cleanup with it:
  # an orphaned lock became PERMANENT. This gate precedes every other gate,
  # including the idle GC, so a single orphan wedged the loop forever and the
  # state could never be collected. Found by adversarial review, reproduced
  # against a control.
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
    log "lock dir older than ${LOCK_STALE_MINUTES}min — no live holder is possible; reclaiming"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null && LOCK_HELD=1
  fi
fi
if [ "$LOCK_HELD" -ne 1 ]; then
  log "lock held by another hook instance; soft-pause"
  soft_pause "lock contention" \
    "dual-review-loop: another hook instance holds the lock, so this turn did not advance. A lock with no live holder is reclaimed automatically after ${LOCK_STALE_MINUTES} minutes. To clear it now: rmdir $LOCK_DIR"
fi

# Gate 1: JSON parses AND is an object?
#
# `jq -e .` only asks "does this parse, and is it truthy". `[]`, `123` and
# `"str"` all pass it, and the very next line runs `jq -r '.schema // ""'` on
# them, which exits non-zero and trips the ERR trap. The result was that a file
# which does not parse at all got the full fail_open explanation while a merely
# wrong-shaped one got a bare approve — the more corrupt input was handled
# better than the less corrupt one. Ask the real question here instead.
if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
  fail_open "state file is not a JSON object (unparseable, or parses to an array/string/number)"
fi

SCHEMA=$(jq -r '.schema // ""' "$STATE_FILE")
ACTIVE=$(jq -r '.active // false' "$STATE_FILE")
PLAN_PATH=$(jq -r '.plan_path // ""' "$STATE_FILE")
# Every numeric field below is coerced at the jq boundary. `//` only substitutes
# for null/false, so a string, bool or float written by a hand-edit or an external
# tool passed through verbatim and detonated later in bash arithmetic: under
# `set -u` an identifier-shaped value like "unknown" is an unbound-variable abort
# that killed the shell before ANY decision was emitted — a fail-open violation on
# a hook that runs on every Stop event. `floor` also flattens float epochs, which
# otherwise printed raw bash diagnostics and silently read as not-idle.
ITERATION=$(jq -r 'if (.iteration|type)=="number" then (.iteration|floor) else 0 end' "$STATE_FILE")
MAX_ITERATIONS=$(jq -r 'if (.max_iterations|type)=="number" then (.max_iterations|floor) else 20 end' "$STATE_FILE")
# Fallback 0 = disabled. NOTE this is a fallback, not a migration: a loop already
# in flight carries an explicit wall-clock cap in its state file, written by the
# command at start, and keeps whatever value it was given — so the old
# unreachable cap persists for those runs until they end or are cancelled.
# Lowering a fallback is forbidden by the mid-flight rule; raising one, as here,
# is safe but reaches only states that omit the field.
# max_iterations is the binding cap; a wall-clock
# cap that fits 20 iterations does not exist, because Gate 10b measures
# elapsed time since started_at_epoch — including every minute the loop
# sits paused waiting for the user — and deletes state when it fires.
MAX_MINUTES=$(jq -r 'if (.max_minutes|type)=="number" then (.max_minutes|floor) else 0 end' "$STATE_FILE")
SESSION_ID_STATE=$(jq -r '.session_id // ""' "$STATE_FILE")
STARTED_AT=$(jq -r 'if (.started_at_epoch|type)=="number" then (.started_at_epoch|floor) else 0 end' "$STATE_FILE")
LAST_ITER_AT=$(jq -r 'if (.last_iter_at_epoch|type)=="number" then (.last_iter_at_epoch|floor) else 0 end' "$STATE_FILE")
LAST_INJECTED_AT=$(jq -r 'if (.last_injected_at_epoch|type)=="number" then (.last_injected_at_epoch|floor) else 0 end' "$STATE_FILE")
LAST_INJECTED_ITER=$(jq -r 'if (.last_injected_iter|type)=="number" then (.last_injected_iter|floor) else 0 end' "$STATE_FILE")
LAST_BRIEF_PATH=$(jq -r '.last_brief_path // ""' "$STATE_FILE")

# v2 fields (default to "plan mode + Infinity gates" so v1 state is byte-equivalent).
# Cumulative cap fields are hook-OWNED — computed from git diff + filesystem,
# not trusted from prompt-driven state updates (dual review #8 high #1).
MODE=$(jq -r '.mode // "plan"' "$STATE_FILE")
MAX_FILES=$(jq -r 'if (.max_files|type)=="number" then (.max_files|floor) else 999999 end' "$STATE_FILE")
MAX_LOC=$(jq -r 'if (.max_loc|type)=="number" then (.max_loc|floor) else 999999 end' "$STATE_FILE")
MAX_REVIEWS=$(jq -r 'if (.max_reviews|type)=="number" then (.max_reviews|floor) else 999999 end' "$STATE_FILE")
STARTED_AT_SHA=$(jq -r '.started_at_sha // ""' "$STATE_FILE")
# HEAD recorded when the current in-flight iter was injected (hook-owned).
# Gate 7 uses it as ground truth for "did this iter's commit land?" so marker
# clearing no longer depends on the LLM running the prompt's `rm` step. Empty
# for v1 / upgraded-mid-flight state → Gate 7 cannot detect → never false-advances.
INFLIGHT_BASE_SHA=$(jq -r '.inflight_base_sha // ""' "$STATE_FILE")

NOW_EPOCH=$(date +%s)

# Gate 2: schema (accept any version in SCHEMA_VERSIONS_OK)
case " $SCHEMA_VERSIONS_OK " in
  *" $SCHEMA "*) ;;
  # Preserve state on mismatch (could be a future-schema downgrade by an
  # older hook). fail_open here would nuke the user's loop; soft-pause lets
  # them downgrade/upgrade manually instead.
  *) soft_pause "schema mismatch (got=$SCHEMA expected one of: $SCHEMA_VERSIONS_OK) — state preserved; downgrade hook or cancel manually" \
       "dual-review-loop paused: state schema '$SCHEMA' unknown. To resume: install a hook supporting this schema, OR run /dual-review-loop:cancel-loop (or rm $STATE_FILE) to start over." ;;
esac

# Gate 2b: numeric fields must actually be numeric.
#
# The coercion above keeps a corrupt value from detonating in bash arithmetic, but
# coercing to 0 quietly RELABELS the state: a garbage timestamp reads as epoch
# 1970, the idle GC collects it, and the user is told "no activity for over 24h"
# — a specific factual claim about their loop that never happened, on the path
# where they are least able to check it. Corrupt state is not idle state. Say so.
#
# Deliberately AFTER Gate 2: a future schema may legitimately type these fields
# differently, and fail_open deletes state. Running this first would delete every
# future-schema state — the exact failure the schema gate exists to prevent, and
# what midflight M4/M5 assert against.
# Classified HERE: after the state fields are read, before any gate that can end
# the loop while a decision is outstanding.
#
# It sat below the numeric-field gate, so that gate deleted state and printed its
# open-question note as an empty string — the note read a verdict nobody had
# computed. That is the same "structurally dead note" defect fixed one commit ago
# at Gate 3, at three more sites. The two gates still above this point (jq
# missing, state not a JSON object) genuinely cannot classify — there is no jq,
# or no usable state — and are exempted by name in the docs test rather than
# left to look compliant. Both are pure reads of HOOK_INPUT with no other ordering
# needs, and the classifier needs the session id to refuse a foreign transcript.
SESSION_ID_HOOK=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

# Classify the brief BEFORE the idle GC, not just before Gate 7.
#
# The GC decides whether a loop is dead from timestamps alone, and `soft_pause`
# never advances a timestamp — so a loop this hook is deliberately holding looks
# identical to an abandoned one. It was collected at 24h with the message "no
# activity for over 24h", which is false: there was activity every turn and the
# hook refused to advance. That is the same defect already fixed below for
# corrupt timestamps, where the comment says "corrupt state is not idle state".
# Paused state is not idle state either, and the GC can only know that if the
# verdict exists before it runs.
oq_classify

BAD_NUMERIC=$(jq -r '
  [ to_entries[]
    | select(.key | test("^(iteration|max_iterations|max_minutes|started_at_epoch|last_iter_at_epoch|last_injected_at_epoch|last_injected_iter|max_files|max_loc|max_reviews|reviews_baseline)$"))
    | select(.value != null and (.value | type) != "number")
    | .key ]
  | join(", ")' "$STATE_FILE" 2>/dev/null || echo "")
[ -z "$BAD_NUMERIC" ] || fail_open "non-numeric value in numeric state field(s): $BAD_NUMERIC"


# Gate 3: active
[ "$ACTIVE" = "true" ] || cleanup_and_approve "state.active != true" \
  "dual-review-loop: the loop was already marked inactive, so its state was cleared. Nothing you committed was touched.$(oq_suffix)"


# Gate 6 (idle GC): runs HERE, ahead of the defensive gates, not after them.
#
# It used to sit between Gate 5 and Gate 7. Every defensive gate in front of it
# exits before reaching it — Gate 4 soft-pauses on a session mismatch, Gate 5 on
# a missing continuation signal — so a state owned by a session that no longer
# exists could never be collected. It was preserved, re-examined on the next
# fire, paused again, forever. That path is 214 fires / 58% of the field baseline.
#
# Scope the claim honestly: this collects the subset of that path which is ALSO
# past the idle timeout. A cross-session state younger than 24h still soft-pauses
# at Gate 4 exactly as before. What fraction of the 214 is old enough to collect
# has NOT been measured — bucketing those fires by state age is the check that
# would settle it, and it has not been run.
#
# It must stay AFTER Gate 2. Gate 2 is the schema check, and collecting an
# unknown schema would delete state the hook does not understand — see idle_dead.
# It is also after Gate 3, so a state the user explicitly cancelled is logged as
# cancelled rather than as an idle timeout.
LAST_ACT=$LAST_ITER_AT
[ "$LAST_ACT" -eq 0 ] && LAST_ACT=$STARTED_AT
if idle_dead "$NOW_EPOCH" "$LAST_ACT" "$INFLIGHT_FILE" "$LAST_INJECTED_AT"; then
  # Three arms, not two. Collapsing stop and pause here would repeat the exact
  # conflation this file splits apart at Gate 7 and Gate 11 — telling a user whose
  # brief heading says "→ 해소됨" that they never answered a question. Collected
  # either way (the lease is what bounds a hold, and an unbounded one is worse),
  # but the claim has to match what was actually seen.
  case "$OQ_VERDICT" in
    stop)
      cleanup_and_approve "idle timeout (>${IDLE_TIMEOUT_SECONDS}s) while held on an open question" \
        "dual-review-loop ended after more than 24h. It was NOT idle — it was holding for a decision in the review brief that was never answered: $(printf '%s' "$OQ_DETAIL" | head -c 160). Brief: ${LAST_BRIEF_PATH:-<none>}. Its state was cleared; answer the question and start a new loop."
      ;;
    pause)
      cleanup_and_approve "idle timeout (>${IDLE_TIMEOUT_SECONDS}s) while held on an unreadable Open Questions section" \
        "dual-review-loop ended after more than 24h. It was NOT idle — it was holding on a section shaped like an open question that it could not read as a decision, and nobody resolved it: $(printf '%s' "$OQ_DETAIL" | head -c 160). Brief: ${LAST_BRIEF_PATH:-<none>}. Check whether that section was a decision for you. Its state was cleared; start a new loop when you know."
      ;;
  esac
  cleanup_and_approve "idle timeout (>${IDLE_TIMEOUT_SECONDS}s)" \
    "dual-review-loop: this loop had no activity for over $((IDLE_TIMEOUT_SECONDS / 3600))h, so its state was collected and the loop has ended. Nothing you committed was touched — only the plugin's own state file and marker. To pick the work back up, start a new loop on the same plan."
fi

# Gate 4: cross-session phantom defense
# `|| echo ""` and not a bare pipe: jq exits non-zero when its INPUT does not
# parse, and HOOK_INPUT is whatever the CLI handed us. Without the fallback a
# malformed stdin trips the ERR trap instead of being treated as "no session id
# supplied". The numeric-field read above already guards this way.
[ -n "$SESSION_ID_STATE" ] || fail_open "state.session_id empty"
if [ -n "$SESSION_ID_HOOK" ] && [ "$SESSION_ID_HOOK" != "$SESSION_ID_STATE" ]; then
  soft_pause "different session ($SESSION_ID_HOOK != $SESSION_ID_STATE)" \
    "dual-review-loop: this loop belongs to a different Claude Code session, so this turn did not advance it. Its state is untouched. Resume it from the session that started it, or run /dual-review-loop:cancel-loop to clear it."
fi

# Gate 5: same-session phantom defense
# If we've already injected at least once, the previous user-turn must contain
# our sentinel. Sentinels (mode-aware):
#   plan: "[dual-review-loop iter <N>"
#   task: "[dual-review-loop task iter <N>"
if [ "$LAST_INJECTED_ITER" -gt 0 ]; then
  CONTINUATION=0
  # Strategy A: time window — if injection was very recent, assume continuation
  if [ "$LAST_INJECTED_AT" -gt 0 ]; then
    GAP=$((NOW_EPOCH - LAST_INJECTED_AT))
    if [ "$GAP" -lt "$PHANTOM_GRACE_SECONDS" ]; then
      CONTINUATION=1
    fi
  fi
  # Strategy B: transcript sentinel check. Mode-pinned (no cross-mode escape)
  # and digit-anchored ("iter 1" must not match "iter 10/11/...").
  # We still scan the whole transcript (parsing JSONL last-user-message safely
  # across schema variants is brittle); the digit anchor + mode pin + iter#
  # equality together make stale matches structurally rare. Hook-owned counter
  # advances LAST_INJECTED_ITER each fire, so once iter advances the old
  # sentinel for iter N stops matching iter N+1's check.
  if [ "$CONTINUATION" -eq 0 ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Anchor uses ([^0-9]|$) so end-of-line / end-of-file also terminates
    # the iter# (bare `[^0-9]` would fail to match if a future format change
    # ever drops the trailing `/MAX]` suffix that today's format guarantees).
    case "$MODE" in
      task) SENTINEL_RE="\[dual-review-loop task iter ${LAST_INJECTED_ITER}([^0-9]|\$)" ;;
      *)    SENTINEL_RE="\[dual-review-loop iter ${LAST_INJECTED_ITER}([^0-9]|\$)" ;;
    esac
    if grep -qE "$SENTINEL_RE" "$TRANSCRIPT_PATH" 2>/dev/null; then
      CONTINUATION=1
    fi
  fi
  if [ "$CONTINUATION" -eq 0 ]; then
    soft_pause "no continuation signal (last_injected_iter=$LAST_INJECTED_ITER, gap=${GAP:-?}s) — user likely took control" \
      "dual-review-loop: the loop did not advance because this turn does not look like a continuation of iteration $LAST_INJECTED_ITER — you likely took over manually. The state is preserved; it picks up again on a turn that follows its instructions, or run /dual-review-loop:cancel-loop to stop it."
  fi
fi

# Gate 6 ran here until the idle GC moved ahead of Gates 4/5 (see above). It is
# NOT duplicated here: a second unconditional copy would collect exactly the
# states the marker lease just exempted, making the lease dead code.

# Gate 7: in-flight marker — previous iter not yet finalized.
# UNION completion detection (dual review #11): the marker is hook-created but
# was historically LLM-cleared (prompt step 9 `rm inflight`). When the LLM
# never reached that step — plan mode blocking the commit being the canonical
# case, also early stops / errors — the marker stayed and this gate became a
# permanent dead-end (no advance, no re-inject) → frozen loop.
# Now we advance when EITHER signal says the iter is done:
#   (a) marker absent      → LLM cleared it (normal path, incl. legitimate
#                            no-op iters that commit nothing; see task §6), OR
#   (b) marker present BUT  → hook proves via git the commit landed
#       commit landed         (HEAD moved forward past inflight_base_sha).
# Soft-pause ONLY when the marker is present AND no commit landed. The git
# backstop makes recovery auto-resume the moment a commit lands (Claude's or a
# manual one) — the old manual `rm .inflight` recovery step is no longer needed.
if [ -f "$INFLIGHT_FILE" ]; then
  INFLIGHT_ITER=$(cat "$INFLIGHT_FILE" 2>/dev/null || echo "?")
  COMMIT_LANDED=0
  if [ -n "$INFLIGHT_BASE_SHA" ]; then
    CUR_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$CUR_HEAD" ] && [ "$CUR_HEAD" != "$INFLIGHT_BASE_SHA" ]; then
      # HEAD moved. Confirm FORWARD motion (base is an ancestor of HEAD) so an
      # unrelated reset/checkout doesn't read as a completed iter. Note:
      # `merge-base --is-ancestor` exits 1 on a normal "not an ancestor" answer
      # — it MUST stay inside this `if` or the ERR trap (top of file) would fire.
      if git -C "$REPO_ROOT" merge-base --is-ancestor "$INFLIGHT_BASE_SHA" "$CUR_HEAD" 2>/dev/null; then
        COMMIT_LANDED=1
      fi
    fi
  fi
  if [ "$COMMIT_LANDED" -eq 1 ]; then
    log "in-flight iter $INFLIGHT_ITER: commit landed (HEAD $CUR_HEAD past base $INFLIGHT_BASE_SHA) — clearing marker, advancing"
    rm -f "$INFLIGHT_FILE" 2>/dev/null || true
    # Fall through to the normal advance path below (gates 8-11 + iter++).
  else
    # Marker present, no commit detected. Don't inject (no fighting plan mode).
    # The recovery advice MUST differ by whether the git backstop is armed: when
    # inflight_base_sha is empty (legacy v1 / non-git / upgraded mid-flight) we
    # genuinely cannot auto-detect a landed commit, so manual recovery is still
    # required and we must NOT claim auto-resume or "no commit since base"
    # (dual review #11: Codex C2/C3 + code-reviewer P2 — over-promising message).
    # Ask WHY before saying anything. This gate fires on the marker, but the
    # marker is a symptom shared by several causes, and the most common one is
    # not the one the message used to name.
    #
    # The injected prompt orders the steps: step 5 says "if ## Open Questions is
    # non-empty: STOP, do NOT continue", step 8 is the commit, step 9 clears the
    # marker. So an OBEDIENT model stops at step 5 with the marker still set and
    # nothing committed — which lands here, on this gate, which sits ahead of
    # Gate 11. The old message never said "Open Questions", told the user about
    # plan mode instead, and advised "exit plan mode and let it finish": an
    # instruction to let an iteration through that was deliberately halted on an
    # unresolved reviewer disagreement. Following the escape hatch it offered
    # (rm the marker) then reached Gate 11, which deletes the state file. Wrong
    # cause, wrong remedy, and stable across fires.
    #
    # Forcing a message onto every exit path does not fix this. The message was
    # bound to the gate that fired rather than to the cause of the stop, and only
    # ordering fixes that. So: look at the brief first, and let the real cause
    # speak even though a different gate is doing the talking.
    # Two verdicts, two different claims. Saying "the brief has an open question"
    # for a `pause` is a flat assertion about a document that often says the
    # opposite in its own heading ("(저신뢰 — 판정을 좌우하지 않음)"). Only `stop`
    # has actually read a question.
    OQ_CAVEAT=""
    [ -n "$INFLIGHT_BASE_SHA" ] || OQ_CAVEAT=" (Note: this loop has no baseline SHA — legacy or non-git state — so a landed commit cannot be auto-detected here.)"
    if [ "$OQ_VERDICT" = "stop" ]; then
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} stopped on a reviewer disagreement, not on a commit problem. The brief has an open question and the loop must not decide it for you — $(printf '%s' "$OQ_DETAIL" | head -c 160). Brief: ${LAST_BRIEF_PATH:-<none>}. Answer it, then run /dual-review-loop:cancel-loop and start a new loop. Do NOT just clear the marker to make this go away: that lets the loop continue past a disagreement nobody settled.${OQ_CAVEAT}"
    elif [ "$OQ_VERDICT" = "pause" ]; then
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} did not commit, and its brief has a heading shaped like an open question that the loop cannot read as a decision — $(printf '%s' "$OQ_DETAIL" | head -c 160). Brief: ${LAST_BRIEF_PATH:-<none>}. Check whether that section is a decision for you. If it is not, rename the heading to anything that does not begin with 'Open Questions' and the loop continues; /dual-review-loop:cancel-loop stops it instead.${OQ_CAVEAT}"
    elif [ -n "$INFLIGHT_BASE_SHA" ]; then
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} has not committed yet (plan mode can block commits, or it stopped early) and its brief shows no open question. It auto-resumes the moment a commit lands — exit plan mode and let it finish. If this iteration legitimately produced no commit, run /dual-review-loop:cancel-loop (or rm .claude/dual-review-loop.inflight)."
    else
      PAUSE_MSG="dual-review-loop: iter ${INFLIGHT_ITER} is in-flight but completion can't be auto-detected (no baseline SHA — legacy state or non-git repo). Its brief shows no open question. If the work already committed, rm .claude/dual-review-loop.inflight to resume; otherwise run /dual-review-loop:cancel-loop."
    fi
    log "in-flight marker present (iter=$INFLIGHT_ITER) — no commit detected; not advancing (base_sha=${INFLIGHT_BASE_SHA:-<none>})"
    # Keep state + marker so the next fire / a debugger can still see it.
    release_lock
    DECISION_EMITTED=1
    jq -n --arg m "$PAUSE_MSG" '{"decision":"approve","systemMessage":$m}' 2>/dev/null \
      || printf '{"decision":"approve","systemMessage":"dual-review-loop: previous iter still in-flight; not advancing"}\n'
    exit 0
  fi
fi

# Mode dispatch: plan/task share gates 10-11 + state update; gates 8-9
# differ (plan inspects plan_path checkboxes; task validates task_description).
# Unknown mode fails open so a corrupted state never traps the user.
TASK_DESCRIPTION=""
TASK_LOG_PATH=""

case "$MODE" in
  plan)
    # Gate 8 (plan): plan_path absolute + exists
    case "$PLAN_PATH" in
      /*) ;;
      *)  fail_open "plan_path not absolute: $PLAN_PATH" ;;
    esac
    [ -f "$PLAN_PATH" ] || fail_open "plan_path missing: $PLAN_PATH"

    # Gate 9 (plan): plan has unfinished tasks? (also check working tree
    # clean to avoid premature completion)
    UNFINISHED=$(grep -cE '^([-*+]|[0-9]+\.) \[ \]' "$PLAN_PATH" 2>/dev/null | head -1)
    UNFINISHED=${UNFINISHED:-0}
    if [ "$UNFINISHED" -eq 0 ] 2>/dev/null; then
      # No unfinished tasks. But if working tree has uncommitted changes,
      # the last iter's commit may not have landed yet — don't declare done.
      #
      # Scope this to REPO_ROOT, not dirname("$PLAN_PATH"). The loop's repo is
      # REPO_ROOT by construction — the state file lives under it and that is
      # where iteration commits land. A plan kept at the `/plan` default
      # (~/.claude/plans/) is outside any repo, so `git -C` there failed and
      # the whole dirty check was SKIPPED: the loop declared completion over
      # the user's uncommitted code. The rev-parse guard stays because
      # REPO_ROOT falls back to pwd when the hook runs outside a git repo.
      if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        DIRTY=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1)
        if [ -n "$DIRTY" ]; then
          log "no unfinished tasks but working tree dirty — soft-pause for manual commit"
          # This lands at the finish line: every task is done and the loop
          # stops one gate short of completing. Without a message the turn
          # just ends and the user cannot tell success from a hang.
          soft_pause "no unfinished tasks but uncommitted changes present" \
            "dual-review-loop: every task in the plan is complete, but the working tree still has uncommitted changes, so the loop did not declare completion. Commit or stash them and the loop finishes on the next turn. If the changes are plugin artifacts, add .claude/dual-review-loop.*, .claude/dual-review-loop/ and .claude/reviews/ to .gitignore.$(oq_suffix)"
        fi
      fi
      # Completion is a CLAIM, not just an exit: it tells the user the run
      # succeeded and then deletes the evidence. Never make it over a brief that
      # still holds a decision — fall through instead, and let Gate 11 end the
      # loop with the question as the stated reason. Gate 10 may fire first; its
      # message now carries the question too.
      if [ "$OQ_VERDICT" != "clear" ]; then
        log "all tasks complete BUT the last brief still holds an open question — not declaring completion; deferring to Gate 11"
      else
        cleanup_and_approve "all tasks complete after $ITERATION iterations" \
          "dual-review-loop: every task in the plan is checked off — the loop finished after $ITERATION iteration(s). The review briefs are in .claude/reviews/."
      fi
    fi
    ;;
  task)
    # Gate 8 (task): task_description present + within length bounds
    TASK_DESCRIPTION=$(jq -r '.task_description // ""' "$STATE_FILE")
    if [ -z "$TASK_DESCRIPTION" ]; then
      fail_open "task_description empty in state"
    fi
    TASK_DESC_LEN=${#TASK_DESCRIPTION}
    if [ "$TASK_DESC_LEN" -gt 2000 ]; then
      fail_open "task_description too long ($TASK_DESC_LEN chars; max 2000)"
    fi
    # Gate 9 (task): task log path read (best-effort — log existence is the
    # command's responsibility, hook only references it in the inject prompt
    # so the LLM can read prior iter context).
    TASK_LOG_PATH=$(jq -r '.task_log_path // ""' "$STATE_FILE")
    ;;
  *)
    fail_open "unknown mode in state: $MODE"
    ;;
esac

# Gate 10: max_iterations
if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  cleanup_and_approve "max_iterations reached ($ITERATION >= $MAX_ITERATIONS)" \
    "dual-review-loop: stopped at the iteration cap ($ITERATION of $MAX_ITERATIONS), with tasks still unfinished in the plan. Start a new loop with a higher --max-iters to continue.$(oq_suffix)"
fi

# Gate 10b: max_minutes (wall-clock cap since started_at_epoch)
if [ "$MAX_MINUTES" -gt 0 ] && [ "$STARTED_AT" -gt 0 ]; then
  ELAPSED_SEC=$(( NOW_EPOCH - STARTED_AT ))
  CAP_SEC=$(( MAX_MINUTES * 60 ))
  if [ "$ELAPSED_SEC" -ge "$CAP_SEC" ]; then
    cleanup_and_approve "max_minutes reached (${ELAPSED_SEC}s >= ${CAP_SEC}s / ${MAX_MINUTES}min cap)" \
      "dual-review-loop: stopped at the wall-clock cap (${MAX_MINUTES} min). This measures elapsed time, not work done — the clock runs while the loop waits for you. Start a new loop to continue.$(oq_suffix)"
  fi
fi

# Gates 10c-e: cumulative caps. Hook-computed from git + filesystem so the
# LLM cannot bypass them by skipping a counter-update step (dual review #8
# Critical/I1). v1 state has no started_at_sha → cum_files/loc stay 0 → no
# enforcement (v1 default 999999 max also keeps this no-op for legacy state).
CUM_FILES=0
CUM_LOC=0
CUM_REVIEWS=0
if [ -n "$STARTED_AT_SHA" ] && git -C "$REPO_ROOT" cat-file -e "$STARTED_AT_SHA" 2>/dev/null; then
  # Baseline SHA still resolvable in this repo (rebase/squash-merge could have
  # orphaned it; in that case we soft-pause below rather than silently treat
  # the run as 0-LOC and bypass budget caps).
  if STATS=$(git -C "$REPO_ROOT" diff --shortstat "$STARTED_AT_SHA" HEAD 2>/dev/null); then
    # Parse "N files changed, X insertions(+), Y deletions(-)" (each piece optional).
    FILES_TOK=$(printf '%s' "$STATS" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' | head -1)
    INS_TOK=$(printf '%s' "$STATS"  | grep -oE '[0-9]+ insertions?'    | grep -oE '[0-9]+' | head -1)
    DEL_TOK=$(printf '%s' "$STATS"  | grep -oE '[0-9]+ deletions?'     | grep -oE '[0-9]+' | head -1)
    CUM_FILES=${FILES_TOK:-0}
    CUM_LOC=$(( ${INS_TOK:-0} + ${DEL_TOK:-0} ))
  fi
elif [ -n "$STARTED_AT_SHA" ]; then
  # SHA exists in state but not in repo (rebase / squash-merge dropped it).
  # Silently leaving CUM_*=0 would disable budget caps; soft-pause for the
  # user to decide (re-baseline by editing state, or cancel cleanly).
  soft_pause "started_at_sha=$STARTED_AT_SHA no longer resolvable (rebase?) — cumulative caps cannot be enforced; resolve manually or cancel" \
    "dual-review-loop paused: baseline commit $STARTED_AT_SHA was lost (rebase/squash/gc). To resume: edit '.started_at_sha' in $STATE_FILE to current HEAD (jq + temp+mv), OR run /dual-review-loop:cancel-loop. (The 'do not edit state' rule applies to hook-owned counter fields, not this recovery edit.)"
fi
# Review-count gate: count files written **after** loop start so prior runs'
# briefs don't pre-exhaust max_reviews. Hook records reviews_baseline on its
# first fire (when iteration was still 0); subsequent fires use that.
REVIEWS_BASELINE=$(jq -r 'if (.reviews_baseline|type)=="number" then (.reviews_baseline|floor) else -1 end' "$STATE_FILE")
CUR_REVIEWS_COUNT=$(ls "$REVIEWS_DIR"/iter-*.md 2>/dev/null | wc -l | tr -d ' ')
CUR_REVIEWS_COUNT=${CUR_REVIEWS_COUNT:-0}
if [ "$REVIEWS_BASELINE" = "-1" ]; then
  REVIEWS_BASELINE=$CUR_REVIEWS_COUNT
fi
CUM_REVIEWS=$(( CUR_REVIEWS_COUNT - REVIEWS_BASELINE ))
# Negative delta means briefs were deleted under us. Just clamping to 0 would
# silently disarm max_reviews until the count climbs back above the old
# baseline. Re-baseline instead so the cap stays meaningful.
if [ "$CUM_REVIEWS" -lt 0 ]; then
  log "reviews_baseline re-init: count $CUR_REVIEWS_COUNT < baseline $REVIEWS_BASELINE (briefs deleted)"
  REVIEWS_BASELINE=$CUR_REVIEWS_COUNT
  CUM_REVIEWS=0
fi

if [ "$CUM_FILES" -ge "$MAX_FILES" ]; then
  cleanup_and_approve "max_files reached ($CUM_FILES >= $MAX_FILES)" \
    "dual-review-loop: stopped after touching $CUM_FILES files (cap $MAX_FILES). Review what landed, then start a new loop if that was expected.$(oq_suffix)"
fi
if [ "$CUM_LOC" -ge "$MAX_LOC" ]; then
  cleanup_and_approve "max_loc reached ($CUM_LOC >= $MAX_LOC)" \
    "dual-review-loop: stopped after changing $CUM_LOC lines (cap $MAX_LOC). Review what landed, then start a new loop if that was expected.$(oq_suffix)"
fi
if [ "$CUM_REVIEWS" -ge "$MAX_REVIEWS" ]; then
  cleanup_and_approve "max_reviews reached ($CUM_REVIEWS >= $MAX_REVIEWS)" \
    "dual-review-loop: stopped after $CUM_REVIEWS dual-review runs (cap $MAX_REVIEWS). Start a new loop to continue.$(oq_suffix)"
fi
# (consecutive_same_failure gate removed in dual review #8 — fingerprint
# was undefined across iters; max_iterations is the hard stop on stuck verify.)

# The Open Questions classifier, in one place.
#
# It lived in two copies — the brief arm and the transcript fallback — that had
# to be kept identical by hand, and no golden row exercises the fallback because
# observe() hardcodes transcript_path:"". A drift between them would therefore
# never turn a light red. tests/transcript-arm.test.sh covers the arm the matrix
# cannot reach.
#
# Reads stdin rather than taking a path. A path parameter would force the
# transcript arm to materialise a temp file, and a failed mktemp there lands on
# the ERR trap: a bare approve with no message, i.e. a new silent exit added by
# a refactor whose whole point is removing them.
#
# `found=1 ... exit` with `END { exit !found }`, not `exit 0` in the rule: in awk
# an exit inside a rule transfers to END, and an exit in END REPLACES the status.
# `print; exit 0` + `END { exit 1 }` therefore always reports "nothing found" and
# silently disables this gate. Measured:
#   awk 'BEGIN{print "x"; exit 0} END{exit 1}' </dev/null; echo $?   -> 1

# Gate 11: Open Questions in the previous brief?
# Already classified above (oq_classify), from the brief file or the transcript.
# Reading the verdict here rather than re-deriving it is the point: the two
# sources used to be classified by two different bodies of code, and only one of
# them learned about the third state.
OPEN_Q_FOUND=0
OQ_ITEM=""
OQ_AMBIG=""
case "$OQ_VERDICT" in
  stop)  OPEN_Q_FOUND=1; OQ_ITEM="$OQ_DETAIL" ;;
  pause) OQ_AMBIG="$OQ_DETAIL" ;;
esac

# Ambiguity pauses; it does not terminate. Terminating on a suffixed heading was
# measured as a net regression (reviewers use the section for their own notes),
# and that measurement still holds — what changed is that the loop no longer
# walks past one in silence. State is preserved, so renaming the heading either
# way resolves it and the loop picks up where it was.
# Gate on the verdict, not on the detail string. Gate 7 above reads OQ_VERDICT
# while this read OQ_AMBIG — two readers of "one answer" asking different
# questions. Latent only because the classifier never prints an empty detail.
if [ "$OQ_VERDICT" = "pause" ]; then
  soft_pause "ambiguous Open Questions in brief ($OQ_AMBIG)" \
    "dual-review-loop paused: the brief has a heading shaped like an Open Questions section that the loop cannot read as a decision — $(printf '%s' "$OQ_DETAIL" | head -c 160). The loop holds rather than guess, because this section is how a reviewer disagreement reaches you. Two ways out, and they do NOT do the same thing. (1) It is only a reviewer's note: rename the heading to anything not beginning with 'Open Questions' and the loop RESUMES where it left off. (2) It is a real decision: rename it to exactly '## Open Questions' with each item on its own top-level bullet — the loop then ENDS and hands it to you, clearing its state (in task mode that also re-baselines the file/LOC/review budgets). Until you do one of those this message repeats every turn, and after 24h the loop is collected. Brief: ${LAST_BRIEF_PATH:-<none>}. /dual-review-loop:cancel-loop stops it now."
fi

if [ "$OPEN_Q_FOUND" -eq 1 ]; then
  # Quote the item. Without it the user is told a brief has a question but not
  # which, and has to open the file to find out what stopped their loop.
  # head -c, not cut -c: cut counts characters or bytes depending on locale, so
  # it either does nothing or splits a Korean codepoint. A byte cut can land
  # mid-codepoint; jq accepts that and renders U+FFFD, which is cosmetic.
  cleanup_and_approve "Open Questions detected in last brief — user decision needed" \
    "dual-review-loop: stopped because the review brief has a question that needs your decision. Brief: ${LAST_BRIEF_PATH:-<none>}. First item: $(printf '%s' "${OQ_ITEM:-<could not read>}" | head -c 200). Note this section means the two REVIEWERS DISAGREED — a reviewer's own follow-up notes belong under a different heading. Answer it, then start a new loop — note that a new loop re-baselines the cumulative caps (max_files/max_loc/max_reviews) to the current HEAD, so in task mode the budget starts over."
fi

# All gates passed — prepare to inject next iteration
NEXT_ITER=$((ITERATION + 1))
ITER_PADDED=$(printf '%03d' "$NEXT_ITER")
NEXT_BRIEF_PATH="${REVIEWS_DIR}/iter-${ITER_PADDED}.md"
# An unwritable .claude (or a regular file sitting where the dir must go) fails
# here. Without the guard that is an ERR-trap exit; with it the user is told.
mkdir -p "$REVIEWS_DIR" 2>/dev/null \
  || fail_open "cannot create the reviews directory: $REVIEWS_DIR (is .claude writable?)"

# `iteration` is hand-seeded (see the state template in commands/), so it can be
# rewound — re-seeding after a terminal gate sets it back to 0 and this path is
# computed a second time. The injected prompt tells the model to save the brief
# there verbatim, so a collision is silent data loss: the previous iteration's
# evidence is overwritten and nothing reports it.
#
# Skip to the first free name instead. The bound is relative to where we started,
# so the refusal below can state the range it actually probed rather than a
# hard-coded one it never checked.
BRIEF_PROBE=$NEXT_ITER
BRIEF_LIMIT=$((NEXT_ITER + 999))
while [ -e "$NEXT_BRIEF_PATH" ] && [ "$BRIEF_PROBE" -lt "$BRIEF_LIMIT" ]; do
  BRIEF_PROBE=$((BRIEF_PROBE + 1))
  ITER_PADDED=$(printf '%03d' "$BRIEF_PROBE")
  NEXT_BRIEF_PATH="${REVIEWS_DIR}/iter-${ITER_PADDED}.md"
done
if [ -e "$NEXT_BRIEF_PATH" ]; then
  # Recoverable: the user archives or deletes one file and the next turn proceeds.
  # soft_pause therefore, not a terminal path — losing the iteration counter and
  # the baselines over a full directory would be a worse outcome than the pause.
  soft_pause "brief path exhausted: iter-$(printf '%03d' "$NEXT_ITER") through iter-${ITER_PADDED} all exist" \
    "dual-review-loop paused: every brief filename from iter-$(printf '%03d' "$NEXT_ITER").md to iter-${ITER_PADDED}.md is already taken in $REVIEWS_DIR, so there is no free name for the next one. Archive or delete some and the loop continues on the next turn."
fi
if [ "$BRIEF_PROBE" -ne "$NEXT_ITER" ]; then
  log "brief path collision: iter-$(printf '%03d' "$NEXT_ITER").md exists — using iter-${ITER_PADDED}.md"
fi

# HEAD at the moment we inject iter NEXT_ITER (before the LLM does any work).
# Gate 7 on the NEXT fire compares HEAD against this to detect whether the
# iter's commit landed — hook-owned completion signal, no LLM-`rm` dependence.
# Empty when not a git repo → Gate 7 falls back to the marker-only path.
NEXT_INFLIGHT_BASE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")

# Atomic state update — hook owns ALL state fields
TEMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXX" 2>/dev/null)" || fail_open "mktemp failed"
jq --argjson next "$NEXT_ITER" \
   --argjson now "$NOW_EPOCH" \
   --argjson baseline "$REVIEWS_BASELINE" \
   --arg brief "$NEXT_BRIEF_PATH" \
   --arg inflightbase "$NEXT_INFLIGHT_BASE_SHA" \
   '.iteration = $next
    | .last_iter_at_epoch = $now
    | .last_injected_at_epoch = $now
    | .last_injected_iter = $next
    | .last_brief_path = $brief
    | .reviews_baseline = $baseline
    | .inflight_base_sha = $inflightbase' \
   "$STATE_FILE" > "$TEMP_FILE" 2>/dev/null

if [ ! -s "$TEMP_FILE" ]; then
  rm -f "$TEMP_FILE"
  fail_open "jq state update produced empty file"
fi
mv "$TEMP_FILE" "$STATE_FILE" 2>/dev/null || { rm -f "$TEMP_FILE"; fail_open "atomic mv failed"; }

# Write in-flight marker (Claude removes it after step 7 commit)
printf '%s\n' "$NEXT_ITER" > "$INFLIGHT_FILE" 2>/dev/null || true

log "iter $NEXT_ITER → injecting (brief target: $NEXT_BRIEF_PATH)"

# Build REASON via jq to safely escape any shell special chars.
# Two prompt shapes — plan (checkbox-driven) vs task (free-form inline).
# IMPORTANT: task prompts must NOT contain the token "ralph" / "RALPH" — that
# brand collides with another plugin family and could cross-trigger their
# stop hook. Sentinel format is "[dual-review-loop iter N/M]" (plan) or
# "[dual-review-loop task iter N/M]" (task); a token-blacklist regression
# test pins this.
case "$MODE" in
  plan)
    REASON=$(jq -nr \
      --argjson iter "$NEXT_ITER" \
      --argjson max "$MAX_ITERATIONS" \
      --arg plan "$PLAN_PATH" \
      --arg brief "$NEXT_BRIEF_PATH" \
      --arg inflight "$INFLIGHT_FILE" '
"[dual-review-loop iter \($iter)/\($max)]

Plan: \($plan)

Process exactly ONE next unfinished task from the plan checkbox list:

1. Pick the first \"- [ ]\" (or \"* [ ]\" / \"+ [ ]\" / \"N. [ ]\") item in \($plan)
2. Execute it (make code changes, run tests, etc.)
3. Invoke the dual-review skill programmatically. Include this block in your dispatch prompt:
     dual-review-invocation:
       mode: programmatic
       execution_mode: wait
       caller: dual-review-loop
       scope:
         type: working-tree
       meta_review: false
4. Read the dual-review synthesis brief. Save it verbatim to: \($brief)
5. Apply auto-fixes per policy:
   - Every item under \"## ✅ Accept — 양쪽 독립 합치\" (Tier 1)
   - Items under \"## ✅ Accept — 단일 리뷰어, 기술적으로 타당\" with Severity ≥ Important
   - Skip Minor items (log to commit footer)
   - If \"## Open Questions\" non-empty: STOP, report to user. Do NOT continue.
6. Re-verify (re-run task tests / verify command)
7. Flip the plan checkbox \"- [ ]\" → \"- [x]\" for the task you just completed.
8. Atomic commit: code changes + plan checkbox flip + deferred-minor footer.
9. After commit lands: delete the in-flight marker (rm \($inflight)). This signals the hook that this iter is done.
10. Stop. The hook will re-fire for the next iter or terminate naturally.

Do NOT manually edit .claude/dual-review-loop.state.json — the hook owns it.
To cancel: rm .claude/dual-review-loop.state.json (or run /dual-review-loop:cancel-loop)."')
    SYSTEM_MSG="dual-review-loop plan iter ${NEXT_ITER}/${MAX_ITERATIONS}"
    ;;
  task)
    REASON=$(jq -nr \
      --argjson iter "$NEXT_ITER" \
      --argjson max "$MAX_ITERATIONS" \
      --argjson max_files "$MAX_FILES" \
      --argjson max_loc "$MAX_LOC" \
      --argjson max_reviews "$MAX_REVIEWS" \
      --arg task "$TASK_DESCRIPTION" \
      --arg log "$TASK_LOG_PATH" \
      --arg brief "$NEXT_BRIEF_PATH" \
      --arg inflight "$INFLIGHT_FILE" '
"[dual-review-loop task iter \($iter)/\($max)]

Task: \($task)

Process exactly ONE next concrete sub-step that advances this task:

1. Decide one next sub-step — bias toward smaller, reviewable units (single file / single concept). If the task is now complete, do NOT invent more work; run /dual-review-loop:cancel-loop instead.
2. Execute it (make code changes, run tests, etc.)
3. Invoke the dual-review skill programmatically. Include this block in your dispatch prompt:
     dual-review-invocation:
       mode: programmatic
       execution_mode: wait
       caller: dual-review-loop
       scope:
         type: working-tree
       meta_review: false
4. Read the dual-review synthesis brief. Save it verbatim to: \($brief)
5. Apply auto-fixes per policy:
   - Every item under \"## ✅ Accept — 양쪽 독립 합치\" (Tier 1)
   - Items under \"## ✅ Accept — 단일 리뷰어, 기술적으로 타당\" with Severity ≥ Important
   - Skip Minor items (log to commit footer or task log)
   - If \"## Open Questions\" non-empty: STOP, report to user. Do NOT continue.
6. Re-verify (re-run task tests / verify command)
7. Append an iteration entry to the task log: \($log)
8. Atomic commit: code changes + task log append + deferred-minor footer.
9. After commit lands: delete the in-flight marker (rm \($inflight)).
10. Stop. The hook will re-fire for the next iter or terminate naturally.

Budget caps (hook gates): max_files=\($max_files), max_loc=\($max_loc), max_reviews=\($max_reviews). Going over any → loop ends.

Do NOT manually edit .claude/dual-review-loop.state.json — the hook owns iteration/timestamp fields.
To cancel: rm .claude/dual-review-loop.state.json (or run /dual-review-loop:cancel-loop)."')
    SYSTEM_MSG="dual-review-loop task iter ${NEXT_ITER}/${MAX_ITERATIONS}"
    ;;
  # Without this arm REASON and SYSTEM_MSG stay unset, and the jq below expands
  # them under `set -u` — which aborts the shell AFTER DECISION_EMITTED=1, so the
  # EXIT trap suppresses its own fail-open and stdout comes out EMPTY. Claude
  # Code then sees no decision at all while the log claims the inject succeeded.
  # Until now the only thing preventing that was the mode gate far above still
  # listing the same two modes: a non-local invariant guarding the worst failure
  # in this file. Adding a third mode to one case and not the other was enough.
  *)
    fail_open "unknown mode at inject time: $MODE"
    ;;
esac

# DECISION_EMITTED goes up AFTER the print, not before. Set first, it converts
# any failure inside the jq expansion into empty stdout (see the *) arm above).
jq -n --arg r "$REASON" --arg s "$SYSTEM_MSG" \
  '{"decision":"block","reason":$r,"systemMessage":$s}' 2>/dev/null || \
  fail_open "final JSON emit failed"
DECISION_EMITTED=1

# Release lock; inflight stays until Claude removes it
release_lock
exit 0
