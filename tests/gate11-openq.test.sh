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
t() {  # $1=label  $2=body  $3=expect STOP|ADVANCE
  local got
  if printf '%b' "$2" | oq_first_item >/dev/null 2>&1; then got=STOP; else got=ADVANCE; fi
  if [ "$got" = "$3" ]; then
    printf '  ✓ %-20s %s\n' "$1" "$got"
  else
    printf '  ✗ %-20s got=%s want=%s\n' "$1" "$got" "$3"
    fail=1
  fi
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

echo "-- input shapes --"
t no-trailing-nl  '## Open Questions\n- a real question'                   STOP
t link-bullet     '## Open Questions\n- [see here](http://x)\n'            STOP
t degraded        '## Open Questions\n- [DEGRADED] recovery failed\n'      STOP
printf '## Open Questions\r\n- a real question\r\n' > "${TMPDIR:-/tmp}/drl-crlf.$$"
if oq_first_item < "${TMPDIR:-/tmp}/drl-crlf.$$" >/dev/null 2>&1; then
  printf '  ✓ %-20s %s\n' "crlf" "STOP"
else
  printf '  ✗ %-20s got=ADVANCE want=STOP\n' "crlf"; fail=1
fi
rm -f "${TMPDIR:-/tmp}/drl-crlf.$$"

# An h1 does NOT close the section, so a bullet under a later h1 still counts.
# Over-stopping, deliberately: it matches the rule this replaced, and a spurious
# pause is recoverable where a skipped disagreement is not. `fenced-hash` above
# is the same decision seen from the side that matters.
t h1-does-not-end '## Open Questions\n- 없음\n# New Section\n- not a question\n' STOP

echo ""
if [ "$fail" -eq 0 ]; then
  echo "== gate11 classifier: 28 cases passed =="
else
  echo "== gate11 classifier: FAILED =="
fi
exit "$fail"
