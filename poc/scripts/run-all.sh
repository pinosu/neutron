#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$HERE/lib.sh"
# shellcheck disable=SC1091
source "$HERE/scenarios/recv.sh"
# shellcheck disable=SC1091
source "$HERE/scenarios/src.sh"
set +e

fail=0
for s in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15; do
  if out=$($s 2>&1); then
    echo "  ok   $s: $out"
  else
    echo "  FAIL $s"
    echo "$out" | sed 's/^/       /'
    fail=1
  fi
done

if [ $fail -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
fi
exit $fail
