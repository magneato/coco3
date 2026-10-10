#!/usr/bin/env python3
"""
gen_assets.py - Freedoom's E1M1 shaped into the tables the 6809 swallows at boot.  Invoked by build.sh.

Sources (all through wad.py, straight from the freedoom/ checkout):
  map        E1M1 rasterised onto the 64 x 64 lattice by grid.py: walls, doors, the exit switch, the start
  walls      the textures that face E1M1's open cells (the 12 most used keep their own slot), doors, the switch
  figures    zombiemen, shotgun guys, imps and demons (front views), pickups and decor, the weapons in hand
  gauge      DOOM's status bar: STBAR with its digits, ARMS panel, keys and faces composited onto it
  sounds     Freedoom's WAVs (sounds.py)
Colour: the 16 GIME colours chosen by palette.py, light and dither through dither.py's tables (L1-L3).

Writes into the build directory:
  equ.inc       constants shared with doom.asm and code2.asm
  pal.inc snd.inc tables2.inc stage.inc   tables assembled into the program
  parts/*.bin   the 8 KB page images of DOOM.DAT, dat_layout.txt their order
  sheets/       what the CoCo will show (map, walls, figures, gauge)

Rules applied: no division at run time (every reciprocal is a table here), data stored in the order it is read
(textures column-major, the gauge pre-reversed for the stack blast), everything computed once, here.
"""
import math, os, sys, struct
from collections import Counter, deque
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import wad, palette, dither, grid, sounds, mkdsk, rle

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(wad.ROOT, "build")
MAPNAME = os.environ.get("DOOM_MAP", "e1m1")
os.makedirs(OUT, exist_ok=True)
SHEETS = os.path.join(OUT, "sheets"); os.makedirs(SHEETS, exist_ok=True)

# ----------------------------------------------------------------------------
# geometry
# ----------------------------------------------------------------------------
SCR_W, SCR_H, STRIDE = 160, 192, 80
VIEW_H = 152                      # 3D view rows; the gauge takes the 40 rows below
HUD_H = SCR_H - VIEW_H
HALF = VIEW_H // 2                # 76 half-rows (row-interlaced rendering)
HUD_TOP = VIEW_H
BAR_TOP = HUD_TOP + 8             # DOOM's 32-row status bar sits on the bottom 32 rows; 8 rows of frame above it
ANGLES = 512                      # angle units per circle
FOV_DEG = 60.0
PROJ_K = 40.0 / math.tan(math.radians(FOV_DEG / 2))   # screen bytes per unit of lateral/forward (planar projection)
KH_SQUARE = 98.0 * PROJ_K / (40.0 / math.tan(math.radians(33.05)))   # half-rows of a 64-unit-tall wall at 1 cell
KH = 2 * KH_SQUARE                # DOOM's walls are 128 units tall on a 64-unit cell (eye at mid-height)
NCLS = 6                          # fisheye cosine classes
TEXW, TEXH = 32, 32               # texels per wall face (32 wide = 16 byte-columns of 2 px; 32 rows)
WALL_UNITS = 128                  # a wall face shows 64 x 128 units of its texture
NBANDS = len(dither.BANDS)        # light bands (COLORMAP levels 0, 4, .. 28)
SPR_BAND = 1                      # figures carry one light band (both dither phases)
LIGHT_BIAS = int(os.environ.get("DOOM_LIGHT_BIAS", "1"))   # bands brighter than DOOM: 64 colours lose its darkest steps
# wall column classes: 58 plain heights (odd up to 35, then every one to 76), then 26 classes taller than the view,
# each showing n of the texture's 32 rows (n = 31 .. 6) centred.  Entries are 3 bytes at class x 3 in a 256-byte
# routine-table page, so class 84 (bytes 252-254) is the last that fits.
N_MIN = 6
WALL_CLS = [(h, 0, 32) for h in list(range(1, 36, 2)) + list(range(37, HALF + 1))] + \
           [(HALF, 16 - n // 2, n) for n in range(31, N_MIN - 1, -1)]
NCLASS = len(WALL_CLS)
assert NCLASS * 3 + 2 <= 255
def wall_class(hh):
    """virtual wall height in half-rows -> class number (1-based)"""
    if hh <= HALF:
        return 1 + min(range(58), key=lambda e: abs(WALL_CLS[e][0] - hh))
    n = max(N_MIN, min(31, int(round(32.0 * HALF / hh))))
    return 1 + 58 + (31 - n)
def class_height(e):
    h, t0, n = WALL_CLS[e - 1]
    return h if n == 32 else 32.0 * HALF / n
def fade_bands(hh):
    """DOOM's scalelight: a wall is brighter by (scale index)/2 COLORMAP levels, scale index = 16 x 160 / distance"""
    d = 64.0 * KH / max(hh, 0.5)
    return -min(47.0, 2560.0 / d) / 2.0 / 4.0

# ----------------------------------------------------------------------------
# the lattice
# ----------------------------------------------------------------------------
G = grid.build(MAPNAME)
lev = G.level
NWALL = 12                        # wall slots 0..11; 12 = the exit switch, 13 = door, 14 = second door look
SWITCH_TEX, DOOR_TEX, ELEV_TEX = 12, 13, 14
NTEX = 15
cells = [(i, t) for i, t in enumerate(G.tex) if t and G.kind[i] == grid.SOLID]
use = Counter(t for _, t in cells)
wall_names = [t for t, _ in use.most_common(NWALL)]
door_use = Counter(G.tex[i] for i in range(4096) if G.kind[i] == grid.DOOR and G.tex[i])
door_names = [t for t, _ in door_use.most_common(2)] or ["BIGDOOR2"]
while len(door_names) < 2:
    door_names.append(door_names[0])
switch_name = None
if G.exit:
    for ld in lev.linedefs:
        if ld.special in grid.EXIT_SPECIALS:
            s = lev.sidedefs[ld.right]
            switch_name = next((t for t in (s.middle, s.lower, s.upper) if t != "-"), None)
            break
switch_name = switch_name or "SW1EXIT"
TEX_NAMES = wall_names + [switch_name] + door_names
assert len(TEX_NAMES) == NTEX, TEX_NAMES

pal_doom = np.array(wad.playpal()[0], dtype=float)
def tex_face(name):
    """the 64 x 128 units of a texture a lattice face shows, tiled when the texture is smaller"""
    w, h, rows = wad.texture(name)
    return [[rows[y % h][x % w] for x in range(64)] for y in range(WALL_UNITS)]
def mean_colour(rows):
    v = [c for r in rows for c in r if c is not None]
    return palette.unlin(palette.lin(pal_doom[v]).mean(axis=0)) if v else np.zeros(3)
slot_of = {n: i for i, n in enumerate(wall_names)}
slot_col = [mean_colour(tex_face(n)) for n in wall_names]
for t in use:                                                   # the rest borrow the nearest-looking slot
    if t not in slot_of:
        c = mean_colour(tex_face(t))
        slot_of[t] = int(np.argmin(palette.dist2(np.array(slot_col), c)))

mapb = bytearray(4096)
for i in range(4096):
    k = G.kind[i]
    if k == grid.OPEN:
        continue
    if k == grid.DOOR:
        mapb[i] = 0x80 + DOOR_TEX * 2
    else:
        mapb[i] = 0x80 + slot_of.get(G.tex[i], 0) * 2
if G.exit:
    ex, ey, _ = G.exit
    mapb[ey * 64 + ex] = 0x80 + SWITCH_TEX * 2
for i in range(4096):                                           # the outer ring is always rock
    x, y = i % 64, i // 64
    if x in (0, 63) or y in (0, 63):
        mapb[i] = mapb[i] or 0x80
def light_band(light):
    """DOOM: startmap = (15 - light/16) x 4 COLORMAP levels -> our band (4 levels each)"""
    return max(0, min(NBANDS - 1, 15 - light // 16 - LIGHT_BIAS))
lightmap = bytes(2 * light_band(G.light[i]) for i in range(4096))
START_X, START_Y = int(G.start[0]), int(G.start[1])
START_ANG = int(round(G.start[2] * ANGLES / 360.0)) % ANGLES
assert mapb[START_Y * 64 + START_X] == 0

# ----------------------------------------------------------------------------
# colour: the palette (L3) and the light tables (L1/L2)
# ----------------------------------------------------------------------------
tcols, tw = palette.targets(lev)
PAL, pal_cost, pal_plain = palette.search(tcols, tw)
HI, LO = dither.light_tables(PAL)
def gime(c): return palette.gime(c)
def nearest_slot(rgb, avoid0=False):
    d = palette.dist2(np.array(PAL, dtype=float), np.asarray(rgb, dtype=float))
    if avoid0: d[0] = 1e30
    return int(np.argmin(d))

# ceiling and floor: the commonest flats of the open cells, through the light the player mostly stands in
fl_use = Counter(lev.sectors[s].floorpic for s in G.sector if s is not None)
ce_use = Counter(lev.sectors[s].ceilpic for s in G.sector if s is not None and not lev.sectors[s].ceilpic.startswith("F_SKY"))
def flat_colour(name, band):
    rows = wad.flat(name); cm = wad.colormap()[dither.BANDS[band]]
    v = [cm[c] for r in rows for c in r]
    return palette.unlin(palette.lin(pal_doom[v]).mean(axis=0))
def flat_at_level(name, level):
    """the colour a flat reads as from afar: the eye follows a textured floor's highlights, so the mean of its
    brighter half (a plain mean of Freedoom's dark flats lands below the GIME's darkest grey blend)"""
    rows = wad.flat(name); cm = wad.colormap()[max(0, min(31, int(round(level))))]
    l = palette.lin(pal_doom[[cm[c] for r in rows for c in r]])
    y = l @ np.array([0.2126, 0.7152, 0.0722])
    return palette.unlin(l[y >= np.median(y)].mean(axis=0))
CEIL_FLAT, FLOOR_FLAT = ce_use.most_common(1)[0][0], fl_use.most_common(1)[0][0]
open_lights = sorted(lev.sectors[s].light for s in G.sector if s is not None)
BASE_LIGHT = open_lights[len(open_lights) // 2]                  # the light the player mostly stands in
def plane_byte(k):
    """half-row k of the view: ceiling above the horizon, floor below, at DOOM's distance light"""
    r = abs(k - HALF / 2 + 0.5)                                  # half-rows from the horizon
    t = KH / (2.0 * r)                                           # the plane is 64 units from the eye: cells away
    level = (15 - BASE_LIGHT // 16 - LIGHT_BIAS) * 4 - min(47.0, 2560.0 / (64.0 * t)) / 2.0
    c = flat_at_level(CEIL_FLAT if k < HALF // 2 else FLOOR_FLAT, level)
    a, b, kk = dither.best_blend([c], PAL)[0]
    ph = k & 1
    return (dither.nibble(a, b, kk, ph, 0) << 4) | dither.nibble(a, b, kk, ph, 1)
plane_ramp = bytes(plane_byte(k) for k in range(HALF))
CEIL_IX, FLOOR1_IX = plane_ramp[HALF // 2 - 1] >> 4, plane_ramp[HALF - 1] >> 4
FLOOR2_IX = FLOOR1_IX

# ----------------------------------------------------------------------------
# walls -> bytes: tex*512 + col*32 + row ; 16 byte-columns x 32 rows ; byte = left texel's nibble << 4 | right's
# ----------------------------------------------------------------------------
tex_texels = [dither.index_texels(tex_face(n), 64 // TEXW, WALL_UNITS // TEXH) for n in TEX_NAMES]
def page_of(texels_list, hi, lo):
    """what the boot forge makes from index texels: byte = HI[left] | LO[right], column-major (the Python twin)"""
    b = bytearray()
    for tt in texels_list:
        for c in range(TEXW // 2):
            for r in range(TEXH):
                b.append(hi[tt[r][2 * c]] | lo[tt[r][2 * c + 1]])
    return bytes(b)
TEX_LEN = NTEX * 512

# ----------------------------------------------------------------------------
# figures: 0..47 still objects (the engine knows ids 6, 20, 21, 24..33 as pickups), 48..60 the monster's frames,
# 61..68 the weapon in hand (ready, firing) x (fist, pistol, shotgun, chaingun)
# ----------------------------------------------------------------------------
PICKUP_OF = {          # DOOM thing -> (engine pickup id, sprite)
    2011: (24, "STIMA0"), 2012: (25, "MEDIA0"), 2023: (25, "PSTRA0"),
    2007: (26, "CLIPA0"), 2048: (26, "AMMOA0"), 2008: (26, "SHELA0"), 2049: (26, "SBOXA0"),
    2001: (27, "SHOTA0"), 2002: (28, "MGUNA0"),
    2014: (6, "BON1A0"), 2015: (29, "BON2A0"), 2046: (30, "BROKA0"), 2010: (30, "ROCKA0"), 2047: (30, "CELLA0"),
    2018: (31, "ARM1A0"), 2019: (32, "ARM2A0"), 2013: (33, "SOULA0"),
    5: (20, "BKEYA0"), 40: (20, "BSKUA0"), 13: (21, "RKEYA0"), 38: (21, "RSKUA0"), 6: (21, "YKEYA0"), 39: (21, "YSKUA0"),
}
DECOR_OF = {           # DOOM thing -> (sprite, blocks the way)
    2035: ("BAR1A0", True), 2028: ("COLUA0", True), 48: ("ELECA0", True), 30: ("COL1A0", True), 31: ("COL2A0", True),
    32: ("COL3A0", True), 33: ("COL4A0", True), 36: ("COL5A0", True), 37: ("COL6A0", True), 34: ("CANDA0", False),
    35: ("CBRAA0", True), 43: ("TRE1A0", True), 47: ("SMITA0", True), 54: ("TRE2A0", True), 44: ("TBLUA0", True),
    45: ("TGRNA0", True), 46: ("TREDA0", True), 55: ("SMBTA0", True), 56: ("SMGTA0", True), 57: ("SMRTA0", True),
    85: ("TLMPA0", True), 86: ("TLP2A0", True), 2025: ("SUITA0", False), 10: ("PLAYW0", False), 12: ("PLAYW0", False),
    15: ("PLAYN0", False), 18: ("POSSL0", False), 19: ("SPOSL0", False), 20: ("TROOM0", False), 21: ("SARGN0", False),
    24: ("POL5A0", False), 79: ("POB1A0", False), 80: ("POB2A0", False), 81: ("BRS1A0", False), 41: ("CEYEA0", True),
    42: ("FSKUA0", True), 25: ("POL1A0", True), 26: ("POL6A0", True), 27: ("POL4A0", True), 28: ("POL2A0", True),
    29: ("POL3A0", True), 49: ("GOR1A0", True), 50: ("GOR2A0", True), 51: ("GOR3A0", True), 52: ("GOR4A0", True),
    53: ("GOR5A0", True), 70: ("FCANA0", True), 72: ("KEENA0", True),
}
MONSTER_OF = {3004: "POSS", 9: "SPOS", 3001: "TROO", 3002: "SARG", 58: "SARG"}
MONSTER_HP = {"POSS": 20, "SPOS": 30, "TROO": 60, "SARG": 150}
# the engine's 13 monster frames: stand, walk 1-4, shoot 1-3, pain, die 1-3, dead -> DOOM frame letters (front view)
MONSTER_FRAMES = {"POSS": "AABCDEFEGHIJL", "SPOS": "AABCDEFEGHIJL", "TROO": "AABCDEFGHIJKM", "SARG": "AABCDEFGHIJKN"}
G_STAND, G_WALK, G_SHOOT, G_PAIN, G_DIE, G_DEAD = 48, 49, 53, 56, 57, 60
G_FRAMES = 13
MONSTER_TYPES = ["POSS", "SPOS", "TROO", "SARG"]                  # frame sets 48, 61, 74, 87 (code2's set_frame)
WEAP_BASE = G_STAND + G_FRAMES * len(MONSTER_TYPES)

def sprite_lump(name):
    """a lump name or its mirrored-pair form (TROOA2A8 holds A2 and, mirrored, A8)"""
    offs = wad.sprite_offsets()
    if name in offs:
        return name, False
    for n in offs:
        if len(n) == 8 and n[:4] == name[:4] and n[6:8] == name[4:6]:
            return n, True
        if len(n) == 8 and n[:6] == name:
            return n, False
    raise KeyError(name)

def world_cells(name):
    """a figure on its 64 x 64-unit canvas (feet on the bottom edge, origin in the middle), 32 x 32 texels"""
    lump, mirror = sprite_lump(name)
    w, h, xo, yo, rows = wad.sprite(lump)
    if mirror:
        rows = [r[::-1] for r in rows]; xo = w - xo
    canvas = [[None] * 64 for _ in range(64)]
    for y in range(h):
        cy = 64 - yo + y
        if not 0 <= cy < 64: continue
        for x in range(w):
            cx = 32 - xo + x
            if 0 <= cx < 64 and rows[y][x] is not None:
                canvas[cy][cx] = rows[y][x]
    return dither.index_texels(canvas, 2, 2, transparent=True)

WEAP_X0, WEAP_W, WEAP_Y0, WEAP_H = 114, 92, 116, 84            # the part of DOOM's 320 x 200 screen the engine shows
def weapon_cells(names):
    """psprites composed where DOOM puts them (full-screen reference, bottom at row 200), then the window"""
    canvas = [[None] * 320 for _ in range(200)]
    for name in names:
        w, h, xo, yo, rows = wad.sprite(name)
        left, top = 1 - xo, int(round(31.5 - yo))
        for y in range(h):
            for x in range(w):
                if rows[y][x] is not None and 0 <= top + y < 200 and 0 <= left + x < 320:
                    canvas[top + y][left + x] = rows[y][x]
    out = []
    for ty in range(32):
        r = []
        for tx in range(32):
            ys = range(WEAP_Y0 + ty * WEAP_H // 32, WEAP_Y0 + (ty + 1) * WEAP_H // 32)
            xs = range(WEAP_X0 + tx * WEAP_W // 32, WEAP_X0 + (tx + 1) * WEAP_W // 32)
            box = [canvas[y][x] for y in ys for x in xs]
            op = [v for v in box if v is not None]
            if 2 * len(op) < len(box):
                r.append(None); continue
            c = palette.unlin(palette.lin(pal_doom[op]).mean(axis=0))
            r.append(dither.snap_index(tuple(int(round(v)) for v in c)))
        out.append(r)
    return out

# still objects: pickups keep their engine ids, decor takes the free ids in order of how often it appears
objs_src = []                                                    # (kind, DOOM type, fx, fy)
for typ, fx, fy, ang in G.things:
    if typ in MONSTER_OF: objs_src.append((3, typ, fx, fy))
    elif typ in PICKUP_OF: objs_src.append((2, typ, fx, fy))
    elif typ in DECOR_OF: objs_src.append((1, typ, fx, fy))
FREE_IDS = [i for i in range(48) if i not in (6, 20, 21, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33)]
decor_use = Counter(t for k, t, _, _ in objs_src if k == 1)
decor_sprites = {}
for t, _ in decor_use.most_common():
    s = DECOR_OF[t][0]
    if s not in decor_sprites.values() and len(decor_sprites) < len(FREE_IDS):
        decor_sprites[FREE_IDS[len(decor_sprites)]] = s
decor_id = {t: next((i for i, s in decor_sprites.items() if s == DECOR_OF[t][0]), None) for t in decor_use}
static_sprite = {i: s for i, s in decor_sprites.items()}
for t, (i, s) in PICKUP_OF.items():
    static_sprite.setdefault(i, s)
spr_cells = []
for i in range(48):
    s = static_sprite.get(i)
    spr_cells.append(world_cells(s) if s else [[None] * 32 for _ in range(32)])
for m in MONSTER_TYPES:
    for f in MONSTER_FRAMES[m]:
        spr_cells.append(world_cells(f"{m}{f}1" if f"{m}{f}1" in wad.sprite_offsets() or any(
            n[:6] == f"{m}{f}1" or (len(n) == 8 and n[:4] == m and n[6:8] == f"{f}1") for n in wad.sprite_offsets()) else f"{m}{f}0"))
WEAP_FRAMES = [["PUNGA0"], ["PUNGB0"], ["PISGA0"], ["PISGB0", "PISFA0"], ["SHTGA0"], ["SHTGA0", "SHTFA0"],
               ["CHGGA0"], ["CHGGA0", "CHGFA0"]]
spr_cells += [weapon_cells(f) for f in WEAP_FRAMES]
NSPR = len(spr_cells)
assert NSPR == WEAP_BASE + 8 and NSPR <= 128

# figure bytes: 0 = transparent.  A reserved DOOM index stands for "no pixel" (the boot tables give it 0); a byte
# with one opaque pixel takes that pixel's colour in both halves; the figure tables never use palette 0 for an
# opaque pixel, so an opaque byte is never 0.
TRANSPARENT = next(i for i in range(255, -1, -1) if dither.snap_index(tuple(wad.playpal()[0][i])) != i)
def figure_tables():
    pp, cm = wad.playpal()[0], wad.colormap()
    blends = dither.best_blend([pp[cm[dither.BANDS[SPR_BAND]][i]] for i in range(256)], PAL[1:])
    hi = [[0] * 256 for _ in range(2)]; lo = [[0] * 256 for _ in range(2)]
    for i, (a, b, k) in enumerate(blends):
        if i == TRANSPARENT: continue
        for ph in (0, 1):
            hi[ph][i] = (dither.nibble(a, b, k, ph, 0) + 1) << 4
            lo[ph][i] = dither.nibble(a, b, k, ph, 1) + 1
    return hi, lo
SHI, SLO = figure_tables()
def figure_texels(cells):
    """None -> TRANSPARENT, and a lone opaque pixel lends its colour to its transparent byte partner"""
    out = [[TRANSPARENT if v is None else v for v in r] for r in cells]
    for y in range(32):
        for c in range(16):
            l, r = cells[y][2 * c], cells[y][2 * c + 1]
            if l is None and r is not None: out[y][2 * c] = r
            if r is None and l is not None: out[y][2 * c + 1] = l
    return out
spr_texels = [figure_texels(c) for c in spr_cells]
spr_bytes = page_of(spr_texels, SHI[0], SLO[0])
assert len(spr_bytes) == NSPR * 512
colmask = b""
for sid in range(NSPR):
    m = 0
    for col in range(16):
        if any(spr_bytes[sid * 512 + col * 32 + r] for r in range(32)): m |= 1 << col
    colmask += m.to_bytes(2, "big")

# ----------------------------------------------------------------------------
# the autopilot's goal (the open cell in front of the exit switch) and the doors to restore on a restart
# ----------------------------------------------------------------------------
DOORC = 0x80 + DOOR_TEX * 2
DOOR2C = 0x80 + ELEV_TEX * 2
def passable(n): return 0 <= n < 4096 and (mapb[n] == 0 or mapb[n] in (DOORC, DOOR2C))
START_IDX = START_Y * 64 + START_X
reach = {START_IDX: 0}; dq = deque([START_IDX])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in reach: reach[n] = reach[c] + 1; dq.append(n)
SW_TILES = [(i % 64, i // 64) for i in range(4096) if mapb[i] == 0x80 + SWITCH_TEX * 2]
cands = []
for ex, ey in SW_TILES:
    for (dx, dy), ang in (((1, 0), 256), ((0, 1), 384), ((-1, 0), 0), ((0, -1), 128)):
        nx, ny = ex + dx, ey + dy
        if 0 <= nx < 64 and 0 <= ny < 64 and (ny * 64 + nx) in reach:
            cands.append((reach[ny * 64 + nx], nx, ny, ang))
assert cands, "the exit switch cannot be reached from the start"
_, GOAL_X, GOAL_Y, GOAL_ANG = max(cands)
DOOR_TILES = [i for i in range(4096) if mapb[i] in (DOORC, DOOR2C)]
DOOR_KIND = [1 if mapb[i] == DOOR2C else 0 for i in DOOR_TILES]
dist = {GOAL_Y * 64 + GOAL_X: 0}; dq = deque([GOAL_Y * 64 + GOAL_X])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in dist:
            dist[n] = dist[c] + 1; dq.append(n)
assert len(dist) <= 2000 and max(dist.values()) < 250, (len(dist), max(dist.values()))
assert START_IDX in dist
AI_INFO = f"goal ({GOAL_X},{GOAL_Y}) face {GOAL_ANG}; {len(dist)} walkable cells, longest path {max(dist.values())}, start->goal {dist[START_IDX]} steps, {len(DOOR_TILES)} doors"

# "terminator vision": the palette as a red monochrome luminance ramp
RED_RAMP = [(0, 0, 0), (85, 0, 0), (170, 0, 0), (255, 85, 85)]
def red_of(c):
    lum = ((0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2]) / 255.0) ** 0.6
    return gime(RED_RAMP[min(3, int(lum * 3.3))])

# ---- figure projection tables (indexed by forward distance in 1/16 cell) ----
shh = bytes(76 if f < 4 else max(1, min(76, int(round(KH / 2 / (f / 16.0))))) for f in range(256))
zq = bytes([0] + [wall_class(2 * hv) * 3 for hv in range(1, HALF + 1)])      # canvas height -> wall class code
kq = bytes(0 if f < 4 else max(0, min(255, int(round(PROJ_K * 16.0 / f)))) for f in range(256))
sstep = b"".join(((int(round(16 * 256.0 / w)) if w else 0) & 0xFFFF).to_bytes(2, "big") for w in range(48))

# ---- objects: monsters first, then the still ones sorted by row (the engine scans only the rows near the player)
OBJ_BASE, ZBUF_BASE, SSTEP_BASE, SPRT_TBL = 0x1900, 0x1900 + 136 * 8, 0x1900 + 136 * 8 + 80, 0x1800
objs, blockmap = [], bytearray(512)
for kind, typ, fx, fy in objs_src:
    x, y = int(fx), int(fy)
    if not (0 < x < 63 and 0 < y < 63) or mapb[y * 64 + x]:
        continue                                                # things the lattice put inside rock
    xf, yf = int((fx - x) * 256) & 255, int((fy - y) * 256) & 255
    if kind == 3:
        mt = MONSTER_TYPES.index(MONSTER_OF[typ])
        objs.append((3, G_STAND + G_FRAMES * mt, x, xf, y, yf, min(255, MONSTER_HP[MONSTER_OF[typ]]), 0))
    elif kind == 2:
        objs.append((2, PICKUP_OF[typ][0], x, 0x80, y, 0x80, 0, PICKUP_OF[typ][0]))
    elif decor_id.get(typ) is not None:
        objs.append((1, decor_id[typ], x, xf, y, yf, 0, decor_id[typ]))
        if DECOR_OF[typ][1]:
            i = y * 64 + x; blockmap[i >> 3] |= 1 << (i & 7)
NOBJ_MAX = 136
objs.sort(key=lambda o: (o[0] != 3, o[0] == 1, o[4], o[2]))     # monsters, pickups, then decor
while len(objs) > NOBJ_MAX:                                       # too many: drop decor that does not block first
    drop = next((i for i in range(len(objs) - 1, -1, -1) if objs[i][0] == 1 and not (blockmap[(objs[i][4] * 64 + objs[i][2]) >> 3] >> ((objs[i][4] * 64 + objs[i][2]) & 7) & 1)), len(objs) - 1)
    objs.pop(drop)
objs.sort(key=lambda o: (o[0] != 3, o[1] if o[0] == 3 else 0, o[4], o[2]))   # monsters by type, the rest by row
NMONSTER = sum(1 for o in objs if o[0] == 3)
def type_start(mt):
    return OBJ_BASE + 8 * next((i for i, o in enumerate(objs) if o[0] != 3 or o[1] >= G_STAND + G_FRAMES * mt), NMONSTER)
ystart = b"".join(((8 * next((i for i, o in enumerate(objs) if i >= NMONSTER and o[4] >= y), len(objs))) & 0xFFFF).to_bytes(2, "big") for y in range(65))
objinit = b"".join(bytes(o) for o in objs) + bytes((NOBJ_MAX - len(objs)) * 8)
assert SSTEP_BASE + 96 <= 0x1E00

# ----------------------------------------------------------------------------
# ray records (angle 0 = east, +angle = clockwise on a y-down map)
# ----------------------------------------------------------------------------
def ray_record(n):
    a = 2 * math.pi * n / ANGLES
    dx = int(round(math.cos(a) * 256)); dy = int(round(math.sin(a) * 256))
    def delta(d): return 0xFFFF if d == 0 else min(0xFFFF, int(round(65536.0 / abs(d))))
    return [dx & 0xFFFF, dy & 0xFFFF, delta(dx), delta(dy)]

def make_layout(widths):
    """rays = vertical strips of the given byte widths, left to right (80 bytes total)"""
    assert sum(widths) == 80
    recs, col = [], 0
    for w in widths:
        center = col + w / 2.0
        off = int(round(math.atan((center - 40.0) / PROJ_K) * ANGLES / (2 * math.pi)))   # planar projection
        cls = min(NCLS - 1, int(abs(center - 40.0) / 40.0 * NCLS))
        recs.append((off, cls, col, w))
        col += w
    return recs

LAYOUTS = {
    "STILL": make_layout([1] * 80),                       # 80 rays x 2 px  (refined when standing still)
    "M0":    make_layout([2] * 40),                       # 40 rays x 4 px  (moving)
    "M1":    make_layout([4] * 4 + [2] * 24 + [4] * 4),   # foveated: fine centre, coarse periphery
    "M2":    make_layout([4] * 20),                       # 20 rays x 8 px  (adaptive fallback)
}
cos_by_cls = [[] for _ in range(NCLS)]
for lay in LAYOUTS.values():
    for off, cls, col, w in lay:
        cos_by_cls[cls].append(math.cos(2 * math.pi * off / ANGLES))
cosv = [sum(c) / len(c) if c else 1.0 for c in cos_by_cls]

RCP_BASE = 0xF000
RB1_TBL, RB2_TBL, RB4_TBL = 0x1500, 0x1600, 0x1700
recip = bytearray()
for k in range(NCLS):
    for i in range(512):
        t = (i + 0.5) / 64.0 if i < 256 else 4.0 + (i - 256 + 0.5) / 4.0
        perp = max(t * cosv[k], 0.05)
        recip.append(wall_class(KH / perp) * 3)
fade = bytearray(256)
for e in range(1, NCLASS + 1):
    fade[e * 3] = (2 * int(round(fade_bands(class_height(e))))) & 0xFF

TBL_OF_W = {1: RB1_TBL, 2: RB2_TBL, 4: RB4_TBL}
def cfg_bytes(layout):
    b = bytearray()
    for off, cls, col, w in layout:
        b += bytes([off & 0xFF, (RCP_BASE >> 8) + cls * 2, col, TBL_OF_W[w] >> 8])
    return b
cfgs = {k: cfg_bytes(v) for k, v in LAYOUTS.items()}

floorband = bytearray(plane_ramp)                               # ceiling rows, then floor rows (the forge reads it)

def blast_order(blob):
    """PULS A,B,X,Y + PSHU A,B,X,Y reverses 6-byte groups: store them reversed so the blast restores true order"""
    assert len(blob) % 6 == 0, len(blob)
    g = [blob[i:i + 6] for i in range(0, len(blob), 6)]
    return b"".join(reversed(g))

# ----------------------------------------------------------------------------
# the gauge: DOOM's status bar.  Everything is composed in DOOM's 320 x 32 bar space, then halved across.
# ----------------------------------------------------------------------------
def gfx(name):
    return wad.load_png(os.path.join(wad.FREEDOOM, "graphics", name.lower() + ".png"))
def gfx_offsets(name):
    for ln in wad._cpp(os.path.join(wad.FREEDOOM, "buildcfg.txt"), "PHASE1").splitlines():
        f = ln.split(";")[0].split()
        if f and f[0].upper() == name.upper():
            return (int(f[1]), int(f[2])) if len(f) >= 3 else (0, 0)
    return (0, 0)
_, _, BAR = gfx("STBAR")
def stamp(dst, name, x, y, use_offsets=True):
    w, h, rows = gfx(name)
    xo, yo = gfx_offsets(name) if use_offsets else (0, 0)
    for yy in range(h):
        for xx in range(w):
            if rows[yy][xx] is not None and 0 <= y - yo + yy < len(dst) and 0 <= x - xo + xx < len(dst[0]):
                dst[y - yo + yy][x - xo + xx] = rows[yy][xx]
bar = [r[:] for r in BAR]
stamp(bar, "STARMS", 104, 0)
stamp(bar, "STTPRCNT", 90, 3)
stamp(bar, "STTPRCNT", 221, 3)
stamp(bar, "STTNUM0", 221 - 13, 3)                              # armour: none in this engine, so DOOM's start value
for i in range(6):                                              # weapon numbers 2..7, all grey
    stamp(bar, f"STGNUM{i + 2}", 111 + (i % 3) * 12, 4 + (i // 3) * 10)
def halve(rows, x0, x1, y0, y1):
    """bar region -> CoCo pixels (two DOOM pixels across become one), DOOM indices"""
    out = []
    for y in range(y0, y1):
        r = []
        for x in range(x0, x1, 2):
            v = [c for c in (rows[y][x], rows[y][x + 1]) if c is not None]
            if not v: r.append(0); continue
            c = palette.unlin(palette.lin(pal_doom[v]).mean(axis=0))
            r.append(dither.snap_index(tuple(int(round(t)) for t in c)))
        out.append(r)
    return out
def to_bytes(px, phase_by_row=True, band=0):
    """CoCo pixels (DOOM indices) -> packed bytes, the 2x2 Bayer phase following the screen row"""
    return bytes(HI[band][(y & 1) if phase_by_row else 0][px[y][2 * x]] | LO[band][(y & 1) if phase_by_row else 0][px[y][2 * x + 1]]
                 for y in range(len(px)) for x in range(len(px[0]) // 2))
frame = [[0] * 320 for _ in range(8)]                           # the 8 rows above the bar: DOOM's dark view border
_, _, BRD = wad.load_png(os.path.join(wad.FREEDOOM, "flats", "flat5_1.png")) if os.path.exists(os.path.join(wad.FREEDOOM, "flats", "flat5_1.png")) else (0, 0, None)
for y in range(8):
    for x in range(320):
        frame[y][x] = (wad.colormap()[20][BRD[y % 64][x % 64]] if BRD else 0)
hud_px = halve(frame + bar, 0, 320, 0, 40)
hud_status = to_bytes(hud_px)                                  # 80 x 40 = 3200
assert len(hud_status) == 3200

HUD_ROW = 3                                                     # digits: bar row of their top
DIG_X = {"ammo": (5, 18, 31), "health": (51, 64, 77)}           # DOOM x of each digit (right-aligned at 44 and 90)
def glyph(name):
    """a big digit composed on the bar's own background (at the ammo box) -> 3 bytes x 16 rows"""
    region = [r[:] for r in bar]
    for y in range(HUD_ROW, HUD_ROW + 16):
        for x in range(4, 18):
            region[y][x] = bar[HUD_ROW + 8][2]                  # the empty number box colour
    if name:
        stamp(region, name, 5, HUD_ROW, use_offsets=False)
    return to_bytes(halve(region, 4, 16, HUD_ROW, HUD_ROW + 16))
hud_digits = b"".join(glyph(f"STTNUM{d}") for d in range(10)) + glyph(None)   # 11 x 48
FACES = ["STFST00", "STFST10", "STFST20", "STFST30", "STFST40", "STFEVL0", "STFOUCH0", "STFDEAD0"]
def face(name):
    region = [r[:] for r in bar]
    stamp(region, name, 143, 0)
    return to_bytes(halve(region, 144, 168, 0, 32))
hud_faces = b"".join(face(f) for f in FACES)                   # 8 x (6 x 32)
def arms(owned):
    region = [r[:] for r in bar]
    for i in range(owned):
        stamp(region, f"STYSNUM{i + 2}", 111 + (i % 3) * 12, 4 + (i // 3) * 10)
    return to_bytes(halve(region, 104, 144, 0, 32))
hud_arms = b"".join(arms(g) for g in range(4))                 # best weapon 0..3 -> 4 x (10 x 32)
def keyicon(name, y):
    region = [r[:] for r in bar]
    stamp(region, name, 239, y)
    return to_bytes(halve(region, 236, 248, y, y + 5))
hud_keys = keyicon("STKEYS0", 3) + keyicon("STKEYS2", 23)      # 2 x (3 x 5)

# ----------------------------------------------------------------------------
# previews: what the CoCo will really show
# ----------------------------------------------------------------------------
def preview():
    from PIL import Image
    def bytes_img(b, wbytes, rows, scale=(3, 2)):
        im = Image.new("RGB", (wbytes * 2, rows)); px = im.load()
        for y in range(rows):
            for x in range(wbytes):
                v = b[y * wbytes + x]
                px[2 * x, y] = PAL[v >> 4]; px[2 * x + 1, y] = PAL[v & 15]
        return im.resize((im.width * scale[0], im.height * scale[1]), Image.NEAREST)
    def col_img(b, scale=(3, 2)):                               # a 16 x 32 column-major block
        rm = bytes(b[c * 32 + r] for r in range(32) for c in range(16))
        return bytes_img(rm, 16, 32, scale)
    sheet = Image.new("RGB", (NTEX * 100, 2 * 66 + 4), (30, 30, 30))
    for t in range(NTEX):
        sheet.paste(col_img(tex_lit[t * 512:(t + 1) * 512]), (t * 100, 0))
        sheet.paste(col_img(tex_sh[t * 512:(t + 1) * 512]), (t * 100, 68))
    sheet.save(os.path.join(SHEETS, "walls_engine.png"))
    fig = Image.new("RGB", (16 * 100, ((NSPR + 15) // 16) * 66), (60, 0, 60))
    for s in range(NSPR):
        fig.paste(col_img(spr_bytes[s * 512:(s + 1) * 512]), ((s % 16) * 100, (s // 16) * 66))
    fig.save(os.path.join(SHEETS, "figures_engine.png"))
    hud = Image.new("RGB", (480, 300), (30, 30, 30))
    hud.paste(bytes_img(hud_status, 80, 40), (0, 0))
    for d in range(11): hud.paste(bytes_img(hud_digits[d * 48:(d + 1) * 48], 3, 16), (d * 24, 90))
    for f in range(8): hud.paste(bytes_img(hud_faces[f * 192:(f + 1) * 192], 6, 32), (f * 40, 130))
    for a in range(4): hud.paste(bytes_img(hud_arms[a * 320:(a + 1) * 320], 10, 32), (a * 64, 200))
    hud.save(os.path.join(SHEETS, "gauge_engine.png"))
    mp = Image.new("RGB", (64, 64)); px = mp.load()
    for i in range(4096):
        v = mapb[i]
        px[i % 64, i // 64] = (0, 0, 0) if v == 0 else (200, 60, 60) if v in (DOORC, DOOR2C) else \
            (60, 220, 60) if v == 0x80 + SWITCH_TEX * 2 else PAL[(tex_lit[((v - 0x80) // 2) * 512 + 16 * 32 // 2]) >> 4]
    for o in objs:
        px[o[2], o[4]] = (255, 255, 0) if o[0] == 3 else (0, 200, 255) if o[0] == 2 else (120, 120, 120)
    px[START_X, START_Y] = (255, 255, 255)
    mp.resize((512, 512), Image.NEAREST).save(os.path.join(SHEETS, "map.png"))

# ----------------------------------------------------------------------------
# emit.   Two things reach the CoCo:
#   DOOM.BIN  (LOADM) - code + a few small boot tables.  LOADM can only place data safely in $2000-$7BFF
#             on this DOS (a bigger load at $8000+ crashes BASIC), so it carries no bulk data.
#   DOOM.DAT  - the bulk data as 8 KB page images, read by the boot code sector by sector with Disk BASIC's own
#             DSKCON straight into their physical pages.
# ----------------------------------------------------------------------------
def fcb(label, data, per=16):
    s = (label + "\n") if label else ""
    for i in range(0, len(data), per):
        s += "        fcb     " + ",".join(str(b) for b in data[i:i + per]) + "\n"
    return s

def fdb(label, words, per=8):
    s = (label + "\n") if label else ""
    for i in range(0, len(words), per):
        s += "        fdb     " + ",".join(str(w & 0xFFFF) for w in words[i:i + per]) + "\n"
    return s

# ray generation seeds: quarter-wave cosine (129 words) + reciprocal 65536/v (257 words)
costab = [int(round(256 * math.cos(2 * math.pi * i / ANGLES))) for i in range(ANGLES // 4 + 1)]
rcp256 = [0xFFFF] + [min(0xFFFF, int(round(65536.0 / v))) for v in range(1, 257)]
def cosq(n):
    n %= ANGLES
    if n <= 128: return costab[n]
    if n <= 256: return -costab[256 - n]
    if n <= 384: return -costab[n - 256]
    return costab[512 - n]
for n in range(ANGLES):                      # the boot-time construction must reproduce the reference exactly
    dx, dy = cosq(n), cosq(n - 128)
    ref = ray_record(n)
    assert [dx & 0xFFFF, dy & 0xFFFF] == ref[:2], (n, dx, dy, ref)
    assert rcp256[abs(dx)] == ref[2] and rcp256[abs(dy)] == ref[3], n

CFG_BASE = 0x1200
cfg_addr, cfgblk = {}, b""
for k in ("STILL", "M0", "M1", "M2"):
    cfg_addr[k] = CFG_BASE + len(cfgblk)
    cfgblk += cfgs[k]
FLOORBAND = CFG_BASE + len(cfgblk)
cfgblk += bytes(floorband)
CFG_LEN = len(cfgblk)
assert FLOORBAND + HALF <= RB1_TBL, (hex(FLOORBAND), RB1_TBL)
RAYS = 0x0200
assert RAYS + ANGLES * 8 <= CFG_BASE

# benchmark camera spots: mean DDA steps over 64 rays for every open cell, then the 5/50/90/99th percentile
def dda_steps(px, py, ang):
    dx, dy = math.cos(ang), math.sin(ang)
    mx, my = int(px), int(py)
    ddx = abs(1 / dx) if dx else 1e30; ddy = abs(1 / dy) if dy else 1e30
    sx, sdx = (-1, (px - mx) * ddx) if dx < 0 else (1, (mx + 1 - px) * ddx)
    sy, sdy = (-1, (py - my) * ddy) if dy < 0 else (1, (my + 1 - py) * ddy)
    n = 0
    while True:
        if sdx < sdy: sdx += ddx; mx += sx
        else: sdy += ddy; my += sy
        n += 1
        if mapb[my * 64 + mx]: return n
open_cells = [(x, y) for y in range(64) for x in range(64) if mapb[y * 64 + x] == 0 and 0 < x < 63 and 0 < y < 63]
score = sorted(((sum(dda_steps(x + .5, y + .5, 2 * math.pi * k / 64) for k in range(64)) / 64.0), x, y) for x, y in open_cells)
bench_spots = bytes(b for q in (0.05, 0.5, 0.9, 0.995) for b in score[int(q * (len(score) - 1))][1:])
BENCH_INFO = [(round(score[int(q * (len(score) - 1))][0], 1), score[int(q * (len(score) - 1))][1:]) for q in (0.05, 0.5, 0.9, 0.995)]

pal_bytes = bytes(gime(c) for c in PAL)
STATUS_BLK = blast_order(hud_status + bytes(4))
hud_raw = STATUS_BLK + hud_digits + hud_faces + hud_arms + hud_keys
HUD_LEN = len(hud_raw)
HUD_STATUS_LEN = len(STATUS_BLK)
assert HUD_LEN <= 8192

SEC = 256
def sectors(b): return (len(b) + SEC - 1) // SEC
CODE2_RESERVE = 8192

# ---- light tables (L2), stored index ^ $80 so the 6809's signed LDA A,Y reaches all 256 from the middle ----
def flipped(t): return bytes(t[k ^ 0x80] for k in range(256))
# The tables are read through W7 at boot, and the GIME shows its constant page and I/O at $FE00-$FFFF whatever
# page is mapped: nothing may sit in the last 512 bytes of a table page.  LTA holds bands 0-6 (HI at +$0000,
# LO at +$1000), the light page LTB the last band beside the lattice light, the fade and the figure tables.
FADE_OFF, SHI_OFF, SLO_OFF, B7_OFF = 0x1000, 0x1100, 0x1300, 0x1500
lt_a, lt_b = bytearray(8192), bytearray(8192)
wall_tbl = {}                                                    # (band, phase) -> (page name, HI offset, LO offset)
for band in range(NBANDS):
    for ph in (0, 1):
        if band < NBANDS - 1:
            o = (2 * band + ph) * 256
            wall_tbl[band, ph] = ("LTA", o, 0x1000 + o)
        else:
            wall_tbl[band, ph] = ("LTB", B7_OFF + ph * 256, B7_OFF + 0x200 + ph * 256)
        name, hi, lo = wall_tbl[band, ph]
        t = lt_a if name == "LTA" else lt_b
        t[hi:hi + 256] = flipped(HI[band][ph]); t[lo:lo + 256] = flipped(LO[band][ph])
lt_b[0:4096] = lightmap
lt_b[FADE_OFF:FADE_OFF + 256] = fade
for ph in (0, 1):
    lt_b[SHI_OFF + ph * 256:SHI_OFF + ph * 256 + 256] = flipped(SHI[ph])
    lt_b[SLO_OFF + ph * 256:SLO_OFF + ph * 256 + 256] = flipped(SLO[ph])
assert not any(lt_a[0x1E00:]) and not any(lt_b[0x1E00:])

# ---- index texels, column-major, lossy-RLE'd per group ----
RLE_TAU = float(os.environ.get("DOOM_RLE_TAU", "120"))           # perceptual merge threshold (palette.dist2 units)
_pd = palette.dist2(pal_doom[:, None, :], pal_doom[None, :, :])
def colmajor(texels): return bytes(texels[r][x] or 0 for x in range(32) for r in range(32))
def colmajor_t(texels): return bytes(texels[r][x] for x in range(32) for r in range(32))
wall_raw = b"".join(colmajor(t) for t in tex_texels)
wall_lossy = rle.lossy(wall_raw, 32, lambda a, b: _pd[a, b], RLE_TAU)
groups = [("walls", wall_lossy + shh + kq, [(0xA0 + 2 * band + ph, wall_tbl[band, ph][0], 0xE000 + wall_tbl[band, ph][1] + 128,
                                             0xE000 + wall_tbl[band, ph][2] + 128, NTEX, 1)
                                            for band in range(NBANDS) for ph in (0, 1)])]
TEXPG0, SPR_PAGE0, STAGE_PG = 0xA0, 0xB0, 0xBE
spr_lossy = []
for g in range((NSPR + 15) // 16):
    ids = range(16 * g, min(NSPR, 16 * g + 16))
    raw = b"".join(colmajor_t(spr_texels[i]) for i in ids)
    lz = rle.lossy(raw, 32, lambda a, b: _pd[a, b], RLE_TAU, keep=(TRANSPARENT,))
    spr_lossy.append(lz)
    groups.append((f"figures{g}", lz, [(SPR_PAGE0 + 2 * g + ph, "LTB", 0xE000 + SHI_OFF + ph * 256 + 128,
                                         0xE000 + SLO_OFF + ph * 256 + 128, len(ids), 0) for ph in (0, 1)]))
assert SPR_PAGE0 + 2 * len(groups[1:]) <= STAGE_PG
stream, starts = bytearray(), []
for name, data, _ in groups:
    starts.append(len(stream))
    packed = rle.pack(data)
    assert rle.unpack(packed, len(data)) == data
    stream += packed
raw_total = len(wall_raw) + 512 + sum(1024 * min(16, NSPR - 16 * g) for g in range(len(groups) - 1))
RLE_INFO = f"{raw_total} B of index texels -> {len(stream)} B ({100 * len(stream) / raw_total:.0f}%, merge threshold {RLE_TAU:g})"
# the pictures the boot forge will make (the Python twin; previews and tests read these)
spr_texels_lossy = []
for g, lz in enumerate(spr_lossy):
    for i in range(len(lz) // 1024):
        cm = lz[i * 1024:(i + 1) * 1024]
        spr_texels_lossy.append([[cm[x * 32 + r] for x in range(32)] for r in range(32)])
tex_texels_lossy = [[[wall_lossy[t * 1024 + x * 32 + r] for x in range(32)] for r in range(32)] for t in range(NTEX)]
def forged_wall(band, ph): return page_of(tex_texels_lossy, HI[band][ph], LO[band][ph]) + shh + kq
def forged_figures(g, ph): return page_of(spr_texels_lossy[16 * g:16 * g + 16], SHI[ph], SLO[ph])
tex_lit, tex_sh = forged_wall(3, 0)[:TEX_LEN], forged_wall(4, 1)[:TEX_LEN]
spr_bytes = b"".join(forged_figures(g, 0) for g in range(len(groups) - 1))

PAGES = [("MAP", bytes(mapb) + bytes(recip) + bytes(blockmap)),
         ("HUD", hud_raw),
         ("CODE2", bytes(CODE2_RESERVE)),
         ("LTA", bytes(lt_a)),
         ("LTB", bytes(lt_b))] + \
        [(f"RLE{i}", bytes(stream[i * 8192:(i + 1) * 8192])) for i in range((len(stream) + 8191) // 8192)]
PAGE0 = 0x41
page_no = {name: PAGE0 + i for i, (name, _) in enumerate(PAGES)}
assert PAGE0 + len(PAGES) <= 0x4E, "the DAT pages run into the autopilot's page ($4E)"
pg_jobs = bytearray()
for (name, data, targets), st in zip(groups, starts):
    pg_jobs += bytes([page_no["RLE0"] + st // 8192]) + struct.pack(">HH", 0x8000 + st % 8192, len(data)) + bytes([len(targets)])
    for dest, tbl, hi, lo, units, extra in targets:
        pg_jobs += bytes([dest, page_no[tbl]]) + struct.pack(">HH", hi, lo) + bytes([units, extra])
pg_jobs += bytes([0])
preview()
# the twin of every page the boot forge makes, in physical page order $A0.. (test/run_tests.sh compares them)
forged = {}
for band in range(NBANDS):
    for ph in (0, 1):
        forged[TEXPG0 + 2 * band + ph] = forged_wall(band, ph)
for g in range(len(groups) - 1):
    for ph in (0, 1):
        forged[SPR_PAGE0 + 2 * g + ph] = forged_figures(g, ph)
with open(os.path.join(OUT, "forged.txt"), "w") as f:
    for pg in sorted(forged):
        f.write(f"{pg:02X} {len(forged[pg])}\n")
os.makedirs(os.path.join(OUT, "forged"), exist_ok=True)
for pg, data in forged.items():
    open(os.path.join(OUT, "forged", f"{pg:02X}.bin"), "wb").write(data)
SND_PAGE0 = 0xC0
snd_list = sounds.build()
snd_pages, snd_rows = sounds.pack(snd_list, SND_PAGE0)
for i, data in enumerate(snd_pages):
    if data:
        PAGES.append((f"SND{i}", data))
        page_no[f"SND{i}"] = SND_PAGE0 + i
snd_synth = b""
for (name, data, steps), (pg, addr, ln) in zip(snd_list, snd_rows):
    if steps is not None:
        snd_synth += bytes([pg]) + struct.pack(">HB", addr, len(steps)) + b"".join(struct.pack(">H", st) for st in steps)
snd_synth += bytes([0])
assert len(mapb) + len(recip) + len(blockmap) <= 8192 - 512 and RCP_BASE - 0xE000 == len(mapb)
nsec = sum(sectors(data) for _, data in PAGES)
os.makedirs(os.path.join(OUT, "parts"), exist_ok=True)
for name, data in PAGES:
    open(os.path.join(OUT, "parts", name + ".bin"), "wb").write(data)
open(os.path.join(OUT, "dat_layout.txt"), "w").write("\n".join(f"{name} {sectors(data)}" for name, data in PAGES) + "\n")
ngran = (nsec + 8) // 9
dat_grans = mkdsk.ORDER[:ngran]

with open(os.path.join(OUT, "equ.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    vals = [("VIEW_H", VIEW_H), ("HALF", HALF), ("HUD_TOP", HUD_TOP), ("HUD_H", HUD_H), ("BAR_TOP", BAR_TOP), ("STRIDE", STRIDE),
            ("ANGLES", ANGLES), ("RAYS", RAYS), ("CFG_STILL", cfg_addr["STILL"]), ("CFG_M0", cfg_addr["M0"]),
            ("CFG_M1", cfg_addr["M1"]), ("CFG_M2", cfg_addr["M2"]), ("CFG_BASE", CFG_BASE),
            ("FLOORBAND", FLOORBAND), ("CFG_LEN", CFG_LEN),
            ("NRAYS_STILL", len(LAYOUTS["STILL"])), ("NRAYS_M0", len(LAYOUTS["M0"])),
            ("NRAYS_M1", len(LAYOUTS["M1"])), ("NRAYS_M2", len(LAYOUTS["M2"])),
            ("RCP_BASE", RCP_BASE), ("RCP_LEN", len(recip)), ("MAP_LEN", len(mapb)), ("TEX_LEN", TEX_LEN),
            ("RB1_TBL", RB1_TBL), ("RB2_TBL", RB2_TBL), ("RB4_TBL", RB4_TBL), ("NTEX", NTEX),
            ("DOOR_CODE", DOORC), ("DOOR2_CODE", DOOR2C), ("SWITCH_CODE", 0x80 + SWITCH_TEX * 2),
            ("START_X", START_X), ("START_Y", START_Y), ("START_ANG", START_ANG),
            ("GOAL_X", GOAL_X), ("GOAL_Y", GOAL_Y), ("GOAL_ANG", GOAL_ANG), ("NDOORS", len(DOOR_TILES)),
            ("SPR_PAGE0", SPR_PAGE0), ("NSPR", NSPR), ("NOBJ", NOBJ_MAX), ("OBJ", OBJ_BASE), ("ZBUF", ZBUF_BASE),
            ("SSTEP", SSTEP_BASE), ("YSTART", 0x1F00), ("NMONSTER", NMONSTER),
            ("RQ1_TBL", 0x7D00), ("RQ2_TBL", 0x7E00), ("RQ4_TBL", 0x7F00), ("TQOFF", 0x68),
            ("TEXPG0", TEXPG0), ("LIGHT_PAGE", page_no["LTB"]), ("NBANDS", NBANDS), ("NCLASS", NCLASS),
            ("REFLECT", int(os.environ.get("DOOM_REFLECT", "1"))), ("STAGE_PG", STAGE_PG), ("FADE_TBL", 0xA000 + FADE_OFF), ("WEAP_BASE", WEAP_BASE), ("G_FRAMES", G_FRAMES),
            ("G_TYPE1", type_start(1)), ("G_TYPE2", type_start(2)), ("G_TYPE3", type_start(3)),
            ("SPRT_TBL", SPRT_TBL), ("SHH_TBL", 0x8000 + TEX_LEN), ("KQ_TBL", 0x8000 + TEX_LEN + 256), ("BLOCKMAP", 0xFC00),
            ("G_STAND", G_STAND), ("G_WALK", G_WALK), ("G_SHOOT", G_SHOOT), ("G_PAIN", G_PAIN), ("G_DIE", G_DIE), ("G_DEAD", G_DEAD),
            ("MAP_PAGE", page_no["MAP"]), ("HUD_PAGE", page_no["HUD"]), ("CODE2_PAGE", page_no["CODE2"]),
            ("DAT_SECTORS", nsec),
            ("HUD_LEN", HUD_LEN), ("HUD_STATUS", 0), ("HUD_STATUS_LEN", HUD_STATUS_LEN), ("HUD_DIGITS", HUD_STATUS_LEN),
            ("HUD_FACES", HUD_STATUS_LEN + len(hud_digits)), ("HUD_ARMS", HUD_STATUS_LEN + len(hud_digits) + len(hud_faces)),
            ("HUD_KEYS", HUD_STATUS_LEN + len(hud_digits) + len(hud_faces) + len(hud_arms)),
            ("HUD_AMMO_AT", (BAR_TOP + HUD_ROW) * STRIDE + 1), ("HUD_HEALTH_AT", (BAR_TOP + HUD_ROW) * STRIDE + 13),
            ("HUD_FACE_AT", BAR_TOP * STRIDE + 36), ("HUD_ARMS_AT", BAR_TOP * STRIDE + 26),
            ("HUD_KEY0_AT", (BAR_TOP + 3) * STRIDE + 59), ("HUD_KEY1_AT", (BAR_TOP + 23) * STRIDE + 59),
            ("CEIL_BYTE", CEIL_IX * 0x11), ("FLOOR1_BYTE", FLOOR1_IX * 0x11), ("FLOOR2_BYTE", FLOOR2_IX * 0x11),
            ("SND_LINES", sounds.SND_LINES), ("SND_SILENCE", sounds.SILENCE),
            ("SYN_WHOLE", sounds.TICK_8_8 >> 8), ("SYN_FRAC", sounds.TICK_8_8 & 255)] \
           + [(name, i + 1) for i, (name, _, _) in enumerate(snd_list)]
    for k, v in vals: f.write(f"{k:<16}equ     {v}\n")

with open(os.path.join(OUT, "pal.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fcb("palette_data", pal_bytes))
    f.write(fcb("zq_tbl", zq))
    f.write(fcb("COLMASK", colmask))                            # per figure: which of its 16 byte-columns have ink
    f.write(fcb("bench_spots", bench_spots))

with open(os.path.join(OUT, "snd.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write("snd_tbl\n")
    for (name, _, _), (pg, addr, ln) in zip(snd_list, snd_rows):
        f.write(f"            fcb     ${pg:02X}\n            fdb     ${addr:04X},{ln:<5}   ; {name}\n")

with open(os.path.join(OUT, "tables2.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fcb("pal_norm", pal_bytes))
    f.write(fcb("pal_red", bytes(red_of(c) for c in PAL)))
    f.write(fdb("door_list", DOOR_TILES))
    f.write(fcb("door_kind", bytes(DOOR_KIND)))

# ----------------------------------------------------------------------------
# cover page (drawn by the boot code while the disk loads): diagonal rainbow, black plate, 3 lines of text
# ----------------------------------------------------------------------------
import colorsys
def gime6(r, g, b):
    return ((r >> 1) << 5) | ((g >> 1) << 4) | ((b >> 1) << 3) | ((r & 1) << 2) | ((g & 1) << 1) | (b & 1)
cover_hues = []
for i in range(14):
    r, g, b = colorsys.hsv_to_rgb(0.83 * i / 13.0, 1.0, 1.0)
    cover_hues.append(gime6(round(r * 3), round(g * 3), round(b * 3)))
cover_pal = bytes(cover_hues + [0x00, 0x3F])
from PIL import Image as _I, ImageDraw as _D, ImageFont as _F
COVER_LINES = ["FREEDOOM", "TRS-80 COCO 3 - 2MB", f"LOADING {MAPNAME.upper()}"]
_font = _F.load_default(size=10)
cover_txt = bytearray()
for _t in COVER_LINES:
    _img = _I.new("L", (160, 8), 0)
    _d = _D.Draw(_img)
    _w = _d.textlength(_t, font=_font)
    _d.text((int((160 - _w) / 2), -2), _t, font=_font, fill=255)
    for _y in range(8):
        for _bx in range(20):
            v = 0
            for _k in range(8):
                v = (v << 1) | (1 if _img.getpixel((_bx * 8 + _k, _y)) > 110 else 0)
            cover_txt.append(v)

with open(os.path.join(OUT, "stage.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fdb("costab", costab))
    f.write(fdb("rcp256", rcp256))
    f.write(fcb("cfgblk", cfgblk))
    f.write(fcb("objinit", objinit))
    f.write(fcb("sstep_tbl", sstep))
    f.write(fcb("cover_pal", cover_pal))
    f.write(fcb("cover_txt", bytes(cover_txt)))
    f.write(fcb("ystart_tbl", ystart))
    f.write(fcb("snd_synth", snd_synth))
    f.write(fcb("syn_levels", bytes(sounds.SYN_LEVELS)))
    f.write(fcb("wall_cls", bytes(v for c in WALL_CLS for v in c)))
    f.write(fcb("pg_jobs", bytes(pg_jobs)))
    f.write(fcb("dat_grans", bytes(dat_grans)))
    pg = b""
    for name, data in PAGES:
        pg += bytes([page_no[name], sectors(data)])
    f.write(fcb("dat_pages", pg + bytes([0])))

print(f"  palette: " + " ".join(f"${gime(c):02X}" for c in PAL) + f"  (error {pal_cost:.0f} with blends, {pal_plain:.0f} without)")
print(f"  map {lev.name}: start ({START_X},{START_Y}) facing {START_ANG}; walls {', '.join(wall_names)}; switch {switch_name}; doors {', '.join(door_names)}")
print(f"  sounds: {len(snd_list)} in {len(snd_pages)} pages, {sounds.FS:.0f} Hz: {sum(len(d) for d in snd_pages)} B stored")
print("  ai:", AI_INFO)
print(f"  figures: {NSPR} ({len(spr_bytes)} B); objects: {len(objs)} ({NMONSTER} monsters, {sum(1 for o in objs if o[0]==2)} pickups, "
      f"{sum(1 for o in objs if o[0]==1)} decor)")
print("  bench spots (mean DDA steps, cell):", BENCH_INFO)
print(f"  planes: ceiling {CEIL_FLAT}, floor {FLOOR_FLAT} at sector light {BASE_LIGHT}; ramp " + " ".join(f"{b:02X}" for b in plane_ramp[::6]))
print(f"  walls: {NCLASS} column classes; light: {NBANDS} bands x 2 dither phases forged at boot")
print(f"  rle: {RLE_INFO}")
print(f"  DOOM.DAT {nsec} sectors in {ngran} granules")
