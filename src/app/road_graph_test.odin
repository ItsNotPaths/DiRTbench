package main

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

@(test)
old_projects_migrate_their_stage_names_into_routes :: proc(t: ^testing.T) {
	p := Venue {
		stages = []string{"route_0", "route_1"},
		names  = {stages = []string{"FIRST", "SECOND"}},
	}
	venue_migrate_routes(&p, context.temp_allocator)
	testing.expect_value(t, len(p.routes), 2)
	testing.expect_value(t, p.routes[0].id, "route_0")
	testing.expect_value(t, p.routes[1].name, "SECOND")
	// Migrated routes have no markers, so the venue says what it still needs
	// instead of looking ready to export.
	for route in p.routes {
		testing.expect(t, !route_has_markers(route))
	}

	// A project that already has routes is left alone.
	kept := Venue {
		stages = []string{"route_0"},
		routes = []Venue_Route{{id = "route_9", start = {0, 1, 0.5}, finish = {1, 2, 0.5}}},
	}
	venue_migrate_routes(&kept, context.temp_allocator)
	testing.expect_value(t, len(kept.routes), 1)
	testing.expect_value(t, kept.routes[0].id, "route_9")
	testing.expect(t, route_has_markers(kept.routes[0]))
}
