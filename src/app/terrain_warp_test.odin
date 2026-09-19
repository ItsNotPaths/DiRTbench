package main

import "core:testing"
import "../geo"

// The warp lifts the ground with distance from the road and leaves both the
// verge and the sculpt alone: it is a modifier, not a reset.
@(test)
terrain_warp_lifts_away_from_the_road :: proc(t: ^testing.T) {
	SEAM_Y :: 3
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)

	height_at := proc(terrain: ^geo.Terrain, u: f32) -> f32 {
		leg := geo.Terrain_Leg{u = u, seam_y = SEAM_Y, w = 1}
		return geo.terrain_world_height(terrain, {0, 0}, {leg, {}}, 1)
	}

	testing.expect_value(t, height_at(&terrain, terrain.reach_m), f32(SEAM_Y))
	terrain.warp_m = 40
	testing.expect_value(t, height_at(&terrain, 0), f32(SEAM_Y)) // the verge holds
	testing.expect_value(t, height_at(&terrain, terrain.reach_m), f32(SEAM_Y + 40))
	// Quadratic, so a quarter of the lift has happened at the halfway mark.
	testing.expect_value(t, height_at(&terrain, terrain.reach_m * 0.5), f32(SEAM_Y + 10))
}
