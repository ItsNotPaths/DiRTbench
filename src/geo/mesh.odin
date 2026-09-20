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

// Side-guard shape. A guard's size, span, taper and knobs are the guard's own
// (see Guard in spline.odin); these are the limits and the constants that give
// each kind its character.
GUARD_MIN :: 0.01 // below this a guard is nothing, and emits no geometry

// Cliff face angle limits, degrees off vertical. Negative overhangs the road;
// the lower bound is small because a steep overhang would let the cliff face
// poke down through the road surface it grew from.
CLIFF_ANGLE_MIN :: -5.0
CLIFF_ANGLE_MAX :: 75.0

// Slider ranges, metres. A rally stage is walled by rock cuttings and banks a
// car could plausibly be contained by, not by canyon faces.
CLIFF_HEIGHT_MAX :: 7.0
BANK_HEIGHT_MAX :: 3.0
BANK_WIDTH_MAX :: 12.0
// A gutter deep enough to swallow a wheel is already a stage-ending ditch, and
// the width is what keeps its walls off vertical.
GUTTER_DEPTH_MAX :: 2.0
GUTTER_WIDTH_MAX :: 10.0

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
// maps it onto that game's own material and surface code (see MAT_EXPORT in
// app/export.odin, and D3_DRAW_KEY in d3/venue_profile.odin).
// The soup is sorted by this before export, because every target we have binds
// one material per *contiguous group* of triangles. Adding a value here means
// adding a row to every target's material table.
Mat_Id :: enum u8 {
	Road,       // the venue's own loose road: gravel, dirt, packed snow
	Cliff,
	Terrain,
	Road_Paved, // its hard road: tarmac, or concrete where the venue has no tarmac
	// Ground within TERRAIN_ROADSIDE_M of a bare road edge. Ordinary terrain in
	// every way that drives; it exists only so the ground can fade into the road
	// instead of meeting it at a line. A ground shader holds two textures, so two
	// materials can never blend into each other — only a third holding both can,
	// and this is it. See MAT_EXPORT in app/export.odin.
	Roadside,
	// The drainage cut at the road edge. Washed-out road dirt rather than the
	// grass it used to wear: water runs off the road into it, so what collects
	// there is what came off the road. Drives as ground, the way it always did.
	Gutter,
	// Road within ROAD_CHANGE_M of a surface change, drawn with one material
	// holding both surfaces so the paint can cross gradually. Two of them for
	// one drawn material, because the code under the car cannot fade: grip flips
	// at the control point while the texture is still half way through.
	Road_Change_Loose,
	Road_Change_Paved,
}

// What a run of road is made of. Deliberately venue-neutral: the same value is
// gravel in Finland and packed snow in Norway, because the art and the collision
// code behind it come from the venue's own palette. `None` is not a surface —
// it means this control point states nothing and takes what reaches it from
// upstream. See Point.surface.
Road_Surface :: enum u8 {
	None,
	Loose,
	Paved,
}

road_surface_mat :: proc(surface: Road_Surface) -> Mat_Id {
	return surface == .Paved ? .Road_Paved : .Road
}

// The same, for road that is mid-change. One drawn material, two codes.
road_change_mat :: proc(surface: Road_Surface) -> Mat_Id {
	return surface == .Paved ? .Road_Change_Paved : .Road_Change_Loose
}

// `pos`, `nrm`, `uv`, `col` and `blend` are per *vertex* (three per triangle,
// flat-shaded); `mat` is per *triangle*, so `mat[i]` describes
// `pos[i*3 .. i*3+2]`.
Tri_Mesh :: struct {
	pos: [dynamic]gfx.Vector3,
	nrm: [dynamic]gfx.Vector3,
	uv:  [dynamic][2]f32,
	col: [dynamic]gfx.Color,
	mat: [dynamic]Mat_Id,
	// How far this vertex leans toward the material's *second* ground texture,
	// 0..1. A DiRT 3 ground shader carries two diffuse layers and mixes them by
	// the vertex colour, so one material can fade between two looks instead of
	// meeting the next one at a hard edge. The target interpolates the
	// material's two vertex colours by this; see D3_Venue_Profile.colour_b. A
	// target with one texture per material ignores it. 0 everywhere reproduces
	// the single-texture look exactly.
	blend: [dynamic]f32,
}

tri_mesh_make :: proc(allocator := context.allocator) -> Tri_Mesh {
	return Tri_Mesh {
		pos = make([dynamic]gfx.Vector3, allocator),
		nrm = make([dynamic]gfx.Vector3, allocator),
		uv = make([dynamic][2]f32, allocator),
		col = make([dynamic]gfx.Color, allocator),
		mat = make([dynamic]Mat_Id, allocator),
		blend = make([dynamic]f32, allocator),
	}
}

tri_mesh_delete :: proc(m: ^Tri_Mesh) {
	delete(m.pos)
	delete(m.nrm)
	delete(m.uv)
	delete(m.col)
	delete(m.mat)
	delete(m.blend)
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
// `ua`/`ub`/`uc` are the corners' UVs, in the same order as the positions, and
// `blend` their texture mix (see Tri_Mesh.blend).
add_tri :: proc(
	m: ^Tri_Mesh,
	a, b, c: gfx.Vector3,
	ua, ub, uc: [2]f32,
	col: gfx.Color,
	mat: Mat_Id,
	blend: [3]f32 = {},
) {
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
		append(&m.blend, blend[i])
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
	blend: [4]f32 = {},
) {
	add_tri(m, a, b, c, ua, ub, uc, col, mat, {blend[0], blend[1], blend[2]})
	add_tri(m, a, c, d, ua, uc, ud, col, mat, {blend[0], blend[2], blend[3]})
}

// --- verge geometry ---------------------------------------------------------
//
// A *verge* is the cross-section between the road edge and the point where the
// terrain takes over. It is a polyline in the road frame's (outward, up) plane,
// starting at the road edge, and it is swept along the road to make a surface.
//
// One segment per side-guard face, always in the same order and always all of
// them: gutter down, gutter up, bank up, bank down, cliff. An absent guard is
// not a shorter polyline — it is one whose two points sit on top of each other,
// so the row a sweep spends there lands where the last one did and the quad
// between them is degenerate. add_tri drops those.
//
// **That fixed layout is the whole trick.** Rows are handed out per segment, so
// how finely the cliff is cut does not depend on whether there is a gutter in
// front of it, and two neighbouring cross-sections agree on what row 7 means
// even when one has a bank and the other does not. The alternative — spacing
// rows by the polyline's total arc — rounds the corners off every shape and
// re-cuts the cliff whenever the gutter beside it changes width.
//
// Nothing outside this section knows which guards are in play. In particular
// the terrain (terrain.odin) consumes only `verge_seam`, the profile's last
// point, whatever built it.
//
// This is why a gutter is *not* a negative cliff height: the sign of one number
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

// --- road detachment ----------------------------------------------------------
//
// The ground standing off the road, swooping between two knobs along its length.
//
// The road never moves: it is authored geometry, and the terrain is welded to
// the verge seam (terrain.odin). So detachment is the *ground* letting go, and
// it is built here rather than in the terrain field for one reason — the field's
// nearest vertex to the road stands `cell_m * TERRAIN_RIM_MARGIN` clear of the
// rim, metres out, to keep Delaunay from pairing it with the rim into slivers.
// A half-metre step cannot be drawn by a mesh whose first vertex is two metres
// away. The verge already tessellates exactly this band, so the step is its
// outermost segment and every consumer of `verge_seam` follows for free.
//
// Positive falls away, which reads as the road up on a low embankment. Negative
// rises, which reads as a lip of ground along the road edge.
DETACH_RUN :: 0.5   // metres out the step takes to happen
DETACH_LIMIT :: 0.75 // furthest either knob may be dragged, each way

// Metres across the largest swoop. Long against a half-metre step, so the road
// detaches and rejoins over hundreds of metres rather than rippling.
DETACH_WAVE :: 150.0

// Detachment always goes to nothing where roads meet.
//
// Two edges into one node let go of the ground independently. A fork with both
// sides dropped tears: the branch's verge falls away across the mouth of the
// road it just left, and the seam the terrain welds to arrives at the node from
// two directions at two heights. Fading over the last stretch hands every
// junction back flat, where the two roads join flush and the verges agree.
//
// Long enough that two roads leaving a node at a shallow angle have pulled
// clear of each other before either starts to drop.
DETACH_JOIN_M :: 24.0

// The two ends of the swoop, in metres. Both zero is the feature off.
Detach_Opts :: struct {
	min_m, max_m: f32,
}

detach_on :: proc(o: Detach_Opts) -> bool {
	return o.min_m != 0 || o.max_m != 0
}

// Where a spot sits in the swoop, -1..1.
//
// One octave of the value noise the cliff rock uses, read off world XZ rather
// than road arc. Arc is the obvious axis and the wrong one: `ribbon_arc`
// accumulates straight across a run break, and either side of a fork the two
// branches carry different arc at the same place, so the ground would let go by
// different amounts on two roads meeting at a node. Position agrees with itself
// everywhere, including where two legs of a hairpin pass.
detach_noise :: proc(p: [2]f32) -> f32 {
	return rock_octave({p[0] / DETACH_WAVE, 0, p[1] / DETACH_WAVE}, 0x5EA15EA1)
}

// The fall at a world spot, in metres.
detach_at :: proc(o: Detach_Opts, p: [2]f32) -> f32 {
	n := clamp(detach_noise(p), -1, 1)
	return math.lerp(o.min_m, o.max_m, (n + 1) * 0.5)
}

// Which graph nodes two or more roads meet at. A plain chain point joins one
// road to itself and needs nothing. A fork, a merge and both ends of a weld are
// places two verges have to agree, and a weld counts whatever its degree says:
// it is the one edge the parent tree cannot express.
detach_joins :: proc(sp: Spline, allocator := context.temp_allocator) -> []bool {
	out := make([]bool, len(sp.points), allocator)
	deg := make([]int, len(sp.points), context.temp_allocator)
	for p, i in sp.points {
		if p.parent >= 0 && p.parent < len(sp.points) {
			deg[i] += 1
			deg[p.parent] += 1
		}
		if p.weld >= 0 && p.weld < len(sp.points) && p.weld != i {
			out[i], out[p.weld] = true, true
		}
	}
	for d, i in deg {
		if d > 2 {
			out[i] = true
		}
	}
	return out
}

// How much of the swoop survives at each sample: nothing at a junction, all of
// it DETACH_JOIN_M of road away from one.
//
// Distance is measured **along the road**, by two sweeps that both stop at a run
// break. A run is one graph edge, and the sample after a break is somewhere else
// entirely, so the straight-line distance between the two means nothing.
detach_join_fade :: proc(
	ribbon: []Cross_Section, join: []bool, allocator := context.temp_allocator,
) -> []f32 {
	FAR :: f32(1e9)
	n := len(ribbon)
	d := make([]f32, n, allocator)
	ds := sample_spacing(ribbon)
	at_node :: proc(cs: Cross_Section, join: []bool) -> bool {
		node := cs.t <= 1e-4 ? cs.e_from : cs.t >= 1 - 1e-4 ? cs.e_to : -1
		return node >= 0 && node < len(join) && join[node]
	}
	for cs, i in ribbon {
		d[i] = at_node(cs, join) ? 0 : FAR
	}
	for i in 1 ..< n {
		if !ribbon[i].break_before {
			d[i] = min(d[i], d[i - 1] + ds[i - 1])
		}
	}
	for i := n - 2; i >= 0; i -= 1 {
		if !ribbon[i + 1].break_before {
			d[i] = min(d[i], d[i + 1] + ds[i])
		}
	}
	for &v in d {
		v = math.smoothstep(f32(0), f32(DETACH_JOIN_M), v)
	}
	return d
}

// Stamp the swoop onto a built ribbon, the way resolve_guards stamps the guards.
// Read at the centreline, so both sides of the road let go together.
//
// Only the fall fades at a junction. The run holds, for the reason
// verge_profile gates on it: a seam that stepped sideways would do it at the one
// place two seams have to meet.
resolve_detach :: proc(sp: Spline, ribbon: []Cross_Section, o: Detach_Opts) {
	if !detach_on(o) || len(ribbon) < 2 {
		return
	}
	fade := detach_join_fade(ribbon, detach_joins(sp))
	for &cs, i in ribbon {
		cs.detach_run = DETACH_RUN
		fall := clamp(detach_at(o, {cs.pos.x, cs.pos.z}), -DETACH_LIMIT, DETACH_LIMIT)
		cs.detach_fall = fall * fade[i]
	}
}

// side 0 = the verge on the ribbon's `left` end (+right), side 1 = the other.
verge_size :: proc(cs: Cross_Section, side: int, kind: Guard_Kind) -> f32 {
	return cs.verge[side][kind].size
}

// A point on the profile: metres outward from the road edge, metres up from it.
// `up` is the road frame's, so a banked road banks its verges with it.
Verge_Point :: [2]f32

// The segments, in the order they are laid outward from the road edge.
Verge_Seg_Id :: enum u8 {
	Gutter_In,  // road edge down to the drain bottom
	Gutter_Out, // and back up to road level
	Bank_In,    // up to the bank crest
	Bank_Out,   // and back down to where the bank started
	Cliff,      // the rock face behind the lot
	Detach,     // the ground pulling away from whatever the verge ended at
}
VERGE_SEGS :: len(Verge_Seg_Id)
VERGE_PTS :: VERGE_SEGS + 1

// Rows the sweep spends on each segment. A guard that is not there still costs
// its rows, which land on one another and emit nothing — the price of a row
// layout that does not shift under the profile beside it.
VERGE_GUTTER_ROWS :: 2
VERGE_BANK_ROWS :: 2
VERGE_CLIFF_ROWS :: 4
// One. The detachment step is a straight fall, so extra rows on it would only
// put collinear vertices down the middle of a half-metre slope.
VERGE_DETACH_ROWS :: 1
VERGE_SEG_ROWS := [Verge_Seg_Id]int {
	.Gutter_In  = VERGE_GUTTER_ROWS,
	.Gutter_Out = VERGE_GUTTER_ROWS,
	.Bank_In    = VERGE_BANK_ROWS,
	.Bank_Out   = VERGE_BANK_ROWS,
	.Cliff      = VERGE_CLIFF_ROWS,
	.Detach     = VERGE_DETACH_ROWS,
}

// How many rows a verge profile is swept into, all segments together.
VERGE_ROWS :: 2 * VERGE_GUTTER_ROWS + 2 * VERGE_BANK_ROWS + VERGE_CLIFF_ROWS +
	VERGE_DETACH_ROWS

// What one segment inherits from the guard that drew it, so a vertex on it can
// be jittered without going back to the cross-section to ask whose it is.
Verge_Seg :: struct {
	size:   f32, // the guard's own size, which is what sizes its rock
	rough:  f32,
	// Where this segment sits in its guard's *own* face, 0 to 1. The jitter
	// fades to nothing at 0 and 1, so it dies at each guard's own ends rather
	// than only at the two ends of the whole profile — otherwise a bank with a
	// cliff behind it would be shaken loose from the road edge.
	f0, f1: f32,
	base_x: f32, // outward distance the guard's face starts at
	run:    f32, // arc length of the guard's whole face
}

Verge_Profile :: struct {
	pts: [VERGE_PTS]Verge_Point,
	seg: [Verge_Seg_Id]Verge_Seg,
	any: bool, // false means "no verge this side": every point is the road edge
	// A gutter, a bank or a cliff stands here. Split from `any` because
	// detachment also makes the sweep emit, and the two questions have
	// different answers: the ground beside a detached road is still ground
	// beside a bare road edge, so it still takes the road's own texture
	// (TERRAIN_ROADSIDE_M). A guard is what stops that.
	guarded: bool,
}

// The profile at one cross-section, one side. Guards stack outward in the order
// they are cut: the gutter at the road edge, the bank heaped outside it, the
// cliff rising behind both.
verge_profile :: proc(cs: Cross_Section, side: int) -> Verge_Profile {
	v := cs.verge[side]
	prof: Verge_Profile
	at := Verge_Point{0, 0} // outer end of what has been laid so far

	// A guard narrower than it is tall is a wall, and a wall at the road edge is
	// a vertical face the car cannot climb out of. The width floor is what keeps
	// every gutter and bank a slope.
	if g := v[.Gutter]; g.size > GUARD_MIN {
		w := max(g.width, g.size)
		prof.pts[1] = {at.x + w * 0.5, at.y - g.size}
		prof.pts[2] = {at.x + w, at.y}
		// No jitter on a gutter: it is a cut drain, not rock.
		at = prof.pts[2]
		prof.any = true
	} else {
		prof.pts[1], prof.pts[2] = at, at
	}

	if b := v[.Bank]; b.size > GUARD_MIN {
		w := max(b.width, b.size)
		prof.pts[3] = {at.x + w * 0.5, at.y + b.size}
		prof.pts[4] = {at.x + w, at.y}
		run := seg_len(at, prof.pts[3]) + seg_len(prof.pts[3], prof.pts[4])
		prof.seg[.Bank_In] = {size = b.size, rough = b.rough, f0 = 0, f1 = 0.5, base_x = at.x, run = run}
		prof.seg[.Bank_Out] = {size = b.size, rough = b.rough, f0 = 0.5, f1 = 1, base_x = at.x, run = run}
		at = prof.pts[4]
		prof.any = true
	} else {
		prof.pts[3], prof.pts[4] = at, at
	}

	if c := v[.Cliff]; c.size > GUARD_MIN {
		// The face is a plane tilted `angle` degrees off vertical, so its
		// horizontal run is height * tan(angle) — linear in height, not curved.
		// A negative angle leans the face back over the road.
		a := clamp(c.angle, CLIFF_ANGLE_MIN, CLIFF_ANGLE_MAX)
		prof.pts[5] = {at.x + c.size * math.tan(math.to_radians(a)), at.y + c.size}
		prof.seg[.Cliff] = {
			size = c.size, rough = c.rough, f0 = 0, f1 = 1,
			base_x = at.x, run = seg_len(at, prof.pts[5]),
		}
		prof.any = true
	} else {
		prof.pts[5] = at
	}
	at = prof.pts[5]
	prof.guarded = prof.any

	// The ground leaving the road, outward of everything else: whatever the
	// guards ended at is where it lets go. `run` at zero is the feature switched
	// off, and it is the geometric identity — the seam stays exactly where the
	// guards left it and this segment's row lands on the one before it.
	//
	// The run is gated on rather than the fall, so a stretch where the swoop
	// happens to pass through zero metres keeps the same seam offset as its
	// neighbours. Gating on the fall would step the seam half a metre sideways
	// between two adjacent samples, and the terrain welds to that seam.
	if cs.detach_run > 0 {
		prof.pts[6] = {at.x + cs.detach_run, at.y - cs.detach_fall}
		prof.any = true
	} else {
		prof.pts[6] = at
	}
	return prof
}

seg_len :: proc(a, b: Verge_Point) -> f32 {
	d := b - a
	return math.sqrt(d.x * d.x + d.y * d.y)
}

// Which segment a sweep row falls on, and how far along it. A row on a boundary
// belongs to the earlier segment, at its far end — the two answers name the same
// point, so nothing downstream can tell them apart.
verge_row_at :: proc(row: int) -> (seg: Verge_Seg_Id, t: f32) {
	r := clamp(row, 0, VERGE_ROWS)
	for id in Verge_Seg_Id {
		n := VERGE_SEG_ROWS[id]
		if r <= n {
			return id, f32(r) / f32(n)
		}
		r -= n
	}
	return .Cliff, 1
}

// Where a row sits on the smooth profile, before any rock is put on it.
verge_sample :: proc(p: Verge_Profile, row: int) -> Verge_Point {
	seg, t := verge_row_at(row)
	a, b := p.pts[int(seg)], p.pts[int(seg) + 1]
	return a + (b - a) * t
}

// The face's own outward normal on segment `seg`: that segment's direction
// turned a quarter turn in the (outward, up) plane. A vertical face gives plain
// `outward`; a face laid back on its angle tips the normal over with it, which
// is what puts height variation into the crest of a shallow cliff and none into
// a sheer one.
//
// Per segment rather than across the whole profile: a bank's two faces lean
// opposite ways, and one normal for both would push the rock sideways through
// the crest.
verge_normal :: proc(cs: Cross_Section, prof: Verge_Profile, side: int, seg: Verge_Seg_Id) -> gfx.Vector3 {
	outward := side == 0 ? cs.right : -cs.right
	d := prof.pts[int(seg) + 1] - prof.pts[int(seg)]
	l := math.sqrt(d.x * d.x + d.y * d.y)
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
// `roughness` is the global slider, and the guard that drew this segment adds
// its own on top — the same arrangement the road surface has with its per-node
// offset, and deliberately a separate number from it. A cliff is rock; the road
// is what a car drives on. A gutter carries no roughness at all, so its
// segments come out smooth however far the global slider is pushed.
verge_vertex :: proc(
	cs: Cross_Section,
	prof: Verge_Profile,
	side, row: int,
	roughness: f32,
) -> gfx.Vector3 {
	outward := side == 0 ? cs.right : -cs.right
	edge := cs.pos + outward * (cs.width * 0.5)
	if !prof.any || row <= 0 {
		return edge
	}

	seg, t := verge_row_at(row)
	q := verge_sample(prof, row)
	p := edge + outward * q.x + cs.up * q.y

	s := prof.seg[seg]
	eff := clamp(roughness + s.rough, 0, 1)
	if eff <= 0 || s.size <= 0 || s.run <= 0 {
		return p
	}
	// How big the rock may be is the guard's *size*, never the length of its
	// face. Lay a 7 m cliff back to 75 degrees and its face is 25 m long, so an
	// amplitude keyed off that length juts 18 m out of the middle of it.
	//
	// `f` is the position in the guard's own face, not in the whole profile, so
	// the fade lands on that guard's two ends.
	f := s.f0 + (s.f1 - s.f0) * t
	// cos(face angle) is the normal's outward part, so the lean this row has
	// over the foot of its own face is the room the rock has to come toward the
	// road in.
	room := (q.x - s.base_x) * s.run / max(s.size, 1e-3)
	return p - verge_normal(cs, prof, side, seg) * (rock_offset(p, s.size, f, room) * eff)
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
	side: int,
	roughness: f32,
) -> (col: Verge_Column) {
	for k in 0 ..= VERGE_ROWS {
		col.p[k] = verge_vertex(cs, prof, side, k, roughness)
		if k > 0 {
			col.v[k] = col.v[k - 1] + gfx.Vector3Length(col.p[k] - col.p[k - 1])
		}
	}
	return
}

// Where the verge hands off to the terrain: the profile's last point, rock and
// all. A cliff's crest; a bank's outer toe; a gutter's outer lip; the bare road
// edge where there is no verge at all, which is exactly right and needs no
// special case.
//
// **The terrain's innermost column must be this proc, called with this sample's
// own cross-section and `roughness`.** The two meshes share no vertex buffer —
// they are welded only by both emitting bit-identical positions. Recompute the
// seam any other way and the skirt tears off the verge.
verge_seam :: proc(cs: Cross_Section, side: int, roughness: f32) -> gfx.Vector3 {
	return verge_vertex(cs, verge_profile(cs, side), side, VERGE_ROWS, roughness)
}

// --- building ---------------------------------------------------------------

// What the editor paints a venue's ground with.
//
// Viewport only. The game reads materials and surface codes instead (see
// Mat_Id), so nothing here reaches it and nothing here can break an export.
// It exists because a venue's ground is not one ground: Finland is green over
// brown, Kenya is orange, Norway is white. Drawing them all in Finland's
// colours makes a snow stage look like a summer one while you build it.
//
// Loaded per base venue from the content pack's palette. `DEFAULT_LOOK` is
// Finland's, and it is what a venue with no palette gets.
Look :: struct {
	road:          gfx.Color,
	road_paved:    gfx.Color,
	terrain:       gfx.Color, // flat ground
	terrain_steep: gfx.Color, // the same ground stood on end
	cliff_top:     gfx.Color,
	cliff_bot:     gfx.Color,
	bank:          gfx.Color, // heaped snow or spoil
	gutter:        gfx.Color, // a wet cut, darker than the road
}

// How far out from a bare road edge the ground keeps some of the road's own
// texture. Short: it is the join that wants softening, not the verge. Stock's
// own gravel-to-tarmac bridge on Tupasentie covers 16 m *along* the road, and
// across the edge a few metres is the whole distance there is.
TERRAIN_ROADSIDE_M :: 4.0

// How far either side of a surface change the road fades between the two.
// Stock's own gravel-to-tarmac bridge on Tupasentie covers 16 m of road, so this
// is half of that each way.
ROAD_CHANGE_M :: 8.0

DEFAULT_LOOK :: Look {
	// Loose is brown and paved is a dark neutral grey, far enough apart to tell
	// at a glance across a whole stage. They used to sit 20 levels apart in the
	// same grey, which read as one colour and made the surface invisible.
	road          = {138, 114, 84, 255},
	road_paved    = {74, 76, 82, 255},
	terrain       = {86, 112, 68, 255},
	terrain_steep = {112, 104, 92, 255},
	cliff_top     = {140, 128, 112, 255},
	cliff_bot     = {86, 80, 74, 255},
	bank          = {198, 202, 210, 255},
	gutter        = {88, 82, 70, 255},
}

lerp_col :: proc(a, b: gfx.Color, t: f32) -> gfx.Color {
	m :: proc(x, y: u8, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * t)}
	return gfx.Color{m(a.r, b.r, t), m(a.g, b.g, t), m(a.b, b.b, t), 255}
}

// Where a road column sits between the material's two ground textures: 0 down
// the middle, 1 at either edge. Stock DiRT 3 paints the same polarity on its
// road shader — the first texture is strongest along the racing line and fades
// out toward the verge — measured as mean R falling from 138 on the line to 74
// past 64 m. So the road wears its worn look in the tracks and its coarser one
// at the edges, out of one material. See Tri_Mesh.blend.
road_blend :: proc(col, cols: int) -> f32 {
	return abs(2 * f32(col) / f32(cols) - 1)
}

// How far through a surface change each slice is: 0 all loose, 1 all paved, and
// `near` marking the slices a change actually reaches.
//
// A surface changes at a control point and the code under the car changes with
// it, because grip cannot fade. The paint can, so the road either side of the
// change draws with one material holding both surfaces and ramps across it. The
// two need not agree — stock's own boundary on Tupasentie has its paint and its
// physics about 30 m apart.
//
// Two changes closer together than ROAD_CHANGE_M overwrite one another, last
// one winning. That is a surface run shorter than its own fade, which has
// nowhere to go but pick an answer.
road_changeover :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	allocator := context.temp_allocator,
) -> (mix: []f32, near: []bool) {
	mix = make([]f32, len(ribbon), allocator)
	near = make([]bool, len(ribbon), allocator)
	for cs, i in ribbon { mix[i] = cs.surface == .Paved ? 1 : 0 }
	// A surface changes at a control point, which is where one graph edge ends
	// and the next begins — so the change always sits on a slice that starts a
	// run. Skipping those found no change at all.
	//
	// The walk is bounded by arc distance alone. `ribbon_arc` accumulates the
	// real distance between consecutive samples, so it runs on through a break
	// where two edges meet at a node (the twins are a metre of nothing apart)
	// and jumps by the whole gap where the next run starts somewhere else. The
	// jump exceeds the reach on its own, which ends the walk without a rule
	// about it.
	for i in 1 ..< len(ribbon) {
		if ribbon[i].surface == ribbon[i-1].surface { continue }
		to_paved := ribbon[i].surface == .Paved
		at := arc[i]
		for j := i; j < len(ribbon); j += 1 {
			d := arc[j] - at
			if d > ROAD_CHANGE_M { break }
			mix[j] = to_paved ? 0.5 + 0.5*d/ROAD_CHANGE_M : 0.5 - 0.5*d/ROAD_CHANGE_M
			near[j] = true
		}
		for j := i-1; j >= 0; j -= 1 {
			d := at - arc[j]
			if d > ROAD_CHANGE_M { break }
			mix[j] = to_paved ? 0.5 - 0.5*d/ROAD_CHANGE_M : 0.5 + 0.5*d/ROAD_CHANGE_M
			near[j] = true
		}
	}
	return
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
build_road_surface :: proc(m: ^Tri_Mesh, ribbon: []Cross_Section, arc: []f32, roughness: f32, look: Look) {
	mix, near := road_changeover(ribbon, arc)
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		// `xsec_ends` returns the +right end first, so that end takes v = 0.
		ua := arc[i] / UV_TILE_M
		ub := arc[i + 1] / UV_TILE_M
		// The segment takes the surface of the slice it leaves, so the code under
		// the car changes on a control point rather than smearing across the span
		// into it.
		changing := near[i] || near[i + 1]
		mat := changing ? road_change_mat(ribbon[i].surface) : road_surface_mat(ribbon[i].surface)
		tint := changing ? (mix[i] + mix[i+1])/2 : mix[i]
		col := lerp_col(look.road, look.road_paved, tint)
		for c in 0 ..< ROAD_COLS {
			a0, va0 := road_vertex(ribbon[i], i, c, ROAD_COLS, roughness)
			a1, va1 := road_vertex(ribbon[i], i, c + 1, ROAD_COLS, roughness)
			b1, vb1 := road_vertex(ribbon[i + 1], i + 1, c + 1, ROAD_COLS, roughness)
			b0, vb0 := road_vertex(ribbon[i + 1], i + 1, c, ROAD_COLS, roughness)
			// Mid-change the mix runs *along* the road, so the wear across its
			// width steps aside for it: one material holds two textures, and
			// through the change they are the two surfaces rather than the two
			// halves of one.
			wa := changing ? mix[i]   : road_blend(c, ROAD_COLS)
			wb := changing ? mix[i+1] : road_blend(c + 1, ROAD_COLS)
			blend := changing ? [4]f32{wa, wa, wb, wb} : [4]f32{wa, wb, wb, wa}
			add_quad(
				m, a0, a1, b1, b0,
				{ua, va0}, {ua, va1}, {ub, vb1}, {ub, vb0},
				col, mat, blend,
			)
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

// The tint and the material a verge quad wears, taken from the row at its outer
// edge so the first quad of a segment already reads as that segment. Only the
// cliff is rock: a bank and a gutter are ground, and the export has one material
// for ground (see Mat_Id).
verge_quad_look :: proc(row: int, look: Look) -> (col: gfx.Color, mat: Mat_Id) {
	seg, t := verge_row_at(row)
	switch seg {
	case .Gutter_In, .Gutter_Out:
		return look.gutter, .Gutter
	case .Bank_In, .Bank_Out:
		return look.bank, .Terrain
	case .Cliff:
		return lerp_col(look.cliff_bot, look.cliff_top, t), .Cliff
	case .Detach:
		// Ground, not rock and not spoil: this is the ground itself letting go
		// of the road, so it wears the plain terrain colour whatever the venue.
		return look.terrain, .Terrain
	}
	return look.cliff_bot, .Cliff
}

// Verge walls. Emitted only where a verge has a profile at all, so a stage with
// no guards costs no triangles.
//
// UV: `u` along the road's arc, `v` along the *profile's* arc — the same
// quantity the rows are spaced by, so a taller cliff shows more texture rather
// than a stretched one. The two neighbouring cross-sections have different
// profile lengths, so `v` is computed per column, not per quad.
build_verges :: proc(m: ^Tri_Mesh, ribbon: []Cross_Section, roughness: f32, look: Look) {
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
			if !p0.any && !p1.any {
				continue
			}
			ca := verge_column(ribbon[i], p0, side, roughness)
			cb := verge_column(ribbon[i + 1], p1, side, roughness)
			// Averaged over the rows a quad actually touches. Rows on a guard
			// that is not there sit on the road edge and emit nothing, and
			// counting them drags `u` toward the road's own arc rather than the
			// rock's — the stretch this `u` exists to avoid, reintroduced by
			// the rows a fixed layout spends on absent guards.
			step, live := f32(0), 0
			for k in 0 ..= VERGE_ROWS {
				below := k > 0 && (ca.p[k] != ca.p[k - 1] || cb.p[k] != cb.p[k - 1])
				above := k < VERGE_ROWS && (ca.p[k + 1] != ca.p[k] || cb.p[k + 1] != cb.p[k])
				if !below && !above {
					continue
				}
				step += gfx.Vector3Length(cb.p[k] - ca.p[k])
				live += 1
			}
			ua := u_run / UV_TILE_M
			ub := (u_run + step / f32(max(live, 1))) / UV_TILE_M
			defer u_run = ub * UV_TILE_M
			for k in 0 ..< VERGE_ROWS {
				a, b := ca.p[k], ca.p[k + 1]
				c, d := cb.p[k + 1], cb.p[k]
				col, mat := verge_quad_look(k + 1, look)

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
					add_quad(m, a, d, c, b, uv_a, uv_d, uv_c, uv_b, col, mat)
				} else {
					add_quad(m, a, b, c, d, uv_a, uv_b, uv_c, uv_d, col, mat)
				}
			}
		}
	}
}

build_tri_mesh :: proc(
	ribbon: []Cross_Section,
	roughness: f32,
	look := DEFAULT_LOOK,
	allocator := context.allocator,
) -> Tri_Mesh {
	m := tri_mesh_make(allocator)
	if len(ribbon) < 2 {
		return m
	}
	arc := ribbon_arc(ribbon) // temp-allocated; the UVs are metres along it
	build_road_surface(&m, ribbon, arc, roughness, look)
	build_verges(&m, ribbon, roughness, look)
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
road_mesh_rebuild :: proc(rm: ^Gpu_Mesh, ribbon: []Cross_Section, roughness: f32, look := DEFAULT_LOOK) {
	gpu_mesh_unload(rm)
	m := build_tri_mesh(ribbon, roughness, look, context.temp_allocator)
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
