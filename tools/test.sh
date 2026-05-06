#!/usr/bin/env bash
# =============================================================================
# test.sh -- Scripted DOSBox test runner.
#
# Each test case is a function below. It writes a key script (DOSBox `stuff`
# commands), boots DOSBox-X with build/LESS.COM and a fixture, runs LESS,
# and the test hook (LESS_TEST=1) writes LESSTEST.LOG which we diff against
# tests/expected/<case>.log.
#
# Usage:
#   tools/test.sh                 # run all
#   tools/test.sh t01 t05         # run specific cases
#   tools/test.sh --update t05    # update snapshot for t05
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build"
FIX="$REPO_ROOT/fixtures"
EXPECTED="$REPO_ROOT/tests/expected"
TMP="$REPO_ROOT/build/test-tmp"

mkdir -p "$EXPECTED" "$TMP"

if [ ! -f "$BUILD/LESS.COM" ]; then
    echo "error: $BUILD/LESS.COM not found. Run tools/build.sh first." >&2
    exit 2
fi

DOSBOX_BIN="${DOSBOX_BIN:-dosbox-x}"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1; shift
fi

run_case() {
    local name="$1" args="$2" keys="$3"
    local logfile="$TMP/$name.log"
    rm -f "$logfile"

    "$DOSBOX_BIN" \
        -conf "$REPO_ROOT/tools/dosbox.conf" \
        -c "mount C \"$BUILD\"" \
        -c "mount D \"$FIX\"" \
        -c "set LESS_TEST=1" \
        -c "C:" \
        -c "LESS.COM $args" \
        -c "$keys" \
        -c "exit" \
        >/dev/null 2>&1 || true

    # The LESS binary writes LESSTEST.LOG to its CWD (= C: = $BUILD).
    if [ -f "$BUILD/LESSTEST.LOG" ]; then
        mv "$BUILD/LESSTEST.LOG" "$logfile"
    else
        echo "$name: no LESSTEST.LOG produced" >&2
        return 1
    fi

    local exp="$EXPECTED/$name.log"
    if [ "$UPDATE" -eq 1 ]; then
        cp "$logfile" "$exp"
        echo "$name: snapshot updated"
        return 0
    fi
    if [ ! -f "$exp" ]; then
        echo "$name: no expected snapshot at $exp" >&2
        return 1
    fi
    if diff -u "$exp" "$logfile" > "$TMP/$name.diff"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        cat "$TMP/$name.diff"
        return 1
    fi
}

# --- test definitions --------------------------------------------------------
declare -A CASES_ARGS CASES_KEYS
CASES_ARGS[t01]="D:\\small.txt"
CASES_KEYS[t01]="keytype q"

CASES_ARGS[t02]="D:\\small.txt"
CASES_KEYS[t02]="keytype { }{ }bq"

CASES_ARGS[t03]="D:\\small.txt"
CASES_KEYS[t03]="keytype Gq"

CASES_ARGS[t04]="D:\\small.txt"
CASES_KEYS[t04]="keytype 5gq"

CASES_ARGS[t05]="D:\\small.txt"
CASES_KEYS[t05]="keytype /foo{ENTER}nq"

CASES_ARGS[t06]="D:\\small.txt"
CASES_KEYS[t06]="keytype G?bar{ENTER}Nq"

CASES_ARGS[t07]="D:\\small.txt D:\\small.txt"
CASES_KEYS[t07]="keytype :n:pq"

CASES_ARGS[t08]="D:\\large.txt"
CASES_KEYS[t08]="keytype Gq"

CASES_ARGS[t09]="-N D:\\small.txt"
CASES_KEYS[t09]="keytype q"

# Note: keytype syntax above is DOSBox-X specific. Plain dosbox uses
# `-c "stuff ..."`. Adjust when running on plain dosbox.

CASES=("$@")
if [ "${#CASES[@]}" -eq 0 ]; then
    CASES=(t01 t02 t03 t04 t05 t06 t07 t08 t09)
fi

fail=0
for c in "${CASES[@]}"; do
    if [ -z "${CASES_ARGS[$c]:-}" ]; then
        echo "$c: unknown case" >&2; fail=1; continue
    fi
    run_case "$c" "${CASES_ARGS[$c]}" "${CASES_KEYS[$c]}" || fail=1
done
exit $fail
