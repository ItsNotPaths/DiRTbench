package geo

// Terrain — the out-of-stage mesh.
//
// Ground outside the road, sculpted by a coarse 2D lattice of **height-only**
// control nodes. Height-only is a guarantee rather than a limitation: a node is
// one f32, its XZ is derived, and so the lattice can never fold or overhang.
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
// The lattice is still ribbon-local — rows along the road by arc length, columns
// outward from the verge — so the sculpt follows the spline. Heights are
// absolute world Y.

import "core:c"
import "core:math"
import rl "../gfx"

// Vertex colours, since the material is unlit (see mesh.odin). Slope picks
// between them: flat ground is grass, a steep face is the rock under it.
TERRAIN_FLAT :: rl.Color{86, 112, 68, 255}
TERRAIN_STEEP :: rl.Color{112, 104, 92, 255}

// The lattice sculpts *landforms* — big sloping hills, not small humps — so the
// node counts are deliberately low and their caps are low with them. A node's
// influence is a couple of lattice cells wide (Catmull-Rom), so fewer nodes is
// the same thing as a longer-wavelength surface. Tessellation is a separate
// knob: `cell_m` decides how finely those hills are drawn.
TERRAIN_REACH_MAX :: 400.0
TERRAIN_ROWS_MAX :: 48
TERRAIN_COLS_MAX :: 12

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

// An edge longer than this many cells cannot be interior: it spans the convex
// hull, or bridges a hole the centroid test happened to miss.
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

Terrain :: struct {
	enabled: bool,
	reach_m: f32, // how far the ground reaches past the verge
	blend_m: f32, // metres over which the lattice takes over from the verge seam
	cell_m:  f32, // spacing of the interior points
	rows:    int, // lattice stations along the road
	cols:    int, // lattice stations across the skirt
	// Node heights, absolute world Y, row-major [r*cols + c]. One lattice per
	// side, mirroring how the verges are built (side 0 = +right).
	nodes:   [2][dynamic]f32,
}

// `blend_m` is deliberately a large fraction of `reach_m`. It is the distance
// over which the road stops dictating the ground and the lattice takes over, and
// a narrow band crossed in one cell reads as a terrace rather than a slope.
//
// Blend and node count are coupled: a coarse lattice approximates the road's
// elevation from further away, so the blend has more height to absorb and needs
// to be wider. Halve the nodes and the blend wants widening, not narrowing.
TERRAIN_DEFAULTS :: Terrain {
	enabled = false,
	reach_m = 96,
	blend_m = 48,
	cell_m  = 8,
	rows    = 13,
	cols    = 3,
}

terrain_delete :: proc(t: ^Terrain) {
	for &side in t.nodes {
		delete(side)
	}
}

// --- lattice ----------------------------------------------------------------

terrain_node_count :: proc(t: ^Terrain) -> int {
	return t.rows * t.cols
}

// A node's height, with clamped indices so the Catmull-Rom taps below can run
// off the edge of the lattice and get the border value instead of a bounds trap.
terrain_node :: proc(t: ^Terrain, side, r, c: int) -> f32 {
	i := clamp(r, 0, t.rows - 1) * t.cols + clamp(c, 0, t.cols - 1)
	return t.nodes[side][i]
}

// Catmull-Rom through p1 and p2, with p0/p3 as the outer tangent taps.
catmull :: proc(p0, p1, p2, p3, t: f32) -> f32 {
	t2 := t * t
	t3 := t2 * t
	return 0.5 *
		(2 * p1 +
				(p2 - p0) * t +
				(2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
				(3 * p1 - p0 - 3 * p2 + p3) * t3)
}

// Height of the sculpted lattice at arc fraction `s_frac` along the road and
// `u` metres outward from the verge. Bicubic, because a bilinear patch creases
// visibly along every node row — and the road it sits beside is a cubic.
//
// Column c sits at u = reach * (c+1)/cols, so there is no dead node pinned at
// u=0 where the blend below would ignore it anyway.
lattice_height :: proc(t: ^Terrain, side: int, s_frac, u: f32) -> f32 {
	if t.rows < 1 || t.cols < 1 {
		return 0
	}
	rf := clamp(s_frac, 0, 1) * f32(t.rows - 1)
	cf := u / max(t.reach_m, 1e-3) * f32(t.cols) - 1

	r0 := int(math.floor(rf))
	c0 := int(math.floor(cf))
	fr := rf - f32(r0)
	fc := cf - f32(c0)

	// interpolate across columns at four consecutive rows, then along the road
	row := proc(t: ^Terrain, side, r, c0: int, fc: f32) -> f32 {
		return catmull(
			terrain_node(t, side, r, c0 - 1),
			terrain_node(t, side, r, c0),
			terrain_node(t, side, r, c0 + 1),
			terrain_node(t, side, r, c0 + 2),
			fc,
		)
	}
	return catmull(
		row(t, side, r0 - 1, c0, fc),
		row(t, side, r0, c0, fc),
		row(t, side, r0 + 1, c0, fc),
		row(t, side, r0 + 2, c0, fc),
		fr,
	)
}

// The surface height `u` metres out from a verge seam. Blend from the **seam**,
// never from a cliff crest's height: with a ditch the seam sits below the road,
// and this stays correct. At u=0 the weight is zero, so the seam is reproduced.
terrain_height :: proc(t: ^Terrain, side: int, s_frac, u, seam_y: f32) -> f32 {
	if u <= 0 {
		return seam_y
	}
	w := math.smoothstep(f32(0), max(t.blend_m, 1e-3), u)
	return seam_y + (lattice_height(t, side, s_frac, u) - seam_y) * w
}

// --- sizing and seeding -----------------------------------------------------

// Index of the ribbon sample nearest `s` metres along the road.
arc_sample :: proc(arc: []f32, s: f32) -> int {
	lo, hi := 0, len(arc) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if arc[mid] < s {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// Seed every node with the verge seam's height at its row, so a freshly enabled
// terrain starts flush with the cliff tops and flat outward — rather than at
// y=0, which would bury the road.
terrain_reset :: proc(t: ^Terrain, ribbon: []Cross_Section, topo: c.int, roughness: f32) {
	for &side in t.nodes {
		resize(&side, terrain_node_count(t))
	}
	n := len(ribbon)
	if n < 2 || t.rows < 1 || t.cols < 1 {
		return
	}

	arc := ribbon_arc(ribbon)
	ds := sample_spacing(ribbon)
	total := arc[n - 1]
	vrows := verge_rows(topo)

	for r in 0 ..< t.rows {
		s := total * f32(r) / f32(max(t.rows - 1, 1))
		i := arc_sample(arc, s)
		for side in 0 ..< 2 {
			y := verge_seam(ribbon[i], side, vrows, i, roughness, ds[i]).y
			for c in 0 ..< t.cols {
				t.nodes[side][r * t.cols + c] = y
			}
		}
	}
}

// Drop the sculpt so terrain_ensure reseeds it from the current verge.
//
// Node heights are **absolute world Y**, measured against the road that was
// under them. Replacing the spline wholesale — New, Load, Generate — leaves
// every node describing a road that no longer exists, and the terrain would sit
// at the old stage's elevation while the new one climbs away from it. Editing a
// point does *not* invalidate: a nudge should preserve the sculpt.
terrain_invalidate :: proc(t: ^Terrain) {
	for &side in t.nodes {
		clear(&side)
	}
}

// Resize after a rows/cols change, and seed if the lattice is empty. Resizing
// discards the sculpt: the nodes are indexed, not positioned, so there is no
// meaning-preserving way to reinterpret them at a different resolution.
terrain_ensure :: proc(t: ^Terrain, ribbon: []Cross_Section, topo: c.int, roughness: f32) {
	if !t.enabled {
		return
	}
	count := terrain_node_count(t)
	if len(t.nodes[0]) != count || len(t.nodes[1]) != count {
		terrain_reset(t, ribbon, topo, roughness)
	}
}

// --- ribbon frame -----------------------------------------------------------

// The outward direction, **flattened onto the ground plane**.
//
// Heights are world-vertical, so a banked road must not tilt the terrain beside
// it. Only when the road is banked to vertical does `right` lose its ground
// component, and then it degenerates to exactly cross(worldUp, fwd).
terrain_outward :: proc(cs: Cross_Section, side: int) -> rl.Vector3 {
	r := side == 0 ? cs.right : -cs.right
	f := rl.Vector3{r.x, 0, r.z}
	if rl.Vector3Length(f) > 1e-4 {
		return rl.Vector3Normalize(f)
	}
	g := rl.Vector3CrossProduct({0, 1, 0}, cs.fwd)
	if rl.Vector3Length(g) < 1e-4 {
		return {1, 0, 0}
	}
	g = rl.Vector3Normalize(g)
	return side == 0 ? g : -g
}

terrain_tri_colour :: proc(n: rl.Vector3) -> rl.Color {
	return lerp_col(TERRAIN_FLAT, TERRAIN_STEEP, clamp((1 - abs(n.y)) * 2, 0, 1))
}

// --- the field ---------------------------------------------------------------

// Everything a world point needs from one ribbon sample to evaluate the field.
Field_Sample :: struct {
	p:      [2]f32,    // centreline, XZ
	right:  [2]f32,    // side-0 outward, flattened, unit
	fwd:    [2]f32,    // travel direction, flattened, unit
	seam:   [2][2]f32, // seam XZ per side
	seam_y: [2]f32,
	e:      [2]f32, // the seam's outward offset from the centreline, per side
	s_frac: f32,
	arc:    f32,
	ds:     f32,
}

// A world point's relationship to one leg of the road.
Terrain_Leg :: struct {
	s_frac: f32,
	u:      f32, // metres outward from that leg's seam; never negative
	seam_y: f32,
	w:      f32, // normalised blend weight
	side:   int,
}

field_samples :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	topo: c.int,
	roughness: f32,
	allocator := context.temp_allocator,
) -> []Field_Sample {
	n := len(ribbon)
	total := arc[n - 1]
	vrows := verge_rows(topo)
	out := make([]Field_Sample, n, allocator)

	for i in 0 ..< n {
		cs := ribbon[i]
		s: Field_Sample
		s.p = {cs.pos.x, cs.pos.z}
		s.arc = arc[i]
		s.ds = ds[i]
		s.s_frac = total > 0 ? arc[i] / total : 0

		r0 := terrain_outward(cs, 0)
		s.right = {r0.x, r0.z}
		f := rl.Vector3{cs.fwd.x, 0, cs.fwd.z}
		if rl.Vector3Length(f) > 1e-4 {
			f = rl.Vector3Normalize(f)
		}
		s.fwd = {f.x, f.z}

		for side in 0 ..< 2 {
			seam := verge_seam(cs, side, vrows, i, roughness, ds[i])
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
	return h
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
hash_nearest :: proc(
	h: Sample_Hash,
	fs: []Field_Sample,
	p: [2]f32,
	limit: f32,
	skip_arc: f32 = -1,
	skip_p: [2]f32 = {},
	other_leg := false,
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
					if other_leg {
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
		other, _ := hash_nearest(h, fs, fs[i].p, 2 * t.reach_m, fs[i].arc, fs[i].p, true)
		out[i] = other >= 0
	}
	return out
}

// How far `p` lies outside the road corridor, in metres, measured from the seam
// of whichever leg is nearest. Negative means inside the road or its verge.
//
// `beyond` marks a point off the end of the stage: its nearest sample is an
// endpoint and it lies past it, so there is no road here to skirt.
Field_Probe :: struct {
	su:     f32,
	beyond: bool,
	ok:     bool,
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
	fr.j = fr.fwd >= 0 ? min(i + 1, len(fs) - 1) : max(i - 1, 0)
	fr.tt = clamp(abs(fr.fwd) / max(s.ds, 1e-4), 0, 1)
	return
}

// The seam's outward offset, interpolated toward the neighbouring sample.
field_seam_offset :: proc(fs: []Field_Sample, i: int, fr: Field_Frame) -> f32 {
	e := fs[i].e[fr.side]
	return e + (fs[fr.j].e[fr.side] - e) * fr.tt
}

field_probe :: proc(h: Sample_Hash, fs: []Field_Sample, p: [2]f32, limit: f32) -> Field_Probe {
	i0, _ := hash_nearest(h, fs, p, limit)
	if i0 < 0 {
		return {}
	}
	fr := field_project(fs, i0, p)
	beyond := (i0 == 0 && fr.fwd < 0) || (i0 == len(fs) - 1 && fr.fwd > 0)
	return {su = abs(fr.lateral) - field_seam_offset(fs, i0, fr), beyond = beyond, ok = true}
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
	leg.s_frac = s.s_frac + (sj.s_frac - s.s_frac) * fr.tt
	leg.u = max(0, abs(fr.lateral) - field_seam_offset(fs, i, fr))
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

	i1, d1 := hash_nearest(h, fs, p, d0 * TERRAIN_LEG_CUTOFF, fs[i0].arc, fs[i0].p, true)
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
}

// Points and triangles depend only on the ribbon and on reach/cell — never on the
// lattice heights, and not on `blend_m` either, which only shapes Y. So dragging a
// node reuses the whole triangulation and re-evaluates Y alone. `ribbon_gen` ticks
// whenever the ribbon is rebuilt.
Terrain_Sig :: struct {
	ribbon_gen: u64,
	reach:      f32,
	cell:       f32,
	rough:      f32,
	topo:       c.int,
}

Terrain_Field :: struct {
	sig:   Terrain_Sig,
	valid: bool,
	pts:   [dynamic]Terrain_Point,
	tris:  [dynamic][3]u32,
}

terrain_field_delete :: proc(f: ^Terrain_Field) {
	delete(f.pts)
	delete(f.tris)
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
	topo: c.int,
	roughness: f32,
) {
	clear(&f.pts)
	clear(&f.tris)
	n := len(ribbon)
	if n < 2 {
		return
	}

	fs := field_samples(ribbon, arc, ds, topo, roughness)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for s in fs {
		lo[0] = min(lo[0], s.p[0]);  lo[1] = min(lo[1], s.p[1])
		hi[0] = max(hi[0], s.p[0]);  hi[1] = max(hi[1], s.p[1])
	}
	hash := hash_build(fs, lo, hi, max(t.cell_m * 2, 8))
	near_other := terrain_near_other(t, fs, hash)

	limit := t.reach_m + 64
	vrows := verge_rows(topo)

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
	margin := cell * TERRAIN_RIM_MARGIN

	seen := make(Dedupe, 1 << 14, context.temp_allocator)
	defer delete_map(seen)

	add_interior := proc(
		f: ^Terrain_Field,
		seen: ^Dedupe,
		hash: Sample_Hash,
		fs: []Field_Sample,
		near_other: []bool,
		p: [2]f32,
		reach, margin, limit: f32,
	) {
		pr := field_probe(hash, fs, p, limit)
		if !pr.ok || pr.beyond || pr.su < margin || pr.su > reach {
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
		append(&f.pts, pt)
	}

	// 1. The rim: the verge seam at every sample, jitter and all. These are the
	//    cliff top's own vertices, and they are the weld.
	for side in 0 ..< 2 {
		for i in 0 ..< n {
			seam := verge_seam(ribbon[i], side, vrows, i, roughness, ds[i])
			if !dedupe_add(&seen, seam.x, seam.z) {
				continue
			}
			append(&f.pts, Terrain_Point{x = seam.x, y = seam.y, z = seam.z, fixed = true})
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
				seam := verge_seam(ribbon[i], side, vrows, i, roughness, ds[i])
				o := terrain_outward(ribbon[i], side)
				p := [2]f32{seam.x + o.x * u, seam.z + o.z * u}
				add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit)
			}
		}
	}

	// 3. The outer edge, so the silhouette follows the road instead of a staircase
	//    of grid cells. Points at u = reach on each side; any that land inside
	//    another leg's corridor, where the offset curve would self-intersect, are
	//    simply rejected by the probe.
	for side in 0 ..< 2 {
		for i := 0; i < n; i += step {
			seam := verge_seam(ribbon[i], side, vrows, i, roughness, ds[i])
			o := terrain_outward(ribbon[i], side)
			p := [2]f32{seam.x + o.x * t.reach_m, seam.z + o.z * t.reach_m}
			add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit)
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
			add_interior(f, &seen, hash, fs, near_other, p, t.reach_m, margin, limit)
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
	tris, ok := delaunay_triangulate(coords)
	if !ok {
		return
	}
	defer delaunay_delete(tris)

	// Delaunay fills the convex hull, so the road corridor, the ground past
	// `reach` and the space off the ends all come back triangulated. Drop them by
	// where their centroid lands. Because the rim is sampled far more densely than
	// the interior, the surviving triangles run their edges along it.
	max_edge2 := (cell * TERRAIN_MAX_EDGE_CELLS) * (cell * TERRAIN_MAX_EDGE_CELLS)
	for tri in tris {
		a := f.pts[tri[0]]
		b := f.pts[tri[1]]
		cp := f.pts[tri[2]]

		pa := [2]f32{a.x, a.z}
		pb := [2]f32{b.x, b.z}
		pc := [2]f32{cp.x, cp.z}
		if dist2(pa, pb) > max_edge2 || dist2(pb, pc) > max_edge2 || dist2(pc, pa) > max_edge2 {
			continue
		}
		centroid := [2]f32{(a.x + b.x + cp.x) / 3, (a.z + b.z + cp.z) / 3}
		pr := field_probe(hash, fs, centroid, limit)
		if !pr.ok || pr.beyond || pr.su <= -TERRAIN_SU_EPS || pr.su > t.reach_m {
			continue
		}
		append(&f.tris, tri)
	}
}

terrain_field_ensure :: proc(
	f: ^Terrain_Field,
	t: ^Terrain,
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	topo: c.int,
	roughness: f32,
	ribbon_gen: u64,
) {
	sig := Terrain_Sig {
		ribbon_gen = ribbon_gen,
		reach      = t.reach_m,
		cell       = t.cell_m,
		rough      = roughness,
		topo       = topo,
	}
	if f.valid && f.sig == sig {
		return
	}
	terrain_field_build(f, t, ribbon, arc, ds, topo, roughness)
	f.sig = sig
	f.valid = true
}

// Y at a terrain point: the field, summed over its legs.
field_y :: proc(t: ^Terrain, v: Terrain_Point) -> f32 {
	if v.fixed {
		return v.y
	}
	y: f32
	for k in 0 ..< v.n {
		l := v.legs[k]
		y += l.w * terrain_height(t, l.side, l.s_frac, l.u, l.seam_y)
	}
	return y
}

field_point :: proc(t: ^Terrain, v: Terrain_Point) -> rl.Vector3 {
	return {v.x, field_y(t, v), v.z}
}

build_terrain_mesh :: proc(m: ^Tri_Mesh, t: ^Terrain, f: ^Terrain_Field) {
	for tri in f.tris {
		a := field_point(t, f.pts[tri[0]])
		b := field_point(t, f.pts[tri[1]])
		cp := field_point(t, f.pts[tri[2]])

		// The terrain is a height field over XZ, so every face points up. Delaunay
		// gives no orientation guarantee, so read the normal and flip the winding
		// rather than trusting it — a downward face would shade as unlit ambient.
		nrm := rl.Vector3CrossProduct(b - a, cp - a)
		if rl.Vector3Length(nrm) < 1e-9 {
			continue
		}
		nrm = rl.Vector3Normalize(nrm)
		if nrm.y < 0 {
			b, cp = cp, b
			nrm = -nrm
		}
		// A height field over XZ, so a world-planar XZ UV is the natural
		// parameterisation — no seams, and it matches across the rim weld.
		// (Grass is a Lightmap-only material today, so nothing reads this.)
		uv :: proc(v: rl.Vector3) -> [2]f32 {
			return {v.x / UV_TILE_M, v.z / UV_TILE_M}
		}
		add_tri(m, a, b, cp, uv(a), uv(b), uv(cp), terrain_tri_colour(nrm), .Terrain)
	}
}

// --- lattice nodes in the world ---------------------------------------------

terrain_set_node :: proc(t: ^Terrain, side, i: int, y: f32) {
	if i < 0 || i >= terrain_node_count(t) {
		return
	}
	t.nodes[side][i] = y
}

// Picking radius of a node handle, scaled to the lattice's spacing so a coarse
// lattice gets fat handles and a fine one does not fuse into a wall of spheres.
terrain_node_radius :: proc(t: ^Terrain) -> f32 {
	return clamp(t.reach_m / f32(max(t.cols, 1)) * 0.15, 0.6, 8)
}

// Every node's world position, indexed [side*count + r*cols + c]. Temp-allocated,
// nil when there is nothing to show.
//
// The Y is the node's **own height**, not the blended surface under it. Inside
// the blend band the surface is pulled toward the verge seam, so a handle there
// floats off the ground it controls — which is the truth, and dragging it stays
// 1:1 with the gizmo.
terrain_node_world :: proc(
	t: ^Terrain,
	ribbon: []Cross_Section,
	topo: c.int,
	roughness: f32,
	allocator := context.temp_allocator,
) -> []rl.Vector3 {
	n := len(ribbon)
	count := terrain_node_count(t)
	if !t.enabled || n < 2 || t.rows < 2 || t.cols < 1 {
		return nil
	}
	if len(t.nodes[0]) != count || len(t.nodes[1]) != count {
		return nil // lattice resized; rebuild_geometry reseeds it next frame
	}

	arc := ribbon_arc(ribbon)
	total := arc[n - 1]
	if total <= 0 {
		return nil
	}
	ds := sample_spacing(ribbon)
	vrows := verge_rows(topo)

	out := make([]rl.Vector3, 2 * count, allocator)
	for side in 0 ..< 2 {
		for r in 0 ..< t.rows {
			i := arc_sample(arc, total * f32(r) / f32(t.rows - 1))
			seam := verge_seam(ribbon[i], side, vrows, i, roughness, ds[i])
			outward := terrain_outward(ribbon[i], side)
			for col in 0 ..< t.cols {
				u := t.reach_m * f32(col + 1) / f32(t.cols)
				p := seam + outward * u
				p.y = terrain_node(t, side, r, col)
				out[side * count + r * t.cols + col] = p
			}
		}
	}
	return out
}

// Nearest node the ray strikes, as an index into terrain_node_world, or -1.
pick_terrain_node :: proc(pos: []rl.Vector3, radius: f32, ray: rl.Ray) -> (idx: int, dist: f32) {
	idx = -1
	dist = max(f32)
	for p, i in pos {
		if hit := rl.GetRayCollisionSphere(ray, p, radius); hit.hit && hit.distance < dist {
			dist = hit.distance
			idx = i
		}
	}
	return
}

// The lattice, drawn as handles joined along rows and columns. `selected` is an
// index into `pos`, or -1.
draw_terrain_nodes :: proc(t: ^Terrain, pos: []rl.Vector3, selected: int) {
	if len(pos) == 0 {
		return
	}
	count := terrain_node_count(t)
	radius := terrain_node_radius(t)
	grid := rl.Color{90, 150, 115, 255}

	for side in 0 ..< 2 {
		base := side * count
		for r in 0 ..< t.rows {
			for col in 0 ..< t.cols - 1 {
				rl.DrawLine3D(pos[base + r * t.cols + col], pos[base + r * t.cols + col + 1], grid)
			}
		}
		for col in 0 ..< t.cols {
			for r in 0 ..< t.rows - 1 {
				rl.DrawLine3D(pos[base + r * t.cols + col], pos[base + (r + 1) * t.cols + col], grid)
			}
		}
		for i in 0 ..< count {
			hcol := base + i == selected ? rl.Color{255, 120, 60, 255} : rl.Color{150, 230, 180, 255}
			// Low-poly: a maxed-out lattice is hundreds of handles a side.
			rl.DrawSphereEx(pos[base + i], radius, 6, 6, hcol)
		}
	}
}

// --- build -------------------------------------------------------------------

terrain_mesh_rebuild :: proc(
	tm: ^Gpu_Mesh,
	f: ^Terrain_Field,
	t: ^Terrain,
	ribbon: []Cross_Section,
	topo: c.int,
	roughness: f32,
	ribbon_gen: u64,
) {
	gpu_mesh_unload(tm)
	if !t.enabled || len(ribbon) < 2 || t.rows < 2 || t.cols < 1 {
		return
	}
	arc := ribbon_arc(ribbon)
	if arc[len(ribbon) - 1] <= 0 {
		return
	}
	ds := sample_spacing(ribbon)

	terrain_field_ensure(f, t, ribbon, arc, ds, topo, roughness, ribbon_gen)

	m := tri_mesh_make(context.temp_allocator)
	build_terrain_mesh(&m, t, f)
	tm^ = gpu_mesh_upload(m)
}
