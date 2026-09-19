package d3

import "core:os"
import "core:path/filepath"
import "core:testing"

// An object count for the encoder tests. Unrelated to any tile grid.
VIS_TEST_OBJECTS :: 32

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

// A venue directory holding `tracksplit.pssg` and a route directory under it
// holding `routesplit.pssg`, both built by our own tile writer. The census
// reads tile boxes off the files, so it needs real files.
@(private = "file")
d3_test_vis_tree :: proc(t: ^testing.T, venue_tris, route_tris: []Collision_Triangle) -> (route_dir, venue_dir: string, ok: bool) {
	dir, err := os.make_directory_temp("", "dirtbench-vis-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "could not create test directory: %v", err) { return }
	route_dir, _ = filepath.join({dir, "route_0"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(route_dir) == nil) { return }

	for pair in ([]struct{tris: []Collision_Triangle, path: string}{
		{venue_tris, filepath.join({dir, "tracksplit.pssg"}, context.temp_allocator) or_else ""},
		{route_tris, filepath.join({route_dir, "routesplit.pssg"}, context.temp_allocator) or_else ""},
	}) {
		data, msg, built := d3_routesplit_build(pair.tris, d3_test_profile(), context.temp_allocator)
		if !testing.expect(t, built, msg) { return }
		if !testing.expect(t, os.write_entire_file(pair.path, data) == nil) { return }
	}
	return route_dir, dir, true
}

// A two-triangle mesh offset far enough from d3_test_mesh that no box of one
// could be mistaken for a box of the other.
@(private = "file")
d3_test_far_mesh :: proc(allocator := context.allocator) -> []Collision_Triangle {
	out := make([]Collision_Triangle, 2, allocator)
	out[0] = {Points = {{1000, 0, 1000}, {1000, 0, 1010}, {1010, 0, 1000}}, Draw = .Terrain, Surface = .Terrain}
	out[1] = {Points = {{1010, 0, 1010}, {1010, 0, 1000}, {1000, 0, 1010}}, Draw = .Terrain, Surface = .Terrain}
	return out
}

@(test)
vis_build_is_self_contained_and_indexes_every_object :: proc(t: ^testing.T) {
	objects := make([]D3_Vis_Object, VIS_TEST_OBJECTS, context.temp_allocator)
	for i in 0..<VIS_TEST_OBJECTS {
		objects[i] = {tag = 0, index = u32(i), lo = {f32(i), 0, 0}, hi = {f32(i)+1, 1, 1}}
	}
	raw, msg, built := d3_vis_build_single_cell(objects, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	testing.expect_value(t, d3_vis_u32(raw, 0x00), u32(4))
	testing.expect_value(t, d3_vis_u32(raw, 0x04), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x08), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x0c), u32(1))
	testing.expect_value(t, d3_vis_u32(raw, 0x40), u32(VIS_TEST_OBJECTS))
	for tag in 1..<16 { testing.expect_value(t, d3_vis_u32(raw, 0x40+tag*4), u32(0)) }

	o2 := int(d3_vis_u32(raw, 0x18)); o3 := int(d3_vis_u32(raw, 0x1c)); o4 := int(d3_vis_u32(raw, 0x2c))
	testing.expect_value(t, d3_vis_u16(raw, 128), u16(0)) // one leaf, no donor tree
	testing.expect_value(t, int(d3_vis_u16(raw, 130)) | int(d3_vis_u16(raw, 132))<<16, o2)
	testing.expect_value(t, o3-o2, 16)
	for bit in 0..=VIS_TEST_OBJECTS { testing.expect(t, raw[o2+bit/8]&(u8(1)<<u8(bit&7)) != 0) }

	testing.expect_value(t, d3_vis_u16(raw, o3+28), u16(0))
	testing.expect_value(t, d3_vis_u16(raw, o3+30), u16(VIS_TEST_OBJECTS))
	for i in 0..<VIS_TEST_OBJECTS {
		box := o3+48+i*32
		testing.expect_value(t, d3_vis_u32(raw, box+12), u32(0))
		testing.expect_value(t, d3_vis_u32(raw, box+28), u32(i))
	}
	testing.expect_value(t, o4, o3+48+VIS_TEST_OBJECTS*32)
	testing.expect_value(t, len(raw), o4+32)
}

// Two ascending runs, the venue's tiles then the route's, each run reversed on
// its own. Reversing the concatenation as a unit puts the route's boxes on the
// venue's indices.
@(test)
vis_census_numbers_venue_tiles_before_route_tiles :: proc(t: ^testing.T) {
	venue_tris := d3_test_mesh(context.temp_allocator)
	route_tris := d3_test_far_mesh(context.temp_allocator)
	route_dir, venue_dir, made := d3_test_vis_tree(t, venue_tris, route_tris)
	if !made { return }
	defer os.remove_all(venue_dir)

	venue_tiles, _, venue_ok := d3_tile_boxes(venue_tris, d3_test_profile(), context.temp_allocator)
	route_tiles, _, route_ok := d3_tile_boxes(route_tris, d3_test_profile(), context.temp_allocator)
	testing.expect(t, venue_ok && route_ok); if !(venue_ok && route_ok) { return }

	objects, msg, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(objects), len(venue_tiles)+len(route_tiles))

	// d3_tile_boxes already emits reverse traversal order, so the census's own
	// per-source reversal puts tile 0 of the file last within its run.
	for object, i in objects {
		testing.expect_value(t, object.tag, u32(0))
		testing.expect_value(t, object.index, u32(i))
		source := i < len(venue_tiles) ? venue_tiles : route_tiles
		at := i < len(venue_tiles) ? i : i-len(venue_tiles)
		testing.expect_value(t, D3_Tile_Box{object.lo, object.hi}, source[len(source)-1-at])
	}
}

@(test)
vis_census_fails_closed_without_a_tracksplit :: proc(t: ^testing.T) {
	route_dir, venue_dir, made := d3_test_vis_tree(t, d3_test_mesh(context.temp_allocator), d3_test_far_mesh(context.temp_allocator))
	if !made { return }
	defer os.remove_all(venue_dir)
	tracksplit, _ := filepath.join({venue_dir, "tracksplit.pssg"}, context.temp_allocator)
	testing.expect(t, os.remove(tracksplit) == nil)
	_, _, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
	testing.expect(t, !ok, "a census with no venue tracksplit must refuse, not emit route-only indices")
}

// track.vis's tag-1 boxes are grass.grs's cell boxes: same bytes, same order.
@(test)
vis_census_repeats_grass_cells_as_its_tag_1_boxes :: proc(t: ^testing.T) {
	route_dir, venue_dir, made := d3_test_vis_tree(
		t, d3_test_mesh(context.temp_allocator), d3_test_far_mesh(context.temp_allocator),
	)
	if !made { return }
	defer os.remove_all(venue_dir)

	// The flag says this export wrote grass.grs, so a missing file is a refusal.
	_, _, missing_ok := d3_vis_census_objects(route_dir, venue_dir, true, context.temp_allocator)
	testing.expect(t, !missing_ok, "a census told grass.grs exists must refuse when it does not")

	step: [D3_GRS_TYPES]f32
	for i in 0 ..< D3_GRS_TYPES { step[i] = 1 }
	cells := []D3_Ground_Cell{gc_test_cell(2000, 2000, 20, 0), gc_test_cell(2040, 2000, 20, 1)}
	grs, grs_msg, built := d3_ground_cover_build(
		gc_test_template({4, 4, 4, 4, 4, 4, 4, 4}), cells, step, context.temp_allocator,
	)
	testing.expect(t, built, grs_msg); if !built { return }
	grs_path, _ := filepath.join({venue_dir, "grass.grs"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(grs_path, grs) == nil)

	objects, msg, ok := d3_vis_census_objects(route_dir, venue_dir, true, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	boxes, _, boxes_ok := d3_ground_cover_boxes(grs, context.temp_allocator)
	testing.expect(t, boxes_ok)
	got := make([dynamic]D3_Vis_Object, context.temp_allocator)
	for obj in objects { if obj.tag == 1 { append(&got, obj) } }
	testing.expect_value(t, len(got), len(boxes))
	for box, i in boxes {
		testing.expect_value(t, got[i].index, u32(i))
		testing.expect_value(t, got[i].lo, box.lo)
		testing.expect_value(t, got[i].hi, box.hi)
	}
}

// Our derived count for a tag we leave out is zero, and the game sizes an
// allocation from the header count regardless. The file we are replacing is
// the only honest source for that number.
@(test)
vis_census_floors_header_counts_against_the_file_it_replaces :: proc(t: ^testing.T) {
	route_dir, venue_dir, made := d3_test_vis_tree(t, d3_test_mesh(context.temp_allocator), d3_test_far_mesh(context.temp_allocator))
	if !made { return }
	defer os.remove_all(venue_dir)

	donor := make([]u8, D3_VIS_HEADER_SIZE, context.temp_allocator)
	binary_store_u32(donor, 0x40+2*4, 291)
	live, _ := filepath.join({route_dir, "track.vis"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(live, donor) == nil)

	raw, msg, built := d3_vis_census_build(route_dir, venue_dir, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	testing.expect_value(t, d3_vis_u32(raw, 0x40+2*4), u32(291))
	testing.expect(t, d3_vis_u32(raw, 0x40) > 0, "the census dropped its own tag-0 tiles")
}

// Tag-3 ids come from each instance's own id field, not its table position —
// the game joins on the cooked id.
@(test)
vis_census_indexes_trees_by_instance_id :: proc(t: ^testing.T) {
	route_dir, venue_dir, made := d3_test_vis_tree(t, d3_test_mesh(context.temp_allocator), d3_test_far_mesh(context.temp_allocator))
	if !made { return }
	defer os.remove_all(venue_dir)

	trees := d3_test_placement_file(context.temp_allocator)
	layout, layout_ok := d3_placement_layout(trees)
	testing.expect(t, layout_ok); if !layout_ok { return }
	inst_table := int(binary_load_u32(trees, layout.inst_table_at))
	ids := []u32{7, 5, 9}
	for id, i in ids { binary_store_u32(trees, inst_table+i*layout.inst_stride+4, id) }
	trees_path, _ := filepath.join({route_dir, "trees.bin"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(trees_path, trees) == nil)

	objects, msg, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	got := make([dynamic]u32, context.temp_allocator)
	for obj in objects { if obj.tag == 3 { append(&got, obj.index) } }
	testing.expect_value(t, len(got), len(ids))
	for id, i in ids { testing.expect_value(t, got[i], id) }
}
