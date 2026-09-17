package main

import "core:testing"
import "../geo"

@(test)
paths_place_measures_curve_off_the_chord :: proc(t: ^testing.T) {
	testing.expect_value(t, paths_place_curve_deviation(nil), f32(0))
	straight := []geo.Cross_Section{{pos = {0, 0, 0}}, {pos = {0, 0, 100}}, {pos = {0, 0, 200}}}
	testing.expect_value(t, paths_place_curve_deviation(straight), f32(0))
	bent := []geo.Cross_Section{{pos = {0, 0, 0}}, {pos = {15, 0, 100}}, {pos = {0, 0, 200}}}
	testing.expect(t, paths_place_curve_deviation(bent) > PATHS_PLACE_MIN_BOW_M)
}

@(test)
flat_venue_exports_d3_route_handedness :: proc(t: ^testing.T) {
	ribbon := []geo.Cross_Section{
		{pos = {0, 0, 0}, right = {1, 0, 0}, width = 8},
		{pos = {0, 0, 10}, right = {1, 0, 0}, width = 8},
	}
	route := flat_venue_route_samples(ribbon)
	defer delete(route)
	testing.expect_value(t, route[0].Left, [3]f32{4, 0, 0})
	testing.expect_value(t, route[0].Right, [3]f32{-4, 0, 0})
}
