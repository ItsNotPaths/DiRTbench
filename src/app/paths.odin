package main

// Where the tool keeps its own files.
//
// Three roots, because the three kinds of file want different treatment: a
// document is the user's work and wants backing up, a cache rebuilds itself and
// is safe to delete, a config is hand-edited. Which directory each of those is
// belongs to the platform — XDG on Linux, the known folders on Windows — and
// `core:os` already knows both.
//
//     <config>/dirtbench.conf      machine-local settings (config.odin)
//     <config>/imgui.ini           the project manager's window layout
//     <data>/maps/                 loose road documents
//     <data>/maps/crash-backups/   autosaves (recovery.odin)
//     <data>/venues/               our venues, one directory each
//     <cache>/content-packs/       what we take out of the vanilla game, one
//                                  pack per base venue, shared by every venue
//                                  of ours that derives from it
//     <cache>/out/                 the debug export detour
//     <exe>/pacenotes/             the co-driver clips, if any are installed
//
// Not beside the executable any more: that cannot work where the binary is
// installed somewhere the user may not write, which on Windows is the ordinary
// case. `DIRTBENCH_HOME` puts all three roots under one directory instead. It
// is how a dev build and a release build stay out of each other's work, and it
// makes the tool portable for anyone who wants it on a stick.
//
// The clips are the exception, deliberately: they are installed content rather
// than anything the tool writes, and dropping a folder next to the program is
// what someone unzipping it expects.
//
// The game install is not here — it is machine-local, read from the config, and
// install.odin owns it.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

APP_DIR :: "dirtbench"
HOME_ENV :: "DIRTBENCH_HOME"

// Our own directory under one of the platform's roots, or `DIRTBENCH_HOME` when
// that is set, which collapses all three onto one. The working directory is the
// last resort: a tool that cannot find a home still has to run.
@(private = "file")
app_dir :: proc(base: string, base_err: os.Error, allocator: runtime.Allocator) -> string {
	if home := os.get_env(HOME_ENV, context.temp_allocator); home != "" {
		return strings.clone(home, allocator)
	}
	if base_err != nil {
		return strings.clone(".", allocator)
	}
	joined, _ := filepath.join({base, APP_DIR}, allocator)
	return joined
}

config_root :: proc(allocator := context.temp_allocator) -> string {
	base, err := os.user_config_dir(context.temp_allocator)
	return app_dir(base, err, allocator)
}

data_root :: proc(allocator := context.temp_allocator) -> string {
	base, err := os.user_data_dir(context.temp_allocator)
	return app_dir(base, err, allocator)
}

cache_root :: proc(allocator := context.temp_allocator) -> string {
	base, err := os.user_cache_dir(context.temp_allocator)
	return app_dir(base, err, allocator)
}

// Where the program itself is, for the one thing installed beside it.
@(private = "file")
exe_dir :: proc(allocator := context.temp_allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		return strings.clone(".", allocator)
	}
	return strings.clone(filepath.dir(exe), allocator)
}

maps_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({data_root(context.temp_allocator), "maps"}, allocator)
	return joined
}

venues_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({data_root(context.temp_allocator), "venues"}, allocator)
	return joined
}

// Derived cache, never a document. A pack rebuilds itself out of the player's
// own install, so erasing this directory costs nothing and nothing in it may
// travel to another machine.
content_packs_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({cache_root(context.temp_allocator), "content-packs"}, allocator)
	return joined
}

// The recorded co-driver clips. Optional: the tool runs without them and the
// pace-note preview simply stays quiet. They are not embedded, and not in the
// repository — see credits.txt.
pacenotes_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({exe_dir(context.temp_allocator), "pacenotes"}, allocator)
	return joined
}

// The debug export detour: **Export targets > Write to out/ instead**, or
// `--debug-out` headless. Exports normally go straight into the game.
out_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({cache_root(context.temp_allocator), "out"}, allocator)
	return joined
}

// Create maps/ if it is not there yet, parents and all: on a first run none of
// the root above it exists either. An already-existing directory is the
// expected case, not an error.
ensure_maps_dir :: proc() -> (dir: string, ok: bool) {
	dir = maps_dir()
	if os.exists(dir) {
		return dir, true
	}
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return dir, false
	}
	return dir, true
}
