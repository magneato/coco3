#!/usr/bin/env python3
"""
grid.py - a DOOM map rasterised onto the engine's 64 x 64 lattice (Stage A of docs/PLAN.md).

One lattice cell is 64 x 64 map units, DOOM's own grid; E1M1 (3952 x 3400 units) fits with room to spare.
Row 0 is the map's north edge (DOOM's y grows north, the lattice's grows south), so angles keep their meaning:
DOOM's counter-clockwise on a y-up map is the engine's clockwise on a y-down one.

Each cell is sampled every 8 units (64 points).  A point is classified by descending the BSP to its subsector
and then testing it against that subsector's own segs: the void behind a one-sided wall lies in some leaf's
region but outside its seg polygon, so this is what tells floor from rock.
  open    in a sector with room to stand (ceiling - floor >= 56)
  door    in a closed sector (ceiling <= floor + 8) that a door special opens
  solid   everything else
A cell is a door if enough of it is door, open if at least half of it is open, solid otherwise.  Then thin
walls are restored: two open neighbours whose centres are separated by a blocking line (one-sided, flagged
impassable, or too low to pass) may not touch, so the less open of the two is closed.

A solid cell's texture is the sidedef texture facing its open neighbours (middle for a one-sided line, lower or
upper for a step), the most common one when faces disagree.  Its light is the brightest open neighbour's.

Usage:  python3 scripts/grid.py [map]      prints the lattice as text (# solid, . open, D door, X exit, @ start)
"""
import math, os, sys
from collections import Counter, namedtuple
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wad

CELL = 64
STEP = 8                                        # sampling pitch inside a cell
PLAYER_H = 56
DOOR_SPECIALS = {1, 2, 3, 16, 26, 27, 28, 29, 31, 32, 33, 34, 42, 46, 50, 61, 63, 75, 76, 86, 90, 103,
                 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118}
EXIT_SPECIALS = {11, 51, 52, 124, 197, 198}
OPEN, DOOR, SOLID = 0, 1, 2

Grid = namedtuple("Grid", "w h x0 y0 kind tex light sector exit start things level door_sector")

class Classifier:
    def __init__(self, lev):
        self.lev = lev
        self.root = len(lev.nodes) - 1
        self.ss_sector = []
        for ss in lev.subsectors:
            sg = lev.segs[ss.first]
            ld = lev.linedefs[sg.linedef]
            sd = ld.left if sg.side else ld.right
            self.ss_sector.append(lev.sidedefs[sd].sector)
        # sectors that a door special opens: the back sector of a door linedef (manual doors), or every sector
        # whose tag a door special names (remote doors)
        self.door_sector = set()
        tags = {ld.tag for ld in lev.linedefs if ld.special in DOOR_SPECIALS and ld.tag}
        for i, s in enumerate(lev.sectors):
            if s.tag and s.tag in tags:
                self.door_sector.add(i)
        for ld in lev.linedefs:
            if ld.special in DOOR_SPECIALS and ld.tag == 0 and ld.left is not None:
                self.door_sector.add(lev.sidedefs[ld.left].sector)

    def subsector(self, x, y):
        n = self.root
        while True:
            nd = self.lev.nodes[n]
            front = (y - nd.y) * nd.dx < (x - nd.x) * nd.dy or (nd.dx == 0 and nd.dy == 0)
            # DOOM's R_PointOnSide: left = ndy*dx, right = dy*ndx, front when right < left
            c = nd.right if front else nd.left
            if c & 0x8000:
                return c & 0x7FFF
            n = c

    def sector_at(self, x, y):
        """sector index, or None for the void"""
        ssi = self.subsector(x, y)
        ss = self.lev.subsectors[ssi]
        for k in range(ss.first, ss.first + ss.count):
            sg = self.lev.segs[k]
            ax, ay = self.lev.vertexes[sg.v1]; bx, by = self.lev.vertexes[sg.v2]
            if (bx - ax) * (y - ay) - (by - ay) * (x - ax) > 0:       # left of a seg: outside this leaf's floor
                return None
        return self.ss_sector[ssi]

    def kind(self, sec):
        if sec is None:
            return SOLID
        s = self.lev.sectors[sec]
        if s.ceil - s.floor >= PLAYER_H:
            return OPEN
        if sec in self.door_sector:
            return DOOR
        return SOLID

def _cross(ax, ay, bx, by, cx, cy):
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

def segments_cross(p, q, a, b):
    d1 = _cross(*a, *b, *p); d2 = _cross(*a, *b, *q)
    d3 = _cross(*p, *q, *a); d4 = _cross(*p, *q, *b)
    return (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0)

def build(mapname="e1m1"):
    lev = wad.load_level(mapname)
    cl = Classifier(lev)
    xs = [v[0] for v in lev.vertexes]; ys = [v[1] for v in lev.vertexes]
    w = (max(xs) - min(xs)) // CELL + 3
    h = (max(ys) - min(ys)) // CELL + 3
    assert w <= 64 and h <= 64, (w, h)
    W = H = 64
    x0 = min(xs) - CELL * ((64 - w) // 2 + 1)         # centre the map in the lattice, one ring of rock around it
    y1 = max(ys) + CELL * ((64 - h) // 2 + 1)         # DOOM y of the lattice's north edge
    def cell_origin(cx, cy):                          # south-west corner of a cell, in DOOM units
        return x0 + cx * CELL, y1 - (cy + 1) * CELL

    kind = [SOLID] * (W * H); sector = [None] * (W * H); openfrac = [0.0] * (W * H)
    door_sec = [None] * (W * H)
    for cy in range(1, H - 1):
        for cx in range(1, W - 1):
            ox, oy = cell_origin(cx, cy)
            cnt = Counter(); secs = Counter(); dsecs = Counter()
            for j in range(CELL // STEP):
                for i in range(CELL // STEP):
                    s = cl.sector_at(ox + STEP // 2 + i * STEP, oy + STEP // 2 + j * STEP)
                    k = cl.kind(s)
                    cnt[k] += 1
                    if k == OPEN: secs[s] += 1
                    if k == DOOR: dsecs[s] += 1
            n = (CELL // STEP) ** 2
            openfrac[cy * W + cx] = cnt[OPEN] / n
            if cnt[DOOR] >= n // 8:
                kind[cy * W + cx] = DOOR; door_sec[cy * W + cx] = dsecs.most_common(1)[0][0]
            elif cnt[OPEN] >= n // 2:
                kind[cy * W + cx] = OPEN; sector[cy * W + cx] = secs.most_common(1)[0][0]

    # blocking lines: one-sided, impassable, or a gap too low.  Steps do not block: the lattice has one floor height,
    # so a ledge, a lift or a stair is just floor (E1M1 starts on a platform 140 units above its corridor)
    def blocking(ld):
        if ld.left is None or ld.flags & 1:
            return True
        a = lev.sectors[lev.sidedefs[ld.right].sector]; b = lev.sectors[lev.sidedefs[ld.left].sector]
        return min(a.ceil, b.ceil) - max(a.floor, b.floor) < PLAYER_H and \
            lev.sidedefs[ld.left].sector not in cl.door_sector and lev.sidedefs[ld.right].sector not in cl.door_sector
    blockers = [(lev.vertexes[ld.v1], lev.vertexes[ld.v2], li) for li, ld in enumerate(lev.linedefs) if blocking(ld)]
    def centre(cx, cy):
        ox, oy = cell_origin(cx, cy); return (ox + CELL / 2, oy + CELL / 2)
    def blocker_between(c1, c2):
        p, q = centre(*c1), centre(*c2)
        for a, b, li in blockers:
            if max(a[0], b[0]) < min(p[0], q[0]) or min(a[0], b[0]) > max(p[0], q[0]) or \
               max(a[1], b[1]) < min(p[1], q[1]) or min(a[1], b[1]) > max(p[1], q[1]):
                continue
            if segments_cross(p, q, a, b):
                return li
        return None
    changed = True
    while changed:
        changed = False
        for cy in range(1, H - 1):
            for cx in range(1, W - 1):
                if kind[cy * W + cx] != OPEN:
                    continue
                for nx, ny in ((cx + 1, cy), (cx, cy + 1)):
                    if kind[ny * W + nx] != OPEN:
                        continue
                    if blocker_between((cx, cy), (nx, ny)) is not None:
                        a, b = cy * W + cx, ny * W + nx
                        loser = a if openfrac[a] < openfrac[b] else b
                        kind[loser] = SOLID; sector[loser] = None; changed = True

    # wall textures and light
    tex = [None] * (W * H); light = [0] * (W * H)
    def face_texture(li, open_sec):
        ld = lev.linedefs[li]
        sides = [ld.right, ld.left]
        for sd in sides:
            if sd is None:
                continue
            side = lev.sidedefs[sd]
            if side.sector != open_sec and len([s for s in sides if s is not None]) > 1:
                continue
            other = sides[1] if sd == ld.right else sides[0]
            if other is None:
                return side.middle if side.middle != "-" else None
            o = lev.sectors[lev.sidedefs[other].sector]; me = lev.sectors[side.sector]
            if o.floor > me.floor and side.lower != "-":
                return side.lower
            if o.ceil < me.ceil and side.upper != "-":
                return side.upper
            return side.middle if side.middle != "-" else (side.lower if side.lower != "-" else side.upper if side.upper != "-" else None)
        return None
    def nearest_line(cx, cy, nx, ny):
        """the linedef closest to the border between a solid cell and its open neighbour"""
        (px, py), (qx, qy) = centre(cx, cy), centre(nx, ny)
        mx, my = (px + qx) / 2, (py + qy) / 2
        best, bd = None, 1e18
        for li, ld in enumerate(lev.linedefs):
            (ax, ay), (bx, by) = lev.vertexes[ld.v1], lev.vertexes[ld.v2]
            dx, dy = bx - ax, by - ay
            L = dx * dx + dy * dy or 1
            t = max(0.0, min(1.0, ((mx - ax) * dx + (my - ay) * dy) / L))
            ex, ey = ax + t * dx - mx, ay + t * dy - my
            d = ex * ex + ey * ey
            if d < bd:
                bd, best = d, li
        return best if bd <= (CELL * 0.75) ** 2 else None
    for cy in range(H):
        for cx in range(W):
            i = cy * W + cx
            if kind[i] == OPEN:
                light[i] = lev.sectors[sector[i]].light
                continue
            votes = Counter(); lights = []
            for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                if not (0 <= nx < W and 0 <= ny < H):
                    continue
                j = ny * W + nx
                if kind[j] != OPEN:
                    continue
                lights.append(lev.sectors[sector[j]].light)
                li = nearest_line(cx, cy, nx, ny)
                if li is not None:
                    t = face_texture(li, sector[j])
                    if t:
                        votes[t] += 1
            if kind[i] == DOOR:
                ds = door_sec[i]
                for ld in lev.linedefs:
                    for sd in (ld.right, ld.left):
                        if sd is not None and ld.special in DOOR_SPECIALS:
                            side = lev.sidedefs[sd]
                            if side.sector != ds and side.upper != "-":
                                votes[side.upper] += 3 if lev.sidedefs[ld.left if sd == ld.right else ld.right].sector == ds else 0
            tex[i] = votes.most_common(1)[0][0] if votes else None
            light[i] = max(lights) if lights else 0

    # the exit: the solid cell holding (or nearest to) an exit line, on the side away from the player
    exit_cell = None
    for ld in lev.linedefs:
        if ld.special in EXIT_SPECIALS:
            (ax, ay), (bx, by) = lev.vertexes[ld.v1], lev.vertexes[ld.v2]
            mx, my = (ax + bx) / 2, (ay + by) / 2
            # step a little behind the line (to its left: the back of a switch)
            nxv, nyv = -(by - ay), (bx - ax)
            L = math.hypot(nxv, nyv) or 1
            px, py = mx + nxv / L * 16, my + nyv / L * 16
            cx, cy = int((px - x0) // CELL), int((y1 - py) // CELL)
            exit_cell = (cx, cy, ld.special)
            if kind[cy * W + cx] == OPEN:                 # a walk-over exit: put the switch in the nearest rock
                best = min(((abs(ex - cx) + abs(ey - cy), ex, ey) for ey in range(H) for ex in range(W)
                            if kind[ey * W + ex] == SOLID and any(kind[(ey + dy) * W + ex + dx] == OPEN
                            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)) if 0 <= ex + dx < W and 0 <= ey + dy < H)))
                exit_cell = (best[1], best[2], ld.special)
            break

    def to_cell(x, y):
        return (x - x0) / CELL, (y1 - y) / CELL
    start = None; things = []
    for t in lev.things:
        fx, fy = to_cell(t.x, t.y)
        if t.type == 1:
            start = (fx, fy, t.angle)
        elif not (t.flags & 0x10) and (t.flags & 0x02):           # single player, skill 3 ("hurt me plenty")
            things.append((t.type, fx, fy, t.angle))
    assert start, "no player start"
    return Grid(W, H, x0, y1, kind, tex, light, sector, exit_cell, start, things, lev, door_sec)

def show(g):
    sx, sy = int(g.start[0]), int(g.start[1])
    for cy in range(g.h):
        row = ""
        for cx in range(g.w):
            k = g.kind[cy * g.w + cx]
            c = "#" if k == SOLID else "D" if k == DOOR else "."
            if g.exit and (cx, cy) == g.exit[:2]: c = "X"
            if (cx, cy) == (sx, sy): c = "@"
            row += c
        print(row)

if __name__ == "__main__":
    g = build(sys.argv[1] if len(sys.argv) > 1 else "e1m1")
    show(g)
    k = Counter(g.kind)
    print(f"open {k[OPEN]}, door {k[DOOR]}, solid {k[SOLID]}; exit {g.exit}; start {g.start}; {len(g.things)} things; "
          f"{len(set(t for t in g.tex if t))} wall textures")
