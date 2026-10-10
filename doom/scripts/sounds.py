#!/usr/bin/env python3
"""
sounds.py - Freedoom's sound effects, made small enough for a 6-bit DAC.

Every sound is one of Freedoom's WAVs (8-bit PCM, 11025 or 22050 Hz), resampled to the CoCo's rate (the GIME
timer fires every SND_LINES scanlines, FIRQ -> $FF20), low-pass filtered, soft-limited and quantised to the
DAC's six bits (the low two bits of $FF20 stay 0).  Two names that use the same WAV share its bytes on the disk.

The boot can still sing square-wave sounds from tick lists (voice_forge in doom.asm, synth() below is the same
arithmetic), but Freedoom needs none: its PC-speaker sounds need DOOM's own frequency table, which is not ours.

The sound number IS its priority: a request replaces the playing sound only if its number is not lower
(the engine compares two bytes).  Sounds are packed whole into 8 KB pages; the engine copies them through
window W6 into a 256-byte ring that the FIRQ handler drains.

    python3 scripts/sounds.py OUTDIR   writes OUTDIR/*.wav previews of what the CoCo plays
"""
import os, struct, sys, wave
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wad

LINE_HZ = 15734.26                  # NTSC horizontal rate: the GIME timer counts scanlines
SND_LINES = 4                       # one sample every 4 lines
FS = LINE_HZ / SND_LINES            # ~3934 Hz
SILENCE = 0x80
PC_TICK = 140.0                     # sung sounds advance 140 times a second
PIT_HZ = 1193181.0
TICK_8_8 = round(FS / PC_TICK * 256)        # samples per tick, 8.8 (28.1): boot adds the fraction each tick
SYN_LEVELS = (0x28, 0x54, 0x80, 0xAC, 0xD8) # 0..4 high quarters of a sample -> DAC byte

# (equate name, Freedoom WAV, longest seconds kept)    -- in rising priority
SOUNDS = [
    ("SND_DOOR",        "dsdoropn", 0.80),
    ("SND_PUNCH",       "dspunch",  0.30),
    ("SND_PISTOL",      "dspistol", 0.45),
    ("SND_SHOTGUN",     "dsshotgn", 0.60),
    ("SND_CHAINGUN",    "dspistol", 0.30),
    ("SND_FOEFIRE",     "dspistol", 0.45),     # a monster's shot
    ("SND_SIGHT",       "dsposit1", 0.90),     # a monster saw the player
    ("SND_AMMO",        "dsitemup", 0.25),
    ("SND_STIM",        "dsitemup", 0.25),
    ("SND_MEDKIT",      "dsitemup", 0.25),
    ("SND_BONUS1",      "dsitemup", 0.25),
    ("SND_BONUS2",      "dsitemup", 0.25),
    ("SND_BONUS3",      "dsitemup", 0.25),
    ("SND_BONUS4",      "dsitemup", 0.25),
    ("SND_KEY",         "dsitemup", 0.25),
    ("SND_GETSHOTGUN",  "dswpnup",  0.55),
    ("SND_GETCHAINGUN", "dswpnup",  0.55),
    ("SND_DEATH1",      "dspodth1", 0.80),
    ("SND_DEATH2",      "dspodth2", 0.75),
    ("SND_ONEUP",       "dsgetpow", 0.45),
    ("SND_PLDEATH",     "dspldeth", 0.75),
    ("SND_LEVEL",       "dsswtchx", 0.40),
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


def read_wav(name):
    with wave.open(os.path.join(wad.FREEDOOM, "sounds", name + ".wav"), "rb") as w:
        rate, width, ch = w.getframerate(), w.getsampwidth(), w.getnchannels()
        raw = w.readframes(w.getnframes())
    x = (np.frombuffer(raw, np.uint8).astype(float) - 128.0) / 128.0 if width == 1 else \
        np.frombuffer(raw, "<i2").astype(float) / 32768.0
    return resample(x[::ch], rate, FS)


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
    """-> [(name, samples, steps)]: steps is None for a stored sound, else the tick list the boot sings"""
    cache = {}
    out = []
    for name, src, keep in SOUNDS:
        if (src, keep) not in cache:
            cache[(src, keep)] = finish(read_wav(src), keep)
        out.append((name, cache[(src, keep)], None))
    return out


def pack(sounds, page0):
    """first-fit into 8 KB pages, stored sounds first -> (page images holding the stored sounds, table rows
    (page, addr, len) in sound order).  The sung sounds only take room: the boot writes them."""
    pages, rows = [], {}
    order = [i for i, x in enumerate(sounds) if x[2] is None] + [i for i, x in enumerate(sounds) if x[2] is not None]
    for i in order:
        name, data, steps = sounds[i]
        assert len(data) <= 8192
        same = next((j for j in rows if sounds[j][1] == data and sounds[j][2] is None and steps is None), None)
        if same is not None:                                    # the same samples: share them
            rows[i] = rows[same]
            continue
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
