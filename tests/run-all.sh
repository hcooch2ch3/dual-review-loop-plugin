#!/usr/bin/env bash
# dual-review-loop — run every test file.
#
# Run: bash tests/run-all.sh
#
# There is no CI. This exists so new test files are discoverable instead of
# needing to be invoked by hand one at a time.
#
# Note: gate-matrix.test.sh compares against a committed golden. To accept an
# INTENDED behaviour change, run it directly with --update and commit the
# regenerated golden — never from here.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; FAILED=""

for f in "$DIR"/*.test.sh; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  echo "───────────────────────────────────────────────"
  echo "▶ $name"
  if bash "$f"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED="$FAILED $name"
  fi
done

echo "───────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL GREEN — $PASS test file(s) passed"
else
  echo "RED — $FAIL of $((PASS+FAIL)) file(s) failed:$FAILED"
fi
[ "$FAIL" -eq 0 ]
