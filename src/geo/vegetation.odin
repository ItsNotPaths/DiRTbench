package geo

// Vegetation: a primitive scatter of trees over the terrain either side of the
// road. It lives in the stage document (see stage.odin) and is handed to the
// export target as a list of `Prop_Kind` placements; each target resolves those
// onto its own game's props, so nothing here knows about any one game.
//
// The distribution is deliberately simple: a jittered grid in (arc, lateral)
// space, one candidate per cell, seeded so a given stage scatters the same way
// every time. Density sets the grid spacing; `road_bias` thins the far edge only
// slightly, so the verge reads a touch busier than the tree line without the road
// ending up in a tunnel of trunks.
//
// Ground height comes from the same terrain field the mesh is built from
// (terrain.odin), so a tree sits on the sculpted surface, not on a flat plane. If
// the terrain is off there is no field to probe: the scatter falls back to the
// verge-seam height and rides the road edge.

import "core:c"
import "core:math"
import rl "../gfx"

// The stock species families offered as presets. The enum value is stable — it is
// persisted in the stage file — so only ever append.
Veg_Preset :: enum i32 {
	Firs  = 0, // conifers, the default rally backdrop
	Oaks,      // leafy broadleaf
	Snowy,     // frosted firs and bare trees, for a winter stage
}

VEG_PRESET_NAMES := [Veg_Preset]cstring {
	.Firs  = "Firs",
	.Oaks  = "Oaks",
	.Snowy = "Snowy",
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
veg_canopy_col :: proc(p: Veg_Preset) -> rl.Color {
	switch p {
	case .Firs:  return {46, 104, 58, 150}
	case .Oaks:  return {84, 148, 66, 150}
	case .Snowy: return {188, 208, 198, 160}
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
	switch p {
	case .Firs:  return firs
	case .Oaks:  return oaks
	case .Snowy: return snowy
	}
	return firs
}

// The knobs, persisted per stage. `road_bias` is intentionally gentle by default:
// the brief is "prioritise near the road, only slightly".
Veg_Params :: struct {
	enabled:   bool,
	preset:    Veg_Preset,
	density:   f32,   // 0..1; drives the grid spacing
	road_bias: f32,   // 0..1; fraction of far-edge candidates thinned out
	seed:      c.int,
}

VEG_DEFAULTS :: Veg_Params {
	enabled   = false,
	preset    = .Firs,
	density   = 0.5,
	road_bias = 0.25,
	seed      = 1,
}

// Grid spacing (metres) at density 0 and density 1. The scatter walks from sparse
// to dense across the slider.
VEG_SPACING_SPARSE :: f32(34)
VEG_SPACING_DENSE :: f32(7)
// How far off the verge seam the nearest tree may stand, so trunks never crowd the
// road edge or clip the verge geometry.
VEG_U_NEAR :: f32(4)
// When the terrain is off there is no reach to read; scatter out this far instead.
VEG_REACH_NO_TERRAIN :: f32(60)
// A hard cap so a huge stage at max density cannot emit an unbounded item list.
VEG_MAX :: 20000

// One placed tree, in world space. `kind`/`pos`/`yaw`/`scale` are what the export
// needs; the rest is the pre-scaled viewport placeholder (veg_draw draws it) so
// the draw loop needs no per-instance lookup. Yaw only — a tree leans nowhere —
// and `scale` is always a real value, never 0.
Veg_Instance :: struct {
	kind:   Prop_Kind,
	pos:    rl.Vector3, // ground anchor
	yaw:    f32,        // radians about +Y
	scale:  f32,
	shape:  Veg_Shape,
	h:      f32, // metres, already scaled by `scale`
	r:      f32,
	trunk:  f32,
	canopy: rl.Color,
}

// --- terrain-height probe ----------------------------------------------------

// A throwaway view onto the terrain field so the scatter can ask "how high is the
// ground at this world XZ, and is it even inside the terrain?" without holding the
// whole Terrain_Field. Rebuilt from the ribbon each generate; cheap beside the
// mesh build, and it keeps vegetation from depending on the mesh cache's lifetime.
Veg_Field :: struct {
	ok:         bool,
	t:          ^Terrain,
	fs:         []Field_Sample,
	hash:       Sample_Hash,
	near_other: []bool,
	limit:      f32,
}

veg_field_make :: proc(
	t: ^Terrain,
	ribbon: []Cross_Section,
	arc: []f32,
	ds: []f32,
	topo: c.int,
	roughness: f32,
) -> Veg_Field {
	if t == nil || !t.enabled || len(ribbon) < 2 {
		return {}
	}
	fs := field_samples(ribbon, arc, ds, topo, roughness)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for s in fs {
		lo[0] = min(lo[0], s.p[0]);  lo[1] = min(lo[1], s.p[1])
		hi[0] = max(hi[0], s.p[0]);  hi[1] = max(hi[1], s.p[1])
	}
	hash := hash_build(fs, lo, hi, max(t.cell_m * 2, 8))
	near := terrain_near_other(t, fs, hash)
	return {ok = true, t = t, fs = fs, hash = hash, near_other = near, limit = t.reach_m + 64}
}

// Ground Y at world XZ, and whether that point lies on the terrain at all. Mirrors
// field_y (terrain.odin) but for a point built on the fly rather than a stored
// vertex. `inside` is false in the road corridor, past `reach`, or off the ends —
// exactly where a tree would float, so the caller drops those candidates. With no
// field (terrain off) it reports inside=true and leaves Y to the caller's fallback.
veg_field_y :: proc(vf: ^Veg_Field, p: [2]f32) -> (y: f32, inside: bool) {
	if !vf.ok {
		return 0, true
	}
	pr := field_probe(vf.hash, vf.fs, p, vf.limit)
	if !pr.ok || pr.beyond || pr.su <= 0 || pr.su > vf.t.reach_m {
		return 0, false
	}
	legs, n := field_legs(vf.hash, vf.fs, vf.near_other, p, vf.limit)
	for k in 0 ..< n {
		l := legs[k]
		y += l.w * terrain_height(vf.t, l.side, l.s_frac, l.u, l.seam_y)
	}
	return y, true
}

// --- the scatter -------------------------------------------------------------

// Nearest ribbon sample to an arc station, by linear scan of the cumulative arc.
// `arc` is monotonic, so the first sample whose arc passes the target brackets it.
veg_sample_at_arc :: proc(arc: []f32, target: f32) -> int {
	for i in 1 ..< len(arc) {
		if arc[i] >= target {
			// Pick whichever of the bracketing pair is closer.
			return target - arc[i - 1] < arc[i] - target ? i - 1 : i
		}
	}
	return len(arc) - 1
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

// Scatter the stage's trees. Persistent-allocates the result (caller frees), or
// returns nil when there is nothing to place. Deterministic in `veg.seed`: the
// same stage and seed scatter identically, run to run.
veg_generate :: proc(
	ribbon: []Cross_Section,
	terrain: ^Terrain,
	veg: Veg_Params,
	topo: c.int,
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

	vf := veg_field_make(terrain, ribbon, arc, ds, topo, roughness)
	reach := vf.ok ? terrain.reach_m : VEG_REACH_NO_TERRAIN
	if reach <= VEG_U_NEAR {
		return nil // no room outside the verge to plant anything
	}

	spacing := VEG_SPACING_SPARSE + (VEG_SPACING_DENSE - VEG_SPACING_SPARSE) * clamp(veg.density, 0, 1)
	spacing = max(spacing, 1)
	bias := clamp(veg.road_bias, 0, 1)
	vrows := verge_rows(topo)
	pool := veg_pool(veg.preset)
	span := reach - VEG_U_NEAR

	rng := rng_init(veg.seed)
	canopy := veg_canopy_col(veg.preset)
	out := make([dynamic]Veg_Instance, allocator)

	rows := max(int(total / spacing), 1)
	for r in 0 ..< rows {
		if len(out) >= VEG_MAX {
			break
		}
		// Centre of the row's arc cell, jittered within it so rows do not stripe.
		s := (f32(r) + 0.5 + rng_range(&rng, -0.4, 0.4)) * spacing
		i := veg_sample_at_arc(arc, clamp(s, 0, total))
		cs := ribbon[i]

		// Flattened travel direction, for the along-road jitter.
		fwd := rl.Vector3{cs.fwd.x, 0, cs.fwd.z}
		fwd = rl.Vector3Length(fwd) > 1e-4 ? rl.Vector3Normalize(fwd) : rl.Vector3{0, 0, 1}

		for side in 0 ..< 2 {
			seam := verge_seam(cs, side, vrows, i, roughness, ds[i])
			o := terrain_outward(cs, side)

			for u := VEG_U_NEAR; u <= reach; u += spacing {
				if len(out) >= VEG_MAX {
					break
				}
				// Jitter the cell: lateral within +/- half a spacing, and a nudge
				// along the road, so the grid dissolves into a natural scatter.
				ju := u + rng_range(&rng, -0.5, 0.5) * spacing
				if ju < VEG_U_NEAR || ju > reach {
					continue
				}
				jf := rng_range(&rng, -0.5, 0.5) * spacing

				px := seam.x + o.x * ju + fwd.x * jf
				pz := seam.z + o.z * ju + fwd.z * jf

				// Prioritise the road, only slightly: keep every near-road candidate,
				// thin the far edge by at most `road_bias`.
				frac := (ju - VEG_U_NEAR) / span
				keep_p := 1 - bias * clamp(frac, 0, 1)
				if rng_unit(&rng) > keep_p {
					continue
				}

				y, inside := veg_field_y(&vf, {px, pz})
				if !inside {
					continue
				}
				if !vf.ok {
					y = seam.y // no terrain: ride the verge-seam height
				}

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

VEG_TRUNK_COL :: rl.Color{92, 66, 44, 210} // a muted bark brown, mostly opaque

// Draw the cached scatter as translucent placeholder shapes. Call inside a 3D
// pass, after the opaque road/terrain, so the canopies blend over the ground
// rather than punching through it. Low slice counts keep a few thousand trees
// cheap; the shapes are symmetric about +Y, so yaw is not applied.
veg_draw :: proc(insts: []Veg_Instance) {
	for it in insts {
		base := it.pos
		top := base + {0, it.trunk, 0} // where the canopy sits

		// A slim trunk, for the "little trunk base" / lifted-canopy read.
		if it.trunk > 0.05 {
			tr := max(it.r * 0.12, 0.12)
			rl.DrawCylinderEx(base, top, tr, tr, 6, VEG_TRUNK_COL)
		}

		switch it.shape {
		case .Conifer:
			// A tapering cone: wide base at the trunk top, point at the crown.
			apex := top + {0, it.h, 0}
			rl.DrawCylinderEx(top, apex, it.r, 0, 8, it.canopy)
		case .Broadleaf:
			// A round canopy resting on the trunk.
			c := top + {0, it.r, 0}
			rl.DrawSphereEx(c, it.r, 6, 8, it.canopy)
		case .Bush:
			// A low ground sphere, squashed so it reads as a shrub, not a ball.
			c := base + {0, it.r * 0.6, 0}
			rl.DrawSphereEx(c, it.r, 5, 7, it.canopy)
		}
	}
}
