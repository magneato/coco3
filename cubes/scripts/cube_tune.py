#!/usr/bin/env python3
"""
cube_tune.py - the soundtrack of cube.asm, written in tracker notation.

    cube_tune.py              rewrite the SONG block of cube.asm (between the ;;; >>> SONG and ;;; <<< SONG lines)
    cube_tune.py --wav F.wav  also render a preview with a model of the 6809 player (3934 Hz, 6-bit)

The player (in cube.asm) is a tiny tracker in the spirit of the ones demos were scored with:
three channels, each with its own list of 32-row tracks (with a transpose per position, as in AHX),
instruments with an 8-step volume envelope, a pitch slide and a waveform, and arpeggio presets.
It ticks 60 times a second in the vertical-sync interrupt; the mixing happens 3934 times a second
in the GIME timer's fast interrupt.

Row notation:  "A-4 7 1"  note A-4, instrument 7, arpeggio preset 1;   "."  nothing;   "==="  note off.
"""
import os, sys, math, re

RATE = 15734.26 / 4          # one FIRQ every 4 scanlines
SPEED = 6                    # ticks per row at 60 Hz: 10 rows a second, 150 BPM with 4 rows to a beat
ROWS = 32

NOTE_NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
def note_num(s):             # "A-4" -> 57 (C-0 = 0)
    return NOTE_NAMES.index(s[:2]) + 12 * int(s[2])
def note_freq(n):
    return 440.0 * 2 ** ((n - 57) / 12)
STEPS = [min(65535, round(note_freq(n) * 65536 / RATE)) for n in range(96)]

# waveforms (cube.asm builds them at boot): 0 square, 1 pulse 25%, 2 saw, 3 triangle, 4 sine, 5 noise, 6 the cube
# instrument: (name, waveform, slide per tick (subtracted from the step), envelope of 8 volumes 0-7, held at the end)
INSTRUMENTS = [
    None,
    ("bass",   0,   0, [7, 7, 6, 6, 5, 5, 5, 4]),
    ("chord",  1,   0, [6, 6, 5, 5, 4, 4, 3, 3]),
    ("kick",   4, 260, [7, 7, 7, 6, 5, 3, 1, 0]),
    ("snare",  5,   0, [7, 6, 5, 3, 2, 1, 0, 0]),
    ("hat",    5,   0, [4, 2, 1, 0, 0, 0, 0, 0]),
    ("cube",   6,   0, [7, 7, 7, 7, 7, 7, 7, 7]),
    ("lead",   2,   0, [7, 7, 6, 6, 6, 5, 5, 5]),
    ("flute",  3,   0, [5, 6, 7, 7, 7, 6, 6, 6]),
]
ARPS = [(0, 0), (3, 7), (4, 7), (7, 12), (12, 0), (5, 9)]   # 0 none, 1 minor, 2 major, 3 power, 4 octave, 5 sus

def T(text):
    rows = text.split()
    out = []
    i = 0
    while i < len(rows):
        tok = rows[i]
        if tok == ".":
            out.append((0, 0)); i += 1
        elif tok == "===":
            out.append((0xFF, 0)); i += 1
        else:
            n, ins, arp = note_num(tok), int(rows[i + 1]), int(rows[i + 2])
            out.append((n + 1, ins * 16 + arp)); i += 3
    assert len(out) == ROWS, (len(out), text[:40])
    return out

def rep(pattern, times):
    return " ".join([pattern] * times)

TRACKS = {
    "empty":  T(rep(".", 32)),
    # chords: Am F | C G, one bar (16 rows) each
    "bassA":  T(rep("A-2 1 0 . A-3 1 0 .", 4) + " " + rep("F-2 1 0 . F-3 1 0 .", 4)),
    "bassB":  T(rep("C-3 1 0 . C-4 1 0 .", 4) + " " + rep("G-2 1 0 . G-3 1 0 .", 4)),
    "bassA2": T("A-2 1 0 . . A-2 1 0 A-3 1 0 . A-2 1 0 . " * 2 + "F-2 1 0 . . F-2 1 0 F-3 1 0 . F-2 1 0 . " * 2),
    "bassB2": T("C-3 1 0 . . C-3 1 0 C-4 1 0 . C-3 1 0 . " * 2 + "G-2 1 0 . . G-2 1 0 G-3 1 0 . G-2 1 0 . " * 2),
    "hats":   T(rep(". . C-6 5 0 .", 8)),
    "beat":   T(rep("C-3 3 0 . C-6 5 0 . C-6 4 0 . C-6 5 0 . C-3 3 0 . C-6 5 0 C-3 3 0 C-6 4 0 . C-6 5 0 .", 2)),
    "fill":   T("C-3 3 0 . C-6 5 0 . C-6 4 0 . C-6 5 0 . C-3 3 0 . C-6 5 0 C-3 3 0 C-6 4 0 . C-6 5 0 . "
                "C-3 3 0 . C-6 4 0 . C-6 4 0 . C-6 4 0 C-6 4 0 C-3 3 0 C-6 4 0 C-6 4 0 C-6 4 0 C-6 4 0 C-6 4 0 C-6 4 0 C-6 4 0"),
    "kicks":  T(rep("C-3 3 0 . . .", 8)),
    "chordA": T(rep("A-4 2 1 . . . A-4 2 1 . A-4 2 1 .", 2) + " " + rep("F-4 2 2 . . . F-4 2 2 . F-4 2 2 .", 2)),
    "chordB": T(rep("C-5 2 2 . . . C-5 2 2 . C-5 2 2 .", 2) + " " + rep("G-4 2 2 . . . G-4 2 2 . G-4 2 2 .", 2)),
    "padA":   T("A-4 8 1 " + rep(".", 15) + " F-4 8 2 " + rep(".", 15)),
    "padB":   T("C-5 8 2 " + rep(".", 15) + " G-4 8 2 " + rep(".", 15)),
    # the tune
    "melA":   T("E-5 7 0 . . . A-5 7 0 . . . G-5 7 0 . E-5 7 0 . D-5 7 0 . C-5 7 0 . "
                "C-5 7 0 . . . A-4 7 0 . . . C-5 7 0 . D-5 7 0 . E-5 7 0 . . ."),
    "melB":   T("E-5 7 0 . . . G-5 7 0 . . . E-5 7 0 . D-5 7 0 . C-5 7 0 . D-5 7 0 . "
                "B-4 7 0 . . . D-5 7 0 . . . G-4 7 0 . . . B-4 7 0 . D-5 7 0 ."),
    "melA2":  T("A-5 7 0 . G-5 7 0 . E-5 7 0 . G-5 7 0 . A-5 7 0 . . . C-6 7 0 . B-5 7 0 . "
                "A-5 7 0 . . . F-5 7 0 . . . A-5 7 0 . C-6 7 0 . A-5 7 0 . . ."),
    "melB2":  T("G-5 7 0 . . . E-5 7 0 . G-5 7 0 . C-6 7 0 . . . B-5 7 0 . G-5 7 0 . "
                "D-5 7 0 . . . G-5 7 0 . . . B-5 7 0 . . . D-6 7 0 . . ==="),
    "arpA":   T(rep("A-4 2 1 .", 4) + " " + rep("A-5 2 1 .", 4) + " " + rep("F-4 2 2 .", 4) + " " + rep("F-5 2 2 .", 4)),
    "arpB":   T(rep("C-5 2 2 .", 4) + " " + rep("C-6 2 2 .", 4) + " " + rep("G-4 2 2 .", 4) + " " + rep("G-5 2 2 .", 4)),
    "end":    T("A-2 1 4 " + rep(".", 30) + " ==="),
}
CUBE = 6

def cube(track):              # the same notes, sung by the cube
    return [(n, CUBE * 16 + (ia & 15)) if n not in (0, 0xFF) else (n, ia) for n, ia in track]
for k in ("melA", "melB", "melA2", "melB2", "padA", "padB"):
    TRACKS["c_" + k] = cube(TRACKS[k])

# positions: (bass, drums, top) as (track, transpose).  Position 0 plays under the title; the song
# then loops from position 1.  cube.asm's script changes phase on these boundaries.
A, B = 0, 1
ORDER = [
    (("empty", 0), ("hats", 0), ("padA", 0)),          # 0  title
    (("bassA", 0), ("hats", 0), ("chordA", 0)),        # 1  8 corner dots
    (("bassB", 0), ("hats", 0), ("chordB", 0)),        # 2
    (("bassA", 0), ("beat", 0), ("arpA", 0)),          # 3  edge dots
    (("bassB", 0), ("beat", 0), ("arpB", 0)),          # 4  surface dots
    (("bassA2", 0), ("beat", 0), ("c_melA", 0)),       # 5  jelly: the cube sings
    (("bassB2", 0), ("beat", 0), ("c_melB", 0)),       # 6
    (("bassA2", 0), ("fill", 0), ("c_melA2", 0)),      # 7
    (("bassB", 0), ("beat", 0), ("arpB", 0)),          # 8  surface dots
    (("bassA", 0), ("beat", 0), ("melA", 0)),          # 9  edge dots
    (("bassB", 0), ("fill", 0), ("melB", 0)),          # 10 wireframe
    (("bassA2", 0), ("beat", 0), ("c_padA", 0)),       # 11 flat-shaded: the cube holds the chords
    (("bassB2", 0), ("beat", 0), ("c_padB", 0)),       # 12
    (("bassA2", 0), ("beat", 0), ("melA2", 0)),        # 13
    (("bassB2", 0), ("beat", 0), ("c_melB2", 0)),      # 14 rubber cube
    (("bassA2", 0), ("beat", 0), ("c_melA", 12)),      # 15
    (("bassB2", 0), ("fill", 0), ("c_melB", 12)),      # 16
    (("bassA", 0), ("beat", 0), ("melA2", 0)),         # 17 flat-shaded
    (("bassB", 0), ("beat", 0), ("melB2", 0)),         # 18
    (("bassA", 0), ("kicks", 0), ("arpA", 0)),         # 19 wireframe
    (("end", 0), ("hats", 0), ("padA", 0)),            # 20 corner dots, and round again
]

# ---------------------------------------------------------------------------------------------
def player_model(seconds):
    """a model of the 6809 player, for previews: returns 8-bit unsigned samples at RATE"""
    import random
    rnd = random.Random(7)
    noise = [rnd.randint(-127, 127) for _ in range(256)]
    def wave(w, i):
        if w == 0: return 127 if i < 128 else -127
        if w == 1: return 127 if i < 64 else -127
        if w == 2: return i - 128
        if w == 3: return -127 + 2 * i if i < 128 else 383 - 2 * i
        if w == 4: return round(127 * math.sin(2 * math.pi * i / 256))
        if w == 5: return noise[i]
        if w == 6: return 127 if (i // 32) % 4 in (0, 1) else -127 + (i % 64) * 3   # a stand-in for the cube
    tabs = {}
    def sample(w, vol, i):
        m = 80 * vol // 7                       # as cube.asm: 40 + (w * m) >> 8 stays within 0..79
        return (40 + ((wave(w, i) * m) >> 8)) & 0xFC
    ch = [dict(note=0, ins=0, arp=0, env=8, step=0, slide=0, ph=0, vol=0, wave=0) for _ in range(3)]
    out = bytearray()
    pos, row, tick, arpph = 0, 0, 0, 0
    per_tick = RATE / 60
    acc = 0.0
    for t in range(int(seconds * 60)):
        if tick == 0:
            for c in range(3):
                name, tr = ORDER[pos][c]
                n, ia = TRACKS[name][row]
                if n == 0xFF:
                    ch[c]['env'] = 99
                elif n:
                    ch[c].update(note=n - 1 + tr, ins=ia >> 4, arp=ia & 15, env=0, slide=0)
            row += 1
            if row == ROWS:
                row = 0
                pos = pos + 1 if pos + 1 < len(ORDER) else 1
        tick = (tick + 1) % SPEED
        for c in range(3):
            k = ch[c]
            ins = INSTRUMENTS[k['ins']] if k['ins'] else None
            if not ins or k['env'] == 99:
                k['vol'] = 0; continue
            k['vol'] = ins[3][min(k['env'], 7)]
            k['env'] += 1
            off = (0, ARPS[k['arp']][0], ARPS[k['arp']][1])[arpph]
            k['step'] = max(0, STEPS[min(95, k['note'] + off)] - k['slide'])
            k['slide'] += ins[2]
            k['wave'] = ins[1]
        arpph = (arpph + 1) % 3
        acc += per_tick
        while acc >= 1:
            acc -= 1
            s = 0
            for k in ch:
                k['ph'] = (k['ph'] + k['step']) & 0xFFFF
                s += sample(k['wave'], k['vol'], k['ph'] >> 8)
            out.append(min(255, s))
    return out

def write_wav(path, seconds):
    import wave
    data = player_model(seconds)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(1); w.setframerate(round(RATE)); w.writeframes(bytes(data))

def emit():
    lines = [";;; >>> SONG (generated by scripts/cube_tune.py from tracker notation - edit it there)",
             "SPEED       equ     %d               ; ticks per row (60 ticks a second)" % SPEED,
             "NPOS        equ     %d              ; positions; the song loops back to position 1" % len(ORDER),
             ";;; instruments: waveform, slide per tick (word), 8 volumes"]
    lines.append("instruments:")
    for ins in INSTRUMENTS:
        if ins is None:
            lines.append("            fcb     0\n            fdb     0\n            fcb     0,0,0,0,0,0,0,0   ; (none)")
        else:
            lines.append("            fcb     %d\n            fdb     %d\n            fcb     %s   ; %s" % (ins[1], ins[2], ",".join(map(str, ins[3])), ins[0]))
    lines.append("arps:       fcb     " + ",".join("%d,%d" % a for a in ARPS))
    lines.append(";;; note steps: phase increment per sample (65536 = one cycle), C-0 .. B-7")
    lines.append("notes:")
    for i in range(0, 96, 12):
        lines.append("            fdb     " + ",".join(str(v) for v in STEPS[i:i + 12]))
    names = list(TRACKS)
    lines.append(";;; tracks: 32 rows of (note + 1 or $FF = off or 0, instrument * 16 + arpeggio)")
    lines.append("tracks:     fdb     " + ",".join("trk_" + n for n in names))
    for n in names:
        flat = [b for r in TRACKS[n] for b in r]
        lines.append("trk_%s:" % n)
        for i in range(0, 64, 16):
            lines.append("            fcb     " + ",".join("$%02X" % b for b in flat[i:i + 16]))
    lines.append(";;; order: per position, per channel: track number, transpose")
    lines.append("order:")
    for i, o in enumerate(ORDER):
        lines.append("            fcb     " + ",".join("%d,%d" % (names.index(t), tr) for t, tr in o) + "   ; %d" % i)
    lines.append(";;; <<< SONG")
    return "\n".join(lines) + "\n"

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    asm = os.path.join(here, "..", "cube.asm")
    src = open(asm).read()
    block = emit()
    if ";;; >>> SONG" in src:
        src = re.sub(r";;; >>> SONG.*?;;; <<< SONG\n", lambda m: block, src, flags=re.S)
    else:
        src = src.replace(";;; sin(2 pi i / 256) * 127\nsintab:", block + "\n;;; sin(2 pi i / 256) * 127\nsintab:")
    open(asm, "w").write(src)
    print("cube.asm: song block written (%d tracks, %d positions, %d s per position)" % (len(TRACKS), len(ORDER), ROWS * SPEED / 60))
    if len(sys.argv) >= 3 and sys.argv[1] == "--wav":
        write_wav(sys.argv[2], (len(ORDER)) * ROWS * SPEED / 60)
        print("preview:", sys.argv[2])
