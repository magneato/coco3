#!/bin/bash
# test/mm.sh - run the game in MAME exactly like run.sh and drive it with test/harness.lua
#   SHOTS="900 1000" KEYSEQ="900-940:RIGHT" EXITAT=1100 test/mm.sh [extra mame args]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP="${SNAPDIR:-$ROOT/screenshots/_tmp}"
rm -rf "$SNAP"; mkdir -p "$SNAP"
timeout -s KILL "${TIMEOUT:-300}" mame coco3 \
    -rompath "$HOME/mame/roms;/usr/local/share/games/mame/roms;/usr/share/games/mame/roms" \
    -ramsize 2M -flop1 "${DSK:-$ROOT/build/WOLF3D.DSK}" \
    -video soft -window -nomaximize -sound none ${NOTHR:--nothrottle} -skip_gameinfo \
    -snapshot_directory "$SNAP" -autoboot_script "$ROOT/test/harness.lua" "$@" 2>&1 | grep -E "SHOT|TRACE|TXT|DUMP|rror|ERR"
ls "$SNAP/coco3" 2>/dev/null
