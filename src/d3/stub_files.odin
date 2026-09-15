package d3

// Valid-but-empty forms of route files whose content describes the *old*
// road. A stub is only safe when a real stock route already ships one this
// way — every form here matches the smallest instance of its file across
// all playable venues. See docs/venue-synthesis.md §4-5 for the survey and
// the manifest this feeds.

D3_STUB_LIGHT_PLACEMENT :: "<light_placement />"
D3_STUB_INTERACTIVE_WATER :: "<interactiveWater />"
D3_STUB_ORGANISM_TRACK_DATASET :: "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<dataset>\r\n</dataset>\r\n"

d3_stub_text :: proc(text: string, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(text), allocator)
	copy(out, text)
	return out
}

d3_stub_zero :: proc(size: int, allocator := context.allocator) -> []u8 {
	return make([]u8, size, allocator)
}

// The stock header of an empty `reducedmechanics.jpk`: magic, zero chunks, a
// fixed 64-byte size. Measured identical across every stock route that ships
// one. Not `d3_jpak_write`'s general shape: that writer has no chunks-and-64-
// bytes case, so this is copied rather than derived.
d3_stub_reducedmechanics :: proc(allocator := context.allocator) -> []u8 {
	out := make([]u8, 64, allocator)
	copy(out[:4], "JPAK")
	binary_store_i32(out, 12, 64)
	binary_store_i32(out, 20, 32)
	return out
}

// The bytes of a real, empty `cameralines.cqtc` past its tag: bounding box,
// tag and section offsets aside, the rest of the leaf is copied rather than
// derived. Two real empty stock `.cqtc` files, with differently-shaped boxes,
// disagree on this leaf's internal child order — and with zero real records
// in either one, neither order is ever traversed, so the one shape is safe to
// reuse for any box.
D3_STUB_CQTC_LEAF := [54]u8{
	0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0xfe, 0xfb, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0xfe, 0xfb, 0xff, 0xff, 0xff,
	0x00, 0x00, 0x00, 0x01, 0x04, 0xff, 0xff, 0xff,
	0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
	0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x01,
	0x00, 0x00, 0x00, 0x00, 0x80, 0x01,
}

// `tag` is exactly 4 bytes: `RESD` for cameralines, `BARR` for barrierlines.
// `resetlines.cqtc` (`RESE`) is the out-of-bounds test and is omitted rather
// than stubbed — see docs/venue-projects.md.
d3_stub_cqtc :: proc(tag: string, lo, hi: [3]f32, allocator := context.allocator) -> []u8 {
	out := make([]u8, 56+len(D3_STUB_CQTC_LEAF), allocator)
	for k in 0 ..< 3 { binary_store_f32(out, k*4, lo[k]) }
	for k in 0 ..< 3 { binary_store_f32(out, 12+k*4, hi[k]) }
	binary_store_u32(out, 24, 2)
	binary_store_u32(out, 28, 4)
	binary_store_u32(out, 32, 1)
	binary_store_u32(out, 36, 56)
	binary_store_u32(out, 40, 88)
	binary_store_u32(out, 44, 91)
	binary_store_u32(out, 48, 105)
	copy(out[52:56], tag)
	copy(out[56:], D3_STUB_CQTC_LEAF[:])
	return out
}
