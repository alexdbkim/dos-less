#!/usr/bin/env bash
# =============================================================================
# build.sh -- Host-side build driver. Boots DOSBox-X, mounts repo and MASM,
#             runs tools/build.bat, exits.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASM_DIR="$REPO_ROOT/tools/masm"

if [ ! -d "$MASM_DIR" ]; then
    echo "error: $MASM_DIR not found." >&2
    echo "       Place ML.EXE and LINK.EXE (MASM 6.0) under tools/masm/." >&2
    echo "       See docs/BUILD.md." >&2
    exit 2
fi

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [ -z "$DOSBOX_BIN" ]; then
    if command -v dosbox-x >/dev/null 2>&1; then
        DOSBOX_BIN="dosbox-x"
    elif command -v dosbox >/dev/null 2>&1; then
        DOSBOX_BIN="dosbox"
    else
        echo "error: neither dosbox-x nor dosbox found in PATH." >&2
        echo "       Install DOSBox-X: brew install dosbox-x" >&2
        exit 2
    fi
fi

CONF="$REPO_ROOT/tools/dosbox.conf"

# Make sure build dir exists.
mkdir -p "$REPO_ROOT/build"

# We invoke DOSBox with autoexec commands via -c to mount and run build.bat.
exec "$DOSBOX_BIN" \
    -conf "$CONF" \
    -c "mount C \"$REPO_ROOT\"" \
    -c "mount T \"$MASM_DIR\"" \
    -c "set PATH=T:\\;%PATH%" \
    -c "C:" \
    -c "cd \\TOOLS" \
    -c "BUILD.BAT" \
    -c "exit"
