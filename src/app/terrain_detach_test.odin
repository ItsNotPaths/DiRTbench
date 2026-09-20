package main

import "core:testing"
import "../geo"
import "../gfx"

// A flat straight road with no guards, so the seam is the bare road edge and
// anything that moved it moved because of detachment.
@(private = "file")
detach_ribbon :: proc(o: geo.Detach_Opts, count := 8) -> []geo.Cross_Section {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * 40}
		geo.spline_push(&sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
	return geo.build_ribbon(sp, 14, context.temp_allocator, o)
}

// Detachment is built into the verge, so the seam the terrain welds to is what
// moves: out by the run, down by the fall.
@(test)
detach_moves_the_verge_seam :: proc(t: ^testing.T) {
	off := detach_ribbon({})
	on := detach_ribbon({min_m = 0.75, max_m = 0.75})
	testing.expect(t, len(off) == len(on) && len(off) > 0, "ribbons did not match")

	for cs, i in off {
		for side in 0 ..< 2 {
			a := geo.verge_seam(cs, side, 0)
			b := geo.verge_seam(on[i], side, 0)
			// Off, the seam is the bare road edge and no row displaces it.
			testing.expect_value(t, a.y, f32(0))
			testing.expect(t, abs(b.y+0.75) < 1e-5, "the seam did not fall by the knob")
			// Out by the run, measured across the road.
			out := geo.terrain_outward(cs, side)
			moved := (b.x-a.x)*out.x + (b.z-a.z)*out.z
			testing.expect(t, abs(moved-geo.DETACH_RUN) < 1e-4, "the seam did not step out by the run")
		}
	}
}

// Negative is a lip of ground along the road edge: the same step, climbing.
@(test)
detach_negative_raises_the_seam :: proc(t: ^testing.T) {
	on := detach_ribbon({min_m = -0.5, max_m = -0.5})
	testing.expect(t, len(on) > 0, "no ribbon")
	testing.expect(t, abs(geo.verge_seam(on[0], 0, 0).y-0.5) < 1e-5, "the seam did not rise")
}

// A swoop that passes through zero metres must not step the seam sideways: the
// run is what the profile gates on, not the fall.
@(test)
detach_holds_its_run_through_zero :: proc(t: ^testing.T) {
	on := detach_ribbon({min_m = -0.6, max_m = 0.6}, 40)
	crossed := false
	for cs, i in on {
		if i > 0 && (cs.detach_fall > 0) != (on[i - 1].detach_fall > 0) {
			crossed = true
		}
		testing.expect_value(t, cs.detach_run, f32(geo.DETACH_RUN))
	}
	testing.expect(t, crossed, "the swoop never crossed zero, so the case went untested")
}

// The ground beside a detached road is still ground beside a bare road edge, so
// it keeps the road's own texture. A guard is what stops that, not the step.
@(test)
detach_is_not_a_guard :: proc(t: ^testing.T) {
	on := detach_ribbon({min_m = 0.75, max_m = 0.75})
	prof := geo.verge_profile(on[0], 0)
	testing.expect(t, prof.any, "the sweep must emit the step")
	testing.expect(t, !prof.guarded, "a step is not a guard")
}

// The swoop has to move along a stage, stay inside the knobs, and answer the
// same everywhere for one spot — a fork's two branches must let go together.
@(test)
detach_swoop_varies_and_stays_in_range :: proc(t: ^testing.T) {
	o := geo.Detach_Opts{min_m = 0, max_m = 0.75}
	lo, hi := max(f32), min(f32)
	for i in 0 ..< 4000 {
		p := [2]f32{f32(i) * 3.7, f32(i) * -2.3}
		m := geo.detach_at(o, p)
		lo, hi = min(lo, m), max(hi, m)
	}
	testing.expect(t, lo >= 0 && hi <= 0.75, "the swoop left the knobs")
	testing.expect(t, hi-lo > 0.5, "the swoop barely moved across 14 km of road")

	p := [2]f32{412.5, -87.25}
	testing.expect_value(t, geo.detach_at(o, p), geo.detach_at(o, p))
	// Smooth, not stepped: two spots a metre apart on a 150 m wave.
	near := geo.detach_at(o, {p[0] + 1, p[1]})
	testing.expect(t, abs(near-geo.detach_at(o, p)) < 0.05, "the swoop steps")
}

// Off costs nothing: every profile point stays where the guards left it, and the
// detach segment's row lands on the one before it.
@(test)
detach_off_is_the_identity :: proc(t: ^testing.T) {
	off := detach_ribbon({})
	prof := geo.verge_profile(off[0], 0)
	testing.expect(t, !prof.any, "a bare edge with no detachment has no verge")
	testing.expect_value(t, prof.pts[geo.VERGE_PTS - 1], prof.pts[geo.VERGE_PTS - 2])
}

// Two edges into one node must let go of the ground by the same amount, and at
// a junction that amount is nothing: the branch's verge would otherwise fall
// away across the mouth of the road it just left.
@(test)
detach_flattens_at_a_fork :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	push :: proc(sp: ^geo.Spline, x, z: f32, parent: int) {
		geo.spline_push(sp, geo.make_point({x, 0, z}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = parent))
	}
	// A trunk up +z, forking at point 3 into two branches that splay apart.
	for i in 0 ..< 4 {
		push(&sp, 0, f32(i) * 40, i - 1)
	}
	push(&sp, -40, 180, 3) // branch A, a second child of 3
	push(&sp, -80, 220, 4)
	push(&sp, 40, 180, 3) // branch B
	push(&sp, 80, 220, 6)

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator, {min_m = 0.75, max_m = 0.75})
	testing.expect(t, len(ribbon) > 0, "no ribbon")

	node := gfx.Vector3{0, 0, 120} // point 3, where all three edges meet
	legs, far := 0, 0
	for cs in ribbon {
		d := gfx.Vector3Distance(cs.pos, node)
		if d < 1 {
			legs += 1
			testing.expect(t, abs(cs.detach_fall) < 1e-3, "the fork did not flatten")
		}
		// Well clear of the fork and of both branch ends, the swoop is intact.
		if d > geo.DETACH_JOIN_M + 20 && cs.detach_fall > 0.7 {
			far += 1
		}
	}
	testing.expect(t, legs >= 3, "the three edges into the fork were not all sampled")
	testing.expect(t, far > 0, "the fade swallowed the whole road")

	// And it lets go smoothly. Samples are ~2.9 m apart and smoothstep's
	// steepest point is 1.5/DETACH_JOIN_M, so 0.75 m of fall moves at most
	// ~0.14 per sample. A real step at the edge of the fade would be the whole
	// 0.75, so this separates the two with room to spare.
	for cs, i in ribbon {
		if i == 0 || cs.break_before {
			continue
		}
		testing.expect(t, abs(cs.detach_fall-ribbon[i-1].detach_fall) < 0.25, "the fade steps")
	}
}

// Every sample of a weld's two ends flattens too. A weld is the edge the parent
// tree cannot express, so degree alone would miss it.
@(test)
detach_flattens_at_a_weld :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	for i in 0 ..< 6 {
		geo.spline_push(&sp, geo.make_point({0, 0, f32(i) * 40}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
	sp.points[5].weld = 0 // close the loop

	ribbon := geo.build_ribbon(sp, 14, context.temp_allocator, {min_m = 0.75, max_m = 0.75})
	for cs in ribbon {
		for node in ([]gfx.Vector3{{0, 0, 0}, {0, 0, 200}}) {
			if gfx.Vector3Distance(cs.pos, node) < 1 {
				testing.expect(t, abs(cs.detach_fall) < 1e-3, "a weld end did not flatten")
			}
		}
	}
}
