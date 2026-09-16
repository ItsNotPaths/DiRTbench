package d3

// Visual geometry for a stage, synthesized from the collision mesh.
//
// The embedded material pack supplies the schema, the two shader libraries and
// every attribute id. The scene, the draw calls and the vertex buffers are
// ours. The shape is the one the stock route files use:
//
//   ROOTNODE > surface > ROOT_<x>_<z> > four RENDERNODEs
//
//   HIGHBATCH_<x>_<z>  batch shader, stride 12, position only
//   HIGH_<x>_<z>       one draw call per material, stride 28
//   LOWBATCH_<x>_<z>   batch shader, stride 12
//   LOW_<x>_<z>        lod shader, stride 16
//
// Tile bounds live on the RENDERNODEs. Every other NODE gets a zero box and an
// identity transform, which is what the stock files do. The LOW pair carries the
// same triangles as the HIGH pair: a collision mesh has no cheap decimation.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"

// No stock render node has a box that is flat on any axis, and a flat one draws
// nothing at all. Keep every axis at least this thick, centred on the extent.
D3_MIN_EXTENT :: 0.1
// One draw call is indexed by ushort, so it holds at most this many vertices.
D3_WELD_MAX :: 65536
D3_TILE_MAX :: 32

D3_Tile_Box :: struct { lo, hi: [3]f32 }

D3_Layer_Role :: enum {
	Batch,
	Lod,
	Surface,
}

D3_Layer :: struct {
	prefix: string,
	stride: u32,
	role:   D3_Layer_Role,
}

D3_LAYERS := [?]D3_Layer{
	{"HIGHBATCH", 12, .Batch},
	{"HIGH", 28, .Surface},
	{"LOWBATCH", 12, .Batch},
	{"LOW", 16, .Lod},
}

D3_Stream :: struct {
	render_type: string,
	data_type:   string,
	offset:      u32,
}

d3_streams_12 := [?]D3_Stream{{"Vertex", "float3", 0}}
d3_streams_16 := [?]D3_Stream{{"Vertex", "float3", 0}, {"ST", "half2", 12}}
d3_streams_28 := [?]D3_Stream{
	{"Vertex", "float3", 0},
	{"Color", "uint_color_argb", 12},
	{"ST", "half2", 16},
	{"Normal", "half4", 20},
}

// Byte offsets inside one vertex, -1 when the layout has no room for the field.
// The normal is three halves plus a w of 1.
D3_Vertex_Layout :: struct {
	stride:  int,
	colour:  int,
	uv:      int,
	normal:  int,
	streams: []D3_Stream,
}

d3_vertex_layout :: proc(stride: u32) -> (D3_Vertex_Layout, bool) {
	switch stride {
	case 12: return {stride=12, colour=-1, uv=-1, normal=-1, streams=d3_streams_12[:]}, true
	case 16: return {stride=16, colour=-1, uv=12, normal=-1, streams=d3_streams_16[:]}, true
	case 28: return {stride=28, colour=12, uv=16, normal=20, streams=d3_streams_28[:]}, true
	}
	return {}, false
}

d3_half :: proc(v: f32) -> u16 { return transmute(u16)f16(v) }

d3_triangle_normal :: proc(tri: Collision_Triangle) -> [3]f32 {
	u := tri.Points[1]-tri.Points[0]
	v := tri.Points[2]-tri.Points[0]
	n := [3]f32{u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]}
	length := math.sqrt(n[0]*n[0]+n[1]*n[1]+n[2]*n[2])
	if length <= 0 { return {0, 1, 0} }
	return n/length
}

d3_bounds :: proc(points: [][3]f32) -> (lo, hi: [3]f32) {
	lo = points[0]; hi = lo
	for p in points {
		for k in 0..<3 { lo[k] = min(lo[k], p[k]); hi[k] = max(hi[k], p[k]) }
	}
	for k in 0..<3 {
		if hi[k]-lo[k] < D3_MIN_EXTENT {
			middle := (lo[k]+hi[k])/2
			lo[k] = middle-D3_MIN_EXTENT/2; hi[k] = middle+D3_MIN_EXTENT/2
		}
	}
	return
}

// Corners at the same position become one vertex, and its normal is the sum of
// the faces that meet there. A draw call is indexed by ushort, so a crowded
// group is welded into several.
D3_Weld :: struct {
	index:  map[[3]f32]u16,
	points: [dynamic][3]f32,
	normal: [dynamic][3]f32,
	tris:   [dynamic][3]u16,
}

d3_weld :: proc(allocator: mem.Allocator) -> D3_Weld {
	return {
		index = make(map[[3]f32]u16, allocator),
		points = make([dynamic][3]f32, allocator),
		normal = make([dynamic][3]f32, allocator),
		tris = make([dynamic][3]u16, allocator),
	}
}

d3_weld_add :: proc(w: ^D3_Weld, tri: Collision_Triangle) {
	face := d3_triangle_normal(tri)
	corner: [3]u16
	for p, k in tri.Points {
		index, seen := w.index[p]
		if !seen {
			index = u16(len(w.points))
			w.index[p] = index
			append(&w.points, p)
			append(&w.normal, [3]f32{})
		}
		w.normal[index] += face
		corner[k] = index
	}
	append(&w.tris, corner)
}

// Dirt 3's terrain shaders consume tile-local normalized atlas coordinates.
// Stock Finland tiles span roughly 426 x 197 metres while their ST values stay
// in 0..1. Measuring in metres (the old /16 rule) emitted values as large as
// 26 x 12 for those same tiles, wrapping/clamping the atlas into coarse grass.
d3_pack_vertices :: proc(
	w: ^D3_Weld,
	layout: D3_Vertex_Layout,
	origin, pitch: [2]f32,
	colour: [4]u8,
	allocator: mem.Allocator,
) -> []u8 {
	data := make([]u8, len(w.points)*layout.stride, allocator)
	rgba := colour
	for p, i in w.points {
		base := i*layout.stride
		for k in 0..<3 { binary_store_f32(data, base+k*4, p[k], .Big) }
		if layout.colour >= 0 { copy(data[base+layout.colour:][:4], rgba[:]) }
		if layout.uv >= 0 {
			binary_store_u16(data, base+layout.uv, d3_half((p[0]-origin[0])/pitch[0]), .Big)
			binary_store_u16(data, base+layout.uv+2, d3_half((p[2]-origin[1])/pitch[1]), .Big)
		}
		if layout.normal >= 0 {
			n := w.normal[i]
			length := math.sqrt(n[0]*n[0]+n[1]*n[1]+n[2]*n[2])
			n = length > 0 ? n/length : [3]f32{0, 1, 0}
			for k in 0..<3 { binary_store_u16(data, base+layout.normal+k*2, d3_half(n[k]), .Big) }
			binary_store_u16(data, base+layout.normal+6, d3_half(1), .Big)
		}
	}
	return data
}

d3_pack_indices :: proc(w: ^D3_Weld, allocator: mem.Allocator) -> []u8 {
	data := make([]u8, len(w.tris)*6, allocator)
	for tri, i in w.tris {
		for k in 0..<3 { binary_store_u16(data, i*6+k*2, tri[k], .Big) }
	}
	return data
}

// A poisoned builder stops making nodes and keeps the first message, the way
// Binary_Writer does, so the assembly below reads as a list of nodes.
D3_Build :: struct {
	file:      ^Pssg_File,
	types:     ^Pssg_Types,
	ids:       ^Pssg_Ids,
	profile:   ^D3_Venue_Profile,
	tris:      []Collision_Triangle,
	blocks:    [dynamic]^Pssg_Node,
	segments:  [dynamic]^Pssg_Node,
	draws:     int,
	allocator: mem.Allocator,
	msg:       string,
	ok:        bool,
}

d3_node :: proc(b: ^D3_Build, name: string, attrs: []Pssg_Set, children: []^Pssg_Node = nil, data: []u8 = nil) -> ^Pssg_Node {
	if !b.ok {
		for child in children { pssg_node_delete(child, b.allocator) }
		if data != nil { delete(data, b.allocator) }
		return nil
	}
	node, msg, ok := pssg_make(b.types, name, attrs, children, data, b.allocator)
	if !ok { b.msg = msg; b.ok = false }
	return node
}

d3_fail :: proc(b: ^D3_Build, msg: string) {
	if b.ok { b.msg = msg; b.ok = false }
}

d3_ref :: proc(id: string) -> string { return fmt.tprintf("#%s", id) }

D3_Cell :: struct {
	ix, iz: int,
	picks:  [Collision_Material][dynamic]int,
	all:    [dynamic]int,
}

D3_Group :: struct {
	picks:  []int,
	shader: string,
	colour: [4]u8,
}

// A HIGH node carries one draw call for each material present in the tile, the
// way stock tiles carry up to 37. Every other layer is one call over the tile.
d3_layer_groups :: proc(b: ^D3_Build, layer: D3_Layer, cell: ^D3_Cell) -> []D3_Group {
	groups := make([dynamic]D3_Group, b.allocator)
	switch layer.role {
	case .Surface:
		for material in Collision_Material {
			if len(cell.picks[material]) == 0 { continue }
			append(&groups, D3_Group{cell.picks[material][:], b.profile.visual[material], b.profile.colour[material]})
		}
	case .Batch: append(&groups, D3_Group{cell.all[:], b.profile.batch, {}})
	case .Lod:   append(&groups, D3_Group{cell.all[:], b.profile.lod, {}})
	}
	return groups[:]
}

// One draw call: a vertex block, an index run, a data source and the instance
// that binds them to a shader. Appends to the render node being assembled.
d3_draw_call :: proc(
	b: ^D3_Build,
	layout: D3_Vertex_Layout,
	origin, pitch: [2]f32,
	w: ^D3_Weld,
	group: D3_Group,
	sources, instances: ^[dynamic]^Pssg_Node,
) -> (lo, hi: [3]f32) {
	vertices := u32(len(w.points))
	indices := u32(len(w.tris)*3)
	block_id := pssg_mint(b.ids, b.allocator)
	source_id := pssg_mint(b.ids, b.allocator)
	index_id := pssg_mint(b.ids, b.allocator)
	instance_id := pssg_mint(b.ids, b.allocator)

	block_kids := make([dynamic]^Pssg_Node, b.allocator)
	for stream in layout.streams {
		append(&block_kids, d3_node(b, "DATABLOCKSTREAM", []Pssg_Set{
			{"renderType", stream.render_type},
			{"dataType", stream.data_type},
			{"offset", stream.offset},
			{"stride", u32(layout.stride)},
		}))
	}
	payload := d3_pack_vertices(w, layout, origin, pitch, group.colour, b.allocator)
	size := u32(len(payload))
	append(&block_kids, d3_node(b, "DATABLOCKDATA", nil, nil, payload))
	append(&b.blocks, d3_node(b, "DATABLOCK", []Pssg_Set{
		{"streamCount", u32(len(layout.streams))},
		{"size", size},
		{"elementCount", vertices},
		{"id", block_id},
	}, block_kids[:]))

	source_kids := make([dynamic]^Pssg_Node, b.allocator)
	append(&source_kids, d3_node(b, "RENDERINDEXSOURCE", []Pssg_Set{
		{"primitive", "triangles"},
		{"maximumIndex", vertices-1},
		{"format", "ushort"},
		{"count", indices},
		{"id", index_id},
	}, []^Pssg_Node{d3_node(b, "INDEXSOURCEDATA", nil, nil, d3_pack_indices(w, b.allocator))}))
	for _, i in layout.streams {
		append(&source_kids, d3_node(b, "RENDERSTREAM", []Pssg_Set{
			{"dataBlock", d3_ref(block_id)},
			{"subStream", u32(i)},
			{"id", fmt.tprintf("%s_%d", source_id, i)},
		}))
	}
	append(sources, d3_node(b, "RENDERDATASOURCE", []Pssg_Set{
		{"streamCount", u32(len(layout.streams))},
		{"primitive", "triangles"},
		{"id", source_id},
	}, source_kids[:]))
	append(instances, d3_node(b, "RENDERSTREAMINSTANCE", []Pssg_Set{
		{"sourceCount", u32(1)},
		{"indices", d3_ref(source_id)},
		{"streamCount", u32(0)},
		{"shader", d3_ref(group.shader)},
		{"id", instance_id},
	}, []^Pssg_Node{d3_node(b, "RENDERINSTANCESOURCE", []Pssg_Set{{"source", d3_ref(source_id)}})}))

	return d3_bounds(w.points[:])
}

d3_render_node :: proc(b: ^D3_Build, layer: D3_Layer, cell: ^D3_Cell, origin, pitch: [2]f32) -> ^Pssg_Node {
	layout, supported := d3_vertex_layout(layer.stride)
	if !supported { d3_fail(b, fmt.tprintf("unsupported Dirt 3 vertex stride %d", layer.stride)); return nil }

	sources := make([dynamic]^Pssg_Node, b.allocator)
	instances := make([dynamic]^Pssg_Node, b.allocator)
	lo, hi: [3]f32
	seen := false

	for group in d3_layer_groups(b, layer, cell) {
		welds := make([dynamic]D3_Weld, b.allocator)
		current := d3_weld(b.allocator)
		for pick in group.picks {
			if len(current.points)+3 > D3_WELD_MAX {
				append(&welds, current)
				current = d3_weld(b.allocator)
			}
			d3_weld_add(&current, b.tris[pick])
		}
		if len(current.tris) > 0 { append(&welds, current) }

		for &weld in welds {
			call_lo, call_hi := d3_draw_call(b, layout, origin, pitch, &weld, group, &sources, &instances)
			if !b.ok { return nil }
			if !seen { lo, hi = call_lo, call_hi; seen = true } else {
				for k in 0..<3 { lo[k] = min(lo[k], call_lo[k]); hi[k] = max(hi[k], call_hi[k]) }
			}
		}
	}
	if !seen { return nil }

	// One SEGMENTSET per RENDERNODE, holding every draw call of that node.
	b.draws += len(sources)
	set_id := pssg_mint(b.ids, b.allocator)
	append(&b.segments, d3_node(b, "SEGMENTSET", []Pssg_Set{
		{"segmentCount", u32(len(sources))},
		{"id", set_id},
	}, sources[:]))

	name := fmt.tprintf("%s_%d_%d", layer.prefix, cell.ix, cell.iz)
	return d3_scene_node(b, "RENDERNODE", name, lo, hi, instances[:])
}

d3_scene_node :: proc(b: ^D3_Build, kind, name: string, lo, hi: [3]f32, children: []^Pssg_Node) -> ^Pssg_Node {
	frame, msg, ok := pssg_frame(b.types, lo, hi, b.allocator)
	if !ok { d3_fail(b, msg); return nil }
	kids := make([dynamic]^Pssg_Node, b.allocator)
	append(&kids, frame[0], frame[1])
	append(&kids, ..children)
	return d3_node(b, kind, []Pssg_Set{
		{"stopTraversal", u32(0)},
		{"nickname", name},
		{"id", name},
	}, kids[:])
}

d3_library :: proc(file: ^Pssg_File, kind: string) -> ^Pssg_Node {
	for child in file.root.children {
		if child.name == "LIBRARY" && pssg_attr_string(file, child, "type") == kind { return child }
	}
	return nil
}

d3_mesh_bounds :: proc(tris: []Collision_Triangle) -> (lo, hi: [3]f32) {
	lo = tris[0].Points[0]; hi = lo
	for tri in tris {
		for p in tri.Points {
			for k in 0..<3 { lo[k] = min(lo[k], p[k]); hi[k] = max(hi[k], p[k]) }
		}
	}
	return
}

// Bounds in the same reverse-z/reverse-x order as the PSSG tile nodes and
// track.vis tag-0 objects. Empty spatial cells emit neither a PSSG tile nor a
// VIS object; because both files are synthesized together, their dense ids
// remain identical without donor slots.
d3_tile_boxes :: proc(collision: []Collision_Triangle, profile: ^D3_Venue_Profile, allocator := context.allocator) -> (boxes: []D3_Tile_Box, msg: string, ok: bool) {
	if len(collision) == 0 { return nil, "Dirt 3 tiles need triangles", false }
	lo, hi := d3_mesh_bounds(collision)
	pitch_x := max(hi[0]-lo[0], D3_MIN_EXTENT)/f32(profile.tiles_x)
	pitch_z := max(hi[2]-lo[2], D3_MIN_EXTENT)/f32(profile.tiles_z)
	count := profile.tiles_x*profile.tiles_z
	cell_lo := make([][3]f32, count, context.temp_allocator)
	cell_hi := make([][3]f32, count, context.temp_allocator)
	seen := make([]bool, count, context.temp_allocator)
	for tri in collision {
		centre := (tri.Points[0]+tri.Points[1]+tri.Points[2])/3
		ix := clamp(int((centre[0]-lo[0])/pitch_x), 0, profile.tiles_x-1)
		iz := clamp(int((hi[2]-centre[2])/pitch_z), 0, profile.tiles_z-1)
		at := iz*profile.tiles_x+ix
		for p in tri.Points {
			if !seen[at] { cell_lo[at] = p; cell_hi[at] = p; seen[at] = true }
			for k in 0..<3 { cell_lo[at][k] = min(cell_lo[at][k], p[k]); cell_hi[at][k] = max(cell_hi[at][k], p[k]) }
		}
	}
	result := make([dynamic]D3_Tile_Box, allocator)
	for iz := profile.tiles_z-1; iz >= 0; iz -= 1 {
		for ix := profile.tiles_x-1; ix >= 0; ix -= 1 {
			i := iz*profile.tiles_x+ix
			if !seen[i] { continue }
			for k in 0..<3 {
				if cell_hi[i][k]-cell_lo[i][k] < D3_MIN_EXTENT {
					middle := (cell_lo[i][k]+cell_hi[i][k])/2
					cell_lo[i][k] = middle-D3_MIN_EXTENT/2
					cell_hi[i][k] = middle+D3_MIN_EXTENT/2
				}
			}
			append(&result, D3_Tile_Box{cell_lo[i], cell_hi[i]})
		}
	}
	return result[:], "", true
}

D3_Scene_Scope :: enum {
	Route,
	Venue,
}

d3_scene_cells :: proc(
	collision: []Collision_Triangle,
	profile: ^D3_Venue_Profile,
	lo, hi: [3]f32,
	pitch_x, pitch_z: f32,
	allocator: mem.Allocator,
) -> []D3_Cell {
	cells := make([]D3_Cell, profile.tiles_x*profile.tiles_z, allocator)
	for &cell in cells {
		cell.all = make([dynamic]int, allocator)
		for material in Collision_Material { cell.picks[material] = make([dynamic]int, allocator) }
	}
	for tri, i in collision {
		centre := (tri.Points[0]+tri.Points[1]+tri.Points[2])/3
		ix := clamp(int((centre[0]-lo[0])/pitch_x), 0, profile.tiles_x-1)
		iz := clamp(int((hi[2]-centre[2])/pitch_z), 0, profile.tiles_z-1)
		cell := &cells[iz*profile.tiles_x+ix]
		append(&cell.picks[tri.Material], i)
		append(&cell.all, i)
	}
	return cells
}

d3_scene_tiles :: proc(
	b: ^D3_Build,
	cells: []D3_Cell,
	lo, hi: [3]f32,
	pitch_x, pitch_z: f32,
) -> []^Pssg_Node {
	tiles := make([dynamic]^Pssg_Node, b.allocator)
	for iz := b.profile.tiles_z-1; iz >= 0; iz -= 1 {
		for ix := b.profile.tiles_x-1; ix >= 0; ix -= 1 {
			cell := &cells[iz*b.profile.tiles_x+ix]
			cell.ix = ix
			cell.iz = iz
			if len(cell.all) == 0 { continue }
			origin := [2]f32{lo[0]+pitch_x*f32(ix), hi[2]-pitch_z*f32(iz+1)}
			pitch := [2]f32{pitch_x, pitch_z}
			renders := make([dynamic]^Pssg_Node, b.allocator)
			for layer in D3_LAYERS {
				if node := d3_render_node(b, layer, cell, origin, pitch); node != nil { append(&renders, node) }
			}
			if !b.ok { return nil }
			if len(renders) > 0 {
				append(&tiles, d3_scene_node(b, "NODE", fmt.tprintf("ROOT_%d_%d", ix, iz), {}, {}, renders[:]))
			}
		}
	}
	return tiles[:]
}

d3_scene_replace_libraries :: proc(
	file: ^Pssg_File,
	root: ^Pssg_Node,
	segments, blocks: []^Pssg_Node,
	scope: D3_Scene_Scope,
	allocator: mem.Allocator,
) -> (msg: string, ok: bool) {
	node_library := d3_library(file, "NODE")
	segment_library := d3_library(file, "SEGMENTSET")
	bound_library := d3_library(file, "RENDERINTERFACEBOUND")
	if node_library == nil || segment_library == nil || bound_library == nil {
		return "the embedded Dirt 3 material pack is missing a scene library", false
	}
	pssg_set_children(node_library, []^Pssg_Node{root}, allocator)
	pssg_set_children(segment_library, segments, allocator)
	if scope == .Route {
		pssg_set_children(bound_library, blocks, allocator)
		return "", true
	}

	// Route shaders resolve texture payloads from the venue tracksplit.
	textures := make([dynamic]^Pssg_Node, allocator)
	for child in bound_library.children {
		if child.name == "TEXTURE" { append(&textures, child) }
	}
	clear(&bound_library.children)
	append(&bound_library.children, ..textures[:])
	append(&bound_library.children, ..blocks)
	return "", true
}

// Stock files list tiles by descending z index, then descending x, and tile z
// index 0 is the high-z end.
d3_routesplit_build_with_template :: proc(
	collision: []Collision_Triangle,
	profile: ^D3_Venue_Profile,
	template: []u8,
	scope: D3_Scene_Scope,
	allocator := context.allocator,
) -> (out: []u8, msg: string, ok: bool) {
	if len(collision) == 0 { return nil, "Dirt 3 graphics need triangles", false }

	// One arena for the whole scene, so a rejected mesh frees everything it
	// built. Only the encoded output is handed back on the caller's allocator.
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return nil, "could not reserve memory for the Dirt 3 scene", false
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	file, read_msg, read_ok := pssg_read(template, scratch)
	if !read_ok { return nil, read_msg, false }
	types := pssg_types(&file, scratch)
	ids := pssg_ids(&file, scratch)

	b := D3_Build{
		file = &file, types = &types, ids = &ids, profile = profile, tris = collision,
		blocks = make([dynamic]^Pssg_Node, scratch),
		segments = make([dynamic]^Pssg_Node, scratch),
		allocator = scratch, ok = true,
	}

	lo, hi := d3_mesh_bounds(collision)
	pitch_x := max(hi[0]-lo[0], D3_MIN_EXTENT)/f32(profile.tiles_x)
	pitch_z := max(hi[2]-lo[2], D3_MIN_EXTENT)/f32(profile.tiles_z)
	cells := d3_scene_cells(collision, profile, lo, hi, pitch_x, pitch_z, scratch)
	tiles := d3_scene_tiles(&b, cells, lo, hi, pitch_x, pitch_z)
	if !b.ok { return nil, b.msg, false }
	if len(tiles) == 0 { return nil, "Dirt 3 graphics need triangles inside the route bounds", false }

	surface := d3_scene_node(&b, "NODE", "surface", {}, {}, tiles[:])
	root := d3_scene_node(&b, "ROOTNODE", "Scene Root", {}, {}, []^Pssg_Node{surface})
	if !b.ok { return nil, b.msg, false }

	if library_msg, libraries_ok := d3_scene_replace_libraries(&file, root, b.segments[:], b.blocks[:], scope, scratch); !libraries_ok {
		return nil, library_msg, false
	}

	out, ok = pssg_write(&file, allocator)
	if !ok { return nil, "could not encode routesplit.pssg", false }
	return out, fmt.tprintf("%d triangles, %d tiles, %d draw calls", len(collision), len(tiles), b.draws), true
}

d3_routesplit_build :: proc(collision: []Collision_Triangle, profile: ^D3_Venue_Profile, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	return d3_routesplit_build_with_template(collision, profile, profile.template, .Route, allocator)
}

d3_write_routesplit :: proc(job: ^Export_Job, profile: ^D3_Venue_Profile) -> (string, bool) {
	data, msg, ok := d3_routesplit_build(job.Collision, profile)
	if !ok { return msg, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "routesplit.pssg", data); !written { return write_msg, false }
	return msg, true
}

// Same container, venue scope: `job.Collision` is the whole road network, not
// one route. `d3_routesplit_build` does not know the difference; only the
// output name does.
d3_write_tracksplit :: proc(job: ^Export_Job, profile: ^D3_Venue_Profile, template: []u8, scope: D3_Scene_Scope) -> (string, bool) {
	data, msg, ok := d3_routesplit_build_with_template(job.Collision, profile, template, scope)
	if !ok { return msg, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "tracksplit.pssg", data); !written { return write_msg, false }
	return msg, true
}

// The profile maps a material to a collision code; going back the other way
// gives a stock or exported track.jpk the visual surface that matches it.
d3_material_of :: proc(profile: ^D3_Venue_Profile, code: string) -> Collision_Material {
	for material in Collision_Material {
		if profile.collision[material] == code { return material }
	}
	return .Terrain
}

// A debug converter: a stock track.jpk in, a routesplit out. It runs with no
// venue open, so it draws with the fixture shaders rather than a venue's own.
dirt3_routesplit_headless :: proc(path, out_path: string) -> (msg: string, ok: bool) {
	profile, profile_msg, profile_ok := d3_profile_fixture()
	if !profile_ok { return profile_msg, false }
	collision, read_msg, read_ok := d3_collision_read(path, context.allocator)
	if !read_ok { return read_msg, false }
	defer d3_collision_delete(&collision)

	total := 0
	for chunk in collision.chunks { total += len(chunk.tris) }
	tris := make([]Collision_Triangle, total, context.allocator)
	defer delete(tris)
	at := 0
	for chunk in collision.chunks {
		for tri in chunk.tris {
			code := chunk.mats[tri.mat] if tri.mat >= 0 && tri.mat < len(chunk.mats) else ""
			tris[at] = {
				Points = {chunk.verts[tri.v[0]], chunk.verts[tri.v[1]], chunk.verts[tri.v[2]]},
				Material = d3_material_of(&profile, code),
			}
			at += 1
		}
	}

	data, build_msg, built := d3_routesplit_build(tris, &profile, context.allocator)
	if !built { return build_msg, false }
	defer delete(data)
	if err := os.write_entire_file(out_path, data); err != nil {
		return fmt.tprintf("could not write %s: %v", out_path, err), false
	}
	return fmt.tprintf("%s: %d chunks, %s", out_path, len(collision.chunks), build_msg), true
}
