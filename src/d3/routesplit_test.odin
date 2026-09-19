package d3

import "core:fmt"
import "core:math"
import "core:testing"

// A flat grid of quads over 800 x 400 m, materials alternating by quad parity.
// With the built-in 8 x 4 tile grid every tile holds four quads of both
// materials, and the mesh is flat in Y so the bounding-box padding is exercised.
d3_test_mesh :: proc(allocator := context.allocator) -> []Collision_Triangle {
	QX :: 16; QZ :: 8
	out := make([]Collision_Triangle, QX*QZ*2, allocator)
	for qz in 0..<QZ {
		for qx in 0..<QX {
			x0 := f32(qx)*50; x1 := x0+50
			z0 := f32(qz)*50; z1 := z0+50
			material: Collision_Material = (qx+qz)%2 == 0 ? .Road : .Terrain
			at := (qz*QX+qx)*2
			out[at] = {Points={{x0,0,z0},{x0,0,z1},{x1,0,z0}}, Material=material}
			out[at+1] = {Points={{x1,0,z0},{x0,0,z1},{x1,0,z1}}, Material=material}
		}
	}
	return out
}

// Every builder takes a profile. Tests use the venue-less fixture.
d3_test_profile :: proc() -> ^D3_Venue_Profile {
	@(static) profile: D3_Venue_Profile
	if profile.template == nil {
		built, _, ok := d3_profile_fixture()
		if ok { profile = built }
	}
	return &profile
}

d3_test_walk :: proc(node: ^Pssg_Node, out: ^[dynamic]^Pssg_Node) {
	append(out, node)
	for child in node.children { d3_test_walk(child, out) }
}

d3_test_named :: proc(nodes: []^Pssg_Node, name: string, out: ^[dynamic]^Pssg_Node) {
	clear(out)
	for node in nodes { if node.name == name { append(out, node) } }
}

@(test)
routesplit_builds_the_stock_tile_scene :: proc(t: ^testing.T) {
	tris := d3_test_mesh(context.temp_allocator)
	raw, msg, built := d3_routesplit_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)
	found := make([dynamic]^Pssg_Node, context.temp_allocator)

	d3_test_named(nodes[:], "ROOTNODE", &found)
	testing.expect_value(t, len(found), 1)

	tiles := 0
	for node in nodes {
		if node.name == "NODE" && pssg_attr_string(&file, node, "id") != "surface" { tiles += 1 }
	}
	testing.expect_value(t, tiles, 32)

	d3_test_named(nodes[:], "RENDERNODE", &found)
	testing.expect_value(t, len(found), 32*len(D3_LAYERS))

	// HIGH splits by material, so each tile draws Road and Terrain separately.
	d3_test_named(nodes[:], "DATABLOCK", &found)
	testing.expect_value(t, len(found), 32*5)
}

@(test)
tracksplit_replaces_geometry_but_retains_texture_payloads :: proc(t: ^testing.T) {
	profile := d3_test_profile()
	donor, donor_msg, donor_ok := pssg_read(profile.template, context.allocator)
	testing.expect(t, donor_ok, donor_msg); if !donor_ok { return }
	defer pssg_delete(&donor)

	texture_type: u32
	for id, name in donor.node_names {
		if name == "TEXTURE" { texture_type = id; break }
	}
	testing.expect(t, texture_type != 0, "fixture schema has no TEXTURE type")
	bound := d3_library(&donor, "RENDERINTERFACEBOUND")
	testing.expect(t, bound != nil, "fixture has no bound library"); if bound == nil { return }
	payload := []u8{0xde, 0xad, 0xbe, 0xef}
	texture := new(Pssg_Node)
	texture.type_id = texture_type
	texture.name = "TEXTURE"
	texture.attrs = make([dynamic]Pssg_Attr)
	texture.children = make([dynamic]^Pssg_Node)
	texture.data = make([]u8, len(payload))
	texture.data_owned = true
	copy(texture.data, payload)
	append(&bound.children, texture)
	template, encoded := pssg_write(&donor, context.allocator)
	testing.expect(t, encoded, "could not encode tracksplit fixture"); if !encoded { return }
	defer delete(template)

	tris := d3_test_mesh(context.temp_allocator)
	raw, msg, built := d3_routesplit_build_with_template(tris, profile, template, .Venue, context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	bound = d3_library(&file, "RENDERINTERFACEBOUND")
	textures, blocks := 0, 0
	for child in bound.children {
		switch child.name {
		case "TEXTURE":
			textures += 1
			testing.expect(t, len(child.data) == len(payload) && child.data[0] == payload[0] && child.data[3] == payload[3], "texture payload changed")
		case "DATABLOCK": blocks += 1
		}
	}
	testing.expect_value(t, textures, 1)
	testing.expect_value(t, blocks, 32*5)
}

@(test)
routesplit_attribute_ids_match_the_material_pack :: proc(t: ^testing.T) {
	pack, pack_msg, pack_ok := pssg_read(d3_test_profile().template, context.temp_allocator)
	testing.expect(t, pack_ok, pack_msg); if !pack_ok { return }
	want := pssg_types(&pack, context.temp_allocator)

	tris := d3_test_mesh(context.temp_allocator)
	raw, msg, built := d3_routesplit_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)
	checked := 0
	for node in nodes {
		for attr in node.attrs {
			name, known := file.attr_names[attr.type_id]
			if !known { continue }
			expected, in_pack := want.attr_id[Pssg_Attr_Key{node=node.name, attr=name}]
			if !in_pack { continue }
			testing.expectf(t, expected == attr.type_id,
				"%s.%s was written with attribute id %d, the pack uses %d",
				node.name, name, attr.type_id, expected)
			checked += 1
		}
	}
	testing.expect(t, checked > 500, fmt.tprintf("only %d attribute ids were comparable", checked))
}

@(test)
routesplit_references_and_counts_agree :: proc(t: ^testing.T) {
	tris := d3_test_mesh(context.temp_allocator)
	raw, msg, built := d3_routesplit_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)

	ids := make(map[string]bool, context.temp_allocator)
	for node in nodes {
		id := pssg_attr_string(&file, node, "id")
		if id == "" { continue }
		testing.expectf(t, id not_in ids, "duplicate id %s", id)
		ids[id] = true
	}

	refs := 0
	for node in nodes {
		for name in ([]string{"shaderGroup", "indices", "shader", "source", "dataBlock"}) {
			target := pssg_attr_string(&file, node, name)
			if target == "" { continue }
			if target[0] == '#' { target = target[1:] }
			refs += 1
			testing.expectf(t, target in ids, "%s.%s points at missing #%s", node.name, name, target)
		}
		switch node.name {
		case "DATABLOCK":
			payload := pssg_walk_first(node, "DATABLOCKDATA")
			stream := pssg_walk_first(node, "DATABLOCKSTREAM")
			if payload == nil || stream == nil { testing.fail(t); continue }
			streams := 0
			for child in node.children { if child.name == "DATABLOCKSTREAM" { streams += 1 } }
			size, _ := pssg_attr_u32(&file, node, "size")
			count, _ := pssg_attr_u32(&file, node, "elementCount")
			stride, _ := pssg_attr_u32(&file, stream, "stride")
			declared, _ := pssg_attr_u32(&file, node, "streamCount")
			testing.expect_value(t, int(size), len(payload.data))
			testing.expect_value(t, int(count*stride), len(payload.data))
			testing.expect_value(t, int(declared), streams)
		case "RENDERINDEXSOURCE":
			payload := pssg_walk_first(node, "INDEXSOURCEDATA")
			if payload == nil { testing.fail(t); continue }
			count, _ := pssg_attr_u32(&file, node, "count")
			highest, _ := pssg_attr_u32(&file, node, "maximumIndex")
			testing.expect_value(t, int(count)*2, len(payload.data))
			for i in 0..<int(count) {
				index := u32(payload.data[i*2])<<8 | u32(payload.data[i*2+1])
				if index > highest { testing.fail(t); break }
			}
		case "RENDERNODE":
			box := pssg_walk_first(node, "BOUNDINGBOX")
			if box == nil || len(box.data) != 24 { testing.fail(t); continue }
			axis := "xyz"
			for k in 0..<3 {
				low := d3_test_f32(box.data, k*4)
				high := d3_test_f32(box.data, 12+k*4)
				testing.expectf(t, high-low > 0,
					"RENDERNODE %s is flat on %c, so the game draws nothing for it",
					pssg_attr_string(&file, node, "id"), axis[k])
			}
		}
	}
	testing.expect(t, refs > 500, fmt.tprintf("only %d references were checked", refs))
}

@(test)
routesplit_splits_a_group_it_cannot_index :: proc(t: ^testing.T) {
	_, _, any := d3_routesplit_build(nil, d3_test_profile(), context.allocator)
	testing.expect(t, !any, "no triangles must be an error, not an empty scene")

	// All in one cell, no two corners at the same position, so welding cannot
	// bring the group back under the ushort index range.
	crowded := make([]Collision_Triangle, D3_WELD_MAX/3+1, context.temp_allocator)
	for &tri, i in crowded {
		y := f32(i)*3
		tri = {Points={{0,y,0},{1,y+1,0},{0,y+2,1}}, Material=.Road}
	}
	raw, msg, built := d3_routesplit_build(crowded, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)
	for node in nodes {
		if node.name != "RENDERNODE" { continue }
		calls := 0
		for child in node.children { if child.name == "RENDERSTREAMINSTANCE" { calls += 1 } }
		testing.expect_value(t, calls, 2)
	}
	// The split is a full call plus the remainder, not two ragged halves.
	indexed := 0
	for node in nodes {
		if node.name != "RENDERINDEXSOURCE" { continue }
		count, _ := pssg_attr_u32(&file, node, "count")
		maximum, _ := pssg_attr_u32(&file, node, "maximumIndex")
		testing.expect(t, maximum < u32(D3_WELD_MAX), "a draw call exceeds the ushort index range")
		indexed += int(count)
	}
	testing.expect_value(t, indexed, len(crowded)*3*len(D3_LAYERS))
}

d3_test_f32 :: proc(data: []u8, at: int) -> f32 { v, _ := pssg_be_u32(data, at); return transmute(f32)v }

// The ST invariant stock holds: one square map over the mesh, u along +X and
// v along +Z, continuous across the tiles. The fixture mesh is 800 x 400 m, so
// v reaching only 0.5 is the point — a per-tile or per-axis map would stretch
// it to 1.
@(test)
routesplit_st_is_one_square_map_over_the_mesh :: proc(t: ^testing.T) {
	tris := d3_test_mesh(context.temp_allocator)
	want := d3_st_map(d3_mesh_bounds(tris))
	testing.expect_value(t, want.side, 800)

	raw, msg, built := d3_routesplit_build(tris, d3_test_profile(), context.allocator)
	testing.expect(t, built, msg); if !built { return }
	defer delete(raw)
	file, parse_msg, parsed := pssg_read(raw, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)

	// Half floats carry the map to about this much of an ST unit.
	TOLERANCE :: 0.001
	checked, v_high := 0, f32(0)
	for node in nodes {
		if node.name != "DATABLOCK" { continue }
		stream := pssg_walk_first(node, "DATABLOCKSTREAM")
		payload := pssg_walk_first(node, "DATABLOCKDATA")
		if stream == nil || payload == nil { continue }
		stride, _ := pssg_attr_u32(&file, stream, "stride")
		layout, known := d3_vertex_layout(stride)
		if !known || layout.uv < 0 { continue }
		count, _ := pssg_attr_u32(&file, node, "elementCount")
		for i in 0..<int(count) {
			base := i*layout.stride
			p := [3]f32{
				binary_load_f32(payload.data, base, .Big),
				binary_load_f32(payload.data, base+4, .Big),
				binary_load_f32(payload.data, base+8, .Big),
			}
			got := [2]f32{
				f32(transmute(f16)binary_load_u16(payload.data, base+layout.uv, .Big)),
				f32(transmute(f16)binary_load_u16(payload.data, base+layout.uv+2, .Big)),
			}
			// The fixture is flat, so its normals are all up and the height fold
			// contributes exactly nothing — which is half of what this asserts.
			expected := d3_st(want, p, {0, 1, 0})
			for k in 0..<2 {
				testing.expectf(t, abs(got[k]-expected[k]) < TOLERANCE,
					"vertex at %v got ST %v, the mesh-wide map gives %v", p, got, expected)
			}
			v_high = max(v_high, got[1])
			checked += 1
		}
	}
	testing.expect(t, checked > 500, fmt.tprintf("only %d textured vertices were read", checked))
	testing.expect(t, abs(v_high-0.5) < TOLERANCE, fmt.tprintf("v reached %v, the 400 m axis of an 800 m map is 0.5", v_high))
}

// A top-down ST map projects a wall onto a line, and the texture stretches up
// the face without limit — worst where the face is sheerest, which is what a
// rough cliff shows in game. The height fold puts the density back.
@(test)
st_holds_its_density_on_a_wall :: proc(t: ^testing.T) {
	m := d3_st_map({0, 0, 0}, {800, 50, 400})
	step :: 4.0

	// Flat ground: unchanged, and indifferent to height.
	ground := d3_st(m, {100, 0, 100}, {0, 1, 0})
	along := d3_st(m, {100 + step, 0, 100}, {0, 1, 0})
	testing.expect_value(t, d3_st(m, {100, 30, 100}, {0, 1, 0}), ground)
	flat_density := abs(along[0] - ground[0]) * m.side / step
	testing.expect(t, abs(flat_density - 1) < 0.001, "flat ground must map a metre to a metre")

	// A wall facing +X, climbed. Its ST must move as far as the ground's does.
	for normal in ([][3]f32{{1, 0, 0}, {0, 0, 1}, {0.707, 0.707, 0}}) {
		lo := d3_st(m, {100, 0, 100}, normal)
		hi := d3_st(m, {100, step, 100}, normal)
		moved := abs(hi[0] - lo[0]) + abs(hi[1] - lo[1])
		// Climbing `step` in y on a face tilted off vertical travels
		// `step/sin(tilt)` along it, of which the top-down map already has the
		// horizontal part. The fold owes the rest.
		slope := math.sqrt(normal[0]*normal[0] + normal[2]*normal[2])
		want := step * (1 - abs(normal[1])) / slope
		testing.expectf(t, abs(moved*m.side - want) < 0.01,
			"normal %v climbed %.1f m: ST moved %.2f m, the face travelled %.2f m further than flat",
			normal, f32(step), moved*m.side, want)
	}
}
