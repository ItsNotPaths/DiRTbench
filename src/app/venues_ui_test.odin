package main

import "core:os"
import "core:strings"
import "core:testing"
import "../geo"
import "../gfx"

// One road-network window per venue, and one window per stage. A second open
// of either raises the window that is already there: two views of the same road
// with two caches behind them would disagree the moment either one edited.
@(test)
venue_window_matches_venue_kind_and_stage :: proc(t: ^testing.T) {
	app := App{}
	defer delete(app.editors)
	forest_doc := Venue_Doc{open_venue = "forest"}
	finland_doc := Venue_Doc{open_venue = "finland"}
	forest := Editor{doc = &forest_doc}
	finland := Editor{doc = &finland_doc}
	stage := Editor{doc = &forest_doc, kind = .Stage, stage_id = "route_1"}
	append(&app.editors, &forest, &finland, &stage)

	testing.expect(t, venue_window(&app, "forest", .Venue) == &forest)
	testing.expect(t, venue_window(&app, "finland", .Venue) == &finland)
	testing.expect(t, venue_window(&app, "michigan", .Venue) == nil)

	testing.expect(t, venue_window(&app, "forest", .Stage, "route_1") == &stage)
	testing.expect(t, venue_window(&app, "forest", .Stage, "route_0") == nil, "a stage window answered for another stage")
	testing.expect(t, venue_window(&app, "finland", .Stage, "route_1") == nil, "a stage window answered for another venue")
}

// A stage window is pointed at its stage by id, because the venue window can
// add or remove one at any time and every index after it shifts.
@(test)
a_stage_window_follows_its_stage_by_id :: proc(t: ^testing.T) {
	doc := Venue_Doc{open_venue = "forest"}
	defer delete(doc.routes)
	append(&doc.routes, Venue_Route{id = "route_0"}, Venue_Route{id = "route_1"})
	ed := Editor{doc = &doc, kind = .Stage, stage_id = "route_1", route_sel = -1}

	testing.expect(t, stage_resync(&ed))
	testing.expect_value(t, ed.route_sel, 1)

	ordered_remove(&doc.routes, 0)
	testing.expect(t, stage_resync(&ed))
	testing.expect_value(t, ed.route_sel, 0)

	ordered_remove(&doc.routes, 0)
	testing.expect(t, !stage_resync(&ed), "a window kept a stage that is no longer in the list")
	testing.expect_value(t, ed.route_sel, -1)
}

// The compiled stage is a cache, so two things can go wrong: it serves a stale
// ribbon after the road moved, or it recompiles every frame. `ribbon_gen` is
// the authority on the first, which is why the road is edited here without it.
@(test)
the_stage_cache_recompiles_only_when_its_key_moves :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer geo.spline_free(&doc.spline)
	defer delete(doc.routes)
	seed_spline(&doc.spline)
	append(&doc.routes, Venue_Route{id = "route_0", start = {0, 1, 0.5}, finish = {2, 3, 0.5}})
	defer delete(doc.routes[0].pins)
	ed := Editor{doc = &doc, kind = .Stage, stage_id = "route_0", route_sel = 0}
	defer stage_cache_clear(&ed)

	stage_cache_refresh(&ed)
	testing.expect_value(t, ed.stage.state, Stage_Compile.Ready)
	testing.expect(t, ed.stage.length > 0, "a compiled stage measured zero metres")
	compiled := ed.stage.length

	doc.spline.points[3].xform.translation.x += 200
	stage_cache_refresh(&ed)
	testing.expect_value(t, ed.stage.length, compiled) // the road moved but the key did not

	doc.ribbon_gen += 1
	stage_cache_refresh(&ed)
	testing.expect(t, ed.stage.length > compiled, "a rebuilt ribbon served the old stage")
	moved := ed.stage.length

	doc.routes[0].finish.t = 0.9
	stage_cache_refresh(&ed)
	testing.expect(t, ed.stage.length > moved, "a moved finish line served the old stage")
	longer := ed.stage.length

	// Pins are the fifth input and are not in Stage_Key — a list cannot be
	// compared with `==` — so the cache keeps its own copy and compares that.
	// A pin on no edge at all is the cheapest proof that it recompiled.
	append(&doc.routes[0].pins, geo.Road_Marker{0, 3, 0.5})
	stage_cache_refresh(&ed)
	testing.expect_value(t, ed.stage.state, Stage_Compile.Failed)
	testing.expect_value(t, len(ed.stage.pins), 1)

	ordered_remove(&doc.routes[0].pins, 0)
	stage_cache_refresh(&ed)
	testing.expect_value(t, ed.stage.state, Stage_Compile.Ready)
	testing.expect_value(t, ed.stage.length, longer)
	testing.expect_value(t, len(ed.stage.pins), 0)

	// A marker off any edge compiles to nothing, and the reason is what the
	// panel shows.
	doc.routes[0].finish = {0, 3, 0.5}
	stage_cache_refresh(&ed)
	testing.expect_value(t, ed.stage.state, Stage_Compile.Failed)
	testing.expect(t, len(ed.stage.ribbon) == 0, "a failed compile left a ribbon to draw")
	testing.expect(t, buf_text(ed.stage.msg[:]) != "", "a failed compile gave no reason")
}

// The notes are a second cache on top of the compiled stage, keyed on the pace
// knobs rather than on the stage key: the knobs change no geometry, so a stage
// that has not moved still needs recalling when one of them does.
@(test)
stage_notes_follow_the_ribbon_and_the_pace_knobs :: proc(t: ^testing.T) {
	doc := Venue_Doc{pace = geo.PACE_DEFAULTS}
	defer geo.spline_free(&doc.spline)
	defer delete(doc.routes)
	seed_spline(&doc.spline)
	// A second child of point 1: the venue road forks, which is the case that
	// used to produce no notes at all. The stage itself is one chain.
	spur := geo.make_point({-40, 3, 60}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = 1)
	geo.spline_push(&doc.spline, spur)
	testing.expect(t, !geo.is_linear(doc.spline), "the fork did not take")
	append(&doc.routes, Venue_Route{id = "route_0", start = {0, 1, 0.5}, finish = {2, 3, 0.5}})
	ed := Editor{doc = &doc, kind = .Stage, stage_id = "route_0", route_sel = 0}
	defer stage_cache_clear(&ed)

	stage_cache_refresh(&ed)
	stage_notes_refresh(&ed)
	testing.expect_value(t, ed.stage.notes_pace, doc.pace)
	testing.expect(t, len(ed.stage.notes) > 0, "a compiled stage was called in silence")

	// A knob moves: the notes are stale even though the road never moved.
	doc.pace.r_on = 90
	stage_cache_refresh(&ed)
	stage_notes_refresh(&ed)
	testing.expect_value(t, ed.stage.notes_pace, doc.pace)

	// A stage that will not compile has nothing to call.
	doc.routes[0].finish = {0, 3, 0.5}
	stage_cache_refresh(&ed)
	stage_notes_refresh(&ed)
	testing.expect_value(t, ed.stage.state, Stage_Compile.Failed)
	testing.expect(t, len(ed.stage.notes) == 0, "a failed compile left notes to call")
}

// A document outlives every window but the last. Closing one of two windows on
// a venue must keep its geometry alive for the other, and the window being
// closed must leave the list before the survivors are counted — otherwise the
// scan reads the entry it is about to free.
@(test)
a_document_is_freed_only_with_its_last_window :: proc(t: ^testing.T) {
	app := App{}
	defer delete(app.editors)
	defer delete(app.docs)
	shared, alone := Venue_Doc{open_venue = "shared"}, Venue_Doc{open_venue = "alone"}
	a, b, c := Editor{doc = &shared}, Editor{doc = &shared}, Editor{doc = &alone}
	append(&app.editors, &a, &b, &c)
	append(&app.docs, &shared, &alone)

	testing.expect(t, editors_detach(&app, &a) == nil, "the shared document went with its first window")
	testing.expect_value(t, len(app.editors), 2)
	testing.expect_value(t, len(app.docs), 2)

	testing.expect(t, editors_detach(&app, &c) == &alone, "an only window did not release its document")
	testing.expect_value(t, len(app.docs), 1)

	testing.expect(t, editors_detach(&app, &b) == &shared, "the last window did not release the shared document")
	testing.expect_value(t, len(app.editors), 0)
	testing.expect_value(t, len(app.docs), 0)
}

// A venue document is one file, so the road and the stage list are written
// together. They were not always: the road save used to re-read the file and
// take the stage list from a document that did not have one yet, which threw
// away the stage every new venue starts with.
@(test)
a_written_document_keeps_its_road_and_its_stages :: proc(t: ^testing.T) {
	path := "/tmp/claude-1000/dirtbench-doc-round-trip.json"
	defer os.remove(path)

	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	append(&doc.routes, Venue_Route{
		id     = strings.clone("route_0"),
		name   = strings.clone("FIRST"),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
	})

	p := Venue{format = VENUE_FORMAT, version = VENUE_VERSION, id = "00112233445566aa", name = "moose", base = "finland/finland_rally"}
	msg, ok := venue_doc_write(p, &doc, path)
	testing.expect(t, ok, msg); if !ok { return }

	back, load_msg, loaded := venue_load_path(path, context.temp_allocator)
	testing.expect(t, loaded, load_msg); if !loaded { return }
	testing.expect_value(t, back.base, "finland/finland_rally")
	testing.expect_value(t, len(back.routes), 1)
	testing.expect_value(t, back.routes[0].name, "FIRST")
	testing.expect_value(t, len(back.road.points), len(doc.spline.points))
	// The counter must clear every id in use, or the next stage takes one back.
	testing.expect(t, back.next_route > 0)
}
