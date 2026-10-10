#!/usr/bin/env python3
"""
dither.py - the Python copy of L1 (dither locked to the screen) and L2 (the light ledger), see docs/PLAN.md.

The disk carries wall textures as one byte per texel: a DOOM palette index (the box-filtered colour, snapped back
to PLAYPAL so COLORMAP still applies).  At boot the CoCo turns them into a page per light band with two tables:

  LIGHT_HI[band][phase][index] = nibble << 4     left pixel of a byte
  LIGHT_LO[band][phase][index] = nibble          right pixel of a byte
  byte(left texel L, right texel R, row phase r) = LIGHT_HI[b][r][L] | LIGHT_LO[b][r][R]

Each nibble comes from a 2x2 Bayer threshold: the light band's colour (PLAYPAL[COLORMAP[m][index]]) is matched to
one of the 16 palette colours or a k/4 blend of two of them (the same facilities and noise charge as
palette.py).  Pixel (row phase r, position x) shows the second colour when BAYER[r][x] < k.

A wall page stores each byte column as interleaved phases, [row0 phase0, row0 phase1, row1 phase0, ...], so a
column routine forged for screen row k reads LDA 2t+(k&1),Y.

Texel grid: 2 map units per texel across (a byte column = 2 texels = 4 units), 4 units per texel down.

Checks (the gate for this step): the boot path (tables on index texels) equals the reference path (each pixel
quantised directly), byte for byte, for every page.

Writes into <build>:
  light.bin        LIGHT_HI then LIGHT_LO, [band][phase][256] each (what the boot code will load)
  texidx.bin       E1M1's wall textures as index texels, with texidx.txt (name, width, height, offset)
  sheets/          textures.png, light.png, sprites.png, flats.png - what the CoCo will show
Usage:  python3 scripts/dither.py [build_dir]
"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wad, palette

BAYER = ((0, 2), (3, 1))
BANDS = [0, 4, 8, 12, 16, 20, 24, 28]          # COLORMAP levels kept as light bands (0 = full bright)
TX, TY = 2, 4                                  # map units per texel, across and down

# ----------------------------------------------------------------------------
# the light tables
# ----------------------------------------------------------------------------
def facilities16(pal16):
    """(colour, noise, a, b, k) for the palette's colours and every k/4 blend of two of them"""
    cols, noise, abk = [], [], []
    n = len(pal16)
    for a in range(n):
        cols.append(pal16[a]); noise.append(0.0); abk.append((a, a, 0))
    for a in range(n):
        for b in range(a + 1, n):
            dab = float(palette.dist2(pal16[a], pal16[b]))
            for k in (1, 2, 3):
                cols.append(tuple(palette.mix(pal16[a], pal16[b], k)))
                noise.append(palette.NOISE * dab * k * (4 - k) / 16.0)
                abk.append((a, b, k))
    return np.array(cols, dtype=float), np.array(noise), abk

def best_blend(colours, pal16):
    """for each target colour -> (a, b, k): the cheapest pure colour or blend"""
    fc, fn, abk = facilities16(pal16)
    D = palette.dist2(fc[:, None, :], np.asarray(colours, dtype=float)[None]) + fn[:, None]
    return [abk[i] for i in D.argmin(axis=0)]

def nibble(a, b, k, r, x):
    return b if BAYER[r][x] < k else a

def light_tables(pal16):
    """-> HI, LO as [band][phase][256] lists of bytes"""
    pp, cm = wad.playpal()[0], wad.colormap()
    HI = [[[0] * 256 for _ in range(2)] for _ in BANDS]
    LO = [[[0] * 256 for _ in range(2)] for _ in BANDS]
    for bi, m in enumerate(BANDS):
        blends = best_blend([pp[cm[m][i]] for i in range(256)], pal16)
        for i, (a, b, k) in enumerate(blends):
            for r in (0, 1):
                HI[bi][r][i] = nibble(a, b, k, r, 0) << 4
                LO[bi][r][i] = nibble(a, b, k, r, 1)
    return HI, LO

# ----------------------------------------------------------------------------
# textures -> index texels
# ----------------------------------------------------------------------------
_snap = {}
def snap_index(rgb):
    """an averaged colour -> the nearest PLAYPAL index (so COLORMAP still applies to it)"""
    if rgb not in _snap:
        base = np.array(wad.playpal()[0], dtype=float)
        _snap[rgb] = int(np.argmin(palette.dist2(base, np.array(rgb, dtype=float))))
    return _snap[rgb]

def index_texels(rows, tx=TX, ty=TY, transparent=False):
    """box-filter (in linear light) a DOOM-index picture to tx x ty units per texel -> rows of indices (None =
    transparent when most of the box is)"""
    pal = np.array(wad.playpal()[0], dtype=float)
    h, w = len(rows), len(rows[0])
    out = []
    for y in range(0, h - h % ty if h >= ty else h, ty):
        o = []
        for x in range(0, w - w % tx if w >= tx else w, tx):
            box = [rows[yy][xx] for yy in range(y, min(h, y + ty)) for xx in range(x, min(w, x + tx))]
            op = [v for v in box if v is not None]
            if not op or (transparent and 2 * len(op) < len(box)):
                o.append(None); continue
            c = palette.unlin(palette.lin(pal[op]).mean(axis=0))
            o.append(snap_index(tuple(int(round(v)) for v in c)))
        out.append(o)
    return out

# ----------------------------------------------------------------------------
# pages: the boot path and the reference path
# ----------------------------------------------------------------------------
def page_boot(texels, band, HI, LO):
    """what the boot code does: per byte column, per texel row, both phases"""
    h, w = len(texels), len(texels[0])
    out = bytearray()
    for c in range(w // 2):
        for t in range(h):
            L, R = texels[t][2 * c] or 0, texels[t][2 * c + 1] or 0
            for r in (0, 1):
                out.append(HI[band][r][L] | LO[band][r][R])
    return bytes(out)

def page_reference(texels, band, pal16):
    """the same page, each pixel quantised on its own"""
    pp, cm = wad.playpal()[0], wad.colormap()
    m = BANDS[band]
    h, w = len(texels), len(texels[0])
    flat = [texels[t][x] or 0 for t in range(h) for x in range(w)]
    blends = dict(zip(sorted(set(flat)), best_blend([pp[cm[m][i]] for i in sorted(set(flat))], pal16)))
    out = bytearray()
    for c in range(w // 2):
        for t in range(h):
            for r in (0, 1):
                a, b, k = blends[texels[t][2 * c] or 0]
                left = nibble(a, b, k, r, 0)
                a, b, k = blends[texels[t][2 * c + 1] or 0]
                out.append((left << 4) | nibble(a, b, k, r, 1))
    return bytes(out)

def page_pixels(page, w, h, pal16, rows_per_texel=2):
    """decode a page the way the column routines show it: a texel row spans rows_per_texel screen rows, and
    screen row y reads phase y & 1.  -> (h * rows_per_texel) rows of 2*(w//2) RGB pixels"""
    img = []
    for y in range(h * rows_per_texel):
        t, r = y // rows_per_texel, y & 1
        row = []
        for c in range(w // 2):
            b = page[(c * h + t) * 2 + r]
            row += [pal16[b >> 4], pal16[b & 15]]
        img.append(row)
    return img

# ----------------------------------------------------------------------------
# contact sheets
# ----------------------------------------------------------------------------
PX_W, PX_H = 3, 2                       # one CoCo pixel on the sheet (pixels are about 1.6x as wide as tall)

def blit(im, x0, y0, rows):
    px = im.load()
    for y, r in enumerate(rows):
        for x, c in enumerate(r):
            if c is None:
                continue
            for dy in range(PX_H):
                for dx in range(PX_W):
                    px[x0 + x * PX_W + dx, y0 + y * PX_H + dy] = tuple(int(v) for v in c)

def doom_preview(rows, w_px, h_px):
    """the original texture, scaled to the same size on the sheet"""
    from PIL import Image
    pal = wad.playpal()[0]
    im = Image.new("RGB", (len(rows[0]), len(rows)), (40, 0, 40))
    p = im.load()
    for y, r in enumerate(rows):
        for x, v in enumerate(r):
            if v is not None:
                p[x, y] = pal[v]
    return im.resize((w_px, h_px), Image.BOX)

def main():
    from PIL import Image
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(wad.ROOT, "build")
    pj = os.path.join(out, "palette.json")
    if not os.path.exists(pj):
        sys.exit("palette.json missing: run scripts/palette.py first")
    pal16 = [tuple(c) for c in json.load(open(pj))["rgb"]]
    sheets = os.path.join(out, "sheets"); os.makedirs(sheets, exist_ok=True)

    HI, LO = light_tables(pal16)
    with open(os.path.join(out, "light.bin"), "wb") as f:
        for T in (HI, LO):
            for band in T:
                for ph in band:
                    f.write(bytes(ph))

    lev = wad.load_level("e1m1")
    tex, flats = wad.level_assets(lev)
    texels, idx, listing, off = {}, bytearray(), [], 0
    for name in tex:
        w, h, rows = wad.texture(name)
        tt = index_texels(rows)
        texels[name] = tt
        th, tw = len(tt), len(tt[0])
        for c in range(tw):
            for t in range(th):
                idx.append(tt[t][c] if tt[t][c] is not None else 0)
        listing.append(f"{name} {tw} {th} {off}"); off += tw * th
    open(os.path.join(out, "texidx.bin"), "wb").write(idx)
    open(os.path.join(out, "texidx.txt"), "w").write("\n".join(listing) + "\n")

    # the gate: boot path == reference path, for every texture and every band
    pages_bytes = 0
    for name, tt in texels.items():
        for band in range(len(BANDS)):
            pb = page_boot(tt, band, HI, LO)
            pr = page_reference(tt, band, pal16)
            if pb != pr:
                sys.exit(f"MISMATCH: {name} band {band}")
            pages_bytes += len(pb)
    print(f"  light tables: {len(BANDS)} bands x 2 phases x 256 x 2 = {2 * len(BANDS) * 2 * 256} B (light.bin)")
    print(f"  walls: {len(texels)} textures, {len(idx)} B as index texels on the disk; "
          f"{pages_bytes // 1024} KB of pages at boot ({len(BANDS)} bands)")
    print(f"  boot path == reference path for all {len(texels) * len(BANDS)} pages")

    # textures.png: original (left) and the CoCo's band 0 (right), side by side, in rows
    order = sorted(texels, key=lambda n: (-len(texels[n]), n))
    cells, x, y, rowh, W = [], 0, 0, 0, 1600
    for name in order:
        tt = texels[name]; th, tw = len(tt), len(tt[0])
        cw, chh = tw * PX_W, th * 2 * PX_H
        if x + 2 * cw + 12 > W:
            x, y, rowh = 0, y + rowh + 8, 0
        cells.append((name, x, y)); x += 2 * cw + 12; rowh = max(rowh, chh)
    im = Image.new("RGB", (W, y + rowh), (24, 24, 24))
    for name, x, y in cells:
        tt = texels[name]; th, tw = len(tt), len(tt[0])
        _, _, rows = wad.texture(name)
        im.paste(doom_preview(rows, tw * PX_W, th * 2 * PX_H), (x, y))
        blit(im, x + tw * PX_W + 2, y, page_pixels(page_boot(tt, 0, HI, LO), tw, th, pal16))
    im.save(os.path.join(sheets, "textures.png"))

    # light.png: a few textures through all the bands
    picks = [n for n in ("BROWN1", "STARTAN3", "COMPTALL", "BIGDOOR2", "SUPPORT2") if n in texels][:4] or order[:4]
    tw = max(len(texels[n][0]) for n in picks); th = max(len(texels[n]) for n in picks)
    im = Image.new("RGB", (len(BANDS) * (tw * PX_W + 4), len(picks) * (th * 2 * PX_H + 4)), (24, 24, 24))
    for j, n in enumerate(picks):
        tt = texels[n]
        for b in range(len(BANDS)):
            blit(im, b * (tw * PX_W + 4), j * (th * 2 * PX_H + 4), page_pixels(page_boot(tt, b, HI, LO), len(tt[0]), len(tt), pal16))
    im.save(os.path.join(sheets, "light.png"))

    # sprites.png: the first frame of each monster from the front, at band 0
    frames = []
    for p in palette.MONSTERS:
        n = next(k for k in sorted(wad.sprite_frames(p)) if k[4:6] == "A1")
        _, _, _, _, rows = wad.sprite(n)
        frames.append(index_texels(rows, transparent=True))
    sw = sum(len(f[0]) // 2 * 2 for f in frames) * PX_W + 8 * len(frames)
    sh = max(len(f) for f in frames) * 2 * PX_H
    im = Image.new("RGB", (sw, sh), (90, 0, 90)); x = 0
    for f in frames:
        w2 = len(f[0]) // 2 * 2
        f2 = [r[:w2] for r in f]
        pix = page_pixels(page_boot(f2, 0, HI, LO), w2, len(f2), pal16)
        pix = [[None if f2[y // 2][xx] is None else c for xx, c in enumerate(r)] for y, r in enumerate(pix)]
        blit(im, x, 0, pix); x += w2 * PX_W + 8
    im.save(os.path.join(sheets, "sprites.png"))

    # flats.png: each flat's average colour through the bands (the L7 ramps), next to the flat itself
    fl = [f for f in flats if not f.startswith("F_SKY")]
    cm, pp = wad.colormap(), np.array(wad.playpal()[0], dtype=float)
    im = Image.new("RGB", (64 + 8 + len(BANDS) * 24, len(fl) * 20), (24, 24, 24)); px = im.load()
    for j, f in enumerate(fl):
        rows = wad.flat(f)
        im.paste(doom_preview(rows, 64, 18), (0, j * 20))
        hist = np.zeros(256); np.add.at(hist, [v for r in rows for v in r], 1.0); hist /= hist.sum()
        avgs = [tuple(int(round(v)) for v in palette.unlin((hist[:, None] * palette.lin(pp[cm[m]])).sum(axis=0))) for m in BANDS]
        for b, (a_, b_, k) in enumerate(best_blend(avgs, pal16)):
            for yy in range(18):
                for xx in range(24):
                    px[72 + b * 24 + xx, j * 20 + yy] = pal16[nibble(a_, b_, k, yy & 1, (xx // PX_W) & 1)]
    im.save(os.path.join(sheets, "flats.png"))
    print(f"  sheets: {sheets}/textures.png light.png sprites.png flats.png")

if __name__ == "__main__":
    main()
