package d3

// grids.pssg: where the car appears and which way it faces.
//
// Stock grid files hold no art, only a scene of NODEs carrying a TRANSFORM and
// a BOUNDINGBOX, so this one is built outright rather than moved from a donor.
// Node and attribute type ids come from the embedded material template, which
// already carries every type the scene needs.
//
// A donor grid places the car wherever the old route started. That point is
// typically kilometres outside a new route's collision, so the car appears over
// nothing.

import "core:fmt"
import "core:math"
import "core:mem/virtual"

// Every one of the 106 stock grids.pssg files also carries a `grid_service`
// node with 3 slots. That grid is presentational: it is where the car stands in
// the intro and the entrants and tune menus, so it has no required place on the
// route. This writer emits the standing grid alone and has not been driven yet.
// See docs/dirt3-binary-notes.md.
D3_GRID_SLOTS :: 8
D3_GRID_SERVICE_SLOTS :: 3       // every stock grids.pssg carries exactly 3
D3_GRID_SERVICE_SPACING :: f32(3) // metres between service slots, line abreast
D3_GRID_SLOT_LEAD :: f32(7)      // first slot, behind the grid node
D3_GRID_SLOT_PITCH :: f32(11)    // slot to slot, along the centre line
D3_GRID_CLEARANCE :: f32(0.5)    // how far the grid node sits above the road
D3_GRID_SLOT_LIFT :: f32(2)      // how far each slot hovers over the road
D3_GRID_SLOT_HALF_WIDTH :: f32(1.4)
D3_GRID_SLOT_HALF_LENGTH :: f32(2.75)

// The grid parent's +Z axis follows route travel. Vehicle slots below are
// rotated 180 degrees inside this frame because Dirt 3 cars face local -Z.
d3_grid_frame :: proc(s: Route_Station) -> (lateral, tangent: [3]f32) {
	dx, dz := s.right[0]-s.left[0], s.right[2]-s.left[2]
	n := math.sqrt(dx*dx+dz*dz)
	if n < 1e-6 { return {-1,0,0}, {0,0,1} }
	// In D3, left->right is route-forward rotated counter-clockwise.
	return {dx/n, 0, dz/n}, {dz/n, 0, -dx/n}
}

d3_grid_transform_bytes :: proc(lateral, tangent, origin: [3]f32, allocator := context.allocator) -> []u8 {
	out := make([]u8, 64, allocator)
	rows := [4][3]f32{lateral, {0,1,0}, tangent, origin}
	for row, r in rows {
		for k in 0..<3 { binary_store_f32(out, r*16+k*4, row[k], .Big) }
		binary_store_f32(out, r*16+12, r == 3 ? 1 : 0, .Big)
	}
	return out
}

// A slot's transform is relative to the grid node. Both frames are yaw only, so
// projecting onto the grid's own axes is the whole of the conversion.
d3_grid_slot_local :: proc(grid, slot: Route_Station) -> (lateral, tangent, origin: [3]f32) {
	gl, gt := d3_grid_frame(grid)
	sl, st := d3_grid_frame(slot)
	// The grid node already carries the lift, so the slot only needs the ground
	// it stands on relative to the grid's.
	d := [3]f32{slot.centre[0]-grid.centre[0], slot.centre[1]-grid.centre[1], slot.centre[2]-grid.centre[2]}
	project :: proc(v, x, z: [3]f32) -> [3]f32 { return {v[0]*x[0]+v[2]*x[2], v[1], v[0]*z[0]+v[2]*z[2]} }
	slot_origin := project(d,gl,gt)
	slot_origin[1] += D3_GRID_SLOT_LIFT
	// The node axes describe local +X/+Z, but a vehicle's nose is local -Z.
	// Negating both horizontal axes is a 180-degree yaw without changing the
	// slot's already-correct position behind the start.
	return -project(sl,gl,gt), -project(st,gl,gt), slot_origin
}

d3_grids_build :: proc(line: []Route_Station, markers: []Progress_Marker, profile: ^D3_Venue_Profile, allocator := context.allocator) -> (data: []u8, msg: string, ok: bool) {
	if len(line) < 2 { return nil, "Dirt 3 grid needs a route", false }

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return nil, "could not reserve memory for the Dirt 3 grid", false
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	file, read_msg, read_ok := pssg_read(profile.template, scratch)
	if !read_ok { return nil, read_msg, false }
	types := pssg_types(&file, scratch)

	// One road width of lead-in before the start gate, matching stock, where the
	// grid sits short of the line rather than on it.
	start := d3_station_at(line, markers[0].Distance)
	grid := d3_station_at(line, markers[0].Distance-d3_dist(start.left, start.right))

	// The trail runs backwards from the grid, and the route ends there. Squeeze
	// it into the lead-in rather than letting d3_station_at clamp every slot
	// past the start onto the same point.
	lead, pitch := D3_GRID_SLOT_LEAD, D3_GRID_SLOT_PITCH
	if needed := lead+f32(D3_GRID_SLOTS-1)*pitch; needed > grid.distance {
		fit := grid.distance/needed
		lead *= fit; pitch *= fit
	}

	slots := make([dynamic]^Pssg_Node, scratch)
	for i in 0..<D3_GRID_SLOTS {
		station := d3_station_at(line, grid.distance-lead-f32(i)*pitch)
		lateral, tangent, origin := d3_grid_slot_local(grid, station)
		frame, frame_msg, frame_ok := d3_grid_node_frame(&types, lateral, tangent, origin,
			{-D3_GRID_SLOT_HALF_WIDTH, 0, -D3_GRID_SLOT_HALF_LENGTH},
			{D3_GRID_SLOT_HALF_WIDTH, 0, D3_GRID_SLOT_HALF_LENGTH}, scratch)
		if !frame_ok { return nil, frame_msg, false }
		id := fmt.tprintf("slot_%02d", i)
		slot, slot_msg, slot_ok := pssg_make(&types, "NODE",
			[]Pssg_Set{{"stopTraversal",u32(0)},{"nickname",id},{"id",id}}, frame[:], nil, scratch)
		if !slot_ok { return nil, slot_msg, false }
		append(&slots, slot)
	}

	gl, gt := d3_grid_frame(grid)
	origin := [3]f32{grid.centre[0], grid.centre[1]+D3_GRID_CLEARANCE, grid.centre[2]}
	frame, frame_msg, frame_ok := d3_grid_node_frame(&types, gl, gt, origin, {-0.5,-0.5,-0.5}, {0.5,0.5,0.5}, scratch)
	if !frame_ok { return nil, frame_msg, false }
	children := make([dynamic]^Pssg_Node, scratch)
	append(&children, ..frame[:])
	append(&children, ..slots[:])
	// The trailing number is a nickname in stock files, not a key: Moosylvania
	// route_3 ships `route_7`. It tracks our one progress route instead.
	start_node, start_msg, start_ok := pssg_make(&types, "NODE",
		[]Pssg_Set{{"stopTraversal",u32(0)},{"nickname","grid_start_standing_route_0"},{"id","grid_start_standing_route_0"}},
		children[:], nil, scratch)
	if !start_ok { return nil, start_msg, false }

	// Every stock grids.pssg also carries a `grid_service` node with 3 slots:
	// where the AI cars stand for the intro showcase and the entrants/tune
	// menus, distinct from the standing grid above and not on the route at
	// all. Missing it is what leaves those cars with nowhere valid to spawn —
	// co-locating it with the standing grid keeps it on real ground with no
	// route position of its own to invent.
	service_node, service_msg, service_ok := d3_grid_service_node(&types, gl, gt, origin, scratch)
	if !service_ok { return nil, service_msg, false }

	root_frame, root_msg, root_ok := d3_grid_node_frame(&types, {1,0,0}, {0,0,1}, {0,0,0}, {}, {}, scratch)
	if !root_ok { return nil, root_msg, false }
	root_children := make([dynamic]^Pssg_Node, scratch)
	append(&root_children, ..root_frame[:])
	append(&root_children, start_node, service_node)
	scene, scene_msg, scene_ok := pssg_make(&types, "ROOTNODE",
		[]Pssg_Set{{"stopTraversal",u32(0)},{"nickname","Scene Root"},{"id","Scene Root"}},
		root_children[:], nil, scratch)
	if !scene_ok { return nil, scene_msg, false }
	library, library_msg, library_ok := pssg_make(&types, "LIBRARY",
		[]Pssg_Set{{"type","NODE"}}, []^Pssg_Node{scene}, nil, scratch)
	if !library_ok { return nil, library_msg, false }
	database, database_msg, database_ok := pssg_make(&types, "PSSGDATABASE", nil, []^Pssg_Node{library}, nil, scratch)
	if !database_ok { return nil, database_msg, false }

	out := Pssg_File{schema=file.schema, node_names=file.node_names, attr_names=file.attr_names, root=database}
	encoded, wrote := pssg_write(&out, allocator)
	if !wrote { return nil, "could not encode grids.pssg", false }
	heading := math.mod(math.to_degrees(math.atan2(gt[0], gt[2]))+360, 360)
	return encoded, fmt.tprintf("%d slots from (%.2f, %.2f, %.2f), heading %.1f deg",
		D3_GRID_SLOTS, origin[0], origin[1], origin[2], heading), true
}

// The presentational grid: 3 slots line abreast at the standing grid's own
// position, no route position of their own. Real stock files jitter each
// slot's local Y to sit on locally uneven ground; ours is flat, so zero is
// already correct.
d3_grid_service_node :: proc(types: ^Pssg_Types, gl, gt, origin: [3]f32, allocator := context.allocator) -> (node: ^Pssg_Node, msg: string, ok: bool) {
	slots := make([dynamic]^Pssg_Node, allocator)
	for i in 0 ..< D3_GRID_SERVICE_SLOTS {
		offset := (f32(i) - f32(D3_GRID_SERVICE_SLOTS-1)/2) * D3_GRID_SERVICE_SPACING
		frame, frame_msg, frame_ok := d3_grid_node_frame(types, {-1,0,0}, {0,0,-1}, {offset,0,0},
			{-0.5,0,-1}, {0.5,0.0001,1}, allocator)
		if !frame_ok { return nil, frame_msg, false }
		id := fmt.tprintf("slot_%02d_service", i)
		slot, slot_msg, slot_ok := pssg_make(types, "NODE",
			[]Pssg_Set{{"stopTraversal",u32(0)},{"nickname",id},{"id",id}}, frame[:], nil, allocator)
		if !slot_ok { return nil, slot_msg, false }
		append(&slots, slot)
	}
	frame, frame_msg, frame_ok := d3_grid_node_frame(types, gl, gt, origin, {-0.5,-0.5,-0.5}, {0.5,0.5,0.5}, allocator)
	if !frame_ok { return nil, frame_msg, false }
	children := make([dynamic]^Pssg_Node, allocator)
	append(&children, ..frame[:])
	append(&children, ..slots[:])
	return pssg_make(types, "NODE",
		[]Pssg_Set{{"stopTraversal",u32(0)},{"nickname","grid_service_route_0"},{"id","grid_service_route_0"}},
		children[:], nil, allocator)
}

d3_grid_node_frame :: proc(types: ^Pssg_Types, lateral, tangent, origin, lo, hi: [3]f32, allocator := context.allocator) -> (out: [2]^Pssg_Node, msg: string, ok: bool) {
	transform, tmsg, tok := pssg_make(types, "TRANSFORM", nil, nil, d3_grid_transform_bytes(lateral, tangent, origin, allocator), allocator)
	if !tok { return out, tmsg, false }
	box, bmsg, bok := pssg_make(types, "BOUNDINGBOX", nil, nil, pssg_box_bytes(lo, hi, allocator), allocator)
	if !bok { pssg_node_delete(transform, allocator); return out, bmsg, false }
	return {transform, box}, "", true
}

d3_write_grids :: proc(job: ^Export_Job, profile: ^D3_Venue_Profile) -> (msg: string, ok: bool) {
	line := d3_route_stations(job.Route)
	data, detail, built := d3_grids_build(line, job.Markers, profile)
	if !built { return detail, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "grids.pssg", data); !written { return write_msg, false }
	return detail, true
}
