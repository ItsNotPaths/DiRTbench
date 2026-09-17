package main

// Crash recovery: an autosave that lands somewhere harmless, and a swap that
// puts it back.
//
// Nothing is saved from inside a crash. The writer allocates, and the crash
// worth recovering from is the one that broke the heap. Every document with
// unsaved work is written to `maps/crash-backups/live-<pid>/` on a timer
// instead, and that folder is deleted when the process reaches its own exit —
// so a folder left behind is the crash flag, and covers a kill and a power cut
// as well as a segfault.
//
// Recovery is a **swap**, never an overwrite. A set folder always holds the
// version that is *not* on disk, and its `state` says which that is, so Restore
// and Undo are one operation and either can be pressed until the copy is thrown
// away. Each set is stamped `set-aside-<hhmmss>`, so two waiting at once are two
// rows rather than a fight.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

RECOVERY_DIR :: "crash-backups"
RECOVERY_ASIDE :: "set-aside-"
RECOVERY_MANIFEST :: "manifest.json"
RECOVERY_FORMAT :: "dirtbench.recovery"
RECOVERY_VERSION :: 1

// How often a changed document is written. Long enough that an idle session
// costs nothing and a busy one is not marshalling constantly; short enough that
// a crash loses a sculpting pass, not an afternoon.
RECOVERY_INTERVAL :: 20.0 // seconds

// Which document a snapshot came from, and so where it goes back to. A venue is
// two files: road.json, and the venue.json its stages live in.
Recovery_Kind :: enum {
	Venue,
	Stage, // a loose road out of maps/
}

Recovery_Doc :: struct {
	kind: Recovery_Kind,
	id:   string, // venue id, or stage name without the extension
	// Where this document belongs, recorded when the snapshot was taken rather
	// than worked out again when it is put back. A venue is two paths, a loose
	// road one, and they pair with the files in the set folder in this order.
	paths: []string,
}

// What a set folder holds. `Recovered` is the state a crash leaves: the folder
// has the work from the dead session and the disk still has what was last
// saved. `Displaced` is the state after a restore: the two have changed places.
Recovery_State :: enum {
	Recovered,
	Displaced,
}

Recovery_Set :: struct {
	dir:   string,
	state: Recovery_State,
	at:    i64, // unix seconds the snapshot was taken
	docs:  []Recovery_Doc,
}

// The on-disk manifest. Flat, like every other file this tool writes. `state` is
// a word rather than the enum: Odin marshals an enum as its ordinal, and a state
// added in the middle would then reinterpret every manifest already written.
Recovery_File :: struct {
	format: string,
	version: int,
	state:  string,
	at:     i64,
	docs:   []Recovery_Doc,
}

recovery_root :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({maps_dir(context.temp_allocator), RECOVERY_DIR}, allocator)
	return joined
}

// This process's snapshot folder. The pid is in the name so a second dirtbench
// cannot clear the first one's work on its way out.
recovery_live_dir :: proc(root: string, pid := -1, allocator := context.temp_allocator) -> string {
	id := pid >= 0 ? pid : os.get_pid()
	joined, _ := filepath.join({root, fmt.tprintf("live-%d", id)}, allocator)
	return joined
}

@(private = "file")
recovery_doc_dir :: proc(
	set_dir: string, doc: Recovery_Doc, allocator := context.temp_allocator,
) -> string {
	kind := doc.kind == .Venue ? "venue" : "stage"
	joined, _ := filepath.join({set_dir, kind, doc.id}, allocator)
	return joined
}

// Which document this is and where it belongs: a venue by id, with its road and
// its venue.json, or a loose road by the name it saves under.
recovery_doc_of :: proc(doc: ^Venue_Doc, allocator := context.temp_allocator) -> Recovery_Doc {
	if doc.open_venue == "" {
		name := sanitise_stage_name(stage_name_text(doc), allocator)
		paths := make([]string, 1, allocator)
		paths[0] = stage_path(name, allocator)
		return {kind = .Stage, id = name, paths = paths}
	}
	paths := make([]string, 2, allocator)
	paths[0] = venue_road_path(doc.open_venue, allocator)
	paths[1], _ = filepath.join(
		{venue_dir(doc.open_venue, context.temp_allocator), VENUE_FILE}, allocator,
	)
	return {kind = .Venue, id = doc.open_venue, paths = paths}
}

@(private = "file")
RECOVERY_FILES := [2]string{VENUE_ROAD_FILE, VENUE_FILE}

// The snapshot file that pairs with each live path, in the same order.
@(private = "file")
recovery_snapshot_paths :: proc(
	set_dir: string, doc: Recovery_Doc, allocator := context.temp_allocator,
) -> []string {
	dir := recovery_doc_dir(set_dir, doc, context.temp_allocator)
	if doc.kind == .Stage {
		out := make([]string, 1, allocator)
		out[0], _ = filepath.join({dir, VENUE_ROAD_FILE}, allocator)
		return out
	}
	out := make([]string, 2, allocator)
	for name, i in RECOVERY_FILES {
		out[i], _ = filepath.join({dir, name}, allocator)
	}
	return out
}

// --- writing the snapshot ------------------------------------------------------

// Write one document into this process's folder. A venue gets its road and a
// copy of venue.json carrying the in-memory stage list, because a road restored
// without its markers is a road with no start or finish lines.
recovery_write_doc :: proc(root: string, doc: ^Venue_Doc) -> (msg: string, ok: bool) {
	rd := recovery_doc_of(doc)
	dir := recovery_doc_dir(recovery_live_dir(root), rd)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dir, err), false
	}
	paths := recovery_snapshot_paths(recovery_live_dir(root), rd)
	if msg, ok = save_road(doc, paths[0]); !ok {
		return
	}
	if rd.kind == .Stage {
		return "", true
	}
	p, load_msg, loaded := venue_load(rd.id, context.temp_allocator)
	if !loaded {
		return load_msg, false
	}
	p.routes = doc.routes[:]
	return venue_write(p, paths[1])
}

// A document written home. Its snapshot goes with it: one older than the file it
// would replace is worse than none.
recovery_doc_saved :: proc(root: string, doc: ^Venue_Doc) {
	if doc.snapshot_edits != 0 {
		_ = os.remove_all(recovery_doc_dir(recovery_live_dir(root), recovery_doc_of(doc)))
	}
	doc_saved(doc)
}

// Write every document that has unsaved work and has changed since its last
// snapshot. A document nobody has touched costs a comparison, and a session
// with nothing outstanding leaves no folder at all.
recovery_snapshot :: proc(root: string, docs: []^Venue_Doc) {
	for doc in docs {
		if !doc_unsaved(doc) || doc.edits == doc.snapshot_edits || len(doc.spline.points) < 2 {
			continue
		}
		if _, ok := recovery_write_doc(root, doc); ok {
			doc.snapshot_edits = doc.edits
		}
	}
	held := make([dynamic]Recovery_Doc, context.temp_allocator)
	for doc in docs {
		if doc.snapshot_edits != 0 {
			append(&held, recovery_doc_of(doc))
		}
	}
	if len(held) == 0 {
		recovery_clear_live(root)
		return
	}
	recovery_write_manifest(recovery_live_dir(root), .Recovered, held[:])
}

recovery_write_manifest :: proc(
	set_dir: string, state: Recovery_State, docs: []Recovery_Doc,
) -> bool {
	if err := os.make_directory_all(set_dir); err != nil && err != os.General_Error.Exist {
		return false
	}
	file := Recovery_File {
		format  = RECOVERY_FORMAT,
		version = RECOVERY_VERSION,
		state   = state == .Recovered ? "recovered" : "displaced",
		at      = time.time_to_unix(time.now()),
		docs    = docs,
	}
	data, merr := json.marshal(file, {pretty = true, use_spaces = true}, context.temp_allocator)
	if merr != nil {
		return false
	}
	path, _ := filepath.join({set_dir, RECOVERY_MANIFEST}, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

// This process reached its own exit, so nothing it was holding was lost. The
// folder going away is what tells the next run that.
recovery_clear_live :: proc(root: string) {
	_ = os.remove_all(recovery_live_dir(root))
}

// --- finding one at boot --------------------------------------------------------

recovery_read_manifest :: proc(
	set_dir: string, allocator := context.allocator,
) -> (set: Recovery_Set, ok: bool) {
	path, _ := filepath.join({set_dir, RECOVERY_MANIFEST}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	file: Recovery_File
	if uerr := json.unmarshal(data, &file, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
		return
	}
	if file.format != RECOVERY_FORMAT || len(file.docs) == 0 {
		return
	}
	return Recovery_Set {
		dir   = strings.clone(set_dir, allocator),
		state = file.state == "displaced" ? .Displaced : .Recovered,
		at    = file.at,
		docs  = file.docs,
	}, true
}

recovery_set_delete :: proc(set: ^Recovery_Set, allocator := context.allocator) {
	for doc in set.docs {
		delete(doc.id, allocator)
		for path in doc.paths {
			delete(path, allocator)
		}
		delete(doc.paths, allocator)
	}
	delete(set.docs, allocator)
	delete(set.dir, allocator)
	set^ = {}
}

// The folder name a set gets when it is claimed: the time of day it was taken,
// six digits, which reads as a clock and is unique unless two land in the same
// second. One is nudged along if it does.
recovery_set_name :: proc(at: i64, allocator := context.temp_allocator) -> string {
	hour, min, sec := time.clock_from_seconds(u64(at % 86_400))
	return fmt.aprintf("%s%02d%02d%02d", RECOVERY_ASIDE, hour, min, sec, allocator = allocator)
}

// Claim what the last run left behind. A `live-<pid>` folder whose process is
// gone is a crash, and becomes a set of its own, stamped with the time its
// snapshot was taken. A folder whose process is still alive belongs to another
// dirtbench and is left alone.
//
// Nothing here deletes. A folder that cannot be claimed stays where it is.
recovery_promote :: proc(root: string) {
	infos, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		if info.type != .Directory || !strings.has_prefix(info.name, "live-") {
			continue
		}
		pid, pok := strconv.parse_int(info.name[len("live-"):])
		if !pok || process_is_running(pid) {
			continue // not ours to claim, or another dirtbench is still using it
		}
		dir, _ := filepath.join({root, info.name}, context.temp_allocator)
		set, sok := recovery_read_manifest(dir, context.temp_allocator)
		if !sok {
			continue
		}
		for bump in 0 ..< 60 {
			name := recovery_set_name(set.at + i64(bump), context.temp_allocator)
			claimed, _ := filepath.join({root, name}, context.temp_allocator)
			if os.exists(claimed) {
				continue
			}
			_ = os.rename(dir, claimed)
			break
		}
	}
}

// Every set waiting on an answer, newest first. Read at boot and after every
// swap, so the project manager's rows are a picture of the folder rather than
// of a flag it kept in memory.
recovery_pending :: proc(root: string, allocator := context.allocator) -> []Recovery_Set {
	out := make([dynamic]Recovery_Set, allocator)
	infos, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for info in infos {
		if info.type != .Directory || !strings.has_prefix(info.name, RECOVERY_ASIDE) {
			continue
		}
		dir, _ := filepath.join({root, info.name}, context.temp_allocator)
		if set, ok := recovery_read_manifest(dir, allocator); ok {
			append(&out, set)
		}
	}
	slice.sort_by(out[:], proc(a, b: Recovery_Set) -> bool { return a.at > b.at })
	return out[:]
}

recovery_pending_delete :: proc(sets: []Recovery_Set, allocator := context.allocator) {
	for &set in sets {
		recovery_set_delete(&set, allocator)
	}
	delete(sets, allocator)
}

// Whether a pid is still alive, by asking /proc. Linux is where this tool runs;
// anywhere without /proc the answer is no, which at worst claims a folder a
// second instance is still writing to.
@(private = "file")
process_is_running :: proc(pid: int) -> bool {
	if !os.exists("/proc") {
		return false
	}
	return os.exists(fmt.tprintf("/proc/%d", pid))
}

// --- the swap --------------------------------------------------------------------

// Exchange every document in the set with what is on disk, and flip the state.
// Pressed once this is Restore; pressed again it is Undo. Either way the folder
// afterwards holds whatever is not live, which is the only rule it has.
//
// A set is all or nothing: a document that will not swap puts the ones already
// done back, so the folder is never half a session.
recovery_swap :: proc(set: ^Recovery_Set) -> (msg: string, ok: bool) {
	for doc, done in set.docs {
		if m, sok := swap_doc(set.dir, doc); !sok {
			for undo in set.docs[:done] {
				_, _ = swap_doc(set.dir, undo)
			}
			return m, false
		}
	}
	next := set.state == .Recovered ? Recovery_State.Displaced : Recovery_State.Recovered
	if !recovery_write_manifest(set.dir, next, set.docs) {
		return "the files were swapped but the manifest could not be written", false
	}
	set.state = next
	return "", true
}

@(private = "file")
swap_doc :: proc(set_dir: string, doc: Recovery_Doc) -> (msg: string, ok: bool) {
	held := recovery_snapshot_paths(set_dir, doc)
	if len(doc.paths) != len(held) {
		return fmt.tprintf("%s names %d files, not %d", doc.id, len(doc.paths), len(held)), false
	}
	for path, i in doc.paths {
		if m, sok := swap_files(path, held[i]); !sok {
			return m, false
		}
	}
	return "", true
}

// Move one file, across filesystems if it has to. A rename cannot half-finish,
// so it is what this reaches for first; a set folder pointed at another drive
// is the case that makes the copy necessary, and there a copy is the only move
// there is.
@(private = "file")
move_file :: proc(from, to: string) -> (msg: string, ok: bool) {
	err := os.rename(from, to)
	if err == nil {
		return "", true
	}
	if err != os.Platform_Error.EXDEV {
		return fmt.tprintf("could not move %s: %v", from, err), false
	}
	if cerr := os.copy_file(to, from); cerr != nil {
		return fmt.tprintf("could not copy %s: %v", from, cerr), false
	}
	if rerr := os.remove(from); rerr != nil {
		return fmt.tprintf("copied %s but could not remove it: %v", from, rerr), false
	}
	return "", true
}

// Exchange two files, either of which may be missing. Through a temporary name
// rather than a read into memory: a road document is the largest thing here.
@(private = "file")
swap_files :: proc(live, held: string) -> (msg: string, ok: bool) {
	have_live, have_held := os.exists(live), os.exists(held)
	if !have_live && !have_held {
		return "", true
	}
	if dir := filepath.dir(live); !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			return fmt.tprintf("could not create %s: %v", dir, err), false
		}
	}
	switch {
	case have_live && have_held:
		tmp := strings.concatenate({held, ".swap"}, context.temp_allocator)
		if m, mok := move_file(held, tmp); !mok {
			return m, false
		}
		if m, mok := move_file(live, held); !mok {
			_, _ = move_file(tmp, held)
			return m, false
		}
		return move_file(tmp, live)
	case have_held:
		// Nothing on disk to keep: the document was never saved. Undoing this
		// puts the folder back to holding it, and the live file goes away.
		return move_file(held, live)
	case:
		return move_file(live, held)
	}
}

// A document the recovery would swap under an open window. Restoring then would
// leave the window holding one version and the disk another, and the window's
// next save would quietly undo the restore.
recovery_blocked_by :: proc(open: []^Venue_Doc, set: Recovery_Set) -> (id: string, blocked: bool) {
	for doc in set.docs {
		for held in open {
			if doc.kind == .Venue && held.open_venue == doc.id {
				return doc.id, true
			}
			if doc.kind == .Stage && held.open_venue == "" &&
			   sanitise_stage_name(stage_name_text(held)) == doc.id {
				return doc.id, true
			}
		}
	}
	return "", false
}

// The time of day a snapshot was taken, for the row to name.
recovery_clock_text :: proc(at: i64, allocator := context.temp_allocator) -> string {
	hour, min, sec := time.clock_from_seconds(u64(at % 86_400))
	return fmt.aprintf("%02d:%02d:%02d", hour, min, sec, allocator = allocator)
}

// Throw the set-aside copy away. Whichever version is live stays live.
recovery_discard :: proc(set: ^Recovery_Set) {
	_ = os.remove_all(set.dir)
}
