package d3

import "core:bytes"
import "core:os"
import "core:testing"

// A tiny legal PSSG with two node types, hand-built so the reader is checked
// against something other than our own writer.
test_pssg_fixture :: proc(allocator := context.allocator) -> []u8 {
	w := binary_writer(allocator)
	binary_write(&w, []u8{'P','S','S','G'})
	file_size, _ := binary_reserve(&w, 4)
	// Schema: two attribute names in total, two node types.
	binary_write_u32(&w, 2, .Big); binary_write_u32(&w, 2, .Big)
	binary_write_u32(&w, 1, .Big); binary_write_u32(&w, 4, .Big); binary_write(&w, []u8{'R','O','O','T'})
	binary_write_u32(&w, 1, .Big); binary_write_u32(&w, 10, .Big); binary_write_u32(&w, 2, .Big); binary_write(&w, []u8{'i','d'})
	binary_write_u32(&w, 2, .Big); binary_write_u32(&w, 4, .Big); binary_write(&w, []u8{'D','A','T','A'})
	binary_write_u32(&w, 1, .Big); binary_write_u32(&w, 11, .Big); binary_write_u32(&w, 4, .Big); binary_write(&w, []u8{'s','i','z','e'})
	// ROOT, one encoded string attribute, then a DATA child.
	binary_write_u32(&w, 1, .Big); root_size, _ := binary_reserve(&w, 4); root_start := len(w.data)
	binary_write_u32(&w, 14, .Big); binary_write_u32(&w, 10, .Big); binary_write_u32(&w, 6, .Big)
	binary_write_u32(&w, 2, .Big); binary_write(&w, []u8{'o','k'})
	binary_write_u32(&w, 2, .Big); child_size, _ := binary_reserve(&w, 4); child_start := len(w.data)
	binary_write_u32(&w, 12, .Big); binary_write_u32(&w, 11, .Big); binary_write_u32(&w, 4, .Big); binary_write_u32(&w, 3, .Big)
	binary_write(&w, []u8{0xaa,0xbb,0xcc})
	binary_patch_u32(&w, child_size, u32(len(w.data)-child_start), .Big)
	binary_patch_u32(&w, root_size, u32(len(w.data)-root_start), .Big)
	binary_patch_u32(&w, file_size, u32(len(w.data)-8), .Big)
	return w.data[:]
}

@(test)
pssg_reader_writer_is_byte_exact :: proc(t: ^testing.T) {
	raw := test_pssg_fixture(context.allocator); defer delete(raw)
	file, msg, ok := pssg_read(raw, context.allocator)
	testing.expect(t, ok, msg); if !ok { return }
	defer pssg_delete(&file)
	testing.expect_value(t, file.root.name, "ROOT")
	testing.expect_value(t, len(file.root.attrs), 1)
	testing.expect_value(t, len(file.root.children), 1)
	testing.expect_value(t, file.root.children[0].name, "DATA")
	testing.expect(t, bytes.equal(file.root.children[0].data, []u8{0xaa,0xbb,0xcc}))
	rebuilt, wrote := pssg_write(&file, context.allocator)
	testing.expect(t, wrote); if wrote { defer delete(rebuilt); testing.expect(t, bytes.equal(raw, rebuilt)) }
}

@(test)
pssg_rejects_bad_sizes :: proc(t: ^testing.T) {
	raw := test_pssg_fixture(context.allocator); defer delete(raw)
	raw[7] -= 1
	file, _, ok := pssg_read(raw, context.allocator)
	testing.expect(t, !ok)
	if ok { pssg_delete(&file) }
}

@(test)
pssg_workspace_routesplit_roundtrips_when_present :: proc(t: ^testing.T) {
	// No proprietary donor in the release environment; a developer's own export
	// exercises the full schema and route tree.
	path := "build/out/mooseloop/routesplit.pssg"
	if !os.exists(path) { return }
	raw, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil); if err != nil { return }
	defer delete(raw)
	file, msg, ok := pssg_read(raw, context.allocator)
	testing.expect(t, ok, msg); if !ok { return }
	defer pssg_delete(&file)
	rebuilt, wrote := pssg_write(&file, context.allocator)
	testing.expect(t, wrote); if wrote { defer delete(rebuilt); testing.expect(t, bytes.equal(raw, rebuilt)) }
}
