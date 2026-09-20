package d3

import "core:math"
import "core:testing"

// Straight in, one constant-radius corner, straight out.
test_arc_route :: proc(radius: f32, allocator := context.temp_allocator) -> []Route_Sample {
	out := make([dynamic]Route_Sample, allocator)
	half :: f32(4)
	place :: proc(out: ^[dynamic]Route_Sample, x, z, nx, nz: f32) {
		append(out, Route_Sample{Centre={x,0,z}, Left={x-nx*half,0,z-nz*half}, Right={x+nx*half,0,z+nz*half}})
	}
	for z := f32(-200); z < 0; z += 5 { place(&out, 0, z, 1, 0) }
	for step in 0..=60 {
		angle := f32(step)*math.PI/180
		place(&out, radius*(1-math.cos(angle)), radius*math.sin(angle), math.cos(angle), -math.sin(angle))
	}
	// The exit straight has to leave on the arc's own tangent, or the join is a
	// sharper corner than the arc and the test measures that instead.
	end := out[len(out)-1].Centre
	exit := f32(60)*math.PI/180
	for step in 1..=40 {
		run := f32(step)*5
		place(&out, end[0]+run*math.sin(exit), end[2]+run*math.cos(exit), math.cos(exit), -math.sin(exit))
	}
	return out[:]
}

@(test)
dirt3_brake_speed_follows_the_corner_radius :: proc(t: ^testing.T) {
	for radius in ([]f32{40, 100, 180}) {
		line := d3_route_stations(test_arc_route(radius))
		gates := d3_ai_gate_distances(line[len(line)-1].distance)
		brakes := d3_brake_points(line, gates)
		testing.expectf(t, len(brakes) > 0, "radius %.0f found no corner", radius)
		want := D3_BRAKE_GRIP*math.sqrt(radius)
		for brake in brakes {
			testing.expectf(t, math.abs(brake.speed-want) < want*0.12,
				"radius %.0f: speed %.1f is not near %.1f", radius, brake.speed, want)
		}
	}
}

@(test)
dirt3_brake_points_stay_off_a_straight :: proc(t: ^testing.T) {
	route := make([]Route_Sample, 80, context.temp_allocator)
	for &sample, i in route {
		z := f32(i)*10
		sample = {Centre={0,0,z}, Left={-4,0,z}, Right={4,0,z}}
	}
	line := d3_route_stations(route)
	gates := d3_ai_gate_distances(line[len(line)-1].distance)
	testing.expect_value(t, len(d3_brake_points(line, gates)), 0)
}

@(test)
dirt3_brake_points_are_ordered_and_leave_room_for_a_hold_line :: proc(t: ^testing.T) {
	line := d3_route_stations(test_arc_route(60))
	gates := d3_ai_gate_distances(line[len(line)-1].distance)
	brakes := d3_brake_points(line, gates)
	previous := -1
	for brake in brakes {
		testing.expect(t, brake.gate > previous)
		testing.expect(t, brake.gate+1 < len(gates))
		previous = brake.gate
	}
}

@(test)
dirt3_ai_vehicle_track_matches_the_ai_track_brake_lines :: proc(t: ^testing.T) {
	line := d3_route_stations(test_arc_route(60))
	gates := d3_ai_gate_distances(line[len(line)-1].distance)
	brakes := d3_brake_points(line, gates)
	testing.expect(t, len(brakes) > 0)
	ai, aok := d3_ai_xml(line, gates, brakes, context.temp_allocator)
	vehicle, vok := d3_ai_vehicle_xml(brakes, context.temp_allocator)
	testing.expect(t, aok); testing.expect(t, vok)
	count := d3_i(len(brakes))
	testing.expect_value(t, test_bxml_attr(ai, "brake_lines", "num_brake_lines"), count)
	testing.expect_value(t, test_bxml_attr(ai, "hold_lines", "num_hold_lines"), count)
	testing.expect_value(t, test_bxml_attr(vehicle, "brake_lines", "num_brake_lines"), count)
	// Stock pairs the two files by brake-line id, and the first one anchors it.
	testing.expect_value(t, test_bxml_attr(ai, "brake_line", "id"), "0")
	testing.expect_value(t, test_bxml_attr(vehicle, "brake_line", "id"), "0")
	// min_speed is the drop applied to max_speed, in both files.
	speed := test_bxml_attr(ai, "brake_data", "max_speed")
	testing.expect_value(t, test_bxml_attr(vehicle, "brake_data", "max_speed"), speed)
	testing.expect(t, test_bxml_attr(ai, "brake_data", "min_speed") != speed)
}
