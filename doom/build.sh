#!/bin/bash
# ==============================================================================
# build.sh - turns Freedoom's E1M1 and the engine source into one bootable CoCo 3 disk
# ==============================================================================
# Usage:
#   ./build.sh            assemble build/DOOM.BIN and write build/DOOM.DSK
#   ./build.sh clean      remove build artifacts
#
# Step 1  scripts/gen_assets.py rasterises E1M1 onto the lattice (grid.py), chooses the palette (palette.py: L3),
#         lights and dithers walls, figures and the status bar (dither.py: L1/L2) and builds every table the
#         engine looks up instead of dividing.  Previews land in build/sheets/.
# Step 2  lwasm assembles code2.asm (game logic page) and doom.asm (boot code + engine).
# Step 3  scripts/mkdsk.py writes a DECB-exact disk image holding DOOM.DAT (bulk data, first on the disk) and
#         DOOM.BIN (code; LOADM'd).  The boot code reads the DAT sectors itself.
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

# config.mk is make syntax (LWASM = path), so parse it rather than sourcing it
if [ -z "${LWASM}" ] && [ -f "${SCRIPT_DIR}/config.mk" ]; then
    LWASM="$(sed -n 's/^[[:space:]]*LWASM[[:space:]]*:\{0,1\}=[[:space:]]*//p' "${SCRIPT_DIR}/config.mk" | tail -n1)"
fi
if [ -z "${LWASM}" ] || [ ! -x "${LWASM}" ]; then
    if command -v lwasm &> /dev/null; then LWASM="$(command -v lwasm)"
    elif [ -x "${SCRIPT_DIR}/tools/lwtools-4.23/lwasm/lwasm" ]; then LWASM="${SCRIPT_DIR}/tools/lwtools-4.23/lwasm/lwasm"
    else echo "lwasm not found - run ./setup.sh first"; exit 1; fi
fi
command -v python3 &> /dev/null || { echo "python3 is required"; exit 1; }
python3 -c "import numpy, PIL" 2>/dev/null || { echo "python3-numpy and python3-pil are required (run ./setup.sh)"; exit 1; }
[ -d "${SCRIPT_DIR}/freedoom/levels" ] || { echo "freedoom/ not found - run ./setup.sh first"; exit 1; }

mkdir -p "${BUILD_DIR}"
echo "[1/3] E1M1, palette, light, figures, status bar and tables"
python3 scripts/gen_assets.py "${BUILD_DIR}"

echo "[2/3] Assembling code2.asm (logic page) and doom.asm (engine)"
"${LWASM}" --6809 --format=raw --output="${BUILD_DIR}/code2.bin" --list="${BUILD_DIR}/code2.lst" code2.asm
python3 scripts/mkdat.py "${BUILD_DIR}"
"${LWASM}" --6809 --format=decb \
    --output="${BUILD_DIR}/DOOM.BIN" \
    --list="${BUILD_DIR}/doom.lst" \
    doom.asm
"${LWASM}" --6809 --format=decb --symbol-dump --output=/dev/null doom.asm > "${BUILD_DIR}/doom.sym" 2>/dev/null || true
echo "  ${BUILD_DIR}/DOOM.BIN ($(stat -c%s "${BUILD_DIR}/DOOM.BIN") bytes)"

echo "[3/3] Writing the disk image"
python3 scripts/mkdsk.py "${BUILD_DIR}/DOOM.DSK" DOOM.DAT:1="${BUILD_DIR}/DOOM.DAT" DOOM.BIN:2="${BUILD_DIR}/DOOM.BIN"
echo "Done."
