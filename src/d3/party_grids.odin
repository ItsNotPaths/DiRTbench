package d3

import "core:math"

// A party mode's start: the start parent of its stock `grids.pssg`, moved as a
// whole. Its slots are a ring local to the parent, so they follow; the service
// and compound groups are left exactly as stock has them.
//
// A start is named by where the ring stands and which way it faces. The ring
// centre is the mean of the slot origins, and the parent hangs above it by the
// stock drop, so a start read and written back lands where it was.

// The ring centre in world space, and the parent's heading: radians from +Z
// toward +X.
d3_party_start :: proc(data: []u8, parent_id: string) -> (pos: [3]f32, yaw: f32, msg: string, ok: bool) {
	file, read_msg, read_ok := pssg_read(data, context.temp_allocator)
	if !read_ok { return {}, 0, read_msg, false }
	frame, centre, find_msg, found := d3_party_start_frame(&file, parent_id)
	if !found { return {}, 0, find_msg, false }
	pos = frame[3] + centre[0]*frame[0] + centre[1]*frame[1] + centre[2]*frame[2]
	return pos, math.atan2(frame[2][0], frame[2][2]), "", true
}

// `data` with the start parent moved so the ring centre stands at `pos`,
// facing `yaw`. Yaw only, as every stock party start is.
d3_party_start_set :: proc(
	data: []u8, parent_id: string, pos: [3]f32, yaw: f32, allocator := context.allocator,
) -> (out: []u8, msg: string, ok: bool) {
	file, read_msg, read_ok := pssg_read(data, context.temp_allocator)
	if !read_ok { return nil, read_msg, false }
	_, centre, find_msg, found := d3_party_start_frame(&file, parent_id)
	if !found { return nil, find_msg, false }
	s, c := math.sin(yaw), math.cos(yaw)
	x, z := [3]f32{c, 0, -s}, [3]f32{s, 0, c}
	origin := pos - (centre[0]*x + centre[1]*[3]f32{0, 1, 0} + centre[2]*z)
	parent := pssg_walk_first_by_id(&file, file.root, "NODE", parent_id)
	pssg_set_data(d3_party_own_transform(parent), d3_grid_transform_bytes(x, z, origin, context.temp_allocator), context.temp_allocator)
	encoded, wrote := pssg_write(&file, allocator)
	if !wrote { return nil, "could not encode grids.pssg", false }
	return encoded, "", true
}

// The parent's rows (x, y, z axes, origin) and its slots' mean local origin.
@(private = "file")
d3_party_start_frame :: proc(file: ^Pssg_File, parent_id: string) -> (frame: [4][3]f32, centre: [3]f32, msg: string, ok: bool) {
	parent := pssg_walk_first_by_id(file, file.root, "NODE", parent_id)
	if parent == nil { return {}, {}, "the stock grid has no start parent", false }
	frame, ok = d3_party_rows(d3_party_own_transform(parent))
	if !ok { return {}, {}, "the start parent has no transform", false }
	slots := 0
	for child in parent.children {
		if child.name != "NODE" { continue }
		rows, slot_ok := d3_party_rows(d3_party_own_transform(child))
		if !slot_ok { continue }
		centre += rows[3]
		slots += 1
	}
	if slots == 0 { return {}, {}, "the start parent has no slots", false }
	return frame, centre / f32(slots), "", true
}

// A node's own TRANSFORM, not one of its children's.
@(private = "file")
d3_party_own_transform :: proc(node: ^Pssg_Node) -> ^Pssg_Node {
	for child in node.children {
		if child.name == "TRANSFORM" { return child }
	}
	return nil
}

@(private = "file")
d3_party_rows :: proc(transform: ^Pssg_Node) -> (rows: [4][3]f32, ok: bool) {
	if transform == nil || len(transform.data) != 64 { return rows, false }
	for r in 0 ..< 4 {
		for k in 0 ..< 3 {
			rows[r][k] = binary_load_f32(transform.data, r*16 + k*4, .Big)
		}
	}
	return rows, true
}
