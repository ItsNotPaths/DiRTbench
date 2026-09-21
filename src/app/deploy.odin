package main

// Putting a venue into the game, and taking it out again.
//
// Everything here writes into the installed game: it hardlinks the base venue's
// art into a directory of our own, clones its registration rows into
// database.bin, and keeps a one-time stock backup of the registration files it
// overwrites. venue.odin owns the project on our side of that line and never
// reaches across it.
//
// Two rules the whole file is built around. **Stock is copied aside once**
// (`ensure_stock_backup`), before the first write to a registration file. And
// **a revert subtracts**: it takes one venue's rows out of the live database
// rather than restoring a snapshot, so reverts need no order.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import d3 "../d3"

// Where a project's route sits inside the installed game, once the venue has
// been deployed. `false` while it has not: the directory is created by
// deployment, which clones the base's registration and hardlinks its art. Until
// that exists, nothing here writes into the install.
venue_deploy_dir :: proc(
	doc: ^Venue_Doc,
	route: string,
	allocator := context.temp_allocator,
) -> (
	dir: string,
	deployed: bool,
) {
	vs := doc.install
	if !vs.found {
		return "", false
	}
	p, _, ok := venue_of_doc(doc, context.temp_allocator)
	if !ok {
		return "", false
	}
	vdir := venue_dir(p)
	venue, found := d3.install_venue(&vs.install, vdir, vdir)
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

// How a file gets from its source into the staged venue.
//
// Base art is hardlinked: it is 127 MB of it, and it already sits on the game's
// own filesystem. A content pack's own art is copied, because
// `build/content-packs/` sits beside the binary and a hardlink cannot cross a
// filesystem.
@(private = "file")
Place_Mode :: enum {
	Link,
	Copy,
}

@(private = "file")
place_entry :: proc(src, dst: string, file_type: os.File_Type, mode: Place_Mode) -> (msg: string, ok: bool) {
	#partial switch file_type {
	case .Directory:
		return place_tree(src, dst, mode)
	case .Regular:
		if mode == .Copy {
			if copy_err := os.copy_file(dst, src); copy_err != nil {
				return fmt.tprintf("could not copy %s: %v", src, copy_err), false
			}
			return "", true
		}
		if link_err := os.link(src, dst); link_err != nil {
			return fmt.tprintf("could not hardlink %s: %v", src, link_err), false
		}
	case:
		return fmt.tprintf("refusing unsupported file type at %s", src), false
	}
	return "", true
}

@(private = "file")
place_tree :: proc(src, dst: string, mode: Place_Mode) -> (msg: string, ok: bool) {
	if err := os.make_directory_all(dst); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dst, err), false
	}
	infos, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not read %s: %v", src, err), false
	}
	for info in infos {
		if info.name == "." || info.name == ".." || is_backup_name(info.name) {
			continue
		}
		from, _ := filepath.join({src, info.name}, context.temp_allocator)
		to, _ := filepath.join({dst, info.name}, context.temp_allocator)
		if msg, ok = place_entry(from, to, info.type, mode); !ok {
			return
		}
	}
	return "", true
}

// Our own backups, not game content. A base venue that has been written over
// carries them, and linking one in makes a fresh deployment look like it had
// already been exported.
is_backup_name :: proc(name: string) -> bool {
	for suffix in ([]string{".orig", ".stock", ".rallysculpt-stock"}) {
		if strings.has_suffix(name, suffix) {
			return true
		}
	}
	return false
}

// The venue-wide art, staged from the two places it can come from: the stock
// venue for everything the pack does not provide, and the pack's own `local/`
// for everything it does. See content_pack.odin — the manifest is what decides,
// and this is the only reader of that decision.
//
// Route directories are not linked here; stage_venue_tree lays those down from
// the base route, one per stage.
//
// `local_dir` is where the pack's own files are, passed in rather than derived
// so a test can stage one without a pack on disk.
place_venue_root :: proc(pack: Content_Pack, local_dir, src, dst: string) -> (msg: string, ok: bool) {
	if err := os.make_directory_all(dst); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dst, err), false
	}
	infos, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not read %s: %v", src, err), false
	}
	for info in infos {
		if info.name == "." || info.name == ".." || is_backup_name(info.name) {
			continue
		}
		if info.type == .Directory && strings.has_prefix(info.name, "route_") {
			continue
		}
		if pack_provides(pack, info.name) {
			continue
		}
		from, _ := filepath.join({src, info.name}, context.temp_allocator)
		to, _ := filepath.join({dst, info.name}, context.temp_allocator)
		if msg, ok = place_entry(from, to, info.type, .Link); !ok {
			return
		}
	}
	return place_pack_local(pack, local_dir, dst)
}

// Everything the pack provides itself. A name in the manifest with no file
// behind it is an error, not a silent fallback to the base: the pack said it
// owns that entry, and a venue built on it expects the pack's version.
@(private = "file")
place_pack_local :: proc(pack: Content_Pack, local_dir, dst: string) -> (msg: string, ok: bool) {
	if len(pack.local) == 0 {
		return "", true
	}
	for name in pack.local {
		from, _ := filepath.join({local_dir, name}, context.temp_allocator)
		info, stat_err := os.stat(from, context.temp_allocator)
		if stat_err != nil {
			return fmt.tprintf(
				"content pack %s says it provides %s, and %s is not there", pack.id, name, from,
			), false
		}
		to, _ := filepath.join({dst, name}, context.temp_allocator)
		if msg, ok = place_entry(from, to, info.type, .Copy); !ok {
			return
		}
	}
	return "", true
}

// The base venue and base route a project derives from, resolved against the
// live install. Used by deployment, and by anything that needs to read real
// donor content (venue-wide art, placements) a from-scratch export leaves
// untouched.
venue_source :: proc(
	vs: ^Install_Scan,
	p: Venue,
) -> (
	venue: d3.Venue,
	route: d3.Route,
	ok: bool,
) {
	// `p.base` names a content pack. The pack's manifest names the stock venue
	// under it, which is what the install is keyed on.
	location, id, split := base_split(pack_manifest(p.base).base)
	if !split {
		return
	}
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
	database, _ := filepath.join({root, d3.DATABASE_SUBPATH}, context.temp_allocator)
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

// One copy of stock, taken before the first write to a registration file and
// never again. Reverts do not read it; it exists so the install can be put back
// by hand. An older `.rallysculpt-stock` counts.
@(private = "file")
ensure_stock_backup :: proc(path: string) -> (msg: string, ok: bool) {
	for suffix in ([]string{".rallysculpt-stock", ".dirtbench-stock"}) {
		if os.is_file(fmt.tprintf("%s%s", path, suffix)) {
			return "", true
		}
	}
	live, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read %s: %v", path, read_err), false
	}
	backup := fmt.tprintf("%s.dirtbench-stock", path)
	if copy_err := os.copy_file(backup, path); copy_err != nil {
		return fmt.tprintf("could not back up %s: %v", path, copy_err), false
	}
	saved, backup_err := os.read_entire_file(backup, context.temp_allocator)
	if backup_err != nil || !bytes_equal(live, saved) {
		return fmt.tprintf("backup verification failed: %s", backup), false
	}
	return "", true
}

@(private = "file")
write_registration_file :: proc(path: string, data: []u8) -> (msg: string, ok: bool) {
	if write_msg, written := d3.atomic_write_file(path, data); !written {
		return write_msg, false
	}
	actual, verify_err := os.read_entire_file(path, context.temp_allocator)
	if verify_err != nil || !bytes_equal(actual, data) {
		return fmt.tprintf("write verification failed: %s", path), false
	}
	return "", true
}

// Every file is attempted even after one fails, because this is also the
// rollback path: leaving the rest half-written would be worse than the error.
@(private = "file")
write_registration_files :: proc(paths: [3]string, contents: [3][]u8) -> (msg: string, ok: bool) {
	first_error := ""
	for path, i in paths {
		if write_msg, written := write_registration_file(path, contents[i]); !written {
			if first_error == "" {
				first_error = write_msg
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
	pack: Content_Pack,
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
	if msg, ok = place_venue_root(pack, pack_local_dir(pack.id), source.dir, staged); !ok {
		return
	}
	for route in routes {
		route_dst, _ := filepath.join({staged, route}, context.temp_allocator)
		if msg, ok = place_tree(source_route.dir, route_dst, .Link); !ok {
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

venue_already_deployed :: proc(vs: ^Install_Scan, p: Venue) -> bool {
	dir := venue_dir(p)
	installed, found := d3.install_venue(&vs.install, dir, dir)
	return found && d3.venue_playable(installed^)
}

@(private = "file")
venue_deployment_delete :: proc(deployment: ^Venue_Deployment) {
	d3.registration_output_delete(&deployment.registration)
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
	dir := venue_dir(p)
	// The last gate before a name becomes two game directories and a
	// `file_string`, which hold 16 bytes.
	if len(dir) > VENUE_ID_MAX {
		return deployment, fmt.tprintf(
			"%q is %d characters as a directory; the game holds %d — rename it first",
			dir, len(dir), VENUE_ID_MAX,
		), false
	}
	if installed, exists := d3.install_venue(&vs.install, dir, dir); exists {
		if d3.venue_playable(installed^) {
			return deployment, fmt.tprintf("already deployed: %s", p.name), false
		}
		return deployment, "partial or conflicting installation found; refusing to reconcile it", false
	}

	deployment.target, _ = filepath.join(
		{vs.install.root, d3.LOCATIONS_SUBDIR, dir, dir},
		context.temp_allocator,
	)
	if os.exists(deployment.target) {
		return deployment, fmt.tprintf(
			"partial or conflicting directory exists: %s",
			deployment.target,
		), false
	}

	ids, names := route_ids(p)
	deployment.registration, msg, ok = d3.prepare_registration(
		vs.install.root,
		source_route.model_id,
		dir,
		dir,
		p.name,
		p.name,
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
		return fmt.tprintf("already deployed: %s", p.name), true
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

// `previous` is what the three files held before this deployment: a rollback
// for this write only, held in memory so nothing outside this call can depend
// on it.
@(private = "file")
publish_venue_deployment :: proc(
	staged, target: string,
	paths: [3]string,
	previous, replacements: [3][]u8,
) -> (string, bool) {
	if publish_err := os.rename(staged, target); publish_err != nil {
		return fmt.tprintf("could not publish %s: %v", target, publish_err), false
	}
	for path, i in paths {
		if write_msg, written := write_registration_file(path, replacements[i]); !written {
			rollback_msg, rolled_back := write_registration_files(paths, previous)
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
		return fmt.tprintf("already deployed: %s", p.name), true
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
	previous: [3][]u8
	for path, i in paths {
		if msg, ok = ensure_stock_backup(path); !ok {
			return
		}
		read_err: os.Error
		previous[i], read_err = os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			return fmt.tprintf("could not read %s: %v", path, read_err), false
		}
	}

	route_dirs, _ := route_ids(p)
	staged, stage_msg, staged_ok := stage_venue_tree(
		pack_manifest(p.base),
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
		previous,
		replacements,
	)
	published = !os.exists(staged)
	if !ok {
		return
	}
	return fmt.tprintf("%s\ndeployed", venue_deployment_text(deployment)), true
}

// Take this venue's rows out of the live database and delete its deployed
// directory. Order-free: nothing another venue registered is touched.
venue_revert :: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool) {
	if !vs.found {
		return install_scan_status_text(vs), false
	}
	dir := venue_dir(p)
	target, _ := filepath.join(
		{vs.install.root, d3.LOCATIONS_SUBDIR, dir, dir},
		context.temp_allocator,
	)
	if !os.is_dir(target) {
		return fmt.tprintf("%s is not deployed", p.name), false
	}

	paths := registration_paths(vs.install.root)
	if msg, ok = ensure_stock_backup(paths[0]); !ok {
		return
	}
	replacement, summary, prepare_msg, prepared := d3.prepare_unregistration(
		vs.install.root,
		dir,
		dir,
		context.temp_allocator,
	)
	if !prepared {
		return prepare_msg, false
	}
	// Registration first: files left behind by a failed delete are invisible to
	// the game, a menu entry pointing at nothing is not.
	if msg, ok = write_registration_file(paths[0], replacement); !ok {
		return
	}
	if remove_err := os.remove_all(target); remove_err != nil {
		return fmt.tprintf(
			"registration removed but could not delete %s: %v",
			target,
			remove_err,
		), false
	}
	return fmt.tprintf(
		"%s\nreverted %s; document remains at %s",
		summary,
		p.name,
		venue_path(dir),
	), true
}

// Shared scaffold for the --venue-* commands: find, act, print, exit code.
venue_action_headless :: proc(key: string, action: proc(vs: ^Install_Scan, p: Venue) -> (msg: string, ok: bool)) -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)
	p, msg, ok := venue_find(key)
	if !ok {
		fmt.println(msg)
		return false
	}
	defer venue_free(p)
	msg, ok = action(&vs, p)
	fmt.println(msg)
	return ok
}
