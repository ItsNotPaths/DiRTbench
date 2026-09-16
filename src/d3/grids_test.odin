package d3

import "core:fmt"
import "core:math"
import "core:testing"

// A right turn, so a straight-line grid would leave the road.
grids_test_line :: proc() -> []Route_Station {
	route := []Route_Sample{
		{Centre={0,2,-100},Left={-4,2,-100},Right={4,2,-100}},
		{Centre={0,2,0},   Left={-4,2,0},   Right={4,2,0}},
		{Centre={100,2,100},Left={96,2,96}, Right={104,2,104}},
	}
	return d3_route_stations(route, context.temp_allocator)
}

grids_test_node :: proc(file: ^Pssg_File, id: string) -> ^Pssg_Node {
	found: ^Pssg_Node
	walk :: proc(file: ^Pssg_File, node: ^Pssg_Node, id: string, found: ^^Pssg_Node) {
		if found^ != nil { return }
		if pssg_attr_string(file, node, "id") == id { found^ = node; return }
		for child in node.children { walk(file, child, id, found) }
	}
	walk(file, file.root, id, &found)
	return found
}

grids_test_transform :: proc(node: ^Pssg_Node) -> (rows: [4][3]f32, ok: bool) {
	transform := pssg_walk_first(node, "TRANSFORM")
	if transform == nil || len(transform.data) != 64 { return rows, false }
	for r in 0..<4 {
		for k in 0..<3 {
			bits, read := pssg_be_u32(transform.data, r*16+k*4)
			if !read { return rows, false }
			rows[r][k] = transmute(f32)bits
		}
	}
	return rows, true
}

@(test)
grids_place_the_start_on_the_route_facing_travel :: proc(t: ^testing.T) {
	line := grids_test_line()
	markers := []Progress_Marker{{.Start,50},{.Checkpoint,140},{.Finish,230}}
	data, msg, ok := d3_grids_build(line, markers, d3_test_profile(), context.temp_allocator)
	testing.expect(t, ok, msg)

	file, read_msg, read_ok := pssg_read(data, context.temp_allocator)
	testing.expect(t, read_ok, read_msg)
	start := grids_test_node(&file, "grid_start_standing_route_0")
	testing.expect(t, start != nil)
	rows, got := grids_test_transform(start)
	testing.expect(t, got)

	// The grid sits one road width short of the start gate, lifted clear.
	station := d3_station_at(line, 50-8)
	testing.expect(t, math.abs(rows[3][0]-station.centre[0]) < 0.01)
	testing.expect(t, math.abs(rows[3][2]-station.centre[2]) < 0.01)
	testing.expect(t, math.abs(rows[3][1]-(station.centre[1]+D3_GRID_CLEARANCE)) < 0.01)
	// This stretch runs along +Z, so local forward is +Z and lateral is +X.
	testing.expect(t, rows[2][2] > 0.99)
	testing.expect(t, rows[0][0] > 0.99)
}

@(test)
grids_slots_trail_the_start_and_follow_the_bend :: proc(t: ^testing.T) {
	line := grids_test_line()
	markers := []Progress_Marker{{.Start,120},{.Checkpoint,170},{.Finish,220}}
	data, msg, ok := d3_grids_build(line, markers, d3_test_profile(), context.temp_allocator)
	testing.expect(t, ok, msg)
	file, read_msg, read_ok := pssg_read(data, context.temp_allocator)
	testing.expect(t, read_ok, read_msg)

	previous := f32(0)
	for i in 0..<D3_GRID_SLOTS {
		slot := grids_test_node(&file, fmt.tprintf("slot_%02d", i))
		testing.expect(t, slot != nil)
		rows, got := grids_test_transform(slot)
		testing.expect(t, got)
		// Local +Z is forward, so every slot sits behind the grid node and they
		// march away from it in order.
		testing.expect(t, rows[3][2] < 0)
		if i > 0 { testing.expect(t, rows[3][2] < previous) }
		previous = rows[3][2]
		// Slots ride the road, so a bend turns them off the grid's own heading.
		length := math.sqrt(rows[2][0]*rows[2][0]+rows[2][2]*rows[2][2])
		testing.expect(t, math.abs(length-1) < 0.01)
	}
	turned := false
	for i in 0..<D3_GRID_SLOTS {
		rows, _ := grids_test_transform(grids_test_node(&file, fmt.tprintf("slot_%02d", i)))
		if math.abs(rows[3][0]) > 0.5 { turned = true }
	}
	testing.expect(t, turned, "a curved route should push its rear slots off the grid's axis")
	// Stations past the bend start (distance 100) aside, neighbours on the
	// straight march at exactly the slot pitch.
	origins := make([][3]f32, D3_GRID_SLOTS, context.temp_allocator)
	for i in 0..<D3_GRID_SLOTS {
		rows, _ := grids_test_transform(grids_test_node(&file, fmt.tprintf("slot_%02d", i)))
		origins[i] = rows[3]
	}
	for i in 2..<D3_GRID_SLOTS {
		dx, dy, dz := origins[i][0]-origins[i-1][0], origins[i][1]-origins[i-1][1], origins[i][2]-origins[i-1][2]
		testing.expect(t, math.abs(math.sqrt(dx*dx+dy*dy+dz*dz)-D3_GRID_SLOT_PITCH) < 0.5)
		testing.expect(t, math.abs(origins[i][1]-D3_GRID_SLOT_LIFT) < 0.01)
	}
}
