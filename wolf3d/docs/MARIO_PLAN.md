# Plan: Super Mario Bros. on the CoCo 3 (with audio), the CoCoWolf3D way

Target: World 1-1 first, then the rest of the game, on a TRS-80 Color Computer 3 (6809E at 1.79 MHz,
GIME, 2 MB), run and tested in MAME like CoCoWolf3D. "The original side scroller" is taken to be
*Super Mario Bros.* (NES, 1985). The 1983 arcade *Mario Bros.* is a single-screen game and would be a
much smaller job: the same pipeline minus scrolling.

## 0. Ground rules (same as Wolf3D)
* **No Nintendo data in the repository.** As with `WOLF3D/`, the user supplies their own ROM dump
  (`SMB/smb.nes`, iNES). A `marioai.py` (the counterpart of `wolfai.py`) extracts CHR tiles, palettes,
  level object streams and music at build time. Everything it produces stays in `build/`, which is git-ignored.
* **A stand-in build for distribution**, like the Ashen Bastion: original procedural tiles, a
  "plumber" sprite, an original level and original chiptunes. `release.sh` ships only that.
* NOTICE.md credits Nintendo and states that this is an unofficial fan port.

## 1. What the NES does for free, and what replaces it
| NES | CoCo 3 replacement | Lesson it reuses |
|---|---|---|
| PPU tile background, 256x240 | GIME **256x225x16** (128 B/row) or 256x192 plus a cropped status bar | Wolf3D's 160x192 glass setup, VRES lines field |
| Hardware scrolling | GIME **virtual 256-byte rows (HVEN, $FF9F)**: a 512-px-wide ring. Scroll = HOFFS write; one new 16-px column of tiles drawn at the hidden edge per 16 px moved | FizzleFade/zoom: moving the *video offset* instead of moving bytes |
| 64 hardware sprites | **Compiled sprites** emitted at boot (one routine per frame per even/odd nibble phase), background restored from the tile map ("dirty rectangles") | Wolf3D's compiled column routines, forged at boot |
| Vblank NMI | **PIA vsync IRQ** counting ticks (cube.asm), fixed 60 Hz logic steps, render at 30 Hz if needed | cube.asm's three-instruction IRQ; Wolf's tide counter |
| APU: 2 pulse, triangle, noise, DPCM | **6-bit DAC fed from a 256-byte ring by the GIME timer FIRQ** (Wolf3D: 3934 Hz, every 4 scanlines) | snd_pump / voice_forge |
| 32 KB PRG + 8 KB CHR | 2 MB RAM through MMU windows; bulk data loaded with DSKCON, not LOADM | LOADM stops at $7BFF; `drink_disk` |

Scroll granularity is the main risk. HOFFS moves in 2-byte steps, which is **4 pixels** at 16 colours.
Two remedies, to be decided by experiment in MAME:
1. Accept 4-px steps at 60 Hz. Mario's top speed is about 2.5 px/frame, so the camera alternates between
   steps of 0 and 4. This is acceptable on many CoCo games.
2. Keep two copies of the ring offset by 2 px (an extra 48 KB, cheap in 2 MB) and flip between them with VOFF.
   This gives 2-px steps at no CPU cost; drawing a new column costs twice as much.

Also verify the GIME's known HVEN quirks in MAME *and* note them for real hardware.

## 2. Frame budget (1.79 MHz / 60 = 29,800 cycles per tick)
| Work | Estimate | How |
|---|---|---|
| Game logic (Mario, about 6 enemies, blocks, fireballs) | 6-8 K | Port of the SMB 6502 logic; zero page maps onto the 6809 **direct page** |
| New tile column (every 4th-8th frame) | about 3 K averaged | 16 px x 192 rows = 1.5 KB, PSHU blast from metatile templates |
| Sprites: restore + draw, about 8 x 16x16 | 10-14 K | compiled, pre-shifted even/odd; restore from the map, not a save buffer |
| Audio mixing | 3-4 K | see section 4 |
| HUD digits | <1 K | only when changed (Wolf's gauge_stale) |

Total: 25-30 K, so 60 Hz is borderline and **30 Hz render with 60 Hz logic** is the safe target. Draw into
the hidden copy and flip at vsync (cube.asm's double buffer). An adaptive governor like Wolf3D's ladder
can drop sprite redraws to every other frame when the screen is busy.

## 3. Graphics pipeline (`marioai.py`, `gen_mario.py`)
* **Tiles:** CHR 2bpp 8x8 -> 4bpp nibbles; combine to 16x16 metatiles as the game does. Store each metatile as
  8 bytes x 16 rows, page-aligned so a lattice byte is an address byte (Wolf's "Shape of Data").
* **Colours:** the NES shows up to 25 colours from a 64-entry master palette; the GIME shows 16 from a
  64-entry RGB palette. Map the NES master palette to the nearest GIME RGB entries. Then run the existing
  palette optimiser over each world (overworld, underground, castle, water). Swap the palette per area,
  as SMB itself does.
* **Levels:** decode SMB's object-stream level format into column lists of metatiles in Python. Store
  them compressed by column, and expand one column per 16 px scrolled.
* **Sprites:** Mario (small, big, fire; walk, jump, skid, swim, climb), Goomba, Koopa, piranha, items.
  Compile each frame into straight-line `STA/STD n,U` with masks for transparent nibbles, mirrored
  copies for left/right, and even/odd pixel phases. Emit at boot into pages $50+, as the column forge does.
* **Status bar:** pre-rendered digits, blitted with the Wolf3D gauge's PULS/PSHU blast.

## 4. Audio (the part Wolf3D already proved)
* **Output:** keep Wolf3D's design: GIME timer FIRQ, 6-bit DAC at $FF20, a page-aligned 256-byte ring
  refilled from the main loop (`snd_pump`). Raise the rate to **7.8 kHz** (timer every 2 lines) for
  the pulse channels' harmonics, at about 4% CPU in the FIRQ.
* **Music: pre-render it, don't synthesise it live.** Wolf3D's voice_forge already turns compact tick
  lists into samples at boot. With 2 MB we can do more: render each SMB tune once (overworld loop
  about 20 s at 7.8 kHz = 160 KB) into spare pages. This happens either at build time in Python, emulating
  the APU's 2 pulses + triangle + noise from the user's ROM music data, or at boot. Playback is then a
  page pointer.
* **Effects** (jump, coin, stomp, bump, pipe, 1-up, fireball) are short and also pre-rendered. They are
  **mixed into the ring by addition with a clamp table** in `snd_pump`, with priority rules like
  Wolf's `snd_req`.
* **Tempo changes** (the hurry-up when time runs low) are a second pre-rendered version of each tune.
  The star theme and death jingle are their own tracks.
* **Verification:** capture the WAV with `-wavwrite` and compare runs of samples, not correlations (see
  the gotchas memory).

## 5. Logic port
* Start from a commented community disassembly of SMB as the *reference model*, not as code to ship.
  Write the physics in a Python model first (subpixel speeds, jump gravity tables, the famous
  momentum rules), then translate to 6809. The 6502's A/X/Y and zero page map naturally onto
  A/B, X/Y and the direct page.
* **Bit-exact verification**, as fractal.asm was checked: feed the same input recordings to the Python
  model and to the 6809 build under MAME, then compare Mario's position, speed and state bytes every
  frame through Lua RAM dumps.
* **Autopilot for demos and tests:** replay recorded inputs (a 1-1 speedrun-style route), like the
  terminator mode in Wolf3D, to drive `run.sh --demo N --video mario.mp4`.

## 6. Milestones
| # | Deliverable | Proof |
|---|---|---|
| M0 | `marioai.py`: ROM check (hash), CHR sheet, palette map, 1-1 decoded to a PNG; stand-in assets | contact sheets, like the Wolf extraction |
| M1 | Scrolling 1-1 background at 60 Hz with keyboard camera; DSKCON loader; HUD | MAME screenshots, frame-rate telemetry |
| M2 | Mario: run/jump physics + collision with the map; compiled sprites | Python-model vs MAME RAM traces identical |
| M3 | Blocks (bump, break, coins, power-ups), Goombas, Koopas, pits, death, flagpole | scripted runs of 1-1 |
| M4 | Audio: FIRQ ring at 7.8 kHz, pre-rendered overworld theme + 8 effects | `-wavwrite` captures |
| M5 | Pipes, underground, 1-2 .. 1-4, castle, title screen, lives/score/timer | full world 1 run |
| M6 | Performance pass (governor, 2-px scroll), worlds 2-8, release stand-in build, demo video | `run.sh --mario --video mario.mp4` |

## 7. Risks
* **Scroll smoothness** (section 1), to be decided in M1.
* **Sprite count in busy scenes** (Bowser bridge, many enemies): fall back to drawing every other frame,
  i.e. the flicker the NES itself has.
* **Colour reduction per area** may need hand-tuned overrides.
* **The DSKCON loader must stay under the ROM-mapping rules** (gotchas memory). Load all world data up front
  into pages; there's room.
