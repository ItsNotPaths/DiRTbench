package main

import "core:os"
import "core:path/filepath"
import "core:testing"

// What the folder picker hands back is whatever the user clicked: the game
// folder, the executable inside it, or a folder well down the tree. All three
// have to name the same root, because everything downstream joins onto it.
@(test)
a_picked_path_trims_to_the_game_folder :: proc(t: ^testing.T) {
	root := "/tmp/claude-1000/dirtbench-install-trim"
	defer os.remove_all(root)
	_ = os.remove_all(root)

	game, _ := filepath.join({root, "DiRT 3 Complete Edition"}, context.temp_allocator)
	db, _ := filepath.join({game, "database"}, context.temp_allocator)
	deep, _ := filepath.join({game, "tracks", "locations", "finland"}, context.temp_allocator)
	for dir in ([]string{db, deep}) {
		testing.expect(t, os.make_directory_all(dir) == nil, "could not make the fixture")
	}
	db_file, _ := filepath.join({db, "database.bin"}, context.temp_allocator)
	exe, _ := filepath.join({game, "dirt3_game.exe"}, context.temp_allocator)
	for path in ([]string{db_file, exe}) {
		testing.expect(t, os.write_entire_file(path, "x") == nil, "could not make the fixture")
	}

	testing.expect_value(t, install_root_trim(game, context.temp_allocator), game)
	testing.expect_value(t, install_root_trim(exe, context.temp_allocator), game)
	testing.expect_value(t, install_root_trim(deep, context.temp_allocator), game)
	// Nothing of the game above it: the pick comes back untouched, so the scan
	// complains about the folder the user actually chose.
	testing.expect_value(t, install_root_trim(root, context.temp_allocator), root)
}
