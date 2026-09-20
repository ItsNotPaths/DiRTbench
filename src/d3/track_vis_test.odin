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

// A scatter wide enough that the group tree really splits: one object per cell
// of an 8x2x2 grid, well past D3_VIS_GROUP_LOAD.
@(private = "file")
d3_test_vis_objects :: proc(allocator := context.allocator) -> []D3_Vis_Object {
	out := make([]D3_Vis_Object, VIS_TEST_OBJECTS, allocator)
	for i in 0..<VIS_TEST_OBJECTS {
		x, y, z := f32(i%8)*10, f32((i/8)%2)*10, f32(i/16)*10
		out[i] = {tag = 0, index = u32(i), lo = {x, y, z}, hi = {x+1, y+1, z+1}}
	}
	return out
}

// One record of section 3, read back out of the bytes the writer produced.
@(private = "file")
D3_Test_Vis_Group :: struct { at, index, boxes, next, next_size, depth, branch, bit: int, lo, hi: [3]f32 }

@(private = "file")
d3_test_vis_groups :: proc(raw: []u8, allocator := context.allocator) -> []D3_Test_Vis_Group {
	out := make([dynamic]D3_Test_Vis_Group, allocator)
	at := int(binary_load_u32(raw, 0x1c))
	for {
		g := D3_Test_Vis_Group{
			at        = at,
			index     = int(binary_load_u16(raw, at+28)),
			boxes     = int(binary_load_u16(raw, at+30)),
			next      = int(binary_load_u32(raw, at+32)),
			next_size = int(binary_load_u16(raw, at+36)),
			depth     = int(binary_load_u16(raw, at+38)),
			branch    = int(binary_load_u32(raw, at+44)),
			bit       = int(binary_load_u16(raw, at+12))*8 + int(binary_load_u16(raw, at+14)),
		}
		for k in 0..<3 {
			g.lo[k] = binary_load_f32(raw, at+k*4)
			g.hi[k] = binary_load_f32(raw, at+16+k*4)
		}
		append(&out, g)
		if g.next == 0 { break }
		at = g.next
	}
	return out[:]
}

@(test)
vis_build_is_self_contained_and_indexes_every_object :: proc(t: ^testing.T) {
	objects := d3_test_vis_objects(context.temp_allocator)
	raw, msg, built := d3_vis_build(objects, objects, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	nodes := int(binary_load_u32(raw, 0x04)); leaves := int(binary_load_u32(raw, 0x08))
	testing.expect_value(t, binary_load_u32(raw, 0x00), u32(4))
	testing.expect_value(t, nodes, 2*leaves-1)
	testing.expect_value(t, binary_load_u32(raw, 0x40), u32(VIS_TEST_OBJECTS))
	for tag in 1..<16 { testing.expect_value(t, binary_load_u32(raw, 0x40+tag*4), u32(0)) }

	o2 := int(binary_load_u32(raw, 0x18)); o3 := int(binary_load_u32(raw, 0x1c)); o4 := int(binary_load_u32(raw, 0x2c))
	testing.expect(t, 0x80 < o2 && o2 < o3 && o3 < o4, "the sections do not run in order")

	groups := d3_test_vis_groups(raw, context.temp_allocator)
	testing.expect_value(t, len(groups), int(binary_load_u32(raw, 0x0c)))

	// Every object appears exactly once, wherever the tree put it, and every
	// bit the first cell addresses is set.
	leaf := 0
	for binary_load_u16(raw, int(binary_load_u32(raw, 0x14))+6*leaf) != 0 { leaf += 1 }
	mask, decoded := d3_test_vis_mask(raw, leaf, context.temp_allocator)
	testing.expect(t, decoded, "a cell's mask did not decode"); if !decoded { return }
	seen := make([]bool, VIS_TEST_OBJECTS, context.temp_allocator)
	for group in groups {
		testing.expect(t, mask[group.bit/8]&(u8(1)<<u8(group.bit&7)) != 0)
		for i in 0..<group.boxes {
			box := group.at+48+i*32
			testing.expect_value(t, binary_load_u32(raw, box+12), u32(0))
			id := int(binary_load_u32(raw, box+28))
			testing.expect(t, id < VIS_TEST_OBJECTS && !seen[id], "an object id is missing or repeated")
			seen[id] = true
			bit := group.bit+1+i
			testing.expect(t, mask[bit/8]&(u8(1)<<u8(bit&7)) != 0)
		}
	}
	for ok in seen { testing.expect(t, ok, "an object never reached section 3") }

	testing.expect_value(t, o4, o3+48*len(groups)+32*VIS_TEST_OBJECTS)
	testing.expect_value(t, len(raw), o4+32*nodes)
}

// The reader half of the section-2 coding: token high bit set repeats the next
// byte, clear copies that many. Nothing in the package decodes a track.vis, so
// the test carries its own.
@(private = "file")
d3_test_vis_mask :: proc(raw: []u8, leaf: int, allocator := context.allocator) -> (mask: []u8, ok: bool) {
	size := int(binary_load_u32(raw, 0x10))
	at := int(binary_load_u32(raw, 0x14)) + 6*leaf
	if binary_load_u16(raw, at) != 0 { return nil, false }
	from := int(binary_load_u16(raw, at+2)) | int(binary_load_u16(raw, at+4) & 0xff)<<16
	out := make([dynamic]u8, 0, size, allocator)
	for len(out) < size && from < len(raw) {
		token := raw[from]
		if token & 0x80 != 0 {
			for _ in 0..<int(token & 0x7f) { append(&out, raw[from+1]) }
			from += 2
			continue
		}
		append(&out, ..raw[from+1:from+1+int(token)])
		from += 1+int(token)
	}
	return out[:], len(out) == size
}

@(private = "file")
d3_test_vis_node :: proc(raw: []u8, i: int) -> (a, b, c: u16) {
	at := int(binary_load_u32(raw, 0x14)) + 6*i
	return binary_load_u16(raw, at), binary_load_u16(raw, at+2), binary_load_u16(raw, at+4)
}

@(private = "file")
d3_test_vis_cell :: proc(raw: []u8, i: int) -> (lo, hi: [3]f32) {
	at := int(binary_load_u32(raw, 0x2c)) + 32*i
	for k in 0..<3 {
		lo[k] = binary_load_f32(raw, at+k*4)
		hi[k] = binary_load_f32(raw, at+12+k*4)
	}
	return
}

// Section 1 and section 4 are one subdivision written twice, and the engine
// reads both: the planes to find a camera's cell, the boxes to size it. A
// writer that lets them drift resolves a camera into a cell it is not in.
@(test)
vis_build_cuts_view_cells_over_the_drivable_surface :: proc(t: ^testing.T) {
	objects := d3_test_vis_objects(context.temp_allocator)
	raw, msg, built := d3_vis_build(objects, objects, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	nodes := int(binary_load_u32(raw, 0x04))
	testing.expect(t, nodes > 1, "the cell tree never split")
	root_lo, root_hi := d3_test_vis_cell(raw, 0)
	for k in 0..<3 {
		testing.expect_value(t, root_lo[k], binary_load_f32(raw, 0x20+k*4))
		testing.expect_value(t, root_hi[k], binary_load_f32(raw, 0x30+k*4))
	}

	child_of := make([]int, nodes, context.temp_allocator)
	seen_mask := make(map[int]struct{}, context.temp_allocator)
	volume, root_volume := f64(0), f64(1)
	for k in 0..<3 { root_volume *= f64(root_hi[k]-root_lo[k]) }
	for i in 0..<nodes {
		a, b, c := d3_test_vis_node(raw, i)
		lo, hi := d3_test_vis_cell(raw, i)
		if a == 0 {
			// A leaf names its own mask, coded, inside section 2. Stock gives
			// every leaf a record of its own and so do we.
			at := int(b) | int(c&0xff)<<16
			testing.expect_value(t, int(c)>>8, 1)
			testing.expect(t, at >= int(binary_load_u32(raw, 0x18)) && at < int(binary_load_u32(raw, 0x1c)))
			testing.expect(t, at not_in seen_mask, "two leaves share one mask record")
			seen_mask[at] = {}
			v := f64(1); for k in 0..<3 { v *= f64(hi[k]-lo[k]) }
			volume += v
			continue
		}
		axis := int(a>>13) & 3
		min_child := int(a & 0x1fff)
		max_child := int(b & 0x0fff) | int(a>>15)<<12
		testing.expect_value(t, max_child, min_child-1)
		testing.expect(t, axis < 3 && min_child < nodes, "a node names a child or an axis it does not have")
		if !(axis < 3 && min_child < nodes) { return }
		child_of[min_child] += 1; child_of[max_child] += 1

		plane := root_lo[axis] +
			f32(int(b>>12)<<16 | int(c)) * (root_hi[axis]-root_lo[axis]) / f32(D3_VIS_PLANE_SCALE)
		min_lo, min_hi := d3_test_vis_cell(raw, min_child)
		max_lo, max_hi := d3_test_vis_cell(raw, max_child)
		for k in 0..<3 {
			testing.expect_value(t, min_lo[k], lo[k])
			testing.expect_value(t, max_hi[k], hi[k])
			if k == axis { continue }
			testing.expect_value(t, min_hi[k], hi[k])
			testing.expect_value(t, max_lo[k], lo[k])
		}
		testing.expect_value(t, min_hi[axis], max_lo[axis])
		// The plane is quantized to 20 bits of the root box, so it comes back
		// near the boundary rather than on it.
		testing.expect(t, abs(plane-min_hi[axis]) < 0.01, "the split plane does not decode to the cell boundary")
	}
	testing.expect_value(t, child_of[0], 0)
	for count in child_of[1:] { testing.expect_value(t, count, 1) }
	testing.expect(t, abs(volume/root_volume - 1) < 1e-4, "the cells do not tile the root box")
}

// The mask is the near/far handoff: stock cuts tree models dead past 300 to
// 400 m and lets the billboard clouds carry the distance. Drawing both over the
// same ground is what an all-visible mask does, and the two then fight.
@(test)
vis_build_cuts_what_a_cell_cannot_reach :: proc(t: ^testing.T) {
	// Two stands of trees a kilometre apart, each over its own surface, so a
	// cell at one end can never reach the other.
	far := f32(1000)
	objects := make([dynamic]D3_Vis_Object, context.temp_allocator)
	for end in ([]f32{0, far}) {
		append(&objects, D3_Vis_Object{
			tag = 0, index = u32(len(objects)),
			lo = {end-40, -2, -40}, hi = {end+40, 2, 40},
		})
		for i in 0..<VIS_TEST_OBJECTS {
			x := end + f32(i%8)*4 - 16
			z := f32(i/8)*4 - 16
			append(&objects, D3_Vis_Object{
				tag = 3, index = u32(i), lo = {x, 0, z}, hi = {x+2, 10, z+2},
			})
		}
	}
	band := make([dynamic]D3_Vis_Object, context.temp_allocator)
	for obj in objects { if obj.tag == 0 { append(&band, obj) } }
	raw, msg, built := d3_vis_build(objects[:], band[:], allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	nodes := int(binary_load_u32(raw, 0x04))
	groups := d3_test_vis_groups(raw, context.temp_allocator)
	near_stand, far_stand, both_ends := 0, 0, 0
	for i in 0..<nodes {
		if binary_load_u16(raw, int(binary_load_u32(raw, 0x14))+6*i) != 0 { continue }
		lo, hi := d3_test_vis_cell(raw, i)
		if lo[0] > 40 || hi[0] < -40 { continue } // a cell over the near stand only
		mask, decoded := d3_test_vis_mask(raw, i, context.temp_allocator)
		testing.expect(t, decoded, "a cell's mask did not decode"); if !decoded { return }
		surface := 0
		for group in groups {
			for j in 0..<group.boxes {
				box := group.at+48+j*32
				bit := group.bit+1+j
				on := mask[bit/8]&(u8(1)<<u8(bit&7)) != 0
				if binary_load_u32(raw, box+12) == 0 {
					testing.expect(t, on, "a surface tile was cut, and terrain is never cut")
					surface += 1
					continue
				}
				if binary_load_f32(raw, box) < far/2 { near_stand += int(on) } else { far_stand += int(on) }
			}
		}
		testing.expect_value(t, surface, 2)
		both_ends += 1
	}
	testing.expect(t, both_ends > 0, "no cell landed over the near stand"); if both_ends == 0 { return }
	testing.expect_value(t, near_stand, VIS_TEST_OBJECTS*both_ends)
	testing.expect_value(t, far_stand, 0)
}

// Tag 0 is not the camera band. It also holds the venue LOD and its skirt,
// which reach kilometres past the road; subdividing those spends the whole
// cell budget on ground no camera visits and leaves the cells over the road
// three times too big.
@(test)
vis_build_spends_no_cells_off_the_route :: proc(t: ^testing.T) {
	reach := f32(2000)
	objects := make([dynamic]D3_Vis_Object, context.temp_allocator)
	append(&objects, D3_Vis_Object{ // the venue LOD and its skirt, one huge tile
		tag = 0, index = 0, lo = {-reach, -6, -reach}, hi = {reach, 6, reach},
	})
	band := make([dynamic]D3_Vis_Object, context.temp_allocator)
	for i in 0..<8 {
		tile := D3_Vis_Object{
			tag = 0, index = u32(1+i),
			lo = {f32(i)*40, -2, -20}, hi = {f32(i)*40+40, 2, 20},
		}
		append(&objects, tile); append(&band, tile)
	}
	raw, msg, built := d3_vis_build(objects[:], band[:], allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	off_route := 0
	for i in 0..<int(binary_load_u32(raw, 0x04)) {
		if binary_load_u16(raw, int(binary_load_u32(raw, 0x14))+6*i) != 0 { continue }
		lo, hi := d3_test_vis_cell(raw, i)
		if max(hi[0]-lo[0], hi[2]-lo[2]) > D3_VIS_CELL_SIZE { continue }
		// A cell one split off the band is still small, so the claim is that
		// small cells cluster on the road rather than out in the skirt.
		near := false
		for tile in band {
			gap := max(max(tile.lo[0]-hi[0], lo[0]-tile.hi[0]), max(tile.lo[2]-hi[2], lo[2]-tile.hi[2]))
			if gap <= D3_VIS_CELL_SIZE { near = true }
		}
		if !near { off_route += 1 }
	}
	testing.expect_value(t, off_route, 0)
}

// Nothing to stand on is not an error. A route with no surface of its own gets
// the one cell it had before, not a subdivision of empty air.
@(test)
vis_build_leaves_one_cell_when_no_surface_carries_a_camera :: proc(t: ^testing.T) {
	objects := d3_test_vis_objects(context.temp_allocator)
	for &obj in objects { obj.tag = 3 }
	raw, msg, built := d3_vis_build(objects, nil, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	testing.expect_value(t, binary_load_u32(raw, 0x04), u32(1))
	testing.expect_value(t, binary_load_u32(raw, 0x08), u32(1))
	testing.expect_value(t, binary_load_u16(raw, 128), u16(0))
}

// A mask byte run longer than the coder's 127 cap has to split into several
// tokens. 2000 coincident trees can never be separated by a cut, so one group
// keeps them all as crossers, and a cell a kilometre away codes their bits as
// a zero run of some 250 bytes.
@(test)
vis_build_codes_a_mask_longer_than_one_run :: proc(t: ^testing.T) {
	objects := make([dynamic]D3_Vis_Object, context.temp_allocator)
	append(&objects, D3_Vis_Object{tag = 0, index = 0, lo = {-40, -2, -40}, hi = {40, 2, 40}})
	for i in 0..<2000 {
		append(&objects, D3_Vis_Object{tag = 3, index = u32(i), lo = {1000, 0, 0}, hi = {1002, 10, 2}})
	}
	raw, msg, built := d3_vis_build(objects[:], objects[:1], allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	groups := d3_test_vis_groups(raw, context.temp_allocator)
	checked := 0
	for i in 0..<int(binary_load_u32(raw, 0x04)) {
		if binary_load_u16(raw, int(binary_load_u32(raw, 0x14))+6*i) != 0 { continue }
		_, hi := d3_test_vis_cell(raw, i)
		if hi[0] >= 1000-D3_VIS_REACH { continue } // only cells the trees are out of reach of
		mask, decoded := d3_test_vis_mask(raw, i, context.temp_allocator)
		testing.expect(t, decoded, "a mask with a long run did not decode"); if !decoded { return }
		lit := 0
		for group in groups {
			for j in 0..<group.boxes {
				if binary_load_u32(raw, group.at+48+j*32+12) != 3 { continue }
				bit := group.bit+1+j
				lit += int(mask[bit/8]&(u8(1)<<u8(bit&7)) != 0)
			}
		}
		testing.expect_value(t, lit, 0)
		checked += 1
	}
	testing.expect(t, checked > 0, "no cell landed out of the trees' reach")
}

// A flat list makes the engine box-test every object of every frame. The tree
// is what lets it reject a subtree, and each of these fields is one the engine
// reads rather than derives.
@(test)
vis_build_writes_a_group_tree_the_engine_can_walk :: proc(t: ^testing.T) {
	objects := d3_test_vis_objects(context.temp_allocator)
	raw, msg, built := d3_vis_build(objects, objects, allocator = context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)

	groups := d3_test_vis_groups(raw, context.temp_allocator)
	testing.expect(t, len(groups) > 1, "the tree never split")
	testing.expect(t, len(groups)%2 == 1, "a binary tree holds an odd number of groups")

	bit := 0
	kids := make([]int, len(groups), context.temp_allocator)
	for group, i in groups {
		testing.expect_value(t, group.index, i)
		testing.expect_value(t, group.next, i == len(groups)-1 ? 0 : groups[i+1].at)
		testing.expect_value(t, group.next_size, i == len(groups)-1 ? 0 : 48+32*groups[i+1].boxes)
		// Depth first in the file, breadth first in the bits, which is why the
		// bit run is stated rather than accumulated.
		if i < len(groups)-1 && groups[i+1].depth > group.depth {
			testing.expect_value(t, group.branch, 2)
			testing.expect_value(t, groups[i+1].depth, group.depth+1)
		} else {
			testing.expect_value(t, group.branch, 0)
		}
		for k in 0..<3 { testing.expect(t, group.lo[k] <= group.hi[k]) }
		kids[i] = group.branch == 2 ? 2 : 0
		bit += 1+group.boxes
	}
	testing.expect_value(t, bit, len(groups)+VIS_TEST_OBJECTS)

	// Breadth first over the tree, the stated runs have to come out contiguous
	// and in order. Walk it the same way the reader does.
	order := make([dynamic]int, 0, len(groups), context.temp_allocator)
	append(&order, 0)
	run := 0
	for at := 0; at < len(order); at += 1 {
		i := order[at]
		testing.expect_value(t, groups[i].bit, run)
		run += 1+groups[i].boxes
		if kids[i] == 0 { continue }
		min_child := i+1
		for depth := groups[i+1].depth; min_child < len(groups); min_child += 1 {
			if groups[min_child].depth == depth && min_child != i+1 { break }
		}
		testing.expect(t, min_child < len(groups), "a branch group has one child")
		append(&order, i+1); append(&order, min_child)
	}
	testing.expect_value(t, len(order), len(groups))
	testing.expect_value(t, run, len(groups)+VIS_TEST_OBJECTS)
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

	objects, _, msg, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
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
	_, _, _, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
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
	_, _, _, missing_ok := d3_vis_census_objects(route_dir, venue_dir, true, context.temp_allocator)
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

	objects, _, msg, ok := d3_vis_census_objects(route_dir, venue_dir, true, context.temp_allocator)
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
	testing.expect_value(t, binary_load_u32(raw, 0x40+2*4), u32(291))
	testing.expect(t, binary_load_u32(raw, 0x40) > 0, "the census dropped its own tag-0 tiles")
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

	objects, _, msg, ok := d3_vis_census_objects(route_dir, venue_dir, allocator = context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	got := make([dynamic]u32, context.temp_allocator)
	for obj in objects { if obj.tag == 3 { append(&got, obj.index) } }
	testing.expect_value(t, len(got), len(ids))
	for id, i in ids { testing.expect_value(t, got[i], id) }
}
