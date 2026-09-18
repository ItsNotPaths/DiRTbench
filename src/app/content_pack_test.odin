package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// A pack with no manifest is one derived straight from the stock venue its id
// names. Every pack on disk today is that, so this is the case that must not
// need a file to work.
@(test)
a_pack_with_no_manifest_reads_as_derived :: proc(t: ^testing.T) {
	pack := pack_manifest("finland/finland_rally")
	testing.expect_value(t, pack.id, "finland/finland_rally")
	testing.expect_value(t, pack.base, "finland/finland_rally")
	testing.expect_value(t, len(pack.local), 0)
	testing.expect(t, !pack_provides(pack, "tracksplit.pssg"))
}

// The one decision the manifest exists to make. A pack that lists an entry
// provides it; everything else still comes out of the installed game.
@(test)
a_pack_provides_only_what_it_lists :: proc(t: ^testing.T) {
	local := []string{"tracksplit.pssg", "textures"}
	pack := Content_Pack{id = "woods", base = "finland/finland_rally", local = local}
	testing.expect(t, pack_provides(pack, "tracksplit.pssg"))
	testing.expect(t, pack_provides(pack, "textures"))
	testing.expect(t, !pack_provides(pack, "objects.pssg"))
	// A pack that stands on its own still says so through `base`, not through
	// an empty list: listing nothing is a derived pack, not a self-contained one.
	testing.expect(t, pack.base != "")
}

// Deployment reads the manifest per entry. A listed name is taken from the
// pack's own `local/` and the stock venue's copy of it is left behind, which is
// the whole mechanism a future art pack needs.
@(test)
deployment_takes_a_listed_entry_from_the_pack :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-pack-deploy"
	defer os.remove_all(root)
	_ = os.remove_all(root)

	base, _ := filepath.join({root, "base"}, context.temp_allocator)
	local, _ := filepath.join({root, "local"}, context.temp_allocator)
	dst, _ := filepath.join({root, "staged"}, context.temp_allocator)
	for dir in ([]string{base, local}) {
		testing.expect(t, os.make_directory_all(dir) == nil, "could not make the fixture")
	}
	write :: proc(dir, name, text: string) -> bool {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		return os.write_entire_file(path, transmute([]u8)text) == nil
	}
	testing.expect(t, write(base, "tracksplit.pssg", "stock"))
	testing.expect(t, write(base, "objects.pssg", "stock"))
	testing.expect(t, write(local, "tracksplit.pssg", "ours"))

	pack := Content_Pack{id = "woods", base = "x/y", local = []string{"tracksplit.pssg"}}
	msg, ok := place_venue_root(pack, local, base, dst)
	testing.expect(t, ok, msg); if !ok { return }

	read :: proc(dir, name: string) -> string {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		return err == nil ? string(data) : ""
	}
	testing.expect_value(t, read(dst, "tracksplit.pssg"), "ours")
	testing.expect_value(t, read(dst, "objects.pssg"), "stock")
}

// A pack that claims an entry it does not ship is a broken pack. Falling back
// to the stock file would deploy a venue that looks right and draws the wrong
// art, which is the failure that costs a drive to find.
@(test)
a_missing_local_entry_fails_the_deployment :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-pack-missing"
	defer os.remove_all(root)
	_ = os.remove_all(root)

	base, _ := filepath.join({root, "base"}, context.temp_allocator)
	local, _ := filepath.join({root, "local"}, context.temp_allocator)
	dst, _ := filepath.join({root, "staged"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(base) == nil, "could not make the fixture")
	path, _ := filepath.join({base, "objects.pssg"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("stock")) == nil)

	pack := Content_Pack{id = "woods", base = "x/y", local = []string{"trees.pssg"}}
	msg, ok := place_venue_root(pack, local, base, dst)
	testing.expect(t, !ok, "a pack that ships nothing for what it claims was allowed")
	testing.expect(t, strings.contains(msg, "trees.pssg"), msg)
}
