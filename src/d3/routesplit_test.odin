package d3

import "core:fmt"
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
