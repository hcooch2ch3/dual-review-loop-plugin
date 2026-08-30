#!/usr/bin/env bash
# Gate 11's classifier, case by case.
#
# The gate matrix pins four polarity rows. That is enough to catch a flip and NOT
# enough to catch a rule that is right on those four and wrong elsewhere — which
# is how a rewrite that disabled the gate entirely once passed a plan review, and
# how a widened terminator that skipped real questions inside fenced code passed
# a corpus measurement. Both are cases below.
#
# The function is lifted out of the hook rather than copied, so this cannot drift
# from what ships. Extraction failing is a hard error, never a skip.
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 2; }

eval "$(sed -n '/^oq_first_item() {$/,/^}$/p' "$HOOK")"
command -v oq_first_item >/dev/null 2>&1 \
  || { echo "FATAL: could not extract oq_first_item from the hook — this suite is guarding nothing"; exit 2; }

fail=0
cases=0
# $4 is optional and pins the ITEM the detector prints, not just whether it
# stopped. Without it this harness checked the exit status alone: deleting the
# trailing-whitespace strip at the end of the awk program left all 28 cases green
# while the printed item became "which schema wins?\r" — measured. That string is
# what the user reads in the systemMessage ("First item: ..."), so an unstripped
# \r lands in their terminal. Pin the item wherever the case exists to guard the
# item, not merely the polarity.
t() {  # $1=label  $2=body  $3=expect STOP|ADVANCE  [$4=expected item]
  local got out
  cases=$((cases+1))
  if out=$(printf '%b' "$2" | oq_first_item 2>/dev/null); then got=STOP; else got=ADVANCE; out=""; fi
  if [ "$got" != "$3" ]; then
    printf '  ✗ %-20s got=%s want=%s\n' "$1" "$got" "$3"
    fail=1
    return
  fi
  if [ -n "${4:-}" ] && [ "$out" != "$4" ]; then
    printf '  ✗ %-20s item=[%s] want=[%s]\n' "$1" "$out" "$4"
    fail=1
    return
  fi
  printf '  ✓ %-20s %s\n' "$1" "$got"
}

echo "== Gate 11 classifier =="

echo "-- the basic polarity --"
t real            '## Open Questions\n- a real question\n'                STOP
t no-section      '## Findings\n- something\n'                            ADVANCE
t section-ended   '## Open Questions\n\n## Next\n- not a question\n'       ADVANCE
t real-after-ph   '## Open Questions\n- 없음\n- an actual question\n'       STOP

echo "-- placeholders are not questions --"
t placeholder-ko  '## Open Questions\n- 없음\n'                            ADVANCE
t haedang         '## Open Questions\n- 해당 없음\n'                        ADVANCE
t placeholder-en  '## Open Questions\n- None\n'                            ADVANCE
t placeholder-na  '## Open Questions\n- N/A\n'                             ADVANCE
t placeholder-par '## Open Questions\n- (none — agreed)\n'                 ADVANCE
t thematic-break  '## Open Questions\n- - -\n'                             ADVANCE
t indented-note   '## Open Questions\n- 없음\n  - but see X\n'              ADVANCE

echo "-- heading and bullet shapes --"
t h3-heading      '### Open Questions\n- a real question\n'                STOP
t star-bullet     '## Open Questions\n* a real question\n'                 STOP
t plus-bullet     '## Open Questions\n+ a real question\n'                 STOP
t nested-heading  '## Open Questions\n### Sub\n- real under sub\n'         STOP
t trailing-ws     '## Open Questions   \n- a real question\n'              STOP
t nospace-head    '##Open Questions\n- a real question\n'                  ADVANCE
t h4-head         '#### Open Questions\n- a real question\n'               ADVANCE

echo "-- the suffix collision, which no regex can resolve --"
t suffix-heading  '## Open Questions (unscored)\n- follow-up note\n'       ADVANCE
t suffix-arrow    '## Open Questions → 해소됨\n- already answered\n'        ADVANCE

echo "-- fenced blocks are quoted material --"
t fenced-hash     '## Open Questions\n\n```bash\n# rebuild the index\n```\n\n- a real question\n' STOP
t quoted-heading  '## Findings\n\n```markdown\n### Open Questions\n- an example\n```\n\n- fine\n' ADVANCE
t fenced-bullet   '## Open Questions\n\n```\n- an example bullet\n```\n'   ADVANCE

echo "-- numbered items are items (the hook's own prompt says so) --"
# Found by dual review in a REAL brief on this machine — a dual-review synthesis
# written FOR THIS REPO, holding two genuine blocking decisions under numbered
# bullets. The detector walked straight past it. The hook's plan prompt already
# tells the model that "N. [ ]" counts as a checkbox alongside "- [ ]", so the
# detector and the prompt in the same file disagreed about what a list item is.
t numbered        '## Open Questions\n1. a real question\n'               STOP 'a real question'
t numbered-paren  '## Open Questions\n1) a real question\n'               STOP 'a real question'
t numbered-multi  '## Open Questions\n1. first\n2. second\n'              STOP 'first'
t numbered-ph     '## Open Questions\n1. 없음\n'                          ADVANCE
t numbered-after-ph '## Open Questions\n- 없음\n2. a real question\n'     STOP 'a real question'
# Indented ones stay excluded, same as bulleted: a note nested under a
# placeholder is not a new question.
t numbered-indent '## Open Questions\n- 없음\n  1. but see X\n'           ADVANCE

echo "-- input shapes --"
t no-trailing-nl  '## Open Questions\n- a real question'                   STOP
t link-bullet     '## Open Questions\n- [see here](http://x)\n'            STOP
t degraded        '## Open Questions\n- [DEGRADED] recovery failed\n'      STOP
t crlf            '## Open Questions\r\n- a real question\r\n'          STOP 'a real question'
t item-is-stripped '## Open Questions\n-    padded question   \n'        STOP 'padded question'
t item-keeps-bold '## Open Questions\n- **A인가 B인가.** 결정 필요\n'      STOP '**A인가 B인가.** 결정 필요' 

# An h1 does NOT close the section, so a bullet under a later h1 still counts.
# Over-stopping, deliberately: it matches the rule this replaced, and a spurious
# pause is recoverable where a skipped disagreement is not. `fenced-hash` above
# is the same decision seen from the side that matters.
t h1-does-not-end '## Open Questions\n- 없음\n# New Section\n- not a question\n' STOP

echo ""
if [ "$fail" -eq 0 ]; then
  echo "== gate11 classifier: $cases cases passed =="
else
  echo "== gate11 classifier: FAILED =="
fi
exit "$fail"
