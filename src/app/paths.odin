package main

// Where the tool keeps its own files.
//
// Everything dirtbench owns sits beside the executable, so a release build and
// a dev build each see their own work and neither can write into the other's:
//
//     <data_dir>/dirtbench.conf   machine-local settings (config.odin)
//     <data_dir>/maps/            loose road documents
//     <data_dir>/maps/crash-backups/  autosaves (recovery.odin)
//     <data_dir>/venues/          our venues, one directory each
//     <data_dir>/out/             the debug export detour
//
// One root, named once: every other path in the tool derives from `data_dir`,
// and nothing else asks where the executable is. The game install is not here —
// it is machine-local, read from the config, and install.odin owns it.

import "core:os"
import "core:path/filepath"
import "core:strings"

// Where the tool's own files live. The executable's directory, or the working
// directory when the platform will not say where the executable is.
data_dir :: proc(allocator := context.temp_allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		return strings.clone(".", allocator)
	}
	return strings.clone(filepath.dir(exe), allocator)
}

maps_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({data_dir(context.temp_allocator), "maps"}, allocator)
	return joined
}

venues_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({data_dir(context.temp_allocator), "venues"}, allocator)
	return joined
}

// The debug export detour: **Export targets > Write to out/ instead**, or
// `--debug-out` headless. Exports normally go straight into the game.
out_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({data_dir(context.temp_allocator), "out"}, allocator)
	return joined
}

// Create maps/ if it is not there yet. An already-existing directory is the
// expected case, not an error.
ensure_maps_dir :: proc() -> (dir: string, ok: bool) {
	dir = maps_dir()
	if os.exists(dir) {
		return dir, true
	}
	if err := os.make_directory(dir); err != nil && err != os.General_Error.Exist {
		return dir, false
	}
	return dir, true
}
