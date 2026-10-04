package nefs

import "core:hash"
import "core:log"
import "core:os"
import "core:testing"

// A stock win_000.nfs; DIRT3_NFS overrides. Tests skip without one.
@(private = "file")
stock_archive :: proc(t: ^testing.T) -> (raw: []u8, ok: bool) {
	path := os.get_env("DIRT3_NFS", context.temp_allocator)
	if path == "" {
		path = "/run/media/paths/SSS-Games/SteamLibrary/steamapps/common/DiRT 3 Complete Edition/win_000.nfs.orig"
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.infof("skipped: no stock archive at %s", path)
		return
	}
	return data, true
}

@(test)
stock_archive_reads :: proc(t: ^testing.T) {
	raw, found_archive := stock_archive(t)
	if !found_archive {
		return
	}
	defer delete(raw)
	a, msg, ok := open(raw)
	defer close(&a)
	testing.expectf(t, ok, "open: %s", msg)

	// Plaintext CRC32s from the Python reference decoder.
	for f in ([]struct {
			name: string,
			size: int,
			crc:  u32,
		} {
			{"csconfig.xml", 37246, 0x5a990a15},
			{"csdata.xml", 351668, 0x8bb5e573},
			{"server_file.xml", 31217, 0x30e8a19d},
		}) {
		data, found := read(&a, f.name, context.temp_allocator)
		testing.expectf(t, found, "%s missing", f.name)
		testing.expect_value(t, len(data), f.size)
		testing.expect_value(t, hash.crc32(data), f.crc)
		testing.expectf(t, checksums_hold(&a, f.name), "%s: stock block CRC16s do not hold", f.name)
	}
}

// An edit with spares keeps every block's CRC16 at the value the signed header holds.
@(test)
edit_keeps_block_checksums :: proc(t: ^testing.T) {
	raw, found_archive := stock_archive(t)
	if !found_archive {
		return
	}
	defer delete(raw)
	a, _, _ := open(raw)
	defer close(&a)

	for name in ([]string{"server_file.xml", "csdata.xml"}) {
		data, _ := read(&a, name, context.temp_allocator)
		data[100] ~= 0x20
		spares := make([dynamic]Spare, context.temp_allocator)
		for i := 200; i < len(data); i += 16 {
			append(&spares, Spare{i, data[i] ~ 1})
		}
		msg, ok := write(&a, name, data, spares[:])
		testing.expectf(t, ok, "write %s: %s", name, msg)
		testing.expectf(t, checksums_hold(&a, name), "%s: a block CRC16 went stale", name)

		back, _ := read(&a, name, context.temp_allocator)
		testing.expect_value(t, back[100], data[100])
	}
}

@(test)
edit_without_spares_is_refused :: proc(t: ^testing.T) {
	raw, found_archive := stock_archive(t)
	if !found_archive {
		return
	}
	defer delete(raw)
	a, _, _ := open(raw)
	defer close(&a)

	data, _ := read(&a, "csconfig.xml", context.temp_allocator)
	data[0] ~= 0x20
	_, ok := write(&a, "csconfig.xml", data, nil)
	testing.expect(t, !ok, "a block CRC16 cannot be kept with no spares")
}
