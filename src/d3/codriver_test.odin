package d3

import "core:strconv"
import "core:testing"

@(private = "file")
VOCAB :: `# a slice of finland, enough to match against
co1_pro_a = left 4
co1_pro_b = into left 4
co1_pro_c = left 4 long
co1_pro_d = right 3
co1_pro_e = 80
co1_pro_f = crest
co1_pro_g = right 4 long, past house
co1_pro_h = into left 5, big cut
co1_pro_i = right 5+ into crest
co1_easy_a = medium left
co1_easy_b = medium right, hairpin, opens
co2_pro_a = left 4
`

@(private = "file")
straight_line :: proc(length: f32, allocator := context.temp_allocator) -> []Route_Station {
	count := int(length / 10) + 1
	line := make([]Route_Station, count, allocator)
	for i in 0 ..< count {
		z := f32(i) * 10
		line[i] = {
			distance = z,
			centre   = {0, 5, z},
			left     = {-4, 5, z},
			right    = {4, 5, z},
		}
	}
	return line
}

@(test)
test_codriver_parse_splits_words_from_content :: proc(t: ^testing.T) {
	plain := d3_codriver_parse("left 4")
	testing.expect_value(t, plain.call.side, D3_Side.Left)
	testing.expect_value(t, plain.call.severity, 4)
	testing.expect_value(t, plain.sides, 1)
	testing.expect_value(t, plain.extra, 0)

	// `easy` mode words a band rather than a number.
	banded := d3_codriver_parse("medium left")
	testing.expect_value(t, banded.sev_lo, 3)
	testing.expect_value(t, banded.sev_hi, 4)

	// A clip naming two corners belongs to the stage it was cut for.
	compound := d3_codriver_parse("right 5 into care, left 4, tightens")
	testing.expect_value(t, compound.sides, 2)

	landmark := d3_codriver_parse("right 4 long, past house")
	testing.expect(t, .Landmark in landmark.call.features, "house is a landmark")
}

@(test)
test_codriver_pick_prefers_the_exact_wording :: proc(t: ^testing.T) {
	vocab := d3_codriver_vocabulary(VOCAB, context.temp_allocator)

	plain, _, found := d3_codriver_pick(vocab, {side = .Left, severity = 4}, 1, "pro")
	testing.expect(t, found, "a plain 4 left is in the bank")
	testing.expect_value(t, plain, "co1_pro_a")

	// Asking for a link word takes the clip that says it, not the bare one.
	linked, _, linked_found := d3_codriver_pick(
		vocab,
		{side = .Left, severity = 4, link = .Into},
		1,
		"pro",
	)
	testing.expect(t, linked_found, "into left 4 is in the bank")
	testing.expect_value(t, linked, "co1_pro_b")

	// The other way round must not happen: a clip that says "into" where we
	// asked for none puts a word on the stage we did not write.
	bare, _, bare_found := d3_codriver_pick(vocab, {side = .Left, severity = 4}, 1, "pro")
	testing.expect(t, bare_found, "still found")
	testing.expect_value(t, bare, "co1_pro_a")

	// `easy` mode answers from its own wording.
	easy, _, easy_found := d3_codriver_pick(vocab, {side = .Left, severity = 4}, 1, "easy")
	testing.expect(t, easy_found, "medium covers severity 4")
	testing.expect_value(t, easy, "co1_easy_a")

	// The second voice never answers with the first voice's recording.
	second, _, second_found := d3_codriver_pick(vocab, {side = .Left, severity = 4}, 2, "pro")
	testing.expect(t, second_found, "voice 2 has its own")
	testing.expect_value(t, second, "co2_pro_a")
}

@(test)
test_codriver_pick_refuses_rather_than_approximates :: proc(t: ^testing.T) {
	vocab := d3_codriver_vocabulary(VOCAB, context.temp_allocator)

	// A grade the bank does not hold borrows the nearest one within two bands,
	// and is reported as inexact. Silence before a hairpin is worse: it leaves
	// the previous call standing as the last thing the driver heard.
	name, exact, found := d3_codriver_pick(vocab, {side = .Left, severity = 2}, 1, "pro")
	testing.expect(t, found, "severity 2 left borrows the 4 left")
	testing.expect(t, !exact, "and says so")
	testing.expect_value(t, name, "co1_pro_a")
	// Four bands away is too far to borrow.
	_, _, far := d3_codriver_pick(vocab, {side = .Left, severity = 0}, 1, "pro")
	testing.expect(t, !far, "a hairpin cannot borrow a 4")
	// A landmark clip is the right phrase about a place that is not there, so
	// it is never picked -- not even when it is the only exact grade.
	house, _, _ := d3_codriver_pick(vocab, {side = .Right, severity = 4, mods = {.Long}}, 1, "pro")
	testing.expect(t, house != "co1_pro_g", "never the clip that names a house")
	// Nor is a clip that names two corners, even as a borrow.
	two, _, _ := d3_codriver_pick(vocab, {side = .Right, severity = 5}, 1, "pro")
	testing.expect(t, two != "co1_pro_i", "never the compound clip")
	// Two grades is two corners even with one side word. Reading only the first
	// would put "hairpin" on a road that has none.
	_, _, two_grades := d3_codriver_pick(
		vocab, {side = .Right, severity = 4, mods = {.Opens}}, 1, "easy",
	)
	testing.expect(t, !two_grades, "medium-right-then-hairpin is not a medium right")
}

@(test)
test_codriver_distances_snap_to_what_the_bank_can_say :: proc(t: ^testing.T) {
	vocab := d3_codriver_vocabulary(VOCAB, context.temp_allocator)
	ladder := d3_codriver_distances(vocab)
	testing.expect_value(t, len(ladder), 1)
	testing.expect_value(t, ladder[0], 80)
	// Our generator rounds to tens; the bank does not hold every ten.
	testing.expect_value(t, d3_codriver_snap_distance(ladder, 70), 80)
	testing.expect_value(t, d3_codriver_snap_distance({40, 60, 80, 100, 150}, 120), 100)
	testing.expect_value(t, d3_codriver_snap_distance({40, 60, 80, 100, 150}, 200), 150)
}

@(test)
test_codriver_builds_a_pair_of_boxes_per_spoken_call :: proc(t: ^testing.T) {
	line := straight_line(600)
	vocab := d3_codriver_vocabulary(VOCAB, context.temp_allocator)
	calls := []D3_Call {
		{at = 100, side = .Left, severity = 4},
		{at = 300, severity = D3_NO_SEVERITY, distance = 80},
		{at = 500, side = .Left, severity = 0}, // no hairpin in this bank
	}
	triggers, spoken, silent, _ := d3_codriver_triggers(line, calls, vocab, 1, "pro", 0, "db")
	testing.expect_value(t, spoken, 2)
	testing.expect_value(t, silent, 1)
	testing.expect_value(t, len(triggers), 4) // an early and a late box each

	for trigger in triggers {
		testing.expect_value(t, trigger.name, "TRIGGERINSTANCE")
		testing.expect_value(t, len(trigger.children), 9)
		testing.expect_value(t, trigger.children[0].name, "TYPE")
		testing.expect_value(t, trigger.children[8].name, "SIZE")
	}
	// And the whole file builds.
	result, ok := d3_codriver_xml(line, calls, vocab, 1, "pro", 0, "db", context.temp_allocator)
	testing.expect(t, ok, "the file builds")
	testing.expect(t, len(result.data) > 0, "and has bytes")
}

@(private = "file")
attr_f32 :: proc(node: ^Bxml_Node, key: string) -> f32 {
	for attr in node.attrs {
		if attr.name == key {
			value, _ := strconv.parse_f32(attr.value)
			return value
		}
	}
	return 0
}

@(test)
test_codriver_transform_matches_the_stock_frame :: proc(t: ^testing.T) {
	// A road heading +Z. COL0 runs along it, COL2 across it, and the XZ
	// determinant is +1, which is what all 16605 stock triggers hold.
	line := straight_line(400)
	vocab := d3_codriver_vocabulary(VOCAB, context.temp_allocator)
	triggers, spoken, _, _ := d3_codriver_triggers(
		line, []D3_Call{{at = 200, side = .Left, severity = 4}}, vocab, 1, "pro", 0, "db",
	)
	testing.expect_value(t, spoken, 1)
	testing.expect_value(t, len(triggers), 2)

	transform := triggers[0].children[1]
	testing.expect_value(t, transform.name, "TRANSFORM")
	c0x, c0z := attr_f32(transform.children[0], "x"), attr_f32(transform.children[0], "z")
	c2x, c2z := attr_f32(transform.children[2], "x"), attr_f32(transform.children[2], "z")
	testing.expect(t, abs(c0z - 1) < 1e-4, "COL0 runs down the road")
	testing.expect(t, abs(c0x * c2x + c0z * c2z) < 1e-4, "COL0 and COL2 are perpendicular")
	testing.expect(t, abs((c0x * c2z - c0z * c2x) - 1) < 1e-4, "the XZ determinant is +1")
	testing.expect_value(t, attr_f32(transform.children[1], "y"), 1)

	// The box sits above the road, not on it: stock is a median 7.63 m up.
	y := attr_f32(transform.children[3], "y")
	testing.expect(t, abs(y - (5 + D3_CODRIVER_RAISE)) < 1e-3, "raised off the road")

	// The early box is upstream of the late one, and by a real distance.
	early_z := attr_f32(triggers[0].children[1].children[3], "z")
	late_z := attr_f32(triggers[1].children[1].children[3], "z")
	testing.expect(t, early_z < late_z, "early comes first down the road")
	testing.expect(t, late_z - early_z > 5, "and far enough to matter")
	// The late box carries no speed gate; the early one does.
	testing.expect_value(t, triggers[1].children[4].attrs[0].value, "0.0")
	testing.expect_value(t, triggers[1].children[5].attrs[0].value, "late")
	testing.expect_value(t, triggers[0].children[5].attrs[0].value, "early")
}
