package d3

// Minimal Dirt 3 visibility file owning only the generated route tiles.
// One view cell sees the whole stage; a spatial PVS can replace it later.

import "core:fmt"

D3_VIS_HEADER_SIZE :: 128

d3_vis_bounds :: proc(boxes: []D3_Tile_Box) -> (lo, hi: [3]f32) {
	lo = boxes[0].lo; hi = boxes[0].hi
	for box in boxes[1:] {
		for k in 0..<3 { lo[k] = min(lo[k], box.lo[k]); hi[k] = max(hi[k], box.hi[k]) }
	}
	return
}

d3_track_vis_build :: proc(collision: []Collision_Triangle, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	profile, profile_msg, profile_ok := d3_profile_builtin()
	if !profile_ok { return nil, profile_msg, false }
	boxes, box_msg, boxes_ok := d3_tile_boxes(collision, &profile, context.temp_allocator)
	if !boxes_ok { return nil, box_msg, false }
	if len(boxes) > 65535 { return nil, "Dirt 3 VIS has too many route tiles", false }

	// One group bit followed by one bit for each tile. VIS masks are padded to
	// 16 bytes; unused padding bits stay zero.
	object_bits := 1+len(boxes)
	mask_bytes, aligned := binary_align_up((object_bits+7)/8, 16)
	if !aligned { return nil, "could not align Dirt 3 VIS mask", false }
	section_1 := D3_VIS_HEADER_SIZE
	section_2 := section_1+16 // one 6-byte leaf record, padded
	section_3 := section_2+mask_bytes // raw one-cell mask
	group_size := 48+len(boxes)*32
	section_4 := section_3+group_size
	lo, hi := d3_vis_bounds(boxes)

	w := binary_writer(allocator)
	defer if !ok { binary_writer_delete(&w) }
	header, reserved := binary_reserve(&w, D3_VIS_HEADER_SIZE)
	if !reserved { return nil, "could not reserve Dirt 3 VIS header", false }
	_ = header

	// Section 1: one raw-mask leaf. Its first u16 is zero, the engine's
	// supported single-view-cell fallback. b/c hold the 24-bit mask offset.
	if section_2 > 0x00ffffff { return nil, "Dirt 3 VIS mask offset exceeds 24 bits", false }
	binary_write_u16(&w, 0)
	binary_write_u16(&w, u16(section_2))
	binary_write_u16(&w, u16(u32(section_2)>>16))
	binary_align(&w, 16)

	// Section 2: every object in the bounded, route-owned set is visible.
	mask_at, mask_ok := binary_reserve(&w, mask_bytes)
	if !mask_ok { return nil, "could not reserve Dirt 3 VIS mask", false }
	for bit in 0..<object_bits { w.data[mask_at+bit/8] |= 1<<u8(bit&7) }

	// Section 3: one leaf group over every tag-0 route tile.
	for k in 0..<3 { binary_write_f32(&w, lo[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // group owns bit 0
	for k in 0..<3 { binary_write_f32(&w, hi[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, u16(len(boxes)))
	binary_write_u32(&w, 0) // no next group
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // next size, depth
	binary_write_u32(&w, 0); binary_write_u32(&w, 0) // reserved, leaf branch
	// Dirt 3 enumerates the PSSG tile nodes in reverse traversal order when it
	// assigns tag-0 visibility indices.  Keep the boxes in that engine order;
	// direct surface-child order gives every drawable another tile's bounds.
	for i in 0..<len(boxes) {
		box := boxes[len(boxes)-1-i]
		for k in 0..<3 { binary_write_f32(&w, box.lo[k]) }
		binary_write_u32(&w, 0) // tag 0: track block
		for k in 0..<3 { binary_write_f32(&w, box.hi[k]) }
		// TODO: the engine reads this as a per-tag drawable index in registration
		// order, not a file position. Inside a populated venue the route's
		// surfaces start after the venue's, at lead 38 on Moosylvania, so `i`
		// names the venue's terrain instead. See docs/dirt3-binary-notes.md.
		binary_write_u32(&w, u32(i))
	}

	// Section 4: the one view-cell node bound, with no occluder hull.
	for k in 0..<3 { binary_write_f32(&w, lo[k]) }
	for k in 0..<3 { binary_write_f32(&w, hi[k]) }
	binary_write_u32(&w, 0); binary_write_u32(&w, 0)
	if !w.ok || len(w.data) != section_4+32 { return nil, "could not encode Dirt 3 VIS sections", false }

	// Header.
	binary_patch_u32(&w, 0x00, 4)
	binary_patch_u32(&w, 0x04, 1); binary_patch_u32(&w, 0x08, 1)
	binary_patch_u32(&w, 0x0c, 1); binary_patch_u32(&w, 0x10, u32(mask_bytes))
	binary_patch_u32(&w, 0x14, u32(section_1)); binary_patch_u32(&w, 0x18, u32(section_2))
	binary_patch_u32(&w, 0x1c, u32(section_3)); binary_patch_u32(&w, 0x2c, u32(section_4))
	for k in 0..<3 { binary_patch_f32(&w, 0x20+k*4, lo[k]); binary_patch_f32(&w, 0x30+k*4, hi[k]) }
	binary_patch_u32(&w, 0x40, u32(len(boxes))) // tag-0 count; other tags remain zero
	if !w.ok { return nil, "could not finalize Dirt 3 VIS header", false }

	out = w.data[:]
	w.data = nil
	return out, fmt.tprintf("1 view cell, %d owned route tiles, no donor objects", len(boxes)), true
}

d3_write_track_vis :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	data, detail, built := d3_track_vis_build(job.Collision)
	if !built { return detail, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "track.vis", data); !written { return write_msg, false }
	return detail, true
}
