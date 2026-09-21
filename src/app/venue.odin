package main

// Our own venue documents: one file per venue, holding its identity, its stage
// list and its road.
//
//     build/maps/<name>.json
//
// Identity and name are two different things, and only one of them is fixed.
// `id` is a 64-bit number minted when the venue is created and never touched
// again; it is what the site knows the venue by, so publishing a new version
// of a renamed venue still lands on the same listing. `name` is soft: it is
// the file name here, the directory the game installs under, and the text the
// game shows. Rename it as often as you like.
//
// Nothing here is a game file. A `.pssg` is an export product, not a document
// anyone edits: the road is the document, and every PSSG, XML and collision
// file is generated from it on the way out. `out/` holds those only when the
// debug detour is on; normally they go straight into the game.
//
// A venue here is a **derivation**, not an original. It owns its stages and
// borrows everything else — terrain, objects, sky, lighting — from a vanilla
// base venue. Deploying one clones the base's `track_model` row and hardlinks
// the base's 127 MB of venue-wide art, which is why a base is not optional.
// Fully custom venues come later.
//
// The file is the only thing that travels. It names its base, and the base's
// content pack is rebuilt out of whatever install the reader has, so a venue
// can be handed to someone else without a single game file going with it.
//
// Nothing in this file touches the game. Deploying one into the install, and
// taking it out again, is deploy.odin.

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../geo"

VENUE_FORMAT :: "dirtbench.venue"
// v12 adds road detachment: `detach_min_m` and `detach_max_m` under `terrain`.
// Both zero is a road joined to its ground, so a v11 venue would have read
// correctly without the bump. It is here anyway, so an older build refuses a
// detached venue outright rather than opening it flat and saving the
// detachment back out as nothing.
// v11 drops `water_depth`. A flooded pad's surface is its own `y`, so the
// height handle is the waterline and the ground under it is whatever it was.
// v10 makes flattening one floor arg among the rest: a pad carries `flatten`
// beside `no_trees`, `no_cover` and `water`, so an outline can flood or clear
// ground it never levels. Every floor key is written every time, and the
// `clear_veg` key a pre-split pad used is gone.
// v9 lifts cliffs off the control points into `road.guards`, which is also
// where snow banks and gutters live. Every `cliff_*` and `span_*` key on a road
// point is gone, and a v8 venue that used them is converted by hand.
// v8 splits identity from name: `id` became a minted 64-bit number and the
// name it used to hold became `name`, which also absorbed `location` and the
// two `names` fields, since all four were only ever the same text twice over.
// v7 was the whole venue in one file, under maps/<id>.json. Nothing reads a v7
// or older venue: the tool was not released, and the venues that existed were
// converted by hand.
VENUE_VERSION :: 12

// Where the venue's thumbnail is taken from: the viewport camera at the moment
// "Use this view" was pressed. Position and angle and nothing else — the lens
// is fixed, so the rest of the shot is not the document's business. The image
// itself is never stored; it is rendered from here when the venue is uploaded.
//
// `set` rather than reading a zero camera as "none": the origin looking down
// the +Z axis is a real framing, and a venue saved there must not silently
// become an unframed one.
Venue_Shot :: struct {
	set:   bool,
	pos:   [3]f32,
	yaw:   f32,
	pitch: f32,
}

// Where this file came from, when it did not come from here. A download fills
// this in; nothing in the tool ever does. It travels with the document on
// purpose — a copy of a copy is still not ours — and the upload panel refuses
// while it is set, so nobody re-publishes someone else's venue under their own
// name by accident.
Venue_Source :: struct {
	site: string,
	slug: string,
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
	// Where the setup screen stands: the pre-race service area, with the car on
	// show and the tuning menu over it. Optional — unplaced, the export leaves
	// it on the start grid.
	setup:  geo.Road_Marker,
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
	id:         string, // 16 lowercase hex digits, minted once, never changed
	// The soft name: file name in maps/, both game directories, and the menu
	// text. `venue_dir` is the form all three directory uses take.
	name:       string,
	base:       string, // "<location>/<venue>" of the vanilla venue it derives from
	base_route: string, // which of the base's routes the registration clones
	// Empty unless this venue was downloaded from a site rather than made here.
	source:     Venue_Source,
	// How the thumbnail is framed. Unset until a window says so.
	shot:       Venue_Shot,
	routes:     []Venue_Route,
	// Names the next stage. Only ever counts up, so an id is never reused.
	next_route: int,
	// The one editable road. Stages are compiled as start/finish paths through
	// this graph; they are not road documents of their own.
	road:       Venue_Road,
}

// --- paths -------------------------------------------------------------------

// Where a venue is filed. Takes the directory form of the name, which is what
// `venue_dir` returns and never the id.
venue_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	file := strings.concatenate({name, STAGE_EXT}, context.temp_allocator)
	joined, _ := filepath.join({maps_dir(context.temp_allocator), file}, allocator)
	return joined
}

// --- identity ----------------------------------------------------------------

// A fresh venue id: 64 bits of system entropy as 16 lowercase hex digits. That
// spelling is deliberate — it is a legal venue directory name and exactly
// VENUE_ID_MAX long, so every check an id passes through, here and on the
// site, accepts it without a special case.
venue_uuid :: proc(allocator := context.allocator) -> string {
	bytes: [8]u8
	crypto.rand_bytes(bytes[:])
	return fmt.aprintf("%016x", transmute(u64)bytes, allocator = allocator)
}

venue_uuid_valid :: proc(id: string) -> bool {
	if len(id) != 16 {
		return false
	}
	for r in id {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}

// --- naming ------------------------------------------------------------------

// The directory form of a venue's name: the file in maps/, the two directories
// the game installs it under, and its `file_string`. Derived on demand rather
// than stored, so a rename cannot leave a second copy of the name behind
// disagreeing with the first.
venue_dir :: proc(p: Venue, allocator := context.temp_allocator) -> string {
	return sanitise_venue_name(p.name, allocator)
}

// Where this venue is filed. Always this rather than `venue_path` when the
// venue itself is in hand: `venue_path` takes a bare string and cannot tell a
// name from an id, and a write addressed by id lands in a file nothing reads.
venue_file :: proc(p: Venue, allocator := context.temp_allocator) -> string {
	return venue_path(venue_dir(p, context.temp_allocator), allocator)
}

// A venue name becomes a directory name, a `file_string` of at most 18 bytes,
// and part of a localization key. Keep it to what all three accept: lower-case
// letters, digits and underscores.
sanitise_venue_name :: proc(raw: string, allocator := context.temp_allocator) -> string {
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

// `track_model.file_string` holds 18 bytes and `folder_string` 16, so a name
// has to fit the shorter of the two. Checked here rather than at deploy, where
// the only honest response would be to make the user rename everything.
VENUE_ID_MAX :: 16

// Whether a venue may take this name. `vs` is the install scan, so a clash
// with a vanilla venue is caught before anything is created. `keep` is the id
// of the venue being renamed, so a rename that changes only the spelling of a
// name is not refused for clashing with itself.
venue_name_free :: proc(
	vs: ^Install_Scan, name: string, keep := "",
) -> (msg: string, ok: bool) {
	dir := sanitise_venue_name(name)
	if strings.trim_space(name) == "" {
		return "a venue needs a name", false
	}
	if len(dir) > VENUE_ID_MAX {
		return fmt.tprintf(
			"%q is %d characters as a directory; the game holds %d", dir, len(dir), VENUE_ID_MAX,
		), false
	}
	if p, _, loaded := venue_load_name(dir, context.temp_allocator); loaded && p.id != keep {
		return fmt.tprintf("a venue named %q already exists here", dir), false
	} else if !loaded && os.exists(venue_path(dir)) {
		return fmt.tprintf("%s is already a file here", venue_path(dir)), false
	}
	if vs.found {
		for venue in vs.install.venues {
			if venue.id == dir || venue.location == dir {
				return fmt.tprintf("the game already has a venue named %q", dir), false
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

// Every venue document in maps/, by file name. The names are what the files
// are called; whether any of them parses is not this procedure's business.
venue_names :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	handle, err := os.open(maps_dir())
	if err != nil {
		return out[:]
	}
	defer os.close(handle)

	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, handle)
	defer os.read_directory_iterator_destroy(&it)
	for info in os.read_directory_iterator(&it) {
		if info.type == .Directory || filepath.ext(info.name) != STAGE_EXT {
			continue
		}
		// info.name is only valid until the iterator advances.
		append(&out, strings.clone(strings.trim_suffix(info.name, STAGE_EXT), allocator))
	}
	slice.sort(out[:])
	return out[:]
}

// Every venue in maps/, sorted by name. A file that does not parse is skipped
// rather than failing the listing: one bad file must not hide the rest.
venues_list :: proc(allocator := context.allocator) -> []Venue {
	out := make([dynamic]Venue, allocator)
	names := venue_names(context.temp_allocator)
	for name in names {
		if p, _, ok := venue_load_name(name, allocator); ok {
			append(&out, p)
		}
	}
	slice.sort_by(out[:], proc(a, b: Venue) -> bool {
		return a.name < b.name
	})
	return out[:]
}

// One venue by its id. Files are named for the venue's name and not its id, so
// the only way from one to the other is to read them until it turns up. Every
// caller of this is something a person asked for — a deploy, an export, a
// save — and never a frame.
venue_load :: proc(
	id: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	if !venue_uuid_valid(id) {
		return Venue{}, fmt.tprintf("%q is not a venue id", id), false
	}
	for name in venue_names(context.temp_allocator) {
		found, _, loaded := venue_load_name(name, context.temp_allocator)
		if loaded && found.id == id {
			return venue_load_name(name, allocator)
		}
	}
	return Venue{}, fmt.tprintf("no venue here has the id %s", id), false
}

// The venue a document belongs to. The document remembers the name it was
// opened under, so this is one read rather than a search by id.
venue_of_doc :: proc(
	doc: ^Venue_Doc,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	return venue_load_name(sanitise_venue_name(doc.venue_name), allocator)
}

// A venue named by a person: on a command line, or anywhere a human types
// rather than picks. A name is the normal case; an id is accepted too, for a
// caller that copied one out of a document. A venue actually named for sixteen
// hex digits would be shadowed by the id reading, which is a fair trade.
venue_find :: proc(
	key: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	if venue_uuid_valid(key) {
		if p, msg, ok = venue_load(key, allocator); ok {
			return
		}
	}
	return venue_load_name(sanitise_venue_name(key), allocator)
}

// One venue by the name it is filed under.
venue_load_name :: proc(
	name: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	path := venue_path(name, context.temp_allocator)
	if p, msg, ok = venue_load_path(path, allocator); !ok {
		return p, msg, false
	}
	// The name inside the file must never be allowed to redirect a read, a
	// write or a deletion at a file other than the one it came out of.
	if venue_dir(p) != name {
		bad := strings.clone(p.name, context.temp_allocator)
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("venue named %q does not match file %q", bad, name), false
	}
	return p, "", true
}

// One venue document, from a path the caller chose. The name is not checked
// against the filename here: save_road writes through this on any path, and the
// crash snapshot reads one back out of its own directory.
venue_load_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return p, fmt.tprintf("could not read %s: %v", path, rerr), false
	}
	return venue_parse(data, path, allocator)
}

// One venue document out of bytes that are not a file yet. A download is
// checked here, before anything of it reaches maps/: the bytes came off the
// network, and the only thing that makes them a venue is that this parses them.
// `label` names them in the messages and nothing else.
venue_parse :: proc(
	data: []u8,
	label: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	if uerr := json.unmarshal(data, &p, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
		return p, fmt.tprintf("could not parse %s: %v", label, uerr), false
	}
	// Refused, and nothing of it kept: a half-read document must not come back
	// looking like a shallow one.
	if p.format != VENUE_FORMAT {
		bad := strings.clone(p.format, context.temp_allocator)
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("not a venue document (format %q)", bad), false
	}
	if p.version != VENUE_VERSION {
		version := p.version
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf(
			"venue document version %d, and this build reads %d",
			version,
			VENUE_VERSION,
		), false
	}
	if !venue_uuid_valid(p.id) {
		bad_id := strings.clone(p.id, context.temp_allocator)
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("venue id %q is not a venue id", bad_id), false
	}
	// Only that the name has a directory form at all. Its length is not
	// checked here: the cap belongs where the name is chosen and where the
	// game is written to, not on the way in, or a venue that somehow acquired
	// a long name could not even be opened to be renamed.
	if p.name == "" || venue_dir(p) == "" {
		bad := strings.clone(p.name, context.temp_allocator)
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("venue name %q is not a usable name", bad), false
	}
	venue_route_counter_floor(&p)
	return p, "", true
}

// The counter may never sit below an id in use, or it hands that id out twice.
venue_route_counter_floor :: proc(p: ^Venue) {
	for r in p.routes {
		if n := d3.route_index(r.id); n != max(int) && n + 1 > p.next_route {
			p.next_route = n + 1
		}
	}
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
	delete(p.name, allocator)
	delete(p.base, allocator)
	delete(p.base_route, allocator)
	delete(p.source.site, allocator)
	delete(p.source.slug, allocator)
	for route in p.routes {
		delete(route.id, allocator)
		delete(route.name, allocator)
		delete(route.pins)
	}
	delete(p.routes, allocator)
}

// --- writing -----------------------------------------------------------------

venue_save :: proc(p: Venue) -> (msg: string, ok: bool) {
	if _, dir_ok := ensure_maps_dir(); !dir_ok {
		return fmt.tprintf("could not create %s", maps_dir()), false
	}
	return venue_write(p, venue_file(p))
}

// The venue `p`, carrying this document's road and stage list, written to
// `path`. Identity comes from `p` and never from the document, which does not
// hold the base venue or the display names.
venue_doc_write :: proc(p: Venue, doc: ^Venue_Doc, path: string) -> (msg: string, ok: bool) {
	out := p
	out.road = road_block(doc, context.temp_allocator)
	out.routes = doc.routes[:]
	out.next_route = doc.next_route
	// The window owns the framing while it is open, the same way it owns the
	// stage list. `p` carries whatever was last read off disk.
	out.shot = doc.shot
	venue_route_counter_floor(&out)
	return venue_write(out, path)
}

// The same document at a path the caller chose. The crash snapshot writes one.
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
	name, base, base_route: string,
	allocator := context.allocator,
) -> (
	p: Venue,
	msg: string,
	ok: bool,
) {
	if msg, ok = venue_name_free(vs, name); !ok {
		return
	}
	if base == "" || base_route == "" {
		return p, "a new venue needs a base venue to take its art from", false
	}

	shown := strings.trim_space(name)
	p = Venue {
		// The one and only place an id is minted.
		id         = venue_uuid(allocator),
		format     = strings.clone(VENUE_FORMAT, allocator),
		version    = VENUE_VERSION,
		name       = strings.clone(shown, allocator),
		base       = strings.clone(base, allocator),
		base_route = strings.clone(base_route, allocator),
		routes     = make([]Venue_Route, 1, allocator),
	}
	// One stage to begin with. It has no markers yet, so the venue says what it
	// still needs rather than looking ready to export.
	p.routes[0] = {
		id     = strings.clone("route_0", allocator),
		name   = strings.clone(shown, allocator),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
		setup  = {from = -1, to = -1},
	}
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	// The stage list goes through the document, because that is where a write
	// takes it from. Handing venue_doc_write a document with no routes is how
	// the first stage was silently lost.
	routes_free(&doc.routes)
	doc.routes = venue_routes(p)
	// The identity above and this seeded road go down in one write.
	if _, dir_ok := ensure_maps_dir(); !dir_ok {
		venue_free(p, allocator)
		return Venue{}, fmt.tprintf("could not create %s", maps_dir()), false
	}
	if msg, ok = venue_doc_write(p, &doc, venue_file(p)); !ok {
		venue_free(p, allocator)
		_ = os.remove(venue_file(p))
		return Venue{}, msg, false
	}
	// The pack is built now, while the base is known good, rather than at
	// export time when a failure costs more. It is usually already there: the
	// first venue on a base pays for it and the rest read it.
	if _, msg, ok = content_pack_profile(vs, p.base); !ok {
		venue_free(p, allocator)
		_ = os.remove(venue_file(p))
		return Venue{}, msg, false
	}
	return p, "", true
}

// A stock venue named as "<location>/<venue>". Both halves are needed: the
// install is keyed on the pair, not on the venue id alone.
base_split :: proc(base: string) -> (location, id: string, ok: bool) {
	slash := strings.index_byte(base, '/')
	if slash < 0 {
		return "", "", false
	}
	return base[:slash], base[slash + 1:], true
}

// The base venue's directory in the install, or "" when it is not there.
base_venue_dir :: proc(vs: ^Install_Scan, base: string) -> string {
	location, id, split := base_split(base)
	if !split || !vs.found {
		return ""
	}
	source, found := d3.install_venue(&vs.install, location, id)
	return found ? source.dir : ""
}

// The shader template a stage draws with, out of the content pack it builds on.
// The pack is built on the spot if this is the first export since the pack
// format moved.
export_profile :: proc(
	vs: ^Install_Scan,
	p: Venue,
	allocator := context.temp_allocator,
) -> (
	out: ^d3.Venue_Profile,
	msg: string,
	ok: bool,
) {
	profile, pack_msg, pack_ok := content_pack_profile(vs, p.base, allocator)
	if !pack_ok {
		return nil, pack_msg, false
	}
	out = new(d3.Venue_Profile, allocator)
	out^ = profile
	return out, "", true
}

// Write the stage list back into the document, leaving the road and the
// identity alone. The editor holds the routes while a road is open; this is how
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
		if load_msg, loaded := doc_load_road(doc, p.road); !loaded {
			return out, load_msg, false
		}
		doc_set_base(doc, p.base)
		doc_take_routes(doc, p)
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
		setup  = {from = -1, to = -1},
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
		geo.marker_follow(&r.setup, split)
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
		r.setup = geo.marker_reversed(r.setup)
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

// Put the venue's stage list on the document. Every path that exports a stage
// needs it: the setup pin lives here, and a document without the list exports
// as if no pin were placed.
doc_take_routes :: proc(doc: ^Venue_Doc, p: Venue) {
	routes_free(&doc.routes)
	doc.routes = venue_routes(p)
	doc.next_route = p.next_route
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
			setup  = r.setup,
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
	if load_msg, loaded := doc_load_road(&doc, p.road); !loaded {
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

// Put a venue in the game: deploy it if it is not there yet, then write every
// stage over the hardlinked art. Idempotent — run it again after a road edit
// and each stage is re-exported.
//
// Deploying alone leaves the base venue's own road in place under a new name,
// so the two halves are one action.
venue_publish :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	// Registration is a one-off; a second publish writes nothing there and says
	// so. What that run really did is re-export, so report the export.
	update := venue_already_deployed(vs, p)
	deploy_msg, deployed := venue_deploy(vs, p)
	if !deployed {
		return deploy_msg, false
	}
	install_scan_rescan(vs)
	export_msg, exported := venue_export_all(vs, p)
	if !exported {
		return fmt.tprintf("%s; export: %s", deploy_msg, export_msg), false
	}
	if update {
		return fmt.tprintf("updated deployed map %s; %s", p.name, export_msg), true
	}
	return fmt.tprintf("%s; %s", deploy_msg, export_msg), true
}

// Every stage of a venue, written into its own deployed route directory. The
// road is loaded once and each stage compiled out of it, so two stages of one
// venue cannot disagree about the road they came from.
venue_export_all :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	target, found := find_target("dirt3")
	if !found {
		return "the Dirt 3 export target is missing", false
	}
	if len(p.routes) == 0 {
		return fmt.tprintf("%s has no stages to export", p.id), false
	}

	doc := doc_defaults()
	defer doc_delete(&doc)
	doc.install = vs
	// The document owns these strings; doc_delete frees them.
	doc.open_venue = strings.clone(p.id)
	doc.venue_name = strings.clone(p.name)
	if load_msg, loaded := doc_load_road(&doc, p.road); !loaded {
		return load_msg, false
	}
	doc_set_base(&doc, p.base)
	doc_take_routes(&doc, p)

	done := make([dynamic]string, context.temp_allocator)
	for route in p.routes {
		if !route_has_markers(route) {
			return fmt.tprintf("%s has no start and finish line yet", route.id), false
		}
		chain, chain_msg, chain_ok := geo.compile_stage(
			doc.spline, route.start, route.finish, route.pins[:], context.temp_allocator,
		)
		if !chain_ok {
			return fmt.tprintf("%s: %s", route.id, chain_msg), false
		}
		if export_msg, exported := export_stage(&doc, chain, route.id, route.id, target); !exported {
			return fmt.tprintf("%s: %s", route.id, export_msg), false
		}
		append(&done, route.id)
	}
	return fmt.tprintf(
		"exported %s",
		strings.join(done[:], ", ", context.temp_allocator),
	), true
}

venue_compiled_delete :: proc(stages: []geo.Spline, allocator := context.allocator) {
	for &stage in stages { geo.spline_free(&stage) }
	delete(stages, allocator)
}

// Delete dirtbench's project directory, reverting a deployed copy first. The
// regular revert path retains its backup and newest-first safety checks.
venue_delete :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	dir := venue_dir(p)
	if dir == "" || len(dir) > VENUE_ID_MAX {
		return fmt.tprintf("refusing unsafe venue name %q", p.name), false
	}
	revert_msg := ""
	if venue_already_deployed(vs, p) {
		if reverted_msg, reverted := venue_revert(vs, p); !reverted {
			return fmt.tprintf("could not unstage %s before deleting it: %s", p.name, reverted_msg), false
		} else {
			revert_msg = reverted_msg
		}
	}
	path := venue_path(dir)
	if err := os.remove(path); err != nil {
		return fmt.tprintf("could not delete %s: %v", path, err), false
	}
	if revert_msg != "" {
		return fmt.tprintf("%s\ndeleted venue %s", revert_msg, p.name), true
	}
	return fmt.tprintf("deleted venue %s", p.name), true
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
		base := fmt.tprintf("%s/%s", venue.location, venue.id)
		art := palette_art(palette_for(base, base, context.temp_allocator))
		profile, msg, ok := d3.Pack_Profile(venue.dir, venue.id, art, context.temp_allocator)
		if ok {
			// One line per material, because what matters per venue is which of
			// them we *made* and which fell back: a fallback is not a failure
			// but it is a surface drawing as another, and only this says so.
			fmt.printfln("%-18s %6d bytes  lod=%s batch=%s", venue.id, len(profile.template), profile.lod, profile.batch)
			for material in d3.Draw_Material {
				name := profile.visual[material]
				note := ""
				switch name {
				case profile.visual[.Road]:
					if material != .Road { note = "  <- fell back to the road" }
				case profile.visual[.Terrain]:
					if material != .Terrain { note = "  <- fell back to the ground" }
				}
				fmt.printfln("    %-12v %-28s%s", material, name, note)
			}
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
		fmt.printfln("%s  (%s, %s)", p.name, p.id, pack_text(p.base, p.base_route))
		// Resolving the profile rebuilds a missing `base/`, so this also
		// repairs a venue made before the pack existed.
		if profile, profile_msg, profile_ok := export_profile(&vs, p, context.temp_allocator);
		   profile_ok {
			fmt.printfln(
				"    shaders        road %s, terrain %s, cliff %s, lod %s",
				profile.visual[.Road], profile.visual[.Terrain], profile.visual[.Cliff], profile.lod,
			)
		} else {
			fmt.printfln("    shaders        none: %s", profile_msg)
		}
		if p.version >= 2 {
			fmt.printfln("    document       %s", venue_file(p))
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
// scope, no route markers involved.
venue_tracksplit_collision :: proc(
	vs: ^Install_Scan,
	p: Venue,
	terrain: bool,
	allocator := context.temp_allocator,
) -> (
	collision: []d3.Collision_Triangle,
	profile: ^d3.Venue_Profile,
	msg: string,
	ok: bool,
) {
	doc := Venue_Doc{
		roughness = 0,
		look      = geo.DEFAULT_LOOK,
		terrain   = geo.TERRAIN_DEFAULTS,
	}
	defer geo.terrain_delete(&doc.terrain)

	if load_msg, loaded := load_road(&doc, venue_file(p)); !loaded {
		return nil, nil, load_msg, false
	}
	defer geo.spline_free(&doc.spline)
	// The document owns the sculpt and the sliders. The flag only forces ground
	// on for a venue that has none.
	doc.terrain.enabled = doc.terrain.enabled || terrain

	g, build_msg, built := build_geometry(&doc, doc.spline)
	defer export_geometry_delete(&g)
	if !built {
		return nil, nil, build_msg, false
	}

	profile, msg, ok = export_profile(vs, p, allocator)
	if !ok {
		return nil, nil, msg, false
	}
	return collision_from_mesh(g.mesh, g.order, allocator), profile, "", true
}

// `--venue-tracksplit <id> [--terrain]`: build `tracksplit.pssg` from a
// venue's whole road network and write it to `out/<id>/`, for inspection
// before `track.vis` is correct at venue scope. Never touches the game.
venue_tracksplit_headless :: proc(key: string, terrain: bool) -> (msg: string, ok: bool) {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	if !vs.found {
		return install_scan_status_text(&vs), false
	}
	p, find_msg, found := venue_find(key, context.temp_allocator)
	if !found {
		return find_msg, false
	}

	collision, profile, build_msg, built := venue_tracksplit_collision(&vs, p, terrain, context.temp_allocator)
	if !built {
		return build_msg, false
	}

	dir, _ := filepath.join({out_dir(), venue_dir(p)}, context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dir, err), false
	}

	return d3.Export_Geometry(&d3.Export_Job{Out = dir, Collision = collision, Profile = profile})
}

// `--project-new <id> --base <venue> [--name <shown>]`: the New venue button,
// for a machine with no display. Creates the project and seeds its road graph.
// Writes nothing into the game.
venue_new_headless :: proc(name, base_id: string) -> bool {
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

	spec := fmt.tprintf("%s/%s", base.location, base.id)
	p, msg, ok := venue_create(&vs, name, spec, base_route)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)

	fmt.printfln("created %s (%s) from %s, at %s", p.name, p.id, spec, venue_file(p))
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
