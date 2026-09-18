package d3

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

// Dirt 3 "instance placement" files: `trees.bin` and `ornaments.bin` share
// one container. A fixed header, a reference table (one row per unique prop
// mesh), an instance table (one row per placement: which reference, where,
// how rotated), then a NUL-terminated string pool at the end holding every
// reference's filename, addressed by *absolute file offset*.
//
// Every core field below is verified against the plain XML sibling files
// (`trees.xml`/`ornaments.xml`), field by field.

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

// ornaments.bin: format tag 28, 116-byte header. 0x38 is the full authored
// main-list count from ornaments.xml; 0x4c is the smaller cooked instance
// count. 0x50..0x70 describe optional dependent references/instances and path
// animations. A valid minimal file has zero counts and all three table offsets
// meeting at the string pool.
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

// One placement shared by decode, donor relocation, synthesis, and ENS
// physics mirroring. Format-specific fields are ignored by the other format.
D3_Placement_Instance :: struct {
	reference_id: u32,
	instance_id:  u32,
	instance_tag: u32,
	basis:        [3][3]f32,
	position:     [3]f32,
	shadow_factor: f32, // trees only; zero emits the stock default of 1
	is_dynamic:    bool, // ornaments only
}

// Complete source data for a donor-free placement file. `reference_id` is
// deliberately explicit on both records: stock files keep ids dense, but the
// writer validates that invariant rather than silently depending on order.
D3_Placement_Reference :: struct {
	reference_id:     u32,
	filename:         string,
	bounds_min:       [3]f32,
	bounds_max:       [3]f32,
	prebaked_shadows: u32,
	sponsor:          u32, // ornaments only; zero for ordinary references
	// Ornament registration capacity, including dynamic ENS-only drawables.
	// Zero derives capacity from the cooked instances.
	instance_capacity: u32,
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

@(private = "file")
d3_placement_build_box :: proc(
	references: []D3_Placement_Reference,
	instances: []D3_Placement_Instance,
) -> (lo, hi: [3]f32, ok: bool) {
	seen := false
	for inst in instances {
		if int(inst.reference_id) >= len(references) { return {}, {}, false }
		ref := references[inst.reference_id]
		for corner_i in 0..<8 {
			corner := [3]f32{
				ref.bounds_min[0] if corner_i&1 == 0 else ref.bounds_max[0],
				ref.bounds_min[1] if corner_i&2 == 0 else ref.bounds_max[1],
				ref.bounds_min[2] if corner_i&4 == 0 else ref.bounds_max[2],
			}
			world: [3]f32
			for k in 0..<3 {
				world[k] = inst.position[k] +
					inst.basis[0][k]*corner[0] + inst.basis[1][k]*corner[1] + inst.basis[2][k]*corner[2]
			}
			for k in 0..<3 {
				if !seen { lo[k], hi[k] = world[k], world[k] } else { lo[k], hi[k] = min(lo[k], world[k]), max(hi[k], world[k]) }
			}
			seen = true
		}
	}
	return lo, hi, seen || len(instances) == 0
}

@(private = "file")
d3_placement_reference_counts :: proc(
	references: []D3_Placement_Reference,
	instances: []D3_Placement_Instance,
	allocator := context.allocator,
) -> (counts: []u32, ok: bool) {
	out := make([]u32, len(references), allocator)
	for ref, i in references {
		if ref.reference_id != u32(i) || ref.filename == "" { delete(out, allocator); return nil, false }
		for k in 0..<3 { if ref.bounds_min[k] > ref.bounds_max[k] { delete(out, allocator); return nil, false } }
	}
	// Instance order is free. Only 8 of 109 stock trees.bin group their
	// instances by reference and the game loads all of them, so the row's
	// count is a population and never a contiguous run — measured exact
	// against every stock file.
	for inst in instances {
		if int(inst.reference_id) >= len(references) { delete(out, allocator); return nil, false }
		out[inst.reference_id] += 1
	}
	return out, true
}

@(private = "file")
d3_placement_reference_capacities :: proc(
	format: D3_Placement_Format,
	references: []D3_Placement_Reference,
	counts: []u32,
	allocator := context.allocator,
) -> (capacities: []u32, total: u32, ok: bool) {
	out := make([]u32, len(references), allocator)
	for ref, i in references {
		capacity := counts[i]
		if format == .Ornaments && ref.instance_capacity != 0 { capacity = ref.instance_capacity }
		if capacity < counts[i] { delete(out, allocator); return nil, 0, false }
		out[i] = capacity
		if total > max(u32)-capacity { delete(out, allocator); return nil, 0, false }
		total += capacity
	}
	return out, total, true
}

// Build trees.bin or ornaments.bin outright. The optional ornament sections
// (dependent wet variants and path animations) are validly empty: stock files
// with neither use this exact shape, with all three offsets meeting at the
// string pool. They can be added to the source model when the editor exposes
// those features without changing the core reference/instance tables.
d3_placement_build :: proc(
	format: D3_Placement_Format,
	references: []D3_Placement_Reference,
	instances: []D3_Placement_Instance,
	allocator := context.allocator,
) -> (out: []u8, msg: string, ok: bool) {
	layout := D3_TREES_LAYOUT
	if format == .Ornaments { layout = D3_ORNAMENTS_LAYOUT }
	counts, counts_ok := d3_placement_reference_counts(references, instances, context.temp_allocator)
	if !counts_ok { return nil, "placement references must be dense, named, bounded, and cover every instance", false }
	capacities, authored_count, capacities_ok := d3_placement_reference_capacities(format, references, counts, context.temp_allocator)
	if !capacities_ok { return nil, "placement reference capacity cannot be smaller than its cooked instance count", false }

	string_bytes := 0
	for ref in references { string_bytes += len(ref.filename)+1 }
	ref_at := layout.header_size
	inst_at := ref_at + len(references)*layout.ref_stride
	strings_at := inst_at + len(instances)*layout.inst_stride
	result := make([]u8, strings_at+string_bytes, allocator)

	binary_store_u32(result, 0x04, 12 if format == .Trees else 28)
	binary_store_u32(result, 0x08, 1)
	lo, hi, bounds_ok := d3_placement_build_box(references, instances)
	if !bounds_ok { delete(result, allocator); return nil, "could not bound placement instances", false }
	bounds_at := 0x0c if format == .Trees else 0x1c
	for k in 0..<3 { binary_store_f32(result, bounds_at+k*4, lo[k]); binary_store_f32(result, bounds_at+12+k*4, hi[k]) }

	if format == .Trees {
		binary_store_u32(result, 0x24, u32(len(references)))
		binary_store_u32(result, 0x28, u32(len(instances)))
		binary_store_u32(result, 0x30, u32(ref_at))
		binary_store_u32(result, 0x34, u32(len(references)))
		binary_store_u32(result, 0x38, u32(inst_at))
		binary_store_u32(result, 0x3c, u32(len(instances)))
	} else {
		binary_store_u32(result, 0x0c, 0x50); binary_store_u32(result, 0x10, 1)
		binary_store_u32(result, 0x14, 0x68); binary_store_u32(result, 0x18, 1)
		binary_store_u32(result, 0x34, u32(len(references)))
		binary_store_u32(result, 0x38, authored_count) // full exported id capacity, including ENS-only drawables
		binary_store_u32(result, 0x40, u32(ref_at))
		binary_store_u32(result, 0x44, u32(len(references)))
		binary_store_u32(result, 0x48, u32(inst_at))
		binary_store_u32(result, 0x4c, u32(len(instances))) // cooked instance count
		// Empty dependent-reference, dependent-instance and path-animation lists.
		binary_store_u32(result, 0x58, u32(strings_at))
		binary_store_u32(result, 0x60, u32(strings_at))
		binary_store_u32(result, 0x6c, u32(strings_at))
	}

	name_at := strings_at
	for ref, i in references {
		at := ref_at+i*layout.ref_stride
		binary_store_u32(result, at, u32(name_at))
		binary_store_u32(result, at+4, ref.reference_id)
		for k in 0..<3 { binary_store_f32(result, at+8+k*4, ref.bounds_min[k]); binary_store_f32(result, at+20+k*4, ref.bounds_max[k]) }
		if format == .Trees {
			binary_store_u32(result, at+32, ref.prebaked_shadows)
			binary_store_u32(result, at+36, counts[i])
		} else {
			binary_store_u32(result, at+32, ref.sponsor)
			binary_store_u32(result, at+36, ref.prebaked_shadows)
			binary_store_u32(result, at+40, capacities[i])
			binary_store_u32(result, at+44, 0xffffffff)
		}
		copy(result[name_at:], ref.filename); name_at += len(ref.filename)+1
	}
	for inst, i in instances {
		at := inst_at+i*layout.inst_stride
		binary_store_u32(result, at, inst.reference_id)
		binary_store_u32(result, at+4, inst.instance_id)
		for row in 0..<3 { for col in 0..<3 { binary_store_f32(result, at+8+(row*3+col)*4, inst.basis[row][col]) } }
		for k in 0..<3 { binary_store_f32(result, at+44+k*4, inst.position[k]) }
		if format == .Trees {
			binary_store_u32(result, at+56, 0xff000000)
			binary_store_f32(result, at+60, inst.shadow_factor if inst.shadow_factor != 0 else 1)
			binary_store_u32(result, at+72, inst.instance_tag)
		} else {
			binary_store_u32(result, at+64, 1 if inst.is_dynamic else 0)
			binary_store_u32(result, at+76, inst.instance_tag)
			binary_store_u32(result, at+80, 0xffffffff)
			binary_store_u32(result, at+84, 0xffffffff)
		}
	}
	return result, fmt.tprintf("%d references, %d instances", len(references), len(instances)), true
}

@(private = "file")
d3_placement_xml_f3 :: proc(v: [3]f32) -> string { return fmt.tprintf("%.9g %.9g %.9g", v[0], v[1], v[2]) }

@(private = "file")
d3_placement_xml_transform :: proc(inst: D3_Placement_Instance) -> string {
	return fmt.tprintf(
		"%.9g %.9g %.9g 0 %.9g %.9g %.9g 0 %.9g %.9g %.9g 0 %.9g %.9g %.9g 1 ",
		inst.basis[0][0], inst.basis[0][1], inst.basis[0][2], inst.basis[1][0], inst.basis[1][1], inst.basis[1][2],
		inst.basis[2][0], inst.basis[2][1], inst.basis[2][2], inst.position[0], inst.position[1], inst.position[2],
	)
}

// Emit the authoring sibling from the same source slices as the cooked BIN.
d3_placement_xml_build :: proc(
	format: D3_Placement_Format,
	references: []D3_Placement_Reference,
	instances: []D3_Placement_Instance,
	allocator := context.allocator,
) -> (out: []u8, msg: string, ok: bool) {
	counts, counts_ok := d3_placement_reference_counts(references, instances, context.temp_allocator)
	if !counts_ok { return nil, "placement references must be dense, named, bounded, and cover every instance", false }
	capacities, authored_count, capacities_ok := d3_placement_reference_capacities(format, references, counts, context.temp_allocator)
	if !capacities_ok { return nil, "placement reference capacity cannot be smaller than its cooked instance count", false }
	lo, hi, bounds_ok := d3_placement_build_box(references, instances)
	if !bounds_ok { return nil, "could not bound placement instances", false }
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "<instancedata>\n  <instancelist bounds_min=\"%s 1\" bounds_max=\"%s 1\" reference_num=\"%d\" instance_num=\"%d\" total_landmarks=\"0\">\n", d3_placement_xml_f3(lo), d3_placement_xml_f3(hi), len(references), authored_count)
	for ref, ri in references {
		fmt.sbprintf(&b, "    <instanceref reference_id=\"%d\" filename=\"%s\" prebaked_shadows=\"%d\" bounds_min=\"%s \" bounds_max=\"%s \"", ref.reference_id, ref.filename, ref.prebaked_shadows, d3_placement_xml_f3(ref.bounds_min), d3_placement_xml_f3(ref.bounds_max))
		if format == .Ornaments && ref.sponsor != 0 { fmt.sbprintf(&b, " sponsor=\"%d\"", ref.sponsor) }
		fmt.sbprintf(&b, " max_instances=\"%d\" />\n", capacities[ri])
		for inst in instances {
			if inst.reference_id != ref.reference_id { continue }
			fmt.sbprintf(&b, "    <instance transform=\"%s\" colour=\"0 0 0 1\" instance_tag=\"%d\" instance_id=\"%d\" reference_id=\"%d\"", d3_placement_xml_transform(inst), inst.instance_tag, inst.instance_id, inst.reference_id)
			if format == .Trees { fmt.sbprintf(&b, " shadow_factor=\"%.9g\"", inst.shadow_factor if inst.shadow_factor != 0 else 1) }
			if format == .Ornaments && inst.is_dynamic { strings.write_string(&b, " dynamic=\"1\"") }
			strings.write_string(&b, " />\n")
		}
	}
	strings.write_string(&b, "  </instancelist>\n  <dependentlist reference_num=\"0\" instance_num=\"0\" />\n</instancedata>\n")
	return b.buf[:], fmt.tprintf("%d references, %d instances", len(references), len(instances)), true
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
	inst.instance_id = binary_load_u32(data, at+4)
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			inst.basis[row][col] = binary_load_f32(data, at+8+(row*3+col)*4)
		}
	}
	for k in 0 ..< 3 { inst.position[k] = binary_load_f32(data, at+44+k*4) }
	// Both formats carry the render/physics join tag, at different tails.
	layout, layout_ok := d3_placement_layout(data)
	if layout_ok { inst.instance_tag = binary_load_u32(data, at + (72 if layout.format == .Trees else 76)) }
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

// The reference table: one row per unique prop mesh, with the filename read
// out of the string pool the row points at. The mirror of the row the writer
// lays down, so the two must stay in step.
//
// A filename is addressed by absolute file offset and is NUL-terminated, so a
// row pointing outside the file or at an unterminated run is a refusal rather
// than a silently truncated name.
d3_placement_read_references :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	references: []D3_Placement_Reference,
	msg: string,
	ok: bool,
) {
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return nil, "not a recognised Dirt 3 placement file", false }

	ref_table_offset := binary_load_i32(data, layout.ref_table_at)
	reference_num := binary_load_i32(data, layout.ref_num_at)
	if reference_num < 0 { return nil, "placement file has a negative reference count", false }
	if ref_table_offset != layout.header_size {
		return nil, "placement file layout does not match what this reader expects", false
	}
	if !binary_range(len(data), ref_table_offset, reference_num*layout.ref_stride) {
		return nil, "placement file is shorter than its own reference table", false
	}

	out := make([]D3_Placement_Reference, reference_num, allocator)
	defer if !ok {
		for ref in out { delete(ref.filename, allocator) }
		delete(out, allocator)
	}
	for i in 0 ..< reference_num {
		at := ref_table_offset + i*layout.ref_stride
		name_at := binary_load_i32(data, at)
		name, name_ok := d3_placement_pool_string(data, name_at, allocator)
		if !name_ok {
			return nil, fmt.tprintf("reference %d names a filename outside the string pool", i), false
		}
		ref := D3_Placement_Reference{
			reference_id = binary_load_u32(data, at+4),
			filename     = name,
		}
		for k in 0..<3 {
			ref.bounds_min[k] = binary_load_f32(data, at+8+k*4)
			ref.bounds_max[k] = binary_load_f32(data, at+20+k*4)
		}
		if layout.format == .Trees {
			ref.prebaked_shadows = binary_load_u32(data, at+32)
		} else {
			ref.sponsor = binary_load_u32(data, at+32)
			ref.prebaked_shadows = binary_load_u32(data, at+36)
			ref.instance_capacity = binary_load_u32(data, at+40)
		}
		out[i] = ref
	}
	return out, fmt.tprintf("%d references", reference_num), true
}

@(private = "file")
d3_placement_pool_string :: proc(data: []u8, at: int, allocator: mem.Allocator) -> (string, bool) {
	if at < 0 || at >= len(data) { return "", false }
	for end in at ..< len(data) {
		if data[end] != 0 { continue }
		return strings.clone(string(data[at:end]), allocator), true
	}
	return "", false
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

// --- ornaments.xml ------------------------------------------------------------

// Every `instance_id` in an `ornaments.xml`, in file order.
//
// This is the id the visibility system looks an ornament up by, and
// `ornaments.bin` does not carry it — the XML sibling is the only place it
// exists. A file whose instances lack the attribute fails closed rather than
// returning a short list, because a missing id reads as a valid one.
d3_ornaments_xml_instance_ids :: proc(data: []u8, allocator := context.allocator) -> (ids: []u32, ok: bool) {
	text := string(data)
	out := make([dynamic]u32, allocator)
	pos := 0
	for {
		start := strings.index(text[pos:], "<instance ")
		if start < 0 { break }
		start += pos
		end := strings.index(text[start:], "/>")
		if end < 0 { return nil, false }
		end += start
		tag := text[start:end]
		attr_at := strings.index(tag, `instance_id="`)
		if attr_at < 0 { return nil, false }
		attr_at += len(`instance_id="`)
		close_quote := strings.index_byte(tag[attr_at:], '"')
		if close_quote < 0 { return nil, false }
		id, id_ok := strconv.parse_int(tag[attr_at:attr_at+close_quote])
		if !id_ok { return nil, false }
		append(&out, u32(id))
		pos = end + 2
	}
	return out[:], true
}
