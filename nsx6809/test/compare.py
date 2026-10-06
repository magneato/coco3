#!/usr/bin/env python3
"""compare.py DUMP N DATDIR - the trainer's RAM after N samples (W0 + $8000-$BFFF, from test/watch.lua) against
tools/nsxdata.py's reference after the same N samples: the last sample's intermediates, then every parameter."""
import sys, struct, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import nsxdata as N
dump, n, datdir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ram = open(dump, "rb").read()
w0, hi = ram[:0x2000], ram[0x2000:]
def words(buf, off, cnt, base=0): return list(struct.unpack_from(">%dh" % cnt, buf, off - base))
tr, te = N.load_dat(datdir)
net = N.Net()
for i in range(n - 1):
    net.train1(tr[i][1], tr[i][0], N.KSCHED[0])
lab, bits = tr[n - 1]
z1, h, z2 = net.forward(bits)
p = net.softmax(z2)
d2 = [max(-255, min(255, p[k] - (256 if k == lab else 0))) for k in range(10)]
net2 = N.Net.from_bytes(net.to_bytes())          # (d1 through the weights before this sample's update)
d1 = []
for j in range(32):
    a = 0
    if 0 < (z1[j] >> 2) < 255:
        for k in range(10):
            if d2[k]:
                w = net.W2[k][j]; t = (abs(d2[k]) * abs(w)) >> 8
                a = N.w16(a - t if (d2[k] < 0) != (w < 0) else a + t)
    d1.append(a)
net.train1(bits, lab, N.KSCHED[0])
def cmp(name, got, want):
    bad = [i for i, (a, b) in enumerate(zip(got, want)) if a != b]
    print("%-6s %s" % (name, "OK" if not bad else "DIFFER at %s: coco %s ref %s" % (bad[:6], [got[i] for i in bad[:6]], [want[i] for i in bad[:6]])))
    return not bad
ok = True
ok &= cmp("z1", words(w0, 0x0D20, 32), z1)
ok &= cmp("h", list(w0[0x0D60:0x0D80]), h)
ok &= cmp("z2", words(w0, 0x0D80, 10), z2)
ok &= cmp("p", list(w0[0x0DA8:0x0DB2]), p)
ok &= cmp("d2", words(w0, 0x0DB2, 10), d2)
ok &= cmp("d1", words(w0, 0x0DC6, 32), d1)
model = N.Net.from_bytes(hi[:N.MODEL_BYTES])
ok &= cmp("W1", [w for r in model.W1 for w in r], [w for r in net.W1 for w in r])
ok &= cmp("b1", model.b1, net.b1)
ok &= cmp("W2", [w for r in model.W2 for w in r], [w for r in net.W2 for w in r])
ok &= cmp("b2", model.b2, net.b2)
E1 = 0xA700 - 0x8000
ok &= cmp("E1", list(hi[E1:E1 + 4608]), [e for r in net.E1 for e in r])
ok &= cmp("Eb1", list(hi[E1 + 4608:E1 + 4640]), net.Eb1)
ok &= cmp("E2", list(hi[E1 + 4640:E1 + 4960]), [e for r in net.E2 for e in r])
ok &= cmp("Eb2", list(hi[E1 + 4960:E1 + 4970]), net.Eb2)
print("IDENTICAL after %d samples" % n if ok else "MISMATCH after %d samples" % n)
sys.exit(0 if ok else 1)
