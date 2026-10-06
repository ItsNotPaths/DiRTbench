package main

// An arena: Battersea with different props, and one party mode per route. It
// has no road and no terrain, so nothing here compiles a stage. The plan is
// docs/plan-party-levels.md.

import "core:encoding/json"
import "core:fmt"
import "core:os"
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

// --- the baseline -------------------------------------------------------------

// The stock placements every arena keeps: Battersea route_0 with the course
// kit taken out, and with what stock hides in both party modes left out. Baked
// by tools/battersea_baseline_bake.py from the tiers painted in the Battersea
// Teardown viewer. See docs/plan-party-levels.md, "The baseline".
ARENA_BASELINE_JSON :: #load("../../assets/d3/battersea_baseline.json")

// One row of the baked file. `tier` is read by the editor, not the export.
Arena_Baseline_Row :: struct {
	mesh:  string,
	trees: bool,
	form:  string,
	tier:  string,
	basis: [3][3]f32,
	pos:   [3]f32,
}

// The file's names for the three forms a stock placement takes.
ARENA_FORM_KEY := [D3_Ens_Form]string {
	.None           = "ornament",
	.Static_Body    = "static_body",
	.Dynamic_Entity = "entity",
}

// The baseline placements, and which triangles of the stock track.jpk belong
// to placements the baseline left out: those are the walls of props that are
// no longer there.
arena_baseline :: proc(
	allocator := context.temp_allocator,
) -> (places: []D3_Place, jpk_drop: []bool, msg: string, ok: bool) {
	file: struct {
		source:     string,
		// Runs of triangle indices: [first, count].
		jpk_drop:   [][2]int,
		placements: []Arena_Baseline_Row,
	}
	if err := json.unmarshal(ARENA_BASELINE_JSON, &file, json.DEFAULT_SPECIFICATION, allocator); err != nil {
		return nil, nil, fmt.tprintf("the baked baseline did not parse: %v", err), false
	}
	if n := len(file.jpk_drop); n > 0 {
		last := file.jpk_drop[n - 1]
		jpk_drop = make([]bool, last[0] + last[1], allocator)
		for run in file.jpk_drop {
			for i in run[0] ..< run[0] + run[1] { jpk_drop[i] = true }
		}
	}
	places = make([]D3_Place, len(file.placements), allocator)
	for row, i in file.placements {
		form, known := arena_form_of(row.form)
		if !known {
			return nil, nil, fmt.tprintf("baseline row %d has form %q", i, row.form), false
		}
		places[i] = {
			ref   = {kind = row.trees ? .Trees_Pssg : .Objects_Pssg, name = row.mesh},
			form  = form,
			basis = row.basis,
			pos   = row.pos,
		}
	}
	return places, jpk_drop, "", true
}

@(private = "file")
arena_form_of :: proc(key: string) -> (D3_Ens_Form, bool) {
	for name, form in ARENA_FORM_KEY {
		if name == key { return form, true }
	}
	return .None, false
}

// --- export -------------------------------------------------------------------

// Every route of a deployed arena: its placement files from the baseline,
// `track.vis` over them, and the stock `track.jpk` without the collision of
// the props the baseline left out. Nothing else is written; the ground, the
// lighting and the game-mode files stay hardlinked to stock route_0.
arena_export_all :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	_, donor, found := venue_source(vs, p)
	if !found {
		return fmt.tprintf("%s/%s is not playable", p.base, p.base_route), false
	}
	baseline, jpk_drop, baseline_msg, baseline_ok := arena_baseline()
	if !baseline_ok {
		return baseline_msg, false
	}
	stock_jpk, read_err := os.read_entire_file(d3.Stock_Path(donor.dir, "track.jpk"), context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read the stock track.jpk: %v", read_err), false
	}
	collision, jpk_msg, jpk_ok := d3.Jpk_Without(stock_jpk, jpk_drop, context.temp_allocator)
	if !jpk_ok {
		return fmt.tprintf("track.jpk: %s", jpk_msg), false
	}
	installed, deployed := d3.install_venue(&vs.install, venue_dir(p), venue_dir(p))
	if !deployed {
		return fmt.tprintf("%s is not in the game yet", p.name), false
	}
	done := make([dynamic]string, context.temp_allocator)
	for route in p.routes {
		dest := ""
		for r in installed.routes {
			if r.id == route.id && d3.route_playable(r) {
				dest = r.dir
			}
		}
		if dest == "" {
			return fmt.tprintf("%s has no deployed directory", route.id), false
		}
		job := d3.Export_Job {
			Name         = route.id,
			Out          = dest,
			Backup       = true,
			Venue_Dir    = installed.dir,
			Route_Index  = route_number(route.id),
			// Cover and water are the donor's, on the donor's ground.
			Vis_Stock    = d3.Stock_Path(donor.dir, "track.vis"),
		}
		placed_msg, placed_ok := d3_write_placements(&job, donor.dir, nil, nil, nil, baseline)
		if !placed_ok {
			return fmt.tprintf("%s: placements: %s", route.id, placed_msg), false
		}
		vis_msg, vis_ok := d3.Write_Track_Vis(&job)
		if !vis_ok {
			return fmt.tprintf("%s: track.vis: %s", route.id, vis_msg), false
		}
		if write_msg, wrote := d3.Write_Out(&job, "track.jpk", collision); !wrote {
			return fmt.tprintf("%s: track.jpk: %s", route.id, write_msg), false
		}
		append(&done, fmt.tprintf("%s (%s; track.vis: %s)", route.id, placed_msg, vis_msg))
	}
	return strings.join(done[:], "\n", context.temp_allocator), true
}
