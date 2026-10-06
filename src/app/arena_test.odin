package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import d3 "../d3"

// Deploy registers each route under the party mode the file gives it. A file
// that lost a mode, or a kind, would deploy as the wrong map list or as a
// stage venue with no road.
@(test)
an_arena_keeps_its_kind_and_route_modes_across_a_write :: proc(t: ^testing.T) {
	path, _ := filepath.join({".", "dirtbench-arena-test.json"}, context.allocator)
	defer delete(path)
	defer os.remove(path)

	routes := make([dynamic]Venue_Route, context.temp_allocator)
	next := 0
	arena_routes_add(&routes, &next, .Transporter, context.temp_allocator)
	arena_routes_add(&routes, &next, .Outbreak, context.temp_allocator)
	p := Venue {
		format     = VENUE_FORMAT,
		version    = VENUE_VERSION,
		kind       = VENUE_KIND_KEY[.Arena],
		id         = "00112233445566aa",
		name       = "yard",
		base       = ARENA_BASE,
		base_route = ARENA_BASE_ROUTE,
		routes     = routes[:],
		next_route = next,
	}
	msg, ok := venue_write(p, path)
	testing.expectf(t, ok, "could not write the arena: %s", msg)

	back, load_msg, loaded := venue_load_path(path, context.allocator)
	defer venue_free(back, context.allocator)
	testing.expectf(t, loaded, "could not read the arena back: %s", load_msg)
	testing.expect_value(t, venue_kind(back), Venue_Kind.Arena)

	types, types_msg, types_ok := arena_net_race_types(back)
	testing.expectf(t, types_ok, "the modes did not resolve: %s", types_msg)
	testing.expect_value(t, len(types), 2)
	testing.expect(t, slice.equal(types[0], []i32{d3.NET_RACE_TRANSPORTER, d3.NET_RACE_JOYRIDE}))
	testing.expect(t, slice.equal(types[1], []i32{d3.NET_RACE_OUTBREAK, d3.NET_RACE_JOYRIDE}))
}

// A route whose mode this build does not know must stop the deploy, not
// register a map that no party mode lists.
@(test)
an_arena_route_without_a_known_mode_is_refused :: proc(t: ^testing.T) {
	p := Venue {
		kind   = VENUE_KIND_KEY[.Arena],
		routes = []Venue_Route{{id = "route_0", mode = "joyride"}},
	}
	_, msg, ok := arena_net_race_types(p)
	testing.expect(t, !ok, "an unknown mode must be refused")
	testing.expectf(t, len(msg) > 0, "a refusal must say why")
}
