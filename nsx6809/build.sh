#!/bin/bash
# ==============================================================================
# build.sh - NSX6809: the CoCo 3 disks MNSTTRN.DSK (training) and MNSTINFR.DSK (inference)
# ==============================================================================
# Usage:  ./build.sh          build/MNSTTRN.DSK and build/MNSTINFR.DSK
#         ./build.sh clean    remove build/ (keeps nothing, including a trained model)
#
# Step 1  tools/nsxdata.py turns MNIST (data/TRAIN.IDX ..., from ./get_mnist.sh) into
#         build/MNIST.DAT (6200 training + 1000 test digits, 12x12 bits), build/GALLERY.DAT (100 held-out
#         digits for the inference UI) and build/MODEL0.NSX (an untrained model file).
# Step 2  lwasm assembles mnsttrn.asm and mnstinfr.asm (both include nsx6809.inc).
# Step 3  tools/dsk.py writes the disks:
#           MNSTTRN.DSK   MNSTTRN.BIN, MODEL.NSX (untrained: training overwrites it), MNIST.DAT
#           MNSTINFR.DSK  MNSTINFR.BIN, MODEL.NSX, GALLERY.DAT
#         MNSTINFR.DSK's MODEL.NSX is the output of training: build/MODEL.NSX, which ./run.sh --train
#         takes off MNSTTRN.DSK when the CoCo has finished.  Until then it is the untrained model
#         (the UI says UNTRAINED!).
# ==============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="${SCRIPT_DIR}/build"
cd "${SCRIPT_DIR}"
if [ "$1" = "clean" ]; then rm -rf "$B"; echo "Clean complete"; exit 0; fi
[ -n "$1" ] && { echo "Usage: ./build.sh [clean]"; exit 2; }

if [ -z "${LWASM}" ] || [ ! -x "${LWASM}" ]; then
    if command -v lwasm &> /dev/null; then LWASM="$(command -v lwasm)"
    elif [ -x /usr/local/bin/lwasm ]; then LWASM=/usr/local/bin/lwasm
    else echo "lwasm not found - see README.md (lwtools 4.x)"; exit 1; fi
fi
command -v python3 &> /dev/null || { echo "python3 is required"; exit 1; }
mkdir -p "$B"

echo "[1/3] MNIST -> MNIST.DAT, GALLERY.DAT (tools/nsxdata.py)"
if [ ! -f "$B/MNIST.DAT" ] || [ ! -f "$B/GALLERY.DAT" ] || [ ! -f "$B/MODEL0.NSX" ]; then
    python3 tools/nsxdata.py data "$B" --ntrain 6200
else
    echo "  (already built)"
fi

echo "[2/3] Assembling mnsttrn.asm and mnstinfr.asm"
"$LWASM" --6809 --format=decb --output="$B/MNSTTRN.BIN" --list="$B/mnsttrn.lst" mnsttrn.asm
"$LWASM" --6809 --format=decb --output="$B/MNSTINFR.BIN" --list="$B/mnstinfr.lst" mnstinfr.asm
echo "  MNSTTRN.BIN $(stat -c%s "$B/MNSTTRN.BIN") bytes, MNSTINFR.BIN $(stat -c%s "$B/MNSTINFR.BIN") bytes"

echo "[3/3] Writing the disks"
python3 tools/dsk.py make "$B/MNSTTRN.DSK" MNSTTRN.BIN:2="$B/MNSTTRN.BIN" MODEL.NSX:1="$B/MODEL0.NSX" MNIST.DAT:1="$B/MNIST.DAT"
MODEL="$B/MODEL.NSX"
if [ ! -f "$MODEL" ]; then
    MODEL="$B/MODEL0.NSX"
    echo "  (no trained model yet: MNSTINFR.DSK gets the untrained one - run ./run.sh --train)"
fi
python3 tools/dsk.py make "$B/MNSTINFR.DSK" MNSTINFR.BIN:2="$B/MNSTINFR.BIN" MODEL.NSX:1="$MODEL" GALLERY.DAT:1="$B/GALLERY.DAT"
echo "Done."
