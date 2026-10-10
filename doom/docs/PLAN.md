# DOOM on the CoCo 3: the plan

Target: **Freedoom Phase 1, E1M1, on a real CoCo 3 with 2 MB**. That means real sectors with different floor and
ceiling heights, real light levels, the four monster types the map places, doors, lifts, barrels, the status bar,
and sound. All of it is built from Freedoom's BSD-licensed data, so the disk can be shared.

The plan has two stages. **Stage A** puts DOOM's look on the Wolf3D engine. It's a guaranteed result, and it
builds the whole art pipeline (palette, dither, light). **Stage B** replaces the grid ray caster with a sector
renderer and reuses everything Stage A made. Each phase ends with a gate. A gate is either a measured number in MAME
plus a screenshot, or a byte-for-byte diff against a Python copy, per the house rules.

Numbers marked *est.* are estimates. Each one gets replaced by a measurement in the phase that builds the thing.

---

## 1. Budgets

### Cycles
The 6809E runs at 1.79 MHz, which is **29,800 cycles per 60 Hz field**.

| Frame rate | Fields | Cycles per frame |
|---|---|---|
| 20 fps | 3 | 89 K |
| 15 fps | 4 | 119 K |
| 12 fps | 5 | 149 K |

Sound takes about 11% of that while a sample is playing.

Measured baseline (`wolf3d/screenshots/fps.txt`): Wolf3D draws 40 strips at half rows in **53 ms (about 95 K
cycles), 18.9 fps**. Stage B adds BSP work on top of that, so the honest target is **12–15 fps while moving at 40
strips, and 20+ fps once foveation and interleaving (§3) are working**.

### Memory (2 MB = 256 pages of 8 KB)
| What | Size (*est.*) | Notes |
|---|---|---|
| Screen | 16 KB (48 KB if the turn-by-scroll test in §3 F4 goes ahead) | 160×192×16, 80 B per row |
| Wall textures, all light bands and dither phases | ≤ 768 KB | made at boot from 1-byte-per-texel sources (L2) |
| Compiled column routines and their entry tables | ~300 KB | Wolf3D already uses about 190 KB |
| Floor and ceiling ramps | ~100 KB | L7 |
| Log and exp tables | ~150 KB | L4 |
| E1M1 geometry, BSP, sector raster | ~130 KB | L5 |
| Sprites (4 monsters, player weapons, items) | ~350 KB | 8 rotations, with mirrored pairs stored once |
| Sound | ~150 KB | 6-bit at 3.9 kHz, the same as Wolf3D |
| **Total** | **≈ 2.0 MB** | The packer in `build.sh` prints this budget and stops the build if it's over |

### Disk
A DECB disk holds about 156 KB, and Wolf3D uses 72 KB of its own. DOOM can't ship finished tables. The disk
carries *sources* (1-byte texels, palette-index sprites, compact geometry), and the boot code builds the big tables
from them, just as Wolf3D builds its 150 routines at start-up. "The boot is the build" doubles as compression. If
E1M1 still doesn't fit one disk, it goes on two (drive 0 and drive 1, as `nsx6809` does), or on one CoCoSDC
image. For now the target is MAME and size is deferred (see Decisions).

---

## 2. The LUTs: what each one replaces

### L1. Dither locked to the screen, set in the instruction stream
Wolf3D's wall bytes hold two *different* texels (the left and right pixel; only ceiling and floor are doubled
nibbles), and its dither is applied in *texture* space when the disk is built. At different wall scales, a
texture-space dither shimmers and makes moiré as each texel stretches over several rows.

L1 moves the dither to **screen space**:
* Each texel colour is matched to a palette pair `(p, q, α)` (`nearest_pair` in Wolf3D's `gen_assets.py` already
  does this).
* A 2×2 Bayer threshold picks p or q per screen pixel. Within a byte, the pixel's horizontal position is fixed
  (left or right nibble), so only the **row parity** varies. Each texel column is therefore stored in two phase
  variants, interleaved: `[t0 phase0, t0 phase1, t1 phase0, ...]`.
* The column compiler knows the screen row *k* of every store, so it emits `LDA 2t+(k&1),Y` instead of `LDA t,Y`.
  **The dither lives in the code's address offsets** and costs nothing at run time.

L6 keeps compiled row = screen row (`U = screen(y0) − y0·160`), so parity stays right at any entry point. The
alternating half rows keep their phase, so the pattern is fixed on screen and doesn't crawl. A 4×4 Bayer version
would need row phase `k&3` (4 variants) plus a +1 `Y` offset on odd strips: that's an option once the memory
budget is known. Each pair gives 5 levels with 2×2 Bayer.

### L2. The light ledger
DOOM lights each wall with *sector light* minus a *distance fade*. The forge already knows the distance: a routine
is forged for a single wall height, and height is 1/distance. So:
* light band = `LIGHT[sector_light][height_class]`, a 2-D table of 32 × 128 bytes;
* each light band is its own **texture page**, so applying the light is the MMU write the ray already makes
  (`sta MMU4`, skipped when the page hasn't changed).

The pages aren't on the disk. Textures ship as one byte per texel, using the **original 256-colour DOOM palette
index**, plus one table: `GIME[colormap_level][doom_index][phase] → byte`, which is 8 × 256 × 2 = 4 KB. At boot
that table is run over every texture, producing every light band and both dither phases. COLORMAP comes straight
from Freedoom's `lumps/colormap`, so the darkening matches DOOM's own.

Texel density is one texel per 4 map units (a 128-tall wall is 32 texels high, which is the Wolf3D column
height). The packer keeps only the light bands each texture can actually appear in (from its sectors' lights and
the distance range), and drops rarely used textures to fewer bands if the budget runs out.

### L3. A palette chosen for its mixtures
Wolf3D chose 16 of the 64 GIME colours by testing them against its art. Here the search scores each candidate
palette on its **136 dithered blends** against Freedoom's PLAYPAL, weighted by how often each colour actually
appears in E1M1's textures and sprites. DOOM's own effects then cost **16 register writes** each:
* the red pain palettes;
* the gold pickup flash;
* the green radiation suit.

They're pre-matched palettes, swapped in during vertical blank.

### L4. Arithmetic in the log domain (where the inverse square root hack fits)
`0x5f3759df` works because a float's bit pattern is roughly its log₂. Stage B does that on purpose: the depth
pipeline works on **16-bit fixed-point log₂ values**.
* **Multiply** becomes an add, and **divide** becomes a subtract: `x·y = EXP[LOG x + LOG y]`.
* **Projection.** Screen column = `COL[LOG|x'| − LOG y']`: one subtract and one lookup, because the column depends
  only on the ratio. Wall scale = `SCALE[LOG y']`.
* **Texture u per column.** It's `rw_offset − tan(θ_col)·dist`. `LOG tan(θ_col)` is a fixed 80-entry table
  (screen columns sit at fixed angles), so each column costs one add and one exp.
* **Inverse square root is a shift.** `rsqrt(x) = EXP[−(LOG x) >> 1]`, the hack with nothing left to
  approximate. It normalises missile and aim vectors, and turns distance into sound volume.
* **The museum piece** promised in `README.md`: the actual magic-constant trick on **Color BASIC's 5-byte floats**
  (exponent byte above a 4-byte mantissa). The constant is worked out for that format in Python, then run on the
  CoCo and compared with `SQR` and `1/` in BASIC. It's a small standalone disk, done early, because it tests the
  idea that L4 rests on.

Table sizes: LOG over a 16-bit input is 128 KB (16 pages; the high bits choose the page). EXP is about 8 KB.
COL, SCALE and LOG tan are each under 1 KB. Each one gets a Python copy and a memory diff.

### L5. The sector raster: one lookup instead of a BSP walk
Offline, Python rasterises E1M1 onto a **16-unit grid** of subsector ids: 247 × 212 cells, 2 bytes each, 104 KB.
One lookup at the player's position replaces `R_PointInSubsector` and gives:
* the floor height under the player, and the sector light;
* collision (a move is allowed if the step is ≤ 24 and the ceiling leaves room);
* the sound and alert sector for monsters.

Doors and lifts still work, because the raster stores *ids* and the heights live in the sector table.

**BSP side bits per subsector.** For each subsector, and for each BSP node whose dividing line doesn't cross that
subsector, the player's side of the line is the same anywhere in it. Python stores 2 bits per (subsector, node)
pair: front, back, or "test". That's 682 × 681 × 2 bits = 116 KB. At run time, most nodes are decided by a bit
lookup instead of a 16×16 cross product. A cross product is only done for the few lines that pass through the
player's own subsector.

### L6. Compiled scalers that can start and stop at any row
Wolf3D's routines always draw a centred wall from ceiling to floor. DOOM needs arbitrary spans: upper walls, lower
walls and middle walls, clipped by portals. The forge writes **one routine per scale class**, quantised to 128
classes and covering up to 152 rows. Each routine comes with an **entry table** (row → address). To draw rows
`[y0, y1)`:
1. Jump to `ENTRY[y0]`.
2. Before the jump, put an `RTS` at `ENTRY[y1]`, and restore that byte afterwards. That's two stores.
3. Set `U = screen(y0) − y0·160`, so the offsets compiled into the routine still point at the right rows.

Walls taller than the screen enter with a texel offset added to `Y` (an error under 1 texel). Textures are stored
twice their height, so `Y+t` never has to wrap. Sprites get the same treatment, with the transparent-run form
already in `forge_figure`.

### L7. Floors and ceilings: depth-faded ramps
Textured flats cost more per pixel than this CPU can spare for every frame. The first version (stretch goals are
in §5) fills floors and ceilings with each **flat's average colour, faded per row by distance**:
* distance(row) = `(viewz − floor_h) · YSLOPE[row]`, where `YSLOPE` is a fixed table;
* each (flat colour, sector light, height-difference class) combination owns a **152-byte ramp** of pre-dithered
  bytes, one per screen row;
* floor spans are drawn with the L6 machinery as `LDA k,X / STA k*160,U`, where `X` points at the ramp.

This is DOOM's fade into darkness, and it costs a store per byte. E1M1 has about 44 flats × a few lights × 16
height classes ≈ 100 KB of ramps.

### L8. Line of sight from REJECT, decisions from a small network
* **REJECT** is already a LUT in the WAD: sector-to-sector visibility, 4 KB for E1M1. It answers "can't see"
  immediately. A blockmap trace runs only when REJECT says "maybe".
* **Monster decisions** use the NSX6809 recipe: binary inputs (can see the player, in melee range, in missile
  range, hurt, recently hit, blocked, player firing, ...) feed a first layer that only **adds**. A 16 → 8 → 5
  network chooses one of chase, strafe, attack, retreat or wait. Cost is about 1–2 K cycles per decision (*est.*),
  with each monster deciding every 4th frame. It's trained offline in Python, first by imitating DOOM's own
  `A_Chase` behaviour (so it plays fair), then tuned. The integer model has a Python copy that matches byte for
  byte, as NSX6809 does.

---

## 3. Foveation and interleaving

Wolf3D already has the basic tools: alternating half rows, a "foveated 32" strip layout, and a speed governor that
switches between layouts. DOOM pushes them further:

* **F1. Foveated columns.** Strips are 2 px wide in the centre, 4 px further out and 8 px at the edges. The ray
  table (`CFG_*`) already describes every strip, so this is just a different table.
* **F2. Foveated dither.** The centre gets L1's two-nibble dither and the full set of light bands. The periphery
  gets plain colours and half the bands, and its routines load texels half as often (fewer `LDA`s). The eye only
  notices the dither where it's looking.
* **F3. A half-rate periphery.** The centre ⅓ of the columns is redrawn every frame, and the outer ⅔ on alternate
  frames, in step with the row parity. While walking forward the edges change least, so that's where to save.
* **F4. Turn by scrolling (experiment).** With the GIME's 256-byte virtual row mode, `HOFFS` scrolls the picture
  horizontally by one byte for one register write. A pure turn shifts the old picture over, and only the newly
  revealed columns are drawn, plus a gradual refresh. A camera rotation isn't exactly a shift, so the error grows
  toward the edges. The gate is screenshots and a measured error. This needs testing on real hardware early,
  because emulators are known to get GIME offset modes wrong.
* **F5. The governor.** Wolf3D's ladder (wider strips, then one row in four) stays as it is, and the F-rungs are
  added to it.

---

## 4. One Stage B frame (*est.*, 40 strips, half rows)

| Step | Work | Cycles |
|---|---|---|
| Find the player's subsector, get z and light | 1 lookup in L5 | < 0.1 K |
| Walk the BSP front to back, with bbox culling | about 150 nodes, mostly decided by side bits | 10 K |
| Transform vertices (cached once per frame) | about 100 × 4 MULs | 15 K |
| Set up segs: log projection, back-face test, clipping | about 80 segs × 250 | 20 K |
| Per column: scale, top/bottom steps, u via L4, clip arrays | 40 × 300 | 12 K |
| Draw walls, floors and ceilings with L6 and L7 | about 76 rows × 40 strips | 25 K |
| Sprites (clipped against floor and ceiling clip arrays) | about 6 on screen | 12 K |
| Game logic, monsters, input, status bar | | 10 K |
| Sound (11% while playing) | | 13 K |
| **Total** | | **≈ 117 K → about 15 fps** |

The two biggest unknowns are the seg count per frame and the vertex cost. Phase 3 measures both with a debug
counter that the test harness reads, as Wolf3D's tests read `refreshes`.

---

## 5. Phases and gates

**P0. Scaffold.** `doom/` gets the same layout as its siblings: `setup.sh`, `build.sh`, `run.sh`, `Makefile` and
`test/`. The first piece is `scripts/wad.py`, which reads levels, PLAYPAL, COLORMAP, patches, flats and sprites
from `freedoom/`. Then come the L3 palette search and contact sheets of everything after quantising.
*Gate:* contact sheets show E1M1's textures, flats and sprites in the chosen 16 colours plus their dithered blends,
and the Python copy of L1/L2 matches its own reference.

**P1. Stage A: DOOM art on the Wolf3D engine.** A fork of `wolf3d/` with:
* Freedoom wall textures, sprites (zombieman, shotgun guy, imp, demon), status bar, face and weapons;
* sounds from `freedoom/sounds/*.wav` through `sounds.py`;
* L1, L2 (sector light becomes a light value per grid cell, so rooms have different light) and L3 with the pain
  and pickup palettes;
* a small original grid level built from Freedoom pieces.

*Gate:* the frame rate on the bench matches Wolf3D's within 10%, and the same disk boots on the real CoCo 3. This
is "DOOM graphics on Wolf3D", finished, before anything risky starts.

**P2. The math kernel.** The L4 tables, `COL`/`SCALE`/`EXP`/rsqrt, and the 5-byte float museum disk. *Gate:* the
Python copy and the CoCo's memory dump match byte for byte over a sweep of inputs, and the rsqrt error is
reported against an exact reference.

**P3. A static sector renderer.** It covers BSP traversal, the vertex cache, seg projection and solid walls only.
Floors and ceilings are flat colour, and there's a fly-through camera with no physics. *Gate:* the E1M1 start
room is recognisable next to a reference render from the Python copy, and fps and seg counts are measured at 4
spots, as `bench.sh` does.

**P4. Portals and heights.** It adds:
* upper, lower and middle walls;
* floor and ceiling clip arrays;
* the L6 entry and exit tables;
* L7 ramps and the L2 light ledger;
* L5 side bits.

*Gate:* the stairs and the raised areas of E1M1 look right, and the fps meets the §4 estimate or the gap is
explained.

**P5. Being there.** It adds:
* player movement and collision through L5;
* doors and lifts (sector height changes);
* pickups, barrels and weapons drawn in the player's hands;
* the status bar;
* sound.

*Gate:* the start of E1M1 can be walked to its exit by scripted keys in `test/`.

**P6. Monsters.** First the four DOOM state machines (frames and timings taken from Freedoom's DEHACKED/info
data), then L8: REJECT line of sight and the NSX-style brain. *Gate:* scripted fights, with screenshots, and a
byte-for-byte match between the brain and its Python copy.

**P7. Speed and the real machine.** F1–F5, tuning on the physical CoCo 3, disk packaging, and `release.sh`.

**Stretch goals:**
* textured flats near the screen centre only (F2 applied to floors), at about 25 cycles per pixel;
* E1M2 onward;
* title music on the 3-voice mixer from `cubes/`;
* a fuzz effect for the spectre (one palette slot that flickers).

---

## 6. Rules and risks

* **Our own code, the same algorithms.** The DOOM source is GPL and this repo is Clear BSD. We read the algorithms
  (BSP traversal, `R_RenderSegLoop`, clip arrays) and write our own 6809 code. Every table is generated from
  maths in our Python scripts, never copied from `tables.c`. Freedoom's data is BSD, so the disk is shareable.
* **Precision in the log domain.** 16-bit log₂ gives about 0.3% relative error, which is plenty for projection.
  Clipping against the near plane needs a linear path for very small `y'`. That's tested in P2.
* **Seg count.** If E1M1's busiest views run to hundreds of segs, the fallback is a per-subsector PVS list worked
  out offline (a LUT of candidate segs), which trims the BSP walk further.
* **HOFFS on real hardware (F4).** Test it first, before relying on it.

## Decisions (2026-10-10)
1. **Target is MAME for now.** Disk size and real-hardware storage are deferred until the game is done. The build
   may use as many disks, or as large an image, as it needs.
2. **Field of view: 60°** (Wolf3D's is about 66°). A narrower view means fewer segs per frame, and each of the 80
   screen columns covers 0.75°.
3. **RGB monitor.** The palette search (L3) and the L1 dither target the GIME's RGB colours. Composite artefact
   colours are out of scope.

## P0 findings (format notes)
* PLAYPAL (14 palettes) and COLORMAP are *generated* by GPL-2.0+ Freedoom scripts: run them as build tools
  (`python3 lumps/playpal/playpal lumps/playpal/playpal-base.lmp`, and `lumps/colormap/colormap` on the same base
  file); never copy their code. Outputs: 10,752 B and 8,704 B.
* Sprite offsets are in `freedoom/buildcfg.txt` under `[sprites]` (for example `POSSA1 22 53`), not in the PNGs.
  Sprite PNGs are mode P with transparency; patches are mode L; flats are mode P, 64×64.
* Wall textures are composed from patches by `freedoom/lumps/textures/textures.cfg`. Freedoom's `simplecpp` fails
  on includes that only exist after a Freedoom build, so `wad._cpp` handles the `#ifdef` subset itself.
* E1M1 places zombiemen (3004) ×12, shotgun guys (9) ×13, imps (3001) ×18, demons (3002) ×9 and a spectre (58) ×1.
  Floors range from −168 to 450 and ceilings from −128 to 536.

## Status (2026-10-10)
**Stage A is playable in MAME** (P0 and P1 done; see README.md): E1M1 on the grid, Freedoom art, DOOM's status
bar, four monster types, sound. `make test` passes, and the speed is 16.0 fps moving at 40 strips.

How the techniques landed, where they differ from the design above:
* **L1** needed no change to the column compiler. Each frame paints rows of one parity, so the dither phase is a
  choice between two texture pages, not an `LDA 2t+(k&1),Y` offset.
* **L2** is 8 band pages × 2 phases, forged at boot from 1-byte index texels (`forge_pages`). The disk carries the
  index texels as lossy RLE (35%), not finished pages. All 30 forged pages are compared with the Python twin in
  `make test`.
* **L3** uses OKLab with chroma weighted ×4 and a dither-noise charge. Redmean let browns drift to pink, and plain
  OKLab drew greys as teal+red.
* **L7** is a single fading ramp for the ceiling and the floor, baked into the column routines (no textured flats).
* DOOM's proportions on the grid: walls 128 units tall, 26 taller-than-view column classes (84 classes is the
  routine-table maximum), figures standing on the floor and cut at the view's bottom row.
* Added beyond the plan: **floor reflections** of walls and figures, compiled into the column routines
  (0.6% of the frame).
* Not yet: L4 (log domain), L5 (BSP side bits), L6 (entry/exit tables), L8 (REJECT, the NSX-style monster
  brain), F2-F5. Those belong to Stage B (P2 onward).
