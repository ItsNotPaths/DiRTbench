package main

// A venue's id is minted once and outlives every name it is ever given. That
// is what lets a renamed venue publish a new version of the same listing
// instead of a second one, so the tests here are about the split: the id never
// moves, and the name is free to.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
a_minted_id_is_sixteen_hex_digits :: proc(t: ^testing.T) {
	id := venue_uuid()
	defer delete(id)
	testing.expect_value(t, len(id), 16)
	testing.expectf(t, venue_uuid_valid(id), "a minted id did not pass as one: %q", id)

	other := venue_uuid()
	defer delete(other)
	testing.expect(t, id != other, "two mints came out the same")
}

// The site keys a listing on this, so anything that is not the minted shape
// has to be refused rather than quietly accepted as a name.
@(test)
a_name_does_not_pass_as_an_id :: proc(t: ^testing.T) {
	testing.expect(t, !venue_uuid_valid(""))
	testing.expect(t, !venue_uuid_valid("dirtbench_1"))
	testing.expect(t, !venue_uuid_valid("b6f588abc7b58ab"), "15 digits passed")
	testing.expect(t, !venue_uuid_valid("b6f588abc7b58ab44"), "17 digits passed")
	testing.expect(t, !venue_uuid_valid("B6F588ABC7B58AB4"), "upper case passed")
	testing.expect(t, !venue_uuid_valid("b6f588abc7b58abg"), "a non-hex digit passed")
}

// The name shown in the game is not the directory it installs under; the
// directory is derived from it, and that derivation is the only thing the
// 16-byte `folder_string` ever sees.
@(test)
a_venue_name_makes_its_own_directory :: proc(t: ^testing.T) {
	testing.expect_value(t, venue_dir(Venue{name = "DIRTBENCH 1"}), "dirtbench_1")
	testing.expect_value(t, venue_dir(Venue{name = "Moose Loop"}), "moose_loop")
	testing.expect_value(t, venue_dir(Venue{name = "  snowoland  "}), "snowoland")
}

// A rename rewrites the document under a new file name. Everything about its
// identity has to come back unchanged, or the site sees a different venue.
@(test)
a_rename_keeps_the_id :: proc(t: ^testing.T) {
	before, _ := filepath.join({".", "dirtbench-rename-before.json"}, context.allocator)
	after, _ := filepath.join({".", "dirtbench-rename-after.json"}, context.allocator)
	defer delete(before)
	defer delete(after)
	defer os.remove(before)
	defer os.remove(after)

	id := venue_uuid()
	defer delete(id)
	p := Venue {
		format  = VENUE_FORMAT,
		version = VENUE_VERSION,
		id      = id,
		name    = "alpha",
		source  = {site = "dirtbench.paths.place", slug = "alpha-ab12cd"},
	}
	msg, ok := venue_write(p, before)
	testing.expectf(t, ok, "could not write the venue: %s", msg)

	renamed, load_msg, loaded := venue_load_path(before, context.allocator)
	testing.expectf(t, loaded, "could not read the venue back: %s", load_msg)
	// The document owns its strings, so the old name goes before the new one
	// takes its place.
	delete(renamed.name, context.allocator)
	renamed.name = strings.clone("beta", context.allocator)
	msg, ok = venue_write(renamed, after)
	testing.expectf(t, ok, "could not write the renamed venue: %s", msg)
	venue_free(renamed, context.allocator)

	back, back_msg, back_ok := venue_load_path(after, context.allocator)
	defer venue_free(back, context.allocator)
	testing.expectf(t, back_ok, "could not read the renamed venue: %s", back_msg)
	testing.expect_value(t, back.id, id)
	testing.expect_value(t, back.name, "beta")
	// The listing it belongs to travels with the document, not with the name.
	testing.expect_value(t, back.source.slug, "alpha-ab12cd")
}

// A document with no id is not a venue. It would upload as a listing keyed on
// nothing, and the site refuses it anyway.
@(test)
a_venue_without_an_id_is_refused :: proc(t: ^testing.T) {
	path, _ := filepath.join({".", "dirtbench-no-id-test.json"}, context.allocator)
	defer delete(path)
	defer os.remove(path)

	msg, ok := venue_write(Venue{format = VENUE_FORMAT, version = VENUE_VERSION, name = "alpha"}, path)
	testing.expectf(t, ok, "could not write the venue: %s", msg)

	_, _, loaded := venue_load_path(path, context.allocator)
	testing.expect(t, !loaded, "a venue with no id was read as one")
}
