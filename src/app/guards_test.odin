package main

// Side guards: cliffs, snow banks and gutters.
//
// The property under test is not any one shape. It is that a guard is **one
// object** covering a run of road: every control point it reaches offers the
// same slider set, and moving that set moves the whole run. Per-point cliffs
// could not do that — shaping a run meant finding and matching five copies.

import "core:testing"
import "../geo"
import "../gfx"

@(private = "file")
straight_road :: proc(sp: ^geo.Spline, count: int, spacing: f32) {
	clear(&sp.points)
	clear(&sp.guards)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * spacing}
		geo.spline_push(sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
}

// The resolved size of one guard kind on one side, at whichever sample stands
// nearest `at`.
@(private = "file")
size_near :: proc(
	ribbon: []geo.Cross_Section, at: gfx.Vector3, side: int, kind: geo.Guard_Kind,
) -> f32 {
	best, size := max(f32), f32(0)
	for cs in ribbon {
		if d := gfx.Vector3Distance(cs.pos, at); d < best {
			best, size = d, cs.verge[side][kind].size
		}
	}
	return size
}

// The headline. Six nodes, one cliff, and the same slider set at every one of
// them — which is the whole reason guards stopped being per-point.
@(test)
one_guard_serves_every_point_it_runs_past :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 6, 20) // z = 0, 20, 40, 60, 80, 100

	g := geo.guard_make(.Cliff, 1, 2) // anchored at z = 40
	g.size, g.taper, g.span = 5, 0, 120 // 60 m either way: z = -20 .. 100
	gi := geo.guard_add(&sp, g)

	// Every node inside the run offers it, and the node at the far end does not:
	// node 5 stands exactly 60 m off, which is where the run stops.
	for node in 0 ..< 5 {
		testing.expectf(
			t, geo.guard_reaches(sp, sp.guards[gi], node),
			"node %d is inside the run and must offer the guard", node,
		)
	}
	testing.expect(t, !geo.guard_reaches(sp, sp.guards[gi], 5), "the run must stop where its span does")

	// And one slider moves all of them at once.
	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	for z in ([]f32{0, 20, 40, 60, 80}) {
		testing.expect_value(t, size_near(ribbon, {0, 0, z}, 1, .Cliff), 5)
	}
	sp.guards[gi].size = 2
	lowered := geo.build_ribbon(sp, 14, context.temp_allocator)
	for z in ([]f32{0, 20, 40, 60, 80}) {
		testing.expect_value(t, size_near(lowered, {0, 0, z}, 1, .Cliff), 2)
	}
}

// Each kind is resolved on its own, so a bank on one side and a gutter on the
// other do not read each other's numbers.
@(test)
kinds_and_sides_stay_out_of_each_others_way :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 4, 20)

	for spec in ([]struct{kind: geo.Guard_Kind, side: int, size: f32}{
		{.Cliff, 0, 5}, {.Bank, 1, 2}, {.Gutter, 1, 1},
	}) {
		g := geo.guard_make(spec.kind, spec.side, 1)
		g.size, g.taper, g.span = spec.size, 0, 1000
		geo.guard_add(&sp, g)
	}

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	at := gfx.Vector3{0, 0, 20}
	testing.expect_value(t, size_near(ribbon, at, 0, .Cliff), 5)
	testing.expect_value(t, size_near(ribbon, at, 0, .Bank), 0)
	testing.expect_value(t, size_near(ribbon, at, 0, .Gutter), 0)
	testing.expect_value(t, size_near(ribbon, at, 1, .Cliff), 0)
	testing.expect_value(t, size_near(ribbon, at, 1, .Bank), 2)
	testing.expect_value(t, size_near(ribbon, at, 1, .Gutter), 1)
}

// Overlapping guards union rather than stack, and the taller one brings its own
// knobs along — a short cliff beside a tall one must not lend it its angle.
@(test)
overlapping_guards_union_and_the_biggest_brings_its_shape :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)

	low := geo.guard_make(.Cliff, 1, 1)
	low.size, low.taper, low.span, low.angle = 2, 0, 1000, 10
	geo.guard_add(&sp, low)
	high := geo.guard_make(.Cliff, 1, 3)
	high.size, high.taper, high.span, high.angle = 6, 0, 1000, 40
	geo.guard_add(&sp, high)

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	best, cs := max(f32), ribbon[0]
	for c in ribbon {
		if d := gfx.Vector3Distance(c.pos, {0, 0, 40}); d < best { best, cs = d, c }
	}
	// 6 and not 8: two guards over one stretch make one ridge, not a spike.
	testing.expect_value(t, cs.verge[1][.Cliff].size, 6)
	testing.expect_value(t, cs.verge[1][.Cliff].angle, 40)
}

// Deleting one control point out of a long run must not delete the run. The
// anchor falls back to the node's parent, which is still inside the same road.
@(test)
deleting_a_point_keeps_the_run_it_anchored :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	geo.guard_add(&sp, geo.guard_make(.Cliff, 1, 3))

	geo.remove_point(&sp, 3)
	testing.expect_value(t, len(sp.guards), 1)
	testing.expect_value(t, sp.guards[0].at, 2) // the old node 3's parent

	// An anchor further down the array still names its own node after the shift.
	straight_road(&sp, 5, 20)
	geo.guard_add(&sp, geo.guard_make(.Bank, 0, 4))
	geo.remove_point(&sp, 1)
	testing.expect_value(t, sp.guards[0].at, 3)

	// A root has no parent to fall back on, so a guard anchored there goes.
	straight_road(&sp, 5, 20)
	geo.guard_add(&sp, geo.guard_make(.Cliff, 1, 0))
	geo.remove_point(&sp, 0)
	testing.expect_value(t, len(sp.guards), 0)
}

// An insert must not shift a guard off the node it was anchored to.
@(test)
inserting_a_point_leaves_every_anchor_where_it_was :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	geo.guard_add(&sp, geo.guard_make(.Cliff, 1, 3))
	anchored_at := sp.points[3].id

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	geo.insert_point(&sp, {0, 0, 10}, ribbon[3])

	testing.expect_value(t, len(sp.guards), 1)
	testing.expect_value(t, sp.points[sp.guards[0].at].id, anchored_at)
}

// Travel direction decides which edge is left, so reversing the road takes every
// guard over to the other side with it.
@(test)
reversing_the_road_swaps_every_guard_over :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	geo.guard_add(&sp, geo.guard_make(.Cliff, 1, 1))

	geo.reverse_spline(&sp)
	testing.expect_value(t, sp.guards[0].side, 0)
	testing.expect_value(t, sp.guards[0].at, 3) // node 1 of 5 is node 3 backwards
}

// --- the shapes themselves ----------------------------------------------------

// The profile of one side at a sample in the middle of the road.
@(private = "file")
mid_profile :: proc(sp: geo.Spline, side: int) -> (geo.Verge_Profile, geo.Cross_Section) {
	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	cs := ribbon[len(ribbon) / 2]
	return geo.verge_profile(cs, side), cs
}

@(private = "file")
road_with :: proc(sp: ^geo.Spline, kind: geo.Guard_Kind, side: int, size, width: f32) {
	g := geo.guard_make(kind, side, len(sp.points) / 2)
	g.size, g.width, g.taper, g.span, g.rough = size, width, 0, 10_000, 0
	geo.guard_add(sp, g)
}

// A gutter is cut below the road and comes back up to road level, so the ground
// behind it starts where it would have without one. That is what lets the
// terrain weld to a gutter at all: the seam never moves down.
@(test)
a_gutter_dips_and_comes_back_to_grade :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	road_with(&sp, .Gutter, 1, 1.2, 4)

	prof, _ := mid_profile(sp, 1)
	testing.expect(t, prof.any, "a gutter must give the side a profile")
	testing.expect_value(t, prof.pts[1], geo.Verge_Point{2, -1.2}) // the bottom
	testing.expect_value(t, prof.pts[2], geo.Verge_Point{4, 0})    // back to grade
	// Nothing behind it, so the last point is the outer lip.
	testing.expect_value(t, prof.pts[geo.VERGE_PTS - 1], geo.Verge_Point{4, 0})

	// A gutter narrower than it is deep would be a slot the car cannot climb
	// out of, so the width is floored at the depth.
	clear(&sp.guards)
	road_with(&sp, .Gutter, 1, 2, 0)
	narrow, _ := mid_profile(sp, 1)
	testing.expect_value(t, narrow.pts[2].x, 2)
}

// A bank is heaped on the ground rather than cut into it: up to a crest, back
// down to where it started.
@(test)
a_bank_rises_and_comes_back_to_grade :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	road_with(&sp, .Bank, 0, 1.5, 6)

	prof, _ := mid_profile(sp, 0)
	testing.expect_value(t, prof.pts[3], geo.Verge_Point{3, 1.5}) // the crest
	testing.expect_value(t, prof.pts[4], geo.Verge_Point{6, 0})   // the outer toe
	testing.expect_value(t, prof.pts[geo.VERGE_PTS - 1], geo.Verge_Point{6, 0})
}

// All three at once, in the order they are laid: the gutter at the road edge,
// the bank outside it, the cliff behind both. Each starts where the one before
// it finished, so the profile never doubles back on itself.
@(test)
guards_stack_outward_in_one_profile :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	road_with(&sp, .Gutter, 1, 1, 4)
	road_with(&sp, .Bank, 1, 2, 6)
	road_with(&sp, .Cliff, 1, 5, 0)

	prof, cs := mid_profile(sp, 1)
	for i in 1 ..< geo.VERGE_PTS {
		testing.expectf(
			t, prof.pts[i].x >= prof.pts[i - 1].x,
			"the profile must go outward at every step, and point %d came back in", i,
		)
	}
	testing.expect_value(t, prof.pts[2].x, 4)  // gutter lip
	testing.expect_value(t, prof.pts[4].x, 10) // bank outer toe
	testing.expect_value(t, prof.pts[5].y, 5)  // and the cliff stands on that

	// The seam the terrain welds to is the cliff crest, not the bank's toe.
	seam := geo.verge_seam(cs, 1, 0)
	testing.expect(t, abs(seam.y - (cs.pos.y + 5)) < 0.01, "the seam must sit on top of the stack")
}

// A guard that is not there costs its rows but no triangles, which is what lets
// the row layout stay fixed. Sharing rows out by arc length instead would re-cut
// the cliff every time the gutter beside it changed width.
@(test)
an_absent_guard_costs_no_triangles :: proc(t: ^testing.T) {
	tris :: proc(sp: geo.Spline) -> int {
		ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
		return geo.tri_count(geo.build_tri_mesh(ribbon, 0, geo.DEFAULT_LOOK, context.temp_allocator))
	}

	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight_road(&sp, 5, 20)
	bare := tris(sp)

	road_with(&sp, .Cliff, 1, 5, 0)
	cliffed := tris(sp)
	testing.expect(t, cliffed > bare, "a cliff must grow triangles")

	// A guard at zero is a guard that is not there.
	road_with(&sp, .Bank, 1, 0, 6)
	road_with(&sp, .Gutter, 0, 0, 4)
	testing.expect_value(t, tris(sp), cliffed)
}

// --- the file -----------------------------------------------------------------

// Guards survive a save, kind and anchor included. The anchor is an id on disk
// and a position in memory, the same crossing parent and weld make.
@(test)
guards_round_trip_through_road_json :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	// Ids that are nothing like positions, so a writer using the position is
	// caught rather than flattered.
	for &p, i in doc.spline.points { p.id = 70 + i * 3 }
	doc.spline.next_id = 200

	want := geo.Guard {
		kind = .Bank, side = 1, at = 2,
		size = 1.75, span = 88, taper = 12, width = 4.5, angle = 3, rough = 0.25,
	}
	geo.guard_add(&doc.spline, want)
	geo.guard_add(&doc.spline, geo.guard_make(.Gutter, 0, 1))

	out := road_block(&doc, context.allocator)
	defer { delete(out.points); delete(out.guards) }
	testing.expect_value(t, len(out.guards), 2)
	testing.expect_value(t, out.guards[0].kind, "bank")
	testing.expect_value(t, out.guards[0].at, 76) // the id of point 2, not "2"
	testing.expect_value(t, out.guards[1].kind, "gutter")

	back := Venue_Doc{}
	defer doc_delete(&back)
	msg, ok := doc_load_road(&back, out)
	testing.expectf(t, ok, "a road with guards would not load: %s", msg)
	testing.expect_value(t, len(back.spline.guards), 2)
	got := back.spline.guards[0]
	testing.expect_value(t, got.kind, geo.Guard_Kind.Bank)
	testing.expect_value(t, got.at, 2) // an index again
	testing.expect_value(t, got.side, want.side)
	testing.expect_value(t, got.size, want.size)
	testing.expect_value(t, got.span, want.span)
	testing.expect_value(t, got.taper, want.taper)
	testing.expect_value(t, got.width, want.width)
	testing.expect_value(t, got.angle, want.angle)
	testing.expect_value(t, got.rough, want.rough)
}

// A guard naming a point that is not in the file, or a kind this build does not
// know, is dropped. Either one aimed somewhere else would be a guard on the
// wrong road, and it would be silent.
@(test)
a_guard_with_nothing_to_hold_on_to_is_dropped :: proc(t: ^testing.T) {
	pts := make([]Stage_Point, 2, context.allocator)
	defer delete(pts)
	pts[0] = {id = 4, parent = -1, weld = -1, pos = {0, 0, 0}, rot = {0, 0, 0, 1}, width = 8}
	pts[1] = {id = 9, parent = 4, weld = -1, pos = {0, 0, 20}, rot = {0, 0, 0, 1}, width = 8}
	guards := make([]Stage_Guard, 3, context.allocator)
	defer delete(guards)
	guards[0] = {id = 0, kind = "cliff", side = 0, at = 9, size = 4, span = 40, taper = 8}
	guards[1] = {id = 1, kind = "cliff", side = 0, at = 77, size = 4, span = 40} // no such point
	guards[2] = {id = 2, kind = "parapet", side = 0, at = 4, size = 4, span = 40} // no such kind

	doc := Venue_Doc{}
	defer doc_delete(&doc)
	msg, ok := doc_load_road(&doc, Venue_Road{points = pts, guards = guards})
	testing.expectf(t, ok, "the road itself is sound and must load: %s", msg)
	testing.expect_value(t, len(doc.spline.guards), 1)
	testing.expect_value(t, doc.spline.guards[0].at, 1)
}
