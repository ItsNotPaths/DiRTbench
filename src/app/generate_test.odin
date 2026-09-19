package main

import "core:math"
import "core:testing"
import "../geo"

// The whole point of camber: the road has to lean *into* a corner. Checked on
// the built frame rather than on seg_bank, because the sign that used to be
// wrong was the one in the axis-angle roll, not the one in the angle.
@(test)
generated_camber_leans_into_the_corner :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	// Heading due +Z, so world +X is the road's right and a right-hand corner
	// has to tilt the surface normal that way.
	gen_push_sample(&sp, Gen_Sample{bank = math.to_radians(f32(5)), width = 8}, 0)
	gen_push_sample(&sp, Gen_Sample{bank = math.to_radians(f32(-5)), width = 8}, 0)

	right := geo.point_up(sp.points[0]).x
	left := geo.point_up(sp.points[1]).x
	testing.expectf(t, right > 0.05, "a right-hand bank leaned %.3f, not into the corner", right)
	testing.expectf(t, left < -0.05, "a left-hand bank leaned %.3f, not into the corner", left)
}

// Camber is a cross-fall of under a metre, not a banked oval. The angle is the
// wrong thing to bound: a narrow hairpin and a wide sweeper have to agree in
// metres, which is what a car feels.
@(test)
generated_camber_stays_under_a_metre :: proc(t: ^testing.T) {
	p := GEN_DEFAULTS
	p.bank = 1
	for turn in ([]f32{5, 45, 90, 180, -180}) {
		for width in ([]f32{p.width_min, p.width_max}) {
			deg := seg_bank(turn, p.bank, width)
			drop := math.tan(math.to_radians(deg)) * width
			testing.expectf(t, abs(drop) <= GEN_CAMBER_M + 1e-4,
				"turn %.0f at %.1f m drops %.2f m", turn, width, drop)
		}
	}
}

// Without the wiggle a straight segment is exactly straight and exactly flat.
// With it the road wanders by metres, which is what the hand-driven stages look
// like and what the segments alone never produce.
@(test)
generated_road_wiggles_on_the_straights :: proc(t: ^testing.T) {
	segs := []Gen_Seg{{length = 600, width = 10}}
	r := geo.rng_init(7)
	p := GEN_DEFAULTS
	line := gen_centreline(segs, p, &r)
	testing.expect(t, len(line) > 100)

	max_yaw, max_grade: f32
	for s in line {
		max_yaw = max(max_yaw, abs(s.yaw))
		max_grade = max(max_grade, abs(s.grade))
	}
	testing.expectf(t, max_yaw > math.to_radians(f32(4)),
		"straight only wandered %.1f degrees", math.to_degrees(max_yaw))
	testing.expectf(t, max_grade > 0.02, "straight only rose %.1f%%", max_grade * 100)

	// Zero knobs mean zero wiggle, so a flat stage is still available.
	p.curviness, p.hilliness = 0, 0
	r = geo.rng_init(7)
	for s in gen_centreline(segs, p, &r) {
		testing.expect(t, s.yaw == 0 && s.grade == 0)
	}
}
