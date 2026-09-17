package main

import "core:encoding/json"
import "core:testing"
import "../geo"

// The stage list belongs to the document. The project manager edits it there
// when a window has the venue open, and on a temp copy of venue.json when not.
@(private = "file")
seed_routes :: proc(routes: ^[dynamic]Venue_Route, n: int) {
	for _ in 0 ..< n {
		routes_add(routes)
	}
}

// A deployed stage has a `track_model` row whose `route_string` is its id and a
// localization key built from it, so an id must never move to another stage.
// The gap a removal leaves is the next id handed out, and nothing else shifts.
@(test)
route_ids_fill_gaps_and_never_renumber :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc.routes, 3)
	testing.expect_value(t, doc.routes[0].id, "route_0")
	testing.expect_value(t, doc.routes[1].id, "route_1")
	testing.expect_value(t, doc.routes[2].id, "route_2")

	routes_remove(&doc.routes, 1)
	testing.expect_value(t, len(doc.routes), 2)
	testing.expect_value(t, doc.routes[0].id, "route_0")
	testing.expect_value(t, doc.routes[1].id, "route_2")

	routes_add(&doc.routes)
	testing.expect_value(t, doc.routes[2].id, "route_1")
}

// Every stage-list edit is addressed by id, because the row the button sits in
// is drawn from a list the document may have changed since.
@(test)
stage_edits_land_on_the_stage_they_name :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc.routes, 3)

	route_rename(&doc.routes, route_index(doc.routes[:], "route_1"), "MOOSE LOOP")
	testing.expect_value(t, doc.routes[1].name, "MOOSE LOOP")

	routes_remove(&doc.routes, route_index(doc.routes[:], "route_0"))
	testing.expect_value(t, len(doc.routes), 2)
	testing.expect_value(t, doc.routes[0].name, "MOOSE LOOP")
	testing.expect_value(t, route_index(doc.routes[:], "route_0"), -1)

	// A name that is not there must move nothing, not the first or last stage.
	route_rename(&doc.routes, route_index(doc.routes[:], "route_9"), "NOWHERE")
	testing.expect_value(t, doc.routes[0].name, "MOOSE LOOP")
}

// A stage with one line is not half ready, it is not ready. Compiling it would
// walk from a marker that is not on the road.
@(test)
a_stage_needs_both_lines_to_read_as_complete :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc.routes, 1)
	testing.expect(t, !route_has_markers(doc.routes[0]), "a fresh stage reads as complete")

	doc.routes[0].start = geo.Road_Marker{from = 1, to = 2, t = 0.25}
	testing.expect(t, !route_has_markers(doc.routes[0]), "a stage with no finish reads as complete")

	doc.routes[0].finish = geo.Road_Marker{from = 7, to = 8, t = 0.5}
	testing.expect(t, route_has_markers(doc.routes[0]))
}

// venue.json carries every stage's markers. This is the format claim on its
// own, without the directory layout venue_save needs.
@(test)
venue_json_round_trips_every_stage_marker :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc.routes, 2)
	doc.routes[0].start = {from = 1, to = 2, t = 0.25}
	doc.routes[0].finish = {from = 7, to = 8, t = 0.5}
	doc.routes[1].start = {from = 3, to = 4, t = 0.125}
	doc.routes[1].finish = {from = 9, to = 10, t = 0.875}

	p := Venue{
		format  = VENUE_FORMAT,
		version = VENUE_VERSION,
		id      = "moose_loop",
		routes  = doc.routes[:],
	}
	data, merr := json.marshal(p, {}, context.temp_allocator)
	testing.expect(t, merr == nil, "could not encode the venue"); if merr != nil { return }

	back: Venue
	uerr := json.unmarshal(data, &back, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, uerr == nil, "could not parse the venue back"); if uerr != nil { return }
	testing.expect_value(t, len(back.routes), 2)
	for route, i in back.routes {
		testing.expect_value(t, route.id, doc.routes[i].id)
		testing.expect_value(t, route.name, doc.routes[i].name)
		testing.expect_value(t, route.start, doc.routes[i].start)
		testing.expect_value(t, route.finish, doc.routes[i].finish)
	}
}
