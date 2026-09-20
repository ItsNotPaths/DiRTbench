package geo

// Terrain — the out-of-stage mesh.
//
// Ground outside the road, sculpted by sparse world-space height controls.
//
// The mesh is a **Delaunay triangulation of the ground region**, not a loft
// between the road and an outer rail. That distinction is the whole design:
//
//   A loft — rows along the road, columns marching outward — can only ever
//   produce a topological rectangle. The ground beside a road stops being one as
//   soon as the road turns tightly. The inside of a corner is a region no ray
//   from the road reaches past the radius of curvature, because that is where
//   adjacent rows' outward rays meet. A hairpin's belly is bounded by road on
//   three sides. Where a road nearly touches itself the region pinches shut and
//   reopens. None of those are rectangles.
//
//   Delaunay maximises the minimum angle, so slivers are the thing it is
//   specifically built to avoid, and it is indifferent to concavity, pinches and
//   holes. See delaunay.odin.
//
// Three things make the triangulation come out right:
//
//   - **The weld.** The verge rim — `verge_seam` at every ribbon sample, jitter
//     and all — is in the point set. Those points are the cliff top's own
//     vertices, so the terrain shares them exactly. The road mesh is a
//     non-indexed soup (mesh.odin) with no shared vertices to merge, so emitting
//     bit-identical positions is the only thing that welds the two surfaces.
//   - **The boundary.** Delaunay triangulates the convex hull, so the corridor
//     and everything past `reach` come back filled. Triangles are dropped by
//     testing their centroid against the field: inside the road, or too far out,
//     or off the end of the stage. Because the rim is sampled far more densely
//     than the interior, Delaunay runs its edges along it of its own accord —
//     the standard way to get a constrained result from an unconstrained
//     algorithm.
//   - **The height.** Y comes from a field evaluated at each point's world XZ.
//     Near a hairpin two legs of the road contribute, weighted by inverse-square
//     distance, so the medial line between them is a saddle rather than a crease.
//
// Sculpt controls are sampled from this valid world-space region rather than
// offset from every road station, so inside corners and hairpins merge cleanly.

import "core:math"
import "../gfx"

// Vertex colours, since the material is unlit (see mesh.odin). Slope picks
// between them: flat ground is grass, a steep face is the rock under it.
TERRAIN_FLAT :: gfx.Color{86, 112, 68, 255}
TERRAIN_STEEP :: gfx.Color{112, 104, 92, 255}

// Controls sculpt broad landforms; `cell_m` separately decides how finely the
// resulting field is triangulated.
TERRAIN_REACH_MAX :: 400.0
TERRAIN_ROW_M_MIN :: 10.0
TERRAIN_ROW_M_MAX :: 30.0

// What makes a sample "another leg" of the road rather than more of the same one.
//
// The discriminator is **road distance versus straight-line distance**. Two legs
// of a hairpin are 40 m apart in space but two hundred along the road; a plain
// 30 m-radius corner is 37 m apart in space and 40 m along the road. An angle
// test cannot separate those — a corner sweeps far enough round to look abeam of
// itself.
TERRAIN_LEG_ARC_SEP :: 24.0
TERRAIN_LEG_RATIO :: 3.0

// How much closer than the nearest leg a second leg must be to stop mattering.
// At equal distance the two blend evenly, which is the saddle; past this ratio
// only the nearest leg contributes.
TERRAIN_LEG_CUTOFF :: 1.3

// Interior points must stand at least this fraction of a cell clear of the rim,
// or Delaunay pairs them with rim points into slivers.
TERRAIN_RIM_MARGIN :: 0.45

// Long edges receive an additional midpoint probe: valid sparse terrain is
// retained, while convex-hull edges and bridges across the road are rejected.
TERRAIN_MAX_EDGE_CELLS :: 6.0

// Points closer together than this collapse to one. Delaunator either drops
// coincident points or refuses the whole set, and a hairpin pinch will otherwise
// bring two rims into contact.
TERRAIN_DEDUPE_M :: 0.5

// How far *inside* the corridor a triangle's centroid may sit before it is
// dropped. Not zero: the rim is jittered, so it is locally concave, and Delaunay
// fills those concavities with slivers whose centroids fall a few centimetres
// inside. Dropping them at exactly zero punches pinholes along the cliff top.
// A triangle that actually spans the road has a centroid metres inside, so this
// tolerance separates the two cleanly.
TERRAIN_SU_EPS :: 0.25

// Backstop on the point set. `cell_m` grows until it fits.
TERRAIN_MAX_POINTS :: 250_000

Terrain_Control :: struct {
	x, z:   f32,
	base_y: f32,
	u:      f32, // metres out from the verge, for the warp
	offset: f32,
	radius: f32,
}

Terrain :: struct {
	enabled: bool,
	reach_m: f32, // how far the ground reaches past the verge
	blend_m: f32, // metres over which sculpt offsets take over from the verge
	cell_m:  f32, // spacing of the interior points
	row_m:   f32, // target world-space distance between sculpt controls
	warp_m:  f32, // global lift of the ground by the time it reaches `reach_m`
	// How far the ground stands off the road, swooping between the two along
	// its length. Read here, built into the verge: see the road detachment
	// section in mesh.odin.
	detach:  Detach_Opts,
	controls: [dynamic]Terrain_Control,
	controls_gen: u64,
	// Flat pads cut into the ground (floor.odin). Authored and world-space, so
	// unlike the controls they are never re-derived and a road edit leaves them
	// alone. Both arrays are owned: copy them with floors_copy, free with
	// floors_delete.
	floors:    [dynamic]Floor,
	floor_pts: [dynamic][2]f32,
	controls_reach, controls_cell, controls_spacing: f32,
}

// `blend_m` is deliberately a large fraction of `reach_m`. It is the distance
// over which the road stops dictating the ground and controls take over. A
// narrow band crossed in one mesh cell reads as a terrace rather than a slope.
TERRAIN_DEFAULTS :: Terrain {
	enabled = false,
	reach_m = 96,
	blend_m = 48,
	cell_m  = 4,
	row_m   = 10,
	warp_m  = 0,
}

terrain_delete :: proc(t: ^Terrain) {
	delete(t.controls)
	floors_delete(t)
}

// --- controls ---------------------------------------------------------------

terrain_node_count :: proc(t: ^Terrain) -> int {
	return len(t.controls)
}

// --- sculpt snapshot --------------------------------------------------------
//
// The whole control set, saved and restored in one piece. There is no
// incremental form: the set is re-derived from the ribbon on every rebuild, so
// a road edit renumbers it wholesale and an index into it means nothing later.
//
// What survives is the offset at a world position. `base_y` and `radius` are
// both re-derived, so only x, z and offset are kept.

// Seed the controls from a snapshot. They are not the live set: the next
// rebuild re-derives that from the ribbon and carries these offsets across by
// position (see terrain_control_add). Clearing the signature is what forces
// that rebuild to happen.
terrain_sculpt_load :: proc(t: ^Terrain, saved: []Terrain_Control) {
	clear(&t.controls)
	append(&t.controls, ..saved)
	t.controls_gen = 0
	t.controls_reach, t.controls_cell, t.controls_spacing = 0, 0, 0
}

// Drop the sculpt. Replacing the spline wholesale must not carry its
// world-space offsets into an unrelated route.
terrain_invalidate :: proc(t: ^Terrain) {
	terrain_sculpt_load(t, nil)
}

// Back to defaults, sculpt dropped. Assigning TERRAIN_DEFAULTS wholesale would
// drop the control allocation with it.
terrain_reset :: proc(t: ^Terrain) {
	d := TERRAIN_DEFAULTS
	t.enabled = d.enabled
	t.reach_m, t.blend_m, t.cell_m, t.row_m = d.reach_m, d.blend_m, d.cell_m, d.row_m
	t.warp_m = d.warp_m
	t.detach = d.detach
	terrain_invalidate(t)
	// The pads go with it. terrain_invalidate deliberately keeps them: they are
	// world-space and owe the road nothing, so replacing the spline must not
	// throw away ground the user shaped by hand.
	clear(&t.floors)
	clear(&t.floor_pts)
}

// The control set, for saving. **Every control, not only the moved ones.**
//
// terrain_control_add adopts the offset of the nearest old control within
// spacing*1.5. The untouched controls are what stop that reaching: a new
// control finds its own zero at distance ~0 and keeps it. Drop them and every
// control within one and a half spacings of a moved one inherits its height,
// so the sculpt smears outward on every load.
//
// An untouched terrain saves nothing at all. With no offsets to carry, the
// match has no work to do, and the alternative is thousands of zeroes in the
// file for every venue that was never sculpted.
terrain_sculpt :: proc(t: ^Terrain, allocator := context.temp_allocator) -> []Terrain_Control {
	sculpted := false
	for c in t.controls {
		if c.offset != 0 {
			sculpted = true
			break
		}
	}
	if !sculpted {
		return nil
	}
	out := make([]Terrain_Control, len(t.controls), allocator)
	for c, i in t.controls {
		out[i] = {x = c.x, z = c.z, offset = c.offset}
	}
	return out
}

// A throwaway copy carrying the sliders and the exact sculpt, for fitting a
// second ribbon: terrain_controls_ensure re-derives controls per ribbon and
// adopts the offset of the nearest old control, so refitting one Terrain to a
// second ribbon smears the sculpt it came from. Delete with terrain_delete.
terrain_clone :: proc(t: ^Terrain) -> (out: Terrain) {
	out = t^
	out.controls = nil
	terrain_sculpt_load(&out, terrain_sculpt(t))
	floors_copy(&out, t^)
	return
}

terrain_ensure :: proc(t: ^Terrain, ribbon: []Cross_Section, roughness: f32) {
	if !t.enabled {
		return
	}
	t.row_m = clamp(t.row_m, TERRAIN_ROW_M_MIN, TERRAIN_ROW_M_MAX)
}

// --- ribbon frame -----------------------------------------------------------

// The outward direction, **flattened onto the ground plane**.
//
// Heights are world-vertical, so a banked road must not tilt the terrain beside
// it. Only when the road is banked to vertical does `right` lose its ground
// component, and then it degenerates to exactly cross(worldUp, fwd).
terrain_outward :: proc(cs: Cross_Section, side: int) -> gfx.Vector3 {
	r := side == 0 ? cs.right : -cs.right
	f := gfx.Vector3{r.x, 0, r.z}
	if gfx.Vector3Length(f) > 1e-4 {
		return gfx.Vector3Normalize(f)
	}
	g := gfx.Vector3CrossProduct({0, 1, 0}, cs.fwd)
	if gfx.Vector3Length(g) < 1e-4 {
		return {1, 0, 0}
	}
	g = gfx.Vector3Normalize(g)
	return side == 0 ? g : -g
}

terrain_tri_colour :: proc(n: gfx.Vector3, look: Look) -> gfx.Color {
	return lerp_col(look.terrain, look.terrain_steep, clamp((1 - abs(n.y)) * 2, 0, 1))
}

// --- the field ---------------------------------------------------------------

// Everything a world point needs from one ribbon sample to evaluate the field.
//
// A branched road is sampled as several runs, one per graph edge, laid end to end
// in one array (build_ribbon). Neighbours, spacing and ends are therefore stored
// per sample rather than read as i-1 / i+1: across a run boundary those index a
// different edge somewhere else entirely. Index 0 is backward, 1 is forward.
Field_Sample :: struct {
	p:      [2]f32,    // centreline, XZ
	right:  [2]f32,    // side-0 outward, flattened, unit
	fwd:    [2]f32,    // travel direction, flattened, unit
	seam:   [2][2]f32, // seam XZ per side
	seam_y: [2]f32,
	e:      [2]f32, // the seam's outward offset from the centreline, per side
	// 1 where the seam is the road edge itself, 0 where a guard stands between
	// them. A float rather than a flag so it can be interpolated along the road:
	// the roadside blend then fades out as a cliff begins, instead of stopping at
	// the first slice that carries one.
	bare:   [2]f32,
	arc:    f32,
	run:    int,       // which run this sample belongs to
	nb:     [2]int,    // neighbouring sample per direction, -1 at a run end
	nd:     [2]f32,    // distance to that neighbour
}

// A world point's relationship to one leg of the road.
Terrain_Leg :: struct {
	u:      f32, // metres outward from that leg's seam; never negative
	bare:   f32, // 1 where this leg's seam is the road edge; see Field_Sample.bare
	seam_y: f32,
	w:      f32, // normalised blend weight
	side:   int,
}

field_samples :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	roughness: f32,
	allocator := context.temp_allocator,
) -> []Field_Sample {
	n := len(ribbon)
	out := make([]Field_Sample, n, allocator)

	run := 0
	for i in 0 ..< n {
		cs := ribbon[i]
		s: Field_Sample
		s.p = {cs.pos.x, cs.pos.z}
		s.arc = arc[i]
		if i > 0 && cs.break_before {
			run += 1
		}
		s.run = run

		back := i > 0 && !cs.break_before
		fore := i < n - 1 && !ribbon[i + 1].break_before
		s.nb = {back ? i - 1 : -1, fore ? i + 1 : -1}
		s.nd = {back ? ds[i - 1] : 0, fore ? ds[i] : 0}

		r0 := terrain_outward(cs, 0)
		s.right = {r0.x, r0.z}
		f := gfx.Vector3{cs.fwd.x, 0, cs.fwd.z}
		if gfx.Vector3Length(f) > 1e-4 {
			f = gfx.Vector3Normalize(f)
		}
		s.fwd = {f.x, f.z}

		for side in 0 ..< 2 {
			seam := verge_seam(cs, side, roughness)
			s.bare[side] = verge_profile(cs, side).guarded ? 0 : 1
			out_dir := terrain_outward(cs, side)
			s.seam[side] = {seam.x, seam.z}
			s.seam_y[side] = seam.y
			// How far out the seam sits: half-width plus the verge's horizontal run.
			s.e[side] = (seam.x - cs.pos.x) * out_dir.x + (seam.z - cs.pos.z) * out_dir.z
		}
		out[i] = s
	}
	return out
}

// --- sample hash -------------------------------------------------------------

Sample_Hash :: struct {
	cell:   f32,
	origin: [2]f32,
	nx, nz: int,
	starts: []int, // nx*nz + 1, prefix-summed
	items:  []int,
	// Cells from here to the nearest cell holding a sample. What makes hash_far
	// an array read rather than a ring walk.
	away:   []i32,
}

hash_coord :: proc(h: Sample_Hash, p: [2]f32) -> (int, int) {
	gx := clamp(int((p[0] - h.origin[0]) / h.cell), 0, h.nx - 1)
	gz := clamp(int((p[1] - h.origin[1]) / h.cell), 0, h.nz - 1)
	return gx, gz
}

// Counting sort into a uniform bucket grid. O(n), no per-cell allocation.
hash_build :: proc(
	fs: []Field_Sample,
	lo, hi: [2]f32,
	cell: f32,
	allocator := context.temp_allocator,
) -> Sample_Hash {
	h: Sample_Hash
	h.cell = cell
	h.origin = lo
	h.nx = max(int((hi[0] - lo[0]) / cell) + 1, 1)
	h.nz = max(int((hi[1] - lo[1]) / cell) + 1, 1)
	h.starts = make([]int, h.nx * h.nz + 1, allocator)
	h.items = make([]int, len(fs), allocator)

	for s in fs {
		gx, gz := hash_coord(h, s.p)
		h.starts[gz * h.nx + gx + 1] += 1
	}
	for i in 1 ..< len(h.starts) {
		h.starts[i] += h.starts[i - 1]
	}
	cursor := make([]int, h.nx * h.nz, allocator)
	for s, i in fs {
		gx, gz := hash_coord(h, s.p)
		ci := gz * h.nx + gx
		h.items[h.starts[ci] + cursor[ci]] = i
		cursor[ci] += 1
	}
	h.away = hash_away(h, allocator)
	return h
}

// Chessboard distance in cells to the nearest occupied cell, in two sweeps.
//
// Chessboard rather than Manhattan: this is read as a *lower bound* on a world
// distance, and Manhattan overstates it, which would reject ground that is
// really in range.
hash_away :: proc(h: Sample_Hash, allocator := context.temp_allocator) -> []i32 {
	FAR :: i32(1 << 20)
	d := make([]i32, h.nx * h.nz, allocator)
	for ci in 0 ..< len(d) {
		d[ci] = h.starts[ci + 1] > h.starts[ci] ? 0 : FAR
	}
	sweep :: proc(h: Sample_Hash, d: []i32, gx, gz: int, nbrs: [4][2]int) {
		ci := gz * h.nx + gx
		for o in nbrs {
			ox, oz := gx + o[0], gz + o[1]
			if ox < 0 || ox >= h.nx || oz < 0 || oz >= h.nz {
				continue
			}
			d[ci] = min(d[ci], d[oz * h.nx + ox] + 1)
		}
	}
	for gz in 0 ..< h.nz {
		for gx in 0 ..< h.nx {
			sweep(h, d, gx, gz, {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}})
		}
	}
	for gz := h.nz - 1; gz >= 0; gz -= 1 {
		for gx := h.nx - 1; gx >= 0; gx -= 1 {
			sweep(h, d, gx, gz, {{1, 0}, {-1, 1}, {0, 1}, {1, 1}})
		}
	}
	return d
}

// True when no sample can be within `d` of `p`. Conservative by construction: a
// cell that might hold one in range always answers false, so this only ever
// saves a ring walk that was going to come back empty.
//
// Two cells `k` apart in the chessboard metric hold points at least `(k-1)*cell`
// apart, and hash_coord clamps a point outside the grid onto the border cell,
// which can only understate how far out it really is.
hash_far :: proc(h: Sample_Hash, p: [2]f32, d: f32) -> bool {
	gx, gz := hash_coord(h, p)
	return f32(h.away[gz * h.nx + gx] - 1) * h.cell > d
}

dist2 :: proc(a, b: [2]f32) -> f32 {
	dx := a[0] - b[0]
	dz := a[1] - b[1]
	return dx * dx + dz * dz
}

// Nearest sample to `p`, by ring expansion.
//
// With `other_leg`, a candidate must be a genuinely different leg of the road
// rather than more of the same one: far along the road from `skip_arc`, *and* far
// along it relative to how close it is to `skip_p`. The ratio is measured from
// `skip_p` — a point on the road — not from `p`, which may be way out in a field.
//
// Arc only means anything within one run, so a candidate from another run is
// another leg by construction — which is what makes a junction blend the way a
// hairpin does.
hash_nearest :: proc(
	h: Sample_Hash,
	fs: []Field_Sample,
	p: [2]f32,
	limit: f32,
	skip_arc: f32 = -1,
	skip_p: [2]f32 = {},
	other_leg := false,
	skip_run: int = -1,
) -> (best: int, best_d: f32) {
	best = -1
	best_d = max(f32)
	cx, cz := hash_coord(h, p)
	max_r := int(math.ceil(limit / h.cell)) + 1

	for r in 0 ..= max_r {
		// A sample in ring r is at least (r-1)*cell away; once that exceeds the
		// best we have, no further ring can improve on it.
		if best >= 0 && f32(r - 1) * h.cell > best_d {
			break
		}
		for gz in cz - r ..= cz + r {
			if gz < 0 || gz >= h.nz {
				continue
			}
			for gx in cx - r ..= cx + r {
				if gx < 0 || gx >= h.nx {
					continue
				}
				if max(abs(gx - cx), abs(gz - cz)) != r {
					continue // interior of the ring: already visited
				}
				ci := gz * h.nx + gx
				for k in h.starts[ci] ..< h.starts[ci + 1] {
					i := h.items[k]
					if other_leg && fs[i].run == skip_run {
						gap := abs(fs[i].arc - skip_arc)
						if gap < TERRAIN_LEG_ARC_SEP {
							continue
						}
						// A long way round the road but no distance across it: that is
						// a doubling-back. A curve, however tight, fails this.
						chord := math.sqrt(dist2(skip_p, fs[i].p))
						if gap < TERRAIN_LEG_RATIO * chord {
							continue
						}
					}
					if d := math.sqrt(dist2(p, fs[i].p)); d < best_d {
						best_d = d
						best = i
					}
				}
			}
		}
	}
	if best_d > limit {
		return -1, max(f32)
	}
	return
}

// Which stretches of road have another leg near them. Computed once per ribbon,
// and used to skip the per-point second query everywhere else: an other-leg
// search that finds nothing has no best distance to bound its ring walk, so on a
// straight road it would scan every ring to the limit, for every point.
terrain_near_other :: proc(
	t: ^Terrain,
	fs: []Field_Sample,
	h: Sample_Hash,
	allocator := context.temp_allocator,
) -> []bool {
	out := make([]bool, len(fs), allocator)
	for i in 0 ..< len(fs) {
		other, _ := hash_nearest(h, fs, fs[i].p, 2 * t.reach_m, fs[i].arc, fs[i].p, true, fs[i].run)
		out[i] = other >= 0
	}
	return out
}

// How far `p` lies outside the road corridor, in metres, measured from the seam
// of whichever leg is nearest. Negative means inside the road or its verge.
Field_Probe :: struct {
	su: f32,
	ok: bool,
}

// Where `p` sits relative to sample `i`, in that sample's own road frame.
//
// `field_probe` and `field_leg_at` must agree on this to the bit: the probe
// decides which triangles survive and the leg decides their height, and if their
// idea of "outside the corridor" drifts apart the terrain tears off the verge.
// Hence one proc, called by both.
Field_Frame :: struct {
	lateral: f32, // signed distance across the road
	fwd:     f32, // signed distance along it, from the sample
	// Metres past the end of this leg, zero while the run carries on. A run end
	// owns no road beyond itself, so the corridor must stop there instead of
	// reaching forward for ever.
	out:     f32,
	side:    int,
	j:       int, // the neighbouring sample `fwd` points at
	tt:      f32, // how far toward it, 0..1
}

field_project :: proc(fs: []Field_Sample, i: int, p: [2]f32) -> (fr: Field_Frame) {
	s := fs[i]
	dx := p[0] - s.p[0]
	dz := p[1] - s.p[1]
	fr.lateral = dx * s.right[0] + dz * s.right[1]
	fr.fwd = dx * s.fwd[0] + dz * s.fwd[1]
	fr.side = fr.lateral >= 0 ? 0 : 1
	dir := fr.fwd >= 0 ? 1 : 0
	open := s.nb[dir] < 0
	fr.out = open ? abs(fr.fwd) : 0
	fr.j = open ? i : s.nb[dir]
	fr.tt = open ? 0 : clamp(abs(fr.fwd) / max(s.nd[dir], 1e-4), 0, 1)
	return
}

// How far `p` lies outside this leg of the road, in metres; negative inside it.
//
// The road is a band of the seam's half-width, and it stops at a run end: past
// that end the distance is measured from the end face, so the ground closes
// around the tip. Measuring it across the road instead would carve a road-shaped
// hole out of the ground ahead of every dead end.
field_su :: proc(fs: []Field_Sample, i: int, fr: Field_Frame) -> f32 {
	lat := abs(fr.lateral) - field_seam_offset(fs, i, fr)
	if fr.out <= 0 {
		return lat
	}
	if lat <= 0 {
		return fr.out
	}
	return math.sqrt(lat * lat + fr.out * fr.out)
}

// The seam's outward offset, interpolated toward the neighbouring sample.
field_seam_offset :: proc(fs: []Field_Sample, i: int, fr: Field_Frame) -> f32 {
	e := fs[i].e[fr.side]
	return e + (fs[fr.j].e[fr.side] - e) * fr.tt
}

field_probe :: proc(
	h: Sample_Hash,
	fs: []Field_Sample,
	near_other: []bool,
	p: [2]f32,
	limit: f32,
) -> Field_Probe {
	i0, _ := hash_nearest(h, fs, p, limit)
	if i0 < 0 {
		return {}
	}
	fr := field_project(fs, i0, p)
	su := field_su(fs, i0, fr)
	// Past the end of a leg the road usually just carries on as the next edge,
	// whose first samples sit on top of this one's last. The nearest sample cannot
	// tell that apart from a dead end, so ask the other legs: the corridor is the
	// union of all of them, and only a real dead end has nothing carrying on. Left
	// to one leg, every node of a branched road opens a gap in its own corridor —
	// wide enough to plant a tree in the middle of the road.
	if fr.out > 0 && near_other[i0] {
		i1, _ := hash_nearest(h, fs, p, limit, fs[i0].arc, fs[i0].p, true, fs[i0].run)
		if i1 >= 0 {
			su = min(su, field_su(fs, i1, field_project(fs, i1, p)))
		}
	}
	return {su = su, ok = true}
}

// One leg's contribution at world point `p`.
//
// Everything is interpolated along the road toward the neighbouring sample rather
// than read off sample `i` alone. The seam carries the verge's jitter, so reading
// it per-sample would step by the jitter amplitude — tens of centimetres — each
// time the nearest sample changed, and ripple the terrain along the road.
field_leg_at :: proc(fs: []Field_Sample, i: int, p: [2]f32) -> (leg: Terrain_Leg) {
	s := fs[i]
	fr := field_project(fs, i, p)
	sj := fs[fr.j]

	leg.side = fr.side
	leg.seam_y = s.seam_y[fr.side] + (sj.seam_y[fr.side] - s.seam_y[fr.side]) * fr.tt
	leg.bare = s.bare[fr.side] + (sj.bare[fr.side] - s.bare[fr.side]) * fr.tt
	leg.u = max(0, field_su(fs, i, fr))
	return
}

// The legs contributing at `p`: the nearest, plus a second one from another leg
// of the road if it is competitively close. Weights are normalised.
//
// At a hairpin's medial line the two are equidistant and blend evenly, so the
// surface crossing it is a saddle. Past TERRAIN_LEG_CUTOFF the second fades
// smoothly to nothing, rather than switching off and creasing the surface.
field_legs :: proc(
	h: Sample_Hash,
	fs: []Field_Sample,
	near_other: []bool,
	p: [2]f32,
	limit: f32,
) -> (legs: [2]Terrain_Leg, n: int) {
	i0, d0 := hash_nearest(h, fs, p, limit)
	if i0 < 0 {
		return
	}
	legs[0] = field_leg_at(fs, i0, p)
	legs[0].w = 1
	n = 1
	if !near_other[i0] || d0 < 1e-4 {
		return
	}

	i1, d1 := hash_nearest(h, fs, p, d0 * TERRAIN_LEG_CUTOFF, fs[i0].arc, fs[i0].p, true, fs[i0].run)
	if i1 < 0 {
		return
	}
	fade := 1 - math.smoothstep(f32(1), f32(TERRAIN_LEG_CUTOFF), d1 / d0)
	if fade <= 0 {
		return
	}
	ratio := d0 / d1
	w1 := fade * ratio * ratio

	legs[1] = field_leg_at(fs, i1, p)
	legs[1].w = w1
	inv := 1 / (1 + w1)
	legs[0].w *= inv
	legs[1].w *= inv
	n = 2
	return
}

// --- the point set and its triangulation --------------------------------------

// A terrain vertex. `fixed` marks a rim point, which *is* the verge seam: its Y
// is stored, never recomputed from the field. The field would read the nearest
// sample's seam, which beside a jittered cliff is often a different sample, and
// the weld would open.
Terrain_Point :: struct {
	x, z:  f32,
	y:     f32, // meaningful only when `fixed`
	legs:  [2]Terrain_Leg,
	n:     int,
	fixed: bool,
	// How much of the road's own texture this point keeps: 1 at a bare road
	// edge, 0 by TERRAIN_ROADSIDE_M and 0 wherever a guard stands between the
	// ground and the road. Stored rather than derived from the legs, because a
	// rim point **is** the seam and carries no legs at all — deriving it there
	// read as no road, which is the one place the road should be at its
	// strongest. Depends on the ribbon alone, so it caches with the point.
	roadside: f32,
}

// Points and triangles depend only on the ribbon and on reach/cell — never on the
// control heights, and not on `blend_m` either, which only shapes Y. So dragging a
// node reuses the whole triangulation and re-evaluates Y alone. `ribbon_gen` ticks
// whenever the ribbon is rebuilt.
Terrain_Sig :: struct {
	ribbon_gen: u64,
	reach:      f32,
	cell:       f32,
	rough:      f32,
	cell_scale: f32,
}

Terrain_Field :: struct {
	sig:   Terrain_Sig,
	valid: bool,
	pts:   [dynamic]Terrain_Point,
	tris:  [dynamic][3]u32,
	// Y per point as of the last mesh build — sculpt, floors and all. Outside
	// `sig` on purpose: it tracks the control heights, which the signature
	// deliberately ignores. Picking reads it, so it is what was last drawn.
	ys:    [dynamic]f32,
}

terrain_control_base_y :: proc(v: Terrain_Point) -> f32 {
	y: f32
	for k in 0 ..< v.n {
		y += v.legs[k].w * v.legs[k].seam_y
	}
	return y
}

// How far out from the verge a point sits, blended across its legs.
terrain_point_u :: proc(v: Terrain_Point) -> f32 {
	u: f32
	for k in 0 ..< v.n {
		u += v.legs[k].w * v.legs[k].u
	}
	return u
}

// The roadside weight an interior point works out to: bareness and distance
// blended across its legs, like everything else a point reads off the road. A
// rim point does not go through this — see Terrain_Point.roadside.
terrain_legs_roadside :: proc(legs: [2]Terrain_Leg, n: int) -> f32 {
	bare, u: f32
	for k in 0 ..< n {
		bare += legs[k].w * legs[k].bare
		u += legs[k].w * legs[k].u
	}
	return bare * (1 - clamp(u/TERRAIN_ROADSIDE_M, 0, 1))
}

// The global lift: ground climbs away from the road, on top of whatever the
// controls say rather than instead of it. Quadratic, so the verge stays where
// the road put it and the rise is all in the outer half.
terrain_warp :: proc(t: ^Terrain, u: f32) -> f32 {
	if t.warp_m == 0 {
		return 0
	}
	s := clamp(u / max(t.reach_m, 1e-3), 0, 1)
	return t.warp_m * s * s
}

Control_Buckets :: distinct map[[2]i32]int

terrain_control_add :: proc(
	t: ^Terrain,
	buckets: ^Control_Buckets,
	bucket_cell: f32,
	p: Terrain_Point,
	spacing, radius: f32,
	old: []Terrain_Control,
) -> bool {
	key := [2]i32{i32(math.floor(p.x / bucket_cell)), i32(math.floor(p.z / bucket_cell))}
	rings := int(math.ceil(spacing / bucket_cell))
	for dz in -rings ..= rings {
		for dx in -rings ..= rings {
			if j, ok := buckets^[[2]i32{key[0] + i32(dx), key[1] + i32(dz)}]; ok {
				q := t.controls[j]
				dxw, dzw := p.x - q.x, p.z - q.z
				if dxw * dxw + dzw * dzw < spacing * spacing {
					return false
				}
			}
		}
	}
	c := Terrain_Control {
		x      = p.x,
		z      = p.z,
		base_y = terrain_control_base_y(p),
		u      = terrain_point_u(p),
		radius = radius,
	}
	best_d2 := (spacing * 1.5) * (spacing * 1.5)
	for q in old {
		dx, dz := c.x - q.x, c.z - q.z
		if d2 := dx * dx + dz * dz; d2 < best_d2 {
			best_d2 = d2
			c.offset = q.offset
		}
	}
	append(&t.controls, c)
	buckets^[key] = len(t.controls) - 1
	return true
}

// Derive a dense boundary ring and a sparser interior layer from the validated
// world-space point set. There is no left/right row topology: hairpins and
// nearby legs share the same Poisson-spaced control field.
terrain_controls_ensure :: proc(t: ^Terrain, f: ^Terrain_Field) {
	if !t.enabled || !f.valid {
		return
	}
	spacing := clamp(t.row_m, TERRAIN_ROW_M_MIN, TERRAIN_ROW_M_MAX)
	if t.controls_gen == f.sig.ribbon_gen && t.controls_reach == t.reach_m && t.controls_cell == t.cell_m && t.controls_spacing == spacing {
		return
	}
	old := t.controls
	t.controls = nil
	buckets := make(Control_Buckets, context.temp_allocator)
	bucket_cell := spacing * 0.5
	// A narrow boundary band keeps this a single depth of controls. Widening it
	// past one spacing silently creates a second concentric row.
	band := max(t.cell_m * 0.5, spacing * 0.5)
	for p in f.pts {
		if p.fixed || p.n == 0 {
			continue
		}
		if terrain_point_u(p) < t.reach_m - band {
			continue
		}
		_ = terrain_control_add(t, &buckets, bucket_cell, p, spacing, spacing * 3, old[:])
	}

	interior_spacing := clamp(spacing * 2, f32(20), f32(30))
	for p in f.pts {
		if p.fixed || p.n == 0 {
			continue
		}
		u := terrain_point_u(p)
		if u <= max(t.blend_m * 0.5, interior_spacing * 0.5) || u >= t.reach_m - band {
			continue
		}
		_ = terrain_control_add(t, &buckets, bucket_cell, p, interior_spacing, interior_spacing * 2, old[:])
	}
	delete(old)
	t.controls_gen = f.sig.ribbon_gen
	t.controls_reach = t.reach_m
	t.controls_cell = t.cell_m
	t.controls_spacing = spacing
}

terrain_field_delete :: proc(f: ^Terrain_Field) {
	delete(f.pts)
	delete(f.tris)
	delete(f.ys)
}

// Quantised key, so a hairpin pinch that brings two rims into contact does not
// hand delaunator a pair of coincident points.
Dedupe :: distinct map[[2]i32]bool

dedupe_add :: proc(seen: ^Dedupe, x, z: f32) -> bool {
	key := [2]i32{i32(math.floor(x / TERRAIN_DEDUPE_M)), i32(math.floor(z / TERRAIN_DEDUPE_M))}
	if key in seen^ {
		return false
	}
	seen^[key] = true
	return true
}

terrain_field_build :: proc(
	f: ^Terrain_Field,
	t: ^Terrain,
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	roughness: f32,
	cell_scale := f32(1),
) {
	clear(&f.pts)
	clear(&f.tris)
	clear(&f.ys)
	n := len(ribbon)
	if n < 2 {
		return
	}

	fs := field_samples(ribbon, arc, ds, roughness)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for s in fs {
		lo[0] = min(lo[0], s.p[0]);  lo[1] = min(lo[1], s.p[1])
		hi[0] = max(hi[0], s.p[0]);  hi[1] = max(hi[1], s.p[1])
	}
	limit := t.reach_m + 64

	// Grow the cell rather than allocate without bound on a huge stage.
	cell := max(t.cell_m, 0.5)
	for {
		span_x := (hi[0] - lo[0]) + 2 * (t.reach_m + cell)
		span_z := (hi[1] - lo[1]) + 2 * (t.reach_m + cell)
		est := int(span_x / cell + 1) * int(span_z / cell + 1) + 4 * n
		if est <= TERRAIN_MAX_POINTS {
			break
		}
		cell *= 2
	}
	// After the growth, not before it: a long stage is already at whatever cell
	// the point budget allows, and a preview asked for a multiple of the cell
	// actually in use, not of the one that was asked for.
	cell *= cell_scale
	margin := cell * TERRAIN_RIM_MARGIN

	// Every hash answer is exact whatever its cell, so the cell is sized by
	// measurement alone. The floor is the load-bearing half: a ring walk pays
	// per cell visited, scanning one big cell's run of samples is far cheaper,
	// and 32 m is at or within a few per cent of best on stages from 3 to 16 km.
	hash := hash_build(fs, lo, hi, max(cell * 2, 32))
	near_other := terrain_near_other(t, fs, hash)

	seen := make(Dedupe, 1 << 14, context.temp_allocator)
	defer delete_map(seen)

	// A candidate past this from every centreline sample is past `reach` from
	// every seam, because no seam sits further out than `max_e`. Answering that
	// off the cell grid is what keeps the interior pass off the ring walk: most
	// of a stage's bounding box is nowhere near its road, and rejecting one of
	// those points the long way costs a search out to `limit` that finds nothing.
	max_e: f32
	for s in fs {
		max_e = max(max_e, abs(s.e[0]), abs(s.e[1]))
	}
	far := t.reach_m + max_e

	add_interior := proc(
		f: ^Terrain_Field,
		seen: ^Dedupe,
		hash: Sample_Hash,
		fs: []Field_Sample,
		near_other: []bool,
		p: [2]f32,
		reach, margin, limit, far: f32,
	) {
		if hash_far(hash, p, far) {
			return
		}
		pr := field_probe(hash, fs, near_other, p, limit)
		if !pr.ok || pr.su < margin || pr.su > reach {
			return
		}
		if !dedupe_add(seen, p[0], p[1]) {
			return
		}
		pt := Terrain_Point {
			x = p[0],
			z = p[1],
		}
		pt.legs, pt.n = field_legs(hash, fs, near_other, p, limit)
		pt.roadside = terrain_legs_roadside(pt.legs, pt.n)
		append(&f.pts, pt)
	}

	// 1. The rim: the verge seam at every sample, jitter and all. These are the
	//    cliff top's own vertices, and they are the weld.
	for side in 0 ..< 2 {
		for i in 0 ..< n {
			seam := verge_seam(ribbon[i], side, roughness)
			if !dedupe_add(&seen, seam.x, seam.z) {
				continue
			}
			// u is zero by construction here, so the weight is the bareness and
			// nothing else: the road's own texture where the seam is the road
			// edge, none of it where a guard stands in between.
			append(&f.pts, Terrain_Point{
				x = seam.x, y = seam.y, z = seam.z, fixed = true,
				roadside = fs[i].bare[side],
			})
		}
	}

	// 2. Two offset rings close in, so the jump from a 1.7 m rim to a `cell` grid
	//    is graded rather than sudden. Points only — Delaunay finds the topology.
	avg_ds: f32
	for d in ds {
		avg_ds += d
	}
	avg_ds = max(avg_ds / f32(n), 1e-3)
	step := max(int(cell / (1.5 * avg_ds)), 1)
	for u in ([]f32{cell * 1.0, cell * 2.5}) {
		for side in 0 ..< 2 {
			for i := 0; i < n; i += step {
				seam := verge_seam(ribbon[i], side, roughness)
				o := terrain_outward(ribbon[i], side)
				p := [2]f32{seam.x + o.x * u, seam.z + o.z * u}
				add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit, far)
			}
		}
	}

	// 3. The outer edge, so the silhouette follows the road instead of a staircase
	//    of grid cells. Points at u = reach on each side; any that land inside
	//    another leg's corridor, where the offset curve would self-intersect, are
	//    simply rejected by the probe.
	for side in 0 ..< 2 {
		for i := 0; i < n; i += step {
			seam := verge_seam(ribbon[i], side, roughness)
			o := terrain_outward(ribbon[i], side)
			p := [2]f32{seam.x + o.x * t.reach_m, seam.z + o.z * t.reach_m}
			add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit, far)
		}
	}

	// 4. The interior, on a world grid. No parameterisation, so corner interiors
	//    and hairpin bellies fill in like anywhere else.
	gx0 := lo[0] - t.reach_m - cell
	gz0 := lo[1] - t.reach_m - cell
	nx := int((hi[0] - lo[0] + 2 * (t.reach_m + cell)) / cell) + 1
	nz := int((hi[1] - lo[1] + 2 * (t.reach_m + cell)) / cell) + 1
	for iz in 0 ..= nz {
		for ix in 0 ..= nx {
			p := [2]f32{gx0 + f32(ix) * cell, gz0 + f32(iz) * cell}
			add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit, far)
		}
	}

	if len(f.pts) < 3 {
		return
	}

	coords := make([]f64, 2 * len(f.pts), context.temp_allocator)
	for p, i in f.pts {
		coords[i * 2 + 0] = f64(p.x)
		coords[i * 2 + 1] = f64(p.z)
	}
	tris, ok := delaunay_owned(coords, context.temp_allocator)
	if !ok {
		return
	}

	// Delaunay fills the convex hull, so the road corridor, the ground past
	// `reach` and the space off the ends all come back triangulated. Drop them by
	// where their centroid lands. Because the rim is sampled far more densely than
	// the interior, the surviving triangles run their edges along it.
	max_edge2 := (cell * TERRAIN_MAX_EDGE_CELLS) * (cell * TERRAIN_MAX_EDGE_CELLS)
	long_edge_valid := proc(
		a, b: [2]f32,
		max_edge2: f32,
		hash: Sample_Hash,
		fs: []Field_Sample,
		near_other: []bool,
		limit, reach: f32,
	) -> bool {
		if dist2(a, b) <= max_edge2 {
			return true
		}
		mid := [2]f32{(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5}
		pr := field_probe(hash, fs, near_other, mid, limit)
		return pr.ok && pr.su > -TERRAIN_SU_EPS && pr.su <= reach
	}
	for tri in tris {
		a := f.pts[tri[0]]
		b := f.pts[tri[1]]
		cp := f.pts[tri[2]]

		pa := [2]f32{a.x, a.z}
		pb := [2]f32{b.x, b.z}
		pc := [2]f32{cp.x, cp.z}
		if !long_edge_valid(pa, pb, max_edge2, hash, fs, near_other, limit, t.reach_m) ||
		   !long_edge_valid(pb, pc, max_edge2, hash, fs, near_other, limit, t.reach_m) ||
		   !long_edge_valid(pc, pa, max_edge2, hash, fs, near_other, limit, t.reach_m) {
			continue
		}
		centroid := [2]f32{(a.x + b.x + cp.x) / 3, (a.z + b.z + cp.z) / 3}
		pr := field_probe(hash, fs, near_other, centroid, limit)
		if !pr.ok || pr.su <= -TERRAIN_SU_EPS || pr.su > t.reach_m {
			continue
		}
		append(&f.tris, tri)
	}
}

// `cell_scale` above 1 builds the same field at a coarser interior spacing: the
// rim is still every ribbon sample, so the road edge is identical, and only the
// ground between is thinner. That is the editor's preview pass (rebuild.odin),
// and it is the one thing that may not derive the sculpt controls — they belong
// to the document's own cell, and re-deriving them at a coarser one renumbers
// the whole set and re-seats every offset by nearest neighbour.
terrain_field_ensure :: proc(
	f: ^Terrain_Field,
	t: ^Terrain,
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	roughness: f32,
	ribbon_gen: u64,
	cell_scale := f32(1),
) {
	sig := Terrain_Sig {
		ribbon_gen = ribbon_gen,
		reach      = t.reach_m,
		cell       = t.cell_m,
		rough      = roughness,
		cell_scale = cell_scale,
	}
	if !f.valid || f.sig != sig {
		terrain_field_build(f, t, ribbon, arc, ds, roughness, cell_scale)
		f.sig = sig
		f.valid = true
	}
	if cell_scale == 1 {
		terrain_controls_ensure(t, f)
	}
}

terrain_control_offset :: proc(t: ^Terrain, p: [2]f32) -> f32 {
	if len(t.controls) == 0 {
		return 0
	}
	best_d2 := [4]f32{max(f32), max(f32), max(f32), max(f32)}
	best := [4]int{-1, -1, -1, -1}
	for c, i in t.controls {
		dx, dz := p[0] - c.x, p[1] - c.z
		d2 := dx * dx + dz * dz
		if d2 < 1e-4 {
			return c.offset
		}
		if d2 >= c.radius * c.radius {
			continue
		}
		for slot in 0 ..< 4 {
			if d2 < best_d2[slot] {
				for j := 3; j > slot; j -= 1 {
					best_d2[j], best[j] = best_d2[j - 1], best[j - 1]
				}
				best_d2[slot], best[slot] = d2, i
				break
			}
		}
	}
	weighted, weights: f32
	for slot in 0 ..< 4 {
		if best[slot] < 0 {
			continue
		}
		c := t.controls[best[slot]]
		d := math.sqrt(best_d2[slot])
		fade := 1 - d / max(c.radius, 1e-3)
		w := fade * fade / max(best_d2[slot], 1)
		weighted += c.offset * w
		weights += w
	}
	return weights > 0 ? weighted / weights : 0
}

terrain_world_height :: proc(t: ^Terrain, p: [2]f32, legs: [2]Terrain_Leg, n: int) -> f32 {
	base_y, u: f32
	for k in 0 ..< n {
		base_y += legs[k].w * legs[k].seam_y
		u += legs[k].w * legs[k].u
	}
	fade := math.smoothstep(f32(0), max(t.blend_m, 1e-3), u)
	return base_y + terrain_warp(t, u) + terrain_control_offset(t, p) * fade
}

// Y at a terrain point: seam-following base plus the sparse world control field.
field_y :: proc(t: ^Terrain, v: Terrain_Point) -> f32 {
	if v.fixed {
		return v.y
	}
	return terrain_world_height(t, {v.x, v.z}, v.legs, v.n)
}

field_point :: proc(t: ^Terrain, v: Terrain_Point) -> gfx.Vector3 {
	return {v.x, field_y(t, v), v.z}
}

// How far the apron drops, and how far out it leans per metre of drop. Short
// and slightly banked: it has to read as a lip of ground, not a wall.
TERRAIN_SKIRT_DROP : f32 : 1.6
TERRAIN_SKIRT_LEAN : f32 : 0.35

// An apron over the seams the triangulation left bare.
//
// The rim points *are* the verge seams, so every consecutive pair along a run
// ought to be an edge of the terrain. Two things stop it: Delaunay is
// unconstrained, and `TERRAIN_DEDUPE_M` drops a rim point outright when another
// lands within half a metre. Both only bite where two rims come that close,
// which is a fork or a weld and nowhere else — measured on dirtbench_1, the
// bare pairs sit at the three branch nodes and at none of the other 67 edges.
//
// Rather than constrain the triangulation, hang a short bank off the pairs that
// came out bare. It is buried under the ground everywhere the ground did meet
// the road, so it costs nothing to emit on a pair that turns out to be fine.
build_terrain_skirt :: proc(
	m: ^Tri_Mesh,
	t: ^Terrain,
	f: ^Terrain_Field,
	ribbon: []Cross_Section,
	roughness: f32,
	look: Look,
) {
	n := len(ribbon)
	if n < 2 {
		return
	}
	// Rim points by position, then the rim-to-rim edges the triangulation has.
	// Keyed on the seam's own x/z, which `verge_seam` reproduces to the bit.
	at := make(map[[2]f32]int, len(f.pts), context.temp_allocator)
	defer delete(at)
	for p, i in f.pts {
		if p.fixed {
			at[{p.x, p.z}] = i
		}
	}
	have := make(map[[2]int]bool, context.temp_allocator)
	defer delete(have)
	for tri in f.tris {
		for k in 0 ..< 3 {
			a, b := int(tri[k]), int(tri[(k + 1) % 3])
			if !f.pts[a].fixed || !f.pts[b].fixed {
				continue
			}
			if a > b {
				a, b = b, a
			}
			have[{a, b}] = true
		}
	}

	arc := ribbon_arc(ribbon)
	ds := sample_spacing(ribbon)
	for side in 0 ..< 2 {
		for i in 0 ..< n - 1 {
			if ribbon[i + 1].break_before {
				continue
			}
			a := verge_seam(ribbon[i], side, roughness)
			b := verge_seam(ribbon[i + 1], side, roughness)
			ia, a_ok := at[{a.x, a.z}]
			ib, b_ok := at[{b.x, b.z}]
			if a_ok && b_ok {
				lo, hi := ia, ib
				if lo > hi {
					lo, hi = hi, lo
				}
				if have[{lo, hi}] {
					continue // the ground meets the road here
				}
			}
			oa := terrain_outward(ribbon[i], side)
			ob := terrain_outward(ribbon[i + 1], side)
			lean := TERRAIN_SKIRT_DROP * TERRAIN_SKIRT_LEAN
			da := a + oa * lean - gfx.Vector3{0, TERRAIN_SKIRT_DROP, 0}
			db := b + ob * lean - gfx.Vector3{0, TERRAIN_SKIRT_DROP, 0}
			// Wound to face away from the road, so the bank is lit from the side
			// the hole is seen from.
			nrm := gfx.Vector3CrossProduct(b - a, da - a)
			p0, p1, p2, p3 := a, b, db, da
			if gfx.Vector3DotProduct(nrm, oa) < 0 {
				p0, p1, p2, p3 = b, a, da, db
			}
			drop := TERRAIN_SKIRT_DROP / UV_TILE_M
			ua := arc[i] / UV_TILE_M
			ub := arc[i + 1] / UV_TILE_M
			add_quad(
				m, p0, p1, p2, p3,
				{ua, 0}, {ub, 0}, {ub, drop}, {ua, drop},
				lerp_col(look.cliff_bot, look.cliff_top, 0.5), .Cliff,
			)
		}
	}
}

build_terrain_mesh :: proc(
	m: ^Tri_Mesh,
	t: ^Terrain,
	f: ^Terrain_Field,
	ribbon: []Cross_Section,
	roughness: f32,
	look := DEFAULT_LOOK,
) {
	// Heights for the whole point set at once: a floor's divot pass needs its
	// neighbours (floor.odin), and a vertex is shared by about six triangles.
	ys := terrain_floor_heights(t, f)
	at :: proc(f: ^Terrain_Field, ys: []f32, i: u32) -> gfx.Vector3 {
		return {f.pts[i].x, ys[i], f.pts[i].z}
	}
	for tri in f.tris {
		a := at(f, ys, tri[0])
		b := at(f, ys, tri[1])
		cp := at(f, ys, tri[2])
		// How much of the road's own texture each corner keeps. Carried beside
		// the positions because the winding fix below may swap two of them.
		wa := f.pts[tri[0]].roadside
		wb := f.pts[tri[1]].roadside
		wc := f.pts[tri[2]].roadside

		// The terrain is a height field over XZ, so every face points up. Delaunay
		// gives no orientation guarantee, so read the normal and flip the winding
		// rather than trusting it — a downward face would shade as unlit ambient.
		nrm := gfx.Vector3CrossProduct(b - a, cp - a)
		if gfx.Vector3Length(nrm) < 1e-9 {
			continue
		}
		nrm = gfx.Vector3Normalize(nrm)
		if nrm.y < 0 {
			b, cp = cp, b
			wb, wc = wc, wb
			nrm = -nrm
		}
		// A height field over XZ, so a world-planar XZ UV is the natural
		// parameterisation — no seams, and it matches across the rim weld.
		// (Grass is a Lightmap-only material today, so nothing reads this.)
		uv :: proc(v: gfx.Vector3) -> [2]f32 {
			return {v.x / UV_TILE_M, v.z / UV_TILE_M}
		}
		// A triangle clear of the road is ordinary terrain. That is not only
		// cheaper: it is what makes the handover exact, because the roadside
		// material at weight 0 draws the terrain's own texture and nothing else.
		col := terrain_tri_colour(nrm, look)
		mat := Mat_Id.Terrain
		if max(wa, wb, wc) > 0 {
			mat = .Roadside
			col = lerp_col(col, look.road, (wa + wb + wc)/3) // preview only
		}
		add_tri(m, a, b, cp, uv(a), uv(b), uv(cp), col, mat, {wa, wb, wc})
	}
	build_terrain_skirt(m, t, f, ribbon, roughness, look)
}

// --- world-space sculpt controls --------------------------------------------

terrain_set_node :: proc(t: ^Terrain, i: int, y: f32) {
	if i < 0 || i >= terrain_node_count(t) {
		return
	}
	c := &t.controls[i]
	c.offset = y - c.base_y - terrain_warp(t, c.u)
}

// Picking radius follows the world-space control spacing.
terrain_node_radius :: proc(t: ^Terrain) -> f32 {
	return clamp(t.row_m * 0.12, 0.8, 4)
}

// Controls already own their XZ rather than deriving it from a road normal.
terrain_node_world :: proc(
	t: ^Terrain,
	ribbon: []Cross_Section,
	roughness: f32,
	allocator := context.temp_allocator,
) -> []gfx.Vector3 {
	if !t.enabled || len(t.controls) == 0 {
		return nil
	}
	out := make([]gfx.Vector3, len(t.controls), allocator)
	for c, i in t.controls {
		out[i] = {c.x, c.base_y + terrain_warp(t, c.u) + c.offset, c.z}
	}
	return out
}

terrain_node_active_mask :: proc(
	t: ^Terrain,
	pos: []gfx.Vector3,
	allocator := context.temp_allocator,
) -> []bool {
	out := make([]bool, len(pos), allocator)
	for &v in out {
		v = true
	}
	return out
}

// Nearest node the ray strikes, as an index into terrain_node_world, or -1.
pick_terrain_node :: proc(pos: []gfx.Vector3, active: []bool, radius: f32, ray: gfx.Ray) -> (idx: int, dist: f32) {
	idx = -1
	dist = max(f32)
	for p, i in pos {
		if len(active) == len(pos) && !active[i] {
			continue
		}
		if hit := gfx.GetRayCollisionSphere(ray, p, radius); hit.hit && hit.distance < dist {
			dist = hit.distance
			idx = i
		}
	}
	return
}

// World controls have no artificial along-road adjacency, so only handles are
// drawn; connecting them would reintroduce misleading crossings at hairpins.
draw_terrain_nodes :: proc(
	t: ^Terrain, pos: []gfx.Vector3, active: []bool, weights: []f32, selected: int,
) {
	if len(pos) == 0 {
		return
	}
	count := min(terrain_node_count(t), len(pos))
	radius := terrain_node_radius(t)
	for i in 0 ..< count {
		if len(active) == len(pos) && !active[i] {
			continue
		}
		hcol := gfx.Color{150, 230, 180, 255}
		if i < len(weights) && weights[i] > 0 {
			hcol = gfx.color_mix(hcol, {255, 190, 80, 255}, weights[i])
		}
		if i == selected {
			hcol = {255, 120, 60, 255}
		}
		gfx.DrawSphereEx(pos[i], radius, 3, 4, hcol)
	}
}

// --- build -------------------------------------------------------------------

terrain_mesh_rebuild :: proc(
	tm: ^Gpu_Mesh,
	f: ^Terrain_Field,
	t: ^Terrain,
	ribbon: []Cross_Section,
	roughness: f32,
	ribbon_gen: u64,
) {
	gpu_mesh_unload(tm)
	if !t.enabled || len(ribbon) < 2 {
		return
	}
	arc := ribbon_arc(ribbon)
	if arc[len(ribbon) - 1] <= 0 {
		return
	}
	ds := sample_spacing(ribbon)

	terrain_field_ensure(f, t, ribbon, arc, ds, roughness, ribbon_gen)

	m := tri_mesh_make(context.temp_allocator)
	build_terrain_mesh(&m, t, f, ribbon, roughness)
	tm^ = gpu_mesh_upload(m)
}
