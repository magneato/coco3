#!/bin/bash
# scripts/ingame_fps.sh - average breaths per second of the REAL game (input, logic, autopilot, governor all running)
# during a fixed stretch of the terminator's walk.  usage: scripts/ingame_fps.sh [first_frame] [last_frame]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${1:-4900}"; B="${2:-9700}"
pkill -9 mame 2>/dev/null; sleep 2
KEYSEQ="4450-4460:T" SHOTS="$A $B" TELE="4400:6.5:14.5:200" EXITAT=$((B+10)) SNAPDIR=/tmp/ingame_snap "$ROOT/test/mm.sh" 2>&1 | grep SHOT | \
python3 -c "
import sys,re
v=[]
for l in sys.stdin:
    m=re.search(r'frame=(\d+).*fcount=(\d+).*score=(\d+)',l)
    if m: v.append((int(m.group(1)),int(m.group(2)),m.group(3)))
(a,fa,sa),(b,fb,sb)=v[0],v[-1]
print('in-game: %.1f breaths/s over emulated frames %d..%d (%d breaths); score %s -> %s' % ((fb-fa)/((b-a)/60.0),a,b,fb-fa,sa,sb))
"
