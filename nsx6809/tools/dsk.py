#!/usr/bin/env python3
"""
dsk.py - RS-DOS (Disk Extended Color BASIC) floppy images: make one, read a file out, write a file back.

    dsk.py make OUT.DSK NAME.EXT:TYPE=FILE [NAME.EXT:TYPE=FILE ...]
        TYPE  0 BASIC  1 data  2 machine-language (DECB .BIN)  (default 2)
    dsk.py get  IMAGE.DSK NAME.EXT OUT_FILE      copy a file out of an image
    dsk.py put  IMAGE.DSK NAME.EXT IN_FILE       overwrite a file's contents in place (it must fit the
                                                 granules already allocated to it); the directory's
                                                 last-sector byte count is updated
    dsk.py ls   IMAGE.DSK

Why not imgtool?  imgtool allocates file data from granule 0 (track 0), which makes this MAME's Disk
BASIC come up with a blank screen.  Real RS-DOS (and toolshed's decb) start at granule 34, next to the
directory track, and then spiral outward - the same order is used here (and verified byte-for-byte
against a disk made by real tools).  Files are allocated in the order given, so the first file always
starts at granule 34.

Geometry: 35 tracks x 18 sectors x 256 bytes, no JVC header (161280 bytes).
Track 17 is the directory track and is skipped by the 68-entry granule numbering:
granule g -> track g//2 (g < 34) or g//2 + 1 (g >= 34); sectors 1-9 (g even) or 10-18 (g odd).
FAT = track 17 sector 2, directory = track 17 sectors 3-11.
"""
import sys

TRACKS, SECS, SEC = 35, 18, 256
SEC_PER_GRAN = 9

# allocation order (matches toolshed): 34,35 then 32,33 ... 0,1 then 36,37 ... 66,67
ORDER = [34, 35] + [g for p in range(16, -1, -1) for g in (p * 2, p * 2 + 1)] \
        + [g for p in range(18, 34) for g in (p * 2, p * 2 + 1)]
assert sorted(ORDER) == list(range(68))

def granule_track(g):
    return g // 2 + (1 if g >= 34 else 0)

def granule_first_sector(g):
    return 1 if g % 2 == 0 else 10

def sector_off(track, sector):          # sector is 1-based
    return (track * SECS + (sector - 1)) * SEC

def build(files):
    """files: [(name, type, bytes)] -> (image, [granule chain per file])"""
    img = bytearray(b"\xFF" * (TRACKS * SECS * SEC))
    fat_off = sector_off(17, 2)
    dir_off = sector_off(17, 3)
    fat = bytearray(b"\xFF" * 68)
    # DECB formats track 17 sector 1 and the unused tail of the FAT sector with zeros
    img[sector_off(17, 1):sector_off(17, 1) + SEC] = bytes(SEC)
    img[fat_off:fat_off + SEC] = bytes(SEC)
    nxt = 0
    chains = []
    for idx, (name, ftype, data) in enumerate(files):
        nsec = (len(data) + SEC - 1) // SEC
        ngran = (nsec + SEC_PER_GRAN - 1) // SEC_PER_GRAN
        assert nxt + ngran <= len(ORDER), "disk full"
        grans = ORDER[nxt:nxt + ngran]
        nxt += ngran
        chains.append(grans)
        pos = 0
        for g in grans:
            track, first = granule_track(g), granule_first_sector(g)
            for s in range(SEC_PER_GRAN):
                chunk = data[pos:pos + SEC]
                if not chunk:
                    break
                o = sector_off(track, first + s)
                img[o:o + len(chunk)] = chunk
                pos += SEC
        for i, g in enumerate(grans):
            fat[g] = grans[i + 1] if i + 1 < len(grans) else 0xC0 + (nsec - (ngran - 1) * SEC_PER_GRAN)
        base, _, ext = name.upper().partition(".")
        last_bytes = len(data) - (nsec - 1) * SEC
        entry = bytearray(32)
        entry[0:8] = base.ljust(8).encode()
        entry[8:11] = ext.ljust(3).encode()
        entry[11] = ftype
        entry[12] = 0
        entry[13] = grans[0]
        entry[14] = last_bytes >> 8
        entry[15] = last_bytes & 0xFF
        img[dir_off + 32 * idx:dir_off + 32 * idx + 32] = entry
    img[fat_off:fat_off + 68] = fat
    return img, chains


def _dir(img):
    """-> [(index, name, type, first granule, last-sector bytes)]"""
    out = []
    for i in range(72):
        e = img[sector_off(17, 3) + 32 * i: sector_off(17, 3) + 32 * i + 32]
        if e[0] in (0x00, 0xFF):
            continue
        name = e[0:8].decode().rstrip() + "." + e[8:11].decode().rstrip()
        out.append((i, name, e[11], e[13], e[14] * 256 + e[15]))
    return out

def _chain(img, first):
    fat = img[sector_off(17, 2): sector_off(17, 2) + 68]
    secs, g = [], first
    while True:
        nxt = fat[g]
        track, s0 = granule_track(g), granule_first_sector(g)
        n = (nxt & 0x1F) if nxt >= 0xC0 else SEC_PER_GRAN
        secs += [(track, s0 + s) for s in range(n)]
        if nxt >= 0xC0:
            return secs, g
        g = nxt

def _find(img, name):
    for i, n, t, g, lb in _dir(img):
        if n == name.upper():
            return i, g, lb
    sys.exit("dsk.py: %s not on the disk" % name)

def get(path, name):
    img = open(path, "rb").read()
    _, g, lb = _find(img, name)
    secs, _ = _chain(img, g)
    data = b"".join(img[sector_off(t, s): sector_off(t, s) + SEC] for t, s in secs)
    return data[:(len(secs) - 1) * SEC + lb]

def put(path, name, data):
    img = bytearray(open(path, "rb").read())
    i, g, _ = _find(img, name)
    secs, _ = _chain(img, g)
    need = (len(data) + SEC - 1) // SEC
    if need != len(secs):
        sys.exit("dsk.py: %s holds %d sectors, the new data needs %d" % (name, len(secs), need))
    for k, (t, s) in enumerate(secs):
        chunk = data[k * SEC:(k + 1) * SEC]
        o = sector_off(t, s)
        img[o:o + len(chunk)] = chunk
    lb = len(data) - (need - 1) * SEC
    d = sector_off(17, 3) + 32 * i
    img[d + 14], img[d + 15] = lb >> 8, lb & 0xFF
    open(path, "wb").write(img)

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "make":
        out = sys.argv[2]
        files = []
        for arg in sys.argv[3:]:
            left, _, path = arg.partition("=")
            name, _, ftype = left.partition(":")
            files.append((name, int(ftype or 2), open(path, "rb").read()))
        img, chains = build(files)
        open(out, "wb").write(img)
        for (name, _, data), g in zip(files, chains):
            print(f"  {out}: {name.upper()} {len(data)} bytes in granules {g}")
    elif cmd == "get":
        open(sys.argv[4], "wb").write(get(sys.argv[2], sys.argv[3]))
    elif cmd == "put":
        put(sys.argv[2], sys.argv[3], open(sys.argv[4], "rb").read())
    elif cmd == "ls":
        img = open(sys.argv[2], "rb").read()
        for i, n, t, g, lb in _dir(img):
            secs, _ = _chain(img, g)
            print("%-12s type %d  %6d bytes  first granule %d" % (n, t, (len(secs) - 1) * SEC + lb, g))
    else:
        sys.exit(__doc__)

if __name__ == "__main__":
    main()
