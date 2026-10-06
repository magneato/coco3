#!/usr/bin/env python3
# Copyright (c) 2026 Neural Splines LLC. Code: Clear BSD licence (LICENSE). Neural Splines technology, including
# Bresenham Gradient Descent, is protected by patents and pending patent applications: no patent licence is
# granted; personal, educational and non-commercial use is permitted (see PATENTS.md in the repository root).
"""
nsxdata.py - data, model files and the bit-exact reference model for NSX6809 (NSX86 on the CoCo 3).

    nsxdata.py data  OUTDIR [--ntrain N]   MNIST (data/TRAIN.IDX ..., from ./get_mnist.sh) -> OUTDIR/MNIST.DAT,
                                           OUTDIR/GALLERY.DAT and an untrained OUTDIR/MODEL0.NSX
    nsxdata.py train MODEL.NSX DATDIR      train in Python exactly as MNSTTRN does on the CoCo (same bits)
    nsxdata.py eval  MODEL.NSX DATDIR      accuracy on MNIST.DAT's test records (and the full 10,000 test set)
    nsxdata.py show  MODEL.NSX             the model header

Everything here is integer arithmetic chosen so the 6809 can do the same thing exactly; mnsttrn.asm and
mnstinfr.asm implement these functions instruction by instruction, and test/verify.sh checks that a
model trained on the (emulated) CoCo is byte-identical to one trained here.

THE NETWORK  (Q8.8 fixed point everywhere, as in NSX86)
  input   144 bits: the digit, normalised like MNIST (fit in 20x20, centred by mass in 28x28), pooled 2x2
          to 14x14 (a cell is on when its four 0-3 levels sum to 6 or more), border dropped -> 12x12
  hidden  32 units:  z1 = b1 + sum of the W1 rows of the lit inputs (additions only: the input is binary)
                     h  = clamp(z1 >> 2, 0, 255)       (ReLU, Q2.6 in one byte)
  output  10 units:  z2 = b2 + sum_j sgn(W2) * ((h_j * |W2|) >> 6)     (16-bit wrap, as the 6809 adds)
  softmax e_k = EXP[(max z2 - z2_k) >> 2] (NSX86's EXP256 table, 0 past its end), R = (2^24-1) // sum e,
          p_k = (e_k * R) >> 16      (one division per sample)

BRESENHAM GRADIENT DESCENT (NSX86's BGD, made exact)
  Every parameter W has an error accumulator E (0 .. 2^K-1).  A gradient g is diffused into it like a
  Bresenham error term:  D = E + g;  W -= D >> K (floor);  E = D mod 2^K.  Over time W moves by exactly
  -sum(g) / 2^K: stochastic gradient descent with learning rate 2^-K and no rounding drift, on 16-bit
  integer weights.  K = 5, 5, 6, 6 over four epochs.
"""
import os, sys, math, struct, random

NIN, NH, NOUT = 144, 32, 10
REC = 19                                    # label + 18 bytes of bits
NTEST = 1000
GALLERY_PER_DIGIT = 10
SEED = 1984                                 # NSX86's example seed (/SEED 1984)
KSCHED = [5, 5, 6, 6]
EXP = [int(round(math.exp(-i / 64.0) * 256)) for i in range(256)]   # NSX86's gen_exp_lut.py, EXP256.LUT
HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.normpath(os.path.join(HERE, "..", "data"))      # where get_mnist.sh leaves TRAIN.IDX ...

# ------------------------------------------------------------------------------------------------
# MNIST and the shared preprocessing
# ------------------------------------------------------------------------------------------------
def read_idx(name):
    path = os.path.join(DATA_DIR, name)
    if not os.path.exists(path):
        sys.exit("nsxdata.py: %s missing - run ./get_mnist.sh first" % path)
    raw = open(path, "rb").read()
    if raw[2] == 8 and raw[3] == 3:
        n = struct.unpack(">I", raw[4:8])[0]
        return [raw[16 + 784 * i: 16 + 784 * (i + 1)] for i in range(n)]
    return list(raw[8:])

def levels(img):                            # 0-255 grey -> 0-3
    return [(g * 3 + 127) // 255 for g in img]

def normalize(L):
    """28x28 levels -> 28x28 levels: the ink's bounding box scaled (nearest neighbour) so its longer side
    is 20, then placed so its centre of mass sits on (14, 14).  Integer only; mnstinfr.asm does the same."""
    xs = [i % 28 for i in range(784) if L[i]]
    ys = [i // 28 for i in range(784) if L[i]]
    if not xs:
        return [0] * 784
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    s = max(w, h)
    W, H = max(1, (w * 20) // s), max(1, (h * 20) // s)
    tmp = [[0] * 20 for _ in range(20)]
    for v in range(H):
        sy = y0 + (v * s) // 20
        for u in range(W):
            tmp[v][u] = L[sy * 28 + x0 + (u * s) // 20]
    M = sum(sum(r) for r in tmp)
    Mx = sum(tmp[v][u] * u for v in range(20) for u in range(20))
    My = sum(tmp[v][u] * v for v in range(20) for u in range(20))
    ox = 14 - (2 * Mx + M) // (2 * M)
    oy = 14 - (2 * My + M) // (2 * M)
    out = [0] * 784
    for v in range(20):
        for u in range(20):
            X, Y = u + ox, v + oy
            if 0 <= X < 28 and 0 <= Y < 28:
                out[Y * 28 + X] = tmp[v][u]
    return out

def pool(N):                                # 28x28 levels -> 144 input bits (12x12)
    bits = []
    for r in range(12):
        for c in range(12):
            y, x = 2 * r + 2, 2 * c + 2
            s = N[y * 28 + x] + N[y * 28 + x + 1] + N[(y + 1) * 28 + x] + N[(y + 1) * 28 + x + 1]
            bits.append(1 if s >= 6 else 0)
    return bits

def pack_bits(bits):
    return bytes(sum(bits[8 * i + b] << (7 - b) for b in range(8)) for i in range(18))

def unpack_bits(b18):
    return [(b18[i // 8] >> (7 - i % 8)) & 1 for i in range(NIN)]

def features(img):
    return pool(normalize(levels(img)))

# ------------------------------------------------------------------------------------------------
# The model
# ------------------------------------------------------------------------------------------------
def w16(x):
    return ((x + 0x8000) & 0xFFFF) - 0x8000

class LFSR:                                 # NSX86's lfsr_random, word for word (tap 0xB400)
    def __init__(self, seed):
        self.s = seed or 0xDEAD
    def __call__(self):
        v = self.s
        a = v ^ (v >> 1) ^ (v >> 2) ^ (v >> 5) ^ (v >> 6)
        n = v >> 1
        if v & 1:
            n ^= 0xB400
        self.s = n
        return a & 0xFFFF

class Net:
    def __init__(self, seed=SEED):
        r = LFSR(seed)
        self.seed = seed
        self.W1 = [[(r() & 63) - 32 for j in range(NH)] for i in range(NIN)]      # W1[input][hidden]
        self.W2 = [[(r() & 127) - 64 for j in range(NH)] for k in range(NOUT)]    # W2[output][hidden]
        self.b1, self.b2 = [0] * NH, [0] * NOUT
        self.E1 = [[0] * NH for i in range(NIN)]
        self.E2 = [[0] * NH for k in range(NOUT)]
        self.Eb1, self.Eb2 = [0] * NH, [0] * NOUT
        self.epochs, self.k, self.test_acc, self.train_acc, self.ntrain, self.trained = 0, KSCHED[0], 0, 0, 0, 0

    def forward(self, bits):
        z1 = list(self.b1)
        for i in range(NIN):
            if bits[i]:
                row = self.W1[i]
                for j in range(NH):
                    z1[j] = w16(z1[j] + row[j])
        h = [min(255, max(0, z >> 2)) for z in z1]
        z2 = []
        for k in range(NOUT):
            acc = self.b2[k]
            for j in range(NH):
                if h[j]:
                    w = self.W2[k][j]
                    t = ((h[j] * abs(w)) >> 6) & 0xFFFF
                    acc = w16(acc - t if w < 0 else acc + t)
            z2.append(acc)
        return z1, h, z2

    @staticmethod
    def argmax(z2):
        best = 0
        for k in range(1, NOUT):
            if z2[k] > z2[best]:
                best = k
        return best

    @staticmethod
    def softmax(z2):
        m = max(z2)
        e = [EXP[(m - z) >> 2] if ((m - z) >> 2) < 256 else 0 for z in z2]
        R = (2 ** 24 - 1) // sum(e)
        return [(x * R) >> 16 for x in e]

    def _bgd(self, W, E, idx, g, K):
        D = E[idx] + g
        st = D >> K
        W[idx] = w16(W[idx] - st)
        E[idx] = D - (st << K)

    def train1(self, bits, label, K):
        z1, h, z2 = self.forward(bits)
        p = self.softmax(z2)
        d2 = [max(-255, min(255, p[k] - (256 if k == label else 0))) for k in range(NOUT)]
        active = [0 < (z >> 2) < 255 for z in z1]
        d1 = [0] * NH
        for j in range(NH):                  # through the OLD W2
            if active[j]:
                acc = 0
                for k in range(NOUT):
                    if d2[k]:
                        w = self.W2[k][j]
                        t = (abs(d2[k]) * abs(w)) >> 8
                        acc = w16(acc - t if (d2[k] < 0) != (w < 0) else acc + t)
                d1[j] = acc
        for k in range(NOUT):
            if d2[k]:
                for j in range(NH):
                    if h[j]:
                        g = (abs(d2[k]) * h[j]) >> 6
                        self._bgd(self.W2[k], self.E2[k], j, -g if d2[k] < 0 else g, K)
            self._bgd(self.b2, self.Eb2, k, d2[k], K)
        for i in range(NIN):
            if bits[i]:
                for j in range(NH):
                    self._bgd(self.W1[i], self.E1[i], j, d1[j], K)
        for j in range(NH):
            self._bgd(self.b1, self.Eb1, j, d1[j], K)
        return self.argmax(z2) == label

    # ---- MODEL.NSX: 32-byte header (NSX86 style) + big-endian Q8.8 words ----
    def to_bytes(self):
        hdr = bytearray(32)
        hdr[0] = 42
        hdr[1:8] = b"NSX6809"
        hdr[8:16] = b"MNIST8.8"
        hdr[16], hdr[17] = 3, 0
        hdr[18], hdr[19], hdr[20], hdr[21] = NIN, NH, NOUT, self.trained
        hdr[22], hdr[23] = self.epochs, self.k
        struct.pack_into(">HHHH", hdr, 24, self.test_acc, self.train_acc, self.seed, self.ntrain)
        words = [w for row in self.W1 for w in row] + self.b1 + [w for row in self.W2 for w in row] + self.b2
        return bytes(hdr) + struct.pack(">%dh" % len(words), *words)

    @classmethod
    def from_bytes(cls, data):
        assert data[0] == 42 and data[1:8] == b"NSX6809", "not an NSX6809 model"
        net = cls.__new__(cls)
        net.trained, net.epochs, net.k = data[21], data[22], data[23]
        net.test_acc, net.train_acc, net.seed, net.ntrain = struct.unpack_from(">HHHH", data, 24)
        n = NIN * NH + NH + NOUT * NH + NOUT
        w = list(struct.unpack_from(">%dh" % n, data, 32))
        net.W1 = [w[i * NH:(i + 1) * NH] for i in range(NIN)]; o = NIN * NH
        net.b1 = w[o:o + NH]; o += NH
        net.W2 = [w[o + k * NH:o + (k + 1) * NH] for k in range(NOUT)]; o += NOUT * NH
        net.b2 = w[o:o + NOUT]
        return net

MODEL_BYTES = 32 + 2 * (NIN * NH + NH + NOUT * NH + NOUT)

# ------------------------------------------------------------------------------------------------
def build_data(outdir, ntrain):
    timg, tlab = read_idx("TRAIN.IDX"), read_idx("TRAINL.IDX")
    eimg, elab = read_idx("TEST.IDX"), read_idx("TESTL.IDX")
    order = list(range(len(timg)))
    random.Random(SEED).shuffle(order)
    dat = bytearray(b"NSXDATA" + bytes([1]) + struct.pack(">HHB", ntrain, NTEST, REC) + bytes(3))
    for i in order[:ntrain]:
        dat += bytes([tlab[i]]) + pack_bits(features(timg[i]))
    for i in range(NTEST):
        dat += bytes([elab[i]]) + pack_bits(features(eimg[i]))
    open(os.path.join(outdir, "MNIST.DAT"), "wb").write(dat)
    # the gallery: held-out test digits (from index 5000 on), raw 28x28 levels, 2 bits each
    gal = bytearray(b"NSXGALL" + bytes([1, GALLERY_PER_DIGIT]) + bytes(7))
    for d in range(10):
        picked = [i for i in range(5000, len(eimg)) if elab[i] == d][:GALLERY_PER_DIGIT]
        for i in picked:
            L = levels(eimg[i])
            gal += bytes((L[4 * b] << 6) | (L[4 * b + 1] << 4) | (L[4 * b + 2] << 2) | L[4 * b + 3] for b in range(196))
    open(os.path.join(outdir, "GALLERY.DAT"), "wb").write(gal)
    open(os.path.join(outdir, "MODEL0.NSX"), "wb").write(Net().to_bytes())
    print("  MNIST.DAT   %d train + %d test records, %d bytes" % (ntrain, NTEST, len(dat)))
    print("  GALLERY.DAT %d digits, %d bytes" % (10 * GALLERY_PER_DIGIT, len(gal)))
    print("  MODEL0.NSX  untrained (seed %d), %d bytes" % (SEED, MODEL_BYTES))

def load_dat(datdir):
    d = open(os.path.join(datdir, "MNIST.DAT"), "rb").read()
    ntrain, ntest, rec = struct.unpack_from(">HHB", d, 8)
    recs = [(d[16 + rec * i], unpack_bits(d[16 + rec * i + 1:16 + rec * (i + 1)])) for i in range(ntrain + ntest)]
    return recs[:ntrain], recs[ntrain:]

def accuracy(net, recs):
    return sum(net.argmax(net.forward(b)[2]) == l for l, b in recs) / len(recs)

def train(path, datdir, log=print):
    tr, te = load_dat(datdir)
    net = Net()
    net.ntrain = len(tr)
    for ep, K in enumerate(KSCHED):
        net.k = K
        ok = sum(net.train1(b, l, K) for l, b in tr)
        net.epochs, net.trained = ep + 1, 1
        net.train_acc = ok * 1000 // len(tr)
        net.test_acc = sum(net.argmax(net.forward(b)[2]) == l for l, b in te) * 1000 // len(te)
        log("  epoch %d (K=%d): train %.1f%%  test %.1f%%" % (ep + 1, K, net.train_acc / 10, net.test_acc / 10))
    open(path, "wb").write(net.to_bytes())

def show(path):
    net = Net.from_bytes(open(path, "rb").read())
    print("%s: NSX6809 model, %s, %d epoch(s), last K=%d, seed %d, %d training samples, train %.1f%%, test %.1f%%"
          % (path, "trained" if net.trained else "UNTRAINED", net.epochs, net.k, net.seed, net.ntrain,
             net.train_acc / 10, net.test_acc / 10))
    return net

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "data":
        n = int(a[a.index("--ntrain") + 1]) if "--ntrain" in a else 6000
        os.makedirs(a[1], exist_ok=True)
        build_data(a[1], n)
    elif a[0] == "train":
        train(a[1], a[2])
    elif a[0] == "eval":
        net = show(a[1])
        _, te = load_dat(a[2])
        print("  test records in MNIST.DAT: %.2f%%" % (100 * accuracy(net, te)))
        if "--full" in a:
            eimg, elab = read_idx("TEST.IDX"), read_idx("TESTL.IDX")
            ok = sum(net.argmax(net.forward(features(eimg[i]))[2]) == elab[i] for i in range(len(eimg)))
            print("  all 10,000 MNIST test digits: %.2f%%" % (ok / 100))
    elif a[0] == "show":
        show(a[1])
    else:
        sys.exit(__doc__)
