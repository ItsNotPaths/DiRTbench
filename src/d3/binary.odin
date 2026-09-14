package d3

// Shared primitives for the binary containers emitted by export targets.
// Writers append sequentially, but may reserve a header and patch it after the
// payload is known. A bad range or alignment poisons the writer instead of
// indexing outside its buffer; callers check `ok` before publishing the bytes.

import "core:mem"

Byte_Order :: enum {
	Little,
	Big,
}

Binary_Writer :: struct {
	data: [dynamic]u8,
	ok:   bool,
}

binary_writer :: proc(allocator := context.allocator) -> Binary_Writer {
	return {data = make([dynamic]u8, allocator), ok = true}
}

binary_writer_delete :: proc(w: ^Binary_Writer) {
	delete(w.data)
	w^ = {}
}

// True when [at, at+size) is a valid range. Written without `at+size` so a
// hostile size cannot wrap before the comparison.
binary_range :: proc(length, at, size: int) -> bool {
	return at >= 0 && size >= 0 && at <= length && size <= length - at
}

binary_align_up :: proc(value, alignment: int) -> (aligned: int, ok: bool) {
	if value < 0 || alignment <= 0 || !mem.is_power_of_two(uintptr(alignment)) {
		return 0, false
	}
	mask := alignment - 1
	if value > max(int) - mask {
		return 0, false
	}
	return (value + mask) & ~mask, true
}

binary_reserve :: proc(w: ^Binary_Writer, size: int) -> (at: int, ok: bool) {
	if !w.ok || size < 0 || len(w.data) > max(int) - size {
		w.ok = false
		return 0, false
	}
	at = len(w.data)
	resize(&w.data, at + size)
	return at, true
}

binary_align :: proc(w: ^Binary_Writer, alignment: int, fill: u8 = 0) -> bool {
	target, valid := binary_align_up(len(w.data), alignment)
	if !w.ok || !valid {
		w.ok = false
		return false
	}
	old := len(w.data)
	_, ok := binary_reserve(w, target - old)
	if ok && fill != 0 {
		for i in old ..< target {
			w.data[i] = fill
		}
	}
	return ok
}

binary_write :: proc(w: ^Binary_Writer, src: []u8) -> (at: int, ok: bool) {
	at, ok = binary_reserve(w, len(src))
	if ok {
		copy(w.data[at:], src)
	}
	return
}

binary_write_string :: proc(w: ^Binary_Writer, src: string, nul_terminate := false) -> (at: int, ok: bool) {
	extra := 0
	if nul_terminate { extra = 1 }
	at, ok = binary_reserve(w, len(src) + extra)
	if ok {
		copy(w.data[at:], transmute([]u8)src)
	}
	return
}

binary_patch_u8 :: proc(w: ^Binary_Writer, at: int, value: u8) -> bool {
	if !w.ok || !binary_range(len(w.data), at, 1) {
		w.ok = false
		return false
	}
	w.data[at] = value
	return true
}

binary_patch_u16 :: proc(w: ^Binary_Writer, at: int, value: u16, order: Byte_Order = .Little) -> bool {
	if !w.ok || !binary_range(len(w.data), at, 2) {
		w.ok = false
		return false
	}
	if order == .Little {
		w.data[at] = u8(value); w.data[at+1] = u8(value >> 8)
	} else {
		w.data[at] = u8(value >> 8); w.data[at+1] = u8(value)
	}
	return true
}

binary_patch_u32 :: proc(w: ^Binary_Writer, at: int, value: u32, order: Byte_Order = .Little) -> bool {
	if !w.ok || !binary_range(len(w.data), at, 4) {
		w.ok = false
		return false
	}
	if order == .Little {
		for i in 0..<4 { w.data[at+i] = u8(value >> (uintptr(8)*uintptr(i))) }
	} else {
		for i in 0..<4 { w.data[at+i] = u8(value >> (uintptr(8)*uintptr(3-i))) }
	}
	return true
}

binary_patch_u64 :: proc(w: ^Binary_Writer, at: int, value: u64, order: Byte_Order = .Little) -> bool {
	if !w.ok || !binary_range(len(w.data), at, 8) {
		w.ok = false
		return false
	}
	if order == .Little {
		for i in 0..<8 { w.data[at+i] = u8(value >> (uintptr(8)*uintptr(i))) }
	} else {
		for i in 0..<8 { w.data[at+i] = u8(value >> (uintptr(8)*uintptr(7-i))) }
	}
	return true
}

// Bounds-checked stores for an existing fixed buffer. These are useful when a
// format's final size is known up front, while Binary_Writer covers streaming.
binary_store_u16 :: proc(dst: []u8, at: int, value: u16, order: Byte_Order = .Little) -> bool {
	if !binary_range(len(dst), at, 2) { return false }
	if order == .Little {
		dst[at] = u8(value); dst[at+1] = u8(value >> 8)
	} else {
		dst[at] = u8(value >> 8); dst[at+1] = u8(value)
	}
	return true
}

binary_store_u32 :: proc(dst: []u8, at: int, value: u32, order: Byte_Order = .Little) -> bool {
	if !binary_range(len(dst), at, 4) { return false }
	if order == .Little {
		for i in 0..<4 { dst[at+i] = u8(value >> (uintptr(8)*uintptr(i))) }
	} else {
		for i in 0..<4 { dst[at+i] = u8(value >> (uintptr(8)*uintptr(3-i))) }
	}
	return true
}

binary_store_i32 :: proc(dst: []u8, at: int, value: int, order: Byte_Order = .Little) -> bool {
	return binary_store_u32(dst, at, u32(i32(value)), order)
}

binary_store_f32 :: proc(dst: []u8, at: int, value: f32, order: Byte_Order = .Little) -> bool {
	return binary_store_u32(dst, at, transmute(u32)value, order)
}

binary_patch_i32 :: proc(w: ^Binary_Writer, at: int, value: int, order: Byte_Order = .Little) -> bool {
	return binary_patch_u32(w, at, u32(i32(value)), order)
}

binary_patch_f32 :: proc(w: ^Binary_Writer, at: int, value: f32, order: Byte_Order = .Little) -> bool {
	return binary_patch_u32(w, at, transmute(u32)value, order)
}

binary_write_u8 :: proc(w: ^Binary_Writer, value: u8) -> bool {
	at, ok := binary_reserve(w, 1)
	return ok && binary_patch_u8(w, at, value)
}

binary_write_u16 :: proc(w: ^Binary_Writer, value: u16, order: Byte_Order = .Little) -> bool {
	at, ok := binary_reserve(w, 2)
	return ok && binary_patch_u16(w, at, value, order)
}

binary_write_u32 :: proc(w: ^Binary_Writer, value: u32, order: Byte_Order = .Little) -> bool {
	at, ok := binary_reserve(w, 4)
	return ok && binary_patch_u32(w, at, value, order)
}

binary_write_u64 :: proc(w: ^Binary_Writer, value: u64, order: Byte_Order = .Little) -> bool {
	at, ok := binary_reserve(w, 8)
	return ok && binary_patch_u64(w, at, value, order)
}

binary_write_i32 :: proc(w: ^Binary_Writer, value: int, order: Byte_Order = .Little) -> bool {
	return binary_write_u32(w, u32(i32(value)), order)
}

binary_write_f32 :: proc(w: ^Binary_Writer, value: f32, order: Byte_Order = .Little) -> bool {
	return binary_write_u32(w, transmute(u32)value, order)
}

// A first-seen string table for formats such as BinXML. Strings are borrowed:
// the source text must remain alive until the container has been emitted.
Binary_String_Table :: struct {
	values: [dynamic]string,
}

binary_string_table :: proc(allocator := context.allocator) -> Binary_String_Table {
	return {values = make([dynamic]string, allocator)}
}

binary_string_table_delete :: proc(t: ^Binary_String_Table) {
	delete(t.values)
	t^ = {}
}

binary_string_intern :: proc(t: ^Binary_String_Table, value: string) -> int {
	for existing, i in t.values {
		if existing == value { return i }
	}
	append(&t.values, value)
	return len(t.values) - 1
}
