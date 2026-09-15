package d3

import "core:slice"
import "core:testing"

// A minimal, hand-built trees.bin-shaped file: 2 references ("alpha",
// "omega"), 3 instances. Not real game bytes — this tests that the
// relocate transform's bookkeeping (offsets, counts, pointer shifts) is
// internally consistent, independent of whether the still-unconfirmed
// ornaments fields are ever understood.
d3_test_placement_file :: proc(allocator := context.allocator) -> []u8 {
	layout := D3_TREES_LAYOUT
	ref_num := 2
	inst_num := 3
	ref_table_at := layout.header_size
	inst_table_at := ref_table_at + ref_num*layout.ref_stride
	string_pool_at := inst_table_at + inst_num*layout.inst_stride
	names := []string{"alpha", "omega"}
	pool_size := 0
	for n in names { pool_size += len(n)+1 }

	data := make([]u8, string_pool_at+pool_size, allocator)
	binary_store_u32(data, 0x04, 12) // format tag
	binary_store_u32(data, 0x08, 1)
	binary_store_u32(data, layout.ref_num_at, u32(ref_num))
	binary_store_u32(data, layout.ref_table_at, u32(ref_table_at))
	binary_store_u32(data, layout.inst_table_at, u32(inst_table_at))
	for i in layout.inst_num_write {
		binary_store_u32(data, i, u32(inst_num))
	}

	name_at := string_pool_at
	for name, r in names {
		at := ref_table_at + r*layout.ref_stride
		binary_store_u32(data, at, u32(name_at))
		binary_store_u32(data, at+4, u32(r))
		binary_store_u32(data, at+36, 1) // max_instances
		copy(data[name_at:], name)
		name_at += len(name)+1
	}

	for i in 0 ..< inst_num {
		inst := D3_Placement_Instance{
			reference_id = u32(i % ref_num),
			basis        = D3_BASIS_IDENTITY,
			position     = {f32(i)*10, 1, 0},
		}
		d3_placement_encode_instance(data, inst_table_at+i*layout.inst_stride, u32(i), inst, layout)
	}
	return data
}

d3_test_placement_name :: proc(data: []u8, layout: D3_Placement_Layout, reference_id: int) -> string {
	at := layout.header_size + reference_id*layout.ref_stride
	name_at := binary_load_i32(data, at)
	end := name_at
	for end < len(data) && data[end] != 0 { end += 1 }
	return string(data[name_at:end])
}

@(test)
placement_layout_detects_both_formats :: proc(t: ^testing.T) {
	trees := make([]u8, 8, context.temp_allocator)
	binary_store_u32(trees, 4, 12)
	l1, ok1 := d3_placement_layout(trees)
	testing.expect(t, ok1)
	testing.expect_value(t, l1.format, D3_Placement_Format.Trees)

	ornaments := make([]u8, 8, context.temp_allocator)
	binary_store_u32(ornaments, 4, 28)
	l2, ok2 := d3_placement_layout(ornaments)
	testing.expect(t, ok2)
	testing.expect_value(t, l2.format, D3_Placement_Format.Ornaments)

	unknown := make([]u8, 8, context.temp_allocator)
	binary_store_u32(unknown, 4, 99)
	_, ok3 := d3_placement_layout(unknown)
	testing.expect(t, !ok3)
}

@(test)
placement_relocate_with_unchanged_instances_is_identity :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)
	layout := D3_TREES_LAYOUT
	instances := make([]D3_Placement_Instance, 3, context.temp_allocator)
	for i in 0 ..< 3 {
		instances[i] = {reference_id = u32(i % 2), basis = D3_BASIS_IDENTITY, position = {f32(i)*10, 1, 0}}
	}
	out, msg, ok := d3_placement_relocate(original, instances, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect(t, slice.equal(out, original))
}

@(test)
placement_relocate_shrinks_and_keeps_references_findable :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)
	layout := D3_TREES_LAYOUT

	// Fewer instances than the original, referencing only "omega" (index 1).
	instances := []D3_Placement_Instance{
		{reference_id = 1, basis = D3_BASIS_IDENTITY, position = {5, 2, 9}},
	}
	out, msg, ok := d3_placement_relocate(original, instances, context.temp_allocator)
	testing.expect(t, ok, msg)

	got, got_ok := d3_placement_layout(out)
	testing.expect(t, got_ok)
	testing.expect_value(t, binary_load_i32(out, got.inst_num_write[0]), 1)
	testing.expect_value(t, binary_load_i32(out, got.inst_num_write[1]), 1)
	testing.expect_value(t, binary_load_i32(out, got.ref_num_at), 2) // references untouched

	testing.expect_value(t, d3_test_placement_name(out, got, 0), "alpha")
	testing.expect_value(t, d3_test_placement_name(out, got, 1), "omega")

	inst_at := binary_load_i32(out, got.inst_table_at)
	testing.expect_value(t, binary_load_i32(out, inst_at), 1) // reference_id
	testing.expect_value(t, binary_load_f32(out, inst_at+44), f32(5))
	testing.expect_value(t, binary_load_f32(out, inst_at+48), f32(2))
	testing.expect_value(t, binary_load_f32(out, inst_at+52), f32(9))
}

@(test)
placement_relocate_grows_and_keeps_references_findable :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)

	instances := make([]D3_Placement_Instance, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		instances[i] = {reference_id = u32(i % 2), basis = D3_BASIS_IDENTITY, position = {f32(i), 0, f32(i)*2}}
	}
	out, msg, ok := d3_placement_relocate(original, instances, context.temp_allocator)
	testing.expect(t, ok, msg)

	got, got_ok := d3_placement_layout(out)
	testing.expect(t, got_ok)
	testing.expect_value(t, binary_load_i32(out, got.inst_num_write[0]), 10)
	testing.expect_value(t, d3_test_placement_name(out, got, 0), "alpha")
	testing.expect_value(t, d3_test_placement_name(out, got, 1), "omega")
}

@(test)
placement_relocate_clears_to_zero_instances :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)
	out, msg, ok := d3_placement_relocate(original, nil, context.temp_allocator)
	testing.expect(t, ok, msg)

	got, got_ok := d3_placement_layout(out)
	testing.expect(t, got_ok)
	testing.expect_value(t, binary_load_i32(out, got.inst_num_write[0]), 0)
	testing.expect_value(t, d3_test_placement_name(out, got, 1), "omega")
}

@(test)
placement_read_recovers_every_encoded_instance :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)
	want := make([]D3_Placement_Instance, 3, context.temp_allocator)
	for i in 0 ..< 3 {
		want[i] = {reference_id = u32(i % 2), basis = D3_BASIS_IDENTITY, position = {f32(i)*10, 1, 0}}
	}

	got, msg, ok := d3_placement_read(original, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< len(want) {
		testing.expect_value(t, got[i].reference_id, want[i].reference_id)
		testing.expect_value(t, got[i].basis, want[i].basis)
		testing.expect_value(t, got[i].position, want[i].position)
	}
}

@(test)
placement_read_round_trips_through_relocate :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)
	want := []D3_Placement_Instance{
		{reference_id = 1, basis = D3_BASIS_IDENTITY, position = {5, 2, 9}},
		{reference_id = 0, basis = D3_BASIS_IDENTITY, position = {-3, 0, 12}},
	}
	relocated, relocate_msg, relocate_ok := d3_placement_relocate(original, want, context.temp_allocator)
	testing.expect(t, relocate_ok, relocate_msg)

	got, msg, ok := d3_placement_read(relocated, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< len(want) {
		testing.expect_value(t, got[i].position, want[i].position)
	}
}

// A rotation, not just a translation: basis swaps X and Z, so a reference box
// that is long on X and thin on Z reads back long on Z and thin on X once the
// instance's own bounds are folded in.
@(test)
placement_instance_box_transforms_local_bounds :: proc(t: ^testing.T) {
	layout := D3_TREES_LAYOUT
	ref_table_at := layout.header_size
	data := make([]u8, ref_table_at+layout.ref_stride, context.temp_allocator)
	binary_store_u32(data, 0x04, 12)
	binary_store_u32(data, layout.ref_num_at, 1)
	binary_store_u32(data, layout.ref_table_at, u32(ref_table_at))

	binary_store_f32(data, ref_table_at+8, -4)  // local bounds_min
	binary_store_f32(data, ref_table_at+12, 0)
	binary_store_f32(data, ref_table_at+16, -1)
	binary_store_f32(data, ref_table_at+20, 4) // local bounds_max
	binary_store_f32(data, ref_table_at+24, 2)
	binary_store_f32(data, ref_table_at+28, 1)

	lo, hi, bounds_ok := d3_placement_reference_bounds(data, layout, 0)
	testing.expect(t, bounds_ok)
	testing.expect_value(t, lo, [3]f32{-4, 0, -1})
	testing.expect_value(t, hi, [3]f32{4, 2, 1})

	rotate_xz := [3][3]f32{{0, 0, 1}, {0, 1, 0}, {1, 0, 0}} // swap local X and Z
	inst := D3_Placement_Instance{reference_id = 0, basis = rotate_xz, position = {100, 10, 100}}
	box_lo, box_hi, box_ok := d3_placement_instance_box(data, layout, inst)
	testing.expect(t, box_ok)
	testing.expect_value(t, box_lo, [3]f32{99, 10, 96})
	testing.expect_value(t, box_hi, [3]f32{101, 12, 104})
}

// A gap between the instance table and the string pool, the way ornaments.bin
// sometimes has one (see `d3_placement_shift_gap`): one word that is a real
// pointer and must shift with everything else, one that only looks like an
// out-of-range offset and must not.
@(test)
placement_relocate_shifts_a_real_pointer_hiding_in_the_gap :: proc(t: ^testing.T) {
	layout := D3_TREES_LAYOUT
	ref_table_at := layout.header_size
	inst_table_at := ref_table_at + layout.ref_stride
	gap_at := inst_table_at + layout.inst_stride
	string_pool_at := gap_at + 8
	name := "solo"

	data := make([]u8, string_pool_at+len(name)+1, context.temp_allocator)
	binary_store_u32(data, 0x04, 12)
	binary_store_u32(data, 0x08, 1)
	binary_store_u32(data, layout.ref_num_at, 1)
	binary_store_u32(data, layout.ref_table_at, u32(ref_table_at))
	binary_store_u32(data, layout.inst_table_at, u32(inst_table_at))
	for i in layout.inst_num_write { binary_store_u32(data, i, 1) }

	binary_store_u32(data, ref_table_at, u32(string_pool_at)) // filename_offset
	binary_store_u32(data, ref_table_at+36, 1)                // max_instances
	copy(data[string_pool_at:], name)

	solo := D3_Placement_Instance{reference_id = 0, basis = D3_BASIS_IDENTITY, position = {0, 0, 0}}
	d3_placement_encode_instance(data, inst_table_at, 0, solo, layout)

	binary_store_u32(data, gap_at, u32(len(data)+1000))    // out of range: not a pointer
	binary_store_u32(data, gap_at+4, u32(string_pool_at))  // a real pointer to "solo"

	instances := make([]D3_Placement_Instance, 4, context.temp_allocator)
	for i in 0 ..< 4 {
		instances[i] = {reference_id = 0, basis = D3_BASIS_IDENTITY, position = {f32(i), 0, 0}}
	}
	out, msg, ok := d3_placement_relocate(data, instances, context.temp_allocator)
	testing.expect(t, ok, msg)

	delta := (4-1) * layout.inst_stride
	new_gap_at := gap_at + delta
	testing.expect_value(t, binary_load_i32(out, new_gap_at), len(data)+1000) // untouched
	testing.expect_value(t, binary_load_i32(out, new_gap_at+4), string_pool_at+delta) // shifted

	got, got_ok := d3_placement_layout(out)
	testing.expect(t, got_ok)
	testing.expect_value(t, d3_test_placement_name(out, got, 0), name)
}
