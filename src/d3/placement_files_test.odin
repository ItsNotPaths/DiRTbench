package d3

import "core:slice"
import "core:strings"
import "core:testing"

// A minimal, hand-built trees.bin-shaped file: 2 references ("alpha",
// "omega"), 3 instances. Not real game bytes — this tests that the
// relocate transform's bookkeeping (offsets, counts, pointer shifts) is
// internally consistent.
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
	instances := make([]D3_Placement_Instance, 3, context.temp_allocator)
	for i in 0 ..< 3 {
		instances[i] = {reference_id = u32(i % 2), instance_id=u32(i), instance_tag=u32(i+1), basis = D3_BASIS_IDENTITY, position = {f32(i)*10, 1, 0}}
	}
	out, msg, ok := d3_placement_relocate(original, instances, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect(t, slice.equal(out, original))
}

@(test)
placement_relocate_shrinks_and_keeps_references_findable :: proc(t: ^testing.T) {
	original := d3_test_placement_file(context.temp_allocator)

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
		want[i] = {reference_id = u32(i % 2), instance_id=u32(i), instance_tag=u32(i+1), basis = D3_BASIS_IDENTITY, position = {f32(i)*10, 1, 0}}
	}

	got, msg, ok := d3_placement_read(original, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< len(want) {
		testing.expect_value(t, got[i].reference_id, want[i].reference_id)
		testing.expect_value(t, got[i].instance_id, want[i].instance_id)
		testing.expect_value(t, got[i].instance_tag, want[i].instance_tag)
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

@(test)
placement_builds_donor_free_tree_bin_and_xml :: proc(t: ^testing.T) {
	refs := []D3_Placement_Reference{{
		reference_id=0, filename="fir", bounds_min={-2,0,-1}, bounds_max={2,10,1},
	}}
	instances := []D3_Placement_Instance{
		{reference_id=0, instance_id=40, instance_tag=9001, basis=D3_BASIS_IDENTITY, position={10,2,30}},
		{reference_id=0, instance_id=41, instance_tag=9002, basis={{0,0,-1},{0,1,0},{1,0,0}}, position={20,3,40}},
	}
	data, msg, ok := d3_placement_build(.Trees, refs, instances, context.temp_allocator)
	testing.expect(t, ok, msg)
	layout, layout_ok := d3_placement_layout(data)
	testing.expect(t, layout_ok)
	testing.expect_value(t, layout.format, D3_Placement_Format.Trees)
	testing.expect_value(t, binary_load_i32(data, 0x24), 1)
	testing.expect_value(t, binary_load_i32(data, 0x28), 2)
	testing.expect_value(t, binary_load_i32(data, 0x30), 0x40)
	testing.expect_value(t, binary_load_i32(data, 0x38), 0x40+40)

	ref_at := binary_load_i32(data, 0x30)
	testing.expect_value(t, d3_test_placement_name(data, layout, 0), "fir")
	testing.expect_value(t, binary_load_i32(data, ref_at+36), 2)
	inst_at := binary_load_i32(data, 0x38)
	testing.expect_value(t, binary_load_i32(data, inst_at+4), 40)
	testing.expect_value(t, binary_load_i32(data, inst_at+72), 9001)
	testing.expect_value(t, binary_load_i32(data, inst_at+76+4), 41)
	testing.expect_value(t, binary_load_i32(data, inst_at+76+72), 9002)
	testing.expect_value(t, binary_load_f32(data, 0x0c), f32(8))
	testing.expect_value(t, binary_load_f32(data, 0x18), f32(21))

	xml, xml_msg, xml_ok := d3_placement_xml_build(.Trees, refs, instances, context.temp_allocator)
	testing.expect(t, xml_ok, xml_msg)
	text := string(xml)
	testing.expect(t, strings.contains(text, `reference_num="1" instance_num="2"`))
	testing.expect(t, strings.contains(text, `instance_tag="9001" instance_id="40" reference_id="0" shadow_factor="1"`))
}

@(test)
placement_builds_minimal_ornament_auxiliary_tables :: proc(t: ^testing.T) {
	refs := []D3_Placement_Reference{{
		reference_id=0, filename="rural_house_yellow_a",
		bounds_min={-4.314604,-0.9315009,-4.149647}, bounds_max={3.78497219,6.766279,4.35014439},
	}}
	instances := []D3_Placement_Instance{
		{reference_id=0, instance_id=700, instance_tag=800, basis=D3_BASIS_IDENTITY, position={25,0,110}},
		{reference_id=0, instance_id=701, instance_tag=801, basis=D3_BASIS_IDENTITY, position={25,8,110}},
		{reference_id=0, instance_id=702, instance_tag=802, basis=D3_BASIS_IDENTITY, position={25,16,110}},
	}
	data, msg, ok := d3_placement_build(.Ornaments, refs, instances, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect_value(t, binary_load_i32(data, 0x0c), 0x50)
	testing.expect_value(t, binary_load_i32(data, 0x14), 0x68)
	testing.expect_value(t, binary_load_i32(data, 0x34), 1)
	testing.expect_value(t, binary_load_i32(data, 0x38), 3)
	testing.expect_value(t, binary_load_i32(data, 0x40), 0x74)
	testing.expect_value(t, binary_load_i32(data, 0x48), 0x74+48)
	testing.expect_value(t, binary_load_i32(data, 0x4c), 3)
	strings_at := 0x74+48+3*88
	testing.expect_value(t, binary_load_i32(data, 0x50), 0)
	testing.expect_value(t, binary_load_i32(data, 0x54), 0)
	testing.expect_value(t, binary_load_i32(data, 0x58), strings_at)
	testing.expect_value(t, binary_load_i32(data, 0x60), strings_at)
	testing.expect_value(t, binary_load_i32(data, 0x68), 0)
	testing.expect_value(t, binary_load_i32(data, 0x6c), strings_at)

	inst_at := binary_load_i32(data, 0x48)
	testing.expect_value(t, binary_load_i32(data, inst_at+4), 700)
	testing.expect_value(t, binary_load_i32(data, inst_at+76), 800)
	testing.expect_value(t, binary_load_i32(data, inst_at+80), -1)
	testing.expect_value(t, binary_load_i32(data, inst_at+84), -1)

	xml, xml_msg, xml_ok := d3_placement_xml_build(.Ornaments, refs, instances, context.temp_allocator)
	testing.expect(t, xml_ok, xml_msg)
	text := string(xml)
	testing.expect(t, strings.contains(text, `filename="rural_house_yellow_a"`))
	testing.expect(t, strings.contains(text, `instance_tag="802" instance_id="702" reference_id="0"`))
	testing.expect(t, strings.contains(text, `<dependentlist reference_num="0" instance_num="0" />`))
}

@(test)
placement_ornament_references_can_reserve_ens_drawable_ids :: proc(t: ^testing.T) {
	refs := []D3_Placement_Reference{
		{reference_id=0, filename="house", bounds_min={-1,-1,-1}, bounds_max={1,1,1}, instance_capacity=3},
		{reference_id=1, filename="hay", bounds_min={-1,-1,-1}, bounds_max={1,1,1}, instance_capacity=5},
	}
	instances := []D3_Placement_Instance{
		{reference_id=0, instance_id=0, instance_tag=1, basis=D3_BASIS_IDENTITY},
		{reference_id=0, instance_id=1, instance_tag=2, basis=D3_BASIS_IDENTITY},
		{reference_id=0, instance_id=2, instance_tag=3, basis=D3_BASIS_IDENTITY},
	}
	data, msg, ok := d3_placement_build(.Ornaments, refs, instances, context.temp_allocator)
	testing.expect(t, ok, msg)
	testing.expect_value(t, binary_load_u32(data, 0x38), u32(8)) // exported tag-2 capacity
	testing.expect_value(t, binary_load_u32(data, 0x4c), u32(3)) // cooked ornament records
	ref_at := int(binary_load_u32(data, 0x40))
	testing.expect_value(t, binary_load_u32(data, ref_at+40), u32(3))
	testing.expect_value(t, binary_load_u32(data, ref_at+48+40), u32(5))

	xml, xml_msg, xml_ok := d3_placement_xml_build(.Ornaments, refs, instances, context.temp_allocator)
	testing.expect(t, xml_ok, xml_msg)
	text := string(xml)
	testing.expect(t, strings.contains(text, `reference_num="2" instance_num="8"`))
	testing.expect(t, strings.contains(text, `filename="hay" prebaked_shadows="0" bounds_min="-1 -1 -1 " bounds_max="1 1 1 " max_instances="5"`))

	refs[0].instance_capacity = 2
	_, error_msg, rejected := d3_placement_build(.Ornaments, refs, instances, context.temp_allocator)
	testing.expect(t, !rejected)
	testing.expect(t, strings.contains(error_msg, "capacity cannot be smaller"))
}

@(test)
placement_build_rejects_ungrouped_instances :: proc(t: ^testing.T) {
	refs := []D3_Placement_Reference{
		{reference_id=0, filename="a", bounds_max={1,1,1}},
		{reference_id=1, filename="b", bounds_max={1,1,1}},
	}
	instances := []D3_Placement_Instance{
		{reference_id=1, basis=D3_BASIS_IDENTITY},
		{reference_id=0, basis=D3_BASIS_IDENTITY},
	}
	_, _, ok := d3_placement_build(.Trees, refs, instances, context.temp_allocator)
	testing.expect(t, !ok)
}
