#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${ROOT}/release}"
case "$OUT" in
    /*) ;;
    *) OUT="${ROOT}/${OUT}" ;;
esac

"${ROOT}/build.sh" --standin
mkdir -p "$OUT"
cp "${ROOT}/build/WOLF3D.DSK" "${OUT}/WOLF3D.DSK"
cp "${ROOT}/build/WOLF3D.BIN" "${OUT}/WOLF3D.BIN"
cp "${ROOT}/build/WOLF3D.DAT" "${OUT}/WOLF3D.DAT"
cp "${ROOT}/build/wolf3d.sym" "${OUT}/WOLF3D.SYM"
cp "${ROOT}/build/preview_textures.png" "${OUT}/ASSET-PREVIEW.png"
cp "${ROOT}/LICENSE" "${OUT}/LICENSE"

cat > "${OUT}/README.txt" <<'EOF'
ASHEN BASTION - CoCo 3 raycaster stand-in release

This is an original, procedurally illustrated raycaster demo. It does not
contain Wolfenstein 3D or DOOM game data, art, maps, sounds, or executable code.

EMULATOR (MAME)
  mame coco3 -ramsize 2M -flop1 WOLF3D.DSK

When Disk BASIC is ready, enter:
  LOADM"WOLF3D":EXEC

The emulator must provide a CoCo 3 with 2 MB of RAM. For other emulators,
mount WOLF3D.DSK as a 35-track, 18-sector, 256-byte-sector RS-DOS disk image,
boot Disk BASIC, and enter the same LOADM command.

REAL COCO 3
  Write WOLF3D.DSK to a compatible floppy using a tool that supports JVC
  disk images, or copy WOLF3D.DAT and WOLF3D.BIN onto an RS-DOS disk in that
  order. The DAT file must be the first file on the disk. Boot Disk BASIC and
  enter LOADM"WOLF3D":EXEC.

The included BIN and DAT are also present on WOLF3D.DSK. The game requires a
CoCo 3, Disk BASIC/RS-DOS, and 2 MB of RAM.
WOLF3D.SYM is optional symbol metadata used by the project's emulator runner.

Controls: W/UP and S/DOWN move; A/LEFT and D/RIGHT turn; SPACE opens doors;
CTRL or F fires; T toggles autopilot; BREAK returns to BASIC.

Generated from the MIT-licensed source in the CoCoWolf3D project. See LICENSE.
EOF

echo "Release bundle ready: ${OUT}"
echo "Included: WOLF3D.DSK, WOLF3D.BIN, WOLF3D.DAT, WOLF3D.SYM, ASSET-PREVIEW.png, LICENSE, README.txt"
