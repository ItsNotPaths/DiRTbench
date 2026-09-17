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
	defer delete(sp.points)
	seed_spline(&sp) // 0 -> 1 -> 2 -> 3
	m := geo.marker_of(sp, {from = 2, to = 3, t = 0.5})
	was, placed := marker_pos(sp, m)
	testing.expect(t, placed, "the marker did not resolve where it was placed")

	frame := geo.sample_edge(sp, 0, 1, 0.5)
	testing.expect_value(t, geo.insert_point(&sp, frame.pos, frame), 1)

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
	defer delete(sp.points)
	seed_spline(&sp)
	start := geo.marker_of(sp, {from = 1, to = 2, t = 0.3})
	finish := geo.marker_of(sp, {from = 2, to = 3, t = 0.7})

	before, bmsg, bok := geo.compile_stage(sp, start, finish, nil, context.allocator)
	defer delete(before.points)
	testing.expect(t, bok, bmsg)
	if !bok {
		return
	}

	// Edge (0,1) is upstream of the start line, so the stage never touches it.
	frame := geo.sample_edge(sp, 0, 1, 0.5)
	testing.expect(t, geo.insert_point(&sp, frame.pos, frame) >= 0)

	after, amsg, aok := geo.compile_stage(sp, start, finish, nil, context.allocator)
	defer delete(after.points)
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
	defer delete(sp.points)
	seed_spline(&sp)
	tail := len(sp.points) - 1
	testing.expect(t, geo.weld_points(&sp, tail, 0))
	pins := []geo.Road_Marker{geo.marker_of(sp, {from = 2, to = 3, t = 0.5})}
	start := geo.marker_of(sp, {from = 0, to = 1, t = 0.1})
	finish := geo.marker_of(sp, {from = tail, to = 0, t = 0.9})

	before, bmsg, bok := geo.compile_stage(sp, start, finish, pins, context.allocator)
	defer delete(before.points)
	testing.expect(t, bok, bmsg)
	if !bok {
		return
	}

	frame := geo.sample_edge(sp, 1, 2, 0.5)
	testing.expect(t, geo.insert_point(&sp, frame.pos, frame) >= 0)

	after, amsg, aok := geo.compile_stage(sp, start, finish, pins, context.allocator)
	testing.expect(t, aok, amsg)
	if !aok {
		return
	}
	defer delete(after.points)
	// One more control point on the way round, and the same road either side.
	testing.expect_value(t, len(after.points), len(before.points) + 1)
}

// Ids are retired, never reissued, so a marker whose road is gone stays gone
// rather than waking up on whatever point is added next.
@(test)
a_removed_point_never_hands_its_id_on :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	m := geo.marker_of(sp, {from = 2, to = 3, t = 0.5})
	testing.expect(t, geo.marker_valid(sp, m))

	geo.remove_point(&sp, 3)
	testing.expect(t, !geo.marker_valid(sp, m), "a marker whose road is gone must not resolve")

	geo.append_point(&sp, {80, 8, 140})
	geo.append_point(&sp, {100, 9, 180})
	testing.expect(t, !geo.marker_valid(sp, m), "a new point took a retired id")
}

// The one case an id cannot answer: a split edge stops existing, so the
// marker unhooks rather than guessing which half holds it.
@(test)
an_insert_on_the_marker_edge_unhooks_it :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	m := geo.marker_of(sp, {from = 1, to = 2, t = 0.7})
	testing.expect(t, geo.marker_valid(sp, m))

	frame := geo.sample_edge(sp, 1, 2, 0.4)
	testing.expect(t, geo.insert_point(&sp, frame.pos, frame) >= 0)
	testing.expect(t, !geo.marker_valid(sp, m), "a split edge must not still answer")
}

@(test)
road_file_round_trips_point_ids :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	frame := geo.sample_edge(doc.spline, 0, 1, 0.5)
	testing.expect(t, geo.insert_point(&doc.spline, frame.pos, frame) >= 0)
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

// Every road written before v9 names its points by array position, and every
// marker written before venue.json v5 holds those same numbers. Handing out
// id = index on load is what makes both keep meaning what they meant.
@(private = "file")
V8_ROAD :: `{
	"format": "dirtbench.stage",
	"version": 8,
	"name": "legacy",
	"points": [
		{"parent": -1, "weld": -1, "pos": [0, 0, 0],  "rot": [0, 0, 0, 1], "width": 8},
		{"parent": 0,  "weld": -1, "pos": [0, 0, 32], "rot": [0, 0, 0, 1], "width": 8},
		{"parent": 1,  "weld": -1, "pos": [0, 0, 64], "rot": [0, 0, 0, 1], "width": 8},
		{"parent": 2,  "weld": -1, "pos": [0, 0, 96], "rot": [0, 0, 0, 1], "width": 8}
	]
}`

@(test)
a_road_written_before_ids_keeps_its_markers :: proc(t: ^testing.T) {
	path := "/tmp/claude-1000/dirtbench-v8-road.json"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(V8_ROAD)) == nil)
	defer os.remove(path)

	doc := doc_defaults()
	defer doc_delete(&doc)
	msg, ok := load_road(&doc, path)
	testing.expect(t, ok, msg)
	if !ok {
		return
	}
	for p, i in doc.spline.points {
		testing.expect_value(t, p.id, i)
	}
	testing.expect_value(t, doc.spline.next_id, len(doc.spline.points))
	// A v4 venue.json wrote array positions. Read as ids they name the same edge.
	old := geo.Road_Marker{from = 2, to = 3, t = 0.5}
	at, resolved := geo.marker_resolve(doc.spline, old)
	testing.expect(t, resolved, "a marker from before ids stopped resolving")
	testing.expect_value(t, at.from, 2)
	testing.expect_value(t, at.to, 3)
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
	"format": "dirtbench.stage",
	"version": 9,
	"name": "bad",
	"points": [
		{"id": 0,  "parent": -1, "weld": -1, "pos": [0, 0, 0],  "rot": [0, 0, 0, 1], "width": 8},
		{"id": -3, "parent": 0,  "weld": -1, "pos": [0, 0, 32], "rot": [0, 0, 0, 1], "width": 8}
	]
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
