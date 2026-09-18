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
// released first.
//
// Every window shares this one scan, so any of them can call this at any time.
// That is the rule for anything derived from it elsewhere: hold an id, never an
// index into `install.venues` or into a venue's routes, and look it up again.
install_scan_rescan :: proc(vs: ^Install_Scan) {
	if vs.found {
		d3.install_delete(&vs.install)
	}
	delete(vs.status)
	vs.found, vs.status = false, ""

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
