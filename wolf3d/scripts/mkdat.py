#!/usr/bin/env python3
"""
mkdat.py - assemble WOLF3D.DAT from the page images gen_assets.py wrote into build/parts/ plus the
assembled code2 page (build/code2.bin).  Layout (page order, sector counts) comes from build/dat_layout.txt.
usage: mkdat.py BUILD_DIR
"""
import os, sys
build = sys.argv[1]
SEC = 256
out = bytearray()
for line in open(os.path.join(build, "dat_layout.txt")):
    name, nsec = line.split()
    nsec = int(nsec)
    if name == "CODE2":
        data = open(os.path.join(build, "code2.bin"), "rb").read()
        assert len(data) <= 8192, f"code2 is {len(data)} bytes, its page holds 8192"
        print(f"  code2: {len(data)} of 8192 bytes used")
    else:
        data = open(os.path.join(build, "parts", name + ".bin"), "rb").read()
    assert len(data) <= nsec * SEC, (name, len(data), nsec)
    out += data + bytes(nsec * SEC - len(data))
open(os.path.join(build, "WOLF3D.DAT"), "wb").write(out)
print(f"  WOLF3D.DAT: {len(out)} bytes ({len(out) // SEC} sectors)")
