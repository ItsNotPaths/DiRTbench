package main

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../gfx"
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
	seeds := [?]struct{pos: gfx.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 200}, 0},
		{{0, 30, 400}, 1}, // main road, climbing to a dead end
		{{200, 0, 200}, 1}, // branch, level, leaving the junction sideways
	}
	for s in seeds {
		rot := gfx.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		geo.spline_push(&sp, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
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
		&field, &terrain, ribbon, arc, geo.sample_spacing(ribbon), 0, 1,
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
	seeds := [?]struct{pos: gfx.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},
		{{0, 12, 160}, 1},  // main road climbs to a dead end
		{{80, 0, 80}, 1},   // branch leaves the junction
		{{140, 8, 130}, 3}, // and climbs to its own dead end
	}
	for s in seeds {
		rot := gfx.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		geo.spline_push(&sp, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
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
	geo.terrain_field_ensure(&field, &terrain, ribbon, arc, ds, 0, 1)

	vf := geo.veg_field_make(&terrain, ribbon, arc, ds, 0)
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

// A road that forks and doubles back alongside itself: the shape a bug that only
// shows up between two legs needs.
@(private = "file")
branched_road :: proc() -> (sp: geo.Spline) {
	seeds := [?]struct{pos: gfx.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},
		{{0, 0, 160}, 1},
		{{40, 0, 120}, 1}, // a branch that runs back alongside the main road
		{{40, 0, 40}, 3},
	}
	for s in seeds {
		rot := gfx.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		geo.spline_push(&sp, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}
	return
}

// A straight road of the same width: the control. It cannot overlap itself, so
// whatever it scatters is what an honest density looks like.
@(private = "file")
straight_road :: proc() -> (sp: geo.Spline) {
	for z in ([]f32{0, 80, 160, 240, 320}) {
		geo.spline_push(
			&sp,
			geo.make_point({0, 0, z}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = len(sp.points) - 1),
		)
	}
	return
}

// Trees per 8 m square of ground, at the busiest square.
@(private = "file")
thickest_patch :: proc(trees: []geo.Veg_Instance) -> (worst: int) {
	cells := make(map[[2]i32]int, 0, context.temp_allocator)
	defer delete(cells)
	for it in trees {
		cell := [2]i32{i32(math.floor(it.pos.x / 8)), i32(math.floor(it.pos.z / 8))}
		cells[cell] += 1
		worst = max(worst, cells[cell])
	}
	return
}

// Rows are spaced in metres of road, and on a branched route the ribbon is a set
// of disjoint edges in one array: the step from one edge's last sample to the
// next edge's first is a jump across the map, not road. Spacing rows along the
// arc table walks straight through that jump and lands every row of it on the
// junction — a slab of trees across the road, which is the bug this holds shut.
@(test)
vegetation_rows_stay_on_the_road :: proc(t: ^testing.T) {
	sp := branched_road()
	defer delete(sp.points)
	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)

	// Coarser than the tessellation (~5.7 m here), so two rows may share a sample
	// and no honest spacing can put a third on it.
	SPACING :: f32(10)
	rng := geo.rng_init(7)
	rows := geo.veg_rows(ribbon, arc, SPACING, &rng, context.allocator)
	defer delete(rows)

	per_sample := make(map[int]int, 0, context.temp_allocator)
	defer delete(per_sample)
	worst, worst_at := 0, 0
	for i in rows {
		per_sample[i] += 1
		if per_sample[i] > worst {
			worst, worst_at = per_sample[i], i
		}
	}
	testing.expectf(t, worst <= 2,
		"%d of %d rows stand on ribbon sample %d — they were spaced across an edge jump",
		worst, len(rows), worst_at)
}

// And the scatter that comes out of those rows, against the straight control. The
// legs meeting at a junction cover the same ground, so a branch is where two
// stands can end up planted in one place.
@(test)
vegetation_does_not_thicken_at_a_branch :: proc(t: ^testing.T) {
	veg := geo.Veg_Params{enabled = true, density = 1, seed = 7}
	patch :: proc(sp: geo.Spline, veg: geo.Veg_Params) -> int {
		ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
		defer delete(ribbon)
		terrain := geo.TERRAIN_DEFAULTS
		defer geo.terrain_delete(&terrain)
		trees := geo.veg_generate(ribbon, &terrain, veg, 0)
		defer delete(trees)
		return thickest_patch(trees)
	}

	forked, plain := branched_road(), straight_road()
	defer delete(forked.points)
	defer delete(plain.points)

	branch_worst, straight_worst := patch(forked, veg), patch(plain, veg)
	testing.expectf(t, branch_worst <= straight_worst + 2,
		"a branch packs %d trees into 8 m of ground where a straight road packs %d",
		branch_worst, straight_worst)
}

// Trees keep off every leg of the route, sculpted terrain or not. A candidate is
// cast outward from one leg's verge, which on a branched route aims it straight at
// the carriageway of another — so the road corridor has to reject it whether or
// not the terrain is switched on.
@(test)
vegetation_keeps_off_every_branch :: proc(t: ^testing.T) {
	sp := branched_road()
	defer delete(sp.points)

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

		trees := geo.veg_generate(ribbon, &terrain, veg, 0)
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
	seeds := [?]struct{pos: gfx.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},  // the junction
		{{0, 0, 160}, 1}, // straight on
		{{80, 0, 80}, 1}, // and off to the side
	}
	for s in seeds {
		rot := gfx.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		geo.spline_push(&sp, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)

	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	ds := geo.sample_spacing(ribbon)

	fs := geo.field_samples(ribbon, arc, ds, 0)
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

// --- sculpt persistence -------------------------------------------------------

// A seeded road with its terrain controls derived, which is the state a sculpt
// starts from. The caller frees the returned ribbon.
@(private = "file")
build_sculpted_terrain :: proc(doc: ^Venue_Doc, field: ^geo.Terrain_Field) -> []geo.Cross_Section {
	ribbon := geo.build_ribbon(doc.spline, 8, context.allocator)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	geo.terrain_field_ensure(
		field, &doc.terrain, ribbon, arc, geo.sample_spacing(ribbon), 0, 1,
	)
	return ribbon
}

// A document with terrain on and its controls derived from a seeded road.
@(private = "file")
sculpt_doc :: proc(field: ^geo.Terrain_Field) -> (doc: Venue_Doc, ribbon: []geo.Cross_Section) {
	doc = doc_defaults()
	doc.terrain.enabled = true
	seed_spline(&doc.spline)
	return doc, build_sculpted_terrain(&doc, field)
}

// The sculpt is a set of world offsets, not a list of node indices, so the road
// document has to round-trip it through a whole regeneration of the control set.
@(test)
road_file_round_trips_the_terrain_sculpt :: proc(t: ^testing.T) {
	field: geo.Terrain_Field
	defer geo.terrain_field_delete(&field)
	doc, ribbon := sculpt_doc(&field)
	defer doc_delete(&doc)
	defer delete(ribbon)
	terrain := &doc.terrain

	n := geo.terrain_node_count(terrain)
	testing.expect(t, n > 4, "the seed road produced no terrain controls"); if n <= 4 { return }
	moved := n / 2
	geo.terrain_set_node(terrain, moved, terrain.controls[moved].base_y + 7)
	at := [2]f32{terrain.controls[moved].x, terrain.controls[moved].z}
	testing.expect_value(t, terrain.controls[moved].offset, f32(7))

	path := "/tmp/claude-1000/dirtbench-terrain-roundtrip.json"
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg); if !ok { return }
	defer os.remove(path)

	back_doc := doc_defaults()
	defer doc_delete(&back_doc)
	load_msg, loaded := load_road(&back_doc, path)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	back := &back_doc.terrain
	testing.expect(t, back.enabled, "terrain came back disabled")
	testing.expect_value(t, back.reach_m, terrain.reach_m)
	testing.expect_value(t, back.row_m, terrain.row_m)

	// Regenerating is the real test: the loaded controls are only match sources,
	// and the live set is derived from the ribbon again on this call.
	back_field: geo.Terrain_Field
	defer geo.terrain_field_delete(&back_field)
	back_ribbon := build_sculpted_terrain(&back_doc, &back_field)
	defer delete(back_ribbon)

	testing.expect_value(t, geo.terrain_node_count(back), n)
	for c, i in back.controls {
		want := terrain.controls[i].offset
		testing.expectf(t, c.offset == want,
			"control %d at (%.1f, %.1f) came back at %.2f, not %.2f", i, c.x, c.z, c.offset, want)
	}
	testing.expect_value(t, geo.terrain_control_offset(back, at), f32(7))
}

// An untouched terrain writes no controls at all, so an unsculpted venue does
// not carry thousands of zeroes.
@(test)
unsculpted_terrain_writes_no_controls :: proc(t: ^testing.T) {
	field: geo.Terrain_Field
	defer geo.terrain_field_delete(&field)
	doc, ribbon := sculpt_doc(&field)
	defer doc_delete(&doc)
	defer delete(ribbon)
	testing.expect(t, geo.terrain_node_count(&doc.terrain) > 0, "no controls to begin with")
	testing.expect_value(t, len(geo.terrain_sculpt(&doc.terrain)), 0)

	// The sliders still have to come back, or turning terrain on and saving
	// without sculpting would reset reach and cell on the next load.
	path := "/tmp/claude-1000/dirtbench-terrain-unsculpted.json"
	doc.terrain.reach_m, doc.terrain.cell_m = 140, 12
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg); if !ok { return }
	defer os.remove(path)

	back := doc_defaults()
	defer doc_delete(&back)
	load_msg, loaded := load_road(&back, path)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	testing.expect(t, back.terrain.enabled, "terrain came back disabled")
	testing.expect_value(t, back.terrain.reach_m, f32(140))
	testing.expect_value(t, back.terrain.cell_m, f32(12))
	testing.expect_value(t, geo.terrain_node_count(&back.terrain), 0)
}

// A road written before v8 has no terrain block. It must load with the ground
// off and the sliders at their defaults, not at whatever the caller held.
@(test)
pre_v8_road_loads_with_terrain_off :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)

	path := "/tmp/claude-1000/dirtbench-terrain-v7.json"
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg); if !ok { return }
	defer os.remove(path)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil, "could not read back the file"); if rerr != nil { return }
	aged, _ := strings.replace(string(data), `"version": 8`, `"version": 7`, 1, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)aged) == nil, "could not age the file")

	// A document already carrying a sculpt: the v7 load must clear it, not
	// leave the previous venue's ground behind.
	stale := doc_defaults()
	defer doc_delete(&stale)
	stale.terrain.enabled = true
	stale.terrain.reach_m = 123
	append(&stale.terrain.controls, geo.Terrain_Control{x = 1, z = 2, offset = 5})

	load_msg, loaded := load_road(&stale, path)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	testing.expect(t, !stale.terrain.enabled, "a v7 road turned terrain on")
	testing.expect_value(t, stale.terrain.reach_m, geo.TERRAIN_DEFAULTS.reach_m)
	testing.expect_value(t, geo.terrain_node_count(&stale.terrain), 0)
}
