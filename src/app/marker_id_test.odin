package main

// A marker names its road by point id, so every edit that renumbers the array
// has to leave it pointing at the same stretch of road. See geo.Road_Marker.

import "core:os"
import "core:testing"
import "../gfx"
import "../geo"

@(private = "file")
marker_pos :: proc(sp: geo.Spline, m: geo.Road_Marker) -> (gfx.Vector3, bool) {
	at, ok := geo.marker_resolve(sp, m)
	if !ok {
		return {}, false
	}
	return geo.sample_edge(sp, at.from, at.to, at.t).pos, true
}

// The case the whole scheme exists for: a point goes in ahead of the marker,
// every later array position shifts, and the marker does not.
@(test)
marker_holds_its_road_through_an_insert_upstream :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp) // 0 -> 1 -> 2 -> 3
	m := geo.marker_of(sp, {from = 2, to = 3, t = 0.5})
	was, placed := marker_pos(sp, m)
	testing.expect(t, placed, "the marker did not resolve where it was placed")

	frame := geo.sample_edge(sp, 0, 1, 0.5)
	idx, _ := geo.insert_point(&sp, frame.pos, frame)
	testing.expect_value(t, idx, 1)

	at, still := geo.marker_resolve(sp, m)
	testing.expect(t, still, "an insert upstream unhooked the marker")
	if !still {
		return
	}
	// Both ends moved one slot down the array; the marker followed them.
	testing.expect_value(t, at.from, 3)
	testing.expect_value(t, at.to, 4)
	now, _ := marker_pos(sp, m)
	testing.expect(
		t, gfx.Vector3Distance(was, now) < 0.01,
		"the marker landed on a different stretch of road",
	)
}

// The same thing end to end: editing road the stage never drives must not
// change the stage.
@(test)
an_edit_outside_a_stage_leaves_it_alone :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp)
	start := geo.marker_of(sp, {from = 1, to = 2, t = 0.3})
	finish := geo.marker_of(sp, {from = 2, to = 3, t = 0.7})

	before, bmsg, bok := geo.compile_stage(sp, start, finish, nil, context.allocator)
	defer geo.spline_free(&before)
	testing.expect(t, bok, bmsg)
	if !bok {
		return
	}

	// Edge (0,1) is upstream of the start line, so the stage never touches it.
	frame := geo.sample_edge(sp, 0, 1, 0.5)
	idx, _ := geo.insert_point(&sp, frame.pos, frame)
	testing.expect(t, idx >= 0)

	after, amsg, aok := geo.compile_stage(sp, start, finish, nil, context.allocator)
	defer geo.spline_free(&after)
	testing.expect(t, aok, amsg)
	if !aok {
		return
	}
	testing.expect_value(t, len(after.points), len(before.points))
	for p, i in after.points {
		testing.expect(
			t,
			gfx.Vector3Distance(p.xform.translation, before.points[i].xform.translation) < 0.01,
			"a road edit outside the stage moved the stage",
		)
	}
}

// Pins carry the same hazard the start and finish lines do, and the same fix.
@(test)
pins_hold_their_roads_through_an_insert :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0))
	pins := []geo.Road_Marker{geo.marker_of(sp, {from = 2, to = 3, t = 0.5})}
	start := geo.marker_of(sp, {from = 0, to = 1, t = 0.1})
	finish := geo.marker_of(sp, {from = tail, to = 0, t = 0.9})

	before, bmsg, bok := geo.compile_stage(sp, start, finish, pins, context.allocator)
	defer geo.spline_free(&before)
	testing.expect(t, bok, bmsg)
	if !bok {
		return
	}

	frame := geo.sample_edge(sp, 1, 2, 0.5)
	idx, split := geo.insert_point(&sp, frame.pos, frame)
	testing.expect(t, idx >= 0)
	for &p in pins {
		geo.marker_follow(&p, split)
	}

	after, amsg, aok := geo.compile_stage(sp, start, finish, pins, context.allocator)
	testing.expect(t, aok, amsg)
	if !aok {
		return
	}
	defer geo.spline_free(&after)
	// One more control point on the way round, and the same road either side.
	testing.expect_value(t, len(after.points), len(before.points) + 1)
}

// Ids are retired, never reissued, so a marker whose road is gone stays gone
// rather than waking up on whatever point is added next.
@(test)
a_removed_point_never_hands_its_id_on :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp)
	m := geo.marker_of(sp, {from = 2, to = 3, t = 0.5})
	testing.expect(t, geo.marker_valid(sp, m))

	geo.remove_point(&sp, 3)
	testing.expect(t, !geo.marker_valid(sp, m), "a marker whose road is gone must not resolve")

	geo.append_point(&sp, {80, 8, 140})
	geo.append_point(&sp, {100, 9, 180})
	testing.expect(t, !geo.marker_valid(sp, m), "a new point took a retired id")
}

// An id cannot answer for an edge that was cut in two, so the split says which
// half each marker landed on.
@(test)
a_split_edge_carries_its_markers :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp)
	early := geo.marker_of(sp, {from = 1, to = 2, t = 0.2})
	late := geo.marker_of(sp, {from = 1, to = 2, t = 0.7})
	elsewhere := geo.marker_of(sp, {from = 2, to = 3, t = 0.5})

	frame := geo.sample_edge(sp, 1, 2, 0.4)
	idx, split := geo.insert_point(&sp, frame.pos, frame)
	testing.expect(t, idx >= 0)
	testing.expect_value(t, split.mid, sp.points[idx].id)
	testing.expect(t, !geo.marker_valid(sp, early), "the cut edge must be gone")

	before_elsewhere := elsewhere
	geo.marker_follow(&early, split)
	geo.marker_follow(&late, split)
	geo.marker_follow(&elsewhere, split)

	testing.expect_value(t, early.to, split.mid)
	testing.expect_value(t, late.from, split.mid)
	testing.expect_value(t, elsewhere, before_elsewhere)
	testing.expect(t, geo.marker_valid(sp, early), "the early half lost its marker")
	testing.expect(t, geo.marker_valid(sp, late), "the late half lost its marker")
	// The cut fell at 0.4, so 0.2 is halfway along the first half.
	testing.expect(t, abs(early.t - 0.5) < 0.001)
	testing.expect(t, abs(late.t - 0.5) < 0.001)
}

// No rescale is exact: putting a point in changes the shape of the road between
// the two it sits between. Worst drift over these cuts is 0.11 m on a 31 m
// segment; the bound below is a regression catch, not the promise.
@(test)
a_split_barely_moves_a_marker :: proc(t: ^testing.T) {
	worst: f32
	for cut in ([]f32{0.2, 0.4, 0.5, 0.6, 0.8}) {
		for along in ([]f32{0.1, 0.3, 0.5, 0.7, 0.9}) {
			sp: geo.Spline
			defer geo.spline_free(&sp)
			seed_spline(&sp)
			m := geo.marker_of(sp, {from = 1, to = 2, t = along})
			was, _ := marker_pos(sp, m)
			frame := geo.sample_edge(sp, 1, 2, cut)
			_, split := geo.insert_point(&sp, frame.pos, frame)
			geo.marker_follow(&m, split)
			now, followed := marker_pos(sp, m)
			testing.expect(t, followed, "the marker did not follow the split")
			worst = max(worst, gfx.Vector3Distance(was, now))
		}
	}
	testing.expectf(t, worst < 0.25, "a split moved a marker %.2f m", worst)
}

@(test)
road_file_round_trips_point_ids :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	frame := geo.sample_edge(doc.spline, 0, 1, 0.5)
	idx, _ := geo.insert_point(&doc.spline, frame.pos, frame)
	testing.expect(t, idx >= 0)
	m := geo.marker_of(doc.spline, {from = 3, to = 4, t = 0.5})

	path := "/tmp/claude-1000/dirtbench-marker-id-roundtrip.json"
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg)
	if !ok {
		return
	}
	defer os.remove(path)

	back := doc_defaults()
	defer doc_delete(&back)
	load_msg, loaded := load_road(&back, path)
	testing.expect(t, loaded, load_msg)
	if !loaded {
		return
	}
	for p, i in back.spline.points {
		testing.expect_value(t, p.id, doc.spline.points[i].id)
	}
	testing.expect_value(t, back.spline.next_id, doc.spline.next_id)
	testing.expect(t, geo.marker_valid(back.spline, m), "a saved marker lost its road on load")
}

@(test)
a_road_with_repeated_ids_is_refused :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	doc.spline.points[2].id = doc.spline.points[1].id

	path := "/tmp/claude-1000/dirtbench-dup-ids.json"
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg)
	if !ok {
		return
	}
	defer os.remove(path)

	// Refused, and the document it was loaded into is left as it was.
	back := doc_defaults()
	defer doc_delete(&back)
	seed_spline(&back.spline)
	before := len(back.spline.points)
	load_msg, loaded := load_road(&back, path)
	testing.expect(t, !loaded, "a road with two points sharing an id must not load")
	testing.expect(t, load_msg != "", "a refused road gave no reason")
	testing.expect_value(t, len(back.spline.points), before)
}

// A negative id can only come from a hand-edited file; the loader refuses it
// the same way it refuses a repeat.
@(private = "file")
NEGATIVE_ID_ROAD :: `{
	"format": "dirtbench.venue",
	"version": 7,
	"road": {
		"points": [
			{"id": 0,  "parent": -1, "weld": -1, "pos": [0, 0, 0],  "rot": [0, 0, 0, 1], "width": 8},
			{"id": -3, "parent": 0,  "weld": -1, "pos": [0, 0, 32], "rot": [0, 0, 0, 1], "width": 8}
		]
	}
}`

@(test)
a_road_with_a_negative_id_is_refused :: proc(t: ^testing.T) {
	path := "/tmp/claude-1000/dirtbench-neg-id.json"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(NEGATIVE_ID_ROAD)) == nil)
	defer os.remove(path)

	doc := doc_defaults()
	defer doc_delete(&doc)
	msg, ok := load_road(&doc, path)
	testing.expect(t, !ok, "a negative point id must not load")
	testing.expect(t, msg != "", "a refused road gave no reason")
}

// Reverse rebuilds every parent edge the other way round, so a marker that is
// not turned with it names nothing. The road is the same road; only the
// direction it was drawn in changed.
@(test)
reverse_turns_the_markers_with_the_road :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seed_spline(&sp)
	testing.expect(t, geo.is_linear(sp), "Reverse is only offered on a linear road")
	m := geo.marker_of(sp, {from = 2, to = 3, t = 0.25})
	was, _ := marker_pos(sp, m)

	geo.reverse_spline(&sp)
	testing.expect(t, !geo.marker_valid(sp, m), "an unturned marker must not still resolve")

	m = geo.marker_reversed(m)
	testing.expect(t, geo.marker_valid(sp, m), "a turned marker lost its road")
	now, ok := marker_pos(sp, m)
	testing.expect(t, ok)
	testing.expect(
		t, gfx.Vector3Distance(was, now) < 0.01,
		"the turned marker is not on the same spot of road",
	)
}

// The stage itself is unchanged: the road is undirected, so turning the graph
// round and turning its markers with it compiles the same run.
@(test)
reverse_compiles_the_same_stage :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	routes_add(&doc.routes, &doc.next_route)
	r := &doc.routes[0]
	r.start = geo.marker_of(doc.spline, {from = 0, to = 1, t = 0.4})
	r.finish = geo.marker_of(doc.spline, {from = 2, to = 3, t = 0.6})
	append(&r.pins, geo.marker_of(doc.spline, {from = 1, to = 2, t = 0.5}))

	before, bmsg, bok := geo.compile_stage(doc.spline, r.start, r.finish, r.pins[:], context.allocator)
	defer geo.spline_free(&before)
	testing.expect(t, bok, bmsg)
	if !bok {
		return
	}

	geo.reverse_spline(&doc.spline)
	routes_reverse(doc.routes[:])

	after, amsg, aok := geo.compile_stage(doc.spline, r.start, r.finish, r.pins[:], context.allocator)
	testing.expect(t, aok, amsg)
	if !aok {
		return
	}
	defer geo.spline_free(&after)
	testing.expect_value(t, len(after.points), len(before.points))
	for p, i in after.points {
		testing.expect(
			t,
			gfx.Vector3Distance(p.xform.translation, before.points[i].xform.translation) < 0.01,
			"reversing the road moved the stage",
		)
	}
}

// The setup pin is a marker like the rest: turning the road round has to turn
// it too, or the setup screen is left standing on a road that no longer runs
// that way.
@(test)
reverse_turns_the_setup_pin_with_the_road :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	routes_add(&doc.routes, &doc.next_route)
	r := &doc.routes[0]
	r.setup = geo.marker_of(doc.spline, {from = 1, to = 2, t = 0.5})
	was, had := marker_pos(doc.spline, r.setup)
	testing.expect(t, had)

	geo.reverse_spline(&doc.spline)
	routes_reverse(doc.routes[:])

	now, ok := marker_pos(doc.spline, r.setup)
	testing.expect(t, ok, "the setup pin lost its road when the road turned round")
	testing.expect(
		t, gfx.Vector3Distance(was, now) < 0.01,
		"the turned setup pin is not on the same spot of road",
	)
}
