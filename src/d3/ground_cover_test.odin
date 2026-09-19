package d3

import "core:math"
import "core:strings"
import "core:testing"

// The three tables a writer carries over from the base venue's own file. The
// fixture only has to be structurally right: slot counts, card widths and a
// version, all at the offsets the game's loader hardcodes.
@(private = "file") T_CARD_REC :: 8 * 6 * 4
@(private = "file") T_SCATTER_REC :: 27 * 4
@(private = "file") T_NAME_REC :: 152
@(private = "file") T_CARDS_AT :: 16
@(private = "file") T_SCATTER_AT :: T_CARDS_AT + 8 * T_CARD_REC
@(private = "file") T_NAMES_AT :: T_SCATTER_AT + 8 * T_SCATTER_REC
@(private = "file") T_OFFSETS_AT :: T_NAMES_AT + 8 * T_NAME_REC + 4

gc_test_template :: proc(slots: [8]int, card_w: f32 = 0.8) -> []u8 {
	data := make([]u8, T_OFFSETS_AT, context.temp_allocator)
	binary_store_u32(data, 0, D3_GRS_VERSION)
	binary_store_u32(data, 4, D3_GRS_TYPES)
	binary_store_u32(data, 12, 0)
	for t in 0 ..< 8 {
		binary_store_u32(data, T_NAMES_AT + t*T_NAME_REC + 128, u32(slots[t]))
		for s in 0 ..< slots[t] {
			binary_store_f32(data, T_CARDS_AT + t*T_CARD_REC + s*24, card_w)
		}
		// A step the writer is expected to overwrite.
		binary_store_f32(data, T_SCATTER_AT + t*T_SCATTER_REC, 99)
	}
	return data
}

// A unit square of ground, two triangles, offset so no coordinate is zero.
gc_test_cell :: proc(ox, oz, size: f32, cover: u8) -> D3_Ground_Cell {
	points := make([][3]f32, 4, context.temp_allocator)
	points[0] = {ox, 1, oz}
	points[1] = {ox + size, 3, oz}
	points[2] = {ox + size, 5, oz + size}
	points[3] = {ox, 7, oz + size}
	tris := make([]D3_Ground_Tri, 2, context.temp_allocator)
	tris[0] = {i = {0, 1, 2}, cover = cover}
	tris[1] = {i = {0, 2, 3}, cover = cover}
	return {points = points, tris = tris}
}

// Everything the game's loader reads back out of one cell, so a test asserts
// on fields rather than on a hexdump.
@(private = "file")
Gc_Read_Cell :: struct {
	at:     int,
	lo, hi: [3]f32,
	points: [][3]f32,
	flags:  []u8,
	idx:    [][3]u8,
}

@(private = "file")
gc_read :: proc(t: ^testing.T, data: []u8) -> []Gc_Read_Cell {
	count := int(binary_load_u32(data, 8))
	out := make([]Gc_Read_Cell, count, context.temp_allocator)
	for i in 0 ..< count {
		at := int(binary_load_u32(data, T_OFFSETS_AT + i*4))
		testing.expectf(t, at % 16 == 0, "cell %d starts at %d, not on a 16 byte boundary", i, at)
		c := &out[i]
		c.at = at
		nv := int(binary_load_u16(data, at))
		nt := int(binary_load_u16(data, at+2))
		for k in 0 ..< 12 {
			testing.expectf(t, data[at+4+k] == 0, "cell %d header byte %d is not zero", i, k)
		}
		for axis in 0 ..< 3 {
			c.lo[axis] = binary_load_f32(data, at+16+axis*4)
			c.hi[axis] = binary_load_f32(data, at+28+axis*4)
		}
		c.points = make([][3]f32, nv, context.temp_allocator)
		for v in 0 ..< nv {
			vat := at + 40 + v*8
			qx := f32(binary_load_u16(data, vat))
			qz := f32(binary_load_u16(data, vat+2))
			qy := f32(data[vat+4])
			c.points[v] = {
				c.lo.x + qx/65535 * (c.hi.x - c.lo.x),
				c.lo.y + qy/255 * (c.hi.y - c.lo.y),
				c.lo.z + qz/65535 * (c.hi.z - c.lo.z),
			}
		}
		c.flags = make([]u8, nt, context.temp_allocator)
		c.idx = make([][3]u8, nt, context.temp_allocator)
		for k in 0 ..< nt {
			tat := at + 40 + nv*8 + k*4
			c.idx[k] = {data[tat], data[tat+1], data[tat+2]}
			c.flags[k] = data[tat+3]
		}
	}
	return out
}

@(test)
ground_cover_writes_a_cell_the_loader_can_walk :: proc(t: ^testing.T) {
	template := gc_test_template({4, 6, 6, 5, 4, 4, 3, 4})
	cells := []D3_Ground_Cell{gc_test_cell(100, -200, 20, 3)}
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1.5 }

	out, msg, ok := d3_ground_cover_build(template, cells, step, context.temp_allocator)
	testing.expectf(t, ok, "build failed: %s", msg)

	testing.expect_value(t, binary_load_u32(out, 0), u32(D3_GRS_VERSION))
	testing.expect_value(t, binary_load_u32(out, 4), u32(D3_GRS_TYPES))
	testing.expect_value(t, binary_load_u32(out, 8), u32(1))
	testing.expect_value(t, binary_load_u32(out, 12), u32(0))

	read := gc_read(t, out)
	testing.expect_value(t, len(read), 1)
	c := read[0]
	// The box is the points' own bound, and the quantised corners land back on
	// it exactly.
	testing.expect_value(t, c.lo, [3]f32{100, 1, -200})
	testing.expect_value(t, c.hi, [3]f32{120, 7, -180})
	for want, i in cells[0].points {
		for axis in 0 ..< 3 {
			testing.expectf(
				t, math.abs(c.points[i][axis]-want[axis]) < 0.001,
				"point %d axis %d came back as %v, not %v", i, axis, c.points[i][axis], want[axis],
			)
		}
	}
	// gc_test_cell winds its quad the positive way, which is the way that
	// grows nothing. The writer turns both triangles around.
	testing.expect_value(t, c.idx[0], [3]u8{0, 2, 1})
	testing.expect_value(t, c.idx[1], [3]u8{0, 3, 2})
	// Cover type 3, drawn as B: 0x87 | 3<<3.
	testing.expect_value(t, c.flags[0], u8(0x9f))
	testing.expect_value(t, c.flags[1], u8(0x9f))
	// The whole file is the last cell's end, unpadded.
	testing.expect_value(t, len(out), c.at + 40 + 4*8 + 2*4)
}

@(test)
ground_cover_overwrites_only_the_lattice_step :: proc(t: ^testing.T) {
	slots := [8]int{4, 0, 6, 5, 4, 4, 3, 4}
	template := gc_test_template(slots)
	// A marker in every table the writer must carry over untouched.
	binary_store_f32(template, T_CARDS_AT + 2*T_CARD_REC + 4, 1.25)      // a card height
	binary_store_f32(template, T_SCATTER_AT + 2*T_SCATTER_REC + 4, 0.4)  // the jitter radius
	binary_store_f32(template, T_SCATTER_AT + 2*T_SCATTER_REC + 12, 0.9) // a slot's scale minimum
	copy(template[T_NAMES_AT+2*T_NAME_REC:], "t03_01")

	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = f32(i) + 1 }
	step[4] = 0 // a type we do not grow keeps the donor's own pitch
	out, msg, ok := d3_ground_cover_build(
		template, []D3_Ground_Cell{gc_test_cell(0, 0, 10, 2)}, step, context.temp_allocator,
	)
	testing.expectf(t, ok, "build failed: %s", msg)

	testing.expect_value(t, binary_load_f32(out, T_CARDS_AT + 2*T_CARD_REC + 4), f32(1.25))
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 2*T_SCATTER_REC + 4), f32(0.4))
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 2*T_SCATTER_REC + 12), f32(0.9))
	testing.expect_value(t, string(out[T_NAMES_AT+2*T_NAME_REC:][:6]), "t03_01")
	testing.expect_value(t, binary_load_u32(out, T_NAMES_AT + 2*T_NAME_REC + 128), u32(6))
	// Step written for every type that has cards and a step, left alone for
	// the type with no cards — its whole block is art we do not own — and for
	// the type whose step is zero, which means "not ours to set".
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 2*T_SCATTER_REC), f32(3))
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 0*T_SCATTER_REC), f32(1))
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 1*T_SCATTER_REC), f32(99))
	testing.expect_value(t, binary_load_f32(out, T_SCATTER_AT + 4*T_SCATTER_REC), f32(99))
}

@(test)
ground_cover_pads_between_cells_and_not_after_the_last :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	cells := make([]D3_Ground_Cell, 5, context.temp_allocator)
	for i in 0 ..< 5 { cells[i] = gc_test_cell(f32(i)*40, 0, 20, u8(i)) }
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1.2 }

	out, msg, ok := d3_ground_cover_build(template, cells, step, context.temp_allocator)
	testing.expectf(t, ok, "build failed: %s", msg)
	read := gc_read(t, out)
	testing.expect_value(t, len(read), 5)
	// One cell body is 40 + 4*8 + 2*4 = 80 bytes, already a multiple of 16, so
	// consecutive cells sit exactly 80 apart with no pad in between.
	for i in 1 ..< 5 {
		testing.expect_value(t, read[i].at - read[i-1].at, 80)
	}
	testing.expect_value(t, len(out), read[4].at + 80)
	// And the offset table is the only place a cell's position is recorded.
	first := int(binary_load_u32(out, T_OFFSETS_AT))
	testing.expect_value(t, first % 16, 0)
	testing.expect(t, first >= T_OFFSETS_AT + 5*4)
}

@(test)
ground_cover_boxes_reads_back_what_was_written :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	cells := make([]D3_Ground_Cell, 3, context.temp_allocator)
	for i in 0 ..< 3 { cells[i] = gc_test_cell(f32(i)*25, f32(i)*-13, 20, 0) }
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	out, _, ok := d3_ground_cover_build(template, cells, step, context.temp_allocator)
	testing.expect(t, ok)

	boxes, msg, boxes_ok := d3_ground_cover_boxes(out, context.temp_allocator)
	testing.expectf(t, boxes_ok, "read back failed: %s", msg)
	testing.expect_value(t, len(boxes), 3)
	for i in 0 ..< 3 {
		testing.expect_value(t, boxes[i].lo, [3]f32{f32(i)*25, 1, f32(i)*-13})
		testing.expect_value(t, boxes[i].hi, [3]f32{f32(i)*25 + 20, 7, f32(i)*-13 + 20})
	}
}

@(test)
ground_cover_refuses_a_cell_no_byte_index_can_reach :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	points := make([][3]f32, D3_GRS_CELL_VERTS_MAX+1, context.temp_allocator)
	for i in 0 ..< len(points) { points[i] = {f32(i), 0, 0} }
	tris := make([]D3_Ground_Tri, 1, context.temp_allocator)
	tris[0] = {i = {0, 1, 2}, cover = 0}
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	_, msg, ok := d3_ground_cover_build(
		template, []D3_Ground_Cell{{points = points, tris = tris}}, step, context.temp_allocator,
	)
	testing.expect(t, !ok)
	testing.expectf(t, len(msg) > 0, "a refusal with no reason")
}

@(test)
ground_cover_refuses_a_type_the_art_gives_no_cards :: proc(t: ^testing.T) {
	// Type 5 has no slots, so no triangle may enable it. No stock triangle in
	// the game does: 1337377 of them, zero exceptions.
	template := gc_test_template({4, 4, 4, 4, 4, 0, 4, 4})
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	_, msg, ok := d3_ground_cover_build(
		template, []D3_Ground_Cell{gc_test_cell(0, 0, 10, 5)}, step, context.temp_allocator,
	)
	testing.expect(t, !ok)
	testing.expectf(t, len(msg) > 0, "a refusal with no reason")

	_, _, fine := d3_ground_cover_build(
		template, []D3_Ground_Cell{gc_test_cell(0, 0, 10, 4)}, step, context.temp_allocator,
	)
	testing.expect(t, fine)
}

@(test)
ground_cover_refuses_a_triangle_pointing_off_its_own_cell :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	cell := gc_test_cell(0, 0, 10, 0)
	cell.tris[1].i[2] = 9
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	_, msg, ok := d3_ground_cover_build(template, []D3_Ground_Cell{cell}, step, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expectf(t, len(msg) > 0, "a refusal with no reason")
}

@(test)
ground_cover_boxes_refuses_a_file_the_game_would_reject :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	out, _, ok := d3_ground_cover_build(
		template, []D3_Ground_Cell{gc_test_cell(0, 0, 10, 0)}, step, context.temp_allocator,
	)
	testing.expect(t, ok)

	// The loader tests the version for equality with 7 and loads nothing
	// otherwise; battersea ships a version 5 file the game never reads.
	wrong := make([]u8, len(out), context.temp_allocator)
	copy(wrong, out)
	binary_store_u32(wrong, 0, 5)
	_, _, version_ok := d3_ground_cover_boxes(wrong, context.temp_allocator)
	testing.expect(t, !version_ok)

	_, _, short_ok := d3_ground_cover_boxes(out[:64], context.temp_allocator)
	testing.expect(t, !short_ok)

	lying := make([]u8, len(out), context.temp_allocator)
	copy(lying, out)
	binary_store_u32(lying, 8, 100000)
	_, _, count_ok := d3_ground_cover_boxes(lying, context.temp_allocator)
	testing.expect(t, !count_ok)
}

@(test)
ground_cover_slots_and_card_widths_come_off_the_template :: proc(t: ^testing.T) {
	template := gc_test_template({4, 6, 6, 5, 4, 0, 3, 4}, 1.75)
	slots, slots_ok := d3_ground_cover_slots(template)
	testing.expect(t, slots_ok)
	testing.expect_value(t, slots, [8]int{4, 6, 6, 5, 4, 0, 3, 4})

	width, area, size_ok := d3_ground_cover_card_size(template)
	testing.expect(t, size_ok)
	testing.expect_value(t, width[1], f32(1.75))
	testing.expect_value(t, width[5], f32(0)) // no cards, no width
	testing.expect_value(t, area[5], f32(0))
}


// A positively wound triangle grows nothing at all (see xz_cross): a wrong
// winding loads clean and leaves the venue bare, so this is a gate.
@(test)
ground_cover_winds_every_triangle_the_way_the_scatter_reads :: proc(t: ^testing.T) {
	template := gc_test_template({4, 4, 4, 4, 4, 4, 4, 4})
	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }

	// Four points round a square, and one triangle of each winding over them.
	points := make([][3]f32, 4, context.temp_allocator)
	points[0] = {0, 0, 0}
	points[1] = {10, 0, 0}
	points[2] = {10, 0, 10}
	points[3] = {0, 0, 10}
	tris := make([]D3_Ground_Tri, 2, context.temp_allocator)
	tris[0] = {i = {0, 1, 2}, cover = 0} // positive, needs turning
	tris[1] = {i = {0, 2, 1}, cover = 0} // already negative, left alone
	out, msg, ok := d3_ground_cover_build(
		template, []D3_Ground_Cell{{points = points, tris = tris}}, step, context.temp_allocator,
	)
	testing.expectf(t, ok, "build failed: %s", msg)

	read := gc_read(t, out)
	for tri, k in read[0].idx {
		a := read[0].points[tri[0]]
		b := read[0].points[tri[1]]
		c := read[0].points[tri[2]]
		cross := (b.x-a.x)*(c.z-a.z) - (c.x-a.x)*(b.z-a.z)
		testing.expectf(t, cross < 0, "triangle %d came out wound %v, which grows nothing", k, cross)
	}
	testing.expect_value(t, read[0].idx[0], [3]u8{0, 2, 1})
	testing.expect_value(t, read[0].idx[1], [3]u8{0, 2, 1})
}

// The budget the scatter is solved against is the budget the engine allocates,
// which only holds while this writer and D3_GC_XML_* agree with the file the
// game reads. Finland Rally ships exactly these numbers.
@(test)
ground_cover_xml_is_the_budget_the_solve_assumes :: proc(t: ^testing.T) {
	out, ok := d3_ground_cover_xml(context.temp_allocator)
	testing.expect(t, ok)
	// BinXML, and about the size every stock one is.
	testing.expect_value(t, binary_load_u32(out, 0), u32(0x7252221A))
	testing.expectf(t, len(out) > 300 && len(out) < 600, "%d bytes", len(out))

	text := string(out)
	for want in ([]string{
		"ground_cover", "system", "maxitems", "20000", "zones", "160",
		"mainscene", "draw_distance", "210", "infield_cull", "0.7", "edge_cull", "0.2",
		"rearviewmirror", "75.0", "1.3", "1.0",
	}) {
		testing.expectf(t, strings.contains(text, want), "%q is not in the file the game reads", want)
	}
}
