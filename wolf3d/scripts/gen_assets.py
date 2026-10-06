#!/usr/bin/env python3
"""
gen_assets.py - the build-time forge of ledgers and pictures.  It shapes either the user's original game files
(opened through wolfai.py) or original procedural stand-in art into the tables the 6809 will swallow at boot.
Invoked by build.sh.

Writes into the build directory:
  equ.inc      constants shared with wolf3d.asm
  tex.inc      16 x 16-row wall textures (lit + shaded), loaded straight into W4
  mapdat.inc   64x64 E1M1 map + distance->height tables, loaded straight into W7
  stage.inc    boot staging data (ray records, ray layouts, HUD art) - blasted into place at boot
  preview_*.png  what the CoCo will actually show (so the conversion can be checked by eye)

Nom Nom rules applied (NomNomGalaxy):
  I   Reciprocal cache : the 1/|dir| delta distances and distance->height are tables, never divided at runtime
  II  Shape of data    : one 8-byte record per angle; textures stored column-major, one 16-byte column per hit
  V   Identity         : ceiling/floor are baked into the compiled column routines (no clear pass)
  IX  LUT precompute   : everything below is computed once, here
  X   Perpendicular    : the *palette* is optimised for the whole game (walls+HUD+faces) at once
"""
import math, os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wolfai

OUT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "build"
STANDIN = "--standin" in sys.argv[1:]
os.makedirs(OUT, exist_ok=True)

# ----------------------------------------------------------------------------
# geometry / constants
# ----------------------------------------------------------------------------
SCR_W, SCR_H, STRIDE = 160, 192, 80
VIEW_H = 152                      # 3D view rows; HUD = 40 rows below
HUD_H = SCR_H - VIEW_H
HALF = VIEW_H // 2                # 76 half-rows (row-interlaced rendering)
ANGLES = 512                      # angle units per circle
FOV = 94                          # ~66 degrees
KH = 98.0                         # wall half-rows at 1 tile distance (D/2)
PROJ_K = 40.0 / math.tan(math.radians(33.05))   # screen bytes per unit of lateral/forward (planar projection)
NCLS = 6                          # fisheye cosine classes
TEXW, TEXH = 32, 32               # texture texels (32 wide = 16 byte-columns of 2 px; 32 rows)
HUD_TOP = VIEW_H

# ----------------------------------------------------------------------------
# colour science
# ----------------------------------------------------------------------------
LEVELS = (0, 85, 170, 255)
CANDS = [(r, g, b) for r in LEVELS for g in LEVELS for b in LEVELS]       # the GIME's 64 colours

def dist2(a, b):
    rm = (a[0] + b[0]) / 2.0
    dr, dg, db = a[0] - b[0], a[1] - b[1], a[2] - b[2]
    return (2 + rm / 256.0) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256.0) * db * db

def gime(c):
    r, g, b = (LEVELS.index(v) for v in c)
    return (((r >> 1) & 1) << 5) | (((g >> 1) & 1) << 4) | (((b >> 1) & 1) << 3) | ((r & 1) << 2) | ((g & 1) << 1) | (b & 1)

def choose_palette(hist, forced, n=16):
    """greedy facility-location (+ swap refinement) over the 64 GIME colours, numpy-vectorised"""
    import numpy as np
    cols = list(hist.keys()); w = np.array([hist[c] for c in cols], dtype=float)
    D = np.array([[dist2(c, q) for q in CANDS] for c in cols])          # pixels x 64
    sel = [CANDS.index(c) for c in forced]
    def cost(idx): return float((w * D[:, idx].min(axis=1)).sum())
    while len(sel) < n:
        m = D[:, sel].min(axis=1)
        gains = [(float((w * np.minimum(m, D[:, c])).sum()), c) for c in range(64) if c not in sel]
        sel.append(min(gains)[1])
    for _ in range(4):
        for i in range(len(forced), n):
            best = cost(sel)
            for c in range(64):
                if c in sel: continue
                t = sel[:i] + [c] + sel[i + 1:]
                cc = cost(t)
                if cc < best - 1e-9: sel, best = t, cc
    return [CANDS[i] for i in sel]

_ncache = {}
def nearest(c, pal):
    k = (c, tuple(pal))
    if k not in _ncache:
        _ncache[k] = min(range(len(pal)), key=lambda i: dist2(c, pal[i]))
    return _ncache[k]

# ----------------------------------------------------------------------------
# source art
# ----------------------------------------------------------------------------
if STANDIN:
    import standin_assets
    vga = standin_assets.PALETTE
    vs = standin_assets.VSwap()
    vg = standin_assets.VgaGraph()
else:
    vga = wolfai.load_palette()
    vs = wolfai.VSwap()
    vg = wolfai.VgaGraph()

# wall tile -> (lit chunk, shaded chunk); doors get their own textures
WALL_TILES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 21]
TEXTURES = [((t - 1) * 2, (t - 1) * 2 + 1) for t in WALL_TILES] + [(98, 99), (102, 103)]   # + door, elevator door
NTEX = len(TEXTURES)
DOOR_TEX, ELEV_TEX = 13, 14
TEX_OF_TILE = {t: i for i, t in enumerate(WALL_TILES)}
TEX_OF_TILE.update({90: DOOR_TEX, 91: DOOR_TEX, 92: DOOR_TEX, 93: DOOR_TEX, 94: DOOR_TEX, 95: DOOR_TEX, 100: ELEV_TEX, 101: ELEV_TEX})

def rgb(i): return vga[i]

def resample(rows, ow, oh, srcw=64, srch=64):
    """box-filter an indexed image (rows[y][x] -> palette idx) to ow x oh, returning RGB rows"""
    bx, by = srcw // ow, srch // oh
    out = []
    for y in range(oh):
        r = []
        for x in range(ow):
            acc = [0, 0, 0]; n = 0
            for yy in range(by):
                for xx in range(bx):
                    v = rows[y * by + yy][x * bx + xx]
                    if v is None: continue
                    c = rgb(v); acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; n += 1
            r.append(tuple(a // n for a in acc) if n else None)
        out.append(r)
    return out

tex_rgb = []                        # [tex][shade] -> rows[16][32] of rgb
for lit, dark in TEXTURES:
    tex_rgb.append([resample(vs.wall(lit), TEXW, TEXH), resample(vs.wall(dark), TEXW, TEXH)])

# HUD art
def pic_rgb(i, ow=None, oh=None):
    w, h, rows = vg.pic(i)
    return resample(rows, w // 2, h, srcw=w, srch=h)          # halve the width: our screen is 160 wide

status_rgb = pic_rgb(95)                                     # 160 x 40
digits_rgb = [pic_rgb(108 + d) for d in range(10)] + [pic_rgb(107)]   # 0..9, blank  (4 x 16)
keys_rgb = [pic_rgb(105), pic_rgb(106)]                          # gold, silver key (4 x 16)
FACE_IDS = [120, 123, 126, 129, 132, 135, 138, 141]         # one 'looking ahead' face per health band + dead
faces_rgb = [pic_rgb(i) for i in FACE_IDS]                  # 12 x 32
weap_rgb = [pic_rgb(100 + i) for i in range(4)]             # 24 x 24

# sprites: static objects SPR_STAT_n = chunk n+2 (ids 0..47) and the guard's front-facing frames (ids 48..60)
SPR_STATIC = list(range(2, 50))
SPR_GUARD = [50, 58, 66, 74, 82, 96, 97, 98, 90, 91, 92, 93, 95]      # stand, walk1-4, shoot1-3, pain, die1-3, dead
SPR_SRC = SPR_STATIC + SPR_GUARD
NSPR = len(SPR_SRC)
G_STAND, G_WALK, G_SHOOT, G_PAIN, G_DIE, G_DEAD = 48, 49, 53, 56, 57, 60

def sprite_cells(n):
    """64x64 sprite -> 32x32 grid of RGB (None = transparent): a 2x2 block is opaque if >= 2 of its pixels are"""
    rows = vs.sprite(n)
    cells = []
    for y in range(32):
        r = []
        for x in range(32):
            px = [rows[2 * y + j][2 * x + i] for j in (0, 1) for i in (0, 1)]
            op = [rgb(p) for p in px if p is not None]
            if len(op) >= 2:
                r.append(tuple(sum(c[k] for c in op) // len(op) for k in range(3)))
            else:
                r.append(None)
        cells.append(r)
    return cells
spr_cells = [sprite_cells(n) for n in SPR_SRC]

# first-person weapons: knife / pistol / machine gun / chain gun, a ready frame and an attack frame each (VSWAP sprites 416..435).
# The gun only occupies the bottom-centre of its 64x64 frame, so a 32x32 texel window (x 18..49, y 32..63) is taken at native
# resolution (no resampling); the engine draws it 38 half-rows tall, which is about the original's scale.
WEAP_SRC = [416, 418, 421, 423, 426, 428, 431, 433]
WEAP_BASE = len(spr_cells)
def weapon_cells(n, x0=18, y0=32, win=32):
    rows = vs.sprite(n)
    f = win / 32.0
    cells = []
    for cy in range(32):
        r = []
        for cx in range(32):
            sx0, sx1, sy0, sy1 = x0 + cx * f, x0 + (cx + 1) * f, y0 + cy * f, y0 + (cy + 1) * f
            acc = [0.0, 0.0, 0.0]; wsum = 0.0; opq = 0.0
            for y in range(int(sy0), int(math.ceil(sy1))):
                wy = min(sy1, y + 1) - max(sy0, y)
                for x in range(int(sx0), int(math.ceil(sx1))):
                    wx = min(sx1, x + 1) - max(sx0, x)
                    w = wx * wy; wsum += w
                    p = rows[y][x]
                    if p is None: continue
                    c = rgb(p); opq += w
                    acc[0] += c[0] * w; acc[1] += c[1] * w; acc[2] += c[2] * w
            r.append(tuple(int(a / opq) for a in acc) if opq >= 0.5 * wsum else None)
        cells.append(r)
    return cells
spr_cells += [weapon_cells(n) for n in WEAP_SRC]
NSPR = len(spr_cells)

# ceiling / floor from the game's own palette (E1M1: grey ceiling, dark floor)
CEIL = (85, 85, 85) if STANDIN else rgb(0x1D)
FLOOR1 = rgb(0x19)

def snap(c):                         # nearest GIME colour
    return min(CANDS, key=lambda q: dist2(c, q))

hist = {}
def add(rows, w):
    for r in rows:
        for c in r:
            if c is not None: hist[c] = hist.get(c, 0) + w
for t in tex_rgb:
    for s in t: add(s, 1.0)
add(status_rgb, 1.5)
for d in digits_rgb: add(d, 3.0)
for f in faces_rgb: add(f, 3.0)
for w in weap_rgb: add(w, 1.0)
for k in keys_rgb: add(k, 3.0)
for sc in spr_cells: add(sc, 2.0)      # (palette weights chosen by sweeping a perceptual error metric: sprites x2 wins)

# ceiling: the game's grey; floor: two light greys, the two colours the palette cycler swaps
ceil_c, floor_c1, floor_c2 = snap(CEIL), (85, 85, 85), (0, 85, 85)     # the real floor is mid grey: dark grey and a faintly teal grey, which the colour cycler swaps
forced = [ceil_c, floor_c1, floor_c2]
PAL = choose_palette(hist, forced)
assert len(set(PAL)) >= 15, PAL                       # (ceiling and the first floor grey may be the same colour in two slots)
IDX_CEIL, IDX_FLOOR1, IDX_FLOOR2 = 0, 1, 2

DITHER = float(os.environ.get("WOLF_DITHER", "0" if STANDIN else "32"))
def nearest_pair(c, pal):
    """Return the closest palette pair and the input's projected mix between them."""
    key = (c, tuple(pal))
    if key not in _paircache:
        ranked = sorted((dist2(c, q), i) for i, q in enumerate(pal))
        i0, i1 = ranked[0][1], ranked[1][1]
        p0, p1 = pal[i0], pal[i1]
        weights = (2 + c[0] / 256.0, 4, 2 + (255 - c[0]) / 256.0)
        delta = [p1[k] - p0[k] for k in range(3)]
        denom = sum(weights[k] * delta[k] * delta[k] for k in range(3))
        mix = 0.0 if not denom else sum(
            weights[k] * (c[k] - p0[k]) * delta[k] for k in range(3)
        ) / denom
        _paircache[key] = (i0, i1, max(0.0, min(1.0, mix)))
    return _paircache[key]

_paircache = {}

def quant(rows, dither=0.0, palette=PAL):
    """Quantize with a row-wise error accumulator between the two closest colours."""
    strength = max(0.0, min(1.0, dither / 64.0))
    out = []
    for y, r in enumerate(rows):
        error = (y * 73 + 128) & 255
        o = []
        for c in r:
            if c is None: o.append(0); continue
            first, second, mix = nearest_pair(c, palette)
            error += int(mix * strength * 256 + 0.5)
            if error >= 256:
                o.append(second)
                error -= 256
            else:
                o.append(first)
        out.append(o)
    return out

# ----------------------------------------------------------------------------
# textures -> bytes (LIT only): tex*512 + col*32 + row ; 16 byte-columns x 32 rows ; byte = (px[2c] << 4) | px[2c+1]
# the shaded version is not stored: the boot code derives it (nibble remap) into its own page
# ----------------------------------------------------------------------------
tex_bytes = bytearray()
tex_idx = []
for t in range(NTEX):
    q = quant(tex_rgb[t][0], DITHER)
    for col in range(TEXW // 2):
        for row in range(TEXH):
            tex_bytes.append((q[row][2 * col] << 4) | q[row][2 * col + 1])
    tex_idx.append([q])
assert len(tex_bytes) == NTEX * TEXH * TEXW // 2

# ---- the shaded page (y walls): the game's own dark art, quantised and dithered the same way ----
#      (a boot-time nibble remap of the lit page was tried first: it merged brick and mortar into mush)
tex_sh = bytearray()
for t in range(NTEX):
    q = quant(tex_rgb[t][1], DITHER)
    for col in range(TEXW // 2):
        for row in range(TEXH):
            tex_sh.append((q[row][2 * col] << 4) | q[row][2 * col + 1])
    tex_idx[t].append(q)
tex_lit = bytes(tex_bytes)
print(f"  textures: {NTEX} x {TEXW}x{TEXH} texels lit + shaded, dither {DITHER:g}")

# sprites -> bytes: id*512 + column*32 + row ; byte = (px[2c] << 4) | px[2c+1] ; 0 = transparent.
# Opaque pixels never use palette entry 0 (it is the transparency nibble), and a half-transparent byte takes the
# colour of its opaque pixel.
DITHER_SPR = float(os.environ.get("WOLF_DITHER_SPR", "0" if STANDIN else "20"))
spr_bytes = bytearray()
for cells in spr_cells:
    qrows = quant(cells, DITHER_SPR, PAL[1:])
    for col in range(16):
        for row in range(32):
            l, r = cells[row][2 * col], cells[row][2 * col + 1]
            ql = qrows[row][2 * col] + 1 if l is not None else None
            qr = qrows[row][2 * col + 1] + 1 if r is not None else None
            if ql is None and qr is None: b = 0
            else:
                if ql is None: ql = qr
                if qr is None: qr = ql
                b = (ql << 4) | qr
            spr_bytes.append(b)
assert len(spr_bytes) == NSPR * 512
# per-sprite 16-bit mask of the columns that have any opaque texel (bit c set = column c is drawn): empty columns skip the routine
colmask = b""
for sid in range(NSPR):
    m = 0
    for col in range(16):
        if any(spr_bytes[sid * 512 + col * 32 + r] for r in range(32)): m |= 1 << col
    colmask += m.to_bytes(2, "big")

# ----------------------------------------------------------------------------
# map: plane 0 -> tex codes ($80 + tex*2 = high byte of the texture address; y-walls read the shaded page)
# ----------------------------------------------------------------------------
MAPNAME, mw, mh, p0, p1 = standin_assets.load_map() if STANDIN else wolfai.load_map(0)
assert (mw, mh) == (64, 64)
mapb = bytearray()
for t in p0:
    mapb.append(0x80 + TEX_OF_TILE[t] * 2 if t in TEX_OF_TILE else 0)
# player start from plane 1 (19 N, 20 E, 21 S, 22 W)
start = None
for i, o in enumerate(p1):
    if 19 <= o <= 22:
        start = (i % 64, i // 64, o - 19)
assert start
START_X, START_Y, START_DIR = start
START_ANG = {0: ANGLES * 3 // 4, 1: 0, 2: ANGLES // 4, 3: ANGLES // 2}[START_DIR]   # N=up(-y)


# ---- AI autopilot data: goal tile (open tile in front of an elevator switch) + doors to restore on reset ----
from collections import deque
DOORC = 0x80 + DOOR_TEX * 2
DOOR2C = 0x80 + ELEV_TEX * 2          # elevator doors open like normal doors
def passable(n): return 0 <= n < 4096 and (mapb[n] == 0 or mapb[n] in (DOORC, DOOR2C))
START_IDX = START_Y * 64 + START_X
reach = {START_IDX: 0}; dq = deque([START_IDX])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in reach: reach[n] = reach[c] + 1; dq.append(n)
ELEV_TILES = [(i % 64, i // 64) for i, t in enumerate(p0) if t == 21]
cands = []
for ex, ey in ELEV_TILES:
    for (dx, dy), ang in (((1, 0), 256), ((0, 1), 384), ((-1, 0), 0), ((0, -1), 128)):   # stand east/south/west/north of it
        nx, ny = ex + dx, ey + dy
        if 0 <= nx < 64 and 0 <= ny < 64 and (ny * 64 + nx) in reach:
            cands.append((reach[ny * 64 + nx], nx, ny, ang))
assert cands, "no reachable elevator"
_, GOAL_X, GOAL_Y, GOAL_ANG = max(cands)                       # the exit is the farthest one
DOOR_TILES = [i for i, t in enumerate(mapb) if t in (DOORC, DOOR2C)]
DOOR_KIND = [1 if mapb[i] == DOOR2C else 0 for i in DOOR_TILES]
dist = {GOAL_Y * 64 + GOAL_X: 0}; dq = deque([GOAL_Y * 64 + GOAL_X])
while dq:
    c = dq.popleft()
    for n in (c + 1, c - 1, c + 64, c - 64):
        if passable(n) and n not in dist:
            dist[n] = dist[c] + 1; dq.append(n)
assert len(dist) <= 2000 and max(dist.values()) < 250, (len(dist), max(dist.values()))
assert START_IDX in dist
AI_INFO = f"goal ({GOAL_X},{GOAL_Y}) face {GOAL_ANG}; {len(dist)} walkable tiles, longest path {max(dist.values())}, start->goal {dist[START_IDX]} steps, {len(DOOR_TILES)} doors"

# "terminator vision": the palette as a red monochrome luminance ramp
RED_RAMP = [(0, 0, 0), (85, 0, 0), (170, 0, 0), (255, 85, 85)]     # black, dark red, red, bright red
def red_of(c):
    lum = ((0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2]) / 255.0) ** 0.6   # gamma lift so the dark floor/ceiling stay readable
    return gime(RED_RAMP[min(3, int(lum * 3.3))])

# ---- sprite projection tables (indexed by forward distance in 1/16 tile) ----
shh = bytes(76 if f < 4 else max(1, min(76, int(round(KH / (f / 16.0))))) for f in range(256))
kq = bytes(0 if f < 4 else max(0, min(255, int(round(PROJ_K * 16.0 / f)))) for f in range(256))
sstep = b"".join(((int(round(16 * 256.0 / w)) if w else 0) & 0xFFFF).to_bytes(2, "big") for w in range(48))

# ---- objects from plane 1: statics (decor/pickups), guards, one corpse ----
PICKUPS = {6, 20, 21, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33}      # SPR_STAT_n that can be picked up
BLOCKING = {1, 2, 3, 5, 7, 8, 10, 11, 12, 13, 16, 17, 18, 22, 35, 36, 37, 39, 40, 45, 46}
objs, blockmap = [], bytearray(512)
for i, o in enumerate(p1):
    x, y = i % 64, i // 64
    if 23 <= o <= 70:
        n = o - 23
        objs.append((2 if n in PICKUPS else 1, n, x, y, 0, n))
        if n in BLOCKING: blockmap[i >> 3] |= 1 << (i & 7)
    elif 108 <= o <= 115:
        objs.append((3, G_STAND, x, y, 25, 0))             # guard: hp 25, state 0 = standing
    elif o == 124:
        objs.append((1, G_DEAD, x, y, 0, 0))               # a dead guard lying around
objs.sort(key=lambda o: (o[0] != 3, o[3], o[2]))       # guards first, then the statics by row (draw_objects scans only the rows near the player)
NGUARD = sum(1 for o in objs if o[0] == 3)
ystart = b"".join(((8 * next((i for i, o in enumerate(objs) if i >= NGUARD and o[3] >= y), len(objs))) & 0xFFFF).to_bytes(2, "big") for y in range(65))
NOBJ_MAX = 136
assert len(objs) <= NOBJ_MAX, len(objs)
objinit = b""
for kind, sid, x, y, hp, aux in objs:
    objinit += bytes([kind, sid, x, 0x80, y, 0x80, hp, aux])
objinit += bytes((NOBJ_MAX - len(objs)) * 8)
OBJ_BASE, ZBUF_BASE, SSTEP_BASE, SPRT_TBL = 0x1900, 0x1900 + NOBJ_MAX * 8, 0x1900 + NOBJ_MAX * 8 + 80, 0x1800
assert SSTEP_BASE + 96 <= 0x1E00

# ----------------------------------------------------------------------------
# ray records (angle 0 = east, +angle = clockwise on a y-down map)
# ----------------------------------------------------------------------------
def ray_record(n):
    a = 2 * math.pi * n / ANGLES
    dx = int(round(math.cos(a) * 256)); dy = int(round(math.sin(a) * 256))
    def delta(d): return 0xFFFF if d == 0 else min(0xFFFF, int(round(65536.0 / abs(d))))
    return [dx & 0xFFFF, dy & 0xFFFF, delta(dx), delta(dy)]
rays = bytearray()
for n in range(ANGLES):
    for w in ray_record(n): rays += bytes([w >> 8, w & 0xFF])

# ----------------------------------------------------------------------------
# distance -> routine-table offset (Hh*3); six cosine classes, 512 entries each
#   index <256 : t = i/64 tiles ; index >=256: t = 4 + (i-256)/4 tiles
# ----------------------------------------------------------------------------
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
RB1_TBL, RB2_TBL, RB4_TBL = 0x1500, 0x1600, 0x1700   # routine tables (built at boot) for 1/2/4-byte-wide strips
recip = bytearray()
for k in range(NCLS):
    for i in range(512):
        t = (i + 0.5) / 64.0 if i < 256 else 4.0 + (i - 256 + 0.5) / 4.0
        perp = max(t * cosv[k], 0.05)
        hh = int(round(KH / perp))
        recip.append(max(1, min(HALF, hh)) * 3)

TBL_OF_W = {1: RB1_TBL, 2: RB2_TBL, 4: RB4_TBL}
def cfg_bytes(layout):
    b = bytearray()
    for off, cls, col, w in layout:
        b += bytes([off & 0xFF, (RCP_BASE >> 8) + cls * 2, col, TBL_OF_W[w] >> 8])
    return b
cfgs = {k: cfg_bytes(v) for k, v in LAYOUTS.items()}

# floor stripe pattern (perspective-spaced bands) for colour cycling, per half-row
floorband = bytearray()
for k in range(HALF):
    if k < HALF // 2: floorband.append(0); continue
    y = 2 * (k - HALF // 2) + 1
    d = (KH * 0.5 * 2) / y
    floorband.append(int(d) & 1)

def blast_order(blob):
    """PULS A,B,X,Y + PSHU A,B,X,Y reverses 6-byte groups: store them reversed so the blast restores true order"""
    assert len(blob) % 6 == 0, len(blob)
    g = [blob[i:i + 6] for i in range(0, len(blob), 6)]
    return b"".join(reversed(g))


# ----------------------------------------------------------------------------
# HUD data
# ----------------------------------------------------------------------------
def pack_pairs(q):
    return bytes((q[y][2 * x] << 4) | q[y][2 * x + 1] for y in range(len(q)) for x in range(len(q[0]) // 2))

hud_status = pack_pairs(quant(status_rgb))                           # 80 x 40 bytes = 3200
hud_digits = b"".join(pack_pairs(quant(d)) for d in digits_rgb)       # 11 x (2 x 16) = 352
hud_faces = b"".join(pack_pairs(quant(f)) for f in faces_rgb)         # 8 x (6 x 32) = 1536
hud_weap = b"".join(pack_pairs(quant(w)) for w in weap_rgb)           # 4 x (12 x 24) = 1152
hud_keys = b"".join(pack_pairs(quant(k)) for k in keys_rgb)           # 2 x (2 x 16) = 64

# ----------------------------------------------------------------------------
# previews: what the CoCo will really show
# ----------------------------------------------------------------------------
def preview():
    from PIL import Image
    pal_rgb = PAL
    def draw(q, scale=1):
        im = Image.new("RGB", (len(q[0]), len(q)))
        px = im.load()
        for y, r in enumerate(q):
            for x, v in enumerate(r): px[x, y] = pal_rgb[v]
        return im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    # textures: lit above shaded
    sheet = Image.new("RGB", (NTEX * 34 * 3, 2 * 18 * 3 + 40), (30, 30, 30))
    for t in range(NTEX):
        for s in range(2):
            sheet.paste(draw(tex_idx[t][s], 3), (t * 34 * 3 + 2, 4 + s * 18 * 3))
    # palette strip
    for i, c in enumerate(PAL):
        for y in range(2 * 18 * 3 + 8, 2 * 18 * 3 + 36):
            for x in range(i * 20, i * 20 + 20): sheet.putpixel((x, y), c)
    sheet.save(os.path.join(OUT, "preview_textures.png"))
    # HUD at the CoCo's real 160x40 (x3 horizontally squashed back to 4:3 look: scale x4,y2)
    hq = [[0] * 160 for _ in range(40)]
    sq = quant(status_rgb)
    for y in range(40):
        for x in range(160): hq[y][x] = sq[y][x]
    hud = draw(hq, 1).resize((640, 160), Image.NEAREST)
    faces = Image.new("RGB", (len(faces_rgb) * 12 * 4 + 8, 70), (30, 30, 30))
    for i, f in enumerate(faces_rgb): faces.paste(draw(quant(f), 2).resize((12 * 4, 64), Image.NEAREST), (4 + i * 48, 3))
    dig = Image.new("RGB", (11 * 4 * 4 + 8, 40), (30, 30, 30))
    for i, d in enumerate(digits_rgb): dig.paste(draw(quant(d), 1).resize((16, 32), Image.NEAREST), (4 + i * 16, 4))
    both = Image.new("RGB", (640, 160 + 70 + 40), (30, 30, 30))
    both.paste(hud, (0, 0)); both.paste(faces, (0, 160)); both.paste(dig, (0, 230))
    both.save(os.path.join(OUT, "preview_hud.png"))
preview()

def pad(b, mult):
    return bytes(b) + bytes((-len(b)) % mult)

# ----------------------------------------------------------------------------
# emit.   Two things reach the CoCo:
#   WOLF3D.BIN  (LOADM) - code + a few small boot tables.  LOADM can only place data safely in $2000-$7BFF
#               on this DOS (a bigger load at $8000+ crashes BASIC), so it carries no bulk data.
#   WOLF3D.DAT  - the bulk data as 8 KB page images.  The boot code reads them sector by sector with
#               Disk BASIC's own DSKCON (slow clock, as for all I/O) straight into their final physical
#               pages - no staging, no unpacking, no size limit.
# ----------------------------------------------------------------------------
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkdsk

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

def blast_order(blob):
    """PULS A,B,X,Y + PSHU A,B,X,Y reverses 6-byte groups: store them reversed so the blast restores true order"""
    assert len(blob) % 6 == 0, len(blob)
    g = [blob[i:i + 6] for i in range(0, len(blob), 6)]
    return b"".join(reversed(g))

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

# benchmark camera spots: mean DDA steps over 64 rays for every open tile, then the 5/50/90/99th percentile
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
open_tiles = [(x, y) for y in range(64) for x in range(64) if mapb[y * 64 + x] == 0 and 0 < x < 63 and 0 < y < 63]
score = sorted(((sum(dda_steps(x + .5, y + .5, 2 * math.pi * k / 64) for k in range(64)) / 64.0), x, y) for x, y in open_tiles)
bench_spots = bytes(b for q in (0.05, 0.5, 0.9, 0.995) for b in score[int(q * (len(score) - 1))][1:])
BENCH_INFO = [(round(score[int(q * (len(score) - 1))][0], 1), score[int(q * (len(score) - 1))][1:]) for q in (0.05, 0.5, 0.9, 0.995)]

pal_bytes = bytes(gime(c) for c in PAL)
# status bar is blitted with PULS/PSHU (reverses 6-byte groups): store it pre-reversed (+4 pad bytes that
# land harmlessly past the end of the screen).  The small pieces are copied with ordinary loads.
STATUS_BLK = blast_order(hud_status + bytes(4))
hud_raw = STATUS_BLK + hud_digits + hud_faces + hud_weap + hud_keys
HUD_LEN = len(hud_raw)
HUD_STATUS_LEN = len(STATUS_BLK)

# ---- the DAT page images (physical pages $41..) ----
SEC = 256
def sectors(b): return (len(b) + SEC - 1) // SEC
CODE2_RESERVE = 8192                                      # code2.asm is assembled later; its page is reserved here
PAGES = [("TEX", tex_lit + shh + kq),             # task 0 W4  ($8000 textures, $9E00 sprite tables)
         ("MAP", bytes(mapb) + bytes(recip) + bytes(blockmap)),   # W7 ($E000 map, $F000 distance tables, $FC00 blockers)
         ("HUD", hud_raw),                                # task 1 W6 (status-bar art)
         ("CODE2", bytes(CODE2_RESERVE)),                 # task 1 W5 ($A000): game logic (filled in by mkdat.py)
         ] + [(f"SPR{i}", bytes(spr_bytes[i * 8192:(i + 1) * 8192])) for i in range((len(spr_bytes) + 8191) // 8192)] \
         + [("TEXS", bytes(tex_sh) + shh + kq)]            # the shaded wall page (y walls): same layout as TEX
PAGE0 = 0x41
page_no = {name: PAGE0 + i for i, (name, _) in enumerate(PAGES)}
# the noises (scripts/sounds.py) live in pages $C0.. : far above everything the boot forge writes
import sounds
SND_PAGE0 = 0xC0
snd_list = sounds.build_standin() if STANDIN else sounds.build()
snd_pages, snd_rows = sounds.pack(snd_list, SND_PAGE0)
for i, data in enumerate(snd_pages):
    if data:                                              # pages holding only sung sounds are not on the disk
        PAGES.append((f"SND{i}", data))
        page_no[f"SND{i}"] = SND_PAGE0 + i
snd_synth = b""                                           # boot script for voice_forge: page, address, ticks, steps
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
dat_grans = mkdsk.ORDER[:ngran]                           # DAT is the first file on the disk

with open(os.path.join(OUT, "equ.inc"), "w") as f:
    f.write("; generated by gen_assets.py - do not edit\n")
    vals = [("VIEW_H", VIEW_H), ("HALF", HALF), ("HUD_TOP", HUD_TOP), ("HUD_H", HUD_H), ("STRIDE", STRIDE),
            ("ANGLES", ANGLES), ("RAYS", RAYS), ("CFG_STILL", cfg_addr["STILL"]), ("CFG_M0", cfg_addr["M0"]),
            ("CFG_M1", cfg_addr["M1"]), ("CFG_M2", cfg_addr["M2"]), ("CFG_BASE", CFG_BASE),
            ("FLOORBAND", FLOORBAND), ("CFG_LEN", CFG_LEN),
            ("NRAYS_STILL", len(LAYOUTS["STILL"])), ("NRAYS_M0", len(LAYOUTS["M0"])),
            ("NRAYS_M1", len(LAYOUTS["M1"])), ("NRAYS_M2", len(LAYOUTS["M2"])),
            ("RCP_BASE", RCP_BASE), ("RCP_LEN", len(recip)), ("MAP_LEN", len(mapb)), ("TEX_LEN", len(tex_bytes)),
            ("RB1_TBL", RB1_TBL), ("RB2_TBL", RB2_TBL), ("RB4_TBL", RB4_TBL), ("NTEX", NTEX),
            ("DOOR_CODE", 0x80 + DOOR_TEX * 2), ("DOOR2_CODE", 0x80 + ELEV_TEX * 2),
            ("SWITCH_CODE", 0x80 + TEX_OF_TILE[21] * 2),
            ("START_X", START_X), ("START_Y", START_Y), ("START_ANG", START_ANG),
            ("GOAL_X", GOAL_X), ("GOAL_Y", GOAL_Y), ("GOAL_ANG", GOAL_ANG), ("NDOORS", len(DOOR_TILES)),
            ("SPR_PAGE0", page_no["SPR0"]), ("NSPR", NSPR), ("NOBJ", NOBJ_MAX), ("OBJ", OBJ_BASE), ("ZBUF", ZBUF_BASE), ("SSTEP", SSTEP_BASE), ("COLMASK", 0x1E00), ("YSTART", 0x1F00), ("NGUARD", NGUARD), ("RQ1_TBL", 0x7D00), ("RQ2_TBL", 0x7E00), ("RQ4_TBL", 0x7F00), ("TQOFF", 0x68), ("TEXS_PAGE", page_no["TEXS"]), ("WEAP_BASE", WEAP_BASE),
            ("SPRT_TBL", SPRT_TBL), ("SHH_TBL", 0x8000 + len(tex_bytes)), ("KQ_TBL", 0x8000 + len(tex_bytes) + 256), ("BLOCKMAP", 0xFC00),
            ("G_STAND", G_STAND), ("G_WALK", G_WALK), ("G_SHOOT", G_SHOOT), ("G_PAIN", G_PAIN), ("G_DIE", G_DIE), ("G_DEAD", G_DEAD),
            ("TEX_PAGE", page_no["TEX"]), ("MAP_PAGE", page_no["MAP"]), ("HUD_PAGE", page_no["HUD"]), ("CODE2_PAGE", page_no["CODE2"]),
            ("DAT_SECTORS", nsec),
            ("HUD_LEN", HUD_LEN), ("HUD_STATUS", 0), ("HUD_STATUS_LEN", HUD_STATUS_LEN), ("HUD_DIGITS", HUD_STATUS_LEN),
            ("HUD_FACES", HUD_STATUS_LEN + len(hud_digits)), ("HUD_WEAP", HUD_STATUS_LEN + len(hud_digits) + len(hud_faces)),
            ("HUD_KEYS", HUD_STATUS_LEN + len(hud_digits) + len(hud_faces) + len(hud_weap)),
            ("PAL_F1_RGB", gime(PAL[1])), ("PAL_F2_RGB", gime(PAL[2])),
            ("SND_LINES", sounds.SND_LINES), ("SND_SILENCE", sounds.SILENCE),
            ("SYN_WHOLE", sounds.TICK_8_8 >> 8), ("SYN_FRAC", sounds.TICK_8_8 & 255)] \
           + [(name, i + 1) for i, (name, _, _) in enumerate(snd_list)]
    for k, v in vals: f.write(f"{k:<16}equ     {v}\n")

with open(os.path.join(OUT, "pal.inc"), "w") as f:         # lives in the code window (used at run time)
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fcb("palette_data", pal_bytes))
    f.write(fcb("bench_spots", bench_spots))

with open(os.path.join(OUT, "snd.inc"), "w") as f:         # sound table, in the code window: page, address, length
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write("snd_tbl\n")
    for (name, _, _), (pg, addr, ln) in zip(snd_list, snd_rows):
        f.write(f"            fcb     ${pg:02X}\n            fdb     ${addr:04X},{ln:<5}   ; {name}\n")

with open(os.path.join(OUT, "tables2.inc"), "w") as f:     # data used by code2.asm (task 1)
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fcb("pal_norm", pal_bytes))
    f.write(fcb("pal_red", bytes(red_of(c) for c in PAL)))
    f.write(fdb("door_list", DOOR_TILES))
    f.write(fcb("door_kind", bytes(DOOR_KIND)))


# ----------------------------------------------------------------------------
# cover page (drawn by the boot code while the disk loads): diagonal rainbow, black plate, 3 lines of text
#   palette: 14 hues, black (14), white (15);  stripes are 4 px wide, shift one stripe per 4 rows
# ----------------------------------------------------------------------------
import colorsys
def gime6(r, g, b):                                 # 0..3 per channel -> GIME palette byte  (R1 G1 B1 R0 G0 B0)
    return ((r >> 1) << 5) | ((g >> 1) << 4) | ((b >> 1) << 3) | ((r & 1) << 2) | ((g & 1) << 1) | (b & 1)
cover_hues = []
for i in range(14):
    r, g, b = colorsys.hsv_to_rgb(0.83 * i / 13.0, 1.0, 1.0)
    cover_hues.append(gime6(round(r * 3), round(g * 3), round(b * 3)))
cover_pal = bytes(cover_hues + [0x00, 0x3F])
from PIL import Image as _I, ImageDraw as _D, ImageFont as _F
COVER_LINES = (
    ["ASHEN BASTION", "COCO 3 RAYCASTER - 2MB", "ENTER THE BASTION"]
    if STANDIN else ["WOLFENSTEIN 3D", "TRS-80 COCO 3 - 2MB", "LOADING THE LEVEL"]
)
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
cover_txt = bytes(cover_txt)

with open(os.path.join(OUT, "stage.inc"), "w") as f:       # boot-only tables, in the staging area after the boot code
    f.write("; generated by gen_assets.py - do not edit\n")
    f.write(fdb("costab", costab))
    f.write(fdb("rcp256", rcp256))
    f.write(fcb("cfgblk", cfgblk))
    f.write(fcb("objinit", objinit))
    f.write(fcb("sstep_tbl", sstep))
    f.write(fcb("colmask_tbl", colmask))
    f.write(fcb("cover_pal", cover_pal))
    f.write(fcb("cover_txt", cover_txt))
    f.write(fcb("ystart_tbl", ystart))
    f.write(fcb("snd_synth", snd_synth))
    f.write(fcb("syn_levels", bytes(sounds.SYN_LEVELS)))
    # where the boot loader finds WOLF3D.DAT: its granule chain and the (physical page, sectors) layout
    f.write(fcb("dat_grans", bytes(dat_grans)))
    pg = b""
    for name, data in PAGES:
        pg += bytes([page_no[name], sectors(data)])
    f.write(fcb("dat_pages", pg + bytes([0])))

print(f"  sounds: {len(snd_list)} in {len(snd_pages)} pages, {sounds.FS:.0f} Hz: {sum(len(d) for d in snd_pages)} B stored, "
      f"{sum(len(d) for _, d, st in snd_list if st)} B sung at boot from {len(snd_synth)} B of ticks")
print("  ai:", AI_INFO)
print(f"  sprites: {NSPR} sprites ({len(spr_bytes)} B), objects: {len(objs)} ({sum(1 for o in objs if o[0]==3)} guards, {sum(1 for o in objs if o[0]==2)} pickups)")
print("  bench spots (mean DDA steps, tile):", BENCH_INFO)
print(f"  assets: {NTEX} textures ({len(tex_bytes)} B), map {MAPNAME} start=({START_X},{START_Y}) dir {START_DIR}; "
      f"WOLF3D.DAT {nsec} sectors in {ngran} granules; ray seeds {2*len(costab)+2*len(rcp256)} B (was {ANGLES*8})")
