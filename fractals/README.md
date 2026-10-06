# FRACTAL — nine fractals and an effects show for the CoCo 3

Nine classic fractals drawn by a 1.79 MHz CoCo 3, followed by an effects reel (zooms, dissolves, a spinning picture,
bit-twiddling patterns). It's 6 KB of 6809 code that never multiplies inside its main loop.

![the Mandelbrot set](screenshots/mandelbrot.png) ![Barnsley's fern](screenshots/fern.png)

```
./setup.sh                          # once: assembler, MAME, Python
./run.sh                            # build, boot a CoCo 3 in MAME, type LOADM"FRACTAL":EXEC, watch
./run.sh --video fractals.mp4       # record the whole show from power-on (about 6½ minutes)
test/verify.sh                      # check the CoCo's pictures against a Python copy of the maths, byte for byte
```
`fractals.mp4` is that recording: the BASIC screen, `LOADM` being typed, the title, every picture and the reel.
On a real CoCo 3 (2 MB): put `build/FRACTAL.DSK` on a disk and type `LOADM"FRACTAL":EXEC`.

## The show
1. the Mandelbrot set
2. a tiny copy of the Mandelbrot set hiding on its "needle"
3. Douady's rabbit (a Julia set)
4. another Julia set, all spirals
5. the Burning Ship
6. the Tricorn
7. a fern, grown from four simple rules picked at random (Barnsley's fern)
8. the Heighway dragon (the paper-folding curve)
9. the Sierpinski triangle

Each picture is drawn and then shown for 5 seconds, with its colours cycling. Pictures dissolve into each other with
**FizzleFade**, the random-pixel dissolve from Wolfenstein 3D's death screen. Then comes the reel:
* a **zoom** into the needle and back out (20 frames drawn first, then played back by pointing the video chip at
  different memory);
* smooth **crossfades** between the pictures;
* an **XOR blend** of two fractals;
* a **rotating and zooming** picture;
* **munching squares**, the 1962 PDP-1 display hack;
* patterns made from nothing but x XOR y, x AND y, x OR y and x × y.

| Key | Action |
|---|---|
| **1–9** | jump to a picture |
| **0** | the effects reel |
| **SPACE** | next |
| **BREAK** | back to BASIC |

## How it's done without multiplying
* **Squares come from a table.** Drawing the Mandelbrot set is mostly squaring numbers. At start-up the program
  builds a 24 KB table of squares, using only additions: each square is the previous one plus the next odd number.
  Every number the program uses is stored with its lowest bit clear, so a number can be used directly as its own
  position in that table. Squaring becomes a single table read.
* **Three lookups per step.** One step of the Mandelbrot formula needs x², y² and 2xy. The last one comes free from
  a school identity, 2xy = (x+y)² − x² − y², so each step is three table reads and some additions. The "has it
  escaped?" test is simply the top bit of x² + y².
* **Multiplying with squares.** The fern, dragon and triangle need real multiplication, and get it from the same
  table: a × b = ((a+b)² − (a−b)²) / 4, the "quarter squares" trick from before multipliers existed.
* **Coarse first, then fine.** Each picture appears as 4×4 blocks, then 2×2, then single pixels. When the coarse
  blocks around a pixel all agree, that pixel is filled in instead of computed, which skips most of the work inside
  big areas of one colour. Pictures that are symmetric compute only half and mirror the rest.
* **Memory.** Each finished picture is kept in its own pair of 8 KB pages for the reel, and the zoom frames sit
  where the video chip can show them directly.

Each picture takes 7–37 seconds at 1.79 MHz; the Burning Ship is the slowest.

## Checked, not hoped
`scripts/fractal_scenes.py` contains a Python copy of the program's arithmetic (same table, same shortcuts, same
random numbers). `test/verify.sh` boots the real disk in MAME, saves the screen memory after each picture and
compares: all nine match byte for byte.

## Files
```
fractal.asm                 the program (6809, lwasm)
scripts/fractal_scenes.py   the pictures' settings, palettes and the reel's paths; the Python copy of the maths
scripts/mkdsk.py            writes disk images exactly as Disk BASIC lays them out
build.sh  run.sh  setup.sh  build / run in MAME (and record) / install the tools
test/verify.sh              the byte-for-byte check
```
