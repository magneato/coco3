#!/bin/bash
# ==============================================================================
# build.sh - assemble FRACTAL into a bootable CoCo 3 disk image
# ==============================================================================
# Usage:  ./build.sh          build/FRACTAL.BIN and build/FRACTAL.DSK
#         ./build.sh clean    remove build/
#
# Step 1  scripts/fractal_scenes.py writes build/fractal.inc: the nine scenes, the zoom frames, the
#         rotozoomer's path, the dither order, the title text and the palettes.
# Step 2  lwasm assembles fractal.asm (it includes build/fractal.inc).
# Step 3  scripts/mkdsk.py writes an RS-DOS disk image holding FRACTAL.BIN (LOADM it).
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
echo "[1/3] Scene list (scripts/fractal_scenes.py)"
python3 scripts/fractal_scenes.py "${BUILD_DIR}"
echo "[2/3] Assembling fractal.asm"
"${LWASM}" --6809 --format=decb --output="${BUILD_DIR}/FRACTAL.BIN" --list="${BUILD_DIR}/fractal.lst" fractal.asm
"${LWASM}" --6809 --format=decb --symbol-dump --output=/dev/null fractal.asm > "${BUILD_DIR}/fractal.sym" 2>/dev/null || true
echo "  ${BUILD_DIR}/FRACTAL.BIN ($(stat -c%s "${BUILD_DIR}/FRACTAL.BIN") bytes)"
echo "[3/3] Writing the disk image"
python3 scripts/mkdsk.py "${BUILD_DIR}/FRACTAL.DSK" FRACTAL.BIN:2="${BUILD_DIR}/FRACTAL.BIN"
echo "Done."
