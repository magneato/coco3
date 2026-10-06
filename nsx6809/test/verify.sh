#!/bin/bash
# test/verify.sh - prove the CoCo does exactly what tools/nsxdata.py specifies.
#   1. train the reference model in Python (build/REF.NSX)
#   2. the trainer stopped after 1 and after 64 samples: every activation, error, weight and error byte
#      in its RAM equals the reference's
#   3. the whole training run in MAME (35 minutes of CoCo time): MODEL.NSX on the disk == REF.NSX
#   4. MNSTINFR with that model: the gallery's 0-9 and two drawings (a 7 with the keyboard on a new slot,
#      a 1 with the joystick): the input bits, outputs and probabilities equal the reference's
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -e
./build.sh >/dev/null
LWASM="$(command -v lwasm || echo /usr/local/bin/lwasm)"
ROMPATH="${MAME_ROMPATH:-${HOME}/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms}"
mame_run() {   # disk lua [env...]
    timeout -s KILL 3000 mame coco3 -rompath "$ROMPATH" -ramsize 512K -flop1 "$1" -video none -sound none -nothrottle \
        -skip_gameinfo -autoboot_script "$2" >/dev/null 2>&1 || true
}
echo "== 1. the reference model (Python)"
python3 tools/nsxdata.py train build/REF.NSX build

for N in 1 64; do
    echo "== 2. the trainer after $N sample(s)"
    "$LWASM" --6809 --format=decb -DSTOPAT=$N --output=build/T.BIN mnsttrn.asm
    python3 tools/dsk.py make build/T.DSK MNSTTRN.BIN:2=build/T.BIN MODEL.NSX:1=build/MODEL0.NSX MNIST.DAT:1=build/MNIST.DAT >/dev/null
    RUN_PROG=MNSTTRN WATCH_EVERY=999999 WATCH_DUMP=build/dump$N.bin mame_run build/T.DSK test/watch.lua
    python3 test/compare.py build/dump$N.bin $N build | tail -1
done

echo "== 3. a whole training run on the CoCo"
cp build/MNSTTRN.DSK build/T.DSK
RUN_PROG=MNSTTRN WATCH_EVERY=999999 mame_run build/T.DSK test/watch.lua
python3 tools/dsk.py get build/T.DSK MODEL.NSX build/COCO.NSX
python3 tools/nsxdata.py show build/COCO.NSX
cmp build/COCO.NSX build/REF.NSX && echo "MODEL.NSX trained by the CoCo == the reference, byte for byte"

echo "== 4. inference"
python3 tools/dsk.py make build/T.DSK MNSTINFR.BIN:2=build/MNSTINFR.BIN MODEL.NSX:1=build/COCO.NSX GALLERY.DAT:1=build/GALLERY.DAT >/dev/null
S=""; D=""; t=10
for d in 0 1 2 3 4 5 6 7 8 9; do S="$S$t-$((t+3)):$d,$((t+12))-$((t+15)):ENTER,"; D="$D$((t+40)):build/inf$d.bin,"; t=$((t+50)); done
UI_SCRIPT="$S" UI_DUMP="$D" UI_EXIT=$((t+5)) mame_run build/T.DSK test/ui.lua
JS=""; y=150; u=630; while [ $y -le 870 ]; do JS="$JS$u-$u:JY=$y,"; y=$((y+40)); u=$((u+3)); done
UI_SCRIPT="10-18:RIGHT,40-48:RIGHT,70-78:RIGHT,100-127:A,130-161:W,170-221:SPACE,170-221:D,230-293:SPACE,230-293:S,230-293:A,305-312:ENTER,580-588:RIGHT,600-608:CLEAR,620-620:JX=512,620-620:JY=150,${JS}632-$u:FIRE,$((u+10))-$((u+18)):ENTER" \
UI_DUMP="350:build/draw7.bin,$((u+50)):build/draw1.bin" UI_EXIT=$((u+55)) mame_run build/T.DSK test/ui.lua
python3 test/check_infer.py build/COCO.NSX build/inf?.bin build/draw7.bin build/draw1.bin
