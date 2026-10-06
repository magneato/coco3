#!/usr/bin/env python3
"""
fractal_scenes.py - the scene list for fractal.asm, written as build/fractal.inc, plus a bit-exact model.

    fractal_scenes.py BUILD_DIR                 write BUILD_DIR/fractal.inc
    fractal_scenes.py BUILD_DIR --preview DIR   also render every scene with the SAME integer arithmetic
                                                the 6809 uses (squares ledger, solid guessing, xorshift)
                                                into DIR/scene<N>.png, for comparison with MAME

Number format (shared with fractal.asm): a signed 16-bit word, 1.0 = 8192, always EVEN.  The lowest
bit is kept clear so that |v| can index the squares ledger directly: the 2-byte entry for |v| sits at
SQBASE + |v|.  Range -4 .. +4, resolution 1/4096.

The squares ledger holds sq(v) = 2*round(k*k/4096) for v = 2k (i.e. v*v in the same units, kept even),
for |v| < $6000 (3.0); entries that would pass $FFFE saturate there.  From it:
    x*x, y*y          one lookup each
    2xy               (x+y)^2 - x^2 - y^2      (|x+y| < 2*sqrt(2) whenever x^2 + y^2 < 4)
    a*b               ((a+b)^2 - (a-b)^2) / 4  (quarter squares; needs |a+b|, |a-b| < 3)
"""
import sys, os

ONE = 8192
SQ_LIMIT = 0x6000            # the ledger covers |v| < 3.0
COUNT = 6                    # IFS: transient points not plotted

def fx(v):
    """real -> even fixed-point word"""
    i = int(round(v * ONE / 2)) * 2
    assert -0x8000 <= i < 0x8000, v
    return i

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def sq(v):
    a = abs(v)
    assert a % 2 == 0 and a < SQ_LIMIT, v
    k = a // 2
    hi = (k * k * 16 + 0x8000) >> 16
    return min(hi, 0x7FFF) * 2

def gime(r, g, b):           # 0..3 per channel -> GIME RGB palette byte (R1 G1 B1 R0 G0 B0)
    return ((r >> 1) << 5) | ((g >> 1) << 4) | ((b >> 1) << 3) | ((r & 1) << 2) | ((g & 1) << 1) | (b & 1)

def rgb8(c):                 # GIME byte -> 8-bit RGB (for previews)
    r = ((c >> 4) & 2) | ((c >> 2) & 1)
    g = ((c >> 3) & 2) | ((c >> 1) & 1)
    b = ((c >> 2) & 2) | (c & 1)
    return (r * 85, g * 85, b * 85)

# ---- palettes: entry 0 = the set itself / background, 1-15 = escape bands (cycled) or density ----
BLACK = (0, 0, 0)
PALETTES = {
    'fire':    [BLACK, (1,0,0),(2,0,0),(3,0,0),(3,1,0),(3,2,0),(3,3,0),(3,3,1),(3,3,2),(3,3,3),(2,2,3),(1,1,3),(0,0,3),(0,0,2),(1,0,1),(1,0,0)],
    'ocean':   [BLACK, (0,0,1),(0,0,2),(0,1,2),(0,1,3),(0,2,3),(0,3,3),(1,3,3),(2,3,3),(3,3,3),(2,3,2),(1,3,1),(0,2,1),(0,1,1),(0,1,2),(0,0,1)],
    'rainbow': [BLACK, (3,0,0),(3,1,0),(3,2,0),(3,3,0),(2,3,0),(0,3,0),(0,3,2),(0,3,3),(0,2,3),(0,0,3),(1,0,3),(2,0,3),(3,0,3),(3,0,2),(3,0,1)],
    'copper':  [BLACK, (1,0,0),(1,1,0),(2,1,0),(2,1,1),(3,2,1),(3,2,2),(3,3,2),(3,3,3),(3,3,2),(3,2,1),(2,1,0),(2,1,1),(1,0,1),(1,0,0),(1,1,1)],
    'grape':   [BLACK, (1,0,1),(1,0,2),(2,0,2),(2,1,3),(3,1,3),(3,2,3),(3,3,3),(2,3,3),(1,2,3),(0,1,3),(0,1,2),(1,1,2),(1,0,2),(1,0,1),(0,0,1)],
    'fern':    [BLACK, (0,1,0),(0,1,0),(0,1,0),(0,2,0),(0,2,0),(0,2,1),(0,3,0),(0,3,0),(1,3,0),(1,3,1),(2,3,0),(2,3,1),(2,3,2),(3,3,2),(3,3,3)],
    'dragon':  [BLACK, (3,1,0),(0,2,3)] + [BLACK] * 13,
    'sierp':   [BLACK, (3,0,1),(1,3,0),(1,1,3)] + [BLACK] * 12,
}
for p in PALETTES.values():
    assert len(p) == 16

MANDEL, JULIA, SHIP, TRICORN = range(4)

def escape(name, form, center, width, maxit, pal, mirror=0, c=(0.0, 0.0), flip=False, exact=True):
    """an escape-time scene centred on `center`, `width` real units across 160 pixels.
    Pixels are 1.6x wider than tall on a 4:3 monitor, so dy = dx / 1.6.
    mirror 1 = top/bottom mirror (needs centre on the real axis), 2 = point symmetry (Julia sets)."""
    qx, qy = (4 if mirror == 2 else 2), (4 if mirror and exact else 2)  # mirrors need x0 / y0 = -(159 dx / 2) / (191 dy / 2), even
    dx = int(round(width / 160 * ONE / qx)) * qx
    dy = int(round(dx / 1.6 / qy)) * qy
    x0 = fx(center[0]) - (159 * dx) // 2
    y0 = fx(center[1]) + (191 * dy) // 2
    if mirror:
        y0 = (191 * dy) // 2
        y0 -= y0 % 2                 # (within 1/8192 of symmetric when dy is not a multiple of 4)
        assert not exact or y0 - 191 * dy == -y0
    if mirror == 2:
        x0 = -(159 * dx) // 2
        assert x0 % 2 == 0 and x0 + 159 * dx == -x0
    x0 -= x0 % 2
    y0 -= y0 % 2
    if flip:                         # Burning Ship: imaginary axis pointing down, so the ship floats upright
        y0, dy = fx(center[1]) - (191 * dy) // 2, -dy
        y0 -= y0 % 2
    return dict(kind=0, name=name, form=form, maxit=maxit, mirror=mirror, x0=x0, dx=dx, y0=y0, dy=dy,
                jx=fx(c[0]), jy=fx(c[1]), pal=pal, cycle=1)

def ifs(name, maps, npts, pal, colour_by_map):
    """an iterated function system.  maps: (probability, a, b, c, d, e, f, colour) in natural
    coordinates.  The system is conjugated so that its attractor is centred on the origin and spans
    -1..+1: every quarter-square product (|coefficient| + |coordinate| < 3) stays inside the ledger and
    the pixel offset from the screen centre fits a signed byte."""
    import random
    rnd = random.Random(1)
    x = y = 0.0                      # attractor bounds by a float chaos game
    xs, ys = [], []
    for i in range(60000):
        r = rnd.random()
        for m in maps:
            r -= m[0]
            if r < 0 or m is maps[-1]:
                break
        a, b, c, d, e, f = m[1:7]
        x, y = a * x + b * y + e, c * x + d * y + f
        if i > 20:
            xs.append(x); ys.append(y)
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    hx, hy = (max(xs) - min(xs)) / 2, (max(ys) - min(ys)) / 2
    k = 1.0 / max(hx, hy)            # p' = k (p - centre):  e' = k (a cx + b cy + e - cx), f' likewise
    hx, hy = hx * k, hy * k
    # py = 96 - (y*sy*ONE >> 6) : 128*sy pixels per unit vertically, 128*sx across (pixels are 1.6x wide)
    ppu = min(92 / hy, 77 * 1.6 / hx)
    sy, sx = fx(ppu / 128), fx(ppu / 1.6 / 128)
    recs, acc = [], 0.0
    for idx, m in enumerate(maps):
        acc += m[0]
        thr = 255 if idx == len(maps) - 1 else int(round(acc * 256)) - 1
        a, b, c, d, e, f = m[1:7]
        recs.append(dict(thr=thr, col=m[7], a=fx(a), b=fx(b), c=fx(c), d=fx(d),
                         e=fx(k * (a * cx + b * cy + e - cx)), f=fx(k * (c * cx + d * cy + f - cy))))
    return dict(kind=1, name=name, mode=1 if colour_by_map else 0, maps=recs, npts=npts,
                ox=80, oy=96, sx=sx, sy=sy, pal=pal, cycle=0)

S3 = 0.8660254
SCENES = [
    escape("Mandelbrot set",            MANDEL,  (-0.70, 0.0),      3.0,   48, 'fire', mirror=1),
    escape("Mini Mandelbrot at -1.768", MANDEL,  (-1.7685, 0.0),    0.117, 96, 'ocean', mirror=1),
    escape("Julia set, Douady rabbit",  JULIA,   (0.0, 0.0),        3.2,   64, 'rainbow', mirror=2, c=(-0.123, 0.745)),
    escape("Julia set, c=-0.8+0.156i",  JULIA,   (0.0, 0.0),        3.4,   64, 'grape', mirror=2, c=(-0.8, 0.156)),
    escape("Burning Ship",              SHIP,    (-1.76, -0.035),   0.10,  64, 'copper', flip=True),
    escape("Tricorn (Mandelbar)",       TRICORN, (-0.25, 0.0),      3.6,   48, 'ocean', mirror=1),
    ifs("Barnsley fern", [
        (0.01,  0.00,  0.00,  0.00, 0.16, 0.0, 0.00, 1),
        (0.85,  0.85,  0.04, -0.04, 0.85, 0.0, 1.60, 1),
        (0.07,  0.20, -0.26,  0.23, 0.22, 0.0, 1.60, 1),
        (0.07, -0.15,  0.28,  0.26, 0.24, 0.0, 0.44, 1)], 40000, 'fern', False),
    ifs("Heighway dragon", [
        (0.5,  0.5, -0.5, 0.5,  0.5, 0.0, 0.0, 1),
        (0.5, -0.5, -0.5, 0.5, -0.5, 1.0, 0.0, 2)], 24000, 'dragon', True),
    ifs("Sierpinski triangle", [
        (1/3, 0.5, 0.0, 0.0, 0.5, 0.00, 0.0, 1),
        (1/3, 0.5, 0.0, 0.0, 0.5, 0.50, 0.0, 2),
        (1/3, 0.5, 0.0, 0.0, 0.5, 0.25, S3 / 2, 3)], 20000, 'sierp', True),
]
assert len(SCENES) <= 9                     # keys 1-9 pick a scene

# ---- the effects reel -------------------------------------------------------------------------
# zoom: NZOOM frames from the whole set into the needle, the target point fixed on the screen; drawn at
# 2x2 into their own pages, then played back by moving the GIME's video offset
NZOOM, ZW0, ZW1, ZC0, ZT = 20, 3.0, 0.25, -0.70, -1.7685
ZOOMS = []
for k in range(NZOOM):
    w = ZW0 * (ZW1 / ZW0) ** (k / (NZOOM - 1))
    ZOOMS.append(escape("zoom %d" % k, MANDEL, (ZT + (ZC0 - ZT) * (w / ZW0), 0.0), w, 40, 'rainbow', mirror=1, exact=False))

# rotozoomer: a 64x64 texture sampled from the Douady rabbit, painted as 40x48 blocks of 4x4 pixels.
# Per frame: texture coordinates (8.8) of block (0,0), the step per block across, and per block down.
NROT = 160
def roto():
    import math
    out = []
    for f in range(NROT):
        th = 2 * math.pi * f / NROT * 1.5
        z = 1.0 + 0.6 * math.sin(2 * math.pi * f / NROT * 2)       # zoom out (tiles appear) and back in
        cs, sn = math.cos(th) * z, math.sin(th) * z
        # physical units: a block is 6.4 wide, 4 tall; a texel is 4 wide (2.5 px), 3 tall (3 rows)
        def tex(i, j):
            X, Y = 6.4 * (i - 19.5), 4.0 * (j - 23.5)
            return 32 + (cs * X - sn * Y) / 4.0, 32 + (sn * X + cs * Y) / 3.0
        u0, v0 = tex(0, 0)
        (u1, v1), (u2, v2) = tex(1, 0), tex(0, 1)
        q = lambda v: int(round(v * 256)) & 0xFFFF
        out.append([q(u0), q(v0), q(u1 - u0), q(v1 - v0), q(u2 - u0), q(v2 - v0)])
    return out

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

TITLE = ["", "     FIXED-POINT FRACTALS", "", "  TRS-80 COLOR COMPUTER 3", "  6809E 1.79 MHZ  GIME  2 MB", "",
         "  Z^2+C WITHOUT MULTIPLYING:", "  (X+Y)^2-X^2-Y^2 = 2XY", "",
         "  FORGING THE SQUARES LEDGER", "  (12288 ENTRIES, 24 KB)..."]

# ---------------------------------------------------------------------------------------------
# bit-exact model of fractal.asm
# ---------------------------------------------------------------------------------------------
def iterate(s, cx, cy):
    """-> colour 0 (did not escape) or 1 + (n mod 15), n = iterations completed"""
    form, maxit = s['form'], s['maxit']
    zx, zy = cx, cy
    if form == JULIA:
        cre, cim = s['jx'], s['jy']
    else:
        cre, cim = cx, cy
    cnt = maxit
    while True:
        ax, ay = abs(zx), abs(zy)
        if ax >= 0x4000 or ay >= 0x4000:
            break
        x2, y2 = sq(zx), sq(zy)
        r2 = x2 + y2
        if r2 & 0x8000:
            break
        if form == SHIP:
            t = sq(ax + ay) - r2
        elif form == TRICORN:
            t = r2 - sq(zx + zy)
        else:
            t = sq(zx + zy) - r2
        t = s16(t)
        ny = t + cim
        if not -0x8000 <= ny < 0x8000:
            break
        nx = s16(x2 - y2) + cre
        if not -0x8000 <= nx < 0x8000:
            break
        zx, zy = nx, ny
        cnt -= 1
        if cnt == 0:
            return 0
    n = maxit - cnt
    return 1 + n % 15

def render_escape(s):
    H = 96 if s['mirror'] else 192
    cxs = [s16(s['x0'] + i * s['dx']) for i in range(160)]
    cys = [s16(s['y0'] - r * s['dy']) for r in range(192)]
    img = [[0] * 160 for _ in range(192)]
    calc = lambda x, y: iterate(s, cxs[x], cys[y])
    def fill(x, y, n, c):
        for j in range(n):
            for i in range(n):
                if y + j < 192 and x + i < 160:
                    img[y + j][x + i] = c
    for y in range(0, H, 4):
        for x in range(0, 160, 4):
            fill(x, y, 4, calc(x, y))
    for st in (2, 1):
        for y in range(0, H, st):
            if y & st == 0:                  # row of the coarser grid: points between two parents (left/right)
                xs = range(st, 160, 2 * st)
            else:
                xs = range(0, 160, st)
            for x in xs:
                if y & st == 0:
                    par = [(x - st, y), (x + st, y)] if x + st < 160 else None
                elif x & st == 0:
                    par = [(x, y - st), (x, y + st)] if y + st < H else None
                else:
                    par = [(x - st, y - st), (x + st, y - st), (x - st, y + st), (x + st, y + st)] \
                        if x + st < 160 and y + st < H else None
                if par and all(img[py][px] == img[par[0][1]][par[0][0]] for px, py in par):
                    c = img[par[0][1]][par[0][0]]
                else:
                    c = calc(x, y)
                fill(x, y, st, c)
    if s['mirror'] == 1:
        for r in range(96):
            img[191 - r] = list(img[r])
    elif s['mirror'] == 2:
        for r in range(96):
            img[191 - r] = list(reversed(img[r]))
    return img

def fmul(a, b):
    p, m = a + b, a - b
    assert abs(p) < SQ_LIMIT and abs(m) < SQ_LIMIT, (a, b)
    return ((sq(p) - sq(m)) >> 2) & ~1        # the 6809 keeps the 17th bit (borrow) through the first shift

class Xorshift:
    def __init__(self): self.v = 1
    def __call__(self):
        v = self.v
        v ^= (v << 7) & 0xFFFF
        v ^= v >> 9
        v ^= (v << 8) & 0xFFFF
        self.v = v
        return v >> 8

def render_ifs(s):
    img = [[0] * 160 for _ in range(192)]
    rnd = Xorshift()
    x = y = 0
    for i in range(s['npts'] + COUNT):
        r = rnd()
        m = next(m for m in s['maps'] if r <= m['thr'])
        x, y = s16(fmul(x, m['a']) + fmul(y, m['b']) + m['e']), s16(fmul(x, m['c']) + fmul(y, m['d']) + m['f'])
        if i < COUNT:
            continue
        def byte(v):
            v = (v >> 6) & 0xFF
            return v - 256 if v & 0x80 else v
        px = s['ox'] + byte(fmul(x, s['sx']))
        py = s['oy'] - byte(fmul(y, s['sy']))
        if 0 <= px < 160 and 0 <= py < 192:
            if s['mode']:
                img[py][px] = m['col']
            else:
                img[py][px] = min(15, img[py][px] + 1)
    return img

# ---------------------------------------------------------------------------------------------
def emit(path):
    w = lambda v: "$%04X" % (v & 0xFFFF)
    out = [";;; fractal.inc - generated by scripts/fractal_scenes.py; do not edit",
           ";;; scene record: see the S_/E_/I_/M_ offsets in fractal.asm", "",
           "NSCENES     equ     %d" % len(SCENES), "", "scene_tab:"]
    out += ["            fdb     scene%d" % i for i in range(len(SCENES))]
    for i, s in enumerate(SCENES):
        out += ["", "scene%d:     ; %s" % (i, s['name']),
                "            fcb     %d,%d" % (s['kind'], s['cycle']),
                "            fcb     " + ",".join("$%02X" % gime(*c) for c in PALETTES[s['pal']]) + "   ; " + s['pal']]
        if s['kind'] == 0:
            out += ["            fcb     %d,%d,%d,0          ; formula, iterations, mirror" % (s['form'], s['maxit'], s['mirror']),
                    "            fdb     %s,%s,%s,%s ; x0 dx y0 dy" % (w(s['x0']), w(s['dx']), w(s['y0']), w(s['dy'])),
                    "            fdb     %s,%s       ; Julia c" % (w(s['jx']), w(s['jy']))]
        else:
            out += ["            fcb     %d,%d               ; colour by map, maps" % (s['mode'], len(s['maps'])),
                    "            fdb     %d,%d,%d,%s,%s ; points, origin x/y, scale x/y" % (s['npts'], s['ox'], s['oy'], w(s['sx']), w(s['sy']))]
            for m in s['maps']:
                out.append("            fcb     %d,%d\n            fdb     %s" % (m['thr'], m['col'], ",".join(w(m[k]) for k in "abcdef")))
    rec = lambda s, lbl: ["%s:     ; %s" % (lbl, s['name']),
                          "            fcb     0,1",
                          "            fcb     " + ",".join("$%02X" % gime(*c) for c in PALETTES[s['pal']]),
                          "            fcb     %d,%d,%d,0" % (s['form'], s['maxit'], s['mirror']),
                          "            fdb     %s,%s,%s,%s,%s,%s" % (w(s['x0']), w(s['dx']), w(s['y0']), w(s['dy']), w(s['jx']), w(s['jy']))]
    out += ["", "NZOOM       equ     %d" % NZOOM]
    for k, z in enumerate(ZOOMS):
        out += rec(z, "zoom%d" % k)
    out += ["", "NROT        equ     %d" % NROT, "roto_tab:   ; u0 v0 du dv ru rv (8.8 texels)"]
    out += ["            fdb     " + ",".join(w(v) for v in r) for r in roto()]
    out += ["", "bayer_tab:  ; for threshold t: row (0-3), byte column (0-3)"]
    pos = {BAYER[r][c]: (r, c) for r in range(4) for c in range(4)}
    out += ["            fcb     " + ",".join("%d,%d" % pos[t] for t in range(16))]
    vdg = lambda ch: ord(ch) + 0x40 if ord(ch) < 0x40 else ord(ch)
    out += ["", "title_txt:  ; 32-column text screen lines (VDG codes), 0 ends"]
    for line in TITLE:
        line = line.ljust(32)[:32]
        out += ["            fcb     " + ",".join("$%02X" % vdg(ch) for ch in line)]
    out += ["            fcb     0"]
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")

def preview(d):
    from PIL import Image
    os.makedirs(d, exist_ok=True)
    for i, s in enumerate(SCENES):
        img = render_escape(s) if s['kind'] == 0 else render_ifs(s)
        pal = [rgb8(gime(*c)) for c in PALETTES[s['pal']]]
        im = Image.new("RGB", (160, 192))
        im.putdata([pal[c] for row in img for c in row])
        im.resize((640, 480), Image.NEAREST).save(os.path.join(d, "scene%d.png" % (i + 1)))
        with open(os.path.join(d, "scene%d.bin" % (i + 1)), "wb") as f:
            f.write(bytes((row[2 * j] << 4) | row[2 * j + 1] for row in img for j in range(80)))
        print("  scene %d  %-28s %s" % (i + 1, s['name'], os.path.join(d, "scene%d.png" % (i + 1))))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    emit(os.path.join(sys.argv[1], "fractal.inc"))
    if len(sys.argv) >= 4 and sys.argv[2] == "--preview":
        preview(sys.argv[3])
