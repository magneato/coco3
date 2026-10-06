#!/bin/bash
# ==============================================================================
# build.sh - the ritual that turns sources and the natives' files into one bootable disk
# ==============================================================================
# "Constraints breed elegance, not limitations." - Nom Nom Philosophy
#
# Usage:
#   ./build.sh            assemble build/WOLF3D.BIN and write build/WOLF3D.DSK
#   ./build.sh --standin  build with original procedural stand-in assets (no game data required)
#   ./build.sh clean      remove build artifacts
#
# Step 1  scripts/gen_assets.py builds tables from WOLF3D/ or, with --standin, from original
#         procedural art: palette, textures, map, HUD and ray/reciprocal LUTs.
#         Nothing is divided at runtime.
# Step 2  lwasm assembles wolf3d.asm (boot emitter + engine).
# Step 3  scripts/mkdsk.py writes a DECB-exact disk image holding WOLF3D.DAT (bulk data, first on the
#         disk) and WOLF3D.BIN (code; LOADM'd).  The boot code reads the DAT sectors itself.
# ==============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
cd "${SCRIPT_DIR}"

if [ "$1" = "clean" ]; then
    rm -rf "${BUILD_DIR}"
    echo "Clean complete"
    exit 0
fi
STANDIN=0
if [ "$1" = "--standin" ]; then
    STANDIN=1
elif [ -n "$1" ]; then
    echo "Usage: ./build.sh [--standin|clean]"
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
if [ "$STANDIN" = "0" ]; then
    [ -f "${SCRIPT_DIR}/WOLF3D/VSWAP.WL6" ] || { echo "WOLF3D/ game data files not found"; exit 1; }
fi

mkdir -p "${BUILD_DIR}"
echo "[1/3] Extracting assets and building LUTs (wolfai)"
if [ "$STANDIN" = "1" ]; then
    python3 scripts/gen_assets.py "${BUILD_DIR}" --standin
else
    python3 scripts/gen_assets.py "${BUILD_DIR}"
fi

echo "[2/3] Assembling code2.asm (logic page) and wolf3d.asm (engine)"
"${LWASM}" --6809 --format=raw --output="${BUILD_DIR}/code2.bin" --list="${BUILD_DIR}/code2.lst" code2.asm
python3 scripts/mkdat.py "${BUILD_DIR}"
"${LWASM}" --6809 --format=decb \
    --output="${BUILD_DIR}/WOLF3D.BIN" \
    --list="${BUILD_DIR}/wolf3d.lst" \
    wolf3d.asm
"${LWASM}" --6809 --format=decb --symbol-dump --output=/dev/null wolf3d.asm > "${BUILD_DIR}/wolf3d.sym" 2>/dev/null || true
echo "  ${BUILD_DIR}/WOLF3D.BIN ($(stat -c%s "${BUILD_DIR}/WOLF3D.BIN") bytes)"

echo "[3/3] Writing the disk image"
python3 scripts/mkdsk.py "${BUILD_DIR}/WOLF3D.DSK" WOLF3D.DAT:1="${BUILD_DIR}/WOLF3D.DAT" WOLF3D.BIN:2="${BUILD_DIR}/WOLF3D.BIN"
echo "Done."
