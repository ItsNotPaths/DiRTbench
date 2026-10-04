package d3

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../nefs"

@(private = "file")
INSTALL :: "/run/media/paths/SSS-Games/SteamLibrary/steamapps/common/DiRT 3 Complete Edition"

// A scratch install: the stock archive and the live database, which holds
// deployed venues. Empty without a real install.
@(private = "file")
scratch_root :: proc(t: ^testing.T) -> string {
	archive := INSTALL + "/" + NEFS_ARCHIVE + ".orig"
	if !os.exists(archive) {
		log.infof("skipped: no stock archive at %s", archive)
		return ""
	}
	root, _ := os.make_directory_temp("", "dirtbench-online-*", context.temp_allocator)
	db_dir, _ := filepath.join({root, "database"}, context.temp_allocator)
	_ = os.make_directory(db_dir)
	for pair in ([][2]string {
			{archive, NEFS_ARCHIVE},
			{INSTALL + "/database/database.bin", "database/database.bin"},
			{INSTALL + "/database/database.bin.dirtbench-stock", "database/database.bin.dirtbench-stock"},
		}) {
		to, _ := filepath.join({root, pair[1]}, context.temp_allocator)
		testing.expectf(t, os.copy_file(to, pair[0]) == nil, "could not copy %s", pair[0])
	}
	return root
}

@(private = "file")
reopen :: proc(root: string) -> (a: nefs.Archive, ok: bool) {
	path, _ := filepath.join({root, NEFS_ARCHIVE}, context.temp_allocator)
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	a, _, ok = nefs.open(raw)
	return
}

@(test)
online_edits_keep_every_block_checksum :: proc(t: ^testing.T) {
	root := scratch_root(t)
	if root == "" {
		return
	}
	defer os.remove_all(root)

	msg, ok := online_checksums_blank(root)
	testing.expectf(t, ok, "blank: %s", msg)
	msg, ok = online_server_file_sync(root)
	testing.expectf(t, ok, "sync: %s", msg)
	log.info(msg)
	// Each runs again on its own output.
	msg, ok = online_server_file_sync(root)
	testing.expectf(t, ok, "second sync: %s", msg)
	msg, ok = online_checksums_blank(root)
	testing.expectf(t, ok, "second blank: %s", msg)

	a, opened := reopen(root)
	testing.expect(t, opened, "the edited archive does not open")
	defer nefs.close(&a)
	for name in ([]string{"csconfig.xml", "csdata.xml", "server_file.xml"}) {
		testing.expectf(t, nefs.checksums_hold(&a, name), "%s: a block CRC16 is stale", name)
	}
	config, _ := nefs.read(&a, "csconfig.xml", context.temp_allocator)
	testing.expect(t, !strings.contains(string(config), "<file "), "csconfig.xml still lists files")

	stock_path, _ := filepath.join({root, NEFS_ARCHIVE + ".orig"}, context.temp_allocator)
	stock_raw, _ := os.read_entire_file(stock_path, context.temp_allocator)
	stock, _, _ := nefs.open(stock_raw)
	defer nefs.close(&stock)
	before, _ := nefs.read(&stock, "server_file.xml", context.temp_allocator)
	after, _ := nefs.read(&a, "server_file.xml", context.temp_allocator)
	testing.expect(
		t,
		strings.count(string(after), "<track ") > strings.count(string(before), "<track "),
		"server_file.xml gained no track for the deployed venues",
	)
}

@(test)
server_file_clones_the_base_track :: proc(t: ^testing.T) {
	stock := `<server_file>
  <racetype value="rally" >
    <track value="finland_rally" probability="20" >
      <route value="0" >
        <laps value="1" />
      </route>
      <route value="1" />
    </track>
  </racetype>                                                                      
</server_file>`
	stages := []Online_Stage{{"ours", "finland_rally", "0", "1"}, {"ours", "finland_rally", "1", "0"}}
	text, ok := server_file_with(stock, stages)
	testing.expect(t, ok, "no room")
	testing.expect_value(t, len(text), len(stock))
	testing.expect(
		t,
		strings.contains(text, `<track value="ours" probability="20" ><route value="0" /><route value="1" ><laps value="1" /></route></track>`),
		text,
	)
	testing.expect(t, strings.contains(text, `<track value="finland_rally"`), "the base track went")
}
