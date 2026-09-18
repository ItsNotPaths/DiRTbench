package main

// Our own venue files: the in-house description of a venue and the stage
// definitions inside it. dirtbench owns these; the game install is a deploy
// target, never the source of truth. Verify the game files and these survive.
//
//     build/venues/<id>/
//       venue.json            identity, base venue, display names, stage list
//       stages/route_0.json   the road document, stage.odin's format
//       stages/route_1.json
//
// Nothing here is a game file. A `.pssg` is an export product, not a document
// anyone edits: the stage definition is the document, and every PSSG, XML and
// collision file is generated from it on the way out. `out/` holds those only
// when the debug detour is on; normally they go straight into the game.
//
// A venue here is a **derivation**, not an original. It owns its stages and
// borrows everything else — terrain, objects, sky, lighting — from a vanilla
// base venue. Deploying one clones the base's `track_model` row and hardlinks
// the base's 127 MB of venue-wide art, which is why a base is not optional.
// Fully custom venues come later.
//
// Nothing in this file touches the game. Deploying one into the install, and
// taking it out again, is deploy.odin.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../geo"

VENUE_FORMAT :: "dirtbench.venue"
// v2 owns one venue-wide road.json. Its stages are compiled products, not
// independently edited spline documents.
// v3 gives a stage a start and a finish marker on the venue road graph, so a
// stage compiles out of that graph at export rather than being its own document.
// v4 adds the pins a stage is routed through. An older build reading a v4 file
// would drop them and compile a different road, so the version moves with them.
// v5: a marker's from/to are point ids, not array positions (see
// geo.Road_Marker). road.json v9 migrates as id = array index, so a v4 file
// reads unchanged, but an older build reading ids as positions would put
// every line on the wrong road after one insert.
// v6 carries the stage-id counter. Without it the id came from the lowest free
// `route_N`, so removing a stage handed its id to the next one added.
VENUE_VERSION :: 6
VENUE_FILE :: "venue.json"
VENUE_ROAD_FILE :: "road.json"
VENUE_STAGES_DIR :: "stages"

// Display names, one per menu level. The `db_` prefix the game adds to a
// localization key is implied and must not appear here.
Venue_Names :: struct {
	location: string,
	venue:    string,
	stages:   []string,
}

// One stage: the road between two markers on the venue graph, plus the name the
// game will show. It compiles to a chain when the venue is exported; nothing
// here is a road document of its own.
Venue_Route :: struct {
	id:     string, // "route_0", the directory the game reads
	name:   string, // menu text; the db_ prefix is implied
	start:  geo.Road_Marker,
	finish: geo.Road_Marker,
	// Roads the stage is made to cross between the two lines, in the order they
	// were placed. Without them the compile takes the shortest way round; each
	// one is how a longer way is asked for. Not control points — a pin says
	// which road, not where a point goes.
	pins:   [dynamic]geo.Road_Marker,
}

// The route ids and menu names, in order, as the registration and the staging
// code want them.
route_ids :: proc(p: Venue, allocator := context.temp_allocator) -> (ids, names: []string) {
	ids = make([]string, len(p.routes), allocator)
	names = make([]string, len(p.routes), allocator)
	for route, i in p.routes {
		ids[i] = route.id
		names[i] = route.name
	}
	return
}

// Where this stage sits in the list, or -1.
route_index :: proc(routes: []Venue_Route, id: string) -> int {
	for r, i in routes {
		if r.id == id {
			return i
		}
	}
	return -1
}

route_has_markers :: proc(r: Venue_Route) -> bool {
	return r.start.from >= 0 && r.start.to >= 0 && r.finish.from >= 0 && r.finish.to >= 0
}

// The on-disk shape. Flat and dumb: field names are the JSON keys.
Venue :: struct {
	format:     string,
	version:    int,
	id:         string, // venue directory name, and `file_string`
	location:   string, // location directory name, and `folder_string`
	base:       string, // "<location>/<venue>" of the vanilla venue it derives from
	base_route: string, // which of the base's routes the registration clones
	names:      Venue_Names,
	// v1 and v2 named stages here and in `names.stages`. Both are read on load
	// and migrated into `routes`; nothing writes them any more.
	stages:     []string,
	routes:     []Venue_Route,
	// Names the next stage. Only ever counts up, so an id is never reused.
	// Absent before v6, where it is seeded past every id already in use.
	next_route: int,
}

// --- paths -------------------------------------------------------------------

venue_dir :: proc(id: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({venues_dir(context.temp_allocator), id}, allocator)
	return joined
}

venue_stage_path :: proc(id, route: string, allocator := context.temp_allocator) -> string {
	file := strings.concatenate({route, STAGE_EXT}, context.temp_allocator)
	joined, _ := filepath.join(
		{venue_dir(id, context.temp_allocator), VENUE_STAGES_DIR, file},
		allocator,
	)
	return joined
}

// The editable document belongs to the venue. Stages are later compiled as
// start/finish paths through this graph; they are not separate road documents.
venue_road_path :: proc(id: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({venue_dir(id, context.temp_allocator), VENUE_ROAD_FILE}, allocator)
	return joined
}

// --- naming ------------------------------------------------------------------

// A venue id becomes a directory name, a `file_string` of at most 18 bytes, and
// part of a localization key. Keep it to what all three accept: lower-case
// letters, digits and underscores.
sanitise_venue_id :: proc(raw: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in strings.trim_space(raw) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			strings.write_rune(&b, r)
		case r >= 'A' && r <= 'Z':
			strings.write_rune(&b, r + 32)
		case:
			strings.write_rune(&b, '_')
		}
	}
	out := strings.to_string(b)
	out = strings.trim(out, "_")
	if out == "" {
		return strings.clone("my_venue", allocator)
	}
	return out
}

// `track_model.file_string` holds 18 bytes and `folder_string` 16, so the id has
// to fit the shorter of the two. Checked here rather than at deploy, where the
// only honest response would be to make the user rename everything.
VENUE_ID_MAX :: 16

// Whether a new venue may take this id. `vs` is the install scan, so a
// clash with a vanilla venue is caught before anything is created.
venue_id_free :: proc(vs: ^Install_Scan, id: string) -> (msg: string, ok: bool) {
	if id == "" {
		return "a venue needs a name", false
	}
	if len(id) > VENUE_ID_MAX {
		return fmt.tprintf("%q is %d characters; the game holds %d", id, len(id), VENUE_ID_MAX), false
	}
	if os.exists(venue_dir(id)) {
		return fmt.tprintf("a venue named %q already exists here already", id), false
	}
	if vs.found {
		for venue in vs.install.venues {
			if venue.id == id || venue.location == id {
				return fmt.tprintf("the game already has a venue named %q", id), false
			}
		}
	}
	return "", true
}

// A base has to be a venue whose art suits a rally road, and one the game can
// actually load. Arena and gymkhana venues are not offered, and neither is
// anything half-installed: deriving from an orphan would produce a venue that
// cannot load either.
venue_is_base :: proc(venue: d3.Venue) -> bool {
	if !d3.venue_playable(venue) {
		return false
	}
	return strings.has_suffix(venue.id, "_rally") || strings.has_suffix(venue.id, "_trail")
}

// --- reading -----------------------------------------------------------------

// Every venue under `venues/`, sorted by id. A directory that does not parse
// is skipped rather than failing the listing: one bad file must not hide the
// rest.
venues_list :: proc(allocator := context.allocator) -> []Venue {
	out := make([dynamic]Venue, allocator)
	dir := venues_dir()
	handle, err := os.open(dir)
	if err != nil {
		return out[:]
	}
	defer os.close(handle)

	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, handle)
	defer os.read_directory_iterator_destroy(&it)
	for info in os.read_directory_iterator(&it) {
		if info.type != .Directory {
			continue
		}
		if p, _, ok := venue_load(info.name, allocator); ok {
			append(&out, p)
		}
	}
	slice.sort_by(out[:], proc(a, b: Venue) -> bool {
		return a.id < b.id
	})
	return out[:]
}

venue_load :: proc(
	id: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	path, _ := filepath.join({venue_dir(id, context.temp_allocator), VENUE_FILE}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return p, fmt.tprintf("could not read %s: %v", path, rerr), false
	}
	if uerr := json.unmarshal(data, &p, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
		return p, fmt.tprintf("could not parse %s: %v", path, uerr), false
	}
	if p.format != VENUE_FORMAT {
		return p, fmt.tprintf("not a project file (format %q)", p.format), false
	}
	if p.version > VENUE_VERSION {
		return p, fmt.tprintf(
			"project version %d is newer than this build (%d)",
			p.version,
			VENUE_VERSION,
		), false
	}
	// The manifest is inside venues/<id>; its embedded identity must never be
	// allowed to redirect reads or recursive deletion somewhere else.
	if p.id != id || sanitise_venue_id(p.id) != p.id {
		bad_id := strings.clone(p.id, context.temp_allocator)
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("project id %q does not match directory %q", bad_id, id), false
	}
	venue_migrate_routes(&p, allocator)
	venue_route_counter_floor(&p)
	return p, "", true
}

// The counter may never sit below an id in use, or it hands that id out twice.
// A file written before v6 carries no counter at all.
venue_route_counter_floor :: proc(p: ^Venue) {
	for r in p.routes {
		if n := d3.route_index(r.id); n != max(int) && n + 1 > p.next_route {
			p.next_route = n + 1
		}
	}
}

// A v1 or v2 project lists its stages as bare names. Carry them into `routes`
// with no markers, so an old project opens and says what it is missing rather
// than losing its stage names.
venue_migrate_routes :: proc(p: ^Venue, allocator := context.allocator) {
	if len(p.routes) > 0 || len(p.stages) == 0 {
		return
	}
	routes := make([]Venue_Route, len(p.stages), allocator)
	for id, i in p.stages {
		routes[i] = {
			id     = strings.clone(id, allocator),
			name   = strings.clone(i < len(p.names.stages) ? p.names.stages[i] : id, allocator),
			start  = {from = -1, to = -1},
			finish = {from = -1, to = -1},
		}
	}
	p.routes = routes
}

venues_free :: proc(list: []Venue, allocator := context.allocator) {
	for p in list {
		venue_free(p, allocator)
	}
	delete(list, allocator)
}

venue_free :: proc(p: Venue, allocator := context.allocator) {
	delete(p.format, allocator)
	delete(p.id, allocator)
	delete(p.location, allocator)
	delete(p.base, allocator)
	delete(p.base_route, allocator)
	delete(p.names.location, allocator)
	delete(p.names.venue, allocator)
	for name in p.names.stages {
		delete(name, allocator)
	}
	delete(p.names.stages, allocator)
	for route in p.stages {
		delete(route, allocator)
	}
	delete(p.stages, allocator)
	for route in p.routes {
		delete(route.id, allocator)
		delete(route.name, allocator)
		delete(route.pins)
	}
	delete(p.routes, allocator)
}

// --- writing -----------------------------------------------------------------

venue_save :: proc(p: Venue) -> (msg: string, ok: bool) {
	dir := venue_dir(p.id)
	stages, _ := filepath.join({dir, VENUE_STAGES_DIR}, context.temp_allocator)
	if err := os.make_directory_all(stages); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", stages, err), false
	}
	path, _ := filepath.join({dir, VENUE_FILE}, context.temp_allocator)
	return venue_write(p, path)
}

// The same document at a path the caller chose. The crash snapshot writes one
// of these beside its road, because a venue's stages live in venue.json and a
// road saved without them is a road with no start or finish lines.
venue_write :: proc(p: Venue, path: string) -> (msg: string, ok: bool) {
	out := p
	// What this build writes is this build's format. venue_load keeps the
	// version the file came with, and most writes are a re-read plus an edit,
	// so without this a venue keeps claiming the version it was created at
	// while holding fields no build of that age can read.
	out.version = VENUE_VERSION
	data, merr := json.marshal(out, {pretty = true, use_spaces = true}, context.temp_allocator)
	if merr != nil {
		return fmt.tprintf("could not encode the project: %v", merr), false
	}
	if werr := os.write_entire_file(path, data); werr != nil {
		return fmt.tprintf("could not write %s: %v", path, werr), false
	}
	return "", true
}

// A new venue, on disk and nowhere else. `base` is "<location>/<venue>" naming
// the vanilla venue the art comes from, and `base_route` the route whose
// registration will be cloned.
//
// The project gets its own location, so it appears as its own entry in the
// game's venue menu rather than hiding inside someone else's. That is two more
// database rows at deploy time and both were proven on 2026-09-13.
venue_create :: proc(
	vs: ^Install_Scan,
	id, display, base, base_route: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	if msg, ok = venue_id_free(vs, id); !ok {
		return
	}
	if base == "" || base_route == "" {
		return p, "a new venue needs a base venue to take its art from", false
	}

	shown := strings.trim_space(display)
	if shown == "" {
		shown = id
	}
	p = Venue {
		format     = strings.clone(VENUE_FORMAT, allocator),
		version    = VENUE_VERSION,
		id         = strings.clone(id, allocator),
		location   = strings.clone(id, allocator),
		base       = strings.clone(base, allocator),
		base_route = strings.clone(base_route, allocator),
		names      = {
			location = strings.to_upper(shown, allocator),
			venue    = strings.to_upper(shown, allocator),
			stages   = make([]string, 0, allocator),
		},
		stages     = make([]string, 0, allocator),
		routes     = make([]Venue_Route, 1, allocator),
	}
	// One stage to begin with. It has no markers yet, so the venue says what it
	// still needs rather than looking ready to export.
	p.routes[0] = {
		id     = strings.clone("route_0", allocator),
		name   = strings.to_upper(shown, allocator),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
	}
	if msg, ok = venue_save(p); !ok {
		venue_free(p, allocator)
		return Venue{}, msg, false
	}
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	if msg, ok = save_road(&doc, venue_road_path(p.id)); !ok {
		venue_free(p, allocator)
		_ = os.remove_all(venue_dir(id))
		return Venue{}, msg, false
	}
	// The venue takes its shaders from the base now, while the base is known
	// good, rather than at export time when a failure costs more.
	if msg, ok = venue_pack_install(vs, p); !ok {
		venue_free(p, allocator)
		_ = os.remove_all(venue_dir(id))
		return Venue{}, msg, false
	}
	return p, "", true
}

// The base venue's directory in the install, or "" when it is not there.
venue_base_dir :: proc(vs: ^Install_Scan, p: Venue) -> string {
	slash := strings.index_byte(p.base, '/')
	if slash < 0 || !vs.found {
		return ""
	}
	source, found := d3.install_venue(&vs.install, p.base[:slash], p.base[slash + 1:])
	return found ? source.dir : ""
}

venue_pack_dir :: proc(id: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({venue_dir(id, context.temp_allocator), d3.Profile_Dir}, allocator)
	return joined
}

venue_pack_install :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	base_dir := venue_base_dir(vs, p)
	if base_dir == "" {
		return fmt.tprintf("base venue %s is not installed, so its shaders cannot be read", p.base), false
	}
	detail, installed := d3.Pack_Install(base_dir, venue_pack_dir(p.id), p.id)
	if !installed {
		return fmt.tprintf("could not read the shaders of %s: %s", p.base, detail), false
	}
	return "", true
}

// The shader template a stage draws with. One of ours takes it from its own
// `base/` directory, and a venue made before that directory existed gets it
// built here rather than refusing to export. A stock route target takes the
// shaders of the venue the route lives in.
export_profile :: proc(
	vs: ^Install_Scan,
	venue: string,
	allocator := context.temp_allocator,
) -> (
	out: ^d3.Venue_Profile,
	msg: string,
	ok: bool,
) {
	profile: d3.Venue_Profile
	if venue != "" {
		dir := venue_pack_dir(venue, allocator)
		if !os.exists(dir) {
			p, load_msg, loaded := venue_load(venue, context.temp_allocator)
			if !loaded {
				return nil, load_msg, false
			}
			if msg, ok = venue_pack_install(vs, p); !ok {
				return nil, msg, false
			}
		}
		profile, msg, ok = d3.Profile_Load(dir, allocator)
	} else {
		if !vs.found || vs.venue < 0 {
			return nil, "an export needs one of our venues or a selected route", false
		}
		source := vs.install.venues[vs.venue]
		profile, msg, ok = d3.Pack_Profile(source.dir, source.id, allocator)
	}
	if !ok {
		return nil, msg, false
	}
	out = new(d3.Venue_Profile, allocator)
	out^ = profile
	return out, "", true
}

// Write the stage list back into venue.json, leaving everything else in the
// document alone. The editor holds the routes while a road is open; this is how
// they get home. Re-reading first is what keeps an edit made elsewhere in the
// document — a rename, a base change — from being overwritten by a marker save.
venue_routes_save :: proc(
	id: string, routes: []Venue_Route, next_route: int,
) -> (msg: string, ok: bool) {
	p, load_msg, loaded := venue_load(id, context.temp_allocator)
	if !loaded {
		return load_msg, false
	}
	p.routes = routes
	p.next_route = next_route
	venue_route_counter_floor(&p)
	return venue_save(p)
}

// One named stage of a venue, compiled. The export path takes this when a venue
// stage is the thing being written.
// `veg` and `timing` come off the road document, because they describe the whole
// venue rather than one stage. Skipping them once cost every compiled stage its
// checkpoints.
// `doc` receives the venue's road document, because a compiled stage needs the
// venue's vegetation, timing and terrain as well as its points. Skipping them
// once cost every compiled stage its checkpoints.
venue_compile_route :: proc(
	p: Venue,
	route_id: string,
	doc: ^Venue_Doc,
	allocator := context.allocator,
) -> (out: geo.Spline, msg: string, ok: bool) {
	for route in p.routes {
		if route.id != route_id { continue }
		if !route_has_markers(route) {
			return out, fmt.tprintf("%s has no start and finish line yet", route.id), false
		}
		if load_msg, loaded := load_road(doc, venue_road_path(p.id)); !loaded {
			return out, load_msg, false
		}
		doc.veg.preset = geo.veg_preset_for_base(p.base)
		return geo.compile_stage(doc.spline, route.start, route.finish, route.pins[:], allocator)
	}
	return out, fmt.tprintf("%s has no stage named %q", p.id, route_id), false
}

// Append a stage: a name, and no markers yet. The id is the directory the game
// reads, so it comes off the venue's counter and is never one another stage holds.
routes_add :: proc(routes: ^[dynamic]Venue_Route, next: ^int, allocator := context.allocator) {
	append(routes, Venue_Route{
		id     = route_id_next(next, allocator),
		name   = strings.clone(fmt.tprintf("STAGE %d", len(routes) + 1), allocator),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
	})
}

// Ordered, so the stages keep the order the game's menu shows them in.
routes_remove :: proc(routes: ^[dynamic]Venue_Route, i: int, allocator := context.allocator) {
	if i < 0 || i >= len(routes) {
		return
	}
	delete(routes[i].id, allocator)
	delete(routes[i].name, allocator)
	delete(routes[i].pins)
	ordered_remove(routes, i)
}

// An insert cuts one edge in two, so every line and pin standing on that edge
// moves onto the half that now holds it.
routes_follow_split :: proc(routes: []Venue_Route, split: geo.Edge_Split) {
	for &r in routes {
		geo.marker_follow(&r.start, split)
		geo.marker_follow(&r.finish, split)
		for &p in r.pins {
			geo.marker_follow(&p, split)
		}
	}
}

// Reverse turns every edge round, so every line and pin has to turn with it or
// none of them names a road any more. Pin order stays: a stage still runs from
// its start to its finish, and the compile is undirected.
routes_reverse :: proc(routes: []Venue_Route) {
	for &r in routes {
		r.start = geo.marker_reversed(r.start)
		r.finish = geo.marker_reversed(r.finish)
		for &p in r.pins {
			p = geo.marker_reversed(p)
		}
	}
}

// The menu text only. An id is never renamed.
route_rename :: proc(
	routes: ^[dynamic]Venue_Route, i: int, name: string, allocator := context.allocator,
) {
	if i < 0 || i >= len(routes) {
		return
	}
	delete(routes[i].name, allocator)
	routes[i].name = strings.clone(name, allocator)
}

// The venue's stage list, cloned for the editor to hold and edit.
venue_routes :: proc(p: Venue, allocator := context.allocator) -> [dynamic]Venue_Route {
	out := make([dynamic]Venue_Route, 0, len(p.routes), allocator)
	for r in p.routes {
		pins := make([dynamic]geo.Road_Marker, 0, len(r.pins), allocator)
		append(&pins, ..r.pins[:])
		append(&out, Venue_Route{
			id     = strings.clone(r.id, allocator),
			name   = strings.clone(r.name, allocator),
			start  = r.start,
			finish = r.finish,
			pins   = pins,
		})
	}
	return out
}

routes_free :: proc(routes: ^[dynamic]Venue_Route, allocator := context.allocator) {
	for r in routes {
		delete(r.id, allocator)
		delete(r.name, allocator)
		delete(r.pins)
	}
	delete(routes^)
	routes^ = nil
}

// The next `route_<n>`, counting up and never back.
//
// **Never renumber an existing route, and never reuse a retired id.** A
// deployed venue has a `track_model` row whose `route_string` is this id and a
// localization key built from it, so renaming one orphans both — and handing a
// removed stage's id to a new one makes the new stage inherit the old one's
// deployed directory and database row. An open stage window holds the same id.
// Nothing counts routes, so the number may climb as far as it likes.
route_id_next :: proc(next: ^int, allocator := context.temp_allocator) -> string {
	id := strings.clone(fmt.tprintf("route_%d", next^), allocator)
	next^ += 1
	return id
}

// Compile every stage of a venue out of its one road graph. This is what makes
// a stage real: until it runs, a stage is two markers and a name.
//
// It runs when the venue is exported to the game, not while the road is being
// edited, so a half-drawn branch never has to compile.
venue_compile :: proc(p: Venue, allocator := context.allocator) -> (out: []geo.Spline, msg: string, ok: bool) {
	if len(p.routes) == 0 {
		return nil, fmt.tprintf("%s has no stages to compile", p.id), false
	}
	doc := doc_defaults()
	defer doc_delete(&doc)
	if load_msg, loaded := load_road(&doc, venue_road_path(p.id)); !loaded {
		return nil, load_msg, false
	}

	stages := make([dynamic]geo.Spline, allocator)
	for route in p.routes {
		if !route_has_markers(route) {
			venue_compiled_delete(stages[:], allocator)
			return nil, fmt.tprintf("%s has no start and finish line yet", route.id), false
		}
		stage, stage_msg, stage_ok := geo.compile_stage(
			doc.spline, route.start, route.finish, route.pins[:], allocator,
		)
		if !stage_ok {
			venue_compiled_delete(stages[:], allocator)
			return nil, fmt.tprintf("%s: %s", route.id, stage_msg), false
		}
		append(&stages, stage)
	}
	total := 0
	for stage in stages { total += len(stage.points) }
	return stages[:], fmt.tprintf("%d stages, %d control points", len(stages), total), true
}

venue_compiled_delete :: proc(stages: []geo.Spline, allocator := context.allocator) {
	for stage in stages { delete(stage.points) }
	delete(stages, allocator)
}

// Delete dirtbench's project directory, reverting a deployed copy first. The
// regular revert path retains its backup and newest-first safety checks.
venue_delete :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	if p.id == "" || sanitise_venue_id(p.id) != p.id {
		return fmt.tprintf("refusing unsafe venue id %q", p.id), false
	}
	revert_msg := ""
	if venue_already_deployed(vs, p) {
		if reverted_msg, reverted := venue_revert(vs, p); !reverted {
			return fmt.tprintf("could not unstage %s before deleting it: %s", p.id, reverted_msg), false
		} else {
			revert_msg = reverted_msg
		}
	}
	dir := venue_dir(p.id)
	if err := os.remove_all(dir); err != nil {
		return fmt.tprintf("could not delete %s: %v", dir, err), false
	}
	if revert_msg != "" {
		return fmt.tprintf("%s\ndeleted venue %s", revert_msg, p.id), true
	}
	return fmt.tprintf("deleted venue %s", p.id), true
}

// --- headless ----------------------------------------------------------------

// `--dirt3-pack [<venue>]`: read the shaders out of every venue that can be a
// base, or out of one named venue, and print what its pack would hold. Nothing
// is written. This is the acceptance check for the extractor.
pack_headless :: proc(only: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	if !vs.found {
		fmt.println(install_scan_status_text(&vs))
		return false
	}
	seen, refused := 0, 0
	for venue in vs.install.venues {
		if only != "" ? venue.id != only : !venue_is_base(venue) {
			continue
		}
		seen += 1
		profile, msg, ok := d3.Pack_Profile(venue.dir, venue.id, context.temp_allocator)
		if ok {
			fmt.printfln(
				"%-18s %6d bytes  road=%-26s terrain=%-26s lod=%-24s batch=%s",
				venue.id,
				len(profile.template),
				profile.visual[.Road],
				profile.visual[.Terrain],
				profile.lod,
				profile.batch,
			)
		} else {
			refused += 1
			fmt.printfln("%-18s refused: %s", venue.id, msg)
		}
		// A tracksplit is up to 80 MB, and it lands in temp.
		free_all(context.temp_allocator)
	}
	if seen == 0 {
		fmt.println("no venue matched")
		return false
	}
	fmt.printfln("%d venues, %d refused", seen, refused)
	return refused == 0
}

// `--venues`: what is under `venues/`, and the stage definitions each holds.
venues_headless :: proc() -> bool {
	list := venues_list()
	defer venues_free(list)
	if len(list) == 0 {
		fmt.printfln("no venues in %s", venues_dir())
		return true
	}
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	for p in list {
		fmt.printfln("%s  (location %s, art from %s/%s)", p.id, p.location, p.base, p.base_route)
		// Resolving the profile rebuilds a missing `base/`, so this also
		// repairs a venue made before the pack existed.
		if profile, profile_msg, profile_ok := export_profile(&vs, p.id, context.temp_allocator);
		   profile_ok {
			fmt.printfln(
				"    shaders        road %s, terrain %s, lod %s",
				profile.visual[.Road], profile.visual[.Terrain], profile.lod,
			)
		} else {
			fmt.printfln("    shaders        none: %s", profile_msg)
		}
		if p.version >= 2 {
			fmt.printfln("    road network   %s", venue_road_path(p.id))
		}
		for route in p.routes {
			marks := route_has_markers(route) ? "" : "   [no start/finish yet]"
			fmt.printfln("    %-10s %-20s%s", route.id, route.name, marks)
		}
	}
	return true
}

// `--venue-tracksplit <id> [--terrain]`: build `tracksplit.pssg` from a
// venue's whole road network and write it to `out/<id>/`, for inspection
// before `track.vis` is correct at venue scope. Never touches the game.
// The whole road network's own triangle soup and the venue's shader profile —
// the two things `tracksplit.pssg` is built from, at venue rather than route
// scope, no route markers involved. Shared by the debug converter below and
// by deployment's own venue-wide tracksplit writer.
venue_tracksplit_collision :: proc(
	vs: ^Install_Scan,
	id: string,
	terrain: bool,
	allocator := context.temp_allocator,
) -> (
	collision: []d3.Collision_Triangle,
	ribbon: []geo.Cross_Section,
	profile: ^d3.Venue_Profile,
	msg: string,
	ok: bool,
) {
	doc := Venue_Doc{
		topo      = geo.SAMPLES_PER_SEG,
		roughness = 0,
		terrain   = geo.TERRAIN_DEFAULTS,
	}
	defer geo.terrain_delete(&doc.terrain)

	if load_msg, loaded := load_road(&doc, venue_road_path(id)); !loaded {
		return nil, nil, nil, load_msg, false
	}
	defer delete(doc.spline.points)
	// The document owns the sculpt and the sliders. The flag only forces ground
	// on for a venue that has none.
	doc.terrain.enabled = doc.terrain.enabled || terrain

	defer geo.terrain_field_delete(&doc.terrain_field)
	doc.ribbon = geo.build_ribbon(doc.spline, int(doc.topo), allocator)
	doc.ribbon_gen = 1

	if doc.terrain.enabled {
		geo.terrain_ensure(&doc.terrain, doc.ribbon, doc.topo, doc.roughness)
		arc := geo.ribbon_arc(doc.ribbon)
		ds := geo.sample_spacing(doc.ribbon)
		geo.terrain_field_ensure(&doc.terrain_field, &doc.terrain, doc.ribbon, arc, ds, doc.topo, doc.roughness, doc.ribbon_gen)
	}

	mesh := build_export_mesh(&doc, context.temp_allocator)
	order, _ := sort_faces_by_material(mesh)
	if len(order) == 0 {
		return nil, nil, nil, "nothing to export: the road network has no triangles", false
	}
	collision = collision_from_mesh(mesh, order, allocator)

	profile, msg, ok = export_profile(vs, id, allocator)
	if !ok {
		return nil, nil, nil, msg, false
	}
	return collision, doc.ribbon, profile, "", true
}

// `--venue-tracksplit <id> [--terrain]`: build `tracksplit.pssg` from a
// venue's whole road network and write it to `out/<id>/`, for inspection
// before `track.vis` is correct at venue scope. Never touches the game.
venue_tracksplit_headless :: proc(id: string, terrain: bool) -> (msg: string, ok: bool) {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	if !vs.found {
		return install_scan_status_text(&vs), false
	}

	collision, _, profile, build_msg, built := venue_tracksplit_collision(&vs, id, terrain, context.temp_allocator)
	if !built {
		return build_msg, false
	}

	dir, _ := filepath.join({out_dir(), id}, context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dir, err), false
	}

	return d3.Export_Geometry(&d3.Export_Job{Out = dir, Collision = collision, Profile = profile})
}

// `--project-new <id> --base <venue> [--name <shown>]`: the New venue button,
// for a machine with no display. Creates the project and seeds its road graph.
// Writes nothing into the game.
venue_new_headless :: proc(raw_id, base_id, display: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	if !vs.found {
		fmt.println(install_scan_status_text(&vs))
		return false
	}

	base, base_route, found := find_base(&vs, base_id)
	if !found {
		fmt.printfln(
			"%q is not a usable base: it must be a loadable rally or trail venue; try --dirt3-venues",
			base_id,
		)
		return false
	}

	id := sanitise_venue_id(raw_id)
	spec := fmt.tprintf("%s/%s", base.location, base.id)
	p, msg, ok := venue_create(&vs, id, display, spec, base_route)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)

	fmt.printfln("created %s from %s, with %s", id, spec, venue_road_path(id))
	return true
}

// The named venue and its first loadable route.
@(private = "file")
find_base :: proc(vs: ^Install_Scan, id: string) -> (venue: d3.Venue, route: string, ok: bool) {
	for candidate in vs.install.venues {
		if candidate.id != id || !venue_is_base(candidate) {
			continue
		}
		for r in candidate.routes {
			if d3.route_playable(r) {
				return candidate, r.id, true
			}
		}
		return candidate, "", false
	}
	return
}
