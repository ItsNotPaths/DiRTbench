package d3

import "core:fmt"

// Dirt 3 "instance placement" files: `trees.bin` and `ornaments.bin` share
// one container. A fixed header, a reference table (one row per unique prop
// mesh), an instance table (one row per placement: which reference, where,
// how rotated), then a NUL-terminated string pool at the end holding every
// reference's filename, addressed by *absolute file offset*.
//
// Every field below is verified against the BinXML sibling files
// (`trees.xml`/`ornaments.xml`), field by field, not guessed — one exception
// noted at the ornaments layout.

D3_Placement_Format :: enum { Trees, Ornaments }

D3_Placement_Layout :: struct {
	format:         D3_Placement_Format,
	header_size:    int,
	// Header field(s) to read and overwrite the instance count at. The first
	// is the one trusted to hold the true count; any further ones are
	// written to keep them in step, never read back.
	inst_num_write: []int,
	ref_table_at:   int, // header field holding the reference table's offset
	ref_num_at:     int,
	inst_table_at:  int,
	ref_stride:     int,
	inst_stride:    int,
}

// trees.bin: format tag 12 at offset 4, 64-byte header. instance_num is
// stored twice, and every stock file we measured has the two copies equal.
D3_TREES_LAYOUT := D3_Placement_Layout{
	format = .Trees, header_size = 0x40,
	inst_num_write = []int{0x28, 0x3c},
	ref_table_at = 0x30, ref_num_at = 0x24, inst_table_at = 0x38,
	ref_stride = 40, inst_stride = 76,
}

// ornaments.bin: format tag 28, 116-byte header. Bytes 0x50..0x73, right
// before the reference table, tally reference categories by name prefix —
// confirmed exact for core_barr_*/core_game_*, a third slot unconfirmed —
// and `d3_placement_relocate` leaves them untouched, because the reference
// table they describe never moves or changes.
//
// Unlike trees.bin, offset 0x38 is *not* a second copy of instance_num: it
// disagrees with the true count (checked against the `<instance>` element
// count in the sibling ornaments.xml) in every stock file sampled. What it
// actually holds is unknown, so a rewrite leaves it alone; only 0x4c, the
// field whose value is consistent with the file's own size, is trusted.
D3_ORNAMENTS_LAYOUT := D3_Placement_Layout{
	format = .Ornaments, header_size = 0x74,
	inst_num_write = []int{0x4c},
	ref_table_at = 0x40, ref_num_at = 0x34, inst_table_at = 0x48,
	ref_stride = 48, inst_stride = 88,
}

d3_placement_layout :: proc(data: []u8) -> (layout: D3_Placement_Layout, ok: bool) {
	if len(data) < 8 { return {}, false }
	switch binary_load_u32(data, 4) {
	case 12: return D3_TREES_LAYOUT, true
	case 28: return D3_ORNAMENTS_LAYOUT, true
	}
	return {}, false
}

// One placement: which reference mesh, a row-major 3x3 rotation/scale, and a
// world position. The instance tag is minted by the caller's position in the
// list — every stock file we measured has it unique but not necessarily
// sequential, and nothing reads it back as an index.
D3_Placement_Instance :: struct {
	reference_id: u32,
	basis:        [3][3]f32,
	position:     [3]f32,
}

D3_BASIS_IDENTITY :: [3][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

d3_placement_encode_instance :: proc(w: []u8, at: int, index: u32, inst: D3_Placement_Instance, layout: D3_Placement_Layout) {
	binary_store_u32(w, at, inst.reference_id)
	binary_store_u32(w, at+4, index)
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			binary_store_f32(w, at+8+(row*3+col)*4, inst.basis[row][col])
		}
	}
	for k in 0 ..< 3 { binary_store_f32(w, at+44+k*4, inst.position[k]) }
	switch layout.format {
	case .Trees:
		binary_store_u32(w, at+56, 0xff000000) // colour: opaque black in every stock record
		binary_store_f32(w, at+60, 1.0)        // shadow factor: always 1 in every stock record
		binary_store_u32(w, at+64, 0)
		binary_store_u32(w, at+68, 0)
		binary_store_u32(w, at+72, index+1) // instance_tag: any value works, stock has none repeat
	case .Ornaments:
		for k in 0 ..< 5 { binary_store_u32(w, at+56+k*4, 0) }
		binary_store_u32(w, at+76, index+1)
		binary_store_u32(w, at+80, 0xffffffff)
		binary_store_u32(w, at+84, 0xffffffff)
	}
}

// True where `at` is a byte offset an ASCII, NUL-terminated name could start:
// a printable byte, with a NUL within a short run. Used only to find pointers
// hiding in a not-yet-decoded sub-table (see `d3_placement_relocate`) — never
// inside the string pool itself, so a stray match against ordinary name text
// is not a risk.
d3_placement_looks_like_name_offset :: proc(data: []u8, at: int) -> bool {
	if at < 0 || at >= len(data) || data[at] < 32 || data[at] > 126 { return false }
	limit := min(at+128, len(data))
	for i := at; i < limit; i += 1 {
		if data[i] == 0 { return true }
	}
	return false
}

// Ground truth for where the string pool actually starts: the smallest
// filename pointer any reference names. Everything between the end of the
// instance table and there is an undecoded sub-table, if the file has one.
d3_placement_string_pool_at :: proc(data: []u8, ref_table_offset, reference_num, ref_stride: int) -> int {
	at := len(data)
	for r in 0 ..< reference_num {
		p := binary_load_i32(data, ref_table_offset+r*ref_stride)
		if p < at { at = p }
	}
	return at
}

// Every reference's filename pointer is an absolute file offset into the
// string pool, so it must move by however many bytes the instance table
// grew or shrank.
d3_placement_shift_references :: proc(result: []u8, ref_table_offset, reference_num, ref_stride, delta: int) {
	for r in 0 ..< reference_num {
		at := ref_table_offset + r*ref_stride
		binary_store_i32(result, at, binary_load_i32(result, at)+delta)
	}
}

// The undecoded sub-table between the old instance table and the string pool
// (see `d3_placement_relocate`) may hold its own absolute pointers into the
// same pool. Rather than decode its record layout, every 4-byte-aligned word
// in `[gap_at, gap_end)` is tested for "does this look like a pointer to a
// real name" and shifted if so. `unshifted` is the original file, read at the
// pre-shift position, since the block copy moved bytes but not their content.
d3_placement_shift_gap :: proc(result, unshifted: []u8, gap_at, gap_end, string_pool_at, delta: int) {
	for at := gap_at; at+4 <= gap_end; at += 4 {
		p := binary_load_i32(result, at)
		if p >= string_pool_at && d3_placement_looks_like_name_offset(unshifted, p) {
			binary_store_i32(result, at, p+delta)
		}
	}
}

d3_placement_decode_instance :: proc(data: []u8, at: int) -> (inst: D3_Placement_Instance) {
	inst.reference_id = binary_load_u32(data, at)
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			inst.basis[row][col] = binary_load_f32(data, at+8+(row*3+col)*4)
		}
	}
	for k in 0 ..< 3 { inst.position[k] = binary_load_f32(data, at+44+k*4) }
	return
}

// Read every instance out of a placement file, in file order. The inverse of
// `d3_placement_relocate`.
d3_placement_read :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	instances: []D3_Placement_Instance,
	msg: string,
	ok: bool,
) {
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return nil, "not a recognised Dirt 3 placement file", false }

	ref_table_offset := binary_load_i32(data, layout.ref_table_at)
	reference_num := binary_load_i32(data, layout.ref_num_at)
	instance_table_offset := binary_load_i32(data, layout.inst_table_at)
	instance_num := binary_load_i32(data, layout.inst_num_write[0])

	if ref_table_offset != layout.header_size ||
	   instance_table_offset != ref_table_offset+reference_num*layout.ref_stride {
		return nil, "placement file layout does not match what this reader expects", false
	}
	if instance_num < 0 {
		return nil, "placement file has a negative instance count", false
	}
	tail_at := instance_table_offset + instance_num*layout.inst_stride
	if tail_at > len(data) {
		return nil, "placement file is shorter than its own instance table", false
	}

	out := make([]D3_Placement_Instance, instance_num, allocator)
	for i in 0 ..< instance_num {
		out[i] = d3_placement_decode_instance(data, instance_table_offset+i*layout.inst_stride)
	}
	return out, fmt.tprintf("%d instances, %d references", instance_num, reference_num), true
}

// A reference mesh's local-space bounding box, straight off its row in the
// reference table. Both `trees.bin` and `ornaments.bin` carry it at the same
// relative offset, +8/+20 from the row start, despite their different
// strides — confirmed byte-exact against the BinXML siblings
// (`trees.xml`/`ornaments.xml`'s `bounds_min`/`bounds_max`).
d3_placement_reference_bounds :: proc(
	data: []u8,
	layout: D3_Placement_Layout,
	reference_id: int,
) -> (
	lo, hi: [3]f32,
	ok: bool,
) {
	ref_table_offset := binary_load_i32(data, layout.ref_table_at)
	reference_num := binary_load_i32(data, layout.ref_num_at)
	if reference_id < 0 || reference_id >= reference_num { return {}, {}, false }
	at := ref_table_offset + reference_id*layout.ref_stride
	for k in 0 ..< 3 {
		lo[k] = binary_load_f32(data, at+8+k*4)
		hi[k] = binary_load_f32(data, at+20+k*4)
	}
	return lo, hi, true
}

// The world-space box of one placed instance: the referenced mesh's local
// bounding box, its 8 corners carried through the instance's basis and
// position, then re-flattened to an axis-aligned box.
d3_placement_instance_box :: proc(
	data: []u8,
	layout: D3_Placement_Layout,
	inst: D3_Placement_Instance,
) -> (
	lo, hi: [3]f32,
	ok: bool,
) {
	local_lo, local_hi, bounds_ok := d3_placement_reference_bounds(data, layout, int(inst.reference_id))
	if !bounds_ok { return {}, {}, false }

	seen := false
	for i in 0 ..< 8 {
		corner := [3]f32{
			local_lo[0] if i&1 == 0 else local_hi[0],
			local_lo[1] if i&2 == 0 else local_hi[1],
			local_lo[2] if i&4 == 0 else local_hi[2],
		}
		world: [3]f32
		for k in 0 ..< 3 {
			world[k] = inst.position[k] +
				inst.basis[0][k]*corner[0] + inst.basis[1][k]*corner[1] + inst.basis[2][k]*corner[2]
		}
		for k in 0 ..< 3 {
			if !seen { lo[k] = world[k]; hi[k] = world[k] } else { lo[k] = min(lo[k], world[k]); hi[k] = max(hi[k], world[k]) }
		}
		seen = true
	}
	return lo, hi, true
}

// Replace every instance in a placement file, keeping its reference table and
// string pool untouched. The game finds a prop mesh only through the
// reference table, so a rewrite never needs to touch what a reference *is* —
// only the instance count, and every absolute pointer into the string pool.
d3_placement_relocate :: proc(
	data: []u8,
	instances: []D3_Placement_Instance,
	allocator := context.allocator,
) -> (
	out: []u8,
	msg: string,
	ok: bool,
) {
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return nil, "not a recognised Dirt 3 placement file", false }

	ref_table_offset := binary_load_i32(data, layout.ref_table_at)
	reference_num := binary_load_i32(data, layout.ref_num_at)
	instance_table_offset := binary_load_i32(data, layout.inst_table_at)
	old_instance_num := binary_load_i32(data, layout.inst_num_write[0])

	if ref_table_offset != layout.header_size ||
	   instance_table_offset != ref_table_offset+reference_num*layout.ref_stride {
		return nil, "placement file layout does not match what this writer expects", false
	}
	old_tail_at := instance_table_offset + old_instance_num*layout.inst_stride
	if old_tail_at > len(data) {
		return nil, "placement file is shorter than its own instance table", false
	}
	string_pool_at := d3_placement_string_pool_at(data, ref_table_offset, reference_num, layout.ref_stride)
	if string_pool_at < old_tail_at {
		return nil, "a reference points inside the instance table", false
	}

	new_instance_bytes := len(instances) * layout.inst_stride
	delta := new_instance_bytes - old_instance_num*layout.inst_stride

	total := instance_table_offset + new_instance_bytes + (len(data)-old_tail_at)
	result := make([]u8, total, allocator)
	copy(result[:instance_table_offset], data[:instance_table_offset])
	copy(result[instance_table_offset+new_instance_bytes:], data[old_tail_at:])

	for i in layout.inst_num_write {
		binary_store_u32(result, i, u32(len(instances)))
	}
	d3_placement_shift_references(result, ref_table_offset, reference_num, layout.ref_stride, delta)
	gap_at := instance_table_offset + new_instance_bytes
	d3_placement_shift_gap(result, data, gap_at, gap_at+(string_pool_at-old_tail_at), string_pool_at, delta)
	for inst, i in instances {
		d3_placement_encode_instance(result, instance_table_offset+i*layout.inst_stride, u32(i), inst, layout)
	}

	return result, fmt.tprintf(
		"%d -> %d instances, %d references kept",
		old_instance_num, len(instances), reference_num,
	), true
}
