package main

import "core:encoding/json"
import "core:testing"
import "../geo"

@(private = "file")
seed_routes :: proc(ed: ^Editor, n: int) {
	for _ in 0 ..< n {
		add_route(ed)
	}
}

// A deployed stage has a `track_model` row whose `route_string` is its id and a
// localization key built from it, so an id must never move to another stage.
// The gap a removal leaves is the next id handed out, and nothing else shifts.
@(test)
route_ids_fill_gaps_and_never_renumber :: proc(t: ^testing.T) {
	ed := Editor{}
	defer routes_free(&ed.routes)
	seed_routes(&ed, 3)
	testing.expect_value(t, ed.routes[0].id, "route_0")
	testing.expect_value(t, ed.routes[1].id, "route_1")
	testing.expect_value(t, ed.routes[2].id, "route_2")

	remove_route(&ed, 1)
	testing.expect_value(t, len(ed.routes), 2)
	testing.expect_value(t, ed.routes[0].id, "route_0")
	testing.expect_value(t, ed.routes[1].id, "route_2")

	add_route(&ed)
	testing.expect_value(t, ed.routes[2].id, "route_1")
	testing.expect_value(t, ed.route_sel, 2)
}

// Removing the last stage must leave the selection off the end of the list, not
// pointing past it, or the marker keys write into freed memory.
@(test)
removing_the_last_stage_clears_the_selection :: proc(t: ^testing.T) {
	ed := Editor{}
	defer routes_free(&ed.routes)
	seed_routes(&ed, 1)
	testing.expect(t, selected_route(&ed) != nil)

	remove_route(&ed, 0)
	testing.expect_value(t, ed.route_sel, -1)
	testing.expect(t, selected_route(&ed) == nil, "a removed stage is still selected")
}

// The name field is the only editable copy of a stage name, so it has to follow
// the selection. Left stale, a rename lands on whichever stage was shown last.
@(test)
the_name_field_follows_the_stage_selection :: proc(t: ^testing.T) {
	ed := Editor{}
	defer routes_free(&ed.routes)
	seed_routes(&ed, 2)
	testing.expect_value(t, buf_text(ed.route_name[:]), ed.routes[1].name)

	select_route(&ed, 0)
	testing.expect_value(t, buf_text(ed.route_name[:]), ed.routes[0].name)
}

@(test)
markers_belong_to_the_stage_they_were_placed_on :: proc(t: ^testing.T) {
	ed := Editor{}
	defer routes_free(&ed.routes)
	seed_routes(&ed, 2)

	select_route(&ed, 0)
	selected_route(&ed).start = geo.Road_Marker{from = 1, to = 2, t = 0.25}
	select_route(&ed, 1)
	selected_route(&ed).start = geo.Road_Marker{from = 5, to = 6, t = 0.75}

	testing.expect_value(t, ed.routes[0].start.from, 1)
	testing.expect_value(t, ed.routes[1].start.from, 5)
	testing.expect(t, !route_has_markers(ed.routes[0]), "a stage with no finish reads as complete")
}

// venue.json carries every stage's markers. This is the format claim on its
// own, without the directory layout venue_save needs.
@(test)
venue_json_round_trips_every_stage_marker :: proc(t: ^testing.T) {
	ed := Editor{}
	defer routes_free(&ed.routes)
	seed_routes(&ed, 2)
	ed.routes[0].start = {from = 1, to = 2, t = 0.25}
	ed.routes[0].finish = {from = 7, to = 8, t = 0.5}
	ed.routes[1].start = {from = 3, to = 4, t = 0.125}
	ed.routes[1].finish = {from = 9, to = 10, t = 0.875}

	p := Venue{
		format  = VENUE_FORMAT,
		version = VENUE_VERSION,
		id      = "moose_loop",
		routes  = ed.routes[:],
	}
	data, merr := json.marshal(p, {}, context.temp_allocator)
	testing.expect(t, merr == nil, "could not encode the venue"); if merr != nil { return }

	back: Venue
	uerr := json.unmarshal(data, &back, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, uerr == nil, "could not parse the venue back"); if uerr != nil { return }
	testing.expect_value(t, len(back.routes), 2)
	for route, i in back.routes {
		testing.expect_value(t, route.id, ed.routes[i].id)
		testing.expect_value(t, route.name, ed.routes[i].name)
		testing.expect_value(t, route.start, ed.routes[i].start)
		testing.expect_value(t, route.finish, ed.routes[i].finish)
	}
}
