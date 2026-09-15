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
// Fully custom venues come later; see docs/venue-projects.md.
//
// Nothing in this file touches the game.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
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
VENUE_VERSION :: 3
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
}

venues_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({exe_dir(), "venues"}, allocator)
	return joined
}

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
	return p, "", true
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

	data, merr := json.marshal(p, {pretty = true, use_spaces = true}, context.temp_allocator)
	if merr != nil {
		return fmt.tprintf("could not encode the project: %v", merr), false
	}
	path, _ := filepath.join({dir, VENUE_FILE}, context.temp_allocator)
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
	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	if msg, ok = save_stage_to(sp, venue_road_path(p.id)); !ok {
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

// Write the first stage's two markers back into venue.json, leaving everything
// else in the document alone. The editor holds the markers while a road is
// open; this is how they get home.
venue_markers_save :: proc(id: string, start, finish: geo.Road_Marker) -> (msg: string, ok: bool) {
	p, load_msg, loaded := venue_load(id, context.temp_allocator)
	if !loaded {
		return load_msg, false
	}
	if len(p.routes) == 0 {
		routes := make([]Venue_Route, 1, context.temp_allocator)
		routes[0] = {id = "route_0", name = p.names.venue}
		p.routes = routes
	}
	p.routes[0].start = start
	p.routes[0].finish = finish
	return venue_save(p)
}

// One named stage of a venue, compiled. The export path takes this when a venue
// stage is the thing being written.
// `veg` and `timing` come off the road document, because they describe the whole
// venue rather than one stage. Skipping them once cost every compiled stage its
// checkpoints.
venue_compile_route :: proc(
	p: Venue,
	route_id: string,
	veg: ^geo.Veg_Params = nil,
	timing: ^Timing_Params = nil,
	allocator := context.allocator,
) -> (out: geo.Spline, msg: string, ok: bool) {
	for route in p.routes {
		if route.id != route_id { continue }
		if !route_has_markers(route) {
			return out, fmt.tprintf("%s has no start and finish line yet", route.id), false
		}
		road: geo.Spline
		defer delete(road.points)
		if load_msg, loaded := load_stage_from(&road, venue_road_path(p.id), veg, timing); !loaded {
			return out, load_msg, false
		}
		return geo.compile_stage(road, route.start, route.finish, allocator)
	}
	return out, fmt.tprintf("%s has no stage named %q", p.id, route_id), false
}

// The first stage's markers, or two unset ones when the venue has no stage yet.
venue_markers :: proc(p: Venue) -> (start, finish: geo.Road_Marker) {
	if len(p.routes) == 0 {
		return {from = -1, to = -1}, {from = -1, to = -1}
	}
	return p.routes[0].start, p.routes[0].finish
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
	road: geo.Spline
	defer delete(road.points)
	if load_msg, loaded := load_stage_from(&road, venue_road_path(p.id), nil, nil); !loaded {
		return nil, load_msg, false
	}

	stages := make([dynamic]geo.Spline, allocator)
	for route in p.routes {
		if !route_has_markers(route) {
			venue_compiled_delete(stages[:], allocator)
			return nil, fmt.tprintf("%s has no start and finish line yet", route.id), false
		}
		stage, stage_msg, stage_ok := geo.compile_stage(road, route.start, route.finish, allocator)
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

// Delete only dirtbench's project directory. A deployed venue must first be
// reverted because deleting its source document would strand an installed copy.
venue_delete :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	if venue_already_deployed(vs, p) {
		return fmt.tprintf("revert %s before deleting it", p.id), false
	}
	if p.id == "" || sanitise_venue_id(p.id) != p.id {
		return fmt.tprintf("refusing unsafe venue id %q", p.id), false
	}
	dir := venue_dir(p.id)
	if err := os.remove_all(dir); err != nil {
		return fmt.tprintf("could not delete %s: %v", dir, err), false
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
venue_tracksplit_headless :: proc(id: string, terrain: bool) -> (msg: string, ok: bool) {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	if !vs.found {
		return install_scan_status_text(&vs), false
	}

	road: geo.Spline
	defer delete(road.points)
	if load_msg, loaded := load_stage_from(&road, venue_road_path(id), nil, nil); !loaded {
		return load_msg, false
	}

	ed := Editor{
		topo      = geo.SAMPLES_PER_SEG,
		roughness = 0.5,
		terrain   = geo.TERRAIN_DEFAULTS,
	}
	ed.terrain.enabled = terrain
	defer geo.terrain_delete(&ed.terrain)
	defer geo.terrain_field_delete(&ed.terrain_field)
	ed.spline = road
	ed.ribbon = geo.build_ribbon(ed.spline, int(ed.topo), context.temp_allocator)
	ed.ribbon_gen = 1

	if ed.terrain.enabled {
		geo.terrain_ensure(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
		arc := geo.ribbon_arc(ed.ribbon)
		ds := geo.sample_spacing(ed.ribbon)
		geo.terrain_field_ensure(&ed.terrain_field, &ed.terrain, ed.ribbon, arc, ds, ed.topo, ed.roughness, ed.ribbon_gen)
	}

	mesh := build_export_mesh(&ed, context.temp_allocator)
	order, _ := sort_faces_by_material(mesh)
	if len(order) == 0 {
		return "nothing to export: the road network has no triangles", false
	}
	collision := collision_from_mesh(mesh, order, context.temp_allocator)

	profile, profile_msg, profile_ok := export_profile(&vs, id, context.temp_allocator)
	if !profile_ok {
		return profile_msg, false
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

// Where a project's route sits inside the installed game, once the venue has
// been deployed. `false` while it has not: the directory is created by
// deployment, which clones the base's registration and hardlinks its art. Until
// that exists, nothing here writes into the install.
venue_deploy_dir :: proc(
	ed: ^Editor,
	id, route: string,
	allocator := context.temp_allocator,
) -> (
	dir: string,
	deployed: bool,
) {
	vs := &ed.install
	if !vs.found {
		return "", false
	}
	p, _, ok := venue_load(id, context.temp_allocator)
	if !ok {
		return "", false
	}
	venue, found := d3.install_venue(&vs.install, p.location, p.id)
	if !found {
		return "", false
	}
	for r in venue.routes {
		if r.id == route && d3.route_playable(r) {
			return strings.clone(r.dir, allocator), true
		}
	}
	return "", false
}

// --- deployment -------------------------------------------------------------

@(private = "file")
link_entry :: proc(src, dst: string, file_type: os.File_Type) -> (msg: string, ok: bool) {
	#partial switch file_type {
	case .Directory:
		return link_tree(src, dst)
	case .Regular:
		if link_err := os.link(src, dst); link_err != nil {
			return fmt.tprintf("could not hardlink %s: %v", src, link_err), false
		}
	case:
		return fmt.tprintf("refusing unsupported file type at %s", src), false
	}
	return "", true
}

@(private = "file")
link_tree :: proc(src, dst: string) -> (msg: string, ok: bool) {
	if err := os.make_directory_all(dst); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dst, err), false
	}
	infos, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not read %s: %v", src, err), false
	}
	for info in infos {
		if info.name == "." || info.name == ".." {
			continue
		}
		from, _ := filepath.join({src, info.name}, context.temp_allocator)
		to, _ := filepath.join({dst, info.name}, context.temp_allocator)
		if msg, ok = link_entry(from, to, info.type); !ok {
			return
		}
	}
	return "", true
}

@(private = "file")
link_venue_root :: proc(src, dst: string) -> (msg: string, ok: bool) {
	if err := os.make_directory_all(dst); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dst, err), false
	}
	infos, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not read %s: %v", src, err), false
	}
	for info in infos {
		if info.name == "." || info.name == ".." {
			continue
		}
		if info.type == .Directory && strings.has_prefix(info.name, "route_") {
			continue
		}
		from, _ := filepath.join({src, info.name}, context.temp_allocator)
		to, _ := filepath.join({dst, info.name}, context.temp_allocator)
		if msg, ok = link_entry(from, to, info.type); !ok {
			return
		}
	}
	return "", true
}

@(private = "file")
venue_source :: proc(
	vs: ^Install_Scan,
	p: Venue,
) -> (
	venue: d3.Venue,
	route: d3.Route,
	ok: bool,
) {
	slash := strings.index_byte(p.base, '/')
	if slash < 0 {
		return
	}
	location, id := p.base[:slash], p.base[slash + 1:]
	found_venue, found := d3.install_venue(&vs.install, location, id)
	if !found {
		return
	}
	for candidate in found_venue.routes {
		if candidate.id == p.base_route && d3.route_playable(candidate) {
			return found_venue^, candidate, true
		}
	}
	return
}

@(private = "file")
bytes_equal :: proc(a, b: []u8) -> bool {
	return len(a) == len(b) && (len(a) == 0 || mem.compare(a, b) == 0)
}

@(private = "file")
registration_paths :: proc(root: string) -> [3]string {
	database, _ := filepath.join({root, "database/database.bin"}, context.temp_allocator)
	eng, _ := filepath.join(
		{root, "language/language_extensions_eng.lng"},
		context.temp_allocator,
	)
	use, _ := filepath.join(
		{root, "language/language_extensions_use.lng"},
		context.temp_allocator,
	)
	return {database, eng, use}
}

@(private = "file")
ensure_backup :: proc(path, suffix: string) -> (backup: string, msg: string, ok: bool) {
	backup = fmt.tprintf("%s%s", path, suffix)
	live, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return "", fmt.tprintf("could not read %s: %v", path, read_err), false
	}
	if os.exists(backup) {
		saved, backup_err := os.read_entire_file(backup, context.temp_allocator)
		if backup_err != nil || !bytes_equal(live, saved) {
			return "", fmt.tprintf("existing backup differs from live file: %s", backup), false
		}
		return backup, "", true
	}
	if copy_err := os.copy_file(backup, path); copy_err != nil {
		return "", fmt.tprintf("could not back up %s: %v", path, copy_err), false
	}
	saved, backup_err := os.read_entire_file(backup, context.temp_allocator)
	if backup_err != nil || !bytes_equal(live, saved) {
		return "", fmt.tprintf("backup verification failed: %s", backup), false
	}
	return backup, "", true
}

@(private = "file")
restore_registration_files :: proc(paths, backups: [3]string) -> (msg: string, ok: bool) {
	saved: [3][]u8
	for backup, i in backups {
		read_err: os.Error
		saved[i], read_err = os.read_entire_file(backup, context.temp_allocator)
		if read_err != nil {
			return fmt.tprintf("could not read %s: %v", backup, read_err), false
		}
	}

	first_error := ""
	for path, i in paths {
		if write_msg, written := d3.Atomic_Write(path, saved[i]); !written {
			if first_error == "" {
				first_error = write_msg
			}
			continue
		}
		actual, verify_err := os.read_entire_file(path, context.temp_allocator)
		if verify_err != nil || !bytes_equal(actual, saved[i]) {
			if first_error == "" {
				first_error = fmt.tprintf("restore verification failed: %s", path)
			}
		}
	}
	if first_error != "" {
		return first_error, false
	}
	return "", true
}

@(private = "file")
stage_venue_tree :: proc(
	source: d3.Venue,
	source_route: d3.Route,
	routes: []string,
	target: string,
) -> (
	staged: string,
	msg: string,
	ok: bool,
) {
	parent := filepath.dir(target)
	if err := os.make_directory_all(parent); err != nil && err != os.General_Error.Exist {
		return "", fmt.tprintf("could not create %s: %v", parent, err), false
	}
	temp_path, err := os.make_directory_temp(
		parent,
		".dirtbench-deploy-*",
		context.temp_allocator,
	)
	if err != nil {
		return "", fmt.tprintf("could not stage venue: %v", err), false
	}
	staged = temp_path
	if msg, ok = link_venue_root(source.dir, staged); !ok {
		return
	}
	for route in routes {
		route_dst, _ := filepath.join({staged, route}, context.temp_allocator)
		if msg, ok = link_tree(source_route.dir, route_dst); !ok {
			return
		}
	}
	return staged, "", true
}

@(private = "file")
Venue_Deployment :: struct {
	source:       d3.Venue,
	source_route: d3.Route,
	target:       string,
	registration: d3.Registration_Output,
}

@(private = "file")
venue_already_deployed :: proc(vs: ^Install_Scan, p: Venue) -> bool {
	installed, found := d3.install_venue(&vs.install, p.location, p.id)
	return found && d3.venue_playable(installed^)
}

@(private = "file")
venue_deployment_delete :: proc(deployment: ^Venue_Deployment) {
	d3.Registration_Output_Delete(&deployment.registration)
	deployment^ = {}
}

@(private = "file")
prepare_venue_deployment :: proc(
	vs: ^Install_Scan,
	p: Venue,
) -> (
	deployment: Venue_Deployment,
	msg: string,
	ok: bool,
) {
	// Compiling is what turns two markers into a road, so a venue that cannot
	// compile is not deployable. Do it before anything is written.
	if stages, compile_msg, compiled := venue_compile(p, context.temp_allocator); !compiled {
		return deployment, compile_msg, false
	} else {
		venue_compiled_delete(stages, context.temp_allocator)
	}
	if !vs.found {
		return deployment, install_scan_status_text(vs), false
	}
	source, source_route, found := venue_source(vs, p)
	if !found {
		return deployment, fmt.tprintf("base %s/%s is not playable", p.base, p.base_route), false
	}
	if installed, exists := d3.install_venue(&vs.install, p.location, p.id); exists {
		if d3.venue_playable(installed^) {
			return deployment, fmt.tprintf("already deployed: %s/%s", p.location, p.id), false
		}
		return deployment, "partial or conflicting installation found; refusing to reconcile it", false
	}

	deployment.target, _ = filepath.join(
		{vs.install.root, d3.LOCATIONS_SUBDIR, p.location, p.id},
		context.temp_allocator,
	)
	if os.exists(deployment.target) {
		return deployment, fmt.tprintf(
			"partial or conflicting directory exists: %s",
			deployment.target,
		), false
	}

	ids, names := route_ids(p)
	deployment.registration, msg, ok = d3.Prepare_Registration(
		vs.install.root,
		source_route.model_id,
		p.location,
		p.id,
		p.names.location,
		p.names.venue,
		ids,
		names,
	)
	if !ok {
		return
	}
	deployment.source = source
	deployment.source_route = source_route
	return deployment, "", true
}

@(private = "file")
venue_deployment_text :: proc(deployment: Venue_Deployment) -> string {
	return fmt.tprintf(
		"source: %s/%s\ntarget: %s\n%s",
		deployment.source.dir,
		deployment.source_route.id,
		deployment.target,
		deployment.registration.summary,
	)
}

venue_deploy_preflight :: proc(vs: ^Install_Scan, p: Venue) -> (string, bool) {
	if venue_already_deployed(vs, p) {
		return fmt.tprintf("already deployed: %s/%s", p.location, p.id), true
	}
	deployment, msg, ok := prepare_venue_deployment(vs, p)
	if !ok {
		return msg, false
	}
	defer venue_deployment_delete(&deployment)
	return fmt.tprintf(
		"%s\npreflight complete; no files changed (pass --apply to deploy)",
		venue_deployment_text(deployment),
	), true
}

@(private = "file")
publish_venue_deployment :: proc(
	staged, target: string,
	paths, backups: [3]string,
	replacements: [3][]u8,
) -> (string, bool) {
	if publish_err := os.rename(staged, target); publish_err != nil {
		return fmt.tprintf("could not publish %s: %v", target, publish_err), false
	}
	for path, i in paths {
		if write_msg, written := d3.Atomic_Write(path, replacements[i]); !written {
			rollback_msg, rolled_back := restore_registration_files(paths, backups)
			_ = os.remove_all(target)
			if !rolled_back {
				return fmt.tprintf(
					"%s; rollback also failed: %s",
					write_msg,
					rollback_msg,
				), false
			}
			return fmt.tprintf("%s; deployment rolled back", write_msg), false
		}
	}
	return "", true
}

venue_deploy :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	if venue_already_deployed(vs, p) {
		return fmt.tprintf("already deployed: %s/%s", p.location, p.id), true
	}
	deployment, prepare_msg, prepared := prepare_venue_deployment(vs, p)
	if !prepared {
		return prepare_msg, false
	}
	defer venue_deployment_delete(&deployment)
	paths := registration_paths(vs.install.root)
	replacements := [3][]u8 {
		deployment.registration.database,
		deployment.registration.eng,
		deployment.registration.use,
	}
	backups: [3]string
	backup_suffix := fmt.tprintf(".dirtbench-%s", p.id)
	for path, i in paths {
		backups[i], msg, ok = ensure_backup(path, backup_suffix)
		if !ok {
			return
		}
	}

	route_dirs, _ := route_ids(p)
	staged, stage_msg, staged_ok := stage_venue_tree(
		deployment.source,
		deployment.source_route,
		route_dirs,
		deployment.target,
	)
	if !staged_ok {
		return stage_msg, false
	}
	published := false
	defer if !published && os.exists(staged) {
		_ = os.remove_all(staged)
	}
	msg, ok = publish_venue_deployment(
		staged,
		deployment.target,
		paths,
		backups,
		replacements,
	)
	published = !os.exists(staged)
	if !ok {
		return
	}
	return fmt.tprintf("%s\ndeployed", venue_deployment_text(deployment)), true
}

@(private = "file")
revert_order_ok :: proc(vs: ^Install_Scan, p: Venue, database_backup: []u8) -> (string, bool) {
	projects := venues_list(context.temp_allocator)
	for other in projects {
		if other.id == p.id {
			continue
		}
		installed, found := d3.install_venue(&vs.install, other.location, other.id)
		if !found || !d3.venue_playable(installed^) {
			continue
		}
		if !d3.Database_Bytes_Have_Venue(database_backup, other.location, other.id) {
			return fmt.tprintf(
				"revert %s before %s; deployments must be reverted newest first",
				other.id,
				p.id,
			), false
		}
	}
	return "", true
}

venue_revert :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	if !vs.found {
		return install_scan_status_text(vs), false
	}
	target, _ := filepath.join(
		{vs.install.root, d3.LOCATIONS_SUBDIR, p.location, p.id},
		context.temp_allocator,
	)
	if !os.is_dir(target) {
		return fmt.tprintf("%s is not deployed", p.id), false
	}

	paths := registration_paths(vs.install.root)
	backups: [3]string
	for path, i in paths {
		backups[i] = fmt.tprintf("%s.dirtbench-%s", path, p.id)
		if !os.is_file(backups[i]) {
			return fmt.tprintf("missing verified backup: %s", backups[i]), false
		}
	}
	database_backup, read_err := os.read_entire_file(backups[0], context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read %s: %v", backups[0], read_err), false
	}
	if msg, ok = revert_order_ok(vs, p, database_backup); !ok {
		return
	}
	if msg, ok = restore_registration_files(paths, backups); !ok {
		return
	}
	if remove_err := os.remove_all(target); remove_err != nil {
		return fmt.tprintf(
			"registration restored but could not remove %s: %v",
			target,
			remove_err,
		), false
	}
	return fmt.tprintf("reverted %s; project remains at %s", p.id, venue_dir(p.id)), true
}

venue_deploy_preflight_headless :: proc(id: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	p, msg, ok := venue_load(id)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)
	msg, ok = venue_deploy_preflight(&vs, p)
	fmt.println(msg)
	return ok
}

venue_deploy_headless :: proc(id: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	p, msg, ok := venue_load(id)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)
	msg, ok = venue_deploy(&vs, p)
	fmt.println(msg)
	return ok
}

venue_revert_headless :: proc(id: string) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	p, msg, ok := venue_load(id)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)
	msg, ok = venue_revert(&vs, p)
	fmt.println(msg)
	return ok
}
