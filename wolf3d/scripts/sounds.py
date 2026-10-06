#!/usr/bin/env python3
"""
sounds.py - the natives' noises, made small enough for a 6-bit DAC.

Two sources in the original files:
  * VSWAP.WL6 digitized sounds (8-bit unsigned PCM, 7042 Hz): guns, "Halt!", death screams, the door.
    Resampled to the CoCo's rate (the GIME timer fires every SND_LINES scanlines, FIRQ -> $FF20), low-pass
    filtered, soft-limited and quantised to the DAC's six bits (the low two bits of $FF20 stay 0).  On the disk.
  * AUDIOT.WL6 PC-speaker sounds (one PIT divisor/60 per 1/140 s tick, 0 = silence): pickups, keys, the knife.
    NOT on the disk as samples: each tick is kept as a 16-bit phase step and the boot code sings them again
    (voice_forge in wolf3d.asm: a square wave, four phase steps per sample, the number of 'high' quarters
    picks one of five levels - a box filter against aliasing).  synth() below is the same arithmetic.

The sound number IS its priority: a request replaces the playing sound only if its number is not lower
(the engine compares two bytes).  Sounds are packed whole into 8 KB pages; the engine copies them through
window W6 into a 256-byte ring that the FIRQ handler drains.

    python3 scripts/sounds.py OUTDIR   writes OUTDIR/*.wav previews of what the CoCo plays
"""
import os, struct, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wolfai

LINE_HZ = 15734.26                  # NTSC horizontal rate: the GIME timer counts scanlines
SND_LINES = 4                       # one sample every 4 lines
FS = LINE_HZ / SND_LINES            # ~3934 Hz
SILENCE = 0x80
PC_TICK = 140.0                     # PC-speaker sounds advance 140 times a second
PIT_HZ = 1193181.0
TICK_8_8 = round(FS / PC_TICK * 256)        # samples per tick, 8.8 (28.1): boot adds the fraction each tick
SYN_LEVELS = (0x28, 0x54, 0x80, 0xAC, 0xD8) # 0..4 high quarters of a sample -> DAC byte

# (equate name, source, index, longest seconds kept: the sung ones are kept whole)    -- in rising priority
SOUNDS = [
    ("SND_DOOR",     "digi", 3,  0.80),     # OPENDOORSND
    ("SND_KNIFE",    "spk",  23, 9.9),     # ATKKNIFESND
    ("SND_PISTOL",   "digi", 5,  0.45),     # ATKPISTOLSND
    ("SND_MGUN",     "digi", 4,  0.40),     # ATKMACHINEGUNSND
    ("SND_CHAIN",    "digi", 6,  0.40),     # ATKGATLINGSND
    ("SND_NAZIFIRE", "digi", 21, 0.50),     # NAZIFIRESND (a sentinel's shot)
    ("SND_HALT",     "digi", 0,  0.90),     # HALTSND ("Halt!": a sentinel saw the traveller)
    ("SND_AMMO",     "spk",  31, 9.9),     # GETAMMOSND
    ("SND_FOOD",     "spk",  33, 9.9),     # HEALTH1SND
    ("SND_MEDKIT",   "spk",  34, 9.9),     # HEALTH2SND
    ("SND_CROSS",    "spk",  35, 9.9),     # BONUS1SND
    ("SND_CHALICE",  "spk",  36, 9.9),     # BONUS2SND
    ("SND_CHEST",    "spk",  37, 9.9),     # BONUS3SND
    ("SND_CROWN",    "spk",  45, 9.9),     # BONUS4SND
    ("SND_KEY",      "spk",  12, 9.9),     # GETKEYSND
    ("SND_GETMG",    "spk",  30, 9.9),     # GETMACHINESND
    ("SND_GETCHAIN", "spk",  38, 9.9),     # GETGATLINGSND
    ("SND_DEATH1",   "digi", 12, 0.45),     # DEATHSCREAM1SND
    ("SND_DEATH2",   "digi", 13, 0.55),     # DEATHSCREAM2SND
    ("SND_ONEUP",    "spk",  44, 9.9),     # BONUS1UPSND
    ("SND_PLDEATH",  "spk",  9,  9.9),     # PLAYERDEATHSND
    ("SND_LEVEL",    "spk",  40, 9.9),     # LEVELDONESND
]


def lowpass(x, rate, cut, taps=63):
    """windowed-sinc FIR, cut in Hz"""
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * cut / rate * n) * np.hamming(taps)
    h /= h.sum()
    return np.convolve(x, h, mode="same")


def resample(x, src, dst):
    x = lowpass(x, src, 0.45 * dst)
    t = np.arange(0, len(x) * dst / src) * src / dst
    return np.interp(t, np.arange(len(x)), x)


def digi(vs, pairs, i):
    page, length = pairs[i]
    off = vs.offs[vs.sound_start + page]
    x = np.frombuffer(vs.d[off:off + length], np.uint8).astype(float) - 128.0
    return resample(x / 128.0, 7042.0, FS)


def ticks(chunk, keep):
    """PC-speaker chunk -> phase steps per quarter sample (0 = silence), trailing silence dropped"""
    ln = struct.unpack_from("<I", chunk, 0)[0]
    t = list(chunk[6:6 + ln])[:int(keep * PC_TICK)]
    while t and t[-1] == 0:
        t.pop()
    return [0 if v == 0 else round(PIT_HZ / (v * 60.0) / (4 * FS) * 65536) for v in t]


def synth(steps):
    """exactly what voice_forge computes on the 6809"""
    out, ph, frac = bytearray(), 0, 0
    for st in steps:
        frac += TICK_8_8 & 255
        n = (TICK_8_8 >> 8) + (frac >> 8)
        frac &= 255
        for _ in range(n):
            if st == 0:
                out.append(SILENCE)
                continue
            h = 0
            for _ in range(4):
                ph = (ph + st) & 0xFFFF
                h += ph >> 15
            out.append(SYN_LEVELS[h])
    return bytes(out)


def finish(x, keep):
    n = min(len(x), int(keep * FS))
    x = x[:n].copy()
    fade = min(n, int(0.06 * FS))                       # 60 ms fade-out (where a sound is cut short it would click)
    x[n - fade:] *= np.linspace(1, 0, fade)
    peak = np.abs(x).max() or 1.0
    x = np.tanh(1.6 * x / peak) / np.tanh(1.6)          # normalise + soft limit: loud on a 6-bit DAC
    # trim trailing near-silence (it costs disk and ring time)
    q = np.round(x * 31).astype(int)
    nz = np.nonzero(np.abs(q) > 1)[0]
    q = q[:nz[-1] + 1] if len(nz) else q[:1]
    return bytes(((v + 32) << 2) & 0xFC for v in np.clip(q, -32, 31))


def build():
    """-> [(name, samples, steps)]: steps is None for a stored (digitized) sound, else the tick list the boot sings"""
    vs = wolfai.VSwap()
    info = vs.d[vs.offs[vs.nchunks - 1]:vs.offs[vs.nchunks - 1] + vs.lens[vs.nchunks - 1]]
    pairs = [struct.unpack_from("<2H", info, i) for i in range(0, len(info) - 3, 4)]
    hed = wolfai.rd("AUDIOHED.WL6")
    aud = wolfai.rd("AUDIOT.WL6")
    aoff = struct.unpack(f"<{len(hed) // 4}I", hed)
    out = []
    for name, kind, idx, keep in SOUNDS:
        if kind == "digi":
            out.append((name, finish(digi(vs, pairs, idx), keep), None))
        else:
            st = ticks(aud[aoff[idx]:aoff[idx + 1]], keep)
            assert 0 < len(st) < 256
            out.append((name, synth(st), st))
    return out


def build_standin():
    """Generate original chiptune effects for a build that has no game audio files."""
    out = []
    for i, (name, _kind, _idx, _keep) in enumerate(SOUNDS):
        length = 16 + (i % 6) * 5
        start_hz = 125 + (i * 53) % 620
        steps = []
        for tick in range(length):
            if i % 4 == 0 and tick > length * 2 // 3:
                steps.append(0)
                continue
            hz = max(45, start_hz + (tick - length // 2) * (3 + i % 8))
            steps.append(round(PIT_HZ / (hz * 4 * FS) * 65536))
        out.append((name, synth(steps), steps))
    return out


def pack(sounds, page0):
    """first-fit into 8 KB pages, stored sounds first -> (page images holding the stored sounds, table rows
    (page, addr, len) in sound order).  The sung sounds only take room: the boot writes them."""
    pages, rows = [], {}
    order = [i for i, x in enumerate(sounds) if x[2] is None] + [i for i, x in enumerate(sounds) if x[2] is not None]
    for i in order:
        name, data, steps = sounds[i]
        assert len(data) <= 8192
        for p in pages:
            if len(p) + len(data) <= 8192:
                break
        else:
            p = bytearray()
            pages.append(p)
        rows[i] = (page0 + pages.index(p), 0xC000 + len(p), len(data))
        p += data if steps is None else bytes(len(data))
    stored = [bytes(p).rstrip(b"\0") for p in pages]
    return stored, [rows[i] for i in range(len(sounds))]


def wav(path, data):
    pcm = bytes(((b >> 2) - 32) * 4 + 128 for b in data)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " +
                struct.pack("<IHHIIHH", 16, 1, 1, int(FS), int(FS), 1, 8) + b"data" + struct.pack("<I", len(pcm)) + pcm)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "build/snd"
    os.makedirs(out, exist_ok=True)
    for name, data, steps in build():
        wav(os.path.join(out, name.lower() + ".wav"), data)
        print(f"{name:<14} {len(data):5d} B  {len(data) / FS:.2f} s  " + ("stored" if steps is None else f"sung from {len(steps)} ticks"))
