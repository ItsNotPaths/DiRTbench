package d3

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Co-driver calls: `<base>_codriver_<voice>_<mode>_<route>.xml`, four per route.
// The same trigger boxes in all four, with the recording swapped — two voices,
// two wordings. See docs/guide-pacenotes.md.
//
// The speech bank cannot be written, so every call has to name a recording the
// venue already ships. That is what the vocabulary asset is: one line per clip
// in the bank, and the words it says. The matcher's whole job is finding a clip
// that says what our note says, and refusing rather than approximating.

D3_Side :: enum u8 {None, Left, Right}
D3_Link :: enum u8 {None, Into, And}
D3_Mod :: enum u8 {Long, Tightens, Opens}
// `Landmark` is a clip naming something on its own stage — a house, a bridge,
// the finish. It is the one feature that disqualifies a clip: the phrase is
// correct and the place does not exist on our road.
D3_Feature :: enum u8 {Crest, Jump, Dip, Care, Keep, Cut, Landmark}

D3_NO_SEVERITY :: -1

D3_Call :: struct {
	at:       f32, // where the box goes, not where the corner is
	link:     D3_Link,
	side:     D3_Side,
	severity: int, // 0 hairpin, 1..6, or D3_NO_SEVERITY
	distance: int,
	mods:     bit_set[D3_Mod],
	features: bit_set[D3_Feature],
}

// One recording. `sev_lo..sev_hi` is a band because the `easy` wording says
// "medium" where `pro` says 3 or 4; measured over 292 slots that hold both.
D3_Clip :: struct {
	name:           string,
	call:           D3_Call,
	sev_lo, sev_hi: int,
	sides:          int, // 2+ names two corners, so it belongs to one stage
	grades:         int, // how many corner grades it names, for the same reason
	extra:          int, // words that matched nothing
}

@(private = "file")
d3_word_severity :: proc(word: string) -> (lo, hi: int, ok: bool) {
	switch word {
	case "hairpin":
		return 0, 0, true
	case "tight":
		return 1, 1, true
	case "hard":
		return 2, 2, true
	case "medium", "mid":
		return 3, 4, true
	case "easy":
		return 5, 6, true
	case "flat":
		return 6, 6, true
	}
	return 0, 0, false
}

@(private = "file")
d3_landmark :: proc(word: string) -> bool {
	switch word {
	case "house", "bridge", "gravel", "tarmac", "tower", "top", "barn", "rocks",
	     "finish", "start", "line":
		return true
	}
	return false
}

// Words into a call. Shared by the vocabulary reader and by anything that wants
// to state a call as text, so the two cannot drift apart.
d3_codriver_parse :: proc(text: string) -> D3_Clip {
	clip := D3_Clip{sev_lo = D3_NO_SEVERITY, sev_hi = D3_NO_SEVERITY}
	clip.call.severity = D3_NO_SEVERITY
	for raw in strings.split(text, " ", context.temp_allocator) {
		word := strings.trim(raw, " ,.?!")
		if word == "" {
			continue
		}
		if value, is_number := strconv.parse_int(word); is_number {
			if value >= 1 && value <= 6 {
				clip.grades += 1
				if clip.call.severity == D3_NO_SEVERITY {
					clip.call.severity, clip.sev_lo, clip.sev_hi = value, value, value
				}
			} else if value >= 20 {
				clip.call.distance = value
			}
			continue
		}
		if lo, hi, is_severity := d3_word_severity(word); is_severity {
			clip.grades += 1
			if clip.call.severity == D3_NO_SEVERITY {
				clip.call.severity, clip.sev_lo, clip.sev_hi = lo, lo, hi
			}
			continue
		}
		switch word {
		case "into":
			if clip.call.side == .None {clip.call.link = .Into}
		case "and":
			if clip.call.side == .None {clip.call.link = .And}
		case "left":
			clip.sides += 1
			if clip.call.side == .None {clip.call.side = .Left}
		case "right":
			clip.sides += 1
			if clip.call.side == .None {clip.call.side = .Right}
		case "long":
			clip.call.mods += {.Long}
		case "tightens":
			clip.call.mods += {.Tightens}
		case "opens":
			clip.call.mods += {.Opens}
		case "crest":
			clip.call.features += {.Crest}
		case "jump":
			clip.call.features += {.Jump}
		case "dip":
			clip.call.features += {.Dip}
		case "care":
			clip.call.features += {.Care}
		case "keep":
			clip.call.features += {.Keep}
		case "cut", "don't", "dont":
			clip.call.features += {.Cut}
		case "very", "over", "onto", "at", "to", "in", "plus", "late", "narrows",
		     "narrow", "open", "big", "small":
		// grammar, not content
		case:
			if d3_landmark(word) {
				clip.call.features += {.Landmark}
			} else {
				clip.extra += 1
			}
		}
	}
	return clip
}

// Read the baked vocabulary. Palette grammar: `clip = words`, `#` comments.
d3_codriver_vocabulary :: proc(text: string, allocator := context.allocator) -> []D3_Clip {
	out := make([dynamic]D3_Clip, allocator)
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		split := strings.index(line, "=")
		if split < 0 {
			continue
		}
		name := strings.trim_space(line[:split])
		clip := d3_codriver_parse(strings.trim_space(line[split + 1:]))
		clip.name = strings.clone(name, allocator)
		append(&out, clip)
	}
	return out[:]
}

d3_codriver_vocabulary_delete :: proc(vocab: []D3_Clip) {
	for clip in vocab {delete(clip.name)}
	delete(vocab)
}

// The distances the bank actually holds. Finland's are 40, 60, 80, 100 and 150,
// which is coarser than the ladder our generator rounds to, so a call for 70 has
// to be snapped or dropped.
d3_codriver_distances :: proc(vocab: []D3_Clip, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for clip in vocab {
		if clip.call.distance == 0 {
			continue
		}
		seen := false
		for value in out {if value == clip.call.distance {seen = true}}
		if !seen {append(&out, clip.call.distance)}
	}
	for i in 0 ..< len(out) {
		for j in i + 1 ..< len(out) {
			if out[j] < out[i] {out[i], out[j] = out[j], out[i]}
		}
	}
	return out[:]
}

d3_codriver_snap_distance :: proc(ladder: []int, want: int) -> int {
	if len(ladder) == 0 {
		return 0
	}
	best := ladder[0]
	for value in ladder {
		near := value - want
		far := best - want
		if near < 0 {near = -near}
		if far < 0 {far = -far}
		if near < far {best = value}
	}
	return best
}

@(private = "file")
d3_voice_prefix :: proc(voice: int, mode: string) -> string {
	return fmt.tprintf("co%d_%s_", voice, mode)
}

// How far a clip's grade may sit from the one we asked for. Two bands, so a
// hairpin can borrow a 2 but never a 4.
D3_CODRIVER_GRADE_SLACK :: 2

// Score a clip against a wanted call. Negative means it will not do.
//
// Content is exact: a clip that names two corners, names a landmark, or claims
// a modifier we did not ask for is refused outright, because those put a thing
// on the stage that is not there.
//
// Grade and link words degrade instead of refusing, and that is a correction.
// The first version refused anything inexact, which sounds safe and is not:
// finland has no `1 left` at all, so every hairpin on a derived stage went
// silent, and what the driver actually heard before the hairpin was the
// previous corner -- "left 6". Silence is not the absence of a call. It leaves
// the last one standing.
@(private = "file")
d3_codriver_score :: proc(clip: D3_Clip, want: D3_Call) -> int {
	// Two grades is two corners even when only one side is named: "medium
	// right, hairpin, opens" is a medium right *followed by* a hairpin, and
	// reading only the first word puts a hairpin call on a road that has none.
	if clip.sides > 1 || clip.grades > 1 || clip.extra > 0 ||
	   .Landmark in clip.call.features {
		return -1
	}
	if clip.call.side != want.side {
		return -1
	}
	if want.distance != clip.call.distance {
		return -1
	}
	grade_miss := 0
	if want.severity == D3_NO_SEVERITY {
		if clip.sev_lo != D3_NO_SEVERITY {return -1}
	} else {
		if clip.sev_lo == D3_NO_SEVERITY {return -1}
		if want.severity < clip.sev_lo {
			grade_miss = clip.sev_lo - want.severity
		} else if want.severity > clip.sev_hi {
			grade_miss = want.severity - clip.sev_hi
		}
		if grade_miss > D3_CODRIVER_GRADE_SLACK {return -1}
	}
	// Features are exact: a clip that adds "care" to a plain corner is a
	// different call, and one that drops our "crest" is not the call at all.
	if clip.call.features != want.features {
		return -1
	}
	// An exact grade is worth more than everything else put together, so a
	// borrowed one only ever wins when nothing exact exists.
	score := 40 - 12 * grade_miss
	if clip.call.link == want.link {
		score += 6
	} else if clip.call.link == .None {
		score += 3 // a bare corner fits where we wanted a link word
	}
	// else: a different link word. "into" for "and" is a smaller error than
	// nothing at all, so it scores zero rather than refusing.
	if clip.call.mods == want.mods {
		score += 6
	} else if clip.call.mods == {} {
		score += 2
	} else {
		return -1 // never claim it tightens when it does not
	}
	if clip.sev_lo == clip.sev_hi {
		score += 1 // an exact grade beats a banded `easy`-mode word
	}
	return score
}

// Whether a pick says exactly what was asked, for counting how much of a stage
// the bank could only approximate.
@(private = "file")
d3_codriver_exact :: proc(clip: D3_Clip, want: D3_Call) -> bool {
	if want.severity == D3_NO_SEVERITY {
		return clip.sev_lo == D3_NO_SEVERITY
	}
	return want.severity >= clip.sev_lo && want.severity <= clip.sev_hi
}

// Pick the recording for one call, or refuse. Ties go to the first name in
// order, so two exports of the same stage name the same clips.
d3_codriver_pick :: proc(
	vocab: []D3_Clip,
	want: D3_Call,
	voice: int,
	mode: string,
) -> (
	name: string,
	exact: bool,
	ok: bool,
) {
	prefix := d3_voice_prefix(voice, mode)
	best := -1
	for clip in vocab {
		if !strings.has_prefix(clip.name, prefix) {
			continue
		}
		score := d3_codriver_score(clip, want)
		if score > best || (score == best && score >= 0 && clip.name < name) {
			best, name, exact = score, clip.name, d3_codriver_exact(clip, want)
		}
	}
	return name, exact, best >= 0
}

// What the designer expected to be doing here, by how tight the corner is.
// Read off 794 stock early boxes; see docs/guide-pacenotes.md.
@(private = "file")
d3_codriver_speed :: proc(severity: int) -> f32 {
	switch severity {
	case 0, 1:
		return 46
	case 2:
		return 62
	case 3:
		return 71
	case 4:
		return 80
	case 5:
		return 85
	}
	return 95
}

// The early box sits this far up the road from the late one. Fitted over 3301
// stock pairs; the spread is wide, so this is a shape rather than a law.
@(private = "file")
d3_codriver_gap :: proc(speed: f32) -> f32 {
	return 9.18 + 0.0921 * speed
}

D3_CODRIVER_HALF_THICK :: f32(0.5)
D3_CODRIVER_HALF_HEIGHT :: f32(10)
D3_CODRIVER_HALF_WIDTH :: f32(12.5)
// Stock boxes sit a median 7.63 m above the centreline, so the box covers the
// road from about 2.4 m below it to 17.6 m above. Not the road surface.
D3_CODRIVER_RAISE :: f32(7.5)
D3_CODRIVER_LANGUAGES :: "EN;FR;GE;IT;JP;PO;RS;SP;"

@(private = "file")
d3_codriver_forward :: proc(line: []Route_Station, distance: f32) -> [2]f32 {
	a := d3_station_at(line, max(distance - 2, 0))
	b := d3_station_at(line, min(distance + 2, line[len(line) - 1].distance))
	dx, dz := b.centre[0] - a.centre[0], b.centre[2] - a.centre[2]
	length := math.sqrt(dx * dx + dz * dz)
	if length < 1e-6 {
		return {0, 1}
	}
	return {dx / length, dz / length}
}

@(private = "file")
d3_codriver_trigger :: proc(
	line: []Route_Station,
	distance: f32,
	clip: string,
	setting: string,
	early: bool,
	speed: f32,
) -> ^Bxml_Node {
	station := d3_station_at(line, distance)
	f := d3_codriver_forward(line, distance)
	// COL0 runs along the road, COL2 across it, COL1 is the Y axis. The XZ
	// determinant is +1, which is what every stock trigger holds.
	col := proc(name: string, v: [3]f32, w: string) -> ^Bxml_Node {
		return bxml_node(
			name,
			[]Bxml_Attr {
				{"x", d3_f6(v[0])},
				{"y", d3_f6(v[1])},
				{"z", d3_f6(v[2])},
				{"W", w},
			},
		)
	}
	position := [3]f32{station.centre[0], station.centre[1] + D3_CODRIVER_RAISE, station.centre[2]}
	return bxml_node(
		"TRIGGERINSTANCE",
		nil,
		[]^Bxml_Node {
			bxml_node("TYPE", []Bxml_Attr{{"type", "CODRIVER"}}),
			bxml_node(
				"TRANSFORM",
				nil,
				[]^Bxml_Node {
					col("COL0", {f[0], 0, f[1]}, "0.000000"),
					col("COL1", {0, 1, 0}, "0.000000"),
					col("COL2", {-f[1], 0, f[0]}, "0.000000"),
					col("COL3", position, "1.000000"),
				},
			),
			bxml_node("SETTING", []Bxml_Attr{{"value", setting}}),
			bxml_node("FILENAME", []Bxml_Attr{{"value", clip}}),
			// Every one of 6080 stock SPEED values carries a decimal point, so
			// ours do too rather than finding out the parser is strict.
			bxml_node(
				"SPEED",
				[]Bxml_Attr{{"value", early ? fmt.tprintf("%.4f", speed) : "0.0"}},
			),
			bxml_node("CALL_TYPE", []Bxml_Attr{{"value", early ? "early" : "late"}}),
			bxml_node("FINAL_CALL", []Bxml_Attr{{"value", "false"}}),
			bxml_node("LANGUAGES", []Bxml_Attr{{"value", D3_CODRIVER_LANGUAGES}}),
			bxml_node(
				"SIZE",
				[]Bxml_Attr{{"x", "0.5"}, {"y", "10.0"}, {"z", "12.5"}},
			),
		},
	)
}

D3_Codriver_Result :: struct {
	data:        []u8,
	spoken:      int, // calls that found a recording
	silent:      int, // calls with nothing in the bank that says them
	approximate: int, // spoken, but with a grade the bank does not actually hold
}

// The trigger boxes for one co-driver file, as nodes. Split out from the build
// so a test can read the frame and the spacing back without a BinXML reader,
// which this package does not have: `tools/binxml.py` is the only one.
d3_codriver_triggers :: proc(
	line: []Route_Station,
	calls: []D3_Call,
	vocab: []D3_Clip,
	voice: int,
	mode: string,
	route: int,
	tag: string,
	allocator := context.temp_allocator,
) -> (
	triggers: []^Bxml_Node,
	spoken, silent, approximate: int,
) {
	out := make([dynamic]^Bxml_Node, allocator)
	total := line[len(line) - 1].distance
	for call, i in calls {
		clip, exact, found := d3_codriver_pick(vocab, call, voice, mode)
		if !found {
			silent += 1
			continue
		}
		spoken += 1
		if !exact {approximate += 1}
		severity := call.severity == D3_NO_SEVERITY ? 6 : call.severity
		speed := d3_codriver_speed(severity)
		late := clamp(call.at, 0, total)
		early := clamp(late - d3_codriver_gap(speed), 0, total)
		slot := fmt.tprintf("co%d_%s_%s%d_%03d", voice, mode, tag, route, i)
		append(
			&out,
			d3_codriver_trigger(
				line, early, clip, fmt.tprintf("%s_e_01_r%d", slot, route), true, speed,
			),
		)
		append(
			&out,
			d3_codriver_trigger(
				line, late, clip, fmt.tprintf("%s_l_01_r%d", slot, route), false, speed,
			),
		)
	}
	return out[:], spoken, silent, approximate
}

// One co-driver file. `calls` is in road order; anything with no recording is
// dropped rather than approximated, and counted.
d3_codriver_xml :: proc(
	line: []Route_Station,
	calls: []D3_Call,
	vocab: []D3_Clip,
	voice: int,
	mode: string,
	route: int,
	tag: string,
	allocator := context.allocator,
) -> (
	result: D3_Codriver_Result,
	ok: bool,
) {
	triggers: []^Bxml_Node
	triggers, result.spoken, result.silent, result.approximate = d3_codriver_triggers(
		line, calls, vocab, voice, mode, route, tag,
	)
	if len(triggers) == 0 {
		return result, false
	}
	data, built := bxml_build(bxml_node("TRIGGERINSTANCES", nil, triggers), allocator)
	if !built {
		return result, false
	}
	result.data = data
	return result, true
}

// `<venue>_codriver_<voice>_<mode>_<route>.xml`, where `<venue>` is the venue's
// own directory — `track_model.file_string` in the database.
//
// Two stock venues prove it, because they are the only ones whose directory and
// `ai_track_name` disagree: `michigan_rally` has `ai_track_name` `michigan_ral_0`
// and ships `michigan_rally_codriver_*`; `monte_carlo_rally` has `monte_carlo_0`
// and ships `monte_carlo_rally_codriver_*`. Both follow the directory.
//
// CAUTION: it is *our* venue's name, not the base venue's, and the speech bank
// follows the same rule — `en_codriver1_<venue>.nfs`. A derived venue carrying
// its donor's file names is not read at all, which is silent rather than wrong,
// and is why every hardlinked co-driver file in this install has always done
// nothing.
d3_codriver_file_name :: proc(venue: string, voice: int, mode: string, route: int) -> string {
	return fmt.tprintf("%s_codriver_%d_%s_%d.xml", venue, voice, mode, route)
}


// Emission is off, and the reason is a wall rather than a bug.
//
// A derived venue can only say what its base venue's speech bank already
// holds, and the banks are thin exactly where it matters. Finland ships one
// hairpin recording, "open hairpin right". So a left hairpin has nothing to
// borrow but a grade 2, and the co-driver calls a 180-degree left "left 2".
// Silence there is worse still: it leaves the previous corner's call standing
// as the last thing the driver heard.
//
// Everything below works and is tested. The format is decoded, the writer
// round-trips byte-exact through tools/binxml.py, and the calls land on the
// road. What is not solved is grading a corner the way the game does and
// having a bank able to say the result. See docs/guide-pacenotes.md for where
// it stopped and what would have to be true to switch this back on.
D3_CODRIVER_EMIT :: false

D3_CODRIVER_VOICES :: []int{1, 2}
D3_CODRIVER_MODES :: []string{"easy", "pro"}

// All four co-driver files for a route. Nothing to say is not a failure: a
// venue with no baked vocabulary, or a stage with no notes, writes nothing and
// says so.
d3_write_codriver :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	when !D3_CODRIVER_EMIT {
		return "shelved, see D3_CODRIVER_EMIT", true
	}
	if len(job.Calls) == 0 || len(job.Codriver) == 0 || job.Codriver_Base == "" {
		return "no co-driver vocabulary for this base venue, so no calls", true
	}
	line := d3_route_stations(job.Route)
	if len(line) < 2 {
		return "a route this short has nowhere to put a call", false
	}
	// The file is named after the venue directory we are writing into.
	venue := filepath.base(strings.trim_right(job.Venue_Dir, "/"))
	if venue == "" || venue == "." {
		return "cannot name the co-driver files without the venue directory", false
	}
	vocab := d3_codriver_vocabulary(string(job.Codriver), context.temp_allocator)
	defer for clip in vocab {delete(clip.name, context.temp_allocator)}
	ladder := d3_codriver_distances(vocab)

	calls := make([]D3_Call, len(job.Calls), context.temp_allocator)
	copy(calls, job.Calls)
	// Our generator rounds a distance to the nearest ten. The bank holds a much
	// shorter ladder, so a call for 70 has to become one the bank can say.
	for &call in calls {
		if call.distance > 0 {
			call.distance = d3_codriver_snap_distance(ladder, call.distance)
		}
	}

	spoken, silent := 0, 0
	for voice in D3_CODRIVER_VOICES {
		for mode in D3_CODRIVER_MODES {
			result, built := d3_codriver_xml(
				line,
				calls,
				vocab,
				voice,
				mode,
				job.Route_Index,
				"db",
				context.temp_allocator,
			)
			if !built {
				return fmt.tprintf("co-driver %d %s: nothing could be said", voice, mode), false
			}
			name := d3_codriver_file_name(venue, voice, mode, job.Route_Index)
			if write_msg, written := d3_write_out(job, name, result.data); !written {
				return write_msg, false
			}
			spoken += result.spoken
			silent += result.silent
		}
	}
	return fmt.tprintf(
		"%d calls, %d spoken and %d with no recording, over 4 files",
		len(calls) * 4,
		spoken,
		silent,
	), true
}
