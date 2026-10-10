#!/usr/bin/env python3
"""
wad.py - reads Freedoom (Phase 1) straight from its source checkout in ../freedoom: no IWAD build, no DeuTex.

  levels      freedoom/levels/<map>.wad              (vanilla binary lumps: VERTEXES, SEGS, NODES, ...)
  palettes    PLAYPAL (14 x 256 RGB) and COLORMAP (34 x 256), produced by Freedoom's own generator scripts,
              which are run as tools (they are GPL; nothing of them is copied here)
  textures    freedoom/lumps/textures/textures.cfg (with DOOM1_VERSIONS defined), composed from patches
  flats       freedoom/flats/<name>.png, 64 x 64
  sprites     freedoom/sprites/<name>.png, offsets from buildcfg.txt [sprites] (with PHASE1 defined)

Every picture comes back as rows of DOOM palette indices (None = transparent), the way the original engine sees
it, so COLORMAP applies exactly.  The PNGs come in every mode (P, L, RGB, RGBA, LA, 1); like DeuTex, each pixel
is matched to the nearest PLAYPAL colour, and cyan (0,255,255) or alpha 0 is transparency.

Usage:  python3 scripts/wad.py selftest [map]      counts, plus a load of everything the map uses
"""
import os, struct, subprocess, sys
from collections import namedtuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FREEDOOM = os.environ.get("FREEDOOM", os.path.join(ROOT, "freedoom"))
CACHE = os.environ.get("WAD_CACHE", os.path.join(ROOT, "build", "cache"))

# ----------------------------------------------------------------------------
# levels
# ----------------------------------------------------------------------------
Thing = namedtuple("Thing", "x y angle type flags")
Linedef = namedtuple("Linedef", "v1 v2 flags special tag right left")
Sidedef = namedtuple("Sidedef", "xoff yoff upper lower middle sector")
Seg = namedtuple("Seg", "v1 v2 angle linedef side offset")
Subsector = namedtuple("Subsector", "count first")
Node = namedtuple("Node", "x y dx dy rbox lbox right left")     # boxes: (top, bottom, left, right); child bit 15 = subsector
Sector = namedtuple("Sector", "floor ceil floorpic ceilpic light special tag")
Level = namedtuple("Level", "name things linedefs sidedefs vertexes segs subsectors nodes sectors reject blockmap")

def _name(b):
    return b.split(b"\0", 1)[0].decode("ascii").upper()

def read_wad(path):
    """-> [(lump name, bytes)] in directory order"""
    d = open(path, "rb").read()
    magic, n, off = struct.unpack("<4sii", d[:12])
    assert magic in (b"IWAD", b"PWAD"), path
    out = []
    for i in range(n):
        pos, size, nm = struct.unpack("<ii8s", d[off + 16 * i: off + 16 * i + 16])
        out.append((_name(nm), d[pos:pos + size]))
    return out

def _recs(b, fmt):
    sz = struct.calcsize(fmt)
    return [struct.unpack(fmt, b[i:i + sz]) for i in range(0, len(b) - sz + 1, sz)]

def load_level(name="e1m1"):
    lumps = dict(read_wad(os.path.join(FREEDOOM, "levels", name.lower() + ".wad")))
    sides = [Sidedef(x, y, _name(u), _name(l), _name(m), s) for x, y, u, l, m, s in _recs(lumps["SIDEDEFS"], "<hh8s8s8sh")]
    secs = [Sector(f, c, _name(fp), _name(cp), li, sp, tg) for f, c, fp, cp, li, sp, tg in _recs(lumps["SECTORS"], "<hh8s8shhh")]
    nodes = [Node(r[0], r[1], r[2], r[3], r[4:8], r[8:12], r[12], r[13]) for r in _recs(lumps["NODES"], "<hhhh4h4hHH")]
    lines = [Linedef(*r) for r in _recs(lumps["LINEDEFS"], "<HHhhhHH")]
    lines = [l._replace(right=None if l.right == 0xFFFF else l.right, left=None if l.left == 0xFFFF else l.left) for l in lines]
    return Level(name.upper(),
                 [Thing(*r) for r in _recs(lumps["THINGS"], "<hhhhh")],
                 lines, sides,
                 _recs(lumps["VERTEXES"], "<hh"),
                 [Seg(*r) for r in _recs(lumps["SEGS"], "<HHhHhh")],
                 [Subsector(*r) for r in _recs(lumps["SSECTORS"], "<HH")],
                 nodes, secs, lumps.get("REJECT", b""), lumps.get("BLOCKMAP", b""))

# ----------------------------------------------------------------------------
# palettes: Freedoom's generators, run once and cached
# ----------------------------------------------------------------------------
def _tool(script, *args, stdin=None):
    return subprocess.run([sys.executable, "-I", script, *args], input=stdin, capture_output=True, check=True,
                          cwd=os.path.dirname(script)).stdout

def _cached(fname, make):
    p = os.path.join(CACHE, fname)
    if not os.path.exists(p):
        os.makedirs(CACHE, exist_ok=True)
        open(p, "wb").write(make())
    return open(p, "rb").read()

BASE_PAL = os.path.join(FREEDOOM, "lumps", "playpal", "playpal-base.lmp")

def playpal():
    """14 palettes of 256 (r,g,b): 0 normal, 1-8 pain reds, 9-12 pickup golds, 13 radiation suit green"""
    b = _cached("playpal.lmp", lambda: _tool(os.path.join(FREEDOOM, "lumps", "playpal", "playpal"), BASE_PAL))
    assert len(b) == 14 * 768
    return [[tuple(b[p * 768 + 3 * i: p * 768 + 3 * i + 3]) for i in range(256)] for p in range(14)]

def colormap():
    """34 maps of 256 bytes: 0 = full bright .. 31 = darkest, 32 = invulnerability, 33 = black"""
    b = _cached("colormap.lmp", lambda: _tool(os.path.join(FREEDOOM, "lumps", "colormap", "colormap"), BASE_PAL))
    assert len(b) == 34 * 256
    return [list(b[m * 256:(m + 1) * 256]) for m in range(34)]

# ----------------------------------------------------------------------------
# pictures -> DOOM palette indices
# ----------------------------------------------------------------------------
_lut = None
def _nearest_lut():
    """(r>>2, g>>2, b>>2) -> nearest base-palette index, as a 64^3 numpy table (built once)"""
    global _lut
    if _lut is None:
        import numpy as np
        pal = np.array(playpal()[0], dtype=np.int32)
        v = (np.arange(64, dtype=np.int32) << 2) | 2
        r, g, b = np.meshgrid(v, v, v, indexing="ij")
        q = np.stack([r.ravel(), g.ravel(), b.ravel()], axis=1)
        best = np.zeros(len(q), dtype=np.uint8); bd = np.full(len(q), 1 << 30, dtype=np.int64)
        for i, c in enumerate(pal):
            d = ((q - c) ** 2).sum(axis=1)
            m = d < bd; bd[m] = d[m]; best[m] = i
        _lut = best
    return _lut

def load_png(path):
    """-> (w, h, rows[y][x] = palette index or None)"""
    import numpy as np
    from PIL import Image
    im = Image.open(path)
    if im.mode == "P" and "transparency" not in im.info and _same_palette(im):
        a = np.array(im)
        return im.width, im.height, [list(map(int, r)) for r in a]
    a = np.array(im.convert("RGBA"), dtype=np.int32)
    rgb, alpha = a[..., :3], a[..., 3]
    clear = (alpha < 128) | ((rgb[..., 0] == 0) & (rgb[..., 1] == 255) & (rgb[..., 2] == 255))
    idx = _nearest_lut()[((rgb[..., 0] >> 2) << 12) | ((rgb[..., 1] >> 2) << 6) | (rgb[..., 2] >> 2)]
    return im.width, im.height, [[None if clear[y, x] else int(idx[y, x]) for x in range(im.width)] for y in range(im.height)]

_pal_bytes = None
def _same_palette(im):
    """True when an indexed PNG already uses PLAYPAL in PLAYPAL's order (then its indices are taken as they are)"""
    global _pal_bytes
    if _pal_bytes is None:
        _pal_bytes = bytes(c for rgb in playpal()[0] for c in rgb)
    p = im.getpalette()
    return p is not None and bytes(p[:768]) == _pal_bytes

def _find(dirname, name):
    p = os.path.join(FREEDOOM, dirname, name.lower() + ".png")
    if not os.path.exists(p):
        raise FileNotFoundError(f"{name} not in freedoom/{dirname}")
    return p

def flat(name):
    w, h, rows = load_png(_find("flats", name))
    assert (w, h) == (64, 64), (name, w, h)
    return rows

def patch(name):
    return load_png(_find("patches", name))

# ----------------------------------------------------------------------------
# textures.cfg: TEXTURE1 definitions, composed from patches
# ----------------------------------------------------------------------------
def _cpp(path, *defines):
    """the subset of cpp that Freedoom's config files use (#define #undef #ifdef #ifndef #else #endif).
    #include is skipped: buildcfg.txt includes files that exist only after a Freedoom build."""
    defs, stack, out = set(defines), [], []
    for ln in open(path, encoding="utf-8", errors="replace"):
        s = ln.strip()
        if s.startswith("#"):
            f = s[1:].split()
            cmd, arg = (f[0], f[1] if len(f) > 1 else None) if f else ("", None)
            live = all(stack)
            if cmd in ("ifdef", "ifndef"):
                stack.append((arg in defs) == (cmd == "ifdef"))
            elif cmd == "else":
                stack[-1] = not stack[-1]
            elif cmd == "endif":
                stack.pop()
            elif cmd == "define" and live:
                defs.add(arg)
            elif cmd == "undef" and live:
                defs.discard(arg)
            continue
        if all(stack):
            out.append(ln)
    assert not stack, path
    return "".join(out)

_texdefs = None
def texture_defs():
    """name -> (width, height, [(patch, x, y)])"""
    global _texdefs
    if _texdefs is None:
        _texdefs, cur = {}, None
        for ln in _cpp(os.path.join(FREEDOOM, "lumps", "textures", "textures.cfg"), "DOOM1_VERSIONS").splitlines():
            ln = ln.split(";", 1)[0].strip()
            if not ln:
                continue
            f = ln.split()
            if f[0] == "*":
                cur[2].append((f[1].upper(), int(f[2]), int(f[3])))
            else:
                cur = (int(f[1]), int(f[2]), [])
                _texdefs[f[0].upper()] = cur
    return _texdefs

def texture(name):
    """-> (w, h, rows) composed the way the engine composes it (later patches overwrite earlier ones)"""
    w, h, parts = texture_defs()[name.upper()]
    rows = [[None] * w for _ in range(h)]
    for pname, ox, oy in parts:
        pw, ph, prow = patch(pname)
        for y in range(max(0, oy), min(h, oy + ph)):
            src, dst = prow[y - oy], rows[y]
            for x in range(max(0, ox), min(w, ox + pw)):
                if src[x - ox] is not None:
                    dst[x] = src[x - ox]
    return w, h, rows

# ----------------------------------------------------------------------------
# sprites: offsets from buildcfg.txt
# ----------------------------------------------------------------------------
_sprofs = None
def sprite_offsets():
    """lump name -> (xoff, yoff); a lump may name a mirrored pair, e.g. POSSA2A8"""
    global _sprofs
    if _sprofs is None:
        _sprofs, sect = {}, None
        for ln in _cpp(os.path.join(FREEDOOM, "buildcfg.txt"), "PHASE1").splitlines():
            ln = ln.split(";", 1)[0].strip()
            if not ln:
                continue
            if ln.startswith("["):
                sect = ln.strip("[]").lower(); continue
            if sect == "sprites":
                f = ln.split()
                _sprofs[f[0].upper()] = (int(f[1]), int(f[2])) if len(f) >= 3 else (0, 0)
    return _sprofs

def sprite(name):
    """-> (w, h, xoff, yoff, rows)"""
    xo, yo = sprite_offsets()[name.upper()]
    w, h, rows = load_png(_find("sprites", name))
    return w, h, xo, yo, rows

def sprite_frames(prefix):
    """every lump of a 4-letter sprite name: {lump: [(frame, rotation, mirrored)]}"""
    out = {}
    for n in sorted(sprite_offsets()):
        if n[:4] != prefix.upper():
            continue
        views = [(n[4], int(n[5]), False)]
        if len(n) == 8:
            views.append((n[6], int(n[7]), True))
        out[n] = views
    return out

# ----------------------------------------------------------------------------
def level_assets(lev):
    """textures and flats a level actually uses"""
    tex = set()
    for s in lev.sidedefs:
        for t in (s.upper, s.lower, s.middle):
            if t != "-":
                tex.add(t)
    flats = {s.floorpic for s in lev.sectors} | {s.ceilpic for s in lev.sectors}
    return sorted(tex), sorted(flats)

def selftest(mapname="e1m1"):
    lev = load_level(mapname)
    print(f"{lev.name}: {len(lev.things)} things, {len(lev.linedefs)} linedefs, {len(lev.sidedefs)} sidedefs, "
          f"{len(lev.vertexes)} vertexes, {len(lev.segs)} segs, {len(lev.subsectors)} subsectors, "
          f"{len(lev.nodes)} nodes, {len(lev.sectors)} sectors, reject {len(lev.reject)} B, blockmap {len(lev.blockmap)} B")
    pp, cm = playpal(), colormap()
    print(f"PLAYPAL {len(pp)} palettes, COLORMAP {len(cm)} maps")
    assert cm[0] == list(range(256)) or len(set(cm[0])) > 200          # map 0 is (close to) the identity
    # every node child points at a real node or subsector
    for n in lev.nodes:
        for c in (n.right, n.left):
            assert (c & 0x7FFF) < (len(lev.subsectors) if c & 0x8000 else len(lev.nodes))
    tex, flats = level_assets(lev)
    for t in tex:
        w, h, rows = texture(t)
        assert len(rows) == h and len(rows[0]) == w
    for f in flats:
        if f.startswith("F_SKY"):
            continue
        flat(f)
    print(f"{len(tex)} wall textures and {len(flats)} flats composed")
    for p in ("POSS", "SPOS", "TROO", "SARG"):
        fr = sprite_frames(p)
        for n in fr:
            sprite(n)
        print(f"  sprite {p}: {len(fr)} lumps, {sum(len(v) for v in fr.values())} views")
    print("selftest ok")

if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "selftest":
        selftest(*(sys.argv[2:3]))
    else:
        print(__doc__); sys.exit(2)
