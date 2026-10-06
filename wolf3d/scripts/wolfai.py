#!/usr/bin/env python3
"""
wolfai - the extractor.  It opens the natives' sealed Wolfenstein 3D archives (WOLF3D/) and lays out what the
CoCo3 build needs: a palette, wall textures, a level lattice, gauge pictures.  It also writes PNG contact
sheets so that a human can confirm the extraction by eye.

  wolfai.py palette   unpack LZEXE'd WOLF3D.EXE and pull out the 256-colour VGA palette
  wolfai.py sheet     write PNG contact sheets of walls / pictures / maps into --out
"""
import struct, sys, os

DATA = os.environ.get("WOLF_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "WOLF3D"))

def rd(name):
    return open(os.path.join(DATA, name), "rb").read()

# ----------------------------------------------------------------------------
# LZEXE 0.91 unpacker (the shipped WOLF3D.EXE is LZEXE-compressed)
# ----------------------------------------------------------------------------
def lzexe_unpack(exe):
    hdr = struct.unpack_from("<16H", exe, 0)
    assert hdr[0] == 0x5A4D and exe[0x1C:0x20] == b"LZ91", "not an LZEXE 0.91 file"
    inf = struct.unpack_from("<8H", exe, (hdr[4] + hdr[0x0B]) << 4)   # block at CS:0
    start = (hdr[0x0B] - inf[4] + hdr[4]) << 4                        # compressed image
    out = _lz_decode(exe, start)
    if out is None or len(out) < 60000:
        raise RuntimeError("could not unpack WOLF3D.EXE")
    return out

def _lz_decode(exe, pos):
    """LZEXE 0.91 stream.  The 16-bit flag word is reloaded EAGERLY (right after
    its last bit is consumed), which fixes the byte order of the interleaved
    flag words and literal/offset bytes."""
    out = bytearray()
    n = len(exe)
    try:
        bitbuf = exe[pos] | (exe[pos + 1] << 8); pos += 2; count = 16
        def getbit():
            nonlocal bitbuf, count, pos
            b = bitbuf & 1
            count -= 1
            if count == 0:
                bitbuf = exe[pos] | (exe[pos + 1] << 8); pos += 2; count = 16
            else:
                bitbuf >>= 1
            return b
        while len(out) < 400000:
            if getbit():
                out.append(exe[pos]); pos += 1; continue
            if not getbit():
                ln = getbit() << 1
                ln |= getbit()
                ln += 2
                span = exe[pos] | 0xFF00; pos += 1
            else:
                span = exe[pos]; ln = exe[pos + 1]; pos += 2
                span |= ((ln & ~0x07) << 5) | 0xE000
                ln = (ln & 0x07) + 2
                if ln == 2:
                    ln = exe[pos]; pos += 1
                    if ln == 0: break
                    if ln == 1: continue
                    ln += 1
            span -= 0x10000
            if -span > len(out): return None
            for _ in range(ln):
                out.append(out[span])
        return bytes(out)
    except IndexError:
        return None

def find_palette(img):
    pat = bytes([0, 0, 0, 0, 0, 42, 0, 42, 0, 0, 42, 42, 42, 0, 0, 42, 0, 42, 42, 21, 0, 42, 42, 42])
    i = img.find(pat)
    if i < 0:
        raise RuntimeError("palette not found in unpacked EXE")
    pal = img[i:i + 768]
    assert max(pal) <= 63
    return [(pal[k] * 255 // 63, pal[k + 1] * 255 // 63, pal[k + 2] * 255 // 63) for k in range(0, 768, 3)], i

def load_palette():
    img = lzexe_unpack(rd("WOLF3D.EXE"))
    return find_palette(img)[0]

# ----------------------------------------------------------------------------
# VSWAP: 64x64 wall textures (column-major) and sprites
# ----------------------------------------------------------------------------
class VSwap:
    def __init__(self):
        d = self.d = rd("VSWAP.WL6")
        self.nchunks, self.sprite_start, self.sound_start = struct.unpack_from("<3H", d, 0)
        self.offs = struct.unpack_from(f"<{self.nchunks}I", d, 6)
        self.lens = struct.unpack_from(f"<{self.nchunks}H", d, 6 + 4 * self.nchunks)

    def wall(self, n):
        """64x64 palette indices as rows[y][x]"""
        c = self.d[self.offs[n]:self.offs[n] + 4096]
        return [[c[x * 64 + y] for x in range(64)] for y in range(64)]

    def sprite(self, n):
        """64x64 rows[y][x] palette indices, None = transparent (compressed post format)"""
        base = self.offs[self.sprite_start + n]
        d = self.d
        left, right = struct.unpack_from("<2H", d, base)
        colofs = struct.unpack_from(f"<{right - left + 1}H", d, base + 4)
        img = [[None] * 64 for _ in range(64)]
        for ci, co in enumerate(colofs):
            p = base + co
            while True:
                end2 = struct.unpack_from("<H", d, p)[0]
                if end2 == 0: break
                corr = struct.unpack_from("<h", d, p + 2)[0]
                start2 = struct.unpack_from("<H", d, p + 4)[0]
                p += 6
                y0, y1 = start2 // 2, end2 // 2
                # pixel bytes live at base + corr + y*... (corr is a signed offset trick)
                for y in range(y0, y1):
                    img[y][left + ci] = d[base + corr + y]
        return img

# ----------------------------------------------------------------------------
# Maps: Carmack + RLEW
# ----------------------------------------------------------------------------
def carmack_expand(src, out_len):
    out = bytearray(); i = 0
    while len(out) < out_len:
        w = src[i] | (src[i + 1] << 8); i += 2
        hi = w >> 8
        if hi in (0xA7, 0xA8):
            cnt = w & 0xFF
            if cnt == 0:
                out.append(src[i]); i += 1; out.append(hi)
            elif hi == 0xA7:
                off = src[i]; i += 1
                st = len(out) - off * 2
                for k in range(cnt * 2): out.append(out[st + k])
            else:
                off = src[i] | (src[i + 1] << 8); i += 2
                st = off * 2
                for k in range(cnt * 2): out.append(out[st + k])
        else:
            out += bytes((w & 0xFF, hi))
    return bytes(out)

def rlew_expand(src, out_len, tag):
    out = bytearray(); i = 0
    while len(out) < out_len:
        w = src[i] | (src[i + 1] << 8); i += 2
        if w == tag:
            cnt = src[i] | (src[i + 1] << 8); val = src[i + 2] | (src[i + 3] << 8); i += 4
            out += bytes((val & 0xFF, val >> 8)) * cnt
        else:
            out += bytes((w & 0xFF, w >> 8))
    return bytes(out[:out_len])

def load_map(n):
    """-> (name, plane0 tiles[64*64], plane1 objects[64*64])"""
    head = rd("MAPHEAD.WL6"); gm = rd("GAMEMAPS.WL6")
    tag = struct.unpack_from("<H", head, 0)[0]
    off = struct.unpack_from("<I", head, 2 + 4 * n)[0]
    ps = struct.unpack_from("<3i", gm, off)
    pl = struct.unpack_from("<3H", gm, off + 12)
    w, h = struct.unpack_from("<2H", gm, off + 18)
    name = gm[off + 22:off + 38].split(b"\0")[0].decode()
    planes = []
    for k in range(2):
        raw = gm[ps[k]:ps[k] + pl[k]]
        elen = struct.unpack_from("<H", raw, 0)[0]
        mid = carmack_expand(raw[2:], elen)
        rlen = struct.unpack_from("<H", mid, 0)[0]
        data = rlew_expand(mid[2:], rlen, tag)
        planes.append(struct.unpack(f"<{w * h}H", data))
    return name, w, h, planes[0], planes[1]

# ----------------------------------------------------------------------------
# VGAGRAPH: Huffman-compressed planar pictures
# ----------------------------------------------------------------------------
class VgaGraph:
    def __init__(self):
        self.g = rd("VGAGRAPH.WL6")
        head = rd("VGAHEAD.WL6")
        n = len(head) // 3
        self.offs = [head[i * 3] | head[i * 3 + 1] << 8 | head[i * 3 + 2] << 16 for i in range(n)]
        dic = rd("VGADICT.WL6")
        self.dict = [struct.unpack_from("<2H", dic, i * 4) for i in range(256)]
        self.nchunks = n - 1
        pt = self.chunk(0)
        self.pictable = [struct.unpack_from("<2H", pt, i * 4) for i in range(len(pt) // 4)]

    def chunk(self, i):
        a, b = self.offs[i], self.offs[i + 1]
        raw = self.g[a:b]
        size = struct.unpack_from("<I", raw, 0)[0]
        out = bytearray(); node = 254; src = raw[4:]
        for byte in src:
            for bit in range(8):
                nxt = self.dict[node][(byte >> bit) & 1]
                if nxt < 256:
                    out.append(nxt); node = 254
                    if len(out) >= size: return bytes(out)
                else:
                    node = nxt - 256
        return bytes(out)

    def pic(self, i):
        """chunk i (>=3) -> (w, h, rows[y][x]) palette indices; planar -> linear"""
        w, h = self.pictable[i - 3]
        d = self.chunk(i)
        q = w >> 2
        rows = [[d[(y * q + (x >> 2)) + (x & 3) * q * h] for x in range(w)] for y in range(h)]
        return w, h, rows

# ----------------------------------------------------------------------------
# PNG helpers (PIL)
# ----------------------------------------------------------------------------
def to_img(rows, pal, scale=1, transparent=None):
    from PIL import Image
    h, w = len(rows), len(rows[0])
    im = Image.new("RGB", (w, h), (255, 0, 255))
    px = im.load()
    for y in range(h):
        for x in range(w):
            v = rows[y][x]
            px[x, y] = (255, 0, 255) if v is None else pal[v]
    return im.resize((w * scale, h * scale), Image.NEAREST) if scale != 1 else im

def sheet(out):
    from PIL import Image, ImageDraw
    os.makedirs(out, exist_ok=True)
    pal = load_palette()
    vs = VSwap()
    # walls
    n = vs.sprite_start
    cols = 16
    sh = Image.new("RGB", (cols * 66, ((n + cols - 1) // cols) * 76), (40, 40, 40))
    dr = ImageDraw.Draw(sh)
    for i in range(n):
        im = to_img(vs.wall(i), pal)
        x, y = (i % cols) * 66, (i // cols) * 76
        sh.paste(im, (x + 1, y + 11)); dr.text((x + 2, y), str(i), fill=(255, 255, 0))
    sh.save(os.path.join(out, "walls.png"))
    # pictures
    vg = VgaGraph()
    ids = [i for i in range(3, vg.nchunks) if i - 3 < len(vg.pictable) and 0 < vg.pictable[i - 3][0] <= 320 and 0 < vg.pictable[i - 3][1] <= 200]
    sheet2 = Image.new("RGB", (1000, 2400), (40, 40, 40)); d2 = ImageDraw.Draw(sheet2)
    x = y = 0; rowh = 0
    for i in ids:
        try:
            w, h, rows = vg.pic(i)
        except Exception as e:
            continue
        if x + w + 4 > 1000: x = 0; y += rowh + 14; rowh = 0
        sheet2.paste(to_img(rows, pal), (x, y + 10)); d2.text((x, y), str(i), fill=(255, 255, 0))
        x += w + 4; rowh = max(rowh, h + 10)
    sheet2.crop((0, 0, 1000, min(2400, y + rowh + 14))).save(os.path.join(out, "pics.png"))
    # map 0
    name, w, h, p0, p1 = load_map(0)
    im = Image.new("RGB", (w * 8, h * 8), (0, 0, 0)); px = im.load()
    for yy in range(h):
        for xx in range(w):
            t = p0[yy * w + xx]
            c = (60, 60, 60) if t == 0 or t >= 106 else ((255, 200, 0) if 90 <= t < 106 else (160 + (t * 7) % 90, 80 + (t * 13) % 150, 80 + (t * 29) % 150))
            for dy in range(8):
                for dx in range(8): px[xx * 8 + dx, yy * 8 + dy] = c
    im.save(os.path.join(out, "map0.png"))
    print("map0:", name, w, h)
    print("sheets written to", out, "| walls:", n, "| pics:", len(ids))

def selftest():
    """sanity checks that the extraction really decodes the original game data"""
    ok = True
    def check(name, cond, info=""):
        nonlocal ok
        print(f"  [{'ok' if cond else 'FAIL'}] {name} {info}")
        ok &= bool(cond)
    img = lzexe_unpack(rd("WOLF3D.EXE"))
    check("LZEXE unpack", 280000 < len(img) < 300000, f"({len(img)} bytes)")
    pal, at = find_palette(img)
    check("VGA palette: 256 entries, entry 0 black, entry 15 white, last = magenta key",
          len(pal) == 256 and pal[0] == (0, 0, 0) and pal[15] == (255, 255, 255) and pal[255] == (153, 0, 137))
    vs = VSwap()
    check("VSWAP: 106 wall chunks, sprites start after them", vs.sprite_start == 106 and vs.nchunks > 600, f"({vs.nchunks} chunks)")
    w0 = vs.wall(0)
    check("wall 0 is 64x64 and not flat", len(w0) == 64 and len(set(v for r in w0 for v in r)) > 8)
    sp = vs.sprite(50)
    check("sprite decodes (transparent + opaque pixels)", any(v is None for r in sp for v in r) and any(v is not None for r in sp for v in r))
    name, w, h, p0, p1 = load_map(0)
    check("E1M1 map: 64x64, name 'Wolf1 Map1'", (w, h) == (64, 64) and name == "Wolf1 Map1", f"({name})")
    starts = [i for i, o in enumerate(p1) if 19 <= o <= 22]
    check("exactly one player start", len(starts) == 1, f"(at {starts[0] % 64},{starts[0] // 64})" if starts else "")
    ring = [p0[x] for x in range(64)] + [p0[63 * 64 + x] for x in range(64)] + [p0[y * 64] for y in range(64)] + [p0[y * 64 + 63] for y in range(64)]
    check("outer wall ring is solid (every border tile is a wall 1..63 or a door)", all(0 < t < 64 or 90 <= t < 106 for t in ring))
    vg = VgaGraph()
    check("VGAGRAPH: status bar is 320x40, digits 8x16", vg.pictable[95 - 3] == (320, 40) and vg.pictable[108 - 3] == (8, 16))
    wd, hd, rows = vg.pic(108)
    check("digit '0' glyph has foreground and background", len(set(v for r in rows for v in r)) >= 2)
    print("wolfai selftest:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "palette"
    if cmd == "palette":
        img = lzexe_unpack(rd("WOLF3D.EXE"))
        pal, at = find_palette(img)
        print(f"unpacked EXE: {len(img)} bytes; palette at +{at:#x}")
    elif cmd == "selftest":
        selftest()
    elif cmd == "sheet":
        sheet(sys.argv[2] if len(sys.argv) > 2 else "build/wolfai")
