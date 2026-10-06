# Credits, licences and the one big caveat

## Game-data build and stand-in build
This repository contains **no data from Wolfenstein 3D**. The game's graphics, maps, sounds and the original executable are
id Software's property and are **not redistributable**. For the full game-art build, you need your own legitimate copy of
**Wolfenstein 3D v1.4 (registered / full version, the `*.WL6` files)**, for example from Steam, GOG or another licensed seller.
Copy these files into a folder named `WOLF3D/` next to `build.sh` (that folder is git-ignored on purpose):

    GAMEMAPS.WL6  MAPHEAD.WL6  VSWAP.WL6  VGAGRAPH.WL6  VGAHEAD.WL6  VGADICT.WL6  WOLF3D.EXE
    (AUDIOHED.WL6, AUDIOT.WL6 and CONFIG.WL6 are not used.)

The standard build extracts textures, sprites, status art, map and palette from those files at build time with
`scripts/wolfai.py`. **Do not publish `build/WOLF3D.DSK`, `build/WOLF3D.DAT` or anything else derived from the commercial data.**

`./release.sh` instead creates the **Ashen Bastion** stand-in release using original procedural textures, sprites, map, HUD art
and synthesized sounds. It does not read or package the commercial data, so this release may be shared under this repository's
Clear BSD licence.

## Credit to id Software
Wolfenstein 3D was created by **id Software** (John Carmack, John Romero, Adrian Carmack and Tom Hall, with music and sound by
Bobby Prince), published by Apogee Software and later by id / Bethesda. *Wolfenstein* and *Wolfenstein 3D* are
trademarks of their respective owners; this project is an unofficial fan port and is **not affiliated with or endorsed by**
id Software, Bethesda or ZeniMax.

## Licence status of id's source code (checked)
id Software published the Wolfenstein 3D source code (github.com/id-Software/wolf3d) under a **"Limited Use Software License
Agreement"**: it permits use of portions of the source *"for educational purposes only"* and forbids commercial use; the repository
says you *"will need the data from a released version of wolf or spear"* to use it, and the data is not included.
This repository **does not contain or copy any id Software source code**. The 6809 engine is original work; it re-implements,
from scratch, the widely documented idea of a grid raycaster, and `scripts/wolfai.py` reads the (publicly documented) file
formats of the user's own data files (LZEXE, VSWAP, MAPHEAD/GAMEMAPS with Carmack+RLEW, Huffman VGAGRAPH). If you want to
reuse anything from id's source, read their licence yourself first.

## Licence of this repository
The original code, scripts and documentation here are under the Clear BSD License (see `LICENSE`, (c) Neural Splines LLC,
BSD-3-Clause-Clear), which grants no patent rights (see `PATENTS.md` in the root of this repository). It covers **only that original
work**; it grants nothing in id Software's game data, art, characters or trademarks.

## About the screenshots and the demo video
`screenshots/*.png`, `cover.png` and `demo.mp4` show the running port, and therefore show id Software's artwork at 160x192 in 16
colours. They are included only to document what the port does. If you want to be conservative, delete them before redistributing;
the contact sheets of the extracted art are deliberately *not* in the repository.

## Other tools
Built with lwtools (lwasm) by William Astle, run in MAME (coco3 driver), encoded with ffmpeg; the CoCo 3 BASIC/Disk BASIC ROMs
used by MAME are not included and are Microsoft/Tandy property.
