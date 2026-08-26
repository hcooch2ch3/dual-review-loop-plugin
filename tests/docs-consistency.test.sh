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
  LC_ALL=C grep -Eq 'dual-review-loop\.(\*|state|log|lock|inflight)' "$REPO_GI" || gimiss="$gimiss state/log/lock"
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
if LC_ALL=C awk -v RS='' \
     '/CLAUDE_CODE_STOP_HOOK_BLOCK_CAP/ && (/per user turn/ || /per turn/) { found=1 } END { exit !found }' "$README"; then
  ok "README states the cap is per turn in the same paragraph as the cap itself"
else
  fail "README does not tie 'per turn' to the block cap — the phrase alone can come from anywhere in the file"
fi

echo ""
echo "== docs consistency: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
