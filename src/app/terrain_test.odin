package main

import "core:testing"
import "../geo"
import rl "../gfx"

@(test)
terrain_rows_follow_route_length :: proc(t: ^testing.T) {
	testing.expect_value(t, geo.terrain_rows_for_length(0, 8), 0)
	testing.expect_value(t, geo.terrain_rows_for_length(1, 20), 2)
	testing.expect_value(t, geo.terrain_rows_for_length(80, 20), 5)
	testing.expect_value(t, geo.terrain_rows_for_length(800, 20), 41)
	// Spacing is clamped to the supported 10 m minimum.
	testing.expect_value(t, geo.terrain_rows_for_length(80, 0), 9)
}

@(test)
terrain_inside_corner_offsets_are_compressed :: proc(t: ^testing.T) {
	// 0.1 /m is a 10 m radius. With a 2 m verge, the safe reach is 6 m.
	testing.expect_value(t, geo.terrain_offset_reach(0.1, 0, 2, 20), f32(6))
	// The opposite side of that same corner remains at its requested reach.
	testing.expect_value(t, geo.terrain_offset_reach(0.1, 1, 2, 20), f32(20))
	// A radius already inside the verge collapses nodes to the seam, not the road.
	testing.expect_value(t, geo.terrain_offset_reach(0.5, 0, 2, 20), f32(0))
}

@(test)
terrain_clustered_handles_collapse :: proc(t: ^testing.T) {
	terrain := geo.Terrain{enabled = true, rows = 5, cols = 1}
	// Two identical sides: rows 1/2 form a cluster; the endpoint is preserved.
	one_side := [5]rl.Vector3{{0, 0, 0}, {3, 0, 0}, {6, 0, 0}, {16, 0, 0}, {18, 0, 0}}
	pos := [10]rl.Vector3{}
	copy(pos[:5], one_side[:])
	copy(pos[5:], one_side[:])
	active := geo.terrain_node_active_mask(&terrain, pos[:], context.allocator)
	defer delete(active)
	for base in ([]int{0, 5}) {
		testing.expect(t, active[base + 0])
		testing.expect(t, !active[base + 1])
		testing.expect(t, !active[base + 2])
		testing.expect(t, !active[base + 3]) // replaced by the nearby endpoint
		testing.expect(t, active[base + 4])
	}
}
