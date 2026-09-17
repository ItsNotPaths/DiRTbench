package main

// Putting a venue into the game, and taking it out again.
//
// Everything here writes into the installed game: it hardlinks the base venue's
// art into a directory of our own, clones its registration rows into
// database.bin, and keeps a backup of every file it overwrites. venue.odin owns
// the project on our side of that line and never reaches across it.
//
// Two rules the whole file is built around. **Every write is backed up once**
// (`ensure_backup`), so the first deployment of a venue is the only one that
// records what stock looked like. And **a revert only runs in the order it
// staged in** (`revert_order_ok`), because a registration restored before its
// files are gone is a menu entry pointing at nothing.

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
	id, route: string,
	allocator := context.temp_allocator,
) -> (
	dir: string,
	deployed: bool,
) {
	vs := doc.install
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
