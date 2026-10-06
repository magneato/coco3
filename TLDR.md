# TL;DR

**Machine:** Tandy Color Computer 3. 6809 at 1.79 MHz, GIME video, 128 KB stock (512 KB / 2 MB upgrades), Disk BASIC.
**Tools:** `lwasm` (6809 assembler), MAME (emulator), Python (build-time data and checks).
**Rule:** every project runs from a real Disk BASIC floppy with `LOADM"NAME":EXEC`.

---

## wolf3d — Wolfenstein 3D
* **What:** the real first level, art, status bar and sounds (from your own copy of the game), full screen, 2 MB.
* **Novel:**
  * the engine **writes ~150 wall-drawing routines at boot**, one per height and width: no loops, no lookups when
    drawing;
  * **zero divisions** while playing (all tables);
  * a **6-bytes-per-22-cycles** stack copy (3.5× a byte loop, measured);
  * it **draws half the rows per frame** and sharpens when you stop;
  * the **PC-speaker jingles are re-synthesised at boot** from 2.9 KB of note data into 40 KB of samples;
  * an **autopilot** plays the level by itself.
* **Numbers:** ~26 fps in play, 19–30 in the worst views. Sound at 3.9 kHz for ~11% of the CPU.
* **Run:** `cd wolf3d; ./run.sh` (or `./release.sh` for the stand-in art that needs no game files).

## fractals — FRACTAL
* **What:** Mandelbrot, mini-Mandelbrot, 2 Julia sets, Burning Ship, Tricorn, fern, dragon, Sierpinski, plus an
  effects reel.
* **Novel:**
  * **no multiply in the inner loop**: a 24 KB table of squares, built by adding odd numbers;
  * numbers kept even so **a number is its own table index**;
  * 2xy = (x+y)² − x² − y² makes **one step = 3 lookups**;
  * multiplication by **quarter squares** for the fern, dragon and triangle;
  * **coarse-to-fine drawing with guessing**;
  * Wolf3D's **FizzleFade** between pictures;
  * zoom playback by **moving the video pointer, not the pixels**.
* **Proof:** `test/verify.sh` matches all 9 pictures **byte for byte** against a Python copy.
* **Run:** `cd fractals; ./run.sh` · video: `fractals.mp4`.

## cubes — CUBE
* **What:** dots → jelly dots → wire frame → solid shaded cube → rubber cube, with a soundtrack. One source file.
* **Novel:**
  * rotation is **9 table reads per point** (no multiply per point);
  * **wobble = each dot reads an older frame's rotation**;
  * **a 3-voice tracker mixed live** in a 3,934 Hz interrupt (~130 cycles a sample, self-modifying `LDB`);
  * **the third voice's waveform is the cube's own outline**, so the sound changes as it turns, and an
    oscilloscope draws it.
* **Numbers:** dots 20–60 fps, solid cube ~12 fps (before music); music ≈ a quarter of the CPU.
* **Run:** `cd cubes; ./run.sh` · video: `cubescene.mp4`.

## nsx6809 — a CoCo 3 that learns
* **What:** disk 1 **trains** a digit recogniser on handwriting (MNIST) on the CoCo itself. Disk 2 lets you
  **draw** a digit (keyboard or joystick) and the CoCo reads it.
* **Novel:**
  * the whole modern recipe (guess → measure error → nudge every weight → repeat) in **integer arithmetic on a
    512 KB, 1986-class machine**;
  * first layer is **additions only**, because the input is on/off dots;
  * learning steps use **Bresenham's error term** to keep fractions exact;
  * the model is written back to the floppy through Disk BASIC's own `DSKCON`;
  * text drawn in the **CoCo 3's own ROM font**.
* **Numbers:**
  * **88.5%** on 1,000 unseen digits, **90.2%** on all 10,000;
  * **35 minutes** to learn at 1.79 MHz;
  * programs 3.9 KB + 4.7 KB, model 10 KB.
* **Proof:**
  * the model the CoCo trains is **byte-identical** to a Python reference;
  * the drawing program's answers are bit-exact.
* **Run:** `cd nsx6809; ./get_mnist.sh; ./run.sh --train; ./run.sh`.

## doom — not yet
* **On the bench:** the Quake III inverse square root hack on 6809 floats, monsters driven by real inference, and so on.
  See the [README](README.md).

---
Licence: Clear BSD (BSD-3-Clause-Clear) for the code ([LICENSE.md](LICENSE.md)). **Patents:** Neural Splines technology (nsx6809's learning
method and relatives) is patented; personal, hobby, educational and non-commercial use is fine, anything else needs a
licence ([PATENTS.md](PATENTS.md)). Other people's stuff: [IP.md](IP.md).
