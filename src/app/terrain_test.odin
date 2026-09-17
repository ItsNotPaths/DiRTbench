package main

import "core:math"
import "core:testing"
import rl "../gfx"
import "../geo"

@(test)
terrain_world_control_is_exact_at_its_handle :: proc(t: ^testing.T) {
	terrain := geo.Terrain{}
	append(&terrain.controls, geo.Terrain_Control{x = 10, z = 20, offset = 3, radius = 10})
	defer geo.terrain_delete(&terrain)
	testing.expect_value(t, geo.terrain_control_offset(&terrain, {10, 20}), f32(3))
	testing.expect_value(t, geo.terrain_control_offset(&terrain, {21, 20}), f32(0))
}

// A branched road is sampled as one run per graph edge, laid end to end in one
// ribbon. Every field query that walks the ribbon must stay inside its own run:
// the sample after the last one of an edge belongs to a different edge somewhere
// else on the map. This builds a T — a main road that climbs to a dead end, and a
// level branch leaving it halfway — and checks the ground around both.
@(test)
branched_road_terrain_stays_within_its_own_edge :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seeds := [?]struct{pos: rl.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 200}, 0},
		{{0, 30, 400}, 1}, // main road, climbing to a dead end
		{{200, 0, 200}, 1}, // branch, level, leaving the junction sideways
	}
	for s in seeds {
		rot := rl.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		append(&sp.points, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}
	testing.expect(t, !geo.is_linear(sp), "the T should not be classified as linear")

	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)
	field: geo.Terrain_Field
	defer geo.terrain_field_delete(&field)

	ribbon := geo.build_ribbon(sp, 8, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	geo.terrain_field_ensure(
		&field, &terrain, ribbon, arc, geo.sample_spacing(ribbon), 8, 0, 1,
	)
	testing.expect(t, len(field.tris) > 0, "a branched road produced no terrain at all")

	beside_branch, around_the_end, past_reach, low_at_the_end, near_the_end := 0, 0, 0, 0, 0
	for p in field.pts {
		if p.x > 120 && abs(p.z - 200) < 40 {
			beside_branch += 1
		}
		// The main road stops at z = 400, and the ground wraps around that end
		// rather than being cut off at it. `reach` bounds the wrap, so the far
		// corner past it — where a corridor measured across the road would still
		// have read as inside — has to be empty.
		if p.z > 400 {
			if geo.dist2({p.x, p.z}, {0, 400}) > 112 * 112 {
				past_reach += 1
			} else if p.z > 410 && abs(p.x) < 40 {
				around_the_end += 1
			}
		}
		if p.fixed || p.z < 380 || p.z > 400 || abs(p.x) < 8 || abs(p.x) > 40 {
			continue
		}
		near_the_end += 1
		// The road is 30 m up by here. Reading the next edge's seam instead of
		// this one's drops it to the level of the junction.
		if geo.field_y(&terrain, p) < 15 {
			low_at_the_end += 1
		}
	}
	testing.expect(t, beside_branch > 0, "the branch got no ground beside it")
	testing.expect(t, around_the_end > 0, "no ground wrapped around the dead end")
	testing.expect_value(t, past_reach, 0)
	testing.expect(t, near_the_end > 0, "no sample points near the dead end to check")
	testing.expect_value(t, low_at_the_end, 0)
}

// Nothing belongs on a road: no tree planted in it, no ground laid over it. The
// corridor is the union of every leg, so a junction — where one edge's samples
// stop and the next edge's begin on top of them — must be no more plantable than
// the middle of a straight.
@(test)
nothing_lands_on_a_branched_road :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	// Segment lengths and sampling as the editor uses them: the rim must come out
	// denser than the corridor is wide, or Delaunay bridges the road instead of
	// running its edges along the rim, and no centroid test can tell the two apart.
	seeds := [?]struct{pos: rl.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},
		{{0, 12, 160}, 1},  // main road climbs to a dead end
		{{80, 0, 80}, 1},   // branch leaves the junction
		{{140, 8, 130}, 3}, // and climbs to its own dead end
	}
	for s in seeds {
		rot := rl.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		append(&sp.points, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}

	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)
	field: geo.Terrain_Field
	defer geo.terrain_field_delete(&field)

	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	ds := geo.sample_spacing(ribbon)
	geo.terrain_field_ensure(&field, &terrain, ribbon, arc, ds, geo.SAMPLES_PER_SEG, 0, 1)

	vf := geo.veg_field_make(&terrain, ribbon, arc, ds, geo.SAMPLES_PER_SEG, 0)
	testing.expect(t, vf.ok, "no vegetation field to test against")

	// True when q sits inside a terrain triangle, in plan. Strictly inside: at a
	// dead end the ground closes right up against the road's end line, so the last
	// station on the centreline lies exactly on a triangle's edge. Sharing that
	// boundary is the point; overlapping the road is what must not happen.
	covered :: proc(f: ^geo.Terrain_Field, q: [2]f32) -> bool {
		EPS :: f32(1e-3)
		for tri in f.tris {
			a, b, c := f.pts[tri[0]], f.pts[tri[1]], f.pts[tri[2]]
			d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
			if abs(d) < 1e-6 {
				continue
			}
			u := ((b.z - c.z) * (q[0] - c.x) + (c.x - b.x) * (q[1] - c.z)) / d
			v := ((c.z - a.z) * (q[0] - c.x) + (a.x - c.x) * (q[1] - c.z)) / d
			if u > EPS && v > EPS && u + v < 1 - EPS {
				return true
			}
		}
		return false
	}

	plantable, buried := 0, 0
	for cs in ribbon {
		q := [2]f32{cs.pos.x, cs.pos.z}
		if _, inside := geo.veg_field_y(&vf, q); inside {
			plantable += 1
		}
		if covered(&field, q) {
			buried += 1
		}
	}
	testing.expect_value(t, plantable, 0)
	testing.expect_value(t, buried, 0)
}

// Trees keep off every leg of the route, sculpted terrain or not. A candidate is
// cast outward from one leg's verge, which on a branched route aims it straight at
// the carriageway of another — so the road corridor has to reject it whether or
// not the terrain is switched on.
@(test)
vegetation_keeps_off_every_branch :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seeds := [?]struct{pos: rl.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},
		{{0, 0, 160}, 1},
		{{40, 0, 120}, 1}, // a branch that runs back alongside the main road
		{{40, 0, 40}, 3},
	}
	for s in seeds {
		rot := rl.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		append(&sp.points, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}

	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)

	// Distance from q across the carriageway, in plan: the perpendicular distance
	// to the nearest segment q actually lies abreast of. Segments only, never
	// across a break — two consecutive samples on different edges are not a piece
	// of road — and abreast only, so the ground past the end of a road counts as
	// ground rather than as a disc of road around its last node.
	to_route :: proc(ribbon: []geo.Cross_Section, q: [2]f32) -> f32 {
		best := max(f32)
		for i in 0 ..< len(ribbon) - 1 {
			if ribbon[i + 1].break_before {
				continue
			}
			a := [2]f32{ribbon[i].pos.x, ribbon[i].pos.z}
			b := [2]f32{ribbon[i + 1].pos.x, ribbon[i + 1].pos.z}
			ab := [2]f32{b[0] - a[0], b[1] - a[1]}
			len2 := ab[0] * ab[0] + ab[1] * ab[1]
			if len2 <= 1e-6 {
				continue
			}
			tt := ((q[0] - a[0]) * ab[0] + (q[1] - a[1]) * ab[1]) / len2
			if tt < 0 || tt > 1 {
				continue
			}
			best = min(best, geo.dist2(q, {a[0] + ab[0] * tt, a[1] + ab[1] * tt}))
		}
		return math.sqrt(best)
	}

	veg := geo.Veg_Params{enabled = true, density = 1, seed = 7}
	// Both ways round: the corridor test must not be something the terrain owns.
	for terrain_on in ([]bool{false, true}) {
		terrain := geo.TERRAIN_DEFAULTS
		terrain.enabled = terrain_on
		defer geo.terrain_delete(&terrain)

		trees := geo.veg_generate(ribbon, &terrain, veg, geo.SAMPLES_PER_SEG, 0)
		defer delete(trees)
		testing.expect(t, len(trees) > 0, "nothing was planted at all")

		// Off the carriageway and VEG_CLEAR back from its verge, whichever leg it
		// belongs to. No cliffs here, so the verge seam is the road's own edge.
		keep_out := geo.DEFAULT_WIDTH * 0.5 + geo.VEG_CLEAR - 0.05
		too_close, closest := 0, max(f32)
		for it in trees {
			d := to_route(ribbon, {it.pos.x, it.pos.z})
			closest = min(closest, d)
			if d < keep_out {
				too_close += 1
			}
		}
		testing.expectf(t, too_close == 0,
			"terrain %v: %d of %d trees crowd the route, nearest %.2f m from its centre",
			terrain_on, too_close, len(trees), closest)
	}
}

// The road corridor is the union of every leg. At a junction one edge's samples
// stop where the next edge's begin, and the nearest of them may well be the one
// that stopped — which on its own reports the road as ending there, opening a gap
// in its own corridor a few metres long at every node of a branched route.
@(test)
a_junction_is_still_inside_the_road :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seeds := [?]struct{pos: rl.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},  // the junction
		{{0, 0, 160}, 1}, // straight on
		{{80, 0, 80}, 1}, // and off to the side
	}
	for s in seeds {
		rot := rl.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		append(&sp.points, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)

	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	ds := geo.sample_spacing(ribbon)

	fs := geo.field_samples(ribbon, arc, ds, geo.SAMPLES_PER_SEG, 0)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for s in fs {
		lo[0] = min(lo[0], s.p[0]);  lo[1] = min(lo[1], s.p[1])
		hi[0] = max(hi[0], s.p[0]);  hi[1] = max(hi[1], s.p[1])
	}
	hash := geo.hash_build(fs, lo, hi, max(terrain.cell_m * 2, 8))
	near := geo.terrain_near_other(&terrain, fs, hash)

	// Walking the carriageway across the junction, a metre at a time.
	for dz in ([]f32{-2, -1, -0.5, 0, 0.5, 1, 2}) {
		pr := geo.field_probe(hash, fs, near, {0, 80 + dz}, terrain.reach_m + 64)
		testing.expectf(t, pr.ok && pr.su < 0,
			"%.1f m past the junction reads as %.2f m outside the road", dz, pr.su)
	}
}
