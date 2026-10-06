# Whose is what

The code, scripts and documentation in this repository are original work by Neural Splines LLC, under the Clear
BSD License ([LICENSE.md](LICENSE.md), BSD-3-Clause-Clear), which grants no patent rights. Neural Splines technology is protected by patents and
pending patent applications, and **no patent licence is granted**; see [PATENTS.md](PATENTS.md).
Everything below belongs to someone else and is credited, used with permission of its licence, or deliberately
**left out**.

## id Software — Wolfenstein 3D
**Wolfenstein 3D** was created by **id Software**: John Carmack, John Romero, Adrian Carmack and Tom Hall, with
music and sound by Bobby Prince. It was published by Apogee Software in 1992. *Wolfenstein*
and *Wolfenstein 3D* are trademarks of their respective owners. [wolf3d/](wolf3d/) is an **unofficial fan port**,
not affiliated with or endorsed by id Software, Bethesda or ZeniMax. Thank you, id, for the game that taught a
generation what a ray caster is.

* **No id Software data is in this repository.** The build reads the walls, sprites, map, status bar, palette and
  sounds from **your own copy** of Wolfenstein 3D v1.4 (the full version's `*.WL6` files and `WOLF3D.EXE`, from
  Steam, GOG or another licensed seller), placed in `wolf3d/WOLF3D/`. That folder is ignored by git on purpose.
  Disks built from that data are for your own use: please don't publish them.
* **No id Software source code is in this repository.** The 6809 engine is written from scratch; it re-implements the
  widely documented idea of a grid ray caster and reads the publicly documented file formats. id released the
  Wolfenstein 3D source under a limited-use, educational-only licence; nothing from it was copied.
* **FizzleFade.** The pixel-dissolve effect in [fractals/](fractals/) is a re-implementation of the idea Wolfenstein
  3D used for its death screen, not its code.
* **Screenshots and videos** of the Wolfenstein 3D port (`wolf3d/screenshots/`, `wolf3d/demo.mp4`,
  `wolf3d/cover.png`) show id Software's artwork as the CoCo 3 draws it, and are included only to document what the
  port does.
* **Want to try without the game?** `wolf3d/release.sh` builds *Ashen Bastion*, the same engine with entirely
  original stand-in art, level and sounds. That disk may be shared freely.

## id Software — Quake III Arena
The inverse square root routine quoted in the [README](README.md) is from the **Quake III Arena** source code,
released by id Software under the GNU GPL (version 2). It is quoted for discussion, with two comments reworded, and is
not used by any program here. Its history (Gary Tarolli, Greg Walsh, Cleve Moler, William Kahan and K.C. Ng, Chris
Lomont) is told in the README with credit to the people who uncovered it.

## MNIST
[nsx6809/](nsx6809/) learns from the **MNIST** database of handwritten digits by **Yann LeCun, Corinna Cortes and
Christopher J.C. Burges**, built from NIST's Special Databases 1 and 3. It is **not included**: `nsx6809/get_mnist.sh`
downloads it into an ignored folder. The 100 example digits and 7,200 training and test digits put on the CoCo
disks are derived from it at build time.

## Tandy, Microsoft and Microware — the CoCo 3 ROMs
The Color BASIC, Extended BASIC, Disk BASIC and CoCo 3 ROMs are © Tandy, Microsoft and Microware, and are **not
included**; MAME needs your own copies. At run time, nsx6809's drawing program copies the `HPRINT` character set
out of the CoCo's own ROM into memory to draw its text; no ROM data is stored in this repository.

## Neural Splines LLC — NSX86 and patents
[nsx6809/](nsx6809/) grew out of **NSX86** (Neural Splines for the 8086) by Neural Splines LLC, the same copyright
holder as this repository. Its fixed-point format, learning rule, random number generator, exp table and
model-file header carry over. Neural Splines technology, including the Bresenham Gradient Descent learning rule, is
protected by patents and pending patent applications of Neural Splines LLC. Personal, hobby, educational and
non-commercial research use is permitted; everything else needs a licence ([PATENTS.md](PATENTS.md)).

## Ideas, with thanks
* **Mandelbrot, Julia, Burning Ship, Tricorn**: Benoît Mandelbrot, Gaston Julia, Michael Michelitsch and Otto Rössler,
  and W.D. Crowe et al.
* **Barnsley fern**: Michael Barnsley. **Heighway dragon**: John Heighway, Bruce Banks and William Harter.
  **Sierpinski triangle**: Wacław Sierpiński.
* **Munching squares**: the MIT PDP-1 hackers, 1962.
* **Bresenham's line algorithm**: Jack Bresenham, 1962.
* **Quarter-square multiplication**: older than anyone here.

## Tools
* **lwtools** (`lwasm`) by William Astle.
* **MAME** and its CoCo 3 driver by the MAME team.
* **ffmpeg** for the videos.
* **Python** for the build-time data and the checks.
