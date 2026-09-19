package main

import "core:math"
import "core:os"
import "core:testing"
import "../gfx"
import "../geo"

@(test)
road_graph_branch_and_remove :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	branch := geo.extrude_point(&sp, 1)
	testing.expect(t, branch == 4, "a second child should append in topological order")
	testing.expect(t, sp.points[branch].parent == 1, "branch should remember its parent")
	testing.expect(t, geo.is_branch(sp, branch), "second child was not classified as a branch")
	testing.expect(t, !geo.is_linear(sp), "branched graph was classified as linear")
	ribbon := geo.build_ribbon(sp, 2, context.allocator)
	defer delete(ribbon)
	// Four graph edges, each independently sampled at 0, .5 and 1. The break
	// marker prevents mesh and picking code from bridging separate edges.
	testing.expect(t, len(ribbon) == 12, "branched ribbon did not sample every edge")
	breaks := 0
	for section in ribbon { if section.break_before { breaks += 1 } }
	testing.expect(t, breaks == 4, "branched ribbon lost edge boundaries")

	geo.remove_point(&sp, 1)
	testing.expect(t, len(sp.points) == 4, "remove did not compact the graph")
	for p, i in sp.points {
		testing.expect(t, p.parent < i, "remove left a forward parent reference")
	}
}

@(test)
reversing_a_chain_rebuilds_valid_parents :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	original_head := sp.points[0].xform.translation
	original_tail := sp.points[len(sp.points)-1].xform.translation

	geo.reverse_spline(&sp)
	testing.expect(t, sp.points[0].xform.translation == original_tail, "tail did not become root")
	testing.expect(t, sp.points[len(sp.points)-1].xform.translation == original_head, "root did not become tail")
	testing.expect(t, geo.is_linear(sp), "reverse left stale graph parent indices")
	for p, i in sp.points {
		testing.expect(t, p.parent == i-1, "reversed chain has an invalid parent")
	}
}

@(test)
weld_closes_a_loop_without_touching_the_parent_tree :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1

	testing.expect(t, geo.is_linear(sp), "the seed road should start as a chain")
	plain := geo.build_ribbon(sp, 2, context.temp_allocator)

	testing.expect(t, geo.weld_points(&sp, tail, 0), "tail should weld back onto the root")
	testing.expect(t, !geo.is_linear(sp), "a welded chain must take the graph sampler")
	testing.expect(t, !geo.weld_points(&sp, 0, 1), "a weld must not duplicate a parent edge")

	looped := geo.build_ribbon(sp, 2, context.temp_allocator)
	// Three parent edges and the weld, each sampled at 0, .5 and 1.
	testing.expect_value(t, len(looped), 12)
	testing.expect(t, len(looped) > len(plain), "the weld edge was not sampled")

	// The closing edge ends on the root, which is what makes the loop seamless.
	last := looped[len(looped) - 1]
	testing.expect(t, gfx.Vector3Distance(last.pos, sp.points[0].xform.translation) < 0.01)

	geo.unweld_point(&sp, tail)
	testing.expect(t, geo.is_linear(sp), "unweld did not restore the chain")
}

// A weld edge and the parent edge into the same node share a child index, so an
// insert that went by the child alone put the point on the other road entirely.
@(test)
insert_on_a_welded_stretch_stays_on_that_stretch :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0), "tail should weld back onto the root")

	ribbon := geo.build_ribbon(sp, 4, context.allocator)
	defer delete(ribbon)
	frame: geo.Cross_Section
	found := false
	for cs in ribbon {
		if cs.e_from == tail && cs.e_to == 0 && abs(cs.t - 0.5) < 0.01 {
			frame, found = cs, true
			break
		}
	}
	testing.expect(t, found, "the ribbon has no sample on the weld edge"); if !found { return }

	before := len(sp.points)
	idx, _ := geo.insert_point(&sp, frame.pos, frame)
	testing.expect(t, idx >= 0, "insert refused a welded stretch"); if idx < 0 { return }
	testing.expect_value(t, len(sp.points), before + 1)
	testing.expect(t, gfx.Vector3Distance(sp.points[idx].xform.translation, frame.pos) < 0.01,
		"the new point did not land where the road was clicked")
	// The loop still closes, and now runs tail -> new -> root.
	testing.expect_value(t, sp.points[idx].parent, tail)
	testing.expect_value(t, sp.points[idx].weld, 0)
	testing.expect_value(t, sp.points[tail].weld, -1)
	// The road is unbroken through it: one more edge, and a stage still
	// compiles the whole way round.
	pins := []geo.Road_Marker{{tail, idx, 0.5}}
	lap, msg, ok := geo.compile_stage(sp, {0, 1, 0.1}, {idx, 0, 0.9}, pins, context.allocator)
	defer delete(lap.points)
	testing.expect(t, ok, msg)
}

@(test)
weld_indices_survive_every_graph_edit :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	// Not to its own parent: that edge already exists, and weld_points says so.
	testing.expect(t, !geo.weld_points(&sp, tail, tail - 1))
	testing.expect(t, geo.weld_points(&sp, tail, 1))

	// Inserting ahead of the weld target pushes every later index up by one.
	frame := geo.sample_edge(sp, 0, 1, 0.5)
	inserted, _ := geo.insert_point(&sp, frame.pos, frame)
	testing.expect_value(t, inserted, 1)
	testing.expect_value(t, sp.points[tail + 1].weld, 2)
	testing.expect_value(t, sp.points[inserted].weld, -1)

	// Removing the target drops the edge rather than aiming it at a parent.
	geo.remove_point(&sp, 2)
	for p, i in sp.points {
		testing.expect(t, p.weld < len(sp.points), "remove left a stale weld index")
		testing.expect(t, p.weld != i, "remove left a self weld")
	}
	testing.expect_value(t, sp.points[len(sp.points) - 1].weld, -1)
}

@(test)
stage_file_round_trips_a_welded_loop :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	tail := len(doc.spline.points) - 1
	testing.expect(t, geo.weld_points(&doc.spline, tail, 0))

	path := "/tmp/claude-1000/dirtbench-weld-roundtrip.json"
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg); if !ok { return }
	defer os.remove(path)

	back := doc_defaults()
	defer doc_delete(&back)
	load_msg, loaded := load_road(&back, path)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	testing.expect_value(t, len(back.spline.points), len(doc.spline.points))
	for p, i in back.spline.points { testing.expect_value(t, p.weld, doc.spline.points[i].weld) }
}

// A marker sits on the edge running into `to`, so the seed chain 0->1->2->3
// gives edges (0,1), (1,2) and (2,3).
@(test)
compile_trims_the_road_to_the_two_markers :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	stage, msg, ok := geo.compile_stage(
		sp, {0, 1, 0.5}, {2, 3, 0.5}, nil, context.allocator,
	)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }

	// The marker on (0,1), then nodes 1 and 2, then the marker on (2,3).
	testing.expect_value(t, len(stage.points), 4)
	testing.expect(t, geo.is_linear(stage), "a compiled stage must be a plain chain")
	testing.expect(t, gfx.Vector3Distance(stage.points[1].xform.translation, sp.points[1].xform.translation) < 0.01)
	testing.expect(t, gfx.Vector3Distance(stage.points[2].xform.translation, sp.points[2].xform.translation) < 0.01)
	// Node 0 and node 3 are outside the markers and must not survive.
	for p in stage.points {
		testing.expect(t, gfx.Vector3Distance(p.xform.translation, sp.points[0].xform.translation) > 0.01)
		testing.expect(t, gfx.Vector3Distance(p.xform.translation, sp.points[3].xform.translation) > 0.01)
	}
}

@(test)
compile_accepts_two_markers_on_one_edge :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	stage, msg, ok := geo.compile_stage(sp, {1, 2, 0.2}, {1, 2, 0.8}, nil, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(stage.points), 2)

	// The same stretch the other way round is a stage too, and the points that
	// come out of it face the other way.
	back, back_msg, back_ok := geo.compile_stage(sp, {1, 2, 0.8}, {1, 2, 0.2}, nil, context.allocator)
	defer delete(back.points)
	testing.expect(t, back_ok, back_msg); if !back_ok { return }
	testing.expect_value(t, len(back.points), 2)
	dot := gfx.Vector3DotProduct(
		geo.point_forward(stage.points[0]), geo.point_forward(back.points[0]),
	)
	testing.expect(t, dot < -0.5, "a stage run the other way must face the other way")

	// The two lines on the same spot are no stage at all.
	_, same_msg, same_ok := geo.compile_stage(sp, {1, 2, 0.5}, {1, 2, 0.5}, nil, context.allocator)
	testing.expect(t, !same_ok, "a finish on top of the start must be refused")
	testing.expect(t, same_msg != "")
}

// The whole lap is the long way round a welded loop, and a pin on the far side
// is how it is asked for. Without one the search takes the short way, which is
// the point of the search.
@(test)
compile_runs_a_loop_the_short_way_until_a_pin_says_otherwise :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0), "tail should weld back onto the root")

	// Start just after the root, finish on the weld edge coming back into it.
	// Both are a few metres from node 0, the short way between them.
	short, msg, ok := geo.compile_stage(sp, {0, 1, 0.1}, {tail, 0, 0.9}, nil, context.allocator)
	defer delete(short.points)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(short.points), 3) // start, node 0, finish

	// A pin on the far side of the loop forces the whole lap.
	pins := []geo.Road_Marker{{1, 2, 0.5}}
	lap, lap_msg, lap_ok := geo.compile_stage(sp, {0, 1, 0.1}, {tail, 0, 0.9}, pins, context.allocator)
	defer delete(lap.points)
	testing.expect(t, lap_ok, lap_msg); if !lap_ok { return }
	// Start marker, nodes 1..tail, finish marker on the closing edge.
	testing.expect_value(t, len(lap.points), 5)
	testing.expect(t, geo.is_linear(lap))
	first := lap.points[0].xform.translation
	last := lap.points[len(lap.points) - 1].xform.translation
	testing.expect(t, gfx.Vector3Distance(first, last) < 20, "a closed loop should finish near its start")
	testing.expect(t, geo.spline_length(lap) > geo.spline_length(short) * 5, "the pinned lap must be the long way")
}

// A road is not one-way. The parent pointers say which way it was drawn, not
// which way it can be driven, so a finish upstream of the start is a stage that
// runs back down the road.
@(test)
compile_runs_a_stage_back_down_the_road :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	stage, msg, ok := geo.compile_stage(sp, {2, 3, 0.5}, {0, 1, 0.5}, nil, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(stage.points), 4)
	testing.expect(t, geo.is_linear(stage))
	// It leaves the start heading back toward node 2, not on toward node 3.
	fwd := geo.point_forward(stage.points[0])
	toward_2 := gfx.Vector3Normalize(sp.points[2].xform.translation - stage.points[0].xform.translation)
	testing.expect(t, gfx.Vector3DotProduct(fwd, toward_2) > 0.5, "a backwards stage must face backwards")
	// Every side swaps with the direction: what was the left cliff is now right.
	testing.expect_value(t, stage.points[1].cliff_l, sp.points[2].cliff_r)
}

@(test)
compile_refuses_a_marker_that_is_not_on_an_edge :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	// An edge that is neither a parent edge nor a weld.
	_, bad_msg, bad_ok := geo.compile_stage(sp, {0, 3, 0.5}, {2, 3, 0.5}, nil, context.allocator)
	testing.expect(t, !bad_ok, "a marker off any edge must be refused")
	testing.expect(t, bad_msg != "")
}

// The fork. Before the search went both ways this was the refusal that read
// "no road runs from the start line to the finish line" about a road anyone
// could see joining up: the walk could not come out of one branch and go down
// another.
@(test)
compile_crosses_a_fork_between_two_branches :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp) // 0 -> 1 -> 2 -> 3
	// A second child of node 1, so 1 is a fork with branches (1,2) and (1,spur).
	spur_at := gfx.Vector3{-60, 4, 60}
	tip_at := gfx.Vector3{-120, 6, 90}
	spur := len(sp.points)
	geo.spline_push(&sp, geo.make_point(
		spur_at, geo.heading_quat(sp.points[1].xform.translation, spur_at),
		geo.DEFAULT_WIDTH, parent = 1,
	))
	tip := len(sp.points)
	geo.spline_push(&sp, geo.make_point(
		tip_at, geo.heading_quat(spur_at, tip_at), geo.DEFAULT_WIDTH, parent = spur,
	))

	// Up one branch, through the apex, down the other.
	stage, msg, ok := geo.compile_stage(sp, {spur, tip, 0.5}, {2, 3, 0.5}, nil, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	// Start marker, spur, node 1, node 2, finish marker.
	testing.expect_value(t, len(stage.points), 5)
	testing.expect(t, geo.is_linear(stage))
	testing.expect(t, gfx.Vector3Distance(
		stage.points[2].xform.translation, sp.points[1].xform.translation,
	) < 0.01, "the stage must pass through the fork apex")
	for i in 1 ..< len(stage.points) {
		d := gfx.Vector3Distance(
			stage.points[i - 1].xform.translation, stage.points[i].xform.translation,
		)
		testing.expect(t, d > 0.01, "a stage across a fork has a zero-length segment")
	}
	// The branch it comes up is driven against the way it was drawn, so that
	// point faces back down the branch, toward the apex.
	toward_apex := gfx.Vector3Normalize(
		sp.points[1].xform.translation - sp.points[spur].xform.translation,
	)
	testing.expect(t, gfx.Vector3DotProduct(
		geo.point_forward(stage.points[1]), toward_apex,
	) > 0.5, "the branch driven backwards must face the apex")
}

// Pins are crossed in the order they were placed, so two of them on the same
// road pick which way round it is driven.
@(test)
compile_takes_the_pins_in_order :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0))

	one := geo.Road_Marker{1, 2, 0.5}
	two := geo.Road_Marker{2, 3, 0.5}
	fwd, fmsg, fok := geo.compile_stage(sp, {0, 1, 0.1}, {tail, 0, 0.9}, []geo.Road_Marker{one, two}, context.allocator)
	defer delete(fwd.points)
	testing.expect(t, fok, fmsg); if !fok { return }
	back, bmsg, bok := geo.compile_stage(sp, {0, 1, 0.1}, {tail, 0, 0.9}, []geo.Road_Marker{two, one}, context.allocator)
	defer delete(back.points)
	testing.expect(t, bok, bmsg); if !bok { return }
	// Same two roads, opposite orders: the second has to double back, so it is
	// the longer road of the two.
	testing.expect(t, geo.spline_length(back) > geo.spline_length(fwd), "pins out of order must not shorten the road")
}

@(test)
compile_refuses_a_pin_that_is_not_on_an_edge :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	_, msg, ok := geo.compile_stage(
		sp, {0, 1, 0.5}, {2, 3, 0.5}, []geo.Road_Marker{{0, 3, 0.5}}, context.allocator,
	)
	testing.expect(t, !ok, "a pin off any edge must be refused")
	testing.expect(t, msg != "", "a refused pin gave no reason")
}

@(test)
compile_keeps_markers_clear_of_the_nodes_they_sit_between :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	// t of exactly 1 would land the marker on node 1 and make a zero-length
	// first segment, which has no tangent to follow.
	stage, msg, ok := geo.compile_stage(sp, {0, 1, 1}, {2, 3, 0}, nil, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	for i in 1 ..< len(stage.points) {
		d := gfx.Vector3Distance(stage.points[i-1].xform.translation, stage.points[i].xform.translation)
		testing.expect(t, d > 0.01, "compiled stage has a zero-length segment")
	}
}

// --- cliffs over the graph ----------------------------------------------------

// A straight road along +Z, every point facing the way it runs, so arc length
// between two nodes is exactly their spacing and a span can be asserted in
// metres.
@(private = "file")
straight_road :: proc(sp: ^geo.Spline, count: int, spacing: f32) {
	clear(&sp.points)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * spacing}
		geo.spline_push(sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
}

// The right cliff on whichever sample is nearest `at`.
@(private = "file")
cliff_r_near :: proc(ribbon: []geo.Cross_Section, at: gfx.Vector3) -> f32 {
	best, h := max(f32), f32(0)
	for cs in ribbon {
		if d := gfx.Vector3Distance(cs.pos, at); d < best {
			best, h = d, cs.cliff_r
		}
	}
	return h
}

// The tallest right cliff anywhere on the edge `from` -> `to`.
@(private = "file")
cliff_r_on_edge :: proc(ribbon: []geo.Cross_Section, from, to: int) -> f32 {
	h: f32
	for cs in ribbon {
		if cs.e_from == from && cs.e_to == to {
			h = max(h, cs.cliff_r)
		}
	}
	return h
}

// A span is metres of road, and a road forks. This is the bug the dirtbench_1
// venue showed: on a branched road the ribbon lerped each edge between its two
// ends, so a cliff was stuck on the two edges either side of its own point and
// the span and taper sliders did nothing at all.
@(test)
cliff_span_runs_along_the_road_not_the_array :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 5, 40) // nodes at z = 0, 40, 80, 120, 160

	// A branch off node 3, far enough past it that no lerp between two ends
	// could ever reach it.
	branch := geo.extrude_point(&sp, 3)
	sp.points[branch].xform.translation = {30, 0, 150}
	testing.expect(t, !geo.is_linear(sp), "the test road must take the graph sampler")

	sp.points[2].cliff_r = 5     // at z = 80
	sp.points[2].cliff_taper = 0 // square ends, so the span is exactly readable
	sp.points[2].span_r = 60     // 30 m either way: z = 50 .. 110

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	testing.expect_value(t, cliff_r_near(ribbon, {0, 0, 80}), 5)
	testing.expect_value(t, cliff_r_near(ribbon, {0, 0, 60}), 5)
	testing.expect_value(t, cliff_r_near(ribbon, {0, 0, 20}), 0)
	testing.expect_value(t, cliff_r_near(ribbon, {0, 0, 140}), 0)
	testing.expect_value(t, cliff_r_on_edge(ribbon, 3, branch), 0)

	// Widen it past the fork and it runs into the branch, which is the whole
	// point of walking the road: 40 m to node 3, then 20 m down the branch.
	sp.points[2].span_r = 120 // 60 m either way, so z = 20 .. 140
	wide := geo.build_ribbon(sp, 14, context.temp_allocator)
	testing.expect_value(t, cliff_r_near(wide, {0, 0, 130}), 5)
	testing.expect(t, cliff_r_on_edge(wide, 3, branch) > 0, "a span past a fork must reach into the branch")
	// It stops inside the branch rather than covering it whole.
	tip := sp.points[branch].xform.translation
	testing.expect_value(t, cliff_r_near(wide, tip), 0)

	// And it comes back when the span is taken away again.
	sp.points[2].span_r = 0
	none := geo.build_ribbon(sp, 14, context.temp_allocator)
	testing.expect_value(t, cliff_r_near(none, {0, 0, 80}), 0)
}

// The editor draws the venue road and the game drives a compiled stage, and a
// stage is a chain where the venue is a graph. Both must stand the cliff in the
// same place, or the window is lying about what ships.
@(test)
a_stage_carries_the_cliff_the_venue_shows :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 5, 40)
	branch := geo.extrude_point(&sp, 3)
	sp.points[branch].xform.translation = {30, 0, 150}

	sp.points[2].cliff_r = 4
	sp.points[2].cliff_taper = 10
	sp.points[2].span_r = 100

	venue := geo.build_ribbon(sp, 14, context.temp_allocator)

	// Drawn direction, so no side swaps: from the first edge to the last of the
	// main chain.
	stage, msg, ok := geo.compile_stage(sp, {0, 1, 0.5}, {3, 4, 0.5}, nil, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	compiled := geo.build_ribbon(stage, 14, context.temp_allocator)

	for z in ([]f32{40, 60, 80, 100, 120}) {
		at := gfx.Vector3{0, 0, z}
		v, c := cliff_r_near(venue, at), cliff_r_near(compiled, at)
		testing.expectf(t, abs(v - c) < 0.05, "at z=%.0f the venue says %.2f m and the stage says %.2f m", z, v, c)
	}
}

// The walk the cliffs and the stage search share. Distance is metres of road,
// not hops, and it stops where it is told to.
@(test)
graph_reach_measures_the_road_in_metres :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 5, 40)

	near := geo.graph_reach(sp, 2, 50)
	testing.expect_value(t, near[2], 0)
	testing.expect_value(t, near[1], 40)
	testing.expect_value(t, near[3], 40)
	// Node 0 is 80 m away, past the limit, so it is never settled.
	testing.expect(t, near[0] > 50, "the walk settled a point past its limit")

	far := geo.graph_reach(sp, 2, 1000)
	testing.expect_value(t, far[0], 80)
	testing.expect_value(t, far[4], 80)
}

// Two roughness knobs, and they are not the same one. The knob on the point
// panel is the road surface a car drives on; the one under Cliffs is the rock
// face. The verge used to read the global slider alone, which is held at zero,
// so the cliff jitter could not be reached from the editor at all.
@(test)
cliff_roughness_moves_the_face_and_the_road_knob_does_not :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 4, 40)
	for &p in sp.points { p.cliff_r, p.cliff_rough = 4, 0 }
	smooth := road_mesh(&sp)

	for &p in sp.points { p.roughness = 1 }
	cliff_dev, road_dev := mesh_deviation(smooth, road_mesh(&sp))
	testing.expect_value(t, cliff_dev, 0) // the road knob leaves rock alone
	testing.expect(t, road_dev > 0.01, "the road knob must move the road")

	for &p in sp.points { p.roughness, p.cliff_rough = 0, 1 }
	cliff_dev, road_dev = mesh_deviation(smooth, road_mesh(&sp))
	testing.expect(t, cliff_dev > 0.1, "the cliff knob must break up the face")
	testing.expect_value(t, road_dev, 0) // and leave the road alone
}

@(private = "file")
road_mesh :: proc(sp: ^geo.Spline) -> geo.Tri_Mesh {
	ribbon := geo.build_ribbon(sp^, 14, context.temp_allocator)
	return geo.build_tri_mesh(ribbon, 0, context.temp_allocator)
}

// Mean metres each material's vertices moved between two builds of one road.
// Both meshes come off the same spline topology, so the two are the same
// vertices in the same order and can be compared straight across.
@(private = "file")
mesh_deviation :: proc(a, b: geo.Tri_Mesh) -> (cliff, road: f32) {
	cliff_n, road_n: f32
	for mat, tri in a.mat {
		for corner in 0 ..< 3 {
			i := tri*3 + corner
			d := gfx.Vector3Length(b.pos[i] - a.pos[i])
			switch mat {
			case .Cliff:           cliff += d; cliff_n += 1
			case .Road, .RoadSand: road += d;  road_n += 1
			case .Terrain:
			}
		}
	}
	return cliff / max(cliff_n, 1), road / max(road_n, 1)
}

// The bug a rough cliff used to show: the crest is the line the terrain welds
// to, and the terrain triangulates it in plan. A per-vertex random walked
// neighbouring crest points on top of each other and past each other, which
// dropped points out of the weld and left holes along the lip. A field cannot
// do that while its gradient stays under 1, and this is what says so.
//
// Both spacings matter. Control points far apart give a ribbon coarse enough
// that the short octave is no longer representable, and drawing it anyway is
// the per-vertex random again — see the band limit in rock_displacement.
@(test)
a_rough_cliff_keeps_its_crest_in_order :: proc(t: ^testing.T) {
	rough_cliff_holds(t, 40)
	rough_cliff_holds(t, 120)
}

@(private = "file")
rough_cliff_holds :: proc(t: ^testing.T, spacing: f32) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 6, spacing) // up +z, so the right-hand cliff stands on -x
	for &p in sp.points {
		p.cliff_r = geo.CLIFF_HEIGHT_MAX
		p.cliff_rough = 1
	}
	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	ds := geo.sample_spacing(ribbon)

	moved, prev := false, gfx.Vector3{}
	for cs, i in ribbon {
		seam := geo.verge_seam(cs, 1, geo.VERGE_ROWS, 0)
		if i > 0 {
			testing.expect(t, seam.z > prev.z, "the crest must not double back along the road")
			step := abs(seam.x-prev.x) + abs(seam.z-prev.z)
			testing.expect(t, step > 0.2, "two crest points must not collapse onto one another")
			moved = moved || abs(seam.x - prev.x) > 0.01
		}
		prev = seam
	}
	testing.expect(t, moved, "a rough crest must actually wander, or this proves nothing")

	// And the face itself stays the right way out. The cliff stands on -x and is
	// the wall you drive past, so every triangle on it looks back at the road,
	// which a folded one would not.
	mesh := geo.build_tri_mesh(ribbon, 0, context.temp_allocator)
	faces := 0
	for mat, tri in mesh.mat {
		if mat != .Cliff { continue }
		faces += 1
		testing.expect(t, mesh.nrm[tri*3].x > 0, "a rough face must not turn a triangle inside out")
	}
	testing.expect(t, faces > 100, "the test road must actually grow a cliff")
}

// Rock stands off the cut face, and the cut was made for the road. Three things
// the amplitude was chosen against, all measured: no stone over the road at any
// slider setting, no triangle standing off the wall like a blade, and no face
// turned inside out on a bend — where the face normals converge and a fold would
// show first.
@(test)
rock_stands_off_the_face_and_never_over_the_road :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 6, 24) // the cliff stands on -x, the road is 8 m wide
	for &p in sp.points { p.cliff_r, p.cliff_rough = geo.CLIFF_HEIGHT_MAX, 0 }
	smooth := road_mesh(&sp)
	for &p in sp.points { p.cliff_rough = 1 }
	rough := road_mesh(&sp)

	relief, n := f32(0), f32(0)
	faces, blades := 0, 0
	for mat, tri in rough.mat {
		if mat != .Cliff { continue }
		// Not how *steep* the face gets: a rough face is steep facets, and the
		// angle off the wall measures roughness and spikiness with one number,
		// so asserting on it only pins a look. Facing away from the road is a
		// defect either way — it reads as a hole through the cliff.
		faces += 1
		if rough.nrm[tri*3].x <= 0 { blades += 1 }
		for corner in 0 ..< 3 {
			i := tri*3 + corner
			testing.expect(t, rough.pos[i].x <= -geo.DEFAULT_WIDTH*0.5 + 0.01, "rock must not lean over the road")
			relief += gfx.Vector3Length(rough.pos[i] - smooth.pos[i]); n += 1
		}
	}
	testing.expect_value(t, blades, 0) // no face may turn its back on the road
	// Relief worth the name: well under the amplitude it was tuned to, so this
	// catches the field being turned off, not the next tuning pass.
	testing.expect(t, relief/max(n, 1) > 0.4, "a face at full roughness must actually stand off the smooth cut")

	bend: geo.Spline
	defer delete(bend.points)
	for i in 0 ..< 10 {
		a := f32(i) * 0.25
		pos := gfx.Vector3{25*math.cos(a) - 25, 0, 25*math.sin(a)}
		geo.spline_push(&bend, geo.make_point(pos, gfx.QuaternionFromAxisAngle({0,1,0}, -a), geo.DEFAULT_WIDTH, parent = i - 1))
	}
	for &p in bend.points { p.cliff_l, p.cliff_rough = geo.CLIFF_HEIGHT_MAX, 1 }
	ribbon := geo.build_ribbon(bend, 14, context.temp_allocator)
	mesh := geo.build_tri_mesh(ribbon, 0, context.temp_allocator)
	bend_faces := 0
	for mat, tri in mesh.mat {
		if mat != .Cliff { continue }
		bend_faces += 1
		// By position, not by index: a tapered cliff skips samples, so the
		// triangle's place in the soup does not name the sample it grew from.
		c := (mesh.pos[tri*3] + mesh.pos[tri*3+1] + mesh.pos[tri*3+2]) / 3
		best, near := max(f32), ribbon[0]
		for cs in ribbon {
			if d := gfx.Vector3Length(cs.pos - c); d < best { best, near = d, cs }
		}
		testing.expect(t, gfx.Vector3DotProduct(mesh.nrm[tri*3], -near.right) > 0, "a face on a bend must not turn inside out")
	}
	testing.expect(t, bend_faces > 100, "the bend must actually grow a cliff")
}

// The ribbon emits two coincident samples at every node: one ending the edge
// into it, one starting the edge out of it. They stand at the same place but
// know different things about their neighbours — the first has no next sample on
// its own edge, so its spacing reads as zero.
//
// Any face vertex that reads something a twin can disagree about opens a crack
// at every node, the width of the disagreement. Band-limiting the rock field by
// the local sample spacing did exactly that, for 1.5 m of gap on a 5 m cliff,
// through the face and the terrain welded to it. Hence: a face vertex is a
// function of the smooth face, and of nothing that varies between twins.
@(test)
node_twins_build_the_same_cliff :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 6, 40)
	// A branch makes the road a graph, which is what a venue always is, and the
	// graph sampler is the one that emits the twins.
	branch := geo.extrude_point(&sp, 3)
	sp.points[branch].xform.translation = {30, 0, 150}
	testing.expect(t, !geo.is_linear(sp), "the test road must take the graph sampler")
	for &p in sp.points { p.cliff_l, p.cliff_r, p.cliff_rough = 5, 5, 1 }

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator)
	twins := 0
	for i in 0 ..< len(ribbon) {
		for j in i + 1 ..< len(ribbon) {
			if gfx.Vector3Length(ribbon[i].pos - ribbon[j].pos) > 0.001 { continue }
			twins += 1
			for side in 0 ..< 2 {
				pa := geo.verge_profile(ribbon[i], side)
				pb := geo.verge_profile(ribbon[j], side)
				for row in 0 ..= geo.VERGE_ROWS {
					a := geo.verge_vertex(ribbon[i], pa, side, row, geo.VERGE_ROWS, 0)
					b := geo.verge_vertex(ribbon[j], pb, side, row, geo.VERGE_ROWS, 0)
					testing.expect_value(t, gfx.Vector3Length(a - b), 0)
				}
			}
		}
	}
	testing.expect(t, twins >= 4, "the test road must actually put twins at its nodes")
}

// The crest is the one line the rest of the world welds to: the terrain rim, the
// billboards and the scatter all read `verge_seam`, and the terrain triangulates
// it in plan. A crest that moves with the roughness drags all of them with it,
// and the 2D triangulation is where that turns into holes — points bunching
// together or crossing over in plan view.
//
// So rock goes to nothing at the crest, exactly as it does at the road edge, and
// the whole class of seam goes with it. The cost is a clean skyline.
@(test)
the_crest_never_moves :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 6, 40)
	branch := geo.extrude_point(&sp, 3)
	sp.points[branch].xform.translation = {30, 0, 150}
	for &p in sp.points { p.cliff_l, p.cliff_r, p.cliff_rough = 5, 5, 0 }
	smooth := geo.build_ribbon(sp, 14, context.temp_allocator)
	for &p in sp.points { p.cliff_rough = 1 }
	rough := geo.build_ribbon(sp, 14, context.temp_allocator)

	testing.expect_value(t, len(rough), len(smooth))
	for i in 0 ..< len(smooth) {
		for side in 0 ..< 2 {
			a := geo.verge_seam(smooth[i], side, geo.VERGE_ROWS, 0)
			b := geo.verge_seam(rough[i], side, geo.VERGE_ROWS, 0)
			testing.expect_value(t, gfx.Vector3Length(a - b), 0)
		}
	}
}

// How big the rock gets is set by the cliff's height and by nothing else. Lay a
// cliff back and its face grows much faster than it does: a 7 m cliff at 75
// degrees has a 25 m face, and an amplitude keyed off that length put an 18 m
// jut through the middle of it. The lean buys room for rock to stand toward the
// road; it must not buy more rock.
@(test)
a_laid_back_cliff_grows_no_bigger_rock :: proc(t: ^testing.T) {
	worst_at :: proc(angle: f32) -> f32 {
		sp: geo.Spline
		defer delete(sp.points)
		straight_road(&sp, 6, 24)
		for &p in sp.points { p.cliff_r, p.cliff_angle, p.cliff_rough = geo.CLIFF_HEIGHT_MAX, angle, 0 }
		smooth := geo.build_ribbon(sp, 14, context.temp_allocator)
		for &p in sp.points { p.cliff_rough = 1 }
		rough := geo.build_ribbon(sp, 14, context.temp_allocator)

		worst: f32
		for i in 0 ..< len(smooth) {
			ps := geo.verge_profile(smooth[i], 1)
			pr := geo.verge_profile(rough[i], 1)
			if ps.n < 2 { continue }
			for row in 1 ..< geo.VERGE_ROWS {
				a := geo.verge_vertex(smooth[i], ps, 1, row, geo.VERGE_ROWS, 0)
				b := geo.verge_vertex(rough[i], pr, 1, row, geo.VERGE_ROWS, 0)
				worst = max(worst, gfx.Vector3Length(a - b))
			}
		}
		return worst
	}

	sheer, laid := worst_at(geo.CLIFF_ANGLE_MIN + 1), worst_at(geo.CLIFF_ANGLE_MAX)
	testing.expect(t, sheer > 1, "a sheer face must still grow rock")
	testing.expect(t, laid < sheer*1.25, "laying a cliff back must not inflate its rock")
}

// UVs here are metres over UV_TILE_M in both axes, so the texture should land at
// one density everywhere. Drawn on the smooth cut they do not: the rock stands
// metres off it, and every edge came out stretched, up to 3.4x, mean 1.22. Both
// axes now measure the rock itself — `v` up each column, `u` along the road by
// what the rung's rows actually moved.
@(test)
the_cliff_texture_keeps_its_density :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	straight_road(&sp, 6, 24)
	for &p in sp.points { p.cliff_r, p.cliff_angle, p.cliff_rough = geo.CLIFF_HEIGHT_MAX, 45, 1 }
	mesh := geo.build_tri_mesh(geo.build_ribbon(sp, 14, context.temp_allocator), 0, context.temp_allocator)

	worst, sum, n := f32(0), f32(0), f32(0)
	for mat, tri in mesh.mat {
		if mat != .Cliff { continue }
		for e in 0 ..< 3 {
			a, b := mesh.pos[tri*3 + e], mesh.pos[tri*3 + (e+1)%3]
			ua, ub := mesh.uv[tri*3 + e], mesh.uv[tri*3 + (e+1)%3]
			span := gfx.Vector3Length({ub.x-ua.x, ub.y-ua.y, 0}) * geo.UV_TILE_M
			if span < 1e-4 { continue }
			r := gfx.Vector3Length(b - a) / span
			worst = max(worst, r); sum += r; n += 1
		}
	}
	testing.expect(t, n > 100, "the test road must actually grow a cliff")
	// Centred, not merely bounded: UVs on the smooth cut can only ever stretch,
	// so the mean is what catches that coming back.
	testing.expect(t, abs(sum/n - 1) < 0.1, "the texture must land at the density it asks for")
	testing.expect(t, worst < 2.5, "no edge may stretch the texture over its own length")
}

// Growing the road takes its height from the node it grew from, never from the
// cursor: the cursor only ever rides the world plane at y=0.
@(test)
grow_road_copies_the_parent_height :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	sp.points[tail].xform.translation.y = 45

	// From the selection, off the tail.
	idx := grow_road(&sp, tail, {30, 0, 160})
	testing.expect_value(t, sp.points[idx].xform.translation.y, f32(45))
	testing.expect_value(t, sp.points[idx].xform.translation.x, f32(30))

	// From the head, which grows backwards and renumbers the array.
	sp.points[0].xform.translation.y = 12
	head := grow_road(&sp, 0, {-30, 0, -20})
	testing.expect_value(t, sp.points[head].xform.translation.y, f32(12))

	// With nothing selected it appends to the tail and takes the tail's height.
	want := sp.points[len(sp.points) - 1].xform.translation.y
	app := grow_road(&sp, -1, {99, 0, 99})
	testing.expect_value(t, sp.points[app].xform.translation.y, want)
}
