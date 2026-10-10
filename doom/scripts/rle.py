#!/usr/bin/env python3
"""
rle.py - the disk's packing: PackBits run-length coding, made lossy in a way the eye forgives.

Format (what forge_pages in doom.asm unpacks):
  control 0..127    the next (control + 1) bytes are literals
  control 128..255  the next byte, repeated (control - 125) times (3..130)

The data are DOOM palette numbers in column order (one texel column after another), so a run is a vertical
stretch of one colour.  lossy() lengthens runs before packing: a texel joins the run above it when the two
colours are closer than a perceptual threshold (squared OKLab distance, palette.dist2, of the colours COLORMAP
level 0 gives them).  Transparency (a reserved index) never merges with a colour, and a run never crosses the
top of a column, so edges and silhouettes stay exact.

Usage:  python3 scripts/rle.py selftest
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def pack(data):
    """PackBits: runs of 3+ equal bytes become (count, byte), everything else literal groups of up to 128"""
    data = bytes(data)
    out, lit, i, n = bytearray(), bytearray(), 0, len(data)
    def flush():
        while lit:
            chunk = lit[:128]
            out.append(len(chunk) - 1); out.extend(chunk)
            del lit[:128]
    while i < n:
        j = i
        while j < n and j - i < 130 and data[j] == data[i]:
            j += 1
        if j - i >= 3:
            flush()
            out.append(j - i + 125); out.append(data[i])
            i = j
        else:
            lit.append(data[i]); i += 1
    flush()
    return bytes(out)

def unpack(blob, length):
    """the 6809's loop, in Python"""
    out, i = bytearray(), 0
    while len(out) < length:
        c = blob[i]; i += 1
        if c < 128:
            out += blob[i:i + c + 1]; i += c + 1
        else:
            out += bytes([blob[i]]) * (c - 125); i += 1
    assert len(out) == length, (len(out), length)
    return bytes(out)

def lossy(data, column, distance, threshold, keep=()):
    """merge each byte into the run above it (same column) when distance(a, b) < threshold.
    keep: values that only ever match themselves (transparency)."""
    out = bytearray(data)
    for i in range(1, len(out)):
        if i % column == 0:
            continue
        a, b = out[i - 1], out[i]
        if a == b or a in keep or b in keep:
            continue
        if distance(a, b) < threshold:
            out[i] = a
    return bytes(out)

def selftest():
    import random
    random.seed(1984)
    for _ in range(200):
        n = random.randint(1, 3000)
        d = bytes(random.choice([0, 0, 0, 7, random.randint(0, 255)]) for _ in range(n))
        assert unpack(pack(d), n) == d
    assert pack(b"\x05" * 130) == bytes([255, 5])
    assert pack(b"\x05\x05") == bytes([1, 5, 5])
    print("rle selftest ok")

if __name__ == "__main__":
    if sys.argv[1:2] == ["selftest"]:
        selftest()
    else:
        print(__doc__); sys.exit(2)
