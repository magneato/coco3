#!/usr/bin/env python3
"""
palette.py - L3: choose the 16 GIME colours (of 64) by what their 2x2 Bayer *blends* can show, not only by
what they are (see docs/PLAN.md, L3).

What has to be shown: every DOOM colour that E1M1 puts on the screen - its wall textures, the average colour of
each flat (floors and ceilings are drawn as depth-faded average colours, L7), the four monster types and the
status bar - each passed through COLORMAP at the light levels the map's sectors actually use, spread toward
dark for distance.  That gives a weight for each of the 256 base-palette colours.

What can be shown: the 16 palette colours, and for each pair 1/4, 2/4 and 3/4 mixes (2x2 Bayer: k of the 4
pixels show the second colour).  An RGB monitor blends neighbouring dots by light, so mixes are averaged in linear
light (gamma 2.2).  A mix of two very different colours is visibly noisy, so it is charged
NOISE x distance(a,b) x k(4-k)/16 extra.

Search: greedy facility location over the 64 colours, then swap refinement until nothing improves (with the
blends as extra facilities).  Slot 0 is forced black: the
darkest COLORMAP levels need it, and it is the ceiling of the sky-less dark.

The 13 effect palettes (pain reds, pickup golds, radiation green) are made by tinting each chosen colour the way
PLAYPAL tints its nearest DOOM colour, then snapping back to the GIME's 64.

Writes <build>/palette.json and <build>/sheets/palette.png.
Usage:  python3 scripts/palette.py [build_dir] [--map e1m1]
"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wad

LEVELS = (0, 85, 170, 255)
CANDS = [(r, g, b) for r in LEVELS for g in LEVELS for b in LEVELS]       # the GIME's 64 colours
NOISE = float(os.environ.get("DOOM_DITHER_NOISE", "0.15"))
GAMMA = 2.2

def gime(c):
    """(r,g,b) on LEVELS -> GIME palette register byte: R1 G1 B1 R0 G0 B0"""
    r, g, b = (LEVELS.index(v) for v in c)
    return (((r >> 1) & 1) << 5) | (((g >> 1) & 1) << 4) | (((b >> 1) & 1) << 3) | ((r & 1) << 2) | ((g & 1) << 1) | (b & 1)

def oklab(c):
    """sRGB-ish (gamma 2.2, 0..255) -> OKLab, vectorised over (..., 3)"""
    l = (np.asarray(c, dtype=float) / 255.0) ** GAMMA
    M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    return np.cbrt(l @ M1.T) @ M2.T

CHROMA = float(os.environ.get("DOOM_CHROMA", "4"))

def dist2(a, b):
    """squared OKLab distance x 1e5, with hue/chroma error counted CHROMA times: the GIME's 64 colours are coarse
    in lightness, and a grey drawn teal or red looks far worse than a grey drawn a little light.  Vectorised."""
    d = oklab(a) - oklab(b)
    return 1e5 * (d[..., 0] ** 2 + CHROMA * (d[..., 1] ** 2 + d[..., 2] ** 2))

def lin(c):   return (np.asarray(c, dtype=float) / 255.0) ** GAMMA
def unlin(l): return 255.0 * np.asarray(l) ** (1.0 / GAMMA)

def mix(a, b, k):
    """what an RGB monitor shows for k of 4 pixels b and the rest a"""
    return unlin(((4 - k) * lin(a) + k * lin(b)) / 4.0)

# ----------------------------------------------------------------------------
# what has to be shown
# ----------------------------------------------------------------------------
MONSTERS = ("POSS", "SPOS", "TROO", "SARG")

def light_weights(lev):
    """weight per COLORMAP level 0..31 from the sectors' light, spread for distance (DOOM: startmap = (15-light/16)*4,
    and distance darkens from there)"""
    lw = np.zeros(32)
    for s in lev.sectors:
        m0 = (15 - min(255, max(0, s.light)) // 16) * 4
        for m in range(m0 - 4, m0 + 13):
            lw[min(31, max(0, m))] += 1.0
    return lw / lw.sum()

def index_histogram(lev):
    """weight of each DOOM palette index in the art E1M1 shows (before lighting)"""
    h = np.zeros(256)
    def add(rows, w):
        for r in rows:
            for v in r:
                if v is not None:
                    h[v] += w
    tex, flats = wad.level_assets(lev)
    for t in tex:
        _, _, rows = wad.texture(t)
        add(rows, 1.0 / max(1, len(rows) * len(rows[0])) * 4096)         # each texture counts as one 64x64 area
    flat_hist = []                                                       # per flat: how often each index occurs
    for f in flats:
        if f.startswith("F_SKY"):
            continue
        fh = np.zeros(256)
        np.add.at(fh, [v for r in wad.flat(f) for v in r], 1.0)
        flat_hist.append(fh / fh.sum())
    for name in MONSTERS:
        for n in wad.sprite_frames(name):
            _, _, _, _, rows = wad.sprite(n)
            add(rows, 2.0 * 4096 / 70 / max(1, sum(v is not None for r in rows for v in r)) * 20)
    for g in ("STBAR", "STARMS"):
        p = os.path.join(wad.FREEDOOM, "graphics", g.lower() + ".png")
        if os.path.exists(p):
            add(wad.load_png(p)[2], 1.5)
    return h, flat_hist

def targets(lev):
    """-> (colours (N,3), weights (N,)) of everything to be shown, lighting applied"""
    pal, cm = wad.playpal()[0], wad.colormap()
    h, flat_hist = index_histogram(lev)
    lw = light_weights(lev)
    W = np.zeros(256)
    for m in range(32):
        np.add.at(W, cm[m], h * lw[m])
    cols = [pal[i] for i in range(256) if W[i] > 0]
    w = [W[i] for i in range(256) if W[i] > 0]
    wsum = sum(w)
    # flats: their average colour at every light level (COLORMAP applied texel by texel, then averaged in linear
    # light, as the eye averages a distant floor), weighted as a large screen area (floor + ceiling)
    palarr = np.array(pal, dtype=float)
    for fh in flat_hist:
        for m in range(32):
            if lw[m] > 0:
                cols.append(tuple(unlin((fh[:, None] * lin(palarr[cm[m]])).sum(axis=0))))
                w.append(wsum * 0.5 / len(flat_hist) * lw[m])
    w = np.array(w); return np.array(cols, dtype=float), w / w.sum()

# ----------------------------------------------------------------------------
# what can be shown, and the search
# ----------------------------------------------------------------------------
def facilities():
    """rows: 64 pure colours, then (a, b, k) mixes for a < b, k = 1..3.  -> (colours, noise, index tuples)"""
    cols, noise, ids = [], [], []
    for a in range(64):
        cols.append(CANDS[a]); noise.append(0.0); ids.append((a, a, 0))
    for a in range(64):
        for b in range(a + 1, 64):
            dab = float(dist2(CANDS[a], CANDS[b]))
            for k in (1, 2, 3):
                cols.append(tuple(mix(CANDS[a], CANDS[b], k))); noise.append(NOISE * dab * k * (4 - k) / 16.0)
                ids.append((a, b, k))
    return np.array(cols), np.array(noise), ids

def search(tcols, tw, n=16, forced=((0, 0, 0),)):
    fcols, fnoise, ids = facilities()
    D = dist2(fcols[:, None, :], tcols[None, :, :]) + fnoise[:, None]          # facilities x targets
    pure = {a: a for a in range(64)}
    rows_of = {}                                                                # (a,b) -> rows of its mixes
    for r, (a, b, k) in enumerate(ids):
        if k:
            rows_of.setdefault((a, b), []).append(r)
    def rows(sel):
        s = sorted(sel); r = [pure[a] for a in s]
        for i in range(len(s)):
            for j in range(i + 1, len(s)):
                r += rows_of[(s[i], s[j])]
        return r
    def cost(sel):
        return float((tw * D[rows(sel)].min(axis=0)).sum())
    sel = [CANDS.index(tuple(c)) for c in forced]
    while len(sel) < n:
        best = min((cost(sel + [c]), c) for c in range(64) if c not in sel)
        sel.append(best[1])
    cur = cost(sel); improved = True
    while improved:
        improved = False
        for i in range(len(forced), n):
            for c in range(64):
                if c in sel:
                    continue
                t = sel[:i] + [c] + sel[i + 1:]
                cc = cost(t)
                if cc < cur - 1e-9:
                    sel, cur, improved = t, cc, True
    # order: forced first, then dark to light (stable, readable listings)
    rest = sorted(sel[len(forced):], key=lambda a: (sum(lin(CANDS[a])), a))
    sel = sel[:len(forced)] + rest
    plain = float((tw * dist2(np.array([CANDS[a] for a in sel])[:, None, :], tcols[None]).min(axis=0)).sum())
    return [CANDS[a] for a in sel], cur, plain

def effect_palettes(pal16):
    """PLAYPAL 1..13 applied to our colours: tint as the nearest DOOM colour is tinted, snap to the GIME's 64"""
    pp = wad.playpal(); base = np.array(pp[0], dtype=float); cands = np.array(CANDS, dtype=float)
    out = []
    for p in range(14):
        row = []
        for c in pal16:
            i = int(np.argmin(dist2(base, np.array(c, dtype=float))))
            shift = np.array(pp[p][i], dtype=float) - base[i]
            want = np.clip(np.array(c, dtype=float) + shift, 0, 255)
            row.append(CANDS[int(np.argmin(dist2(cands, want)))])
        out.append(row)
    return out

def sheet(pal16, path):
    """the 16 colours on the diagonal, each pair's 2/4 mix above it and 1/4 / 3/4 below, as real 2x2 Bayer dots"""
    from PIL import Image
    B = ((0, 2), (3, 1)); cell = 8
    im = Image.new("RGB", (16 * cell * 2, 16 * cell))                              # x doubled: CoCo pixels are wide
    px = im.load()
    for i in range(16):
        for j in range(16):
            a, b = pal16[min(i, j)], pal16[max(i, j)]
            k = 0 if i == j else (2 if j > i else (1 if (i + j) & 1 else 3))
            for y in range(cell):
                for x in range(cell):
                    c = b if B[y & 1][x & 1] < k else a
                    px[2 * (j * cell + x), i * cell + y] = c
                    px[2 * (j * cell + x) + 1, i * cell + y] = c
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.resize((im.width * 2, im.height * 4), Image.NEAREST).save(path)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = args[0] if args else os.path.join(wad.ROOT, "build")
    mapname = sys.argv[sys.argv.index("--map") + 1] if "--map" in sys.argv else "e1m1"
    lev = wad.load_level(mapname)
    tcols, tw = targets(lev)
    pal16, cost, plain = search(tcols, tw)
    eff = effect_palettes(pal16)
    os.makedirs(out, exist_ok=True)
    json.dump({"map": lev.name, "noise": NOISE, "gamma": GAMMA,
               "rgb": pal16, "gime": [gime(c) for c in pal16],
               "effects_gime": [[gime(c) for c in row] for row in eff],
               "cost_with_blends": cost, "cost_pure_only": plain},
              open(os.path.join(out, "palette.json"), "w"), indent=1)
    sheet(pal16, os.path.join(out, "sheets", "palette.png"))
    print(f"  palette ({lev.name}): " + " ".join(f"${gime(c):02X}" for c in pal16))
    print(f"  error per pixel: {cost:.0f} with blends, {plain:.0f} with the 16 colours alone "
          f"({100 * (1 - cost / plain):.0f}% less)")

if __name__ == "__main__":
    main()
