package gfx

// The native folder picker: the xdg portal on Linux, the shell dialog on
// Windows. SDL answers on whatever thread the platform hands it, so the answer
// lands in a fixed buffer under a mutex and the caller collects it on a later
// frame.
//
// One picker for the process. Nothing here needs two open at once, and a single
// slot means the callback has no pointer of ours to outlive.

import "core:c"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

@(private = "file")
picker: struct {
	mu:    sync.Mutex,
	path:  [1024]u8,
	n:     int,
	ready: bool,
	open:  bool,
}

// Ask for a folder, starting at `at` when that is somewhere real. Returns at
// once; the answer arrives through FolderPicked.
ShowFolderDialog :: proc(window: ^Window, at: string) {
	sync.lock(&picker.mu)
	already := picker.open
	picker.open, picker.ready = true, false
	sync.unlock(&picker.mu)
	if already {
		return
	}
	start: cstring
	if at != "" {
		start = strings.clone_to_cstring(at, context.temp_allocator)
	}
	sdl.ShowOpenFolderDialog(folder_chosen, nil, window.handle, start, false)
}

// The folder the last dialog returned, once. A cancelled dialog answers false,
// same as no dialog at all.
FolderPicked :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	sync.lock(&picker.mu)
	defer sync.unlock(&picker.mu)
	if !picker.ready {
		return
	}
	picker.ready = false
	if picker.n == 0 {
		return
	}
	return strings.clone(string(picker.path[:picker.n]), allocator), true
}

@(private = "file")
folder_chosen :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	sync.lock(&picker.mu)
	defer sync.unlock(&picker.mu)
	picker.open, picker.ready, picker.n = false, true, 0
	// nil is an error, an empty list is a cancel; both leave the buffer empty.
	if filelist == nil || filelist[0] == nil {
		return
	}
	chosen := string(filelist[0])
	picker.n = min(len(chosen), len(picker.path))
	copy(picker.path[:picker.n], chosen[:picker.n])
}
