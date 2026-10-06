package main

// An arena: Battersea with different props, and one party mode per route. It
// has no road and no terrain, so nothing here compiles a stage. The plan is
// docs/plan-party-levels.md.

import "core:fmt"
import "core:slice"
import "core:strings"
import d3 "../d3"

// Every arena is built on this route: the free-roam variant, registered for
// both party modes, with no block-off fences.
ARENA_BASE :: "uk/battersea"
ARENA_BASE_ROUTE :: "route_0"

Venue_Kind :: enum {
	Stage, // a road graph, and stages cut out of it
	Arena, // Battersea's ground, and party-mode routes on it
}

// The file's names for Venue_Kind, for the same reason a guard kind is a name.
VENUE_KIND_KEY := [Venue_Kind]string {
	.Stage = "stage",
	.Arena = "arena",
}

venue_kind_of :: proc(key: string) -> (Venue_Kind, bool) {
	for name, kind in VENUE_KIND_KEY {
		if name == key { return kind, true }
	}
	return .Stage, false
}

venue_kind :: proc(p: Venue) -> Venue_Kind {
	kind, _ := venue_kind_of(p.kind)
	return kind
}

Arena_Mode :: enum {
	Outbreak,
	Transporter,
}

// Also the `game_modes/` directory names.
ARENA_MODE_KEY := [Arena_Mode]string {
	.Outbreak    = "outbreak",
	.Transporter = "transporter",
}

// What the game's menus call them.
ARENA_MODE_LABEL := [Arena_Mode]string {
	.Outbreak    = "Infection",
	.Transporter = "Transporter",
}

ARENA_MODE_NET_RACE := [Arena_Mode]i32 {
	.Outbreak    = d3.NET_RACE_OUTBREAK,
	.Transporter = d3.NET_RACE_TRANSPORTER,
}

arena_mode_of :: proc(key: string) -> (Arena_Mode, bool) {
	for name, mode in ARENA_MODE_KEY {
		if name == key { return mode, true }
	}
	return .Outbreak, false
}

// The net_race_types each route registers under, as registration wants them.
// Nil for a stage venue, which keeps every mode its source route has.
//
// Every route is also a Joyride map. Joyride loads solo, so a level can be
// driven without a second player in a lobby.
arena_net_race_types :: proc(
	p: Venue, allocator := context.temp_allocator,
) -> (types: [][]i32, msg: string, ok: bool) {
	if venue_kind(p) != .Arena {
		return nil, "", true
	}
	types = make([][]i32, len(p.routes), allocator)
	for route, i in p.routes {
		mode, known := arena_mode_of(route.mode)
		if !known {
			return nil, fmt.tprintf("%s has no party mode (%q)", route.id, route.mode), false
		}
		types[i] = slice.clone([]i32{ARENA_MODE_NET_RACE[mode], d3.NET_RACE_JOYRIDE}, allocator)
	}
	return types, "", true
}

// Append a route of one mode. The stage markers stay unplaced: an arena route
// has none, and a zero marker would name a real road edge.
arena_routes_add :: proc(
	routes: ^[dynamic]Venue_Route, next: ^int, mode: Arena_Mode, allocator := context.allocator,
) {
	append(routes, Venue_Route{
		id     = route_id_next(next, allocator),
		name   = strings.clone(fmt.tprintf("%s %d", ARENA_MODE_LABEL[mode], len(routes) + 1), allocator),
		mode   = strings.clone(ARENA_MODE_KEY[mode], allocator),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
		setup  = {from = -1, to = -1},
	})
}

// A new arena, on disk and nowhere else: one route of each mode, and no road.
// No content pack either: the pack is shaders for a generated road surface,
// and an arena draws nothing of its own.
venue_create_arena :: proc(
	vs: ^Install_Scan, name: string, allocator := context.allocator,
) -> (p: Venue, msg: string, ok: bool) {
	if msg, ok = venue_name_free(vs, name); !ok {
		return
	}
	routes := make([dynamic]Venue_Route, allocator)
	next := 0
	for mode in Arena_Mode {
		arena_routes_add(&routes, &next, mode, allocator)
	}
	p = Venue {
		// The one other place an id is minted; see venue_create.
		id         = venue_uuid(allocator),
		format     = strings.clone(VENUE_FORMAT, allocator),
		version    = VENUE_VERSION,
		kind       = strings.clone(VENUE_KIND_KEY[.Arena], allocator),
		name       = strings.clone(strings.trim_space(name), allocator),
		base       = strings.clone(ARENA_BASE, allocator),
		base_route = strings.clone(ARENA_BASE_ROUTE, allocator),
		routes     = routes[:],
		next_route = next,
	}
	if msg, ok = venue_save(p); !ok {
		venue_free(p, allocator)
		return Venue{}, msg, false
	}
	return p, "", true
}

// `--arena-new <name>`: the New arena button, for a machine with no display.
// Writes nothing into the game.
arena_new_headless :: proc(name: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	p, msg, ok := venue_create_arena(&vs, name)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)
	fmt.printfln("created arena %s (%s) on %s/%s, at %s", p.name, p.id, p.base, p.base_route, venue_file(p))
	return true
}
