#!/usr/bin/env bash
# dual-review-loop — documentation / constant consistency
#
# Run: bash tests/docs-consistency.test.sh
#
# WHY THIS FILE EXISTS
# Every other test in this suite drives the hook and observes its behaviour.
# None of them read commands/*.md or README.md at all, so a constant could be
# changed in the hook and left stale in three documents — or a rule could be
# stated in one command file and contradicted in the other — and the whole
# suite would stay green. That gap was recorded as a known blind spot before
# this file existed; the budget/doc-consistency work is what it guards.
#
# SCOPE, AND ITS LIMIT
# These are grep assertions over text. They pin that a claim appears where it
# has to appear and that a retired claim appears nowhere. They cannot check
# that prose is true. Keep them anchored to values a reader would ACT on
# (defaults, gate labels, recovery commands), not to phrasing.
#
# The hook is the authority for anything it implements. Where a doc states a
# constant the hook owns, the assertion derives the expected value FROM the
# hook rather than hardcoding it, so the two cannot drift apart silently.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/stop-hook.sh"
README="$ROOT/README.md"
CMD_PLAN="$ROOT/commands/dual-review-loop.md"
CMD_TASK="$ROOT/commands/dual-review-task.md"
CMD_CANCEL="$ROOT/commands/cancel-loop.md"

for f in "$HOOK" "$README" "$CMD_PLAN" "$CMD_TASK" "$CMD_CANCEL"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 2; }
done

PASS=0; FAIL=0
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }

# assert that PATTERN occurs in FILE
has() {  # has <label> <file> <ere>
  if LC_ALL=C grep -Eq -e "$3" "$2"; then ok "$1"; else fail "$1 — no match for /$3/ in ${2#"$ROOT"/}"; fi
}

# assert that PATTERN occurs NOWHERE in the shipped docs + hook
absent_everywhere() {  # absent_everywhere <label> <ere>
  local hits
  hits=$(LC_ALL=C grep -rEln -e "$2" "$HOOK" "$README" "$ROOT/commands" 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "$1"; else fail "$1 — still present in: $(echo "$hits" | sed "s|$ROOT/||" | tr '\n' ' ')"; fi
}

echo "== docs/constant consistency =="

# ---------------------------------------------------------------------------
# 1. max_minutes default. The hook's jq fallback is the authority; every doc
#    that quotes a default must quote the same number. This is the constant
#    that was arithmetically impossible (30 min vs 20 iterations x 9-14 min)
#    and the reason the cap now ships disabled.
# ---------------------------------------------------------------------------
# Anchored on the jq `else <default> end` branch. The reads were coerced to
# integers at the jq boundary, which retired the old `// <default>` spelling —
# this assertion caught that drift when it happened, which is the point of it.
HOOK_MAX_MIN=$(LC_ALL=C sed -n "s/^MAX_MINUTES=.*else \([0-9][0-9]*\) end.*/\1/p" "$HOOK" | head -1)
if [ -n "$HOOK_MAX_MIN" ]; then
  ok "hook exposes a max_minutes fallback (found: $HOOK_MAX_MIN)"
else
  fail "could not read the max_minutes fallback out of the hook — anchor changed"
fi

if [ "$HOOK_MAX_MIN" = "0" ]; then
  ok "max_minutes fallback is 0 (wall-clock cap disabled by default)"
else
  fail "max_minutes fallback is $HOOK_MAX_MIN, expected 0 — raising it back re-creates a cap that cannot fit max_iterations"
fi

has "README quotes the same max-minutes default" "$README" \
    "--max-minutes ${HOOK_MAX_MIN}([^0-9]|$)"
has "plan command quotes the same max-minutes default" "$CMD_PLAN" \
    "--max-minutes M.*default: ${HOOK_MAX_MIN}"
has "task command quotes the same max-minutes default" "$CMD_TASK" \
    "--max-minutes M.*default: ${HOOK_MAX_MIN}"

# The retired default must not survive anywhere as a claim about max-minutes.
absent_everywhere "no doc still claims a 30-minute wall-clock default" \
    "max.minutes.{0,20}(default: )?30([^0-9]|$)"

# Whichever cap binds has to be stated, or the disabled one reads as an oversight.
has "README names the binding cap" "$README" "max-iters.*(binds|binding cap)"
has "plan command names the binding cap" "$CMD_PLAN" "max_iterations.{0,2} is the binding cap"

# ---------------------------------------------------------------------------
# 2. Idle timeout. Deliberately still 24h — lowering it was considered and
#    rejected. Docs must agree with the hook's constant.
# ---------------------------------------------------------------------------
if LC_ALL=C grep -Eq '^IDLE_TIMEOUT_SECONDS=\$\(\(24 \* 3600\)\)' "$HOOK"; then
  ok "hook idle timeout is 24h"
else
  fail "hook idle timeout is no longer 24*3600 — update every doc that says 24h, then this assertion"
fi
has "README/commands: plan command states the 24h idle timeout" "$CMD_PLAN" "24h idle timeout"
has "task command states the 24h idle gate" "$CMD_TASK" "Idle > 24h"

# The in-flight marker lease EXTENDS the idle timeout, so a doc that names only
# the 24h figure is incomplete: a user watching a loop still alive at 40h has
# nothing that explains it. Derive the hours from the hook so the two cannot drift.
LEASE_H=$(LC_ALL=C sed -n "s/^MARKER_LEASE_SECONDS=\$((\([0-9][0-9]*\) \* 3600)).*/\1/p" "$HOOK" | head -1)
if [ -n "$LEASE_H" ]; then
  ok "hook exposes a marker lease (found: ${LEASE_H}h)"
else
  fail "could not read MARKER_LEASE_SECONDS out of the hook — anchor changed"
fi
IDLE_H=24
if [ -n "$LEASE_H" ] && [ "$LEASE_H" -gt "$IDLE_H" ]; then
  ok "marker lease (${LEASE_H}h) exceeds the idle timeout (${IDLE_H}h), so the exemption can apply"
else
  fail "marker lease ${LEASE_H}h does not exceed the ${IDLE_H}h idle timeout — the exemption would be unreachable dead code"
fi
# Anchored to the claim, not to the file. A bare "48h" grep passed when the lease
# sentence was deleted outright and an unrelated line mentioning 48h was added —
# measured. Require the figure to appear in the SAME paragraph as the thing it
# describes. awk RS='' is paragraph mode, which is also how the gitignore block
# below is scoped; grep cannot do this because these docs wrap mid-sentence.
for site in "$README:README" "$CMD_PLAN:plan command" "$CMD_TASK:task command"; do
  f=${site%:*}; label=${site##*:}
  if LC_ALL=C awk -v RS='' -v L="${LEASE_H}h" \
       'index($0,L) && (index($0,"marker") || index($0,"lease")) { found=1 } END { exit !found }' "$f"; then
    ok "$label states the ${LEASE_H}h lease in the same paragraph as the marker it governs"
  else
    fail "$label does not tie ${LEASE_H}h to the in-flight marker — a bare figure elsewhere in the file does not document the lease"
  fi
done

# ---------------------------------------------------------------------------
# 3. Gate labels. The hook labels cumulative caps 10c-e. README used to cite a
#    Gate 10f that has never existed.
# ---------------------------------------------------------------------------
# Two spellings have to be caught, and the first fix caught only one of them.
# The typo shipped as "Gates 10c–f" (the f follows a dash, no "10" in front), but
# "Gates 10f" and "Gates 10c-10f" are equally wrong and a pattern tailored to the
# one observed spelling passes them. Measured: both escaped the previous version.
# Covers the bare token AND any range whose upper bound is f.
absent_everywhere "no doc cites a nonexistent Gate 10f" "10f|10[a-e][^a-z0-9]*f([^a-z0-9]|$)"
has "hook labels the cumulative caps 10c-e" "$HOOK" "Gates 10c-e"

# ---------------------------------------------------------------------------
# 4. gitignore guidance. Three DISTINCT patterns: `.claude/dual-review-loop.*`
#    (state/log/lock), `.claude/dual-review-loop/` (task logs) and
#    `.claude/reviews/` (briefs). None matches the others — the first has a dot
#    where the second has a slash. Any one left untracked keeps the working
#    tree dirty, and Gate 9 refuses to declare completion over a dirty tree,
#    so a repo that followed incomplete advice can never finish a plan.
#    Every site that gives the advice must give all three.
# ---------------------------------------------------------------------------
#    Scope to the BULLET (or paragraph) giving the advice and require all three
#    patterns inside that one block. Three weaker versions were measured and all
#    three escaped: a whole-file grep matched `.claude/reviews/iter-NNN.md` in
#    unrelated prose; a +/-4 line window was satisfied by an unrelated bullet
#    three lines above; and paragraph mode failed because consecutive markdown
#    bullets form a single paragraph, so an adjacent bullet still leaked its
#    patterns in. Blocks here break on a blank line OR a new top-level bullet.
#
#    HONEST LIMIT: this is still a grep over prose. It pins that the advice names
#    three patterns together; it cannot pin that the advice is true or that anyone
#    followed it. The compliance check below is the one that is not a heuristic.
for site in "$README:README" "$CMD_PLAN:plan command" "$CMD_TASK:task command" "$CMD_CANCEL:cancel command"; do
  f=${site%:*}; label=${site##*:}
  if ! LC_ALL=C grep -q '\.gitignore' "$f"; then
    fail "$label gives no .gitignore guidance at all"
    continue
  fi
  if LC_ALL=C awk '
       /^[[:space:]]*[-*+] / || /^[[:space:]]*$/ { blk="" }
       { blk = blk " " $0 }
       blk ~ /\.gitignore/ &&
       blk ~ /dual-review-loop\.\*/ &&
       blk ~ /dual-review-loop\// &&
       blk ~ /\.claude\/reviews\// { found=1 }
       END { exit !found }' "$f"; then
    ok "$label names all three ignore patterns in the block that gives the advice"
  else
    fail "$label does not name all three ignore patterns together where it gives the advice — an unignored artifact blocks Gate 9 completion"
  fi
done

# COMPLIANCE, not advice. The four checks above police what the docs SAY; this one
# checks the only file that changes behaviour. This repo runs the loop on itself,
# so an artifact it forgets to ignore keeps its own tree dirty and makes Gate 9
# completion — the project's stated acceptance criterion — unreachable here.
# Found by adversarial review: the repo was missing its own task-log pattern while
# all four documents correctly told users to add it.
REPO_GI="$ROOT/.gitignore"
if [ -f "$REPO_GI" ]; then
  gimiss=""
  # The state/log/lock slot needs the glob OR every individual file. An earlier
  # version accepted any ONE of them, so a repo listing only the state file read
  # as compliant while an untracked .log kept the tree dirty forever — looser than
  # the failure it guards against.
  if ! LC_ALL=C grep -Eq 'dual-review-loop\.\*' "$REPO_GI"; then
    for one in state.json log lock inflight; do
      LC_ALL=C grep -Eq "dual-review-loop\\.$one" "$REPO_GI" \
        || gimiss="$gimiss .claude/dual-review-loop.$one"
    done
  fi
  LC_ALL=C grep -Eq 'dual-review-loop/' "$REPO_GI"                                || gimiss="$gimiss .claude/dual-review-loop/"
  LC_ALL=C grep -Eq '\.claude/reviews/' "$REPO_GI"                                || gimiss="$gimiss .claude/reviews/"
  if [ -z "$gimiss" ]; then
    ok "this repo's own .gitignore covers every artifact the loop writes"
  else
    fail "this repo's .gitignore omits:$gimiss — the loop would dirty its own tree and never reach 'all tasks complete' here"
  fi
else
  fail "this repo has no .gitignore — the loop's own artifacts would block Gate 9 completion"
fi

# ---------------------------------------------------------------------------
# 5. Open Questions STOP clause — FOUR enforcement points, not two.
#    Two live in the hook's injected prompts (plan + task) and two in the
#    command files, where one is worded differently and so does not match a
#    search for the hook's phrasing. If any single site loses the rule, the
#    model stops on its own before committing and before clearing the in-flight
#    marker, which strands the loop with no commit to auto-resume from.
#    sentinel-contract.test.sh covers the two hook sites; these are the two
#    nobody was reading.
# ---------------------------------------------------------------------------
HOOK_STOP_CLAUSES=$(LC_ALL=C grep -c 'Open Questions\\" non-empty: STOP' "$HOOK" || true)
if [ "${HOOK_STOP_CLAUSES:-0}" -eq 2 ]; then
  ok "hook carries the STOP clause in both injected prompts (plan + task)"
else
  fail "hook has $HOOK_STOP_CLAUSES STOP clauses in its prompts, expected 2 (plan + task)"
fi
has "task command carries the STOP clause" "$CMD_TASK" \
    '`## Open Questions` non-empty: STOP'
has "plan command carries the STOP rule (differently worded on purpose)" "$CMD_PLAN" \
    'STOP on Open Questions'

# ---------------------------------------------------------------------------
# 6. Recovery commands the docs tell users to run must name real paths. These
#    are the escape hatches; a typo here strands someone with a wedged loop.
# ---------------------------------------------------------------------------
for pathvar in 'dual-review-loop\.state\.json' 'dual-review-loop\.inflight' 'dual-review-loop\.lock'; do
  if LC_ALL=C grep -Eq "$pathvar" "$HOOK" && LC_ALL=C grep -Eqr "$pathvar" "$README" "$ROOT/commands"; then
    ok "recovery path $(echo "$pathvar" | tr -d '\\') is both implemented and documented"
  else
    fail "recovery path $(echo "$pathvar" | tr -d '\\') is not in both the hook and the docs"
  fi
done

# Deliberately requires the command on a SINGLE line: a recovery command split
# across a line wrap cannot be copy-pasted, which is the whole point of printing it.
has "README prints the stale-lock recovery command on one line" "$README" "rmdir .claude/dual-review-loop\.lock"

# ---------------------------------------------------------------------------
# 7. Stop-hook block cap. Measured at 8 per user turn, resetting each turn.
#    It is documented because "20 iterations is reachable" depends on it, and
#    an earlier plan proposed lowering max-iters on the belief that the cap was
#    a lifetime ceiling.
# ---------------------------------------------------------------------------
has "README documents the block cap and its env var" "$README" \
    "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP"
# The block-cap section must keep BOTH observations. A dogfood run injected 9
# times in one headless invocation and completed, which contradicts the earlier
# probe's "9th block is overridden". Collapsing that back to a single confident
# claim — in either direction — is the exact error this project has now made
# three times: a measurement taken under one condition, generalised to another.
if LC_ALL=C awk -v RS='' \
     '/CLAUDE_CODE_STOP_HOOK_BLOCK_CAP/ { seen=1 }
      /9 times inside a single headless invocation/ { real=1 }
      /always blocked and did no work between blocks/ { probe=1 }
      END { exit !(seen && real && probe) }' "$README"; then
  ok "README records both the probe and the real-run observation of the block cap"
else
  fail "README no longer carries both block-cap observations — do not reduce them to one claim without a new measurement"
fi

# ---------------------------------------------------------------------------
# 8. State-file ownership. The command files hand the model a JSON template to
#    write, so anything in that template is a field the model will dutifully
#    invent. Two failure shapes, both measured:
#
#    (a) A field nobody reads. `pid` was seeded by BOTH templates and read by
#        the hook ZERO times (`grep -c '"pid"' hooks/stop-hook.sh` -> 0). Dead
#        template fields are worse than noise here: they read as a contract, so
#        a later reader adds pid-liveness logic to match a field that never
#        meant anything. The absent_everywhere form is what makes this stick —
#        the templates are duplicated across two files and the natural mistake
#        is fixing one of them.
#
#    (b) A field the hook OWNS being written by hand. `inflight_base_sha` and
#        `reviews_baseline` are written by the hook's own state update (see the
#        `.reviews_baseline = $baseline | .inflight_base_sha = $inflightbase`
#        assignment). Seeding them from the command corrupts the in-flight
#        backstop and the review-budget baseline. Meanwhile `session_id` is the
#        one field that MUST be right: the hook fail-opens on an empty one and
#        soft-pauses the loop on a mismatch. Both templates have to say so, in
#        the same paragraph as the template they qualify.
# ---------------------------------------------------------------------------
absent_everywhere "no doc still seeds a pid field the hook never reads" \
    '"pid"[[:space:]]*:'
# Derive the "hook never reads it" half from the hook, so re-introducing pid
# handling there makes this assertion tell the truth instead of going stale.
if [ "$(LC_ALL=C grep -c '"pid"' "$HOOK")" -eq 0 ]; then
  ok "hook still reads no pid field (the reason the templates must not seed one)"
else
  fail "hook now reads a pid field — the templates may legitimately need it again; revisit the assertion above"
fi

# Paragraph mode: these docs wrap mid-sentence, so a line-oriented grep cannot
# require the four tokens to be part of one claim. RS='' is the same idiom the
# lease and gitignore assertions use.
for site in "$CMD_PLAN:plan command" "$CMD_TASK:task command"; do
  f=${site%:*}; label=${site##*:}
  if LC_ALL=C awk -v RS='' '
       index($0,"inflight_base_sha") && index($0,"reviews_baseline") &&
       index($0,"session_id") && (index($0,"hook-owned") || index($0,"hook owns")) { found=1 }
       END { exit !found }' "$f"; then
    ok "$label marks the hook-owned state fields and names session_id as the one that must be right"
  else
    fail "$label does not name inflight_base_sha/reviews_baseline as hook-owned alongside session_id — a hand-written baseline breaks the in-flight backstop silently"
  fi
done

# ---------------------------------------------------------------------------
# 9. Two limitations that are deliberate hook behaviour, not bugs. Both were
#    hit in real use and both look like a broken loop from the outside, so an
#    undocumented one costs a debugging session. Each assertion is paired with
#    a check against the hook, so the doc claim cannot outlive the behaviour.
# ---------------------------------------------------------------------------
# (a) Single-repo scope. Every git call is pinned to REPO_ROOT, which the hook
#     resolves once from its own cwd. Commits that land in a DIFFERENT repo are
#     invisible: the in-flight backstop sees no forward HEAD motion (no auto-
#     advance) and `git diff --shortstat` measures 0, so max_files/max_loc never
#     fire — the caps read as generous when they are simply blind.
if LC_ALL=C grep -Eq '^REPO_ROOT=\$\(git rev-parse --show-toplevel' "$HOOK" \
   && LC_ALL=C grep -q 'git -C "\$REPO_ROOT" diff --shortstat' "$HOOK"; then
  ok "hook scopes its diff counters to a single REPO_ROOT (the behaviour the limitation describes)"
else
  fail "hook no longer resolves one REPO_ROOT / no longer measures the diff there — re-check the single-repo limitation in README"
fi
if LC_ALL=C awk -v RS='' '
     index($0,"max_files") && index($0,"max_loc") &&
     (index($0,"another repo") || index($0,"different repo") || index($0,"other repo")) { found=1 }
     END { exit !found }' "$README"; then
  ok "README documents that commits into another repo neither advance the loop nor count toward max_files/max_loc"
else
  fail "README does not tie the single-repo scope to max_files/max_loc — a blind cap reads as a generous one"
fi

# (b) Open Questions is a REVIEWER-DISAGREEMENT signal, and the detector's
#     trailing anchor makes suffixed headings a deliberate non-match. Dropping
#     the anchor was measured as a net regression, so the anchor is the thing
#     the doc claim depends on: assert it is still there.
if LC_ALL=C grep -q 'Open Questions\[\[:space:\]\]\*\$' "$HOOK"; then
  ok "hook's Open Questions heading regex still anchors at end-of-line (what makes a suffixed heading not match)"
else
  fail "hook's Open Questions regex lost its trailing anchor — suffixed headings now stop the loop; README says they do not"
fi
# The claim to pin is now the THREE-state rule. A doc that says only "suffixed
# headings are not matched" describes the behaviour this replaced, and would read
# as "they are ignored" — which is the exact failure the third state removes.
# Scoped to the BULLET, not the paragraph. Consecutive markdown bullets form a
# single RS='' record, so a paragraph-mode version passed while the bullet said
# only "deliberately not matched" — the neighbouring plan-mode bullet supplied
# the word "pause" and this bullet supplied "unscored". Measured. Blocks here
# break on a blank line OR a new top-level bullet, the same way the gitignore
# assertion above is scoped.
if LC_ALL=C awk '
     /^[[:space:]]*[-*+] / || /^[[:space:]]*$/ { blk="" }
     { blk = blk " " $0 }
     blk ~ /Open Questions/ && blk ~ /unscored/ && blk ~ /paus/ { found=1 }
     END { exit !found }' "$README"; then
  ok "README documents the suffixed heading as a PAUSE, not as a silent non-match"
else
  fail "README does not say a suffixed Open Questions heading pauses the loop — describing it only as 'not matched' reads as 'ignored', which is the behaviour the third state removed"
fi
# And the hook must still have the third state the README promises.
if LC_ALL=C grep -q '^oq_ambiguous() {' "$HOOK"; then
  ok "hook still implements the third classifier state"
else
  fail "hook has no oq_ambiguous — README promises a pause the hook cannot produce"
fi
# Gate 7 must know the brief's verdict, or the most common stop reports the wrong
# cause and advises continuing past a disagreement. Anchored on ORDER, not on a
# variable name: the classification has to be resolved before the gate that reads
# it. Bash looks a function up at call time, so "defined below the caller" is the
# same as "absent" — that exact ordering bug shipped once in this file and made
# the gate answer "no open question" for every brief it was handed.
CLASSIFY_LINE=$(LC_ALL=C grep -n '^oq_classify$' "$HOOK" | head -1 | cut -d: -f1)
GATE7_LINE=$(LC_ALL=C grep -n '^if \[ -f "\$INFLIGHT_FILE" \]; then' "$HOOK" | head -1 | cut -d: -f1)
DEFN_LINE=$(LC_ALL=C grep -n '^oq_classify() {' "$HOOK" | head -1 | cut -d: -f1)
if [ -z "$CLASSIFY_LINE" ] || [ -z "$GATE7_LINE" ] || [ -z "$DEFN_LINE" ]; then
  fail "could not locate oq_classify (definition/call) or the Gate 7 marker check — anchors changed, this assertion is not running"
else
  if [ "$CLASSIFY_LINE" -lt "$GATE7_LINE" ]; then
    ok "the brief is classified before Gate 7 reads it (line $CLASSIFY_LINE < $GATE7_LINE)"
  else
    fail "oq_classify runs at line $CLASSIFY_LINE, after Gate 7 at $GATE7_LINE — the gate reports a plan-mode commit block for what is actually a reviewer disagreement, and tells the user to continue past it"
  fi
  if [ "$DEFN_LINE" -lt "$CLASSIFY_LINE" ]; then
    ok "oq_classify is defined above its caller"
  else
    fail "oq_classify is defined at line $DEFN_LINE, below the call at $CLASSIFY_LINE — bash resolves functions at call time, so the lookup fails silently"
  fi
fi
# Both sources must go through the one classifier. Two call sites is how the
# third state reached the brief-file arm and not the transcript arm.
# Count INVOCATIONS, not mentions: comments discussing the detector and the
# definition line itself are not call sites, and a naive grep -c counts them.
OQ_CALLS=$(LC_ALL=C awk '
  /^[[:space:]]*#/ { next }
  /^oq_first_item\(\) \{/ { next }
  /oq_first_item/ { n++ }
  END { print n+0 }' "$HOOK")
if [ "$OQ_CALLS" -eq 1 ]; then
  ok "oq_first_item is invoked from exactly one place (the shared classifier)"
else
  fail "oq_first_item is invoked from $OQ_CALLS places, expected 1 — the last time it had two, only one of them learned about the third classifier state and the transcript arm silently advanced"
fi


# ---------------------------------------------------------------------------
# 10. Two claims a reader ACTS on, both of which were belief before they were
#     measured, and both of which are invisible from inside a green test run.
# ---------------------------------------------------------------------------
# (a) The cumulative caps bound ONE RUN, not one task. Every terminal stop
#     deletes the state file, which carries started_at_sha and reviews_baseline,
#     so restarting re-baselines to HEAD and the budget starts over. Inert in
#     plan mode (Infinity defaults); in task mode it is the difference between a
#     budget and a suggestion, and nothing at runtime says so.
# Scoped to the BULLET/paragraph block, not to an RS='' record. Two weaker
# versions were measured escaping: one let `seen` persist across records, and the
# same-record version still passed with the paragraph deleted, because the
# Recovery section is one long bullet run in which the started_at_sha bullet says
# "max_loc" and the reviews bullet says "resets the budget window". Blocks here
# break on a blank line OR a new top-level bullet, the same scoping the gitignore
# assertion uses.
if LC_ALL=C awk '
     /^[[:space:]]*[-*+] / || /^[[:space:]]*$/ { blk="" }
     { blk = blk " " $0 }
     (blk ~ /max-loc/ || blk ~ /max_loc/) && (blk ~ /reset/ || blk ~ /re-baseline/) { found=1 }
     END { exit !found }' "$README"; then
  ok "README states that the cumulative caps reset when a loop ends"
else
  fail "README does not say the cumulative caps re-baseline on restart — a task capped at --max-loc N can spend a multiple of N across stops with nothing warning the user"
fi
# The hook must say it too, at the stop where it actually happens.
if LC_ALL=C grep -q 're-baselines the cumulative caps' "$HOOK"; then
  ok "the Open Questions stop names the budget reset it causes"
else
  fail "the Open Questions stop no longer mentions the budget reset — 'start a new loop' reads as continuation"
fi

# (b) The delivery channel. Every message this plugin prints rides on
#     systemMessage in a NON-blocking response; if that field were dropped the
#     whole message effort would be inert. The repo went a release believing it
#     rather than measuring it. Keep the measurement, and keep the honest limit
#     next to it — the same standard the block-cap section already sets.
# Two independent anchors rather than one section range. The range version passed
# with the limit paragraph deleted: the subsection sat inside "Stop-hook block
# budget", whose own probe note says "headless", so the range swallowed it. (That
# misplacement is also why this now lives in its own section.) Instead: the
# evidence must name the renderer case, and the limit must be a paragraph that
# says BOTH what was not established and which mode it applies to.
# The limit must be asserted ADJACENTLY, on one line, not as two tokens loose in
# a paragraph. Measured: rewriting the sentence to "**Not established:** nothing
# at all. Headless … was measured too and does emit it" kept both tokens in the
# paragraph and the assertion stayed green while the README now claimed the
# OPPOSITE of the measurement. An honesty check that cannot tell a limit from a
# denial of that limit is worse than none — it certifies the inversion.
if LC_ALL=C grep -q 'hook_system_message' "$README" \
   && LC_ALL=C grep -Eq '\*\*Not established:\*\*[[:space:]]*headless' "$README"; then
  ok "README records how systemMessage delivery was measured AND what was not measured"
else
  fail "README no longer carries both halves of the systemMessage measurement — do not reduce it to a bare claim, in either direction, without a new measurement"
fi

# ---------------------------------------------------------------------------
# 11. EVERY gate that ends a loop must account for the brief's verdict.
#     This is the consumer-side invariant. The producer side was already pinned
#     (classify before Gate 7, defined above its caller, one call site) and the
#     suite still stayed green while six terminal exits ignored the answer —
#     including the one that reports success and deletes the state. Pinning who
#     COMPUTES the verdict says nothing about who READS it.
#
#     A terminal message either carries $(oq_suffix), or is on the allowlist
#     below with the reason it does not need to. The allowlist is the point: it
#     forces the next person to justify a silent terminal exit instead of just
#     adding one.
# ---------------------------------------------------------------------------
# Allowed to omit the suffix, and why:
#   "It was NOT idle"        - IS the open-question message (the OQ_VERDICT arm)
#   "no activity for over"   - only reachable when the verdict is clear
#   "every task in the plan is checked off" - guarded; not reached unless clear
#   "the review brief has a question" - Gate 11 itself; it IS the message
# BOTH state-deleting helpers, not just the one the reported exits happened to
# use. fail_open also runs `rm -f "$STATE_FILE"` and has a dozen call sites; the
# first version of this assertion scanned only cleanup_and_approve and was
# therefore scoped to the instances, which is the very complaint it answers.
#
# The allowlist matches WHOLE LINES, not substrings. A substring alternation
# exempted any future message that merely happened to contain an exempt phrase —
# measured — so it could swallow an exit nobody ever reviewed.
OQ_ALLOW_RE='^[[:space:]]*"dual-review-loop( ended after more than 24h\.|: this loop had no activity for over|: every task in the plan is checked off|: stopped because the review brief has a question)'
# Follow the backslash continuation rather than a fixed line window. A +/-3 line
# window leaked out of one `case` arm into the next one\'s soft_pause message and
# reported it as a missing note — measured. A call site is the helper line plus
# exactly the lines its continuations reach.
# Three escapes were demonstrated against the previous version and all three are
# closed here. (1) A call whose MESSAGE is on the same line as the call was never
# inspected, because the message check ran before `pending` was set — so the
# same line is now checked too. (2) A message not beginning with the literal
# "dual-review-loop was simply dropped; every terminal message must now begin
# with it, so an unusual opening is a violation instead of an exit. (3) See the
# state-deletion scan below for the third.
MISSING=$(LC_ALL=C awk -v allow="$OQ_ALLOW_RE" '
  function check(line, n) {
    if (line !~ /oq_suffix/ && line !~ allow) print n
  }
  {
    is_call = ($0 ~ /(cleanup_and_approve|fail_open) /)
    if (is_call && $0 ~ /"dual-review-loop/) { check($0, NR); pending = 0 }
    else if (is_call) pending = 1
    else if (pending && prev_cont && /"dual-review-loop/) { check($0, NR); pending = 0 }
    else if (pending && !prev_cont) pending = 0
    prev_cont = ($0 ~ /\\$/)
  }' "$HOOK")

# Every loop-ending message must be recognisable as one. The scan above can only
# inspect messages it can find, and it finds them by that opening; without this,
# writing a message that opens differently is a way past the check rather than a
# style slip.
# Only cleanup_and_approve takes a user message as its SECOND argument; fail_open
# takes one argument and builds its own text, so a bare `fail_open "reason"` is
# not a finding. Look at the arguments after the helper name, never at the rest
# of the line — an unrelated `mv "$TEMP_FILE" "$STATE_FILE"` on a line that also
# calls fail_open was flagged by a whole-line version.
ODD_MSG=$(LC_ALL=C awk '
  {
    args = ""
    if (match($0, /cleanup_and_approve /)) args = substr($0, RSTART + RLENGTH)
    if (args != "") {
      # second quoted argument present on this same line?
      if (args ~ /"[^"]*"[[:space:]]+"/ && args !~ /"[^"]*"[[:space:]]+"dual-review-loop/) print NR
      pending = (args ~ /\\$/)
    } else if (pending && prev_cont) {
      if (/^[[:space:]]*"/ && $0 !~ /"dual-review-loop/) print NR
      pending = 0
    } else pending = 0
    prev_cont = ($0 ~ /\\$/)
  }' "$HOOK")
if [ -z "$ODD_MSG" ]; then
  ok "every loop-ending message opens with the plugin name, so the scan above can find it"
else
  fail "loop-ending message(s) at line(s) $(echo "$ODD_MSG" | tr '\n' ' ')do not begin with \"dual-review-loop — the missing-note scan cannot see them"
fi
if [ -z "$MISSING" ]; then
  ok "every loop-ending message either carries the open-question note or is explicitly exempt"
else
  fail "terminal message(s) at line(s) $(echo "$MISSING" | tr '\n' ' ')end the loop without saying an open question is outstanding — add \$(oq_suffix) or justify it in the allowlist above"
fi

# "Defined above first use" is NOT the invariant that matters, and asserting only
# that certified a dead call for a whole release: Gate 3 interpolated the note 16
# lines before oq_classify assigned the verdict it reads, so it could never emit
# anything, and this file demanded the token be present on that very line. The
# real invariant is that the CLASSIFIER runs above the first place its answer is
# rendered. (Uses inside a function body are evaluated at call time, so only
# top-level interpolations are ordered against it.)
SUF_DEF=$(LC_ALL=C grep -n '^oq_suffix() {' "$HOOK" | head -1 | cut -d: -f1)
CLASSIFY_AT=$(LC_ALL=C grep -n '^oq_classify$' "$HOOK" | head -1 | cut -d: -f1)
FIRST_TOP_USE=$(LC_ALL=C awk '
  /^[a-z_]+\(\) \{/ { fn = 1 }
  /^\}$/              { fn = 0 }
  !fn && /oq_suffix\)/ { print NR; exit }' "$HOOK")
if [ -z "$SUF_DEF" ] || [ -z "$CLASSIFY_AT" ] || [ -z "$FIRST_TOP_USE" ]; then
  fail "could not locate oq_suffix / oq_classify / a top-level note site — anchors changed, this assertion is not running"
else
  [ "$SUF_DEF" -lt "$FIRST_TOP_USE" ] \
    && ok "oq_suffix is defined above its first use (line $SUF_DEF < $FIRST_TOP_USE)" \
    || fail "oq_suffix is defined at $SUF_DEF, below its first use at $FIRST_TOP_USE — bash resolves at call time, so every note would silently vanish"
  if [ "$CLASSIFY_AT" -lt "$FIRST_TOP_USE" ]; then
    ok "oq_classify runs above the first note site (line $CLASSIFY_AT < $FIRST_TOP_USE)"
  else
    fail "oq_classify runs at $CLASSIFY_AT, AFTER the note at $FIRST_TOP_USE — that note reads a verdict nobody has computed yet, so it is decoration: it can never render, and the presence check above will still pass"
  fi

  # The note inside fail_open renders at its CALL sites, which the check above
  # cannot see: it deliberately looks only at top-level interpolations, so all
  # twelve call sites were certified by a single line inside the helper while
  # three of them sat above the classifier and could never print anything.
  # Two gates legitimately cannot classify — no jq, or state that is not an
  # object — and are named here so the exemption is a decision, not an oversight.
  EARLY=$(LC_ALL=C awk -v c="$CLASSIFY_AT" '
    NR < c && /(cleanup_and_approve|fail_open) "/ {
      if ($0 !~ /jq not on PATH/ && $0 !~ /not a JSON object/) print NR
    }' "$HOOK")
  if [ -z "$EARLY" ]; then
    ok "every loop-ending call site that could classify runs after oq_classify"
  else
    fail "loop-ending call site(s) at line(s) $(echo "$EARLY" | tr '\n' ' ')run BEFORE oq_classify — their open-question note expands to nothing, silently, exactly like the Gate 3 note did"
  fi
fi

# State deletion must stay confined to the two helpers the invariant scans. An
# exit that inlines `rm -f "$STATE_FILE"` is invisible to it — measured as a way
# past the check.
# Any way of destroying the state file, not one spelling of one command. The
# literal `rm -f "$STATE_FILE"` match was bypassed by `rm -f "${STATE_FILE}"`,
# and would equally have missed `rm --`, `mv`, `truncate` or a `>` redirect.
INLINE_RM=$(LC_ALL=C awk '
  /^(cleanup_and_approve|fail_open)\(\) \{/ { inhelper = 1 }
  inhelper && /^\}$/ { inhelper = 0; next }
  # A continued message string is prose, not code — the schema-mismatch message
  # tells the user to rm the state file and is not itself doing so.
  !inhelper && /^[[:space:]]*"/ { next }
  # The atomic write is the ONE legitimate mv onto the state file: temp + mv is
  # how every update lands. Named, so the exemption is a decision.
  !inhelper && /mv "\$TEMP_FILE" "\$STATE_FILE"/ { next }
  # No \< \> here: those are a GNU extension and this file must run under the awk
  # that ships with macOS, where they silently never match — measured, with a
  # bypass that stayed green.
  !inhelper && /STATE_FILE/ && /(^|[^a-zA-Z_])(rm|truncate)[[:space:]]/ { print NR; next }
  !inhelper && /STATE_FILE/ && /(^|[^a-zA-Z_])mv[[:space:]]/ { print NR; next }
  !inhelper && />[[:space:]]*"?\$\{?STATE_FILE/ { print NR }' "$HOOK")
if [ -z "$INLINE_RM" ]; then
  ok "state deletion is confined to cleanup_and_approve and fail_open"
else
  fail "state is deleted outside the two helpers at line(s) $(echo "$INLINE_RM" | tr '\n' ' ')— such an exit bypasses the open-question note invariant entirely"
fi

echo ""
echo "== docs consistency: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
