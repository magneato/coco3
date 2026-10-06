#!/bin/bash
# test/bench_blast.sh - prove (and time) PULS/PSHU stack blasting against ordinary copy loops
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build
lwasm --6809 --format=decb -o build/BLAST.BIN test/bench_blast.asm || exit 1
python3 scripts/mkdsk.py build/BLAST.DSK WOLF3D.BIN:2=build/BLAST.BIN > /dev/null
pkill -9 mame 2>/dev/null; sleep 4
DSK=build/BLAST.DSK WATCH=$((0x0F00)) TRACE="500-1400:2" DUMP="1400:0F10:3" EXITAT=1401 SNAPDIR=/tmp/blast_snap test/mm.sh 2>&1 | python3 -c "
import sys, re
N, ITER = 3198, 60
last, t0, phases = None, None, {}
verify = None
for l in sys.stdin:
    m = re.search(r'TRACE t=([\d.]+).* W=(\d+)', l)
    if m:
        t, w = float(m.group(1)), int(m.group(2))
        if w != last:
            if last in (1, 2, 3) and t0 is not None and last not in phases and (w == last + 1 or (last == 3 and w in (4, 1))):
                phases[last] = t - t0
            t0, last = t, w
    m = re.search(r'DUMP frame=\d+ @0F10: (\d+) (\d+) (\d+)', l)
    if m: verify = [int(x) for x in m.groups()]
names = {1: 'LDA ,X+ / STA ,Y+      (1 byte/iter)', 2: 'LDD ,X++ / STD ,Y++    (2 bytes/iter)', 3: 'PULS A,B,X,Y / PSHU A,B,X,Y (6 bytes/iter)'}
print('copy of %d bytes x %d, 1.79 MHz, emulated clock:' % (N, ITER))
base = None
for p in (1, 2, 3):
    if p in phases:
        cyc_per_byte = phases[p] * 1.7897725e6 / (N * ITER)
        if base is None: base = cyc_per_byte
        print('  %-44s %.3f s  = %5.2f cycles/byte  (%.2fx)' % (names[p], phases[p], cyc_per_byte, base / cyc_per_byte))
print('  verified (1 = copy correct):', verify)
"
