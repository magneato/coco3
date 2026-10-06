#!/bin/bash
# scripts/bench.sh - frames-per-second benchmark.  Builds the BENCH variant (a camera that spins one full
# revolution at four map-derived spots - cramped / typical / open / worst - flat out, no vsync) and
# measures the frame rate from MAME's emulated clock.   usage: scripts/bench.sh [quality 0|1|2|still]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
Q="${1:-0}"
python3 scripts/gen_assets.py build > /dev/null
lwasm --6809 --format=decb -DBENCH=1 -DBENCHQ="$Q" $BENCH_DEFS --output=build/BENCH.BIN wolf3d.asm || exit 1
python3 scripts/mkdsk.py build/BENCH.DSK WOLF3D.DAT:1=build/WOLF3D.DAT WOLF3D.BIN:2=build/BENCH.BIN > /dev/null
pkill -9 mame 2>/dev/null; sleep 1
DSK=build/BENCH.DSK TRACE="4400-5200:20" EXITAT=5201 SNAPDIR=/tmp/bench_snap test/mm.sh 2>&1 | grep TRACE | \
python3 -c "
import sys, re
pts = []
for l in sys.stdin:
    m = re.search(r't=([\d.]+).*fcount=(\d+)', l)
    if m: pts.append((float(m.group(1)), int(m.group(2))))
pts = [p for p in pts if 0 < p[1] < 30000]
for i in range(0, len(pts) - 1, 4):
    a, b = pts[i], pts[min(i + 4, len(pts) - 1)]
    if b[0] > a[0]: print('  t=%6.2f  fcount %4d..%4d  %5.1f fps' % (a[0], a[1], b[1], (b[1] - a[1]) / (b[0] - a[0])))
a, b = pts[0], pts[-1]
print('  quality $Q: average %.1f fps over %d frames (%.1f ms/frame)' % ((b[1]-a[1])/(b[0]-a[0]), b[1]-a[1], 1000*(b[0]-a[0])/(b[1]-a[1])))
"
