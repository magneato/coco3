# DOOM? On a CoCo 3?

Not yet. This folder is a promise, not a program.

Wolfenstein 3D fits on a CoCo 3 because every wall is the same height and every floor is flat. DOOM breaks both of
those rules, so the next engine has to decide, all over again, what to optimize and what to drop.

On the bench right now:
* **the inverse square root hack** (see the [main README](../README.md)), rebuilt for the 6809, which has no
  floating-point hardware at all;
* **monsters that use real inference**: a small network like [NSX6809](../nsx6809/)'s, trained ahead of time,
  deciding what to do next;
* **and so on**: sectors instead of a grid, light levels from the palette, sprites from the compiled-code trick.

Watch this space.
