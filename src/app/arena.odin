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

venue_is_arena_base :: proc(venue: d3.Venue) -> bool {
	return fmt.tprintf("%s/%s", venue.location, venue.id) == ARENA_BASE
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

// The start parent of each mode's stock grids.pssg on route_0.
ARENA_START_PARENT := [Arena_Mode]string {
	.Outbreak    = "grid_start_outbreak_0",
	.Transporter = "grid_start_standing_0",
}

// How high a start's ring hangs over the ground it is dropped on: stock drops
// the cars in, 6.4 m up in Infection and 5.4 m in Transporter on route_0.
ARENA_START_LIFT :: f32(5.4)

// The 8 start slots around the ring centre, in the start's own frame (+Z is
// its heading). The same in both modes on route_0; drawn, never written, since
// the export moves the stock ring rather than rebuilding it.
ARENA_START_RING := [8][2]f32 {
	{3.04, -14.47}, {-8.08, -12.38}, {-14.47, -3.04}, {-12.38, 8.08},
	{-3.04, 14.47}, {8.08, 12.38}, {14.47, 3.04}, {12.38, -8.08},
}

// A point a party mode reads: where it stands and which way it faces, in
// radians from +Z toward +X. Zero is unplaced.
Arena_Spot :: struct {
	pos:    [3]f32,
	yaw:    f32,
	placed: bool,
}

// A Transporter flag or drop zone.
Arena_Goal :: d3.Transporter_Goal

// The most capture_the_flag_settings2 asks for, at 8 players. The real
// minimum is not known.
ARENA_MIN_FLAGS :: 2
ARENA_MIN_DROP_ZONES :: 2

ARENA_TRANSPORTER_TRIGGERS :: "game_modes/transporter/triggers_transporter.xml"

arena_goal_counts :: proc(route: Venue_Route) -> (flags, drop_zones: int) {
	for goal in route.goals {
		if goal.drop_zone { drop_zones += 1 } else { flags += 1 }
	}
	return
}

// Stock route_0's flags and drop zones.
arena_stock_goals :: proc(route_dir: string, allocator := context.temp_allocator) -> (goals: []Arena_Goal, msg: string, ok: bool) {
	path := d3.Stock_Path(route_dir, ARENA_TRANSPORTER_TRIGGERS)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if path == "" || err != nil {
		return nil, fmt.tprintf("no stock %s", ARENA_TRANSPORTER_TRIGGERS), false
	}
	return d3.Transporter_Goals(data, allocator)
}

arena_grid_path :: proc(mode: Arena_Mode) -> string {
	return fmt.tprintf("game_modes/%s/grids.pssg", ARENA_MODE_KEY[mode])
}

// Where stock route_0 starts this mode.
arena_stock_start :: proc(route_dir: string, mode: Arena_Mode) -> (spot: Arena_Spot, msg: string, ok: bool) {
	path := d3.Stock_Path(route_dir, arena_grid_path(mode))
	data, err := os.read_entire_file(path, context.temp_allocator)
	if path == "" || err != nil {
		return {}, fmt.tprintf("no stock %s", arena_grid_path(mode)), false
	}
	pos, yaw, start_msg, start_ok := d3.Party_Start(data, ARENA_START_PARENT[mode])
	if !start_ok {
		return {}, start_msg, false
	}
	return {pos = pos, yaw = yaw, placed = true}, "", true
}

// What stops a route from exporting, one line each. Empty when it is ready.
arena_route_problems :: proc(route: Venue_Route, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	if _, known := arena_mode_of(route.mode); !known {
		append(&out, fmt.tprintf("unknown mode %q", route.mode))
	}
	if !route.party_start.placed {
		append(&out, "no start")
	}
	flags, drop_zones := arena_goal_counts(route)
	if route.mode == ARENA_MODE_KEY[.Transporter] {
		if flags < ARENA_MIN_FLAGS {
			append(&out, fmt.tprintf("%d flags, needs %d", flags, ARENA_MIN_FLAGS))
		}
		if drop_zones < ARENA_MIN_DROP_ZONES {
			append(&out, fmt.tprintf("%d drop zones, needs %d", drop_zones, ARENA_MIN_DROP_ZONES))
		}
	} else if len(route.goals) > 0 {
		append(&out, fmt.tprintf("%d flags and drop zones, which only Transporter has", len(route.goals)))
	}
	return out[:]
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

// One row of the baked file.
Arena_Baseline_Row :: struct {
	mesh:  string,
	trees: bool,
	form:  string,
	tier:  string,
	basis: [3][3]f32,
	pos:   [3]f32,
	jpk:   [][2]int, // the stock track.jpk triangles this placement owns
}

// The file's names for the three forms a stock placement takes.
ARENA_FORM_KEY := [D3_Ens_Form]string {
	.None           = "ornament",
	.Static_Body    = "static_body",
	.Dynamic_Entity = "entity",
}

// What the tier pass lets you do with a baseline placement. The fourth tier,
// delete-and-place, is not in the baseline at all: its placements are gone
// from the start, and its meshes are only in the catalogue.
Arena_Tier :: enum u8 {
	Static,      // stays, and its mesh is not placeable
	Place_Only,  // stays, and its mesh is placeable
	Delete_Only, // removable, and its mesh is not placeable
}

ARENA_TIER_KEY := [Arena_Tier]string {
	.Static      = "static",
	.Place_Only  = "addonly",
	.Delete_Only = "deletable",
}

ARENA_TIER_NAMES := [Arena_Tier]string {
	.Static      = "static",
	.Place_Only  = "place-only",
	.Delete_Only = "delete-only",
}

Arena_Baseline :: struct {
	places:    []D3_Place,
	tiers:     []Arena_Tier,
	owned:     [][][2]int, // per placement: runs of track.jpk triangles, [first, count]
	jpk_drop:  []bool,     // the triangles of placements the baseline left out
	catalogue: []Prop_Ref, // the meshes new props may be
}

// The baked baseline. Parsed per call into `allocator`: it is a constant, and
// the callers are a window load, a removal and an export, never a frame.
arena_baseline :: proc(allocator := context.temp_allocator) -> (base: Arena_Baseline, msg: string, ok: bool) {
	file: struct {
		source:     string,
		jpk_drop:   [][2]int,
		catalogue:  []struct{mesh: string, trees: bool},
		placements: []Arena_Baseline_Row,
	}
	if err := json.unmarshal(ARENA_BASELINE_JSON, &file, json.DEFAULT_SPECIFICATION, allocator); err != nil {
		return {}, fmt.tprintf("the baked baseline did not parse: %v", err), false
	}
	base.jpk_drop = arena_runs_mask(nil, file.jpk_drop, allocator)
	n := len(file.placements)
	base.places = make([]D3_Place, n, allocator)
	base.tiers = make([]Arena_Tier, n, allocator)
	base.owned = make([][][2]int, n, allocator)
	for row, i in file.placements {
		form, form_ok := arena_key_of(ARENA_FORM_KEY, row.form)
		tier, tier_ok := arena_key_of(ARENA_TIER_KEY, row.tier)
		if !form_ok || !tier_ok {
			return {}, fmt.tprintf("baseline row %d has form %q, tier %q", i, row.form, row.tier), false
		}
		base.places[i] = {
			ref   = {kind = row.trees ? .Trees_Pssg : .Objects_Pssg, name = row.mesh},
			form  = form,
			basis = row.basis,
			pos   = row.pos,
		}
		base.tiers[i], base.owned[i] = tier, row.jpk
	}
	base.catalogue = make([]Prop_Ref, len(file.catalogue), allocator)
	for entry, i in file.catalogue {
		base.catalogue[i] = {kind = entry.trees ? .Trees_Pssg : .Objects_Pssg, name = entry.mesh}
	}
	return base, "", true
}

// `mask` with every triangle of `runs` set, grown to fit.
@(private = "file")
arena_runs_mask :: proc(mask: []bool, runs: [][2]int, allocator := context.temp_allocator) -> []bool {
	n := len(mask)
	for run in runs {
		n = max(n, run[0] + run[1])
	}
	out := make([]bool, n, allocator)
	copy(out, mask)
	for run in runs {
		for i in run[0] ..< run[0] + run[1] { out[i] = true }
	}
	return out
}

// Which baseline placements a venue's `removed` list names. An entry names a
// placement by mesh, library and position, so a re-bake that adds or drops
// rows cannot move a removal onto another prop. Only delete-only placements
// can be removed; an entry that matches nothing removable is counted, not used.
ARENA_MATCH_M :: 0.01

arena_removed_mask :: proc(
	base: Arena_Baseline, removed: []Stage_Prop, allocator := context.temp_allocator,
) -> (mask: []bool, unmatched: int) {
	mask = make([]bool, len(base.places), allocator)
	outer: for entry in removed {
		kind: Prop_Lib_Kind = entry.trees ? .Trees_Pssg : .Objects_Pssg
		for place, i in base.places {
			if mask[i] || base.tiers[i] != .Delete_Only || place.ref.kind != kind || place.ref.name != entry.name {
				continue
			}
			d := place.pos - entry.pos
			if d.x * d.x + d.y * d.y + d.z * d.z < ARENA_MATCH_M * ARENA_MATCH_M {
				mask[i] = true
				continue outer
			}
		}
		unmatched += 1
	}
	return
}

// The stock track.jpk triangles an arena drops: the baseline's own, plus the
// ones each removed placement owns.
arena_jpk_drop :: proc(base: Arena_Baseline, mask: []bool, allocator := context.temp_allocator) -> []bool {
	drop := base.jpk_drop
	for gone, i in mask {
		if gone {
			drop = arena_runs_mask(drop, base.owned[i], allocator)
		}
	}
	return drop
}

// The baseline placements an arena keeps.
arena_kept_places :: proc(base: Arena_Baseline, mask: []bool, allocator := context.temp_allocator) -> []D3_Place {
	out := make([dynamic]D3_Place, 0, len(base.places), allocator)
	for place, i in base.places {
		if !mask[i] {
			append(&out, place)
		}
	}
	return out[:]
}

// Whether a new prop may be this mesh.
arena_catalogued :: proc(base: Arena_Baseline, ref: Prop_Ref) -> bool {
	for entry in base.catalogue {
		if entry == ref { return true }
	}
	return false
}

@(private = "file")
arena_key_of :: proc(table: [$E]string, key: string) -> (E, bool) {
	for name, value in table {
		if name == key { return value, true }
	}
	return {}, false
}

// --- export -------------------------------------------------------------------

// The route's mode grid: stock, with the start ring moved to the route's start.
@(private = "file")
arena_write_start :: proc(job: ^d3.Export_Job, donor_dir: string, route: Venue_Route) -> (msg: string, ok: bool) {
	mode, _ := arena_mode_of(route.mode)
	path := arena_grid_path(mode)
	stock, err := os.read_entire_file(d3.Stock_Path(donor_dir, path), context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not read the stock %s: %v", path, err), false
	}
	start := route.party_start
	data, set_msg, set_ok := d3.Party_Start_Set(stock, ARENA_START_PARENT[mode], start.pos, start.yaw, context.temp_allocator)
	if !set_ok {
		return fmt.tprintf("%s: %s", path, set_msg), false
	}
	return d3.Write_Out(job, path, data)
}

// Every route of a deployed arena: its placement files from the baseline,
// `track.vis` over them, and the stock `track.jpk` without the collision of
// the props the baseline left out. Nothing else is written; the ground, the
// lighting and the game-mode files stay hardlinked to stock route_0.
arena_export_all :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	for route in p.routes {
		if problems := arena_route_problems(route); len(problems) > 0 {
			return fmt.tprintf("%s: %s", route.id, strings.join(problems, ", ", context.temp_allocator)), false
		}
	}
	_, donor, found := venue_source(vs, p)
	if !found {
		return fmt.tprintf("%s/%s is not playable", p.base, p.base_route), false
	}
	base, baseline_msg, baseline_ok := arena_baseline()
	if !baseline_ok {
		return baseline_msg, false
	}
	mask, unmatched := arena_removed_mask(base, p.road.removed)
	if unmatched > 0 {
		return fmt.tprintf("%d removed props match no removable baseline placement", unmatched), false
	}
	baseline := arena_kept_places(base, mask)
	jpk_drop := arena_jpk_drop(base, mask)
	placed := make([]Prop_Instance, len(p.road.props), context.temp_allocator)
	for pr, i in p.road.props {
		placed[i] = prop_of_stage(pr)
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
		placed_msg, placed_ok := d3_write_placements(&job, donor.dir, nil, placed, nil, baseline)
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
		if grid_msg, wrote := arena_write_start(&job, donor.dir, route); !wrote {
			return fmt.tprintf("%s: %s", route.id, grid_msg), false
		}
		if route.mode == ARENA_MODE_KEY[.Transporter] {
			triggers, built := d3.Transporter_Triggers(route.goals[:], context.temp_allocator)
			if !built {
				return fmt.tprintf("%s: the triggers did not encode", route.id), false
			}
			if write_msg, wrote := d3.Write_Out(&job, ARENA_TRANSPORTER_TRIGGERS, triggers); !wrote {
				return fmt.tprintf("%s: %s", route.id, write_msg), false
			}
		}
		append(&done, fmt.tprintf("%s (%s; track.vis: %s)", route.id, placed_msg, vis_msg))
	}
	return strings.join(done[:], "\n", context.temp_allocator), true
}
