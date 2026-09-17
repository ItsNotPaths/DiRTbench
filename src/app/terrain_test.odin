package main

import "core:testing"
import "../geo"

@(test)
terrain_world_control_is_exact_at_its_handle :: proc(t: ^testing.T) {
	terrain := geo.Terrain{}
	append(&terrain.controls, geo.Terrain_Control{x = 10, z = 20, offset = 3, radius = 10})
	defer geo.terrain_delete(&terrain)
	testing.expect_value(t, geo.terrain_control_offset(&terrain, {10, 20}), f32(3))
	testing.expect_value(t, geo.terrain_control_offset(&terrain, {21, 20}), f32(0))
}
