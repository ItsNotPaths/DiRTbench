package main

// The editor's view of the installed game: one scan, shared by the venue
// screen and by the export destination.
//
// This is a cache of `d3.install_open`, which reads `database.bin` and
// cross-checks the filesystem. Nothing here writes to the game.
//
// The install directory is machine-local and lives in `dirtbench.conf` beside
// the binary, key `install_dir`. See config.odin for the grammar.

import "core:fmt"
import "core:os"
import "core:strings"
import d3 "../d3"

D3_INSTALL_KEY :: "install_dir"

Install_Scan :: struct {
	install: d3.Install,
	found:   bool,
	status:  string, // why the last scan failed, when it did
	venue:   int,    // index into install.venues, -1 for none
	route:   int,    // index into that venue's routes, -1 for none
}

install_scan_init :: proc(vs: ^Install_Scan) {
	install_scan_rescan(vs)
}

install_scan_delete :: proc(vs: ^Install_Scan) {
	if vs.found {
		d3.install_delete(&vs.install)
	}
	delete(vs.status)
	vs^ = {}
}

// Re-read the install from disk. Safe to call at any time; the previous scan is
// released first, and the selection is dropped because its indices no longer
// mean anything.
install_scan_rescan :: proc(vs: ^Install_Scan) {
	if vs.found {
		d3.install_delete(&vs.install)
	}
	delete(vs.status)
	vs.found, vs.status = false, ""
	vs.venue, vs.route = -1, -1

	root, have_root := d3_install_dir()
	if !have_root {
		vs.status = strings.clone(
			fmt.tprintf("no %s in %s", D3_INSTALL_KEY, conf_path()),
		)
		return
	}
	inst, msg, ok := d3.install_open(root)
	if !ok {
		vs.status = strings.clone(msg)
		return
	}
	vs.install, vs.found = inst, true
}

// The selected route's directory, or "" when nothing is selected.
install_scan_route_dir :: proc(vs: ^Install_Scan) -> string {
	if !vs.found || vs.venue < 0 || vs.route < 0 {
		return ""
	}
	return vs.install.venues[vs.venue].routes[vs.route].dir
}

// Select a route by name: `<venue>/<route_n>`, e.g. `finland_rally/route_0`.
// The location is not part of it — venue ids are unique across the install.
install_scan_select :: proc(vs: ^Install_Scan, spec: string) -> (msg: string, ok: bool) {
	if !vs.found {
		return install_scan_status_text(vs), false
	}
	slash := strings.index_byte(spec, '/')
	if slash < 0 {
		return fmt.tprintf("route %q is not <venue>/<route_n>", spec), false
	}
	want_venue, want_route := spec[:slash], spec[slash + 1:]
	for venue, vi in vs.install.venues {
		if venue.id != want_venue {
			continue
		}
		for route, ri in venue.routes {
			if route.id == want_route {
				vs.venue, vs.route = vi, ri
				return "", true
			}
		}
		return fmt.tprintf("%s has no %s", venue.id, want_route), false
	}
	return fmt.tprintf("no venue named %q", want_venue), false
}

// One line for the status bar after a rescan.
install_scan_status_text :: proc(vs: ^Install_Scan) -> string {
	if !vs.found {
		return fmt.tprintf("Dirt 3 install not found: %s", vs.status)
	}
	c := d3.install_counts(vs.install)
	if c.orphan_venues == 0 && c.orphan_routes == 0 {
		return fmt.tprintf("Dirt 3: %d venues, %d routes under %s", c.venues, c.routes, vs.install.root)
	}
	return fmt.tprintf(
		"Dirt 3: %d venues, %d routes (%d venues and %d routes are half-installed) under %s",
		c.venues,
		c.routes,
		c.orphan_venues,
		c.orphan_routes,
		vs.install.root,
	)
}

// `install_dir` out of the machine-local config, checked to be a directory.
@(private = "file")
d3_install_dir :: proc(allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	dir, ok = conf_get(D3_INSTALL_KEY, allocator)
	return dir, ok && os.is_dir(dir)
}

// --- headless ----------------------------------------------------------------

// `--dirt3-venues`: what the install holds, and where the database and the
// filesystem disagree. The same scan the venue screen draws.
install_headless :: proc() -> bool {
	vs: Install_Scan
	install_scan_init(&vs)
	defer install_scan_delete(&vs)

	fmt.println(install_scan_status_text(&vs))
	if !vs.found {
		return false
	}
	for venue in vs.install.venues {
		fmt.printfln("%s/%s%s", venue.location, venue.id, d3.venue_playable(venue) ? "" : "   [not loadable]")
		for route in venue.routes {
			note := ""
			switch {
			case !route.registered:
				note = "on disk, not registered — the game cannot see it"
			case !route.on_disk:
				note = "registered, no files — a broken menu entry"
			}
			fmt.printfln("    %-10s %s", route.id, note)
		}
	}
	return true
}
