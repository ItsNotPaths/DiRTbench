package geo

// Triangle mesh generation: spline -> road surface + verges -> GPU mesh.
//
// This is the single source of geometry. The viewport draws it and every export
// target (export.odin) walks the same triangle list, so what you see is what
// ships.
//
// The mesh is a **non-indexed, flat-shaded triangle soup**: three unique
// vertices per triangle, each carrying that face's normal. Two reasons:
//   - the game exporters we target are flat-shaded, with no smooth-vertex
//     sharing, so an indexed smooth mesh would have to be exploded anyway;
//   - an indexed u16 mesh would cap us at 65k vertices.
//
// Nothing here is lit by a shader: the default material is unlit, so a
// fixed key light is baked into the vertex colours at build time.

import "core:math"
import "../gfx"

// Cliff shape. Heights, spans, tapers and the face angle are per-point (see
// spline.odin); these are the constants that give a cliff its character.
CLIFF_MIN :: 0.01 // below this a cliff is nothing, and emits no geometry

// Face angle limits, degrees off vertical. Negative overhangs the road; the
// lower bound is small because a steep overhang would let the cliff face poke
// down through the road surface it grew from.
CLIFF_ANGLE_MIN :: -5.0
CLIFF_ANGLE_MAX :: 75.0

// Height slider range, metres. A rally stage is walled by rock cuttings and
// banks a car could plausibly be contained by, not by canyon faces.
CLIFF_HEIGHT_MAX :: 7.0

// Rock on a cliff face.
//
// One rule, and every trap below is a corollary of it: **a face vertex is a
// function of the smooth face and nothing else.** Not of the ribbon index, not
// of the spacing to the next sample, not of how finely the face is cut into
// rows. Two reasons, both learned the hard way:
//
//   - The ribbon emits two coincident samples at every node, one ending the edge
//     into it and one starting the edge out of it, and they know different
//     things about their neighbours. Anything twins can disagree about opens a
//     crack at every node.
//   - The road mesh and the terrain compute the shared vertices separately and
//     are welded only by both landing on the same position, to the bit.
//
// Three things shape it:
//
//   - **It stands off along the face normal.** A world-space offset spends most
//     of its length sliding the face along itself, where it shows as nothing.
//     Along the normal every metre is relief, and the face stays a height field
//     over its own smooth self, which is why it cannot fold.
//   - **It goes to nothing at both ends of the profile.** The road edge is where
//     the road surface welds; the crest is where the terrain, the billboards and
//     the scatter all weld. Leave the crest alone and none of them can tear, and
//     the terrain's 2D triangulation keeps the well-behaved rim it was written
//     for. The cost is a clean skyline; the alternative was holes.
//   - **It only ever stands proud.** The smooth face is where the rock was cut
//     away for the road, so anything leaning back in hangs over the road. The
//     noise is mapped to 0..1 rather than fenced after the fact.
//
// What is left is the amplitude, and the only real limit on it is spikiness:
// past about a slope of 1 the triangles stand off the wall like blades. Octaves
// that halve in both wavelength and amplitude each carry the same slope, so the
// count costs nothing in steepness and the depth is the one knob.
CLIFF_ROCK_DEPTH :: 0.7   // relief at full roughness, as a fraction of cliff height
CLIFF_ROCK_WAVE :: 6.0   // metres across the largest lump
CLIFF_ROCK_OCTAVES :: 5   // each half the wavelength of the one before
CLIFF_ROCK_KEEP :: 0.8    // and this much of its amplitude: 0.5 is one big bowl
CLIFF_ROCK_CONTRAST :: 3.0 // how hard the noise is pushed to its extremes

// One hashed lattice corner, in [-1,1].
rock_lattice :: proc(x, y, z: i32, seed: u32) -> f32 {
	h := hash_u32(u32(x) * 73856093 ~ u32(y) * 19349663 ~ u32(z) * 83492791 ~ seed)
	return f32(h) / f32(max(u32)) * 2 - 1
}

// One octave of value noise at a world point, in [-1,1]. Trilinear between the
// eight lattice corners around it, each axis smoothstepped so the field is
// smooth across a lattice plane rather than creased along it.
rock_octave :: proc(p: gfx.Vector3, seed: u32) -> f32 {
	base := gfx.Vector3{math.floor(p.x), math.floor(p.y), math.floor(p.z)}
	i := [3]i32{i32(base.x), i32(base.y), i32(base.z)}
	t := p - base
	s := gfx.Vector3{t.x*t.x*(3-2*t.x), t.y*t.y*(3-2*t.y), t.z*t.z*(3-2*t.z)}
	c: [8]f32
	for k in 0 ..< 8 {
		c[k] = rock_lattice(i.x+i32(k&1), i.y+i32((k>>1)&1), i.z+i32((k>>2)&1), seed)
	}
	x00 := math.lerp(c[0], c[1], s.x)
	x10 := math.lerp(c[2], c[3], s.x)
	x01 := math.lerp(c[4], c[5], s.x)
	x11 := math.lerp(c[6], c[7], s.x)
	return math.lerp(math.lerp(x00, x10, s.y), math.lerp(x01, x11, s.y), s.z)
}

// How far the rock stands off the smooth face at `p`, in metres. `f` is the
// position up the profile: 0 at the road edge, 1 at the crest, and the offset is
// zero at both.
// Positive stands toward the road, negative cuts back into the hillside, and
// `height` is the cliff's, which is what sets how big its rock can be.
//
// `room` is how far this vertex may come toward the road before it crosses the
// road edge: the distance the smooth face has already leaned out by, measured
// along the normal. It is the *only* fence, and it is a hard one — the rock the
// eye reads as rock is the part standing toward you, and on a sheer cut there
// is nowhere for it to stand. That is geometry, not tuning: lean the face back
// (the angle slider) and the room appears.
rock_offset :: proc(p: gfx.Vector3, height, f, room: f32) -> f32 {
	sum, total, amp, wave := f32(0), f32(0), f32(1), f32(CLIFF_ROCK_WAVE)
	for i in 0 ..< CLIFF_ROCK_OCTAVES {
		sum += rock_octave(p / wave, u32(i) * 0x9E3779B9) * amp
		total += amp
		amp *= CLIFF_ROCK_KEEP
		wave *= 0.5
	}
	// Stretched to its extremes, and centred on the cut. Summed noise piles up
	// around its middle, so without the stretch every column gets the same shape
	// at the same height — one dip running the length of the cliff. Without the
	// centring every column gets it in the same *direction*, which is a face
	// that only ever hollows out.
	n := clamp((sum / total) * CLIFF_ROCK_CONTRAST, -1, 1)
	h := n * (CLIFF_ROCK_DEPTH * height) * (4 * f * (1 - f))
	// Cutting the protrusions off at the road edge would leave a flat spot every
	// time one reached it, and a flat spot in a rough face is a step with a
	// steep triangle either side of it. Scale that half to fit the room instead.
	return h > 0 ? h * min(1, room / max(abs(h), 1e-3)) : h
}

// Road-surface tessellation.
//
// The ribbon is subdivided *along* its length by SAMPLES_PER_SEG; ROAD_COLS splits each
// rung into this many columns across its width, so the surface is a grid. That
// is what gives the roughness field interior vertices to displace: a single
// full-width quad can only tilt, not undulate.
//
// The count is fixed and global, never per-segment: adjacent segments share a
// rung, and two segments splitting that shared rung into different column counts
// would leave a T-junction crack in a non-indexed soup.
ROAD_COLS :: 6

// Roughness is a small **vertical** (world +Y) jitter on the road-surface
// vertices, so a stage reads as a rough rally surface rather than a billiard
// table. The amplitude is a hard cap, not a soft target: no road vertex is ever
// displaced more than ROUGH_MAX_M above or below the smooth surface its
// neighbours define. The tightest constraint is the Trackmania Stadium car, which
// cannot take real ruts — 7 inches is enough to feel through its suspension and
// small enough not to launch it.
//
// Only the *interior* columns are displaced; the two edge columns stay exactly on
// the road edge, so the surface remains welded to the verges and the terrain,
// which both key off the un-jittered road edge (see verge_vertex row 0).
ROUGH_MAX_M :: 0.1778 // 7 inches, in metres

// Baked key light. Unlit material, so shading lives in the vertex colours.
LIGHT_DIR :: gfx.Vector3{0.40, 1.00, 0.30}
AMBIENT :: 0.38

// Metres of surface per tile of a base texture. Every UV below is *metres over
// this*, in both axes, so texel density is uniform and nothing stretches: a road
// on a 1-in-4 grade tiles at the same rate as a flat one.
//
// The viewport ignores UVs (its material is unlit and untextured). They exist
// for the export, which cannot recover them: the road's `u` runs across the
// ribbon and its `v` along the arc, and a triangle soup has thrown away both.
// Not every target's material reads them (export.odin).
UV_TILE_M :: 8.0

// --- CPU triangle soup ------------------------------------------------------

// What a triangle is made of, said in terms no one game owns. The viewport
// ignores it — it shades from the baked vertex colours — and each export target
// maps it onto that game's own material (see D3_MATERIAL_KEY in d3/venue_profile.odin).
// The soup is sorted by this before export, because every target we have binds
// one material per *contiguous group* of triangles. Adding a value here means
// adding a row to every target's material table.
Mat_Id :: enum u8 {
	Road,     // dirt look, Dirt grip
	Cliff,
	Terrain,
	// The road surface is a checkered mix of Road (Dirt grip) and RoadSand: both
	// wear the same dirt texture, but RoadSand drives as the Sand penalty surface.
	// ~1/3 of the road segments are RoadSand, so a car feels a mostly-dirt surface
	// with a sand penalty scattered through it. See build_road_surface /
	// road_surf_mat.
	RoadSand, // dirt look, Sand penalty
}

// `pos`, `nrm`, `uv` and `col` are per *vertex* (three per triangle,
// flat-shaded); `mat` is per *triangle*, so `mat[i]` describes
// `pos[i*3 .. i*3+2]`.
Tri_Mesh :: struct {
	pos: [dynamic]gfx.Vector3,
	nrm: [dynamic]gfx.Vector3,
	uv:  [dynamic][2]f32,
	col: [dynamic]gfx.Color,
	mat: [dynamic]Mat_Id,
}

tri_mesh_make :: proc(allocator := context.allocator) -> Tri_Mesh {
	return Tri_Mesh {
		pos = make([dynamic]gfx.Vector3, allocator),
		nrm = make([dynamic]gfx.Vector3, allocator),
		uv = make([dynamic][2]f32, allocator),
		col = make([dynamic]gfx.Color, allocator),
		mat = make([dynamic]Mat_Id, allocator),
	}
}

tri_mesh_delete :: proc(m: ^Tri_Mesh) {
	delete(m.pos)
	delete(m.nrm)
	delete(m.uv)
	delete(m.col)
	delete(m.mat)
}

tri_count :: proc(m: Tri_Mesh) -> int {
	return len(m.pos) / 3
}

// Shade a colour by the baked light. Flat normals, so this is per-face.
shade :: proc(col: gfx.Color, n: gfx.Vector3) -> gfx.Color {
	l := gfx.Vector3Normalize(LIGHT_DIR)
	k := AMBIENT + (1 - AMBIENT) * max(0, gfx.Vector3DotProduct(n, l))
	return gfx.Color{u8(f32(col.r) * k), u8(f32(col.g) * k), u8(f32(col.b) * k), col.a}
}

// Winding is counter-clockwise seen from the front, so the face normal is
// cross(b-a, c-a). Callers must order their vertices accordingly.
// `ua`/`ub`/`uc` are the corners' UVs, in the same order as the positions.
add_tri :: proc(m: ^Tri_Mesh, a, b, c: gfx.Vector3, ua, ub, uc: [2]f32, col: gfx.Color, mat: Mat_Id) {
	n := gfx.Vector3CrossProduct(b - a, c - a)
	if gfx.Vector3Length(n) < 1e-9 {
		return // degenerate, e.g. a cliff of zero height
	}
	n = gfx.Vector3Normalize(n)
	sc := shade(col, n)
	uvs := [3][2]f32{ua, ub, uc}
	for v, i in ([]gfx.Vector3{a, b, c}) {
		append(&m.pos, v)
		append(&m.nrm, n)
		append(&m.uv, uvs[i])
		append(&m.col, sc)
	}
	// After the degenerate bail, so `mat` stays one entry per emitted triangle.
	append(&m.mat, mat)
}

add_quad :: proc(
	m: ^Tri_Mesh,
	a, b, c, d: gfx.Vector3,
	ua, ub, uc, ud: [2]f32,
	col: gfx.Color,
	mat: Mat_Id,
) {
	add_tri(m, a, b, c, ua, ub, uc, col, mat)
	add_tri(m, a, c, d, ua, uc, ud, col, mat)
}

// --- verge geometry ---------------------------------------------------------
//
// A *verge* is the cross-section between the road edge and the point where the
// terrain takes over. It is a polyline in the road frame's (outward, up) plane,
// starting at the road edge, and it is swept along the road to make a surface.
//
// Today the only verge is a cliff: one segment, rising outward. A ditch is the
// same idea with a segment that falls before it rises, and a ditch with a cliff
// behind it is three segments. Nothing outside this section knows which, and in
// particular the terrain (terrain.odin) consumes only `verge_seam` — the
// profile's last point — so it needs no change when ditches land.
//
// This is why a ditch is *not* a negative cliff height: the sign of one number
// cannot add a vertex to the profile.

// Deterministic per-vertex hash. The jitter must not change frame to frame, and
// adjacent quads must agree on a shared vertex or the verge tears open.
hash_u32 :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

// side 0 = the verge on the ribbon's `left` end (+right), side 1 = the other.
cliff_height :: proc(cs: Cross_Section, side: int) -> f32 {
	return side == 0 ? cs.cliff_l : cs.cliff_r
}

// A point on the profile: metres outward from the road edge, metres up from it.
// `up` is the road frame's, so a banked road banks its verges with it.
Verge_Point :: [2]f32

// Room for the ditch profile (fall, rise, and a cliff behind it) without
// resizing anything. `pts[0]` is always the road edge, {0,0}.
VERGE_MAX_PTS :: 4

Verge_Profile :: struct {
	pts: [VERGE_MAX_PTS]Verge_Point,
	n:   int, // points in use, >= 1; n < 2 means "no verge this side"
	len: f32, // total arc length of the polyline
}

// The profile at one cross-section, one side.
verge_profile :: proc(cs: Cross_Section, side: int) -> Verge_Profile {
	p: Verge_Profile
	p.n = 1 // pts[0] = {0,0}, the road edge
	if h := cliff_height(cs, side); h > CLIFF_MIN {
		// The face is a plane tilted `cliff_angle` degrees off vertical, so its
		// horizontal run is height * tan(angle) — linear in height, not curved.
		// A negative angle leans the face back over the road.
		a := clamp(cs.cliff_angle, CLIFF_ANGLE_MIN, CLIFF_ANGLE_MAX)
		p.pts[1] = {h * math.tan(math.to_radians(a)), h}
		p.n = 2
	}
	for i in 1 ..< p.n {
		d := p.pts[i] - p.pts[i - 1]
		p.len += math.sqrt(d.x * d.x + d.y * d.y)
	}
	return p
}

// Walk the profile to the point `f` of the way along its arc length. f=1 returns
// the last point exactly, rather than whatever the accumulated float lands on:
// the terrain welds to it, so it must be reproducible bit for bit.
verge_sample :: proc(p: Verge_Profile, f: f32) -> Verge_Point {
	if p.n < 2 || f <= 0 {
		return p.pts[0]
	}
	if f >= 1 {
		return p.pts[p.n - 1]
	}
	target := p.len * f
	acc: f32
	for i in 1 ..< p.n {
		d := p.pts[i] - p.pts[i - 1]
		seg := math.sqrt(d.x * d.x + d.y * d.y)
		if seg <= 0 {
			continue
		}
		if acc + seg >= target {
			return p.pts[i - 1] + d * ((target - acc) / seg)
		}
		acc += seg
	}
	return p.pts[p.n - 1]
}

// The face's own outward normal: the profile's direction turned a quarter turn
// in the (outward, up) plane. A vertical face gives plain `outward`; a face laid
// back on its angle tips the normal over with it, which is what puts height
// variation into the crest of a shallow cliff and none into a sheer one.
verge_normal :: proc(cs: Cross_Section, prof: Verge_Profile, side: int) -> gfx.Vector3 {
	outward := side == 0 ? cs.right : -cs.right
	if prof.n < 2 { return outward }
	d := prof.pts[prof.n-1] - prof.pts[0]
	l := math.sqrt(d.x*d.x + d.y*d.y)
	if l <= 0 { return outward }
	return (outward * d.y - cs.up * d.x) / l
}

// A vertex on the swept verge face.
//
// Row 0 sits exactly on the road edge, undisplaced, so the verge is watertight
// with the road surface. The rock ramps in along the profile from there.
//
// The displacement is a function of the *smooth* face position and nothing else
// — no ribbon index, no row number, no tessellation. Two callers that agree on
// the cross-section agree on the vertex, to the bit, without having to agree on
// how they got there.
//
// `roughness` is the global slider, and this slice's own `cliff_rough` adds to
// it — the same arrangement the road surface has with its per-node offset, and
// deliberately a separate number from it. A cliff is rock; the road is what a
// car drives on.
verge_vertex :: proc(
	cs: Cross_Section,
	prof: Verge_Profile,
	side, row, rows: int,
	roughness: f32,
) -> gfx.Vector3 {
	outward := side == 0 ? cs.right : -cs.right
	edge := cs.pos + outward * (cs.width * 0.5)
	if prof.n < 2 || prof.len <= 0 || row == 0 {
		return edge
	}

	f := f32(row) / f32(rows)
	q := verge_sample(prof, f)
	p := edge + outward * q.x + cs.up * q.y

	eff := clamp(roughness + cs.cliff_rough, 0, 1)
	if eff <= 0 {
		return p
	}
	// How big the rock may be is the cliff's *height*, never the length of its
	// face. Lay a 7 m cliff back to 75 degrees and its face is 25 m long, so an
	// amplitude keyed off that length juts 18 m out of the middle of it.
	top := prof.pts[prof.n - 1]
	// cos(face angle) is the normal's outward part, so the lean at this row over
	// it is the room the rock has to come toward the road in.
	room := q.x * prof.len / max(top.y, 1e-3)
	return p - verge_normal(cs, prof, side) * (rock_offset(p, top.y, f, room) * eff)
}

// One cross-section's face, bottom to top: the vertices, and `v` beside them.
//
// `v` is metres along the *rock*, accumulated from the vertices themselves, not
// metres along the smooth cut they were drawn on. The two differ by however far
// the rock stands off, which is metres — a texture laid out on the smooth cut
// stretches over every lump and squashes into every hollow. Same reason `u` runs
// along the road's arc: UVs here are metres over UV_TILE_M in both axes, so the
// texel density is meant to be uniform.
//
// (`u` is still the smooth arc. Two neighbouring samples differ in displacement
// by far less than two neighbouring rows do, and a per-row `u` would have to
// accumulate along the whole road, per row, across branches.)
Verge_Column :: struct {
	p: [VERGE_ROWS + 1]gfx.Vector3,
	v: [VERGE_ROWS + 1]f32,
}

verge_column :: proc(
	cs: Cross_Section,
	prof: Verge_Profile,
	side, rows: int,
	roughness: f32,
) -> (col: Verge_Column) {
	for k in 0 ..= min(rows, VERGE_ROWS) {
		col.p[k] = verge_vertex(cs, prof, side, k, rows, roughness)
		if k > 0 {
			col.v[k] = col.v[k - 1] + gfx.Vector3Length(col.p[k] - col.p[k - 1])
		}
	}
	return
}

// Where the verge hands off to the terrain: the profile's last point, rock and
// all. A cliff's crest; a ditch's outer lip; the bare road edge where there is
// no verge at all, which is exactly right and needs no special case.
//
// **The terrain's innermost column must be this proc, called with this sample's
// own cross-section and `roughness`.** The two meshes share no vertex buffer —
// they are welded only by both emitting bit-identical positions. Recompute the
// seam any other way and the skirt tears off the verge.
verge_seam :: proc(cs: Cross_Section, side, rows: int, roughness: f32) -> gfx.Vector3 {
	return verge_vertex(cs, verge_profile(cs, side), side, rows, rows, roughness)
}

// --- building ---------------------------------------------------------------

ROAD_COL :: gfx.Color{104, 108, 120, 255}      // Dirt-grip segments (editor tint)
ROAD_COL_SAND :: gfx.Color{150, 138, 120, 255} // Sand-penalty segments (editor tint)
CLIFF_TOP :: gfx.Color{140, 128, 112, 255}
CLIFF_BOT :: gfx.Color{86, 80, 74, 255}

lerp_col :: proc(a, b: gfx.Color, t: f32) -> gfx.Color {
	m :: proc(x, y: u8, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * t)}
	return gfx.Color{m(a.r, b.r, t), m(a.g, b.g, t), m(a.b, b.b, t), 255}
}

// Which surface a road segment gets: ~2 in 3 keep Dirt grip, ~1 in 3 are the
// Sand penalty. Hashed on the segment index so it is deterministic and scattered
// along the road rather than clumping or striping. A whole segment (all its width
// columns) takes one surface, so with short segments the car switches
// surface every few centimetres of travel — fast enough to feel like one blended
// surface that reads as mostly dirt.
road_surf_mat :: proc(seg: int) -> Mat_Id {
	return hash_u32(u32(seg) * 73856093) % 3 == 0 ? .RoadSand : .Road
}

// One road-surface vertex: ribbon sample `s`, column `col` of `cols` across the
// width. `col == 0` is the +right edge (v = 0), `col == cols` the far edge
// (v = -1). Returns the world position (roughness applied) and its `v`.
//
// The vertical roughness offset is deterministic — a hash of (sample, column), not
// a per-frame random — so the vertex shared by two adjacent segments lands in the
// same place from either side and the surface does not tear. The edge columns are
// never displaced (watertight with the verges/terrain), and the offset fades to
// zero as a column approaches either edge, so the ramp in is smooth. Amplitude is
// the effective roughness (global slider + this slice's per-node offset, clamped
// to [0,1]) times ROUGH_MAX_M — the hard 7-inch cap.
road_vertex :: proc(
	cs: Cross_Section,
	s, col, cols: int,
	global_rough: f32,
) -> (pos: gfx.Vector3, v: f32) {
	left, right := xsec_ends(cs) // left = +right edge, right = far edge
	f := f32(col) / f32(cols)
	pos = left + (right - left) * f
	v = -f
	if col == 0 || col == cols {
		return // edge columns: no jitter, so the weld holds
	}
	eff := clamp(global_rough + cs.roughness, 0, 1)
	if eff <= 0 {
		return
	}
	fade := 4 * f * (1 - f) // parabola: 0 at both edges, 1 at the centre
	amp := eff * ROUGH_MAX_M * fade
	h := hash_u32(u32(s) * 2654435761 ~ u32(col) * 2246822519)
	j := f32(h) / f32(max(u32)) * 2 - 1 // [-1, 1]
	pos.y += j * amp
	return
}

// Road surface. The quad (left_i, right_i, right_i+1, left_i+1) winds so that
// its face normal comes out as +up; see the frame identity in spline.odin.
//
// UV: `u` runs **along** the arc and tiles; `v` runs across the ribbon, 0 at one
// edge and -1 at the other. This is the base chart — `u` across [0,1], `v` along
// the arc — turned a quarter turn by `(u,v) -> (v, -u)`, which lays the dirt's
// grain down the road instead of across it.
//
// **That is a rotation, not a transpose.** Swapping `u` and `v` mirrors the chart
// and flips the tangent handedness (`dot(cross(T,B), N)` changes sign); rotating
// preserves it, which is why the negation is there. It is the chart the tangent
// frame was built for.
//
// `u` runs to the hundreds and the road renders fine, so a `BaseMaterial` UV has
// no [0,1] constraint. The across-road extent is *normalised*, not scaled by
// UV_TILE_M, so the texture spans the road exactly once at any width.
build_road_surface :: proc(m: ^Tri_Mesh, ribbon: []Cross_Section, arc: []f32, roughness: f32) {
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		// `xsec_ends` returns the +right end first, so that end takes v = 0.
		ua := arc[i] / UV_TILE_M
		ub := arc[i + 1] / UV_TILE_M
		mat := road_surf_mat(i)
		// Editor-only tint so the hidden penalty mix is visible: Dirt grip keeps the
		// road grey, Sand penalty runs a touch warmer. No target writes vertex
		// colour, so in game both read as plain dirt.
		col := mat == .Road ? ROAD_COL : ROAD_COL_SAND
		for c in 0 ..< ROAD_COLS {
			a0, va0 := road_vertex(ribbon[i], i, c, ROAD_COLS, roughness)
			a1, va1 := road_vertex(ribbon[i], i, c + 1, ROAD_COLS, roughness)
			b1, vb1 := road_vertex(ribbon[i + 1], i + 1, c + 1, ROAD_COLS, roughness)
			b0, vb0 := road_vertex(ribbon[i + 1], i + 1, c, ROAD_COLS, roughness)
			add_quad(m, a0, a1, b1, b0, {ua, va0}, {ua, va1}, {ub, vb1}, {ub, vb0}, col, mat)
		}
	}
}

// Along-road spacing at each sample: distance to the next one, and for the last
// sample the distance to the previous. A property of the sample, so every quad
// that touches sample i jitters it identically. Temp-allocated.
sample_spacing :: proc(ribbon: []Cross_Section) -> []f32 {
	n := len(ribbon)
	ds := make([]f32, n, context.temp_allocator)
	for i in 0 ..< n - 1 {
		ds[i] = ribbon[i + 1].break_before ? 0 : gfx.Vector3Distance(ribbon[i].pos, ribbon[i + 1].pos)
	}
	ds[n - 1] = ds[n - 2]
	return ds
}

// Verge walls. Emitted only where a verge has a profile at all, so a stage with
// no cliffs costs no triangles.
//
// UV: `u` along the road's arc, `v` along the *profile's* arc — the same
// quantity the rows are spaced by, so a taller cliff shows more texture rather
// than a stretched one. The two neighbouring cross-sections have different
// profile lengths, so `v` is computed per column, not per quad.
build_verges :: proc(m: ^Tri_Mesh, ribbon: []Cross_Section, rows: int, roughness: f32) {
	for side in 0 ..< 2 {
		// Metres along the rock, the same way `v` is metres up it. The road's own
		// arc is the wrong ruler here: two neighbouring samples can stand a metre
		// apart on the smooth cut and four metres apart once their rock is on,
		// which stretches the texture by as much again.
		//
		// One number for the whole rung, advanced by what its rows moved on
		// average — not one per row. Per-row runs drift apart over a few hundred
		// metres of road, and a quad whose two corners are twenty metres apart in
		// `u` is sheared beyond anything the stretch was worth fixing.
		//
		// Never reset, not even where a quad is skipped. Twins at a node sit in
		// the same place, so the run carries across a break with nothing added,
		// and a reset there would put a texture seam at every node.
		u_run: f32
		for i in 0 ..< len(ribbon) - 1 {
			if ribbon[i + 1].break_before { continue }
			p0 := verge_profile(ribbon[i], side)
			p1 := verge_profile(ribbon[i + 1], side)
			if p0.n < 2 && p1.n < 2 {
				continue
			}
			ca := verge_column(ribbon[i], p0, side, rows, roughness)
			cb := verge_column(ribbon[i + 1], p1, side, rows, roughness)
			step: f32
			for k in 0 ..= min(rows, VERGE_ROWS) {
				step += gfx.Vector3Length(cb.p[k] - ca.p[k])
			}
			ua := u_run / UV_TILE_M
			ub := (u_run + step / f32(min(rows, VERGE_ROWS) + 1)) / UV_TILE_M
			defer u_run = ub * UV_TILE_M
			for k in 0 ..< rows {
				a, b := ca.p[k], ca.p[k + 1]
				c, d := cb.p[k + 1], cb.p[k]
				col := lerp_col(CLIFF_BOT, CLIFF_TOP, f32(k) / f32(rows))

				uv_a := [2]f32{ua, ca.v[k] / UV_TILE_M}
				uv_b := [2]f32{ua, ca.v[k + 1] / UV_TILE_M}
				uv_c := [2]f32{ub, cb.v[k + 1] / UV_TILE_M}
				uv_d := [2]f32{ub, cb.v[k] / UV_TILE_M}

				// Sweeping the profile along the road gives each quad the normal
				// cross(fwd, t) on side 0 and cross(t, fwd) on side 1, where t is
				// the profile tangent (b - a). One fixed sign per side, and the
				// profile's own direction does the rest: a rising cliff faces back
				// at the road, and a ditch's floor and outer wall come out facing
				// up and back at it too. Do not re-derive this from "point at the
				// centreline" — that rule flips sign partway along a ditch.
				if side == 0 {
					add_quad(m, a, d, c, b, uv_a, uv_d, uv_c, uv_b, col, .Cliff)
				} else {
					add_quad(m, a, b, c, d, uv_a, uv_b, uv_c, uv_d, col, .Cliff)
				}
			}
		}
	}
}

// How many rows a verge profile is swept into. Tied to SAMPLES_PER_SEG so the
// verge tessellates in step with the ribbon it hangs off.
VERGE_ROWS :: min(max(SAMPLES_PER_SEG / 3, 2), 12)

build_tri_mesh :: proc(
	ribbon: []Cross_Section,
	roughness: f32,
	allocator := context.allocator,
) -> Tri_Mesh {
	m := tri_mesh_make(allocator)
	if len(ribbon) < 2 {
		return m
	}
	arc := ribbon_arc(ribbon) // temp-allocated; the UVs are metres along it
	build_road_surface(&m, ribbon, arc, roughness)
	build_verges(&m, ribbon, VERGE_ROWS, roughness)
	return m
}

// --- GPU upload -------------------------------------------------------------

// An uploaded triangle soup. Not road-specific: the road and the terrain
// (terrain.odin) are two of these, drawn separately so either can be toggled.
// A nil buffer means headless (no GPU device): building still counts the
// triangles, and drawing skips the mesh.
Gpu_Mesh :: struct {
	mesh: gfx.Mesh,
	tris: int,
}

gpu_mesh_unload :: proc(rm: ^Gpu_Mesh) {
	gfx.mesh_free(&rm.mesh)
	rm^ = {}
}

// Copy the soup into a backend-owned buffer. The backend copies the vertices
// synchronously, so the Tri_Mesh may be temp-allocated.
gpu_mesh_upload :: proc(m: Tri_Mesh) -> Gpu_Mesh {
	n := len(m.pos)
	if n == 0 {
		return {}
	}
	verts := make([]gfx.Upload_Vertex, n, context.temp_allocator)
	for i in 0 ..< n {
		verts[i] = {pos = m.pos[i], col = m.col[i]}
	}
	return Gpu_Mesh{mesh = gfx.mesh_upload(verts), tris = n / 3}
}

// Rebuild the whole thing from the ribbon. The old GPU buffers are released
// first, so callers may call this every frame while a gizmo is dragged.
road_mesh_rebuild :: proc(rm: ^Gpu_Mesh, ribbon: []Cross_Section, roughness: f32) {
	gpu_mesh_unload(rm)
	m := build_tri_mesh(ribbon, roughness, context.temp_allocator)
	rm^ = gpu_mesh_upload(m)
}

gpu_mesh_draw :: proc(rm: Gpu_Mesh, mat: gfx.Material, wireframe: bool) {
	if rm.mesh.buffer == nil {
		return
	}
	// Every face is single-sided and correctly wound for export: the road faces
	// up, and a cliff faces the road it grew from. In the editor the camera
	// orbits freely, so culling would make cliffs vanish whenever you look at
	// their backs. Draw both sides here; the mesh itself is unchanged.
	gfx.DisableBackfaceCulling()
	defer gfx.EnableBackfaceCulling()

	// Not `defer` inside the if: Odin scopes defer to the enclosing block, so it
	// would disable wire mode before the draw rather than after.
	if wireframe {
		gfx.EnableWireMode()
	}
	gfx.DrawMesh(rm.mesh, mat, gfx.Matrix(1))
	if wireframe {
		gfx.DisableWireMode()
	}
}
