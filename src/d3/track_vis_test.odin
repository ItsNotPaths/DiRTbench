package d3

import "core:testing"

// A group record (48-byte header, `boxes` 32-byte items) followed
// immediately by the next group at `next_at`, or terminated with a zero
// "next group" offset. Mirrors a real (possibly multi-group) track.vis well
// enough to test d3_vis_read_tag_boxes's chain-following, without needing
// the BSP tree shape section 3 normally has — the reader only ever follows
// the "next group" field, never the tree.
@(private = "file")
D3_Test_Vis_Box :: struct { tag, id: u32, lo, hi: [3]f32 }

@(private = "file")
d3_test_vis_write_group :: proc(data: []u8, at: int, boxes: []D3_Test_Vis_Box, next_at: int) {
	binary_store_u16(data, at+30, u16(len(boxes)))
	binary_store_u32(data, at+32, u32(next_at))
	for box, i in boxes {
		item_at := at + 48 + i*32
		for k in 0 ..< 3 { binary_store_f32(data, item_at+k*4, box.lo[k]) }
		binary_store_u32(data, item_at+12, box.tag)
		for k in 0 ..< 3 { binary_store_f32(data, item_at+16+k*4, box.hi[k]) }
		binary_store_u32(data, item_at+28, box.id)
	}
}

@(test)
vis_read_tag_boxes_follows_the_group_chain_and_filters_by_tag :: proc(t: ^testing.T) {
	section_3 := D3_VIS_HEADER_SIZE
	group_1_size := 48 + 2*32
	group_2_at := section_3 + group_1_size
	group_2_size := 48 + 1*32
	data := make([]u8, group_2_at+group_2_size, context.temp_allocator)
	binary_store_u32(data, 0x1c, u32(section_3))

	d3_test_vis_write_group(data, section_3, []D3_Test_Vis_Box{
		{tag = 2, id = 411, lo = {1, 2, 3}, hi = {4, 5, 6}},
		{tag = 3, id = 900, lo = {0, 0, 0}, hi = {1, 1, 1}}, // different tag, must not appear
	}, group_2_at)
	d3_test_vis_write_group(data, group_2_at, []D3_Test_Vis_Box{
		{tag = 2, id = 588, lo = {7, 8, 9}, hi = {10, 11, 12}},
	}, 0)

	boxes, ok := d3_vis_read_tag_boxes(data, 2, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(boxes), 2)
	testing.expect_value(t, boxes[411], D3_Tile_Box{{1, 2, 3}, {4, 5, 6}})
	testing.expect_value(t, boxes[588], D3_Tile_Box{{7, 8, 9}, {10, 11, 12}})
	_, has_wrong_tag := boxes[900]
	testing.expect(t, !has_wrong_tag)
}

@(test)
vis_read_tag_boxes_fails_closed_on_a_short_file :: proc(t: ^testing.T) {
	_, ok := d3_vis_read_tag_boxes(make([]u8, D3_VIS_HEADER_SIZE-1, context.temp_allocator), 2, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
vis_read_tag_boxes_fails_closed_when_the_group_chain_runs_past_the_file :: proc(t: ^testing.T) {
	section_3 := D3_VIS_HEADER_SIZE
	data := make([]u8, section_3+47, context.temp_allocator) // one byte short of one group header
	binary_store_u32(data, 0x1c, u32(section_3))
	_, ok := d3_vis_read_tag_boxes(data, 2, context.temp_allocator)
	testing.expect(t, !ok)
}

d3_vis_u16 :: proc(data: []u8, at: int) -> u16 { return u16(data[at]) | u16(data[at+1])<<8 }
d3_vis_u32 :: proc(data: []u8, at: int) -> u32 { return u32(data[at]) | u32(data[at+1])<<8 | u32(data[at+2])<<16 | u32(data[at+3])<<24 }
d3_vis_f32 :: proc(data: []u8, at: int) -> f32 { return transmute(f32)d3_vis_u32(data, at) }

@(test)
track_vis_is_self_contained_and_indexes_every_route_tile :: proc(t: ^testing.T) {
	tris := d3_test_mesh(context.temp_allocator)
	raw, msg, built := d3_track_vis_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	testing.expect_value(t, d3_vis_u32(raw, 0x00), u32(4))
	testing.expect_value(t, d3_vis_u32(raw, 0x04), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x08), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x0c), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x40), u32(D3_TILE_MAX))
	for tag in 1..<16 { testing.expect_value(t, d3_vis_u32(raw, 0x40+tag*4), u32(0)) }

	o2 := int(d3_vis_u32(raw, 0x18)); o3 := int(d3_vis_u32(raw, 0x1c)); o4 := int(d3_vis_u32(raw, 0x2c))
	testing.expect_value(t, d3_vis_u16(raw, 128), u16(0)) // one leaf, no donor tree
	testing.expect_value(t, int(d3_vis_u16(raw, 130)) | int(d3_vis_u16(raw, 132))<<16, o2)
	testing.expect_value(t, o3-o2, 16)
	for bit in 0..=D3_TILE_MAX { testing.expect(t, raw[o2+bit/8]&(u8(1)<<u8(bit&7)) != 0) }

	testing.expect_value(t, d3_vis_u16(raw, o3+28), u16(0))
	testing.expect_value(t, d3_vis_u16(raw, o3+30), u16(D3_TILE_MAX))
	for i in 0..<D3_TILE_MAX {
		box := o3+48+i*32
		testing.expect_value(t, d3_vis_u32(raw, box+12), u32(0))
		testing.expect_value(t, d3_vis_u32(raw, box+28), u32(i))
	}
	testing.expect_value(t, o4, o3+48+D3_TILE_MAX*32)
	testing.expect_value(t, len(raw), o4+32)
}

@(test)
track_vis_owns_only_nonempty_tiles_without_donor_slots :: proc(t: ^testing.T) {
	tris := []Collision_Triangle{{Points={{0,0,0},{0,0,1},{1,0,0}}, Material=.Road}}
	raw, msg, built := d3_track_vis_build(tris, d3_test_profile())
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	testing.expect_value(t, d3_vis_u32(raw, 0x40), u32(1))
	o3 := int(d3_vis_u32(raw, 0x1c))
	testing.expect_value(t, d3_vis_u16(raw, o3+30), u16(1))
	testing.expect_value(t, d3_vis_u32(raw, o3+48+28), u32(0))
}

@(test)
track_vis_boxes_match_routesplit_tile_order :: proc(t: ^testing.T) {
	tris := d3_test_mesh(context.temp_allocator)
	vis, vis_msg, vis_ok := d3_track_vis_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, vis_ok, vis_msg); if !vis_ok { return }
	defer delete(vis)
	pssg, pssg_msg, pssg_ok := d3_routesplit_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, pssg_ok, pssg_msg); if !pssg_ok { return }
	defer delete(pssg)
	file, read_msg, read_ok := pssg_read(pssg, context.allocator)
	testing.expect(t, read_ok, read_msg); if !read_ok { return }
	defer pssg_delete(&file)

	surface := pssg_walk_first(file.root, "NODE")
	testing.expect(t, surface != nil); if surface == nil { return }
	o3 := int(d3_vis_u32(vis, 0x1c))
	count := int(d3_vis_u16(vis, o3+30))
	testing.expect_value(t, len(surface.children)-2, count)
	tiles := surface.children[2:]
	for i in 0..<len(tiles) {
		tile := tiles[len(tiles)-1-i]
		lo, hi: [3]f32
		seen := false
		for render in tile.children[2:] {
			box := pssg_walk_first(render, "BOUNDINGBOX")
			if box == nil || len(box.data) != 24 { continue }
			for k in 0..<3 {
				low := d3_test_f32(box.data, k*4); high := d3_test_f32(box.data, 12+k*4)
				if !seen { lo[k] = low; hi[k] = high } else { lo[k] = min(lo[k], low); hi[k] = max(hi[k], high) }
			}
			seen = true
		}
		testing.expect(t, seen); if !seen { continue }
		at := o3+48+i*32
		for k in 0..<3 {
			testing.expect_value(t, d3_vis_f32(vis, at+k*4), lo[k])
			testing.expect_value(t, d3_vis_f32(vis, at+16+k*4), hi[k])
		}
	}
}
