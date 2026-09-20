package geo

// Pace-note generation: spline ribbon -> a stream of co-driver calls.
//
// Structured as a small compiler front-end:
//   lex    — walk the ribbon, maximal-munch runs of "cornering" into corner
//            tokens (hysteresis on radius; a curvature sign flip forces a break,
//            which is how an esse splits into two corners). Elevation extrema lex
//            into crest/dip/jump.
//   parse  — turn tokens into calls with a little lookahead: the link word
//            (into/and) and the distance-filler call are both decided by the gap
//            to the *next* corner. `long`/`tightens`/`opens` are attributes read
//            off the corner's own shape, no lookahead.
//   codegen— each call fires at  feature_arc - lead.  (Scheduling of overlapping
//            calls, and clip tiling, live on the player side — this is pure.)
//
// Everything reads from geometry you already have: `ribbon_curvature` (signed,
// +ve = a right-hander), `ribbon_arc`, and `pos.y` for elevation. Deterministic.
//
// Severity convention (user): 1 = tight .. 6 = flat, hairpin below 1. `square` is
// a ~90 deg corner, reserved (near-architected intersection) — rare on our tracks.
// The recorded VO tops out at 6 (six synthesized from "sixty").

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../gfx"

Pace_Kind :: enum u8 {
	Corner,
	Distance,
	Crest,
	Dip,
	Jump,
	Hectic, // a chaotic straight: rapid little kinks, no single called corner
}

// Display word for a hectic section. There isn't one universal rally term (co-
// drivers improvise: "twisty", "jinky", "rough over bumps"); this is a placeholder
// to rename to taste. It is voiced as a `caution` (scaled to double/triple), the
// nearest thing the recorded VO actually has.
HECTIC_WORD :: "twisty"

Pace_Dir :: enum u8 {
	None,
	Left,
	Right,
}

// A link word spoken *before* this call, joining it to the previous one. Our VO
// carries these pre-attached ("into-hairpin-left"), so it is the following call
// that owns the link.
Pace_Link :: enum u8 {
	None,
	Into,
	And,
}

Pace_Mod :: enum u8 {
	Long,
	Tightens,
	Opens,
}

Pace_Note :: struct {
	station: f32, // arc where the call FIRES = feature_at - lead
	at:      f32, // the feature itself (corner entry / crest apex / straight start)
	kind:    Pace_Kind,
	dir:     Pace_Dir,
	sev:     int, // Corner: 0 = hairpin, 1..6 ; ignored otherwise
	square:  bool, // Corner: overrides sev for a ~90 deg call
	link:    Pace_Link,
	mods:    bit_set[Pace_Mod],
	dist:    int, // Distance: metres (rounded to the recorded 40..200 ladder)
	// Corner: the tightest radius measured, in metres, and the angle swept.
	// What `sev` was decided from, carried so a call can be checked against the
	// road it was made for without re-deriving anything.
	radius:  f32,
	sweep:   f32,
}

// All the tuning knobs. Radii are in metres, angles in degrees.
//
// The defaults are no longer a guess. They are fitted against DiRT 3's own
// calls: every stock route says what it calls and where, so `tools/pacenote_fit.py`
// searches these until our notes agree with the game's. Fitted on finland,
// norway and michigan (24 routes) and checked on monte carlo, kenya, monaco,
// aspen and smelter (22 routes it never saw).
Pace_Params :: struct {
	smooth_m:   f32,     // curvature box-filter window (~a car length)
	r_on:       f32,     // enter a corner when radius drops below this
	r_off:      f32,     // leave it when radius rises above this (hysteresis)
	sev_r:      [7]f32,  // radius bands, kept for reporting; see pace_sev
	sev_deg:    [7]f32,  // lower swept-angle bound of [hairpin,1,2,3,4,5,6]
	square_tol: f32,     // within this many deg of 90 (and mid severity) -> square
	min_sweep:  f32,     // a corner sweeping less than this is not called at all
	long_deg:   f32,     // swept angle above this -> "long"
	tighten:    f32,     // exit-third radius this fraction under entry-third -> tightens
	into_m:     f32,     // straight <= this before a corner -> "into"
	and_m:      f32,     // straight <= this -> "and" (a flick)
	dist_min_m: f32,     // straight >= this with no link -> a spoken distance
	lead_m:     f32,     // how far before the feature the call fires
	crest_k:    f32,     // |vertical curvature| (1/m) to call a crest/dip
	jump_grade: f32,     // downslope right after a crest to promote it to a jump
	feat_gap_m: f32,     // min arc between elevation features (dedupe)

	// Hectic ("twisty") detection: a window with at least `hectic_flicks` curvature
	// sign changes and mean |curvature| over `hectic_amp` is a chaotic straight.
	hectic_win_m:     f32,
	hectic_flicks:    int,
	hectic_amp:       f32,
	hectic_min_len_m: f32,
}

PACE_DEFAULTS :: Pace_Params {
	smooth_m   = 4,
	r_on       = 160,
	r_off      = 390,
	// The bands are narrow at the tight end and wide at 4 on purpose, and it is
	// not overfitting: restoring the old even spread costs grade error 1.06 ->
	// 1.84 and exact agreement 0.28 -> 0.06 on venues the fit never saw. With
	// an even spread we call almost everything tighter than the game does.
	sev_r      = {18, 21, 24, 30, 89, 160, 220},
	// Read off the game's own calls: the median swept angle it gives to a
	// hairpin, 2, 3, 4, 5 and 6 is 154, 82, 77, 57, 51 and 44 degrees.
	sev_deg    = {143, 140, 134, 86, 54, 47, 0},
	square_tol = 12,
	// The game does not name a bend this slight. Without a floor we called
	// 8-degree kinks and emitted 12.1 calls/km against its 7.0.
	min_sweep  = 28,
	long_deg   = 90,
	tighten    = 0.25,
	into_m     = 30,
	and_m      = 8,
	// 26% of everything the game says is a distance. At 60 we emit half that;
	// the fit raised it and nothing in the objective noticed until the notes
	// were read out loud.
	dist_min_m = 40,
	lead_m     = 95,
	crest_k    = 0.008,
	jump_grade = 0.14,
	feat_gap_m = 15,
	hectic_win_m     = 80,
	hectic_flicks    = 3,
	hectic_amp       = 0.004,
	hectic_min_len_m = 25,
}

@(private = "file")
radius :: proc(k: f32) -> f32 {
	a := abs(k)
	return a < 1e-6 ? 1e9 : 1.0 / a
}

// Box-filter curvature over `win` metres of arc. Hermite is only C1 across control
// points, so raw k steps at every node — smoothing kills the phantom tightens/opens
// that would otherwise appear there.
@(private = "file")
pace_smooth :: proc(k, arc: []f32, win: f32, allocator := context.temp_allocator) -> []f32 {
	n := len(k)
	out := make([]f32, n, allocator)
	half := win * 0.5
	for i in 0 ..< n {
		lo := arc[i] - half
		hi := arc[i] + half
		sum, wsum: f32
		for j := i; j >= 0 && arc[j] >= lo; j -= 1 {
			sum += k[j]; wsum += 1
		}
		for j := i + 1; j < n && arc[j] <= hi; j += 1 {
			sum += k[j]; wsum += 1
		}
		out[i] = wsum > 0 ? sum / wsum : k[i]
	}
	return out
}

// How sharp a corner is called: 0 = hairpin, 1..6, from how far it turns.
//
// **Radius does not decide this, and that is measured, not assumed.** Over 894
// stock calls the game's 3, 4, 5 and 6 sit at 31, 36, 43 and 44 m of radius —
// no separation at all — while their swept angles are 77, 57, 51 and 44
// degrees. Grading on radius, or on the tighter of radius and angle, calls the
// game's 6 about a 4; grading on angle alone moves exact agreement from 0.37
// to 0.48 on venues the fit never saw.
//
// `sev_r` survives for the radius the note carries, which the exporter and the
// inspector both show. Nothing reads it to pick a grade.
@(private = "file")
pace_sev :: proc(swept_deg: f32, pp: Pace_Params) -> int {
	for i in 0 ..< 7 {
		if swept_deg >= pp.sev_deg[i] {
			return i
		}
	}
	return 6
}

// Per-sample mask of "hectic" road: within a window, many curvature sign changes
// (each with real amplitude) and a decent mean |curvature| — a chaotic straight,
// not a sustained corner (which has no sign changes) nor dead-straight noise.
@(private = "file")
pace_hectic_mask :: proc(arc, ks: []f32, pp: Pace_Params, allocator := context.temp_allocator) -> []bool {
	n := len(ks)
	mask := make([]bool, n, allocator)
	half := pp.hectic_win_m * 0.5

	// Per-sample flip count: real direction changes in the window. `hectic_amp` is
	// the amplitude floor separating a genuine kink from straight-line noise.
	// Density of flips, not mean curvature — a spiky wiggle averages low but flips
	// a lot.
	flips := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		lo := i
		for lo > 0 && arc[i] - arc[lo - 1] <= half {lo -= 1}
		hi := i
		for hi < n - 1 && arc[hi + 1] - arc[i] <= half {hi += 1}
		f, prev := 0, 0
		for j in lo ..= hi {
			s := ks[j] > pp.hectic_amp ? 1 : (ks[j] < -pp.hectic_amp ? -1 : 0)
			if s != 0 {
				if prev != 0 && s != prev {f += 1}
				prev = s
			}
		}
		flips[i] = f
	}

	// Enter/exit hysteresis: a chaotic section winds down into bigger, slower
	// alternations whose flip count dips below the enter threshold even though it
	// is plainly still hectic. Enter at `hectic_flicks`, but hold the zone open
	// while at least `exit` flips remain, so the tail consolidates too.
	exit := max(2, pp.hectic_flicks - 1)
	in_zone := false
	for i in 0 ..< n {
		if in_zone {
			if flips[i] < exit {in_zone = false}
		} else if flips[i] >= pp.hectic_flicks {
			in_zone = true
		}
		mask[i] = in_zone
	}

	// Bridge short below-exit dips between two in-zone stretches, so a one-flip
	// wobble at a zero crossing does not split the zone.
	bridge := pp.hectic_win_m * 0.5
	i := 0
	for i < n {
		if mask[i] {
			i += 1
			continue
		}
		j := i
		for j < n && !mask[j] {j += 1}
		if i > 0 && j < n && arc[j - 1] - arc[i] < bridge {
			for t in i ..< j {mask[t] = true}
		}
		i = j
	}
	return mask
}

// Nearest rung of the recorded distance ladder (40..200 by tens).
@(private = "file")
pace_round_dist :: proc(m: f32) -> int {
	d := int(math.round(m / 10.0)) * 10
	return clamp(d, 40, 200)
}

// Diagnostic: print per-sample smoothed curvature and windowed flip count, so the
// hectic thresholds can be calibrated against a real stage.
pace_debug_flips :: proc(ribbon: []Cross_Section, pp: Pace_Params, s0, s1: f32) {
	arc := ribbon_arc(ribbon)
	k := ribbon_curvature(ribbon, arc)
	ks := pace_smooth(k, arc, pp.smooth_m)
	n := len(ks)
	half := pp.hectic_win_m * 0.5
	maxf := 0
	for i in 0 ..< n {
		lo := i
		for lo > 0 && arc[i] - arc[lo - 1] <= half {lo -= 1}
		hi := i
		for hi < n - 1 && arc[hi + 1] - arc[i] <= half {hi += 1}
		flips, prev := 0, 0
		for j in lo ..= hi {
			s := ks[j] > pp.hectic_amp ? 1 : (ks[j] < -pp.hectic_amp ? -1 : 0)
			if s != 0 {
				if prev != 0 && s != prev {flips += 1}
				prev = s
			}
		}
		if flips > maxf {maxf = flips}
		if arc[i] >= s0 && arc[i] <= s1 {
			r := radius(ks[i])
			fmt.printf("%7.1f  k=%+.4f  r=%6.0f  flips=%d\n", arc[i], ks[i], r, flips)
		}
	}
	fmt.printf("# max flips in any %.0fm window over the whole stage: %d (threshold %d)\n",
		pp.hectic_win_m, maxf, pp.hectic_flicks)
}

// --- lexers ------------------------------------------------------------------
//
// Three passes over the same ribbon, each appending its own notes. Order matters
// once: hectic runs first and claims its samples, so the corner and elevation
// passes skip them rather than calling every little kink inside a twisty section.

// A chaotic straight becomes one caution call, scaled by how many times the
// curvature flips sign across it.
@(private = "file")
pace_lex_hectic :: proc(arc, ks: []f32, hectic: []bool, pp: Pace_Params, out: ^[dynamic]Pace_Note) {
	n := len(arc)
	i := 0
	for i < n {
		if !hectic[i] {
			i += 1
			continue
		}
		j := i
		for j < n && hectic[j] {j += 1}
		if arc[j - 1] - arc[i] >= pp.hectic_min_len_m {
			// intensity from the flip count -> caution / double / triple
			flips, prev := 0, 0
			seg_len := arc[j - 1] - arc[i]
			for t in i ..< j {
				s := ks[t] > pp.hectic_amp ? 1 : (ks[t] < -pp.hectic_amp ? -1 : 0)
				if s != 0 {
					if prev != 0 && s != prev {flips += 1}
					prev = s
				}
			}
			hn: Pace_Note
			hn.kind = .Hectic
			hn.sev = (flips >= 10 || seg_len > 120) ? 2 : (flips >= 6 || seg_len > 60) ? 1 : 0
			// The length of the section, spoken after the caution ("triple
			// caution 180"): how far the driver stays on it. Rounded to tens.
			hn.dist = int(math.round(seg_len / 10.0)) * 10
			hn.at = arc[i]
			hn.station = max(0, arc[i] - pp.lead_m)
			append(out, hn)
		}
		i = j
	}
}

// Maximal-munch corners, with a lookahead-behind over the straight just crossed:
// it either becomes this call's link word or a distance call of its own.
@(private = "file")
pace_lex_corners :: proc(arc, ks: []f32, hectic: []bool, pp: Pace_Params, out: ^[dynamic]Pace_Note) {
	n := len(arc)
prev_exit_s: f32
have_prev := false

i := 0
for i < n {
	// A hectic sample never starts (or belongs to) a corner — it was consumed
	// above.
	if radius(ks[i]) >= pp.r_on || hectic[i] {
		i += 1
		continue
	}
	// maximal-munch this corner: same sign, radius under the release threshold.
	// `sign` is just the curvature sign for grouping the corner; the spoken
	// left/right is assigned below.
	sign := ks[i] > 0
	j := i
	apex := i
	for j < n {
		if radius(ks[j]) >= pp.r_off || (ks[j] > 0) != sign || hectic[j] {
			break
		}
		if radius(ks[j]) < radius(ks[apex]) {
			apex = j
		}
		j += 1
	}
	s_enter := arc[i]
	s_exit := arc[j - 1]
	r_min := radius(ks[apex])

	sweep: f32
	for t in i ..< j {
		ds := t + 1 < n ? arc[t + 1] - arc[t] : 0
		sweep += abs(ks[t]) * ds
	}
	sweep_deg := math.to_degrees(sweep)

	// A corner that barely bends is road, not a call. Without this the
	// generator names 8-degree kinks and outruns the game's own density.
	if sweep_deg < pp.min_sweep {
		prev_exit_s = s_exit
		have_prev = true
		i = j
		continue
	}

	note: Pace_Note
	note.kind = .Corner
	// The curvature sign runs opposite the driven left/right, so positive
	// curvature is called a LEFT. This contradicts ribbon_curvature's own
	// "positive = right" doc; the viewport agrees with this one. reverse_spline
	// only swaps sides, so the single flip serves both driving directions.
	note.dir = sign ? .Left : .Right
	note.sev = pace_sev(sweep_deg, pp)
	note.radius, note.sweep = r_min, sweep_deg
	if note.sev >= 2 && note.sev <= 4 && abs(sweep_deg - 90) < pp.square_tol {
		note.square = true
	}
	if sweep_deg > pp.long_deg {
		note.mods += {.Long}
	}
	// tightens/opens from the corner's shape: compare the tightest radius over
	// the entry third against the exit third. A late-tightening corner has a
	// smaller exit radius; an opening one the reverse.
	if j - i >= 6 {
		third := (j - i) / 3
		r_in := radius(ks[i])
		for t in i ..< i + third {r_in = min(r_in, radius(ks[t]))}
		r_out := radius(ks[j - 1])
		for t in j - third ..< j {r_out = min(r_out, radius(ks[t]))}
		if r_out < r_in * (1 - pp.tighten) {
			note.mods += {.Tightens}
		} else if r_out > r_in * (1 + pp.tighten) {
			note.mods += {.Opens}
		}
	}

	// lookahead-behind: the straight we just crossed decides the link word,
	// or becomes its own distance call.
	gap := have_prev ? s_enter - prev_exit_s : 1e9
	if have_prev && gap <= pp.and_m {
		note.link = .And
	} else if have_prev && gap <= pp.into_m {
		note.link = .Into
	} else if have_prev && gap >= pp.dist_min_m {
		dn: Pace_Note
		dn.kind = .Distance
		dn.dist = pace_round_dist(gap)
		dn.at = prev_exit_s // spoken as soon as the previous corner is done
		dn.station = max(0, dn.at - pp.lead_m)
		append(out, dn)
	}

	note.at = s_enter
	note.station = max(0, s_enter - pp.lead_m)
	append(out, note)

	prev_exit_s = s_exit
	have_prev = true
	i = j
}

}

// Crests, dips and jumps, from the vertical curvature of the centreline.
@(private = "file")
pace_lex_elevation :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	hectic: []bool,
	pp: Pace_Params,
	out: ^[dynamic]Pace_Note,
) {
	n := len(arc)
last_feat_s := f32(-1e9)
for t in 1 ..< n - 1 {
	if hectic[t] {
		continue // the bumpiness is part of the hectic call
	}
	ds0 := arc[t] - arc[t - 1]
	ds1 := arc[t + 1] - arc[t]
	if ds0 < 1e-3 || ds1 < 1e-3 {
		continue
	}
	y0 := ribbon[t - 1].pos.y
	y1 := ribbon[t].pos.y
	y2 := ribbon[t + 1].pos.y
	g_pre := (y1 - y0) / ds0
	g_post := (y2 - y1) / ds1
	vcurv := (g_post - g_pre) / (0.5 * (ds0 + ds1))

	is_crest := y1 > y0 && y1 > y2 && vcurv < -pp.crest_k
	is_dip := y1 < y0 && y1 < y2 && vcurv > pp.crest_k
	if !is_crest && !is_dip {
		continue
	}
	if arc[t] - last_feat_s < pp.feat_gap_m {
		continue
	}
	last_feat_s = arc[t]

	fn: Pace_Note
	fn.at = arc[t]
	fn.station = max(0, arc[t] - pp.lead_m)
	if is_dip {
		fn.kind = .Dip
	} else if g_post < -pp.jump_grade {
		fn.kind = .Jump // a crest that falls away steeply
	} else {
		fn.kind = .Crest
	}
	append(out, fn)
}

}

// Generate the note list into `out` (cleared first). Persistent allocation — the
// inspector and preview read it across frames.
pace_generate :: proc(ribbon: []Cross_Section, pp: Pace_Params, out: ^[dynamic]Pace_Note) {
	clear(out)
	n := len(ribbon)
	if n < 3 {
		return
	}
	arc := ribbon_arc(ribbon)
	k := ribbon_curvature(ribbon, arc)
	ks := pace_smooth(k, arc, pp.smooth_m)
	hectic := pace_hectic_mask(arc, ks, pp)

	pace_lex_hectic(arc, ks, hectic, pp, out)
	pace_lex_corners(arc, ks, hectic, pp, out)
	pace_lex_elevation(ribbon, arc, hectic, pp, out)

	// codegen order: by trigger station. (Overlap scheduling is the player's job.)
	slice.sort_by(out[:], proc(a, b: Pace_Note) -> bool {
		return a.station < b.station
	})
}

// --- display -----------------------------------------------------------------

@(private = "file")
sev_word :: proc(sev: int) -> string {
	switch sev {
	case 0:
		return "hairpin"
	case 1:
		return "1"
	case 2:
		return "2"
	case 3:
		return "3"
	case 4:
		return "4"
	case 5:
		return "5"
	case:
		return "6"
	}
}

// One call as a co-driver would say it, for the inspector list. Temp-allocated.
pace_note_text :: proc(nt: Pace_Note, allocator := context.temp_allocator) -> string {
	b: [64]u8
	w := 0
	put :: proc(b: []u8, w: int, s: string) -> int {
		n := min(len(s), len(b) - w)
		copy(b[w:w + n], s[:n])
		return w + n
	}
	if nt.link == .Into {
		w = put(b[:], w, "into ")
	} else if nt.link == .And {
		w = put(b[:], w, "and ")
	}
	switch nt.kind {
	case .Corner:
		w = put(b[:], w, nt.dir == .Right ? "right " : "left ")
		w = put(b[:], w, nt.square ? "square" : sev_word(nt.sev))
		if .Long in nt.mods {
			w = put(b[:], w, " long")
		}
		if .Tightens in nt.mods {
			w = put(b[:], w, " tightens")
		}
		if .Opens in nt.mods {
			w = put(b[:], w, " opens")
		}
	case .Distance:
		buf: [8]u8
		s := int_to_str(buf[:], nt.dist)
		w = put(b[:], w, s)
	case .Crest:
		w = put(b[:], w, "crest")
	case .Dip:
		w = put(b[:], w, "dip")
	case .Jump:
		w = put(b[:], w, "jump")
	case .Hectic:
		w = put(b[:], w, nt.sev >= 2 ? "triple caution " : nt.sev == 1 ? "double caution " : "caution ")
		w = put(b[:], w, HECTIC_WORD)
		if nt.dist >= 40 {
			w = put(b[:], w, " ")
			buf: [8]u8
			w = put(b[:], w, int_to_str(buf[:], min(nt.dist, 200)))
		}
	}
	return string_clone(b[:w], allocator)
}

@(private = "file")
int_to_str :: proc(buf: []u8, v: int) -> string {
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	n := v
	digits: [8]u8
	d := 0
	for n > 0 {
		digits[d] = u8('0' + n % 10)
		n /= 10
		d += 1
	}
	for i in 0 ..< d {
		buf[i] = digits[d - 1 - i]
	}
	return string(buf[:d])
}

@(private = "file")
string_clone :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return string(out)
}

// --- VO clips + preview ride -------------------------------------------------
//
// The generator above is pure. This half loads the extracted OGG snippets and
// drives an automated ride: a cursor advances along the ribbon by arc, and each
// note fires its clips (tiled longest-match against the manifest) as the cursor
// passes the note's trigger station. The audio backend decodes OGG, so a clip is
// just an gfx.Sound.

// The clip names use spoken words ("one".."six"); the display uses digits.
@(private = "file")
sev_token :: proc(sev: int) -> string {
	switch sev {
	case 0:
		return "hairpin"
	case 1:
		return "one"
	case 2:
		return "two"
	case 3:
		return "three"
	case 4:
		return "four"
	case 5:
		return "five"
	case:
		return "six"
	}
}

// The ideal spoken tokens for a note, in order. The link word leads so the tiler
// can grab a whole "into-two-right" phrase clip; mods trail as their own clips.
pace_note_tokens :: proc(nt: Pace_Note, allocator := context.temp_allocator) -> []string {
	toks := make([dynamic]string, allocator)
	if nt.link == .Into {
		append(&toks, "into")
	} else if nt.link == .And {
		append(&toks, "and")
	}
	switch nt.kind {
	case .Corner:
		append(&toks, nt.square ? "square" : sev_token(nt.sev))
		append(&toks, nt.dir == .Right ? "right" : "left")
		if .Long in nt.mods {append(&toks, "long")} // no clip; tiler drops it
		if .Tightens in nt.mods {append(&toks, "tightens")}
		if .Opens in nt.mods {append(&toks, "opens")}
	case .Distance:
		append(&toks, fmt.tprintf("%d", nt.dist))
	case .Crest:
		append(&toks, "crest")
	case .Dip:
		append(&toks, "dip")
	case .Jump:
		append(&toks, "jump")
	case .Hectic:
		// Voiced as a caution, scaled by intensity ("twisty" has no clip), then the
		// section length as a distance ("triple caution 180").
		if nt.sev >= 2 {
			append(&toks, "triple")
		} else if nt.sev == 1 {
			append(&toks, "double")
		}
		append(&toks, "caution")
		if nt.dist >= 40 {
			append(&toks, fmt.tprintf("%d", min(nt.dist, 200)))
		}
	}
	return toks[:]
}

// Maximal-munch: consume the longest run of tokens that names an existing clip,
// falling back to shorter runs, dropping any token with no clip at all. `present`
// is any map keyed by clip name — the loaded sounds for the preview, or a bare
// name set for the headless bake.
pace_tile :: proc(
	toks: []string,
	present: map[string]$V,
	allocator := context.temp_allocator,
) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(toks) {
		matched := false
		for l := len(toks) - i; l >= 1; l -= 1 {
			name := strings.join(toks[i:i + l], "-", context.temp_allocator)
			if name in present {
				append(&out, name)
				i += l
				matched = true
				break
			}
		}
		if !matched {
			i += 1
		}
	}
	return out[:]
}
