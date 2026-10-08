#!/bin/sh
# Run every scenario in its own fresh process + root dir.
# Usage: sh tests/all.sh                  (uses /bin/sh)
#        SHELL_BIN=mksh sh tests/all.sh   (Android's real shell)
HERE=$(cd "$(dirname "$0")" && pwd)
SHELL_BIN=${SHELL_BIN:-sh}
TMP=${TMPDIR:-/tmp}/pdt_tests
rm -rf "$TMP"; mkdir -p "$TMP"
TP=0; TF=0
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    root="$TMP/run$n"
    rm -rf "$root"; mkdir -p "$root"
    echo "=== Scenario $n ==="
    out=$("$SHELL_BIN" "$HERE/scen.sh" "$n" "$root" 2>&1)
    echo "$out"
    p=$(echo "$out" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p' | tail -1)
    f=$(echo "$out" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p' | tail -1)
    TP=$((TP + ${p:-0})); TF=$((TF + ${f:-0}))
done
echo ""
echo "TOTAL: $TP passed, $TF failed"
[ "$TF" = 0 ] || exit 1
echo "ALL TESTS PASSED"
