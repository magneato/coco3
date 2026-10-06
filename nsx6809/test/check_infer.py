#!/usr/bin/env python3
"""check_infer.py MODEL.NSX DUMP... - for each W0 dump taken after ENTER (test/ui.lua): the 6809's canvas,
run through tools/nsxdata.py's normalize/pool/forward, must give the same 144 input bits, the same 10
output sums and the same answer as the 6809 computed."""
import sys, os, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import nsxdata as N
net = N.Net.from_bytes(open(sys.argv[1], "rb").read())
bad = 0
for path in sys.argv[2:]:
    w0 = open(path, "rb").read()
    canvas = list(w0[0x0400:0x0400 + 784])
    bits = N.pool(N.normalize(canvas))
    got_bits = N.unpack_bits(w0[0x0BB0:0x0BB0 + 18])
    z2 = net.forward(bits)[2]
    got_z2 = list(struct.unpack_from(">10h", w0, 0x0D80))
    p = net.softmax(z2)
    got_p = list(w0[0x0DA8:0x0DB2])
    ok = bits == got_bits and z2 == got_z2 and p == got_p
    bad += not ok
    print("%s: answer %d (%3d%%)  bits %s  z2 %s  p %s" % (os.path.basename(path), N.Net.argmax(z2), p[N.Net.argmax(z2)] * 100 >> 8,
          "ok" if bits == got_bits else "DIFFER", "ok" if z2 == got_z2 else "DIFFER", "ok" if p == got_p else "DIFFER"))
print("PASS: the 6809's answers are bit-exact" if not bad else "FAIL: %d mismatch(es)" % bad)
sys.exit(1 if bad else 0)
