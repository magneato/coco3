#!/bin/bash
# ==============================================================================
# test/run_tests.sh - end-to-end proof that the game works.
#   1. self-tests: the WAD reader (everything E1M1 uses loads) and the RLE codec
#   2. build
#   3. the gate: every page the boot forge makes (16 wall pages, 14 figure pages) is read out of the emulated
#      CoCo's RAM and compared byte for byte with the Python twin (build/forged/)
#   4. boot / walk / turn / fight / autopilot screenshots     5. frame-rate benchmark
# ==============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/screenshots"
mkdir -p "$OUT"

echo "== 1. self-tests"
python3 scripts/wad.py selftest
python3 scripts/rle.py selftest

echo "== 2. build"
./build.sh > /dev/null

echo "== 3. forged pages: the CoCo's RAM against the Python twin"
rm -f build/pages_mame.bin
PAGEDUMP="5400:A0-BD:$ROOT/build/pages_mame.bin" SNAPDIR="$OUT/_gate" EXITAT=5500 test/mm.sh > /dev/null || true
python3 - <<'EOF'
import os, sys
d = open("build/pages_mame.bin", "rb").read()
bad = 0
for line in open("build/forged.txt"):
    pg, n = line.split(); pg, n = int(pg, 16), int(n)
    twin = open(f"build/forged/{pg:02X}.bin", "rb").read()
    coco = d[(pg - 0xA0) * 8192:(pg - 0xA0) * 8192 + n]
    if coco != twin:
        i = next(i for i in range(n) if coco[i] != twin[i])
        print(f"   page ${pg:02X}: differs at ${i:04X} (coco {coco[i]:02X}, twin {twin[i]:02X})"); bad += 1
print(f"   {sum(1 for _ in open('build/forged.txt')) - bad} pages identical, {bad} different")
sys.exit(1 if bad else 0)
EOF

echo "== 4. boot / walk / turn / autopilot screenshots"
# Frames are emulated 60 Hz frames.  The disk load and the boot forge finish around frame ~5000.
SNAPDIR="$OUT/_run" SHOTS="5300 5700 6000 6400 7400 8400" \
KEYSEQ="5400-5650:UP,5750-5850:RIGHT,5900-5990:UP,6100-6110:T" EXITAT=8401 TIMEOUT=600 test/mm.sh | tee "$OUT/telemetry.txt"
i=0
for name in 01_start 02_walking 03_turning 04_walking_after_turn 05_autopilot 06_autopilot_later; do
    f=$(printf "%s/_run/coco3/%04d.png" "$OUT" $i); i=$((i+1))
    [ -f "$f" ] && cp "$f" "$OUT/$name.png"
done
grep -q "health=" "$OUT/telemetry.txt" || { echo "no telemetry: the game did not run"; exit 1; }

echo "== 5. frame-rate benchmark (40 strips while moving)"
scripts/bench.sh 0 | tee "$OUT/fps.txt"
echo "== all tests passed"
