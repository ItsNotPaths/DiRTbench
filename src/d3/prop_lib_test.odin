package d3

import "core:testing"

// A PSSG built node by node rather than from bytes. The reader's own container
// handling is covered by pssg_test; what matters here is which draw calls a
// prop root resolves to, so these tests build the shapes a stock prop has and
// nothing else.
Prop_Test_Builder :: struct {
	file:    Pssg_File,
	next_id: u32,
}

prop_test_builder :: proc(b: ^Prop_Test_Builder) {
	b.file.node_names = make(map[u32]string, context.temp_allocator)
	b.file.attr_names = make(map[u32]string, context.temp_allocator)
}

prop_test_type :: proc(b: ^Prop_Test_Builder, names: map[u32]string, name: string) -> u32 {
	for id, known in names {
		if known == name {
			return id
		}
	}
	b.next_id += 1
	return b.next_id
}

prop_test_attr :: proc(b: ^Prop_Test_Builder, name, value: string) -> Pssg_Attr {
	id := prop_test_type(b, b.file.attr_names, name)
	b.file.attr_names[id] = name
	bytes := make([]u8, 4 + len(value), context.temp_allocator)
	binary_store_u32(bytes, 0, u32(len(value)), .Big)
	copy(bytes[4:], transmute([]u8)value)
	return {type_id = id, value = bytes}
}

prop_test_attr_u32 :: proc(b: ^Prop_Test_Builder, name: string, value: u32) -> Pssg_Attr {
	id := prop_test_type(b, b.file.attr_names, name)
	b.file.attr_names[id] = name
	bytes := make([]u8, 4, context.temp_allocator)
	binary_store_u32(bytes, 0, value, .Big)
	return {type_id = id, value = bytes}
}

prop_test_node :: proc(
	b: ^Prop_Test_Builder, name: string, attrs: []Pssg_Attr, children: []^Pssg_Node, data: []u8 = nil,
) -> ^Pssg_Node {
	id := prop_test_type(b, b.file.node_names, name)
	b.file.node_names[id] = name
	node := new(Pssg_Node, context.temp_allocator)
	node.type_id = id
	node.name = name
	node.attrs = make([dynamic]Pssg_Attr, context.temp_allocator)
	node.children = make([dynamic]^Pssg_Node, context.temp_allocator)
	append(&node.attrs, ..attrs)
	append(&node.children, ..children)
	node.data = data
	return node
}

prop_test_f32s :: proc(values: [][3]f32) -> []u8 {
	out := make([]u8, len(values) * 12, context.temp_allocator)
	for v, i in values {
		for k in 0 ..< 3 {
			binary_store_f32(out, i * 12 + k * 4, v[k], .Big)
		}
	}
	return out
}

prop_test_indices :: proc(values: []u16) -> []u8 {
	out := make([]u8, len(values) * 2, context.temp_allocator)
	for v, i in values {
		binary_store_u16(out, i * 2, v, .Big)
	}
	return out
}

// One draw call's worth of geometry, addressed by `id`.
prop_test_source :: proc(
	b: ^Prop_Test_Builder, id: string, verts: [][3]f32, indices: []u16,
) -> ^Pssg_Node {
	block_id := concat_temp(id, "_block")
	block := prop_test_node(b, "DATABLOCK", {
		prop_test_attr(b, "id", block_id),
		prop_test_attr_u32(b, "elementCount", u32(len(verts))),
	}, {
		prop_test_node(b, "DATABLOCKSTREAM", {
			prop_test_attr(b, "renderType", "Vertex"),
			prop_test_attr(b, "dataType", "float3"),
			prop_test_attr_u32(b, "offset", 0),
			prop_test_attr_u32(b, "stride", 12),
		}, nil),
		prop_test_node(b, "DATABLOCKDATA", nil, nil, prop_test_f32s(verts)),
	})
	source := prop_test_node(b, "RENDERDATASOURCE", {prop_test_attr(b, "id", id)}, {
		prop_test_node(b, "RENDERINDEXSOURCE", {
			prop_test_attr(b, "format", "ushort"),
			prop_test_attr_u32(b, "count", u32(len(indices))),
		}, {
			prop_test_node(b, "INDEXSOURCEDATA", nil, nil, prop_test_indices(indices)),
		}),
		prop_test_node(b, "RENDERSTREAM", {
			prop_test_attr(b, "dataBlock", concat_temp("#", block_id)),
		}, nil),
	})
	// The block is a sibling of the source in a stock file, and is found by id.
	return prop_test_node(b, "LIBRARY", {prop_test_attr(b, "type", "RENDERINTERFACEBOUND")}, {source, block})
}

concat_temp :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out[:len(a)], transmute([]u8)a)
	copy(out[len(a):], transmute([]u8)b)
	return string(out)
}

prop_test_instance :: proc(b: ^Prop_Test_Builder, source: string) -> ^Pssg_Node {
	return prop_test_node(b, "RENDERSTREAMINSTANCE", nil, {
		prop_test_node(b, "RENDERINSTANCESOURCE", {
			prop_test_attr(b, "source", concat_temp("#", source)),
		}, nil),
	})
}

// Root the file at a NODE library holding these prop roots, plus the geometry
// libraries, and bind it.
prop_test_bind :: proc(b: ^Prop_Test_Builder, lib: ^Prop_Library, roots, others: []^Pssg_Node) {
	children := make([dynamic]^Pssg_Node, context.temp_allocator)
	append(&children, prop_test_node(b, "LIBRARY", {prop_test_attr(b, "type", "NODE")}, roots))
	append(&children, ..others)
	b.file.root = prop_test_node(b, "PSSGDATABASE", nil, children[:])
	lib.file = b.file
	prop_lib_bind(lib, context.temp_allocator)
}

@(test)
prop_lod0_is_the_lod_node_and_not_the_cheaper_levels :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	prop_test_builder(&b)

	near := prop_test_source(&b, "near", {{0, 0, 0}, {2, 0, 0}, {0, 3, 0}}, {0, 1, 2})
	far := prop_test_source(&b, "far", {{0, 0, 0}, {9, 0, 0}, {0, 9, 0}}, {0, 1, 2})
	// A stock prop: the drawn node, a cheaper level under LODRENDERINSTANCES, and
	// a variant node beside the drawn one. Only the first is LOD0.
	root := prop_test_node(&b, "ROOTNODE", {prop_test_attr(&b, "id", "crate Root")}, {
		prop_test_node(&b, "LODVISIBLERENDERNODE", {
			prop_test_attr(&b, "id", "lod!1"),
			prop_test_attr(&b, "nickname", "lod"),
		}, {
			prop_test_instance(&b, "near"),
			prop_test_node(&b, "LODRENDERINSTANCES", nil, {
				prop_test_node(&b, "LODRENDERINSTANCELIST", nil, {prop_test_instance(&b, "far")}),
			}),
		}),
		prop_test_node(&b, "NODE", {
			prop_test_attr(&b, "id", "default!1"),
			prop_test_attr(&b, "nickname", "default"),
		}, {prop_test_instance(&b, "far")}),
	})

	lib: Prop_Library
	prop_test_bind(&b, &lib, {root}, {near, far})
	testing.expect_value(t, len(lib.props), 1)
	testing.expect_value(t, lib.props[0].name, "crate")

	mesh, ok := prop_lib_mesh(&lib, "crate", context.temp_allocator)
	testing.expect(t, ok, "the prop has geometry")
	if !ok {
		return
	}
	testing.expect_value(t, len(mesh.pos), 3)
	testing.expect_value(t, len(mesh.tris), 3)
	// The cheaper level reaches 9 m; LOD0 does not.
	testing.expect_value(t, mesh.hi, [3]f32{2, 3, 0})
}

@(test)
prop_tree_takes_its_most_detailed_tier :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	prop_test_builder(&b)

	detailed := prop_test_source(&b, "xt", {{0, 0, 0}, {1, 0, 0}, {0, 7, 0}}, {0, 1, 2})
	coarse := prop_test_source(&b, "x2", {{0, 0, 0}, {5, 0, 0}, {0, 5, 0}}, {0, 1, 2})
	trunk := prop_test_source(&b, "trunk", {{0, 0, 0}, {0.2, 0, 0}, {0, 1, 0}}, {0, 1, 2})
	// A tree nests its levels one deeper as sibling sub-nodes, and the trunk sits
	// under the tier it belongs to.
	root := prop_test_node(&b, "ROOTNODE", {prop_test_attr(&b, "id", "birch Root")}, {
		prop_test_node(&b, "LODVISIBLERENDERNODE", {
			prop_test_attr(&b, "id", "lod!2"),
			prop_test_attr(&b, "nickname", "lod"),
		}, {
			prop_test_node(&b, "NODE", {prop_test_attr(&b, "nickname", "birch_x2")}, {
				prop_test_instance(&b, "x2"),
			}),
			prop_test_node(&b, "NODE", {prop_test_attr(&b, "nickname", "birch_xt")}, {
				prop_test_instance(&b, "xt"),
			}),
			prop_test_instance(&b, "trunk"),
		}),
	})

	lib: Prop_Library
	prop_test_bind(&b, &lib, {root}, {detailed, coarse, trunk})
	mesh, ok := prop_lib_mesh(&lib, "birch", context.temp_allocator)
	testing.expect(t, ok, "the tree has geometry")
	if !ok {
		return
	}
	// The _xt tier plus the unsuffixed trunk, and nothing from _x2.
	testing.expect_value(t, len(mesh.pos), 6)
	testing.expect_value(t, mesh.hi, [3]f32{1, 7, 0})
}

@(test)
prop_bad_index_drops_its_triangle_only :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	prop_test_builder(&b)
	// The first triangle names a vertex the block does not hold. Only that
	// triangle goes; the good one after it must come through unshifted.
	geom := prop_test_source(&b, "geom", {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}, {0, 1, 9, 0, 1, 2})
	root := prop_test_node(&b, "ROOTNODE", {prop_test_attr(&b, "id", "sign Root")}, {
		prop_test_node(&b, "LODVISIBLERENDERNODE", {
			prop_test_attr(&b, "id", "lod!1"),
			prop_test_attr(&b, "nickname", "lod"),
		}, {prop_test_instance(&b, "geom")}),
	})

	lib: Prop_Library
	prop_test_bind(&b, &lib, {root}, {geom})
	mesh, ok := prop_lib_mesh(&lib, "sign", context.temp_allocator)
	testing.expect(t, ok, "the good triangle survives")
	if !ok {
		return
	}
	testing.expect_value(t, len(mesh.tris), 3)
	testing.expect_value(t, mesh.tris[0], u32(0))
	testing.expect_value(t, mesh.tris[1], u32(1))
	testing.expect_value(t, mesh.tris[2], u32(2))
}

@(test)
prop_missing_name_is_not_a_mesh :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	prop_test_builder(&b)
	lib: Prop_Library
	prop_test_bind(&b, &lib, nil, nil)
	_, ok := prop_lib_mesh(&lib, "nothing", context.temp_allocator)
	testing.expect(t, !ok, "a prop the library does not hold has no mesh")
}
