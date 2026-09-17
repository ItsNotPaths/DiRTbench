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
//   - raylib's Mesh.indices is u16, which would cap us at 65k vertices.
//
// Nothing here is lit by a shader: the default raylib material is unlit, so a
// fixed key light is baked into the vertex colours at build time.

import "core:c"
import "core:math"
import rl "../gfx"

// Cliff shape. Heights, spans, tapers and the face angle are per-point (see
// spline.odin); these are the constants that give a cliff its character.
CLIFF_MIN :: 0.01 // below this a cliff is nothing, and emits no geometry

// Face angle limits, degrees off vertical. Negative overhangs the road; the
// lower bound is small because a steep overhang would let the cliff face poke
// down through the road surface it grew from.
CLIFF_ANGLE_MIN :: -5.0
CLIFF_ANGLE_MAX :: 15.0

// Height slider range, metres. A rally stage is walled by rock cuttings and
// banks a car could plausibly be contained by, not by canyon faces.
CLIFF_HEIGHT_MAX :: 7.0

// Vertex jitter, as a fraction of the local quad size at roughness 1.
//
// It is scaled by the *cell* — the smaller of the along-road sample spacing and
// the row height — not by the cliff's height. Scaling by height folds the mesh
// inside out: a 30 m cliff at high roughness would displace vertices several
// metres while the ribbon samples sit ~1.7 m apart, so vertices overshoot their
// neighbours and the faces invert. Staying under half a cell cannot fold.
CLIFF_JITTER :: 0.45

// Road-surface tessellation.
//
// The ribbon is subdivided *along* its length by `topo`; ROAD_COLS splits each
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
LIGHT_DIR :: rl.Vector3{0.40, 1.00, 0.30}
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
	pos: [dynamic]rl.Vector3,
	nrm: [dynamic]rl.Vector3,
	uv:  [dynamic][2]f32,
	col: [dynamic]rl.Color,
	mat: [dynamic]Mat_Id,
}

tri_mesh_make :: proc(allocator := context.allocator) -> Tri_Mesh {
	return Tri_Mesh {
		pos = make([dynamic]rl.Vector3, allocator),
		nrm = make([dynamic]rl.Vector3, allocator),
		uv = make([dynamic][2]f32, allocator),
		col = make([dynamic]rl.Color, allocator),
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
shade :: proc(col: rl.Color, n: rl.Vector3) -> rl.Color {
	l := rl.Vector3Normalize(LIGHT_DIR)
	k := AMBIENT + (1 - AMBIENT) * max(0, rl.Vector3DotProduct(n, l))
	return rl.Color{u8(f32(col.r) * k), u8(f32(col.g) * k), u8(f32(col.b) * k), col.a}
}

// Winding is counter-clockwise seen from the front, so the face normal is
// cross(b-a, c-a). Callers must order their vertices accordingly.
// `ua`/`ub`/`uc` are the corners' UVs, in the same order as the positions.
add_tri :: proc(m: ^Tri_Mesh, a, b, c: rl.Vector3, ua, ub, uc: [2]f32, col: rl.Color, mat: Mat_Id) {
	n := rl.Vector3CrossProduct(b - a, c - a)
	if rl.Vector3Length(n) < 1e-9 {
		return // degenerate, e.g. a cliff of zero height
	}
	n = rl.Vector3Normalize(n)
	sc := shade(col, n)
	uvs := [3][2]f32{ua, ub, uc}
	for v, i in ([]rl.Vector3{a, b, c}) {
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
	a, b, c, d: rl.Vector3,
	ua, ub, uc, ud: [2]f32,
	col: rl.Color,
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

// A per-vertex offset in [-1,1]^3, keyed on (ribbon sample, row, side).
verge_jitter :: proc(sample, row, side: int) -> rl.Vector3 {
	seed := u32(sample) * 73856093 ~ u32(row) * 19349663 ~ u32(side) * 83492791
	unit := proc(h: u32) -> f32 {return f32(h) / f32(max(u32)) * 2 - 1}
	return {
		unit(hash_u32(seed)),
		unit(hash_u32(seed ~ 0x9E3779B9)),
		unit(hash_u32(seed ~ 0x85EBCA6B)),
	}
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

// A vertex on the swept verge face.
//
// Row 0 sits exactly on the road edge with zero jitter, so the verge is
// watertight with the road surface. Jitter ramps in along the profile, and its
// amplitude is bounded by the local cell so the surface cannot fold (see
// CLIFF_JITTER). `ds` is the along-road spacing at this sample; it must be a
// property of the sample, never of the quad, or two quads sharing a vertex
// would place it differently and tear the verge open.
//
// Rows are spaced evenly along the profile's *arc length*, so the row height is
// `len/rows` — height/cos(angle) for a single tilted segment. That is the right
// quantity for the fold bound, which is about the distance between rows, not
// about how much of that distance was vertical.
verge_vertex :: proc(
	cs: Cross_Section,
	prof: Verge_Profile,
	side, row, rows, sample: int,
	roughness, ds: f32,
) -> rl.Vector3 {
	outward := side == 0 ? cs.right : -cs.right
	edge := cs.pos + outward * (cs.width * 0.5)
	if prof.n < 2 || prof.len <= 0 || row == 0 {
		return edge
	}

	f := f32(row) / f32(rows)
	q := verge_sample(prof, f)
	p := edge + outward * q.x + cs.up * q.y

	// A short verge has short rows, so its jitter shrinks with it and it still
	// fades smoothly to nothing rather than ending in a jittery stub.
	cell := min(ds, prof.len / f32(rows))
	amp := cell * CLIFF_JITTER * roughness * f
	j := verge_jitter(sample, row, side)
	return p + (cs.right * j.x + cs.up * j.y + cs.fwd * j.z) * amp
}

// Where the verge hands off to the terrain: the profile's last point, jitter and
// all. A cliff's crest; a ditch's outer lip; the bare road edge where there is
// no verge at all, which is exactly right and needs no special case.
//
// **The terrain's innermost column must be this proc, called with this sample's
// own `sample`, `ds` and `roughness`.** The two meshes share no vertex buffer —
// they are welded only by both emitting bit-identical positions. Recompute the
// seam any other way and the skirt tears off the verge.
verge_seam :: proc(
	cs: Cross_Section,
	side, rows, sample: int,
	roughness, ds: f32,
) -> rl.Vector3 {
	return verge_vertex(cs, verge_profile(cs, side), side, rows, rows, sample, roughness, ds)
}

// --- building ---------------------------------------------------------------

ROAD_COL :: rl.Color{104, 108, 120, 255}      // Dirt-grip segments (editor tint)
ROAD_COL_SAND :: rl.Color{150, 138, 120, 255} // Sand-penalty segments (editor tint)
CLIFF_TOP :: rl.Color{140, 128, 112, 255}
CLIFF_BOT :: rl.Color{86, 80, 74, 255}

lerp_col :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	m :: proc(x, y: u8, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * t)}
	return rl.Color{m(a.r, b.r, t), m(a.g, b.g, t), m(a.b, b.b, t), 255}
}

// Which surface a road segment gets: ~2 in 3 keep Dirt grip, ~1 in 3 are the
// Sand penalty. Hashed on the segment index so it is deterministic and scattered
// along the road rather than clumping or striping. A whole segment (all its width
// columns) takes one surface, so at high `topo` (short segments) the car switches
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
) -> (pos: rl.Vector3, v: f32) {
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
		ds[i] = ribbon[i + 1].break_before ? 0 : rl.Vector3Distance(ribbon[i].pos, ribbon[i + 1].pos)
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
build_verges :: proc(m: ^Tri_Mesh, ribbon: []Cross_Section, arc: []f32, rows: int, roughness: f32) {
	ds := sample_spacing(ribbon)
	for side in 0 ..< 2 {
		for i in 0 ..< len(ribbon) - 1 {
			if ribbon[i + 1].break_before { continue }
			p0 := verge_profile(ribbon[i], side)
			p1 := verge_profile(ribbon[i + 1], side)
			if p0.n < 2 && p1.n < 2 {
				continue
			}
			ua := arc[i] / UV_TILE_M
			ub := arc[i + 1] / UV_TILE_M
			for k in 0 ..< rows {
				a := verge_vertex(ribbon[i], p0, side, k, rows, i, roughness, ds[i])
				b := verge_vertex(ribbon[i], p0, side, k + 1, rows, i, roughness, ds[i])
				c := verge_vertex(ribbon[i + 1], p1, side, k + 1, rows, i + 1, roughness, ds[i + 1])
				d := verge_vertex(ribbon[i + 1], p1, side, k, rows, i + 1, roughness, ds[i + 1])
				col := lerp_col(CLIFF_BOT, CLIFF_TOP, f32(k) / f32(rows))

				lo := f32(k) / f32(rows)
				hi := f32(k + 1) / f32(rows)
				uv_a := [2]f32{ua, lo * p0.len / UV_TILE_M}
				uv_b := [2]f32{ua, hi * p0.len / UV_TILE_M}
				uv_c := [2]f32{ub, hi * p1.len / UV_TILE_M}
				uv_d := [2]f32{ub, lo * p1.len / UV_TILE_M}

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

// How many rows a verge profile is swept into, derived from the global topo
// resolution so one slider controls tessellation everywhere.
verge_rows :: proc(topo: c.int) -> int {
	return clamp(int(topo) / 3, 2, 12)
}

build_tri_mesh :: proc(
	ribbon: []Cross_Section,
	topo: c.int,
	roughness: f32,
	allocator := context.allocator,
) -> Tri_Mesh {
	m := tri_mesh_make(allocator)
	if len(ribbon) < 2 {
		return m
	}
	arc := ribbon_arc(ribbon) // temp-allocated; the UVs are metres along it
	build_road_surface(&m, ribbon, arc, roughness)
	build_verges(&m, ribbon, arc, verge_rows(topo), roughness)
	return m
}

// --- GPU upload -------------------------------------------------------------

// An uploaded triangle soup. Not road-specific: the road and the terrain
// (terrain.odin) are two of these, drawn separately so either can be toggled.
Gpu_Mesh :: struct {
	mesh:     rl.Mesh,
	uploaded: bool,
	tris:     int,
}

gpu_mesh_unload :: proc(rm: ^Gpu_Mesh) {
	if rm.uploaded {
		rl.UnloadMesh(rm.mesh) // frees the CPU arrays (RL_FREE) and the VBOs
		rm.uploaded = false
	}
	rm^ = {}
}

// Copy the soup into raylib-owned buffers and upload. The arrays must come from
// rl.MemAlloc, because rl.UnloadMesh releases them with RL_FREE.
gpu_mesh_upload :: proc(m: Tri_Mesh) -> Gpu_Mesh {
	n := len(m.pos)
	if n == 0 {
		return {}
	}
	mesh: rl.Mesh
	mesh.vertexCount = c.int(n)
	mesh.triangleCount = c.int(n / 3)

	mesh.vertices = cast([^]f32)rl.MemAlloc(c.uint(n * 3 * size_of(f32)))
	mesh.normals = cast([^]f32)rl.MemAlloc(c.uint(n * 3 * size_of(f32)))
	mesh.colors = cast([^]u8)rl.MemAlloc(c.uint(n * 4 * size_of(u8)))

	for i in 0 ..< n {
		mesh.vertices[i * 3 + 0] = m.pos[i].x
		mesh.vertices[i * 3 + 1] = m.pos[i].y
		mesh.vertices[i * 3 + 2] = m.pos[i].z
		mesh.normals[i * 3 + 0] = m.nrm[i].x
		mesh.normals[i * 3 + 1] = m.nrm[i].y
		mesh.normals[i * 3 + 2] = m.nrm[i].z
		mesh.colors[i * 4 + 0] = m.col[i].r
		mesh.colors[i * 4 + 1] = m.col[i].g
		mesh.colors[i * 4 + 2] = m.col[i].b
		mesh.colors[i * 4 + 3] = m.col[i].a
	}
	rl.UploadMesh(&mesh, false)
	return Gpu_Mesh{mesh = mesh, uploaded = true, tris = n / 3}
}

// Rebuild the whole thing from the ribbon. The old GPU buffers are released
// first, so callers may call this every frame while a gizmo is dragged.
road_mesh_rebuild :: proc(rm: ^Gpu_Mesh, ribbon: []Cross_Section, topo: c.int, roughness: f32) {
	gpu_mesh_unload(rm)
	m := build_tri_mesh(ribbon, topo, roughness, context.temp_allocator)
	rm^ = gpu_mesh_upload(m)
}

gpu_mesh_draw :: proc(rm: Gpu_Mesh, mat: rl.Material, wireframe: bool) {
	if !rm.uploaded {
		return
	}
	// Every face is single-sided and correctly wound for export: the road faces
	// up, and a cliff faces the road it grew from. In the editor the camera
	// orbits freely, so culling would make cliffs vanish whenever you look at
	// their backs. Draw both sides here; the mesh itself is unchanged.
	rl.DisableBackfaceCulling()
	defer rl.EnableBackfaceCulling()

	// Not `defer` inside the if: Odin scopes defer to the enclosing block, so it
	// would disable wire mode before the draw rather than after.
	if wireframe {
		rl.EnableWireMode()
	}
	rl.DrawMesh(rm.mesh, mat, rl.Matrix(1))
	if wireframe {
		rl.DisableWireMode()
	}
}
