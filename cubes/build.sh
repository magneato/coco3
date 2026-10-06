#!/bin/bash
# ==============================================================================
# build.sh - assemble CUBE into a bootable CoCo 3 disk image
# ==============================================================================
# Usage:  ./build.sh          build/CUBE.BIN and build/CUBE.DSK
#         ./build.sh clean    remove build/
#
# cube.asm is self-contained (the song is already written into its SONG block; to change the music
# edit scripts/cube_tune.py and run it, which rewrites that block).
# Step 1  lwasm assembles cube.asm.
# Step 2  scripts/mkdsk.py writes an RS-DOS disk image holding CUBE.BIN (LOADM it).
# ==============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
cd "${SCRIPT_DIR}"

if [ "$1" = "clean" ]; then
    rm -rf "${BUILD_DIR}"
    echo "Clean complete"
    exit 0
elif [ -n "$1" ]; then
    echo "Usage: ./build.sh [clean]"
    exit 2
fi

# config.mk (written by setup.sh, make syntax: LWASM = path) may name the assembler
if [ -z "${LWASM}" ] && [ -f "${SCRIPT_DIR}/config.mk" ]; then
    LWASM="$(sed -n 's/^[[:space:]]*LWASM[[:space:]]*:\{0,1\}=[[:space:]]*//p' "${SCRIPT_DIR}/config.mk" | tail -n1)"
fi
if [ -z "${LWASM}" ] || [ ! -x "${LWASM}" ]; then
    if command -v lwasm &> /dev/null; then LWASM="$(command -v lwasm)"
    elif [ -x "${SCRIPT_DIR}/tools/lwtools-4.23/lwasm/lwasm" ]; then LWASM="${SCRIPT_DIR}/tools/lwtools-4.23/lwasm/lwasm"
    else echo "lwasm not found - run ./setup.sh first"; exit 1; fi
fi
command -v python3 &> /dev/null || { echo "python3 is required"; exit 1; }

mkdir -p "${BUILD_DIR}"
echo "[1/2] Assembling cube.asm"
"${LWASM}" --6809 --format=decb --output="${BUILD_DIR}/CUBE.BIN" --list="${BUILD_DIR}/cube.lst" cube.asm
echo "  ${BUILD_DIR}/CUBE.BIN ($(stat -c%s "${BUILD_DIR}/CUBE.BIN") bytes)"
echo "[2/2] Writing the disk image"
python3 scripts/mkdsk.py "${BUILD_DIR}/CUBE.DSK" CUBE.BIN:2="${BUILD_DIR}/CUBE.BIN"
echo "Done."
