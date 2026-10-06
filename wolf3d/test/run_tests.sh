#!/bin/bash
# ==============================================================================
# test/run_tests.sh - end-to-end proof that the game works.  Boots the real disk image in MAME (the same
# way run.sh does), drives it with scripted keys, and saves screenshots + measurements to screenshots/.
#   1. wolfai self-test (asset extraction)           2. build
#   3. boot + walk + turn + autopilot screenshots     4. frame-rate benchmark   5. stack-blast benchmark
# ==============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/screenshots"
mkdir -p "$OUT"

echo "== 1. wolfai self-test"
python3 scripts/wolfai.py selftest

echo "== 2. build"
./build.sh > /dev/null
mkdir -p archive/extracted_art   # contact sheets show id Software's art: kept out of screenshots/ and out of git
cp build/preview_textures.png build/preview_hud.png archive/extracted_art/ 2>/dev/null || true
python3 scripts/wolfai.py sheet archive/extracted_art/wolfai_contact_sheets > /dev/null

echo "== 3. boot / walk / turn / autopilot screenshots"
# Frames are emulated 60 Hz frames.  The disk load finishes around frame ~3000 (unthrottled in emulated time).
pkill -9 mame 2>/dev/null || true; sleep 2
SNAPDIR="$OUT/_run" SHOTS="4500 4700 4900 5100 5800 6800" \
KEYSEQ="4600-4660:UP,4750-4800:RIGHT,4810-4860:UP,5600-5610:T" EXITAT=6801 test/mm.sh | tee "$OUT/telemetry.txt"
i=0
for name in 01_start 02_walking 03_turning 04_walking_after_turn 05_autopilot_terminator_vision 06_autopilot_later; do
    i=$((i+1)); f=$(printf "%s/_run/coco3/%04d.png" "$OUT" $((i-1)))
    [ -f "$f" ] && cp "$f" "$OUT/$name.png"
done
rm -rf "$OUT/_run"

echo "== 3b. sprites + combat: teleport into the guard room, hold F (fire) -> guard dies, score/ammo change"
pkill -9 mame 2>/dev/null || true; sleep 2
SNAPDIR="$OUT/_run" SHOTS="4400 4600 4900" TELE="4300:6.5:14.5:64" KEYSEQ="4350-4800:F" EXITAT=4950 test/mm.sh | tee "$OUT/telemetry_combat.txt"
i=0
for name in 07_guards_and_decor 08_firing 09_guard_down; do
    f=$(printf "%s/_run/coco3/%04d.png" "$OUT" $i); i=$((i+1))
    [ -f "$f" ] && cp "$f" "$OUT/$name.png"
done
rm -rf "$OUT/_run"

echo "== 3c. terminator AI hunts guards, then walks to the elevator (score +5000 per level)"
pkill -9 mame 2>/dev/null || true; sleep 2
SNAPDIR="$OUT/_run" SHOTS="4600 4900 5800 6800 10300" TELE="4300:6.5:14.5:200" KEYSEQ="4350-4360:T" EXITAT=10400 test/mm.sh | tee "$OUT/telemetry_terminator.txt"
i=0
for name in 10_terminator_aiming 11_terminator_after_kill 12_terminator_en_route 13_terminator_level_done 14_terminator_next_loop; do
    f=$(printf "%s/_run/coco3/%04d.png" "$OUT" $i); i=$((i+1))
    [ -f "$f" ] && cp "$f" "$OUT/$name.png"
done
rm -rf "$OUT/_run"

echo "== 3d. pickups: walk onto the machine gun (weapon icon + ammo change); key icons via a TESTKEYS build"
pkill -9 mame 2>/dev/null || true; sleep 2
SNAPDIR="$OUT/_run" SHOTS="4600" TELE="4300:28.5:25.5:0" EXITAT=4610 test/mm.sh | tee "$OUT/telemetry_pickup.txt"
cp "$OUT/_run/coco3/0000.png" "$OUT/15_machine_gun_pickup.png"; rm -rf "$OUT/_run"
lwasm --6809 --format=decb -DTESTKEYS=1 --output=build/TK.BIN wolf3d.asm
python3 scripts/mkdsk.py build/TK.DSK WOLF3D.DAT:1=build/WOLF3D.DAT WOLF3D.BIN:2=build/TK.BIN > /dev/null
pkill -9 mame 2>/dev/null || true; sleep 2
DSK=build/TK.DSK SNAPDIR="$OUT/_run" SHOTS="4600" EXITAT=4610 test/mm.sh > /dev/null
cp "$OUT/_run/coco3/0000.png" "$OUT/16_hud_key_icons.png"; rm -rf "$OUT/_run" build/TK.BIN build/TK.DSK

echo "== 3e. cover page while the disk loads (frame 1500) and the demo recorder (3 s -> exactly 181 frames)"
pkill -9 mame 2>/dev/null || true; sleep 2
SNAPDIR="$OUT/_run" SHOTS="1500" EXITAT=1510 test/mm.sh > /dev/null
cp "$OUT/_run/coco3/0000.png" "$OUT/00_cover_while_loading.png"; rm -rf "$OUT/_run"
pkill -9 mame 2>/dev/null || true; sleep 2
./run.sh --no-build --demo 3 --video build/demo_test.mp4 | tail -1 | tee "$OUT/demo_smoke.txt"
FR=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 build/demo_test.mp4)
[ "$FR" = "181" ] && echo "demo smoke test: PASS (181 frames)" | tee -a "$OUT/demo_smoke.txt" || { echo "demo smoke test: FAIL ($FR frames)" | tee -a "$OUT/demo_smoke.txt"; exit 1; }
rm -f build/demo_test.mp4

echo "== 4. frame-rate benchmark (flat out, four map-derived camera spots)"
{ for q in 0 1 2 3; do echo "moving layout quality $q:"; scripts/bench.sh $q 2>&1 | tail -1; done; } | tee "$OUT/fps.txt"

echo "== 5. stack-blast benchmark"
test/bench_blast.sh | tee "$OUT/stack_blast.txt"
echo "screenshots and measurements are in $OUT"
