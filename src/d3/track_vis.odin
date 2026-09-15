package d3

// Dirt 3 visibility file, single-cell fallback shape: one view cell over
// every object's bounds, one group, every bit set. See
// docs/dirt3-vis-format.md, "The fallback: one view cell, everything
// visible" — no BSP, no PVS. Section 3's boxes still gate visibility on their
// own regardless of the mask, so a correct box and a correct per-tag
// registration index matter even in this shape.

import "core:fmt"

D3_VIS_HEADER_SIZE :: 128

// One drawable the engine can test independently of the mask: its tag, its
// per-tag registration index (not a file position — see the format doc), and
// its world-space box.
D3_Vis_Object :: struct {
	tag:    u32,
	index:  u32,
	lo, hi: [3]f32,
}

d3_vis_object_bounds :: proc(objects: []D3_Vis_Object) -> (lo, hi: [3]f32) {
	lo = objects[0].lo; hi = objects[0].hi
	for obj in objects[1:] {
		for k in 0..<3 { lo[k] = min(lo[k], obj.lo[k]); hi[k] = max(hi[k], obj.hi[k]) }
	}
	return
}

// The sixteen per-tag counts at 0x40..0x7F of any track.vis, stock or ours —
// only the header needs to parse, so this reads far less than a full file.
d3_vis_read_header_tag_counts :: proc(data: []u8) -> (counts: [16]u32, ok: bool) {
	if len(data) < D3_VIS_HEADER_SIZE { return {}, false }
	for tag in 0..<16 { counts[tag] = binary_load_u32(data, 0x40+tag*4) }
	return counts, true
}

@(private = "file")
d3_vis_tag_span :: proc(counts: [16]u32) -> int {
	n := 0
	for c in counts { if c > 0 { n += 1 } }
	return n
}

// Every object of `tag` in a real (possibly multi-group) track.vis, keyed by
// its per-tag id. Section 3 chains every group in the file through its own
// "offset of the next group" field regardless of tree nesting, so following
// that chain visits every object without needing to walk the BSP itself — see
// docs/dirt3-vis-format.md, "Section 3: the objects". Used to borrow a real
// box for an id this codebase can derive independently of `ornaments.bin` —
// see vis_allvisible.odin's objects.ens objects.
d3_vis_read_tag_boxes :: proc(data: []u8, tag: u32, allocator := context.allocator) -> (boxes: map[u32]D3_Tile_Box, ok: bool) {
	if len(data) < D3_VIS_HEADER_SIZE { return nil, false }
	out := make(map[u32]D3_Tile_Box, allocator)
	at := int(binary_load_u32(data, 0x1c))
	for {
		if !binary_range(len(data), at, 48) { delete(out); return nil, false }
		box_count := int(binary_load_u16(data, at+30))
		for i in 0 ..< box_count {
			item_at := at + 48 + i*32
			if !binary_range(len(data), item_at, 32) { delete(out); return nil, false }
			if binary_load_u32(data, item_at+12) != tag { continue }
			id := binary_load_u32(data, item_at+28)
			box: D3_Tile_Box
			for k in 0 ..< 3 { box.lo[k] = binary_load_f32(data, item_at+k*4); box.hi[k] = binary_load_f32(data, item_at+16+k*4) }
			out[id] = box
		}
		next := int(binary_load_u32(data, at+32))
		if next == 0 { break }
		at = next
	}
	return out, true
}

// `header_floor` raises a tag's header count (0x40+tag*4) to at least this
// value even when `objects` holds fewer of that tag. The game reads that
// count to size an allocation it fills from its own independently-built
// per-tag item list, with no bound check against the size — see
// docs/dirt3-vis-format.md, "Header 0x40..0x7F". A floor borrowed from a
// donor file's real count is a safety margin for a tag this codebase cannot
// yet derive a correct count for on its own.
d3_vis_build_single_cell :: proc(objects: []D3_Vis_Object, header_floor := [16]u32{}, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	if len(objects) == 0 { return nil, "Dirt 3 VIS needs at least one object", false }
	if len(objects) > 65535 { return nil, "Dirt 3 VIS has too many objects for one group", false }

	// One group bit followed by one bit for each object. VIS masks are padded
	// to 16 bytes; unused padding bits stay zero.
	object_bits := 1+len(objects)
	mask_bytes, aligned := binary_align_up((object_bits+7)/8, 16)
	if !aligned { return nil, "could not align Dirt 3 VIS mask", false }
	section_1 := D3_VIS_HEADER_SIZE
	section_2 := section_1+16 // one 6-byte leaf record, padded
	section_3 := section_2+mask_bytes // raw one-cell mask
	group_size := 48+len(objects)*32
	section_4 := section_3+group_size
	lo, hi := d3_vis_object_bounds(objects)

	w := binary_writer(allocator)
	defer if !ok { binary_writer_delete(&w) }
	_, reserved := binary_reserve(&w, D3_VIS_HEADER_SIZE)
	if !reserved { return nil, "could not reserve Dirt 3 VIS header", false }

	// Section 1: one raw-mask leaf. Its first u16 is zero, the engine's
	// supported single-view-cell fallback. b/c hold the 24-bit mask offset.
	if section_2 > 0x00ffffff { return nil, "Dirt 3 VIS mask offset exceeds 24 bits", false }
	binary_write_u16(&w, 0)
	binary_write_u16(&w, u16(section_2))
	binary_write_u16(&w, u16(u32(section_2)>>16))
	binary_align(&w, 16)

	// Section 2: every object visible.
	mask_at, mask_ok := binary_reserve(&w, mask_bytes)
	if !mask_ok { return nil, "could not reserve Dirt 3 VIS mask", false }
	for bit in 0..<object_bits { w.data[mask_at+bit/8] |= 1<<u8(bit&7) }

	// Section 3: one leaf group over every object.
	for k in 0..<3 { binary_write_f32(&w, lo[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // group owns bit 0
	for k in 0..<3 { binary_write_f32(&w, hi[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, u16(len(objects)))
	binary_write_u32(&w, 0) // no next group
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // next size, depth
	binary_write_u32(&w, 0); binary_write_u32(&w, 0) // reserved, leaf branch
	tag_counts: [16]u32
	for obj in objects {
		for k in 0..<3 { binary_write_f32(&w, obj.lo[k]) }
		binary_write_u32(&w, obj.tag)
		for k in 0..<3 { binary_write_f32(&w, obj.hi[k]) }
		binary_write_u32(&w, obj.index)
		if obj.tag < 16 { tag_counts[obj.tag] += 1 }
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
	for tag in 0..<16 { binary_patch_u32(&w, 0x40+tag*4, max(tag_counts[tag], header_floor[tag])) }
	if !w.ok { return nil, "could not finalize Dirt 3 VIS header", false }

	out = w.data[:]
	w.data = nil
	return out, fmt.tprintf("1 view cell, %d objects across %d tags", len(objects), d3_vis_tag_span(tag_counts)), true
}

// Export path: owns only the generated route's own tag-0 tiles, no donor
// objects from the rest of a venue.
d3_track_vis_build :: proc(collision: []Collision_Triangle, profile: ^D3_Venue_Profile, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	boxes, box_msg, boxes_ok := d3_tile_boxes(collision, profile, context.temp_allocator)
	if !boxes_ok { return nil, box_msg, false }
	if len(boxes) > 65535 { return nil, "Dirt 3 VIS has too many route tiles", false }

	// Dirt 3 enumerates the PSSG tile nodes in reverse traversal order when it
	// assigns tag-0 visibility indices. Keep the boxes in that engine order;
	// direct surface-child order gives every drawable another tile's bounds.
	objects := make([]D3_Vis_Object, len(boxes), context.temp_allocator)
	for i in 0..<len(boxes) {
		box := boxes[len(boxes)-1-i]
		objects[i] = {tag = 0, index = u32(i), lo = box.lo, hi = box.hi}
	}

	built, build_msg, built_ok := d3_vis_build_single_cell(objects, allocator = allocator)
	if !built_ok { return nil, build_msg, false }
	return built, fmt.tprintf("1 view cell, %d owned route tiles, no donor objects", len(boxes)), true
}

d3_write_track_vis :: proc(job: ^Export_Job, profile: ^D3_Venue_Profile) -> (msg: string, ok: bool) {
	data, detail, built := d3_track_vis_build(job.Collision, profile)
	if !built { return detail, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "track.vis", data); !written { return write_msg, false }
	return detail, true
}
