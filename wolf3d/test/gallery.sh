#!/bin/bash
# test/gallery.sh - six standing views (the still picture, after it has refined) for judging the look.
#   usage: test/gallery.sh OUTDIR     (writes OUTDIR/g1.png ... g6.png)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-/tmp/gallery}"
mkdir -p "$OUT"
# x:y:angle (angle units 0..511, 0 = east, 128 = south, 256 = west, 384 = north)
VIEWS=( "29.5:57.5:384" "7.5:25.5:0" "34.5:22.5:128" "58.5:34.5:256" "35.5:32.5:0" "6.5:14.5:64" )
TELE=""; SHOTS=""; f=4400
for v in "${VIEWS[@]}"; do TELE+="$f:$v,"; SHOTS+="$((f+90)) "; f=$((f+200)); done
pkill -9 mame 2>/dev/null; sleep 2
TELE="$TELE" SHOTS="$SHOTS" EXITAT=$((f)) SNAPDIR="$OUT/_s" "$ROOT/test/mm.sh" > /dev/null
i=0; for p in "$OUT"/_s/coco3/*.png; do i=$((i+1)); cp "$p" "$OUT/g$i.png"; done; rm -rf "$OUT/_s"
python3 - "$OUT" <<'PY'
import sys
from PIL import Image
out=sys.argv[1]; ims=[Image.open(f"{out}/g{i}.png").convert("RGB") for i in range(1,7)]
w,h=ims[0].size
sheet=Image.new("RGB",(w*2,h*3))
for i,m in enumerate(ims): sheet.paste(m,((i%2)*w,(i//2)*h))
sheet.save(f"{out}/sheet.png")
PY
echo "gallery in $OUT (sheet.png)"
