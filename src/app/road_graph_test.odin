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
	inserted := geo.insert_point(&sp, 1, frame.pos, frame)
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
		sp, {0, 1, 0.5}, {2, 3, 0.5}, context.allocator,
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

	stage, msg, ok := geo.compile_stage(sp, {1, 2, 0.2}, {1, 2, 0.8}, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(stage.points), 2)

	_, back_msg, back_ok := geo.compile_stage(sp, {1, 2, 0.8}, {1, 2, 0.2}, context.allocator)
	testing.expect(t, !back_ok, "a finish before the start on one edge must be refused")
	testing.expect(t, back_msg != "")
}

@(test)
compile_runs_a_loop_through_its_weld :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0), "tail should weld back onto the root")

	// Start just after the root, finish on the weld edge coming back to it.
	stage, msg, ok := geo.compile_stage(sp, {0, 1, 0.1}, {tail, 0, 0.9}, context.allocator)
	defer delete(stage.points)
	testing.expect(t, ok, msg); if !ok { return }
	// Start marker, nodes 1..tail, finish marker on the closing edge.
	testing.expect_value(t, len(stage.points), 5)
	testing.expect(t, geo.is_linear(stage))
	// The loop comes back to where it started.
	first := stage.points[0].xform.translation
	last := stage.points[len(stage.points)-1].xform.translation
	testing.expect(t, gfx.Vector3Distance(first, last) < 20, "a closed loop should finish near its start")
}

@(test)
compile_refuses_a_finish_that_is_not_downstream :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	// Backwards: start late, finish early.
	_, msg, ok := geo.compile_stage(sp, {2, 3, 0.5}, {0, 1, 0.5}, context.allocator)
	testing.expect(t, !ok, "a finish upstream of the start must be refused")
	testing.expect(t, msg != "")

	// An edge that is neither a parent edge nor a weld.
	_, bad_msg, bad_ok := geo.compile_stage(sp, {0, 3, 0.5}, {2, 3, 0.5}, context.allocator)
	testing.expect(t, !bad_ok, "a marker off any edge must be refused")
	testing.expect(t, bad_msg != "")
}

@(test)
compile_keeps_markers_clear_of_the_nodes_they_sit_between :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)

	// t of exactly 1 would land the marker on node 1 and make a zero-length
	// first segment, which has no tangent to follow.
	stage, msg, ok := geo.compile_stage(sp, {0, 1, 1}, {2, 3, 0}, context.allocator)
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
