package main

// Procedural rally-stage generator.
//
// A stage is grown as a list of *route segments* (straight, sweeper, kink,
// esse, hairpin, crest), each carrying a turn, a grade, a bank and a width.
// Those are rasterised into dense per-metre curvature/grade/bank/width tracks,
// box-filtered so segment joins become blends rather than kinks, integrated
// into a centreline, and finally resampled into control points.
//
// The road frame at each control point is built the same way spline.odin does
// it (quat_from_frame): local +Z is travel, +Y is the surface normal. Positive
// yaw turns right, and a positive bank rolls the road *into* a right-hand turn,
// so turn and bank always share a sign. See gen_push_sample for the axis flip
// that makes that true.

import "core:c"
import "core:fmt"
import "core:math"
import "../gfx"
import "../geo"

GEN_DS :: 0.25         // integration step, metres of horizontal arc
GEN_SMOOTH_M :: 11.0   // box-filter width, metres. Small, so mini corners stay tight.
GEN_GROUND_CLEAR :: 2.0 // the stage's lowest point sits this far above y=0

// Layered soft-wall angle budget. Net heading wanders freely below SOFT. Across
// SOFT..HARD an ordinary corner's *outward* turn fades to nothing, so normal
// driving eases up to ~90 and floats there (below 90, cos(yaw) stays positive,
// +Z always advances, and the route cannot fold back over itself). Only a
// hairpin punches past HARD; once beyond it the direction bias is certain to
// steer home, coercing heading back under 90 over the next few corners without
// hard-clamping it. MAX is the single hard ceiling, so nothing runs away.
GEN_YAW_SOFT :: 60.0
GEN_YAW_HARD :: 90.0
GEN_YAW_MAX :: 190.0

// Camber is a cross-fall in metres, not an angle: a drop of half a metre reads
// the same on a wide road as on a narrow one, and a rally road barely cambers.
// CAMBER_TURN is the corner that earns the whole drop; anything sharper gets
// the same.
GEN_CAMBER_M :: 0.9
GEN_CAMBER_TURN :: 90.0

// Short-wavelength wander laid over the finished segments. Without it a segment
// is a dead-straight, dead-flat run, and a stage reads as a chain of arcs.
// Amplitudes are metres of offset at a knob of 1.
//
// The wavelengths are floored well above twice `spacing_m`. Anything shorter
// aliases when the centreline is resampled into control points, and a wave the
// points cannot carry comes out as a zigzag rather than a wiggle. Measured
// against a hand-driven stage, the humps that read as "short" are 4 to 8 points
// long, which is this band.
GEN_WIGGLE_WAVES :: 3
GEN_WIGGLE_M :: 7.0
GEN_WIGGLE_LAM :: [2]f32{100, 240}
GEN_BUMP_M :: 2.1
GEN_BUMP_LAM :: [2]f32{80, 190}
GEN_CALM_M :: 100.0 // the opening and closing straights stay flat and straight

Gen_Params :: struct {
	seed:      c.int,
	length_m:  f32, // target stage length
	spacing_m: f32, // distance between control points
	curviness: f32, // 0..1, scales every turn angle
	hilliness: f32, // 0..1, scales grades
	bank:      f32, // 0..1, scales banking
	hairpins:  f32, // 0..1, extra weight on hairpin segments
	width_min: f32,
	width_max: f32,
	// Share of each road edge that gets a side guard of this kind. See
	// gen_guard_shares: they are shares, not probabilities.
	guard_cliff:  f32,
	guard_bank:   f32,
	guard_gutter: f32,
}

GEN_DEFAULTS :: Gen_Params {
	seed      = 1337,
	length_m  = 3200,
	spacing_m = 24,
	curviness = 0.85,
	hilliness = 0.5,
	bank      = 0.7,
	hairpins  = 0.3,
	width_min = 7.5,
	width_max = 11.0,
	guard_cliff  = 0.15,
	guard_bank   = 0.30,
	guard_gutter = 0.35,
}

// --- route segments ---------------------------------------------------------

Gen_Seg :: struct {
	length:    f32,
	turn_deg:  f32, // + = right
	grade_pct: f32,
	bank_deg:  f32, // shares sign with turn_deg
	width:     f32,
}

// Camber follows the turn and stays tiny: a 90-degree corner drops one side of
// the road GEN_CAMBER_M at bank=1, which is under a metre however wide it is.
seg_bank :: proc(turn_deg, bank, width: f32) -> f32 {
	drop := clamp(turn_deg / GEN_CAMBER_TURN, -1, 1) * GEN_CAMBER_M * bank
	return math.to_degrees(math.atan2(drop, max(width, 1)))
}

// The single hard ceiling. All turns, hairpins included, obey it so heading can
// never run away; it is otherwise slack enough that a hairpin fits.
ceil_turn :: proc(yaw_sum, turn: f32) -> f32 {
	next := yaw_sum + turn
	if next > GEN_YAW_MAX {
		return GEN_YAW_MAX - yaw_sum
	}
	if next < -GEN_YAW_MAX {
		return -GEN_YAW_MAX - yaw_sum
	}
	return turn
}

// The soft wall for ordinary corners: the part of a turn that pushes heading
// further from centre fades to zero across SOFT..HARD, so normal driving glides
// up toward 90 and floats instead of being chopped. Turns heading back home are
// never damped. Hairpins skip this — they exist to breach it — and call
// ceil_turn directly.
soft_turn :: proc(yaw_sum, turn: f32) -> f32 {
	t := turn
	outward := yaw_sum != 0 && (yaw_sum > 0) == (t > 0)
	if outward {
		fade := clamp((GEN_YAW_HARD - abs(yaw_sum)) / (GEN_YAW_HARD - GEN_YAW_SOFT), 0, 1)
		t *= fade
	}
	return ceil_turn(yaw_sum, t)
}

// Build the route until it reaches `length_m`. Turn direction is biased against
// the heading accumulated so far, otherwise the stage spirals off in one
// direction instead of wandering.
gen_segments :: proc(p: Gen_Params, r: ^geo.Rng, allocator := context.temp_allocator) -> []Gen_Seg {
	segs := make([dynamic]Gen_Seg, allocator)
	total: f32 = 0
	yaw_sum: f32 = 0 // degrees of net turning so far
	grade: f32 = 0   // grades random-walk rather than jumping

	// Segment picking weights. Hairpins are the only one the user dials.
	w_straight :: 0.20
	w_sweeper :: 0.30
	w_kink :: 0.14
	w_esse :: 0.16
	w_crest :: 0.10

	// Background grade is a *mean-reverting* walk with a small step and a low cap,
	// so elevation wanders gently instead of drifting into one long slope. The
	// discrete "one-shot" hills come from crest segments, not from this.
	next_grade := proc(r: ^geo.Rng, grade, hilliness: f32) -> f32 {
		lim := 5 * hilliness
		g := grade * 0.85 + geo.rng_range(r, -1.5, 1.5) * hilliness
		return clamp(g, -lim, lim)
	}

	// +1 or -1. Mean-reverting: at centre it is a coin flip, and by HARD it is
	// certain to steer back. Past HARD (only a hairpin gets there) it stays
	// pinned homeward, so the overshoot is walked back rather than compounded.
	turn_sign := proc(r: ^geo.Rng, yaw_sum: f32) -> f32 {
		toward_centre: f32 = yaw_sum > 0 ? -1 : 1
		p_centre := 0.5 + 0.5 * clamp(abs(yaw_sum) / GEN_YAW_HARD, 0, 1)
		return geo.rng_unit(r) < p_centre ? toward_centre : -toward_centre
	}

	add := proc(
		segs: ^[dynamic]Gen_Seg,
		total, yaw_sum: ^f32,
		length, turn_deg, grade_pct, width, bank: f32,
	) {
		append(segs, Gen_Seg{
			length    = length,
			turn_deg  = turn_deg,
			grade_pct = grade_pct,
			bank_deg  = seg_bank(turn_deg, bank, width),
			width     = width,
		})
		total^ += length
		yaw_sum^ += turn_deg
	}

	// The opening straight gives the car (and the camera) somewhere to start.
	add(&segs, &total, &yaw_sum, 140, 0, 1, p.width_max, p.bank)

	// Scales straight off the knob rather than off a base weight, so hairpins=0
	// really means no hairpins. They ignore `curviness` by design: a hairpin
	// that gets gentler is a sweeper, and there is already a sweeper.
	w_hairpin := p.hairpins * 0.6
	w_total := w_straight + w_sweeper + w_kink + w_esse + w_crest + w_hairpin

	for total < p.length_m {
		pick := geo.rng_unit(r) * w_total
		sign := turn_sign(r, yaw_sum)
		grade = next_grade(r, grade, p.hilliness)

		switch {
		case pick < w_straight:
			add(&segs, &total, &yaw_sum, geo.rng_range(r, 70, 150), 0, grade, p.width_max, p.bank)

		case pick < w_straight + w_sweeper:
			turn := soft_turn(yaw_sum, sign * geo.rng_range(r, 25, 60) * p.curviness)
			w := geo.rng_range(r, (p.width_min + p.width_max) * 0.5, p.width_max)
			add(&segs, &total, &yaw_sum, geo.rng_range(r, 55, 120), turn, grade, w, p.bank)

		case pick < w_straight + w_sweeper + w_kink:
			turn := soft_turn(yaw_sum, sign * geo.rng_range(r, 12, 30) * p.curviness)
			add(&segs, &total, &yaw_sum, geo.rng_range(r, 40, 75), turn, grade, p.width_max, p.bank)

		case pick < w_straight + w_sweeper + w_kink + w_esse:
			// A left-right (or right-left) pair, tight and narrow.
			n := int(geo.rng_range(r, 2, 4.99)) // 2..4 changes of direction
			w := geo.rng_range(r, p.width_min, (p.width_min + p.width_max) * 0.5)
			for i in 0 ..< n {
				s := (i % 2 == 0) ? sign : -sign
				turn := soft_turn(yaw_sum, s * geo.rng_range(r, 25, 55) * p.curviness)
				add(&segs, &total, &yaw_sum, geo.rng_range(r, 40, 75), turn, grade, w, p.bank)
			}

		case pick < w_straight + w_sweeper + w_kink + w_esse + w_crest:
			// Up and straight back down: a short, one-shot hill you can land.
			g := geo.rng_range(r, 4, 7) * p.hilliness
			half := geo.rng_range(r, 45, 80)
			add(&segs, &total, &yaw_sum, half, 0, g, p.width_max, p.bank)
			add(&segs, &total, &yaw_sum, half, 0, -g, p.width_max, p.bank)
			grade = -g

		case:
			// A real hairpin: tight, narrow, banked hard, and deliberately
			// allowed to breach the soft wall past 90. `sign` is mean-reverting,
			// so when heading is already off-centre the hairpin reverses toward
			// home; the certain-homeward bias then coerces the overshoot back.
			turn := ceil_turn(yaw_sum, sign * geo.rng_range(r, 140, 180))
			add(&segs, &total, &yaw_sum, geo.rng_range(r, 75, 120), turn, grade * 0.5, p.width_min, p.bank)
		}
	}

	// Flatten out and straighten for the finish line.
	add(&segs, &total, &yaw_sum, 180, 0, 0, p.width_max, p.bank)
	return segs[:]
}

// --- rasterise, smooth, integrate -------------------------------------------

// Box filter via prefix sums: O(n) rather than O(n*window), because the
// generator reruns every frame while a slider is being dragged.
box_filter :: proc(xs: []f32, width_m: f32) {
	n := len(xs)
	if n == 0 {
		return
	}
	half := max(1, int(width_m / GEN_DS / 2))

	sums := make([]f32, n + 1, context.temp_allocator)
	for i in 0 ..< n {
		sums[i + 1] = sums[i] + xs[i]
	}
	for i in 0 ..< n {
		lo := max(0, i - half)
		hi := min(n, i + half + 1)
		xs[i] = (sums[hi] - sums[lo]) / f32(hi - lo)
	}
}

// A band-limited wiggle: a few sines of random wavelength and phase. `amp` is
// metres of *offset*, so one wave set reads as a lateral wander or a vertical
// bump depending on which derivative the caller asks for.
Gen_Wave :: struct {
	k, phase, amp: f32,
}

gen_waves :: proc(r: ^geo.Rng, amp_m: f32, lam: [2]f32) -> (ws: [GEN_WIGGLE_WAVES]Gen_Wave) {
	for i in 0 ..< GEN_WIGGLE_WAVES {
		ws[i] = Gen_Wave {
			k     = math.TAU / geo.rng_range(r, lam[0], lam[1]),
			phase = geo.rng_range(r, 0, math.TAU),
			amp   = amp_m / GEN_WIGGLE_WAVES,
		}
	}
	return
}

// d/ds of the offset: what a vertical wiggle adds to grade.
gen_wave_slope :: proc(ws: [GEN_WIGGLE_WAVES]Gen_Wave, s: f32) -> (v: f32) {
	for w in ws {
		v += w.amp * w.k * math.cos(w.k * s + w.phase)
	}
	return
}

// d2/ds2 of the offset: what a lateral wiggle adds to curvature.
gen_wave_curv :: proc(ws: [GEN_WIGGLE_WAVES]Gen_Wave, s: f32) -> (v: f32) {
	for w in ws {
		v -= w.amp * w.k * w.k * math.sin(w.k * s + w.phase)
	}
	return
}

Gen_Sample :: struct {
	pos:   gfx.Vector3,
	yaw:   f32,
	grade: f32,
	bank:  f32,
	width: f32,
}

// Rasterise the segments to one sample per GEN_DS, smooth, and walk the result.
gen_centreline :: proc(
	segs: []Gen_Seg,
	p: Gen_Params,
	r: ^geo.Rng,
	allocator := context.temp_allocator,
) -> []Gen_Sample {
	steps := 0
	for s in segs {
		steps += max(1, int(math.round(s.length / GEN_DS)))
	}
	curv := make([]f32, steps, context.temp_allocator)
	grade := make([]f32, steps, context.temp_allocator)
	bank := make([]f32, steps, context.temp_allocator)
	width := make([]f32, steps, context.temp_allocator)

	i := 0
	for s in segs {
		n := max(1, int(math.round(s.length / GEN_DS)))
		k := math.to_radians(s.turn_deg) / s.length // radians per metre
		for _ in 0 ..< n {
			curv[i] = k
			grade[i] = s.grade_pct / 100
			bank[i] = math.to_radians(s.bank_deg)
			width[i] = s.width
			i += 1
		}
	}

	// Parenthesised: in a `for ... in` header a bare `{` starts the body.
	for arr in ([][]f32{curv, grade, bank, width}) {
		box_filter(arr, GEN_SMOOTH_M)
	}

	// The wiggle goes on *after* the box filter, which is wider than the
	// shortest wave and would otherwise flatten it back out. Both bands are
	// zero-mean, so neither walks the heading or the height anywhere.
	wig := gen_waves(r, GEN_WIGGLE_M * p.curviness, GEN_WIGGLE_LAM)
	bump := gen_waves(r, GEN_BUMP_M * p.hilliness, GEN_BUMP_LAM)
	run := f32(steps) * GEN_DS
	for j in 0 ..< steps {
		s := f32(j) * GEN_DS
		calm := min(
			math.smoothstep(f32(0), GEN_CALM_M, s),
			math.smoothstep(f32(0), GEN_CALM_M, run - s),
		)
		curv[j] += gen_wave_curv(wig, s) * calm
		grade[j] += gen_wave_slope(bump, s) * calm
	}

	out := make([]Gen_Sample, steps, allocator)
	pos := gfx.Vector3{}
	yaw: f32 = 0
	for j in 0 ..< steps {
		out[j] = Gen_Sample{pos = pos, yaw = yaw, grade = grade[j], bank = bank[j], width = width[j]}
		yaw += curv[j] * GEN_DS
		pos += {math.sin(yaw) * GEN_DS, grade[j] * GEN_DS, math.cos(yaw) * GEN_DS}
	}
	return out
}

// --- side guards -------------------------------------------------------------

GEN_GUARD_RUN_M :: 72.0  // the plateau one generated guard holds
GEN_GUARD_TAPER :: 16.0  // metres in and out of that plateau

// The three weights, read as the share of one road edge each kind covers.
// Shares, not probabilities: at 1/1/1 they take a third each and the edge is
// covered end to end. Under a total of 1 whatever is left over is bare verge.
gen_guard_shares :: proc(p: Gen_Params) -> (out: [geo.Guard_Kind]f32) {
	out = {
		.Cliff  = clamp(p.guard_cliff, 0, 1),
		.Bank   = clamp(p.guard_bank, 0, 1),
		.Gutter = clamp(p.guard_gutter, 0, 1),
	}
	total: f32
	for w in out {
		total += w
	}
	if total > 1 {
		for &w in out {
			w /= total
		}
	}
	return
}

// Tile each edge with runs of GEN_GUARD_RUN_M and deal the kinds out at their
// shares. Spans overlap by a taper at each end, so two runs of the same kind
// union into one long guard instead of pinching to nothing between them (see
// geo.resolve_guards, which takes the largest contribution).
//
// Every guard carries guard_make's defaults for its own shape. The generator
// decides *where* the guards go and nothing else: their height, width and
// roughness are the inspector's job, one guard at a time.
gen_guards :: proc(sp: ^geo.Spline, p: Gen_Params, r: ^geo.Rng) {
	clear(&sp.guards)
	run := max(2, int(math.round(GEN_GUARD_RUN_M / max(p.spacing_m, 1))))
	blocks := (len(sp.points) - 1) / run
	if blocks <= 0 {
		return
	}
	shares := gen_guard_shares(p)
	span := f32(run) * p.spacing_m + 2 * GEN_GUARD_TAPER

	// One slot per run. `nil` is bare verge, which is what the shares do not
	// account for.
	slots := make([]Maybe(geo.Guard_Kind), blocks, context.temp_allocator)
	for side in 0 ..< 2 {
		i := 0
		for kind in geo.Guard_Kind {
			n := min(int(math.round(shares[kind] * f32(blocks))), blocks - i)
			for _ in 0 ..< n {
				slots[i] = kind
				i += 1
			}
		}
		for ; i < blocks; i += 1 {
			slots[i] = nil
		}
		// Fisher-Yates. The counts are what the shares promise; the shuffle is
		// what stops all the gutters landing at the start line.
		for j := blocks - 1; j > 0; j -= 1 {
			k := int(geo.rng_unit(r) * f32(j + 1))
			slots[j], slots[k] = slots[k], slots[j]
		}
		for b in 0 ..< blocks {
			kind, ok := slots[b].?
			if !ok {
				continue
			}
			g := geo.guard_make(kind, side, b * run + run / 2)
			g.span, g.taper = span, GEN_GUARD_TAPER
			geo.guard_add(sp, g)
		}
	}
}

// --- the generator -----------------------------------------------------------

// One sample as a control point, frame and all.
gen_push_sample :: proc(sp: ^geo.Spline, s: Gen_Sample, lift: f32) {
	fwd := gfx.Vector3Normalize({math.sin(s.yaw), s.grade, math.cos(s.yaw)})
	// Bank rolls the surface normal about the travel direction. Rotating +Y
	// about +Z by a positive angle tilts the normal toward -X, so the sign flips
	// here: a right-hand turn (+yaw, +bank) has to lean the normal to +X, into
	// the corner, not out of it.
	up := gfx.Vector3RotateByAxisAngle({0, 1, 0}, fwd, -s.bank)
	pos := s.pos + {0, lift, 0}
	geo.spline_push(sp, geo.make_point(pos, geo.quat_from_frame(fwd, up), s.width, parent = len(sp.points) - 1))
}

// Replace `sp`'s points with a freshly generated stage. Returns a status line.
generate_stage :: proc(sp: ^geo.Spline, p: Gen_Params) -> (msg: string, ok: bool) {
	r := geo.rng_init(p.seed)
	segs := gen_segments(p, &r)
	line := gen_centreline(segs, p, &r)
	if len(line) < 2 {
		return "generator produced nothing", false
	}

	stride := max(1, int(math.round(p.spacing_m / GEN_DS)))

	// Lift the whole stage so its lowest point clears the ground plane.
	lowest := line[0].pos.y
	for s in line {
		lowest = min(lowest, s.pos.y)
	}
	lift := GEN_GROUND_CLEAR - lowest

	clear(&sp.points)
	for j := 0; j < len(line); j += stride {
		gen_push_sample(sp, line[j], lift)
	}
	// Always finish on the true end of the route, not a stride short of it.
	if (len(line) - 1) % stride != 0 {
		gen_push_sample(sp, line[len(line) - 1], lift)
	}

	gen_guards(sp, p, &r)

	length := f32(len(line)) * GEN_DS
	return fmt.tprintf(
		"generated %d points, %.0f m, %d guards",
		len(sp.points), length, len(sp.guards),
	), true
}

// Frame the camera on a freshly generated stage, so it is never off-screen.
frame_spline :: proc(oc: ^Orbit_Camera, sp: geo.Spline) {
	if len(sp.points) == 0 {
		return
	}
	lo := sp.points[0].xform.translation
	hi := lo
	for p in sp.points {
		t := p.xform.translation
		lo = {min(lo.x, t.x), min(lo.y, t.y), min(lo.z, t.z)}
		hi = {max(hi.x, t.x), max(hi.y, t.y), max(hi.z, t.z)}
	}
	oc.target = (lo + hi) * 0.5
	extent := gfx.Vector3Length(hi - lo)
	oc.distance = clamp(extent * 0.75, 5, 800)
}
