package d3

import "core:bytes"
import "core:testing"

@(test)
binary_writer_encodes_both_byte_orders :: proc(t: ^testing.T) {
	w := binary_writer(context.temp_allocator)
	defer binary_writer_delete(&w)

	testing.expect(t, binary_write_u16(&w, 0x1234, .Little))
	testing.expect(t, binary_write_u16(&w, 0x1234, .Big))
	testing.expect(t, binary_write_u32(&w, 0x12345678, .Little))
	testing.expect(t, binary_write_u32(&w, 0x12345678, .Big))
	testing.expect(t, bytes.equal(w.data[:], []u8{
		0x34, 0x12, 0x12, 0x34,
		0x78, 0x56, 0x34, 0x12,
		0x12, 0x34, 0x56, 0x78,
	}))
}

@(test)
binary_writer_reserves_patches_and_aligns :: proc(t: ^testing.T) {
	w := binary_writer(context.temp_allocator)
	defer binary_writer_delete(&w)

	header, ok := binary_reserve(&w, 4)
	testing.expect(t, ok)
	_, ok = binary_write_string(&w, "PSSG", true)
	testing.expect(t, ok)
	testing.expect(t, binary_align(&w, 16, 0xCC))
	testing.expect(t, binary_patch_u32(&w, header, u32(len(w.data))))

	testing.expect_value(t, len(w.data), 16)
	testing.expect(t, bytes.equal(w.data[:9], []u8{16, 0, 0, 0, 'P', 'S', 'S', 'G', 0}))
	for byte in w.data[9:] {
		testing.expect_value(t, byte, u8(0xCC))
	}
}

@(test)
binary_writer_fails_closed_on_bad_ranges :: proc(t: ^testing.T) {
	w := binary_writer(context.temp_allocator)
	defer binary_writer_delete(&w)
	_, _ = binary_reserve(&w, 4)

	testing.expect(t, !binary_patch_u32(&w, 1, 7))
	testing.expect(t, !w.ok)
	testing.expect(t, !binary_write_u8(&w, 1), "a poisoned writer must reject later writes")
	testing.expect_value(t, len(w.data), 4)

	testing.expect(t, !binary_range(4, -1, 1))
	testing.expect(t, !binary_range(4, 3, 2))
	testing.expect(t, !binary_range(4, 0, -1))
	_, aligned := binary_align_up(7, 3)
	testing.expect(t, !aligned, "alignment must be a positive power of two")
}

@(test)
binary_string_table_is_first_seen_and_stable :: proc(t: ^testing.T) {
	table := binary_string_table(context.temp_allocator)
	defer binary_string_table_delete(&table)

	testing.expect_value(t, binary_string_intern(&table, "gate"), 0)
	testing.expect_value(t, binary_string_intern(&table, "position"), 1)
	testing.expect_value(t, binary_string_intern(&table, "gate"), 0)
	testing.expect_value(t, len(table.values), 2)
	testing.expect_value(t, table.values[0], "gate")
	testing.expect_value(t, table.values[1], "position")
}

@(test)
binary_fixed_store_is_checked :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect(t, binary_store_u32(buf[:], 0, 0x3f800000, .Big))
	testing.expect(t, bytes.equal(buf[:4], []u8{0x3f, 0x80, 0, 0}))
	testing.expect(t, binary_store_f32(buf[:], 4, 1.0))
	testing.expect(t, bytes.equal(buf[4:], []u8{0, 0, 0x80, 0x3f}))
	testing.expect(t, !binary_store_u32(buf[:], 6, 0))
	testing.expect(t, binary_store_u16(buf[:], 0, 0x1234, .Big))
	testing.expect(t, binary_store_u16(buf[:], 2, 0x1234, .Little))
	testing.expect(t, bytes.equal(buf[:4], []u8{0x12, 0x34, 0x34, 0x12}))
	testing.expect(t, !binary_store_u16(buf[:], 7, 0))
}
