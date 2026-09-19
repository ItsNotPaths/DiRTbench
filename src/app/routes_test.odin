package main

import "core:encoding/json"
import "core:os"
import "core:testing"
import "../geo"

// The stage list belongs to the document. The project manager edits it there
// when a window has the venue open, and on a temp copy of venue.json when not.
@(private = "file")
seed_routes :: proc(doc: ^Venue_Doc, n: int) {
	for _ in 0 ..< n {
		routes_add(&doc.routes, &doc.next_route)
	}
}

// A deployed stage has a `track_model` row whose `route_string` is its id and a
// localization key built from it, so an id must never move to another stage —
// and a retired id must never come back, or the new stage inherits the old
// one's deployed directory, its database row and any window still open on it.
@(test)
route_ids_count_up_and_never_come_back :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc, 3)
	testing.expect_value(t, doc.routes[0].id, "route_0")
	testing.expect_value(t, doc.routes[1].id, "route_1")
	testing.expect_value(t, doc.routes[2].id, "route_2")

	// A gap in the middle stays a gap; nothing below it shifts.
	routes_remove(&doc.routes, 1)
	testing.expect_value(t, len(doc.routes), 2)
	testing.expect_value(t, doc.routes[0].id, "route_0")
	testing.expect_value(t, doc.routes[1].id, "route_2")
	routes_add(&doc.routes, &doc.next_route)
	testing.expect_value(t, doc.routes[2].id, "route_3")

	// Nor does removing the highest hand its id back.
	routes_remove(&doc.routes, 2)
	routes_add(&doc.routes, &doc.next_route)
	testing.expect_value(t, doc.routes[2].id, "route_4")

	// Not even when the list is emptied.
	for len(doc.routes) > 0 {
		routes_remove(&doc.routes, 0)
	}
	routes_add(&doc.routes, &doc.next_route)
	testing.expect_value(t, doc.routes[0].id, "route_5")
}

// A venue written before v6 carries no counter, so it is seeded past every id
// already in use rather than restarting at zero.
@(test)
a_venue_without_a_counter_starts_past_its_stages :: proc(t: ^testing.T) {
	p := Venue{routes = []Venue_Route{{id = "route_0"}, {id = "route_4"}, {id = "skipfe"}}}
	venue_route_counter_floor(&p)
	testing.expect_value(t, p.next_route, 5)

	// And it never drags a live counter backwards.
	p.next_route = 9
	venue_route_counter_floor(&p)
	testing.expect_value(t, p.next_route, 9)
}

// Every stage-list edit is addressed by id, because the row the button sits in
// is drawn from a list the document may have changed since.
@(test)
stage_edits_land_on_the_stage_they_name :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer routes_free(&doc.routes)
	seed_routes(&doc, 3)

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
	seed_routes(&doc, 1)
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
	seed_routes(&doc, 2)
	doc.routes[0].start = {from = 1, to = 2, t = 0.25}
	doc.routes[0].finish = {from = 7, to = 8, t = 0.5}
	doc.routes[1].start = {from = 3, to = 4, t = 0.125}
	doc.routes[1].finish = {from = 9, to = 10, t = 0.875}
	append(&doc.routes[1].pins, geo.Road_Marker{5, 6, 0.4}, geo.Road_Marker{6, 7, 0.6})
	doc.routes[1].setup = {from = 11, to = 12, t = 0.75}

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
		testing.expect_value(t, route.setup, doc.routes[i].setup)
		// Pins are ordered: a route read back with them shuffled is a different
		// road, so the order is part of what round-trips.
		testing.expect_value(t, len(route.pins), len(doc.routes[i].pins))
		for pin, j in route.pins {
			testing.expect_value(t, pin, doc.routes[i].pins[j])
		}
	}
}

// venue_load keeps the version the file carried, and every save but the first
// is a re-read plus an edit. A venue created at v3 must not go on calling
// itself v3 once this build has written ids into it.
@(test)
a_saved_venue_claims_this_builds_version :: proc(t: ^testing.T) {
	path := "/tmp/claude-1000/dirtbench-venue-version.json"
	defer os.remove(path)
	p := Venue{format = VENUE_FORMAT, version = 3, id = "vtest", next_route = 2}
	msg, ok := venue_write(p, path)
	testing.expect(t, ok, msg)
	if !ok {
		return
	}

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	back: Venue
	testing.expect(t, json.unmarshal(data, &back, json.DEFAULT_SPECIFICATION, context.temp_allocator) == nil)
	testing.expect_value(t, back.version, VENUE_VERSION)
	testing.expect_value(t, back.next_route, 2)
}
