package d3

// Read-side counterpart to binary.odin's bounds-checked stores. Out-of-range
// reads return zero rather than propagating an error: a malformed file
// should not panic, and every caller already validates structure (counts,
// offsets) before trusting a value.

binary_load_u32 :: proc(src: []u8, at: int, order: Byte_Order = .Little) -> u32 {
	if !binary_range(len(src), at, 4) { return 0 }
	if order == .Little {
		return u32(src[at]) | u32(src[at+1])<<8 | u32(src[at+2])<<16 | u32(src[at+3])<<24
	}
	return u32(src[at])<<24 | u32(src[at+1])<<16 | u32(src[at+2])<<8 | u32(src[at+3])
}

binary_load_i32 :: proc(src: []u8, at: int, order: Byte_Order = .Little) -> int {
	return int(i32(binary_load_u32(src, at, order)))
}

binary_load_f32 :: proc(src: []u8, at: int, order: Byte_Order = .Little) -> f32 {
	return transmute(f32)binary_load_u32(src, at, order)
}
