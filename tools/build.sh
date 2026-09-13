#!/usr/bin/env bash
# Per-repo build script. Runs paideia-as build over every .pdx source.
#
# Resolves paideia-as via (in order):
#   1. $PAIDEIA_AS env var
#   2. paideia-os checkout sibling to this repo: ../paideia-os/tools/paideia-as/target/release/paideia-as
#   3. $HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as
#   4. paideia-as on $PATH (must be >= 0.21.0)
#
# Requires paideia-as >= 0.21.0. The 0.9.0 shipped in $PATH by default does not
# accept the syntax used in this repo.

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="0.21.0"

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    # $1 = have, $2 = want ; returns 0 if have >= want
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[build] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 2
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[build] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 2
fi
echo "[build] paideia-as $VER at $PA"

BUILD_DIR="build-out"
mkdir -p "$BUILD_DIR"

FAIL=0
COUNT=0
OWN_OBJECTS=()
for pdx in src/*.pdx; do
    [ -f "$pdx" ] || continue
    COUNT=$((COUNT + 1))
    obj="$BUILD_DIR/$(basename "$pdx" .pdx).o"
    OWN_OBJECTS+=("$obj")
    if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
        FAIL=$((FAIL + 1))
    fi
done

if [ -d tests ]; then
    for pdx in tests/*.pdx; do
        [ -f "$pdx" ] || continue
        COUNT=$((COUNT + 1))
        obj="$BUILD_DIR/tests-$(basename "$pdx" .pdx).o"
        if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
            FAIL=$((FAIL + 1))
        fi
    done
fi

echo "[build] $COUNT source(s), $FAIL failure(s)"
[ "$FAIL" -eq 0 ] || exit 1
echo "[build] OK"

# paideia-os#2440: link every module .o (main.pdx's _start entry pulls
# in the rest via cross-module `call`) into a real ELF via link.ld --
# same shape as tools/user/mkfs.pdxfs/tools/build.sh's own link step
# (both scripts share the monorepo's canonical src/user/link.ld,
# copied verbatim into this repo's root as ./link.ld). This is the
# artifact paideia-os's own tools/build.sh r64v2-tools-shaped shell
# block stages into build/user/shell-satellite.elf for the kernel's
# bin_seeds witness to prefer over the legacy embedded shell.elf.
if [ "$FAIL" -eq 0 ] && [ "${#OWN_OBJECTS[@]}" -gt 0 ]; then
    echo "[link] ld -T link.ld -> $BUILD_DIR/shell.elf"
    ld -nostdlib --warn-common --fatal-warnings --gc-sections -z noexecstack \
        -T link.ld \
        -o "$BUILD_DIR/shell.elf" \
        "${OWN_OBJECTS[@]}"
    echo "[link] OK -> $BUILD_DIR/shell.elf"

    objcopy -O binary "$BUILD_DIR/shell.elf" "$BUILD_DIR/shell.bin"
    echo "[link] OK -> $BUILD_DIR/shell.bin"
fi
