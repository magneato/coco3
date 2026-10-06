#!/bin/bash
# test/verify.sh - prove the 6809 draws exactly what the Python model says.
# Renders every scene with scripts/fractal_scenes.py's bit-exact model (same squares ledger, same
# solid guessing, same xorshift), boots build/FRACTAL.DSK in MAME (headless, unthrottled), dumps the
# screen RAM when each scene is finished and compares the two byte for byte.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f build/FRACTAL.DSK ] && [ -f build/fractal.sym ] || ./build.sh >/dev/null || exit 1
OUT=build/verify; rm -rf "$OUT"; mkdir -p "$OUT/model" "$OUT/mame"
python3 scripts/fractal_scenes.py build --preview "$OUT/model" >/dev/null || { echo "model failed (python3-pil installed?)"; exit 1; }
sym() { sed -n "s/^$1 EQU \\\$\\([0-9A-F]*\\)/\\1/p" build/fractal.sym; }
export DUMPDIR="$OUT/mame" A_SCENE=$((16#$(sym scene))) A_TIMER=$((16#$(sym timer)))
ROMPATH="${MAME_ROMPATH:-${HOME}/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms}"
timeout -s KILL 1200 mame coco3 -rompath "$ROMPATH" -ramsize 2M -flop1 build/FRACTAL.DSK -video soft -window -nomaximize \
    -sound none -nothrottle -skip_gameinfo -autoboot_script test/verify.lua 2>&1 | grep -E "SCENE|TIMEOUT"
python3 - "$OUT" <<'PY'
import sys, os
out = sys.argv[1]; bad = 0
for i in range(1, 10):
    m, p = os.path.join(out, "mame/mame%d.bin" % i), os.path.join(out, "model/scene%d.bin" % i)
    if not os.path.exists(m):
        print("scene %d: no dump from MAME" % i); bad += 1; continue
    a, b = open(m, "rb").read(), open(p, "rb").read()
    diff = sum(x != y for x, y in zip(a, b))
    print("scene %d: %s" % (i, "IDENTICAL" if a == b else "differs in %d bytes" % diff)); bad += a != b
print("PASS: all nine scenes are bit-exact" if not bad else "FAIL: %d scene(s)" % bad)
sys.exit(1 if bad else 0)
PY
