package main

import "core:os"
import "core:testing"
import rl "vendor:raylib"
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
	testing.expect(t, rl.Vector3Distance(last.pos, sp.points[0].xform.translation) < 0.01)

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
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0))

	path := "/tmp/claude-1000/dirtbench-weld-roundtrip.json"
	msg, ok := save_stage_to(sp, path)
	testing.expect(t, ok, msg); if !ok { return }
	defer os.remove(path)

	back: geo.Spline
	defer delete(back.points)
	load_msg, loaded := load_stage_from(&back, path, nil, nil)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	testing.expect_value(t, len(back.points), len(sp.points))
	for p, i in back.points { testing.expect_value(t, p.weld, sp.points[i].weld) }
}
