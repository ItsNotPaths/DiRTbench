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

// The three weights are shares of one road edge. What the slider says is what
// the generated guards cover, measured back off the ribbon rather than off the
// counts the placer used.
//
// Counted on the plateau, not on "any size at all": neighbouring runs overlap
// by a taper so they blend instead of butting, and a slice inside that overlap
// is under two kinds at once.
@(test)
generated_guard_shares_land_as_coverage :: proc(t: ^testing.T) {
	measure :: proc(p: Gen_Params) -> (share: [geo.Guard_Kind]f32, bare: f32) {
		sp: geo.Spline
		defer geo.spline_free(&sp)
		if _, ok := generate_stage(&sp, p); !ok {
			return
		}
		ribbon := geo.build_ribbon(sp)
		full: [geo.Guard_Kind]int
		none := 0
		for cs in ribbon {
			guarded := false
			for kind in geo.Guard_Kind {
				size := cs.verge[0][kind].size
				guarded ||= size > 0
				if size >= geo.guard_make(kind, 0, 0).size {
					full[kind] += 1
				}
			}
			if !guarded {
				none += 1
			}
		}
		n := f32(max(len(ribbon), 1))
		for kind in geo.Guard_Kind {
			share[kind] = f32(full[kind]) / n
		}
		return share, f32(none) / n
	}

	p := GEN_DEFAULTS
	p.guard_cliff, p.guard_bank, p.guard_gutter = 0, 0, 0.3
	one, bare := measure(p)
	testing.expectf(t, abs(one[.Gutter] - 0.3) < 0.08,
		"asked for 30%% gutter, got %.0f%%", one[.Gutter] * 100)
	testing.expect_value(t, one[.Cliff], f32(0))
	testing.expect_value(t, one[.Bank], f32(0))
	testing.expectf(t, bare > 0.5, "30%% gutter left only %.0f%% bare verge", bare * 100)

	// All three at 1 is a third each, and nowhere on the edge is left bare.
	p.guard_cliff, p.guard_bank, p.guard_gutter = 1, 1, 1
	full: f32
	share: [geo.Guard_Kind]f32
	share, bare = measure(p)
	for kind in geo.Guard_Kind {
		testing.expectf(t, abs(share[kind] - 1.0 / 3) < 0.08,
			"%v took %.0f%% of the edge, not a third", kind, share[kind] * 100)
		full += share[kind]
	}
	testing.expectf(t, full > 0.95, "the three only fill %.0f%% of the edge", full * 100)
	testing.expect_value(t, bare, f32(0))

	// No weights, no guards — and none left over from the last road either.
	p.guard_cliff, p.guard_bank, p.guard_gutter = 0, 0, 0
	sp: geo.Spline
	defer geo.spline_free(&sp)
	generate_stage(&sp, GEN_DEFAULTS)
	generate_stage(&sp, p)
	testing.expect_value(t, len(sp.guards), 0)
}
