package main

import "core:os"
import "core:strings"
import "core:testing"

// A config is hand-written: comments, blank lines and the order of the keys are
// the user's, and remembering a username must not cost any of them.
@(test)
conf_apply_keeps_everything_it_did_not_come_for :: proc(t: ^testing.T) {
	before := `# where the game is
d3_install = /games/DiRT 3 Complete Edition

dirtbench_user = olduser
`
	after := conf_apply(before, "dirtbench_user", "paths", context.allocator)
	defer delete(after)

	testing.expect(t, strings.contains(after, "# where the game is"), "the comment was lost")
	testing.expect(
		t,
		strings.contains(after, "d3_install = /games/DiRT 3 Complete Edition"),
		"a value with spaces in it did not survive",
	)
	testing.expect(t, strings.contains(after, "dirtbench_user = paths"), "the key was not written")
	testing.expect(t, !strings.contains(after, "olduser"), "the old value is still there")
}

@(test)
conf_apply_appends_a_key_that_was_not_there :: proc(t: ^testing.T) {
	after := conf_apply("d3_install = /games\n", "upload_slug.pine", "pine-ab12cd", context.allocator)
	defer delete(after)
	testing.expect(t, strings.contains(after, "d3_install = /games"))
	testing.expect(t, strings.contains(after, "upload_slug.pine = pine-ab12cd"))
}

// No config yet: the first remembered key writes the whole file.
@(test)
conf_apply_starts_from_an_empty_file :: proc(t: ^testing.T) {
	first := conf_apply("", "dirtbench_user", "paths", context.allocator)
	defer delete(first)
	testing.expect_value(t, first, "dirtbench_user = paths\n")
}

// A file that somehow holds the same key twice comes back holding it once:
// conf_get returns the first match, so a stale second line would be a value
// that reappears the moment the first is edited by hand.
@(test)
conf_apply_collapses_a_duplicated_key :: proc(t: ^testing.T) {
	after := conf_apply("k = one\nother = keep\nk = two\n", "k", "three", context.allocator)
	defer delete(after)
	testing.expect_value(t, strings.count(after, "k = "), 1)
	testing.expect(t, strings.contains(after, "k = three"))
	testing.expect(t, strings.contains(after, "other = keep"))
}

// A commented-out key is a comment, not a key.
@(test)
conf_apply_does_not_uncomment :: proc(t: ^testing.T) {
	after := conf_apply("# k = one\n", "k", "two", context.allocator)
	defer delete(after)
	testing.expect(t, strings.contains(after, "# k = one"), "the comment was eaten")
	testing.expect(t, strings.contains(after, "k = two"))
}

// A fresh id leaves the listing its old id was tied to behind, and nothing
// will ever look that line up again, so the line goes rather than emptying.
@(test)
conf_apply_removes_a_key :: proc(t: ^testing.T) {
	before := `# keep me
upload_slug.b6f588abc7b58ab4 = dirtbench-b5d179
dirtbench_user = paths
`
	after := conf_apply(before, "upload_slug.b6f588abc7b58ab4", "", context.allocator, remove = true)
	defer delete(after)

	testing.expect(t, !strings.contains(after, "upload_slug"), "the key is still there")
	testing.expect(t, !strings.contains(after, "dirtbench-b5d179"), "the value is still there")
	testing.expect(t, strings.contains(after, "# keep me"), "the comment was lost")
	testing.expect(t, strings.contains(after, "dirtbench_user = paths"), "another key was lost")
}

// Removing a key that was never there leaves the file as it was, rather than
// appending an empty line for it.
@(test)
conf_apply_removing_an_absent_key_changes_nothing :: proc(t: ^testing.T) {
	before := "dirtbench_user = paths\n"
	after := conf_apply(before, "upload_slug.b6f588abc7b58ab4", "", context.allocator, remove = true)
	defer delete(after)
	testing.expect_value(t, after, before)
}

// First run has no config at all. The template goes in the config root, and a
// second run leaves it alone — the file is the user's once it exists.
@(test)
conf_ensure_writes_the_template_once :: proc(t: ^testing.T) {
	path, made := conf_ensure(context.temp_allocator)
	if !made {
		return // this machine has one already; nothing to prove and nothing to touch
	}
	defer os.remove(path)
	body, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the template was not written")
	testing.expect(t, strings.contains(string(body), D3_INSTALL_KEY), "the template says nothing about the install")

	_, again := conf_ensure(context.temp_allocator)
	testing.expect(t, !again, "an existing config was written over")
}
