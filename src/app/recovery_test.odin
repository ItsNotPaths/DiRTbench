package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// A set folder built by hand, so the swap can be tested without a crash.
//
// A snapshot records where each document belongs, so a test can put the live
// half anywhere: it goes under `build/`, while the set folder sits in /tmp.
// Two filesystems, which is what makes the swap take its copy fallback.
@(private = "file")
recovery_fixture :: proc(
	t: ^testing.T, root, live_root, name: string,
) -> (set: Recovery_Set, live_path: string) {
	set_dir, _ := filepath.join({root, "set-aside-120000"}, context.temp_allocator)
	held_dir, _ := filepath.join({set_dir, "venue", name}, context.temp_allocator)
	err := os.make_directory_all(held_dir)
	testing.expect(t, err == nil || err == os.General_Error.Exist, "could not make the set folder")
	held, _ := filepath.join({held_dir, RECOVERY_DOC_FILE}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(held, transmute([]u8)string("recovered")) == nil)

	live_path, _ = filepath.join(
		{live_root, strings.concatenate({name, STAGE_EXT}, context.temp_allocator)},
		context.temp_allocator,
	)
	_ = os.make_directory_all(live_root)

	paths := make([]string, 1, context.temp_allocator)
	paths[0] = live_path
	docs := make([]Recovery_Doc, 1, context.temp_allocator)
	docs[0] = {id = name, paths = paths}
	testing.expect(t, recovery_write_manifest(set_dir, .Recovered, docs), "manifest not written")
	return Recovery_Set{dir = set_dir, state = .Recovered, docs = docs}, live_path
}

@(private = "file")
file_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// Restore and Undo are one operation pressed twice. Whatever is in the folder
// is whatever is not on disk, every time, and neither version is ever lost
// until it is thrown away.
@(test)
recovery_swap_puts_each_version_where_the_other_was :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-recovery-swap"
	live_root := "build/recovery-swap-test"
	defer os.remove_all(root)
	defer os.remove_all(live_root)
	_ = os.remove_all(root)
	set, live := recovery_fixture(t, root, live_root, "moose")
	// What the crash would have left on disk: the last save.
	testing.expect(t, os.write_entire_file(live, transmute([]u8)string("on disk")) == nil)

	held, _ := filepath.join({set.dir, "venue", "moose", RECOVERY_DOC_FILE}, context.temp_allocator)

	msg, ok := recovery_swap(&set)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, file_text(live), "recovered")
	testing.expect_value(t, file_text(held), "on disk")
	testing.expect_value(t, set.state, Recovery_State.Displaced)

	// Pressed again it is Undo, and the manifest on disk says so too.
	msg, ok = recovery_swap(&set)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, file_text(live), "on disk")
	testing.expect_value(t, file_text(held), "recovered")
	back, read_ok := recovery_read_manifest(set.dir, context.temp_allocator)
	testing.expect(t, read_ok, "the manifest could not be read back"); if !read_ok { return }
	testing.expect_value(t, back.state, Recovery_State.Recovered)
	testing.expect_value(t, len(back.docs), 1)
	testing.expect_value(t, back.docs[0].id, "moose")
	testing.expect_value(t, len(back.docs[0].paths), 1)
	testing.expect_value(t, back.docs[0].paths[0], live)
}

// A document that was never saved has nothing on disk to swap back. Undoing it
// has to take the restored file away again rather than leave a copy behind.
@(test)
recovery_swap_handles_a_document_that_was_never_saved :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-recovery-new"
	live_root := "build/recovery-new-test"
	defer os.remove_all(root)
	defer os.remove_all(live_root)
	_ = os.remove_all(root)
	set, live := recovery_fixture(t, root, live_root, "moose")
	_ = os.remove(live) // nothing on disk for this one

	msg, ok := recovery_swap(&set)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, file_text(live), "recovered")

	msg, ok = recovery_swap(&set)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect(t, !os.exists(live), "undoing left the recovered file behind")
	held, _ := filepath.join({set.dir, "venue", "moose", RECOVERY_DOC_FILE}, context.temp_allocator)
	testing.expect_value(t, file_text(held), "recovered")
}

// A live folder is claimed only when its process is gone, and the name it gets
// is the time of day its snapshot was taken.
@(test)
recovery_promote_claims_only_dead_sessions :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-recovery-promote"
	defer os.remove_all(root)
	_ = os.remove_all(root)

	docs := make([]Recovery_Doc, 1, context.temp_allocator)
	docs[0] = {id = "moose_loop"}
	// One from a process that is gone, one from this one, which is alive.
	dead := recovery_live_dir(root, 999_999, context.temp_allocator)
	testing.expect(t, recovery_write_manifest(dead, .Recovered, docs), "no manifest for the dead run")
	mine := recovery_live_dir(root, os.get_pid(), context.temp_allocator)
	testing.expect(t, recovery_write_manifest(mine, .Recovered, docs), "no manifest for this run")

	recovery_promote(root)
	testing.expect(t, !os.exists(dead), "a dead session's folder was not claimed")
	testing.expect(t, os.exists(mine), "a running session's folder was taken from it")

	sets := recovery_pending(root, context.temp_allocator)
	testing.expect_value(t, len(sets), 1)
	if len(sets) != 1 { return }
	testing.expect_value(t, sets[0].state, Recovery_State.Recovered)
	testing.expect_value(t, sets[0].docs[0].id, "moose_loop")
	name := filepath.base(sets[0].dir)
	testing.expect(t, len(name) == len(RECOVERY_ASIDE) + 6,
		fmt.tprintf("a claimed set is named %q, not %s<hhmmss>", name, RECOVERY_ASIDE))
}

// The guard that keeps a restore from happening under an open window: that
// window holds one version and the disk the other, and its next save would put
// the restore back the way it was.
@(test)
recovery_refuses_to_swap_a_document_a_window_holds :: proc(t: ^testing.T) {
	// A snapshot records the venue by id; what the refusal names is the window
	// holding it, which is the name the user is looking at.
	forest := Venue_Doc{open_venue = "00112233445566aa", venue_name = "FOREST"}
	open := []^Venue_Doc{&forest}

	docs := make([]Recovery_Doc, 1, context.temp_allocator)

	docs[0] = {id = "aabbccddeeff0011"}
	_, blocked := recovery_blocked_by(open, Recovery_Set{docs = docs})
	testing.expect(t, !blocked, "a venue nobody has open was refused")

	docs[0] = {id = "00112233445566aa"}
	held, venue_blocked := recovery_blocked_by(open, Recovery_Set{docs = docs})
	testing.expect(t, venue_blocked, "a venue with a window open was allowed")
	testing.expect_value(t, held, "FOREST")
}
