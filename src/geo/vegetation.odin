package geo

// Vegetation: a primitive scatter of trees over the terrain either side of the
// road. It lives in the stage document (see stage.odin) and is handed to the
// export target as a list of `Prop_Kind` placements; each target resolves those
// onto its own game's props, so nothing here knows about any one game.
//
// The distribution is deliberately simple: a jittered grid in (arc, lateral)
// space, one candidate per cell, seeded so a given stage scatters the same way
// every time. Density sets the grid spacing; `road_bias` trades width for nearness,
// giving up the far ground and spending it on tighter rows and tighter columns, so
// the tree count holds and only its shape changes. Rows are measured run by run and
// no two trees share a cell, because a road graph is not one road: see veg_rows and
// VEG_GAP.
//
// Which species is not a knob. A venue derives its art from a base venue, and the
// trees come with it — firs in Finland, thorn trees in Kenya — so the preset is
// read off the base (veg_preset_for_base) and the stage file does not store it.
//
// Ground height comes from the same terrain field the mesh is built from
// (terrain.odin), so a tree sits on the sculpted surface, not on a flat plane. If
// the terrain is off there is no field to probe: the scatter falls back to the
// verge-seam height and rides the road edge.

import "core:c"
import "core:math"
import "core:strings"
import "../gfx"

// The species families. Not a choice: a venue derives its art from a base venue,
// and the trees are part of that art, so the preset is read off the base (see
// veg_preset_for_base). The name is shown, never picked.
Veg_Preset :: enum i32 {
	Firs  = 0, // conifers, the northern forest
	Oaks,      // leafy broadleaf
	Snowy,     // frosted firs and bare trees, for a winter stage
	Acacia,    // flat-topped thorn trees and scrub, for the savannah
}

VEG_PRESET_NAMES := [Veg_Preset]cstring {
	.Firs   = "Firs",
	.Oaks   = "Oaks",
	.Snowy  = "Snowy",
	.Acacia = "Acacia",
}

// Which family a base venue's art calls for. `base` is the "<location>/<venue>"
// a venue derives from (venue.odin); an unknown one falls back to firs, which
// suits any northern forest.
veg_preset_for_base :: proc(base: string) -> Veg_Preset {
	venue := base
	if slash := strings.last_index_byte(base, '/'); slash >= 0 {
		venue = base[slash + 1:]
	}
	switch {
	case strings.has_prefix(venue, "kenya"):       return .Acacia
	case strings.has_prefix(venue, "norway"):      return .Snowy
	case strings.has_prefix(venue, "monte_carlo"): return .Snowy
	case strings.has_prefix(venue, "michigan"):    return .Oaks
	}
	return .Firs
}

// What a scatter prop *is*, independent of any game. An export target maps each
// kind onto whatever prop its own game ships, so a target with no match for a
// kind can drop it without the scatter caring.
// Persisted nowhere — the stage file stores the preset, not the picks — so this
// may be reordered freely.
Prop_Kind :: enum u8 {
	Conifer_Tall,
	Conifer_Medium,
	Conifer_Snow_Tall,
	Conifer_Snow_Medium,
	Broadleaf_Big,
	Broadleaf_Tall,
	Broadleaf_Medium,
	Broadleaf_Bare_Medium,
	Broadleaf_Bare_Small,
	Acacia_Big,
	Acacia_Medium,
	Thorn_Bush,
}

// How a species reads as a viewport placeholder. The game item is the real thing;
// these are just enough shape to judge the scatter's spacing and mass.
Veg_Shape :: enum u8 {
	Conifer,   // tall cone on a short trunk (firs)
	Broadleaf, // round canopy lifted on a taller trunk (the leafy trees)
	Bush,      // a low ground sphere, no real trunk
}

// One member of a preset's pool: what it is, its relative pick weight, the
// uniform-scale band it spawns at, and the placeholder shape + rough metric size
// used to draw it. The scale band gives a stand size variety without distinct
// meshes; `h`/`r`/`trunk` are metres before that per-instance scale is applied.
Veg_Species :: struct {
	kind:      Prop_Kind,
	weight:    f32,
	scale_min: f32,
	scale_max: f32,
	shape:     Veg_Shape,
	h:         f32, // canopy/cone height (Conifer) — unused by round shapes
	r:         f32, // base/canopy radius
	trunk:     f32, // trunk height the canopy sits on
}

// Placeholder canopy tint per preset — translucent green, paler for the winter set.
// Alpha is baked in; the trunk has its own colour in veg_draw.
veg_canopy_col :: proc(p: Veg_Preset) -> gfx.Color {
	switch p {
	case .Firs:   return {46, 104, 58, 150}
	case .Oaks:   return {84, 148, 66, 150}
	case .Snowy:  return {188, 208, 198, 160}
	case .Acacia: return {118, 132, 82, 150}
	}
	return {84, 148, 66, 150}
}

// The pools. Sizes are metres, and are what the viewport draws; the target's own
// prop is whatever it maps the kind onto, so the two only have to agree roughly.
veg_pool :: proc(p: Veg_Preset) -> []Veg_Species {
	@(static) firs := []Veg_Species {
		{.Conifer_Tall, 1.0, 0.9, 1.15, .Conifer, 14, 2.6, 1.2},
		{.Conifer_Medium, 1.3, 0.9, 1.2, .Conifer, 9, 2.1, 1.0},
	}
	@(static) oaks := []Veg_Species {
		{.Broadleaf_Big, 0.8, 0.9, 1.1, .Broadleaf, 0, 4.2, 4.5},
		{.Broadleaf_Tall, 1.0, 0.9, 1.15, .Broadleaf, 0, 3.4, 5.0},
		{.Broadleaf_Medium, 1.4, 0.9, 1.2, .Broadleaf, 0, 3.0, 3.5},
	}
	@(static) snowy := []Veg_Species {
		{.Conifer_Snow_Tall, 1.0, 0.9, 1.15, .Conifer, 13, 2.5, 1.2},
		{.Conifer_Snow_Medium, 1.3, 0.9, 1.2, .Conifer, 9, 2.0, 1.0},
		{.Broadleaf_Bare_Medium, 0.7, 0.9, 1.2, .Broadleaf, 0, 2.6, 3.2},
		{.Broadleaf_Bare_Small, 0.5, 0.9, 1.1, .Broadleaf, 0, 2.1, 2.6},
	}
	// Flat-topped and lifted: a wide, shallow canopy on a long bare trunk, with
	// scrub between the trees. The shapes are the same two the rest of the pools
	// use; only the proportions say savannah.
	@(static) acacia := []Veg_Species {
		{.Acacia_Big, 0.8, 0.9, 1.15, .Broadleaf, 0, 5.0, 6.0},
		{.Acacia_Medium, 1.0, 0.9, 1.2, .Broadleaf, 0, 3.8, 4.5},
		{.Thorn_Bush, 1.6, 0.8, 1.3, .Bush, 0, 1.4, 0},
	}
	switch p {
	case .Firs:   return firs
	case .Oaks:   return oaks
	case .Snowy:  return snowy
	case .Acacia: return acacia
	}
	return firs
}

// The knobs, persisted per stage. `road_bias` is gentle by default but has real
// travel: at 1 a rally stage runs through a corridor of trunks. `preset` is the
// one field nobody types: it comes off the venue's base and is set when the venue
// is opened, so it is not saved with the rest.
Veg_Params :: struct {
	enabled:   bool,
	preset:    Veg_Preset,
	density:   f32,   // 0..1; drives the grid spacing
	road_bias: f32,   // 0..1; how hard the forest is pulled in against the verge
	seed:      c.int,
	// Distant card billboards (billboards.odin): the wall that hides the void past
	// the terrain, and single-tree cards on terrain the trees below do not cover.
	// Independent of `enabled` — a stage with no trees still has a void, and its
	// whole terrain is ground with no tree on it.
	billboards: bool,
}

VEG_DEFAULTS :: Veg_Params {
	enabled    = false,
	preset     = .Firs,
	density    = 0.5,
	road_bias  = 0.25,
	seed       = 1,
	billboards = false,
}

// Grid spacing (metres) at density 0 and density 1. The scatter walks from sparse
// to dense across the slider.
VEG_SPACING_SPARSE :: f32(34)
VEG_SPACING_DENSE :: f32(7)
// How far off the verge seam the nearest tree may stand, so trunks never crowd the
// road edge or clip the verge geometry. Full bias walks it in to VEG_U_NEAR_TIGHT,
// which a rally stage wants and which still clears the corridor test by VEG_CLEAR.
VEG_U_NEAR :: f32(4)
VEG_U_NEAR_TIGHT :: f32(2.5)
// The narrowest a column may be, in metres. The bias walks the first column's width
// down to this; below it the trees would be planted inside each other.
VEG_STEP_MIN :: f32(2.5)
// And how much of the reach the scatter still covers at full bias. A rally stage
// wants a wall of trees beside the road, not the same trees spread to the horizon,
// so the far ground is given up and the rows tighten to pay for it.
VEG_REACH_TIGHT :: f32(0.25)
// The same clearance, enforced against *every* leg of the route rather than the
// one a candidate was cast from. A cast knows only its own verge, so on a branched
// route it can put a trunk hard against the kerb of a road it never looked at.
VEG_CLEAR :: f32(2)
// When the terrain is off there is no reach to read; scatter out this far instead.
VEG_REACH_NO_TERRAIN :: f32(60)
// A hard cap so a huge stage at max density cannot emit an unbounded item list.
VEG_MAX :: 20000
// Closest two trees may stand, as a fraction of the row spacing. Each edge of the
// road graph scatters over its own verge, and the edges meeting at a junction
// cover the same ground, so without this a branch grows two or three stands in
// one place.
VEG_GAP :: f32(0.6)

// One placed tree, in world space. `kind`/`pos`/`yaw`/`scale` are what the export
// needs; the rest is the pre-scaled viewport placeholder (veg_draw draws it) so
// the draw loop needs no per-instance lookup. Yaw only — a tree leans nowhere —
// and `scale` is always a real value, never 0.
Veg_Instance :: struct {
	kind:   Prop_Kind,
	pos:    gfx.Vector3, // ground anchor
	yaw:    f32,        // radians about +Y
	scale:  f32,
	shape:  Veg_Shape,
	h:      f32, // metres, already scaled by `scale`
	r:      f32,
	trunk:  f32,
	canopy: gfx.Color,
}

// --- terrain-height probe ----------------------------------------------------

// A throwaway view onto the terrain field so the scatter can ask "how high is the
// ground at this world XZ, and is it even inside the terrain?" without holding the
// whole Terrain_Field. Rebuilt from the ribbon each generate; cheap beside the
// mesh build, and it keeps vegetation from depending on the mesh cache's lifetime.
Veg_Field :: struct {
	ok:         bool, // there is a road to test candidates against
	heights:    bool, // and a terrain field to read ground height from
	t:          ^Terrain,
	fs:         []Field_Sample,
	hash:       Sample_Hash,
	near_other: []bool,
	reach:      f32, // how far out from a verge a tree may stand
	limit:      f32,
}

// Built whenever there is a road, terrain or no terrain. Keeping a tree out of a
// road corridor is a property of the road, and a branched route puts one leg's
// verge within candidate range of another leg's carriageway — so the corridor
// test cannot be something the terrain toggle switches off. Only the ground
// height needs the sculpted field.
veg_field_make :: proc(
	t: ^Terrain,
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	roughness: f32,
) -> Veg_Field {
	if t == nil || len(ribbon) < 2 {
		return {}
	}
	fs := field_samples(ribbon, arc, ds, roughness)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for s in fs {
		lo[0] = min(lo[0], s.p[0]);  lo[1] = min(lo[1], s.p[1])
		hi[0] = max(hi[0], s.p[0]);  hi[1] = max(hi[1], s.p[1])
	}
	hash := hash_build(fs, lo, hi, max(t.cell_m * 2, 8))
	near := terrain_near_other(t, fs, hash)
	reach := t.enabled ? t.reach_m : VEG_REACH_NO_TERRAIN
	return {
		ok = true,
		heights = t.enabled,
		t = t,
		fs = fs,
		hash = hash,
		near_other = near,
		reach = reach,
		limit = reach + 64,
	}
}

// Ground Y at world XZ, and whether that point lies on the terrain at all. Mirrors
// field_y (terrain.odin) but for a point built on the fly rather than a stored
// vertex. `inside` is false in any leg's road corridor and past `reach` — exactly
// where a tree would float or block the road, so the caller drops those
// candidates, and it keeps VEG_CLEAR back from every corridor rather than merely
// outside it. With the terrain off the test still runs; only Y falls back to the
// caller's own.
veg_field_y :: proc(vf: ^Veg_Field, p: [2]f32) -> (y: f32, inside: bool) {
	if !vf.ok {
		return 0, true
	}
	pr := field_probe(vf.hash, vf.fs, vf.near_other, p, vf.limit)
	if !pr.ok || pr.su <= VEG_CLEAR || pr.su > vf.reach {
		return 0, false
	}
	// A pad that clears its own foliage is off the terrain as far as the scatter
	// is concerned, which is the same answer as the road corridor gets. Tested
	// before the height work below, so a rejected candidate costs less, not more.
	if terrain_floor_clears_veg(vf.t, p) {
		return 0, false
	}
	if !vf.heights {
		return 0, true
	}
	legs, n := field_legs(vf.hash, vf.fs, vf.near_other, p, vf.limit)
	y = terrain_world_height(vf.t, p, legs, n)
	// A pad cuts the ground the trees stand on. The ceiling only, never the
	// divot lift: that needs neighbours (floor.odin) and a scatter point has
	// none, and being under the pad by less than a metre is not visible.
	if level, _, ok := terrain_floor_level(vf.t, p, y); ok && level < y {
		y = level
	}
	return y, true
}

// How far out a world point lies, in the same measure `reach` is in: distance
// from the nearest leg's verge seam, so 0 at the seam and negative on the
// carriageway. `ok` is false only when no leg is within range at all, which means
// the point is a long way outside every terrain the road lays.
//
// The billboard generator works in this number directly: where the terrain ends
// is `su > reach`, and that is a property of the *nearest* leg, so it is right on
// a branch and in a hairpin where a fixed offset from one verge is not.
veg_field_su :: proc(vf: ^Veg_Field, p: [2]f32) -> (su: f32, ok: bool) {
	if !vf.ok {
		return 0, false
	}
	pr := field_probe(vf.hash, vf.fs, vf.near_other, p, vf.limit)
	return pr.su, pr.ok
}

// --- the scatter -------------------------------------------------------------

// One continuous edge of the ribbon, as an inclusive index span.
//
// A branched road is sampled edge by edge into one array (build_ribbon), and the
// step from an edge's last sample to the next edge's first is a jump across the
// map, not road. The arc table counts that jump as length, so a row placed by arc
// station anywhere inside it lands on the junction: every one of them, side by
// side, across the road. That is the blob. Rows are laid inside a run instead,
// where every metre of arc is a metre of road.
Ribbon_Run :: struct {
	lo, hi: int,
}

ribbon_runs :: proc(ribbon: []Cross_Section, allocator := context.temp_allocator) -> []Ribbon_Run {
	out := make([dynamic]Ribbon_Run, allocator)
	for cs, i in ribbon {
		if i > 0 && !cs.break_before {
			out[len(out) - 1].hi = i
			continue
		}
		append(&out, Ribbon_Run{i, i})
	}
	return out[:]
}

// Nearest ribbon sample to an arc station, by linear scan inside one run.
// `arc` is monotonic, so the first sample whose arc passes the target brackets it.
veg_sample_at_arc :: proc(arc: []f32, run: Ribbon_Run, target: f32) -> int {
	for i in run.lo + 1 ..= run.hi {
		if arc[i] >= target {
			// Pick whichever of the bracketing pair is closer.
			return target - arc[i - 1] < arc[i] - target ? i - 1 : i
		}
	}
	return run.hi
}

// The ribbon sample every row of the scatter stands on: one row per `spacing`
// metres of road, jittered inside its own cell so the rows do not stripe. Run by
// run, so a row is never spaced across the jump between two edges.
veg_rows :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	spacing: f32,
	rng: ^Rng,
	allocator := context.temp_allocator,
) -> []int {
	out := make([dynamic]int, allocator)
	for run in ribbon_runs(ribbon) {
		if run.hi <= run.lo {
			continue
		}
		lo, hi := arc[run.lo], arc[run.hi]
		for r in 0 ..< max(int((hi - lo) / spacing), 1) {
			s := lo + (f32(r) + 0.5 + rng_range(rng, -0.4, 0.4)) * spacing
			append(&out, veg_sample_at_arc(arc, run, clamp(s, lo, hi)))
		}
	}
	return out[:]
}

// Weighted pick from a pool. `pool` is never empty (veg_pool guarantees it).
veg_pick :: proc(rng: ^Rng, pool: []Veg_Species) -> Veg_Species {
	total: f32
	for s in pool {
		total += s.weight
	}
	r := rng_unit(rng) * total
	for s in pool {
		r -= s.weight
		if r <= 0 {
			return s
		}
	}
	return pool[len(pool) - 1]
}

// A lateral band, measured out from the verge seam: where it starts and how wide
// it is. One tree stands somewhere in each, so the band's width is both the local
// spacing and the room the tree has to jitter in.
Veg_Column :: struct {
	u, step: f32,
}

// Carve the ground from the verge out to `near + width` into `cols` bands. At bias 0
// they are all `step_near` wide and the scatter is the even grid it has always been.
// Drive `step_near` down and the bands grow by a fixed ratio instead, so the near
// ground is planted harder than the ground behind it.
veg_columns :: proc(
	cols: int,
	near, width, step_near: f32,
	allocator := context.temp_allocator,
) -> []Veg_Column {
	out := make([]Veg_Column, cols, allocator)
	r := veg_column_ratio(cols, width, step_near)
	u, step := near, step_near
	for i in 0 ..< cols {
		out[i] = {u, step}
		u += step
		step *= r
	}
	return out
}

// The growth ratio that makes `cols` bands cover exactly `width`, starting at
// `step_near`. What they cover rises with the ratio, so a bisection finds it; 1 when
// bands of an even width already reach far enough.
veg_column_ratio :: proc(cols: int, width, step_near: f32) -> f32 {
	if cols < 2 || step_near * f32(cols) >= width {
		return 1
	}
	covered :: proc(r: f32, cols: int, step_near: f32) -> f32 {
		return step_near * (math.pow(r, f32(cols)) - 1) / (r - 1)
	}
	lo, hi := f32(1.0001), f32(4)
	for _ in 0 ..< 40 {
		mid := (lo + hi) * 0.5
		if covered(mid, cols, step_near) < width {
			lo = mid
		} else {
			hi = mid
		}
	}
	return (lo + hi) * 0.5
}

// Scatter the stage's trees. Persistent-allocates the result (caller frees), or
// returns nil when there is nothing to place. Deterministic in `veg.seed`: the
// same stage and seed scatter identically, run to run.
veg_generate :: proc(
	ribbon: []Cross_Section,
	terrain: ^Terrain,
	veg: Veg_Params,
	roughness: f32,
	allocator := context.allocator,
) -> []Veg_Instance {
	if !veg.enabled || len(ribbon) < 2 {
		return nil
	}

	arc := ribbon_arc(ribbon)
	ds := sample_spacing(ribbon)
	total := arc[len(arc) - 1]
	if total <= 0 {
		return nil
	}

	vf := veg_field_make(terrain, ribbon, arc, ds, roughness)
	reach := vf.ok ? vf.reach : VEG_REACH_NO_TERRAIN

	spacing := VEG_SPACING_SPARSE + (VEG_SPACING_DENSE - VEG_SPACING_SPARSE) * clamp(veg.density, 0, 1)
	spacing = max(spacing, 1)
	bias := clamp(veg.road_bias, 0, 1)
	pool := veg_pool(veg.preset)
	near := VEG_U_NEAR + (VEG_U_NEAR_TIGHT - VEG_U_NEAR) * bias
	span := reach - near
	if span <= 0 {
		return nil // no room outside the verge to plant anything
	}
	// The bias trades width for density. It pulls the scatter's reach in, packs the
	// columns it still has room for against the verge, and tightens the rows by
	// exactly what the lost columns were worth, so the tree count barely moves.
	even_cols := max(int(span / spacing) + 1, 1)
	band := span * (1 + (VEG_REACH_TIGHT - 1) * bias)
	step_near := spacing + (min(VEG_STEP_MIN, spacing) - spacing) * bias
	cols := clamp(int(band / step_near), 1, even_cols)
	columns := veg_columns(cols, near, band, step_near)
	row_spacing := max(spacing * f32(cols) / f32(even_cols), VEG_STEP_MIN)

	rng := rng_init(veg.seed)
	canopy := veg_canopy_col(veg.preset)
	out := make([dynamic]Veg_Instance, allocator)

	// One tree per cell of a coarse world grid, so two edges covering the same
	// ground near a junction plant one stand between them rather than one each.
	// Sized off the narrowest column, not off `spacing`: at high bias the near columns
	// stand a couple of metres apart and a cell sized for the even grid would swallow
	// the whole verge.
	gap := max(step_near * VEG_GAP, 0.5)
	taken := make(map[[2]i32]bool, 0, context.temp_allocator)
	defer delete(taken)

	for i in veg_rows(ribbon, arc, row_spacing, &rng) {
		if len(out) >= VEG_MAX {
			break
		}
		cs := ribbon[i]

		// Flattened travel direction, for the along-road jitter.
		fwd := gfx.Vector3{cs.fwd.x, 0, cs.fwd.z}
		fwd = gfx.Vector3Length(fwd) > 1e-4 ? gfx.Vector3Normalize(fwd) : gfx.Vector3{0, 0, 1}

		for side in 0 ..< 2 {
			seam := verge_seam(cs, side, roughness)
			o := terrain_outward(cs, side)

			for col in columns {
				if len(out) >= VEG_MAX {
					break
				}
				// Anywhere in the column's own band, plus a nudge along the road, so
				// the grid dissolves into a natural scatter. A tree never leaves its
				// band, so however hard the bias packs them none lands on the verge
				// or past the reach.
				ju := col.u + rng_unit(&rng) * col.step
				jf := rng_range(&rng, -0.5, 0.5) * row_spacing

				px := seam.x + o.x * ju + fwd.x * jf
				pz := seam.z + o.z * ju + fwd.z * jf

				y, inside := veg_field_y(&vf, {px, pz})
				if !inside {
					continue
				}
				if !vf.heights {
					y = seam.y // no terrain: ride the verge-seam height
				}

				cell := [2]i32{i32(math.floor(px / gap)), i32(math.floor(pz / gap))}
				if cell in taken {
					continue
				}
				taken[cell] = true

				sp := veg_pick(&rng, pool)
				sc := rng_range(&rng, sp.scale_min, sp.scale_max)
				append(
					&out,
					Veg_Instance {
						kind = sp.kind,
						pos = {px, y, pz},
						yaw = rng_range(&rng, 0, 2 * math.PI),
						scale = sc,
						shape = sp.shape,
						h = sp.h * sc,
						r = sp.r * sc,
						trunk = sp.trunk * sc,
						canopy = canopy,
					},
				)
			}
		}
	}

	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// --- viewport preview --------------------------------------------------------

VEG_TRUNK_COL :: gfx.Color{92, 66, 44, 210} // a muted bark brown, mostly opaque

// Build the cached scatter into a triangle soup, to be uploaded once per rebuild
// and drawn like the road and the ground.
//
// Not the immediate-mode overlay it used to be. That batch is a fixed buffer
// shared with every handle and node in the frame, and one tree costs upward of a
// hundred vertices, so a dense stage filled it: the trees at the tail of the
// ribbon — whole branches of the road graph — drew nothing, and so did the
// handles queued behind them. A mesh has no such ceiling and is not rebuilt every
// frame.
//
// Viewport only. The export places real props (see Prop_Kind), so the Mat_Id here
// is never read by a target. Low slice counts keep the soup small, and the shapes
// are symmetric about +Y, so yaw is not applied.
veg_build_mesh :: proc(insts: []Veg_Instance, allocator := context.allocator) -> Tri_Mesh {
	m := tri_mesh_make(allocator)
	sink := gfx.Tri_Sink{emit = veg_emit_tri, user = &m}
	for it in insts {
		base := it.pos
		top := base + {0, it.trunk, 0} // where the canopy sits

		// A slim trunk, for the "little trunk base" / lifted-canopy read.
		if it.trunk > 0.05 {
			tr := max(it.r * 0.12, 0.12)
			gfx.CylinderEx(sink, base, top, tr, tr, 6, VEG_TRUNK_COL)
		}

		switch it.shape {
		case .Conifer:
			// A tapering cone: wide base at the trunk top, point at the crown.
			apex := top + {0, it.h, 0}
			gfx.CylinderEx(sink, top, apex, it.r, 0, 8, it.canopy)
		case .Broadleaf:
			// A round canopy resting on the trunk.
			c := top + {0, it.r, 0}
			gfx.SphereEx(sink, c, it.r, 6, 8, it.canopy)
		case .Bush:
			// A low ground sphere, squashed so it reads as a shrub, not a ball.
			c := base + {0, it.r * 0.6, 0}
			gfx.SphereEx(sink, c, it.r, 5, 7, it.canopy)
		}
	}
	return m
}

veg_emit_tri :: proc(user: rawptr, a, b, c: gfx.Vector3, col: gfx.Color) {
	add_tri((^Tri_Mesh)(user), a, b, c, {}, {}, {}, col, .Terrain)
}
