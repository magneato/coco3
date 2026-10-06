#!/usr/bin/env python3
"""
mkdsk.py - lay one or more files onto a floppy image in the exact order the natives' RS-DOS expects (JVC format).

    mkdsk.py OUT.DSK NAME.EXT:TYPE=FILE [NAME.EXT:TYPE=FILE ...]
        TYPE  0 BASIC  1 data  2 machine-language (DECB .BIN)  (default 2)

Why not imgtool?  imgtool allocates file data from granule 0 (track 0), which makes this MAME's Disk
BASIC come up with a blank screen.  Real RS-DOS (and toolshed's decb) start at granule 34, next to the
directory track, and then spiral outward - the same order is used here (and verified byte-for-byte
against a disk made by real tools).  Files are allocated in the order given, so the first file always
starts at granule 34: the game's boot loader relies on that to find WOLF3D.DAT without a directory.

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

def main():
    out = sys.argv[1]
    files = []
    for arg in sys.argv[2:]:
        left, _, path = arg.partition("=")
        name, _, ftype = left.partition(":")
        files.append((name, int(ftype or 2), open(path, "rb").read()))
    img, chains = build(files)
    open(out, "wb").write(img)
    for (name, _, data), g in zip(files, chains):
        print(f"  {out}: {name.upper()} {len(data)} bytes in granules {g}")

if __name__ == "__main__":
    main()
