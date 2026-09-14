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
VENUE_VERSION :: 1
VENUE_FILE :: "venue.json"
VENUE_STAGES_DIR :: "stages"

// Display names, one per menu level. The `db_` prefix the game adds to a
// localization key is implied and must not appear here.
Venue_Names :: struct {
	location: string,
	venue:    string,
	stages:   []string,
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
	stages:     []string, // "route_0", "route_1", …; the id the game will use
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
	return p, "", true
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
	}
	if msg, ok = venue_save(p); !ok {
		venue_free(p, allocator)
		return Venue{}, msg, false
	}
	return p, "", true
}

// Add a route to a project and seed its road document, so the editor has
// something to open. Route ids are dense: the new one is always `route_<n>`
// where n is the count, matching how the game numbers them.
venue_add_stage :: proc(
	p: ^Venue,
	display: string,
	allocator := context.allocator,
) -> (
	route: string,
	msg: string,
	ok: bool,
) {
	route = fmt.aprintf("route_%d", len(p.stages), allocator = allocator)

	sp: geo.Spline
	defer delete(sp.points)
	seed_spline(&sp)
	if msg, ok = save_stage_to(sp, venue_stage_path(p.id, route)); !ok {
		delete(route, allocator)
		return "", msg, false
	}

	shown := strings.trim_space(display)
	if shown == "" {
		shown = route
	}
	p.stages = append_owned(p.stages, route, allocator)
	p.names.stages = append_owned(p.names.stages, strings.to_upper(shown, context.temp_allocator), allocator)

	if msg, ok = venue_save(p^); !ok {
		return "", msg, false
	}
	return route, "", true
}

// Grow a plain slice by one owned string. The project is small and saved on
// every change, so a `[dynamic]` in the serialised struct would buy nothing.
@(private = "file")
append_owned :: proc(list: []string, value: string, allocator := context.allocator) -> []string {
	out := make([]string, len(list) + 1, allocator)
	copy(out, list)
	out[len(list)] = strings.clone(value, allocator)
	delete(list, allocator)
	return out
}

// --- headless ----------------------------------------------------------------

// `--venues`: what is under `venues/`, and the stage definitions each holds.
venues_headless :: proc() -> bool {
	list := venues_list()
	defer venues_free(list)
	if len(list) == 0 {
		fmt.printfln("no venues in %s", venues_dir())
		return true
	}
	for p in list {
		fmt.printfln("%s  (location %s, art from %s/%s)", p.id, p.location, p.base, p.base_route)
		for stage, i in p.stages {
			name := i < len(p.names.stages) ? p.names.stages[i] : ""
			fmt.printfln("    %-10s %-20s %s", stage, name, venue_stage_path(p.id, stage))
		}
	}
	return true
}

// `--project-new <id> --base <venue> [--name <shown>]`: the New venue button,
// for a machine with no display. Creates the project and seeds `route_0`.
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

	route, add_msg, added := venue_add_stage(&p, "")
	if !added {
		fmt.println(add_msg)
		return false
	}
	fmt.printfln("created %s from %s, with %s", id, spec, route)
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

	deployment.registration, msg, ok = d3.Prepare_Registration(
		vs.install.root,
		source_route.model_id,
		p.location,
		p.id,
		p.names.location,
		p.names.venue,
		p.stages,
		p.names.stages,
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

	staged, stage_msg, staged_ok := stage_venue_tree(
		deployment.source,
		deployment.source_route,
		p.stages,
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
