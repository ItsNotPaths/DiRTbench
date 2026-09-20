package geo

// Floors — flat pads cut into the generated ground.
//
// A floor is a closed polygon in world XZ and one height. It is a **ceiling on
// the terrain**: where the ground stands above it the ground comes down, and
// where the ground already lies below it nothing happens. That asymmetry is the
// whole point. A pad that could also lift would drag a hillside up to meet it
// wherever it was hung too high, and it would fight the road, whose verge seam
// is fixed geometry the terrain is welded to (see terrain.odin).
//
// The one exception is the divot. A dip that already sat below the floor is left
// as a hole in an otherwise flat pad, which is the one thing a ceiling alone
// cannot fix. So a point inside the outline may rise, by at most FLOOR_LIFT, and
// only when a neighbour of it in the triangulation was actually cut. That gate
// is what keeps the exception from becoming a lift: with nothing cut nearby, the
// floor is simply hanging over untouched ground, and untouched is what it stays.
//
// Rim points are `fixed` and never floored at all, so no floor can cut the road,
// open the verge weld or touch a cliff — by construction rather than by a check.
//
// Floors are authored, unlike the sculpt controls beside them: they are stored
// in world space and re-derived from nothing, so a road edit leaves them alone.

import "core:math"

// How far a floor may pull the ground up to close a divot.
FLOOR_LIFT :: 1.0

// Metres over which a floor blends out into the ground around it. A hard edge
// is a wall in the exported collision, not just a hard line on screen.
FLOOR_FALLOFF :: 8.0

// The overlay batch is a fixed buffer and a pad is a pad, not a coastline.
FLOOR_MAX_VERTS :: 64

FLOOR_MIN_VERTS :: 3

// Heights within this of the cap count as already flat, so a floor laid exactly
// on the ground neither cuts nor lifts.
FLOOR_EPS :: 1e-3

// One pad. Its outline is a run of `count` points in Terrain.floor_pts — flat
// storage, because a point array per floor would need a deep copy in every one
// of terrain_clone, terrain_snapshot and the rebuild's landing, and a matching
// free in each.
Floor :: struct {
	first, count: int,
	y:            f32,
	falloff:      f32,
	using opts:   Floor_Opts,
}

// What a pad does besides cutting the ground. Args rather than one fixed
// behaviour: a levelled patch that keeps its grass is as ordinary as one
// scraped bare, and the author is the one who knows which this is.
//
// Each claims the outline alone, never the falloff band — the band is a blend
// into the hillside, and the hillside keeps what it grows.
Floor_Opts :: struct {
	no_trees:    bool,
	no_cover:    bool,
	water:       bool,
	water_depth: f32,
}

// How deep the water stands over a pad that has just been flooded.
FLOOR_WATER_DEPTH :: 1.5

// Water is one-sided: it draws from above and shows nothing from below or
// edge-on. A surface level with the pad it sits on is therefore invisible, so a
// flooded pad always holds some depth. See docs/dirt3-water.md.
FLOOR_WATER_MIN :: 0.25

// The height of the water surface over one pad, and whether it has any.
//
// A pad cuts the ground to `y` and never lifts it, so the bed is at `y` or
// below and the surface stands `water_depth` above it. The shoreline is wherever
// the untouched ground outside climbs back through that level, which is what
// the falloff band is already doing.
floor_water_level :: proc(f: Floor) -> (y: f32, ok: bool) {
	if !f.water {
		return 0, false
	}
	return f.y + max(f.water_depth, FLOOR_WATER_MIN), true
}

// Which of a pad's two scatters is being asked about.
Floor_Clears :: enum {
	Trees,
	Cover,
}

floor_verts :: proc(t: ^Terrain, f: Floor) -> [][2]f32 {
	return t.floor_pts[f.first:f.first + f.count]
}

floor_valid :: proc(t: ^Terrain, i: int) -> bool {
	return i >= 0 && i < len(t.floors) && t.floors[i].count >= FLOOR_MIN_VERTS
}

// --- the field ---------------------------------------------------------------

// Distance from `p` to the polygon, negative inside it.
poly_signed_dist :: proc(poly: [][2]f32, p: [2]f32) -> f32 {
	best := max(f32)
	inside := false
	j := len(poly) - 1
	for i in 0 ..< len(poly) {
		a, b := poly[j], poly[i]
		// Crossing count: a ray along +X from p, counted against each edge.
		if (a[1] > p[1]) != (b[1] > p[1]) {
			x := a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0])
			if p[0] < x {
				inside = !inside
			}
		}
		best = min(best, seg_dist2(a, b, p))
		j = i
	}
	d := math.sqrt(best)
	return inside ? -d : d
}

seg_dist2 :: proc(a, b, p: [2]f32) -> f32 {
	ab := [2]f32{b[0] - a[0], b[1] - a[1]}
	len2 := ab[0] * ab[0] + ab[1] * ab[1]
	t: f32
	if len2 > 1e-12 {
		t = clamp(((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / len2, 0, 1)
	}
	dx := p[0] - (a[0] + ab[0] * t)
	dz := p[1] - (a[1] + ab[1] * t)
	return dx * dx + dz * dz
}

// The surface the floors hold at `p`: the lowest of them, given the height the
// ground would otherwise have. `inside` marks a point within an outline, which
// is the only place the divot lift may act, and `ok` is false where no floor
// reaches at all.
//
// This is the pad's own level, **not** a height the ground already has. The
// ceiling is min(y, level) and the lift aims at `level`, so the two must not be
// folded together here: a dip inside a pad has a level above it and a ceiling
// equal to it, and that difference is the whole divot rule.
//
// The level fades to `y` itself across the falloff band rather than rising at
// some fixed rate, so a floor meets the ground it sits in whatever the slope.
terrain_floor_level :: proc(t: ^Terrain, p: [2]f32, y: f32) -> (level: f32, inside, ok: bool) {
	level = y
	for fl in t.floors {
		if fl.count < FLOOR_MIN_VERTS {
			continue
		}
		d := poly_signed_dist(floor_verts(t, fl), p)
		if d >= fl.falloff {
			continue
		}
		s := math.smoothstep(f32(0), max(fl.falloff, 1e-3), max(d, 0))
		l := fl.y + s * (y - fl.y)
		if !ok || l < level {
			level = l
		}
		ok = true
		if d <= 0 {
			inside = true
		}
	}
	return
}

// Whether a pad claims this spot from one of the scatters.
terrain_floor_clears :: proc(t: ^Terrain, p: [2]f32, what: Floor_Clears) -> bool {
	for fl in t.floors {
		on := what == .Trees ? fl.no_trees : fl.no_cover
		if !on || fl.count < FLOOR_MIN_VERTS {
			continue
		}
		if poly_signed_dist(floor_verts(t, fl), p) <= 0 {
			return true
		}
	}
	return false
}

// Ground Y for every point in the field, floors applied.
//
// Also the only place a field point's height is worked out at all: the mesh used
// to re-evaluate it once per incident triangle, which is about six times per
// vertex, and the divot pass needs the whole set in hand anyway. The result is
// kept on the field so a pick can read the surface that was last drawn.
terrain_floor_heights :: proc(t: ^Terrain, f: ^Terrain_Field) -> []f32 {
	resize(&f.ys, len(f.pts))
	ys := f.ys[:]
	for p, i in f.pts {
		ys[i] = field_y(t, p)
	}
	if len(t.floors) == 0 {
		return ys
	}

	levels := make([]f32, len(f.pts), context.temp_allocator)
	inside := make([]bool, len(f.pts), context.temp_allocator)
	cut := make([]bool, len(f.pts), context.temp_allocator)
	for p, i in f.pts {
		if p.fixed {
			continue // the verge seam, which is the weld
		}
		level, ins, ok := terrain_floor_level(t, {p.x, p.z}, ys[i])
		if !ok {
			continue
		}
		levels[i], inside[i] = level, ins
		if ys[i] > level + FLOOR_EPS {
			ys[i] = level
			cut[i] = true
		}
	}

	// "Surrounded by cut ground", read off the triangulation's own adjacency.
	near := make([]bool, len(f.pts), context.temp_allocator)
	for tri in f.tris {
		if !cut[tri[0]] && !cut[tri[1]] && !cut[tri[2]] {
			continue
		}
		near[tri[0]], near[tri[1]], near[tri[2]] = true, true, true
	}
	for p, i in f.pts {
		if p.fixed || cut[i] || !inside[i] || !near[i] {
			continue
		}
		ys[i] = min(levels[i], ys[i] + FLOOR_LIFT)
	}
	return ys
}

// --- editing -----------------------------------------------------------------

// Append a pad. The outline is copied; the caller keeps its own.
floor_add :: proc(t: ^Terrain, verts: [][2]f32, y: f32, opts := Floor_Opts{}) -> int {
	if len(verts) < FLOOR_MIN_VERTS {
		return -1
	}
	n := min(len(verts), FLOOR_MAX_VERTS)
	f := Floor {
		first   = len(t.floor_pts),
		count   = n,
		y       = y,
		falloff = FLOOR_FALLOFF,
		opts    = opts,
	}
	append(&t.floor_pts, ..verts[:n])
	append(&t.floors, f)
	return len(t.floors) - 1
}

floor_remove :: proc(t: ^Terrain, i: int) {
	if i < 0 || i >= len(t.floors) {
		return
	}
	f := t.floors[i]
	remove_range(&t.floor_pts, f.first, f.first + f.count)
	ordered_remove(&t.floors, i)
	floors_reindex(t, i, -f.count)
}

// Slide every run after `from` by `delta`, the flat storage's whole cost.
floors_reindex :: proc(t: ^Terrain, from, delta: int) {
	for &f in t.floors[from:] {
		f.first += delta
	}
}

// A vertex on the edge that leaves `after`, which is where a right-click on that
// edge puts one.
floor_vert_insert :: proc(t: ^Terrain, i, after: int, p: [2]f32) -> int {
	if i < 0 || i >= len(t.floors) {
		return -1
	}
	f := &t.floors[i]
	if f.count >= FLOOR_MAX_VERTS || after < 0 || after >= f.count {
		return -1
	}
	at := f.first + after + 1
	inject_at(&t.floor_pts, at, p)
	f.count += 1
	floors_reindex(t, i + 1, 1)
	return after + 1
}

floor_vert_remove :: proc(t: ^Terrain, i, v: int) -> bool {
	if i < 0 || i >= len(t.floors) {
		return false
	}
	f := &t.floors[i]
	if f.count <= FLOOR_MIN_VERTS || v < 0 || v >= f.count {
		return false
	}
	ordered_remove(&t.floor_pts, f.first + v)
	f.count -= 1
	floors_reindex(t, i + 1, -1)
	return true
}

floor_centre :: proc(t: ^Terrain, i: int) -> (c: [2]f32) {
	if !floor_valid(t, i) {
		return
	}
	verts := floor_verts(t, t.floors[i])
	for v in verts {
		c += v
	}
	return c / f32(len(verts))
}

floor_move :: proc(t: ^Terrain, i: int, d: [2]f32) {
	if i < 0 || i >= len(t.floors) {
		return
	}
	for &v in floor_verts(t, t.floors[i]) {
		v += d
	}
}

// The outline vertex nearest `p` in XZ, and the edge nearest it. The edge is
// named by the vertex it leaves, which is what floor_vert_insert takes.
floor_nearest_vert :: proc(t: ^Terrain, i: int, p: [2]f32) -> (v: int, d2: f32) {
	v, d2 = -1, max(f32)
	if !floor_valid(t, i) {
		return
	}
	for q, k in floor_verts(t, t.floors[i]) {
		dx, dz := p[0] - q[0], p[1] - q[1]
		if s := dx * dx + dz * dz; s < d2 {
			v, d2 = k, s
		}
	}
	return
}

floor_nearest_edge :: proc(t: ^Terrain, i: int, p: [2]f32) -> (e: int, d2: f32) {
	e, d2 = -1, max(f32)
	if !floor_valid(t, i) {
		return
	}
	verts := floor_verts(t, t.floors[i])
	for k in 0 ..< len(verts) {
		if s := seg_dist2(verts[k], verts[(k + 1) % len(verts)], p); s < d2 {
			e, d2 = k, s
		}
	}
	return
}

floors_delete :: proc(t: ^Terrain) {
	delete(t.floors)
	delete(t.floor_pts)
	t.floors, t.floor_pts = nil, nil
}

// Copied whole, outlines and all. Every path that hands a Terrain to somewhere
// else — the export, the rebuild worker — owes the copy its own storage.
floors_copy :: proc(dst: ^Terrain, src: Terrain) {
	dst.floors = nil
	dst.floor_pts = nil
	append(&dst.floors, ..src.floors[:])
	append(&dst.floor_pts, ..src.floor_pts[:])
}

// Triangles covering a pad's outline, wound so each face points +Y.
//
// Delaunay spans the convex hull, so a concave outline comes back with
// triangles outside itself; those are dropped by testing each centroid against
// the polygon. The winding is then forced, because delaunator promises none and
// a water face wound the other way is backface culled into nothing.
floor_triangulate :: proc(poly: [][2]f32, allocator := context.allocator) -> (tris: [][3]u32, ok: bool) {
	if len(poly) < FLOOR_MIN_VERTS {
		return nil, false
	}
	coords := make([]f64, len(poly) * 2, context.temp_allocator)
	for p, i in poly {
		coords[i * 2], coords[i * 2 + 1] = f64(p[0]), f64(p[1])
	}
	spanned, made := delaunay_owned(coords, context.temp_allocator)
	if !made {
		return nil, false
	}
	out := make([dynamic][3]u32, allocator)
	for tri in spanned {
		a, b, c := poly[tri[0]], poly[tri[1]], poly[tri[2]]
		mid := [2]f32{(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3}
		if poly_signed_dist(poly, mid) > 0 {
			continue // the hull reaches outside the outline here
		}
		kept := tri
		if (b[1] - a[1]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[1] - a[1]) < 0 {
			kept[1], kept[2] = kept[2], kept[1]
		}
		append(&out, kept)
	}
	if len(out) == 0 {
		delete(out)
		return nil, false
	}
	return out[:], true
}
