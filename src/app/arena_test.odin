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

// The baseline is stock placements as stock writes them. Some are sheared or
// scaled per axis, which a rotation and one scale cannot hold, so the basis
// must come through exactly as the file has it.
@(test)
the_baseline_keeps_stock_transforms_whole :: proc(t: ^testing.T) {
	base, msg, ok := arena_baseline()
	testing.expectf(t, ok, "the baseline did not load: %s", msg)
	testing.expect(t, len(base.places) > 0, "the baseline is empty")
	non_uniform := 0
	for place in base.places {
		lengths: [3]f32
		for row, i in place.basis {
			lengths[i] = row[0]*row[0] + row[1]*row[1] + row[2]*row[2]
		}
		if abs(lengths[0] - lengths[1]) > 1e-3 || abs(lengths[0] - lengths[2]) > 1e-3 {
			non_uniform += 1
		}
	}
	testing.expect(t, non_uniform > 0, "no non-uniform stock basis survived the load")
}

// A removal names a placement by mesh and position, so it finds the same prop
// again however the list is ordered, and only a delete-only placement can go.
@(test)
removals_name_delete_only_placements :: proc(t: ^testing.T) {
	base, msg, ok := arena_baseline()
	testing.expectf(t, ok, "the baseline did not load: %s", msg)
	deletable, static := -1, -1
	for tier, i in base.tiers {
		if tier == .Delete_Only && deletable < 0 { deletable = i }
		if tier == .Static && static < 0 { static = i }
	}
	testing.expect(t, deletable >= 0 && static >= 0, "the baseline needs both tiers")
	as_removed :: proc(place: D3_Place) -> Stage_Prop {
		return {name = place.ref.name, trees = place.ref.kind == .Trees_Pssg, pos = place.pos}
	}
	mask, unmatched := arena_removed_mask(base, {as_removed(base.places[deletable])})
	testing.expect(t, mask[deletable] && unmatched == 0, "a delete-only placement is removed by its name and position")
	kept := 0
	for gone in mask {
		if gone { kept += 1 }
	}
	testing.expect(t, kept == 1, "one removal removes one placement")

	mask, unmatched = arena_removed_mask(base, {as_removed(base.places[static])})
	testing.expect(t, !mask[static] && unmatched == 1, "a static placement cannot be removed")
}

// A removed placement takes its collision with it, and nothing else does.
@(test)
a_removal_drops_its_collision :: proc(t: ^testing.T) {
	base, msg, ok := arena_baseline()
	testing.expectf(t, ok, "the baseline did not load: %s", msg)
	pick := -1
	for tier, i in base.tiers {
		if tier == .Delete_Only && len(base.owned[i]) > 0 { pick = i; break }
	}
	testing.expect(t, pick >= 0, "no delete-only placement owns collision")
	if pick < 0 { return }
	mask := make([]bool, len(base.places), context.temp_allocator)
	before := arena_jpk_drop(base, mask)
	mask[pick] = true
	after := arena_jpk_drop(base, mask)
	for run in base.owned[pick] {
		for i in run[0] ..< run[0] + run[1] {
			testing.expect(t, after[i], "an owned triangle survived its placement's removal")
		}
	}
	for dropped, i in before {
		testing.expect(t, after[i] == dropped || !dropped, "a removal restored a dropped triangle")
	}
}

// What the window saves is what it reads back: a removal survives a save.
@(test)
a_saved_removal_reloads_as_the_same_placement :: proc(t: ^testing.T) {
	base, msg, ok := arena_baseline()
	testing.expectf(t, ok, "the baseline did not load: %s", msg)
	doc: Venue_Doc
	doc.arena.props = make([]Arena_Prop, len(base.places), context.temp_allocator)
	want := -1
	for place, i in base.places {
		doc.arena.props[i] = {ref = place.ref, pos = place.pos, tier = base.tiers[i]}
		if base.tiers[i] == .Delete_Only { want = i }
	}
	testing.expect(t, want >= 0, "the baseline has no delete-only placement")
	if want < 0 { return }
	doc.arena.props[want].removed = true
	mask, unmatched := arena_removed_mask(base, arena_removed_block(&doc))
	testing.expect(t, mask[want] && unmatched == 0, "the saved removal did not name its placement")
}

// A route exports only with its start placed.
@(test)
a_route_without_a_start_cannot_export :: proc(t: ^testing.T) {
	route := Venue_Route{id = "route_0", mode = ARENA_MODE_KEY[.Outbreak]}
	testing.expect(t, len(arena_route_problems(route)) > 0, "a route with no start was ready")
	route.party_start = {pos = {1, 2, 3}, placed = true}
	testing.expectf(t, len(arena_route_problems(route)) == 0, "a placed start still has problems: %v", arena_route_problems(route))
}
