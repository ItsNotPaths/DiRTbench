package d3

import "core:testing"

// Card clouds, against a hand-built `trees.pssg` so the shape being tested is
// visible in the test rather than buried in 800 KB of stock art. One test at the
// end reads a real venue, when there is one.

// A stride-24 card block: four vertices at one point, the atlas rectangle, and
// the corner offsets in metres.
@(private = "file")
card_block :: proc(b: ^Prop_Test_Builder, id: string, cards: [][2]f32, u_width: f32) -> ^Pssg_Node {
	data := make([]u8, len(cards) * 4 * BILLBOARD_STRIDE, context.temp_allocator)
	for card, i in cards {
		hw, hh := card[0] * 0.5, card[1] * 0.5
		corners := [4][4]f32{
			{0, 1, -hw, -hh},
			{u_width, 1, hw, -hh},
			{u_width, 0, hw, hh},
			{0, 0, -hw, hh},
		}
		for corner, k in corners {
			at := (i * 4 + k) * BILLBOARD_STRIDE
			for axis in 0 ..< 3 {
				binary_store_f32(data, at + axis * 4, f32(i * 10), .Big)
			}
			binary_store_u32(data, at + 12, 0xff808080, .Big)
			for v, n in corner {
				binary_store_u16(data, at + 16 + n * 2, d3_half(v), .Big)
			}
		}
	}
	return prop_test_node(b, "DATABLOCK", {
		prop_test_attr(b, "id", id),
		prop_test_attr_u32(b, "elementCount", u32(len(cards) * 4)),
		prop_test_attr_u32(b, "size", u32(len(data))),
	}, {
		prop_test_node(b, "DATABLOCKSTREAM", {
			prop_test_attr(b, "renderType", "Vertex"),
			prop_test_attr(b, "dataType", "float3"),
			prop_test_attr_u32(b, "offset", 0),
			prop_test_attr_u32(b, "stride", BILLBOARD_STRIDE),
		}, nil),
		prop_test_node(b, "DATABLOCKSTREAM", {
			prop_test_attr(b, "renderType", "ST"),
			prop_test_attr(b, "dataType", "half2"),
			prop_test_attr_u32(b, "offset", 16),
			prop_test_attr_u32(b, "stride", BILLBOARD_STRIDE),
		}, nil),
		prop_test_node(b, "DATABLOCKSTREAM", {
			prop_test_attr(b, "renderType", "ST"),
			prop_test_attr(b, "dataType", "half2"),
			prop_test_attr_u32(b, "offset", 20),
			prop_test_attr_u32(b, "stride", BILLBOARD_STRIDE),
		}, nil),
		prop_test_node(b, "DATABLOCKDATA", nil, nil, data),
	})
}

@(private = "file")
card_box :: proc(b: ^Prop_Test_Builder) -> ^Pssg_Node {
	return prop_test_node(b, "BOUNDINGBOX", nil, nil, pssg_box_bytes({-1, -1, -1}, {1, 1, 1}, context.temp_allocator))
}

// One cloud, in the shape every stock distance cloud has: a `lod` node holding
// one level, holding one draw.
@(private = "file")
card_cloud :: proc(
	b: ^Prop_Test_Builder, name: string, cards: [][2]f32, u_width: f32,
) -> (root, source, block: ^Pssg_Node) {
	block = card_block(b, concat_temp(name, "_block"), cards, u_width)
	indices := make([]u16, len(cards) * 6, context.temp_allocator)
	for i in 0 ..< len(cards) {
		base := u16(i * 4)
		for corner, k in ([6]u16{0, 1, 2, 2, 3, 0}) {
			indices[i * 6 + k] = base + corner
		}
	}
	source = prop_test_node(b, "RENDERDATASOURCE", {prop_test_attr(b, "id", name)}, {
		prop_test_node(b, "RENDERINDEXSOURCE", {
			prop_test_attr(b, "id", concat_temp(name, "_index")),
			prop_test_attr(b, "format", "ushort"),
			prop_test_attr_u32(b, "count", u32(len(indices))),
			prop_test_attr_u32(b, "maximumIndex", u32(len(cards) * 4 - 1)),
		}, {
			prop_test_node(b, "INDEXSOURCEDATA", nil, nil, prop_test_indices(indices)),
		}),
		prop_test_node(b, "RENDERSTREAM", {
			prop_test_attr(b, "id", concat_temp(name, "_stream")),
			prop_test_attr(b, "dataBlock", concat_temp("#", concat_temp(name, "_block"))),
		}, nil),
	})
	draw := prop_test_node(b, "RENDERNODE", {
		prop_test_attr(b, "id", concat_temp(name, "_fo")),
		prop_test_attr(b, "nickname", concat_temp(name, "_fo")),
	}, {
		card_box(b),
		prop_test_node(b, "RENDERSTREAMINSTANCE", {
			prop_test_attr(b, "id", concat_temp(name, "_draw")),
			prop_test_attr(b, "indices", concat_temp("#", name)),
			prop_test_attr(b, "shader", "#sheet_material"),
		}, {
			prop_test_node(b, "RENDERINSTANCESOURCE", {
				prop_test_attr(b, "source", concat_temp("#", name)),
			}, nil),
		}),
	})
	level := prop_test_node(b, "RENDERNODE", {
		prop_test_attr(b, "id", concat_temp(name, "_x0")),
		prop_test_attr(b, "nickname", concat_temp(name, "_x0")),
	}, {card_box(b), draw})
	lod := prop_test_node(b, "NODE", {
		prop_test_attr(b, "id", concat_temp(name, "_lod")),
		prop_test_attr(b, "nickname", "lod"),
	}, {card_box(b), level})
	root = prop_test_node(b, "ROOTNODE", {
		prop_test_attr(b, "id", concat_temp(name, " Root")),
	}, {
		lod,
		prop_test_node(b, "NODE", {
			prop_test_attr(b, "id", concat_temp(name, "_default")),
			prop_test_attr(b, "nickname", "default"),
		}, nil),
		prop_test_node(b, "NODE", {
			prop_test_attr(b, "id", concat_temp(name, "_rigidbody")),
			prop_test_attr(b, "nickname", "rigidbody"),
		}, nil),
	})
	return
}

// A whole library: the clouds named, plus the one material every card names and
// the segment holder a graft clones.
@(private = "file")
card_library :: proc(
	b: ^Prop_Test_Builder, lib: ^Prop_Library, clouds: [][2]^Pssg_Node, roots: []^Pssg_Node, blocks: []^Pssg_Node,
) {
	sources := make([dynamic]^Pssg_Node, context.temp_allocator)
	for pair in clouds {
		append(&sources, prop_test_node(b, "SEGMENTSET", {
			prop_test_attr(b, "id", concat_temp(pssg_attr_string(&b.file, pair[0], "id"), "_segments")),
		}, {pair[0]}))
	}
	others := make([dynamic]^Pssg_Node, context.temp_allocator)
	append(&others, prop_test_node(b, "LIBRARY", {prop_test_attr(b, "type", "SEGMENTSET")}, sources[:]))
	append(&others, prop_test_node(b, "LIBRARY", {prop_test_attr(b, "type", "RENDERINTERFACEBOUND")}, blocks))
	append(&others, prop_test_node(b, "LIBRARY", {prop_test_attr(b, "type", "SHADERINSTANCE")}, {
		prop_test_node(b, "SHADERINSTANCE", {
			prop_test_attr(b, "id", "sheet_material"),
			prop_test_attr(b, "shaderGroup", "#treesheet_foliage.fx"),
		}, nil),
	}))
	prop_test_bind(b, lib, roots, others[:])
}

// Two clouds: a column atlas of single trees and a whole-sheet forest band. What
// separates the tiers is the atlas rectangle, not the name, so neither name says
// anything here.
@(private = "file")
two_tier_library :: proc(b: ^Prop_Test_Builder, lib: ^Prop_Library, extra_name := "") {
	prop_test_builder(b)
	near_root, near_source, near_block := card_cloud(b, "cloud_alpha", {{8, 20}, {9, 22}, {7, 18}}, 0.2)
	far_root, far_source, far_block := card_cloud(b, "cloud_beta", {{55, 28}, {60, 30}}, 1.0)
	clouds := make([dynamic][2]^Pssg_Node, context.temp_allocator)
	roots := make([dynamic]^Pssg_Node, context.temp_allocator)
	blocks := make([dynamic]^Pssg_Node, context.temp_allocator)
	append(&clouds, [2]^Pssg_Node{near_source, nil}, [2]^Pssg_Node{far_source, nil})
	append(&roots, near_root, far_root)
	append(&blocks, near_block, far_block)
	if extra_name != "" {
		root, source, block := card_cloud(b, extra_name, {{70, 34}}, 1.0)
		append(&clouds, [2]^Pssg_Node{source, nil})
		append(&roots, root)
		append(&blocks, block)
	}
	card_library(b, lib, clouds[:], roots[:], blocks[:])
}

@(private = "file")
places_at :: proc(n: int, card: int = 0) -> []Billboard_Place {
	out := make([]Billboard_Place, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = {pos = {f32(i) * 30, 0, f32(i) * 10}, card = card, scale = 1}
	}
	return out
}

// The tiers are read off the atlas rectangle. A card taking the whole sheet is a
// band of forest; a fraction of it is one tree out of a column.
@(test)
a_template_is_sorted_by_its_atlas_rectangle :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib)

	templates := billboard_templates(&lib, context.temp_allocator)
	testing.expect_value(t, len(templates), 2)

	near, near_ok := billboard_template_pick(templates, false)
	far, far_ok := billboard_template_pick(templates, true)
	testing.expect(t, near_ok && far_ok, "both tiers resolved")
	if !near_ok || !far_ok {
		return
	}
	testing.expect_value(t, near.name, "cloud_alpha")
	testing.expect_value(t, far.name, "cloud_beta")
	testing.expect_value(t, len(near.cards), 3)
	// And the sizes come off the art rather than out of this code.
	testing.expect_value(t, far.cards[1].w, 60)
	testing.expect_value(t, far.cards[1].h, 30)
}

// The authoring hook. A pack that ships its own sheet declares one cloud under
// the name below, and it wins over every stock cloud in the file however small it
// is — one card is enough to carry a rectangle and a material.
@(test)
a_declared_template_beats_the_stock_art :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib, BILLBOARD_TEMPLATE_FAR)

	templates := billboard_templates(&lib, context.temp_allocator)
	far, ok := billboard_template_pick(templates, true)
	testing.expect(t, ok, "the far tier resolved")
	if !ok {
		return
	}
	testing.expect_value(t, far.name, BILLBOARD_TEMPLATE_FAR)
	testing.expect_value(t, len(far.cards), 1)
}

// A grafted cloud: its own ids everywhere, the bounds a reference row quotes, and
// above all no id the file already had. A duplicate id hangs the load with no
// fault and no log line, so the writer refuses rather than producing one.
@(test)
a_grafted_cloud_has_its_own_ids :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib)
	templates := billboard_templates(&lib, context.temp_allocator)
	far, _ := billboard_template_pick(templates, true)

	roots_before := len(lib.props)
	cloud, msg, ok := billboard_cloud_write(&lib, far, "bb_r0_far_00", {0, 0, 0}, places_at(4), context.temp_allocator)
	testing.expectf(t, ok, "the graft failed: %s", msg)
	if !ok {
		return
	}
	testing.expect_value(t, cloud.cards, 4)
	testing.expect_value(t, len(lib.props), roots_before + 1)

	clash, clashed := billboard_duplicate_id(&lib)
	testing.expectf(t, !clashed, "the graft left two nodes with the id %s", clash)

	// The box has to contain every card turned any way around: a 55 m card at
	// x = 90 reaches 117.5, and the same width applies across z.
	testing.expect_value(t, cloud.hi[0], 117.5)
	testing.expect_value(t, cloud.lo[2], -27.5)
	// And the cloud is addressable by the name a placement row will quote.
	testing.expect(t, prop_lib_find(&lib, "bb_r0_far_00") != nil, "the cloud is not in the node library")
}

// A re-export replaces its own clouds and leaves everything else alone — the
// other routes of the venue share this file. Dropping only the root would leave
// its vertex payload behind and the file would grow every export.
@(test)
a_strip_takes_our_clouds_and_their_payloads :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib)
	templates := billboard_templates(&lib, context.temp_allocator)
	far, _ := billboard_template_pick(templates, true)

	blocks :: proc(lib: ^Prop_Library) -> int {
		for child in lib.file.root.children {
			if child.name == "LIBRARY" && pssg_attr_string(&lib.file, child, "type") == "RENDERINTERFACEBOUND" {
				return len(child.children)
			}
		}
		return -1
	}
	stock_roots, stock_blocks := len(lib.props), blocks(&lib)

	for name in ([]string{"bb_r0_far_00", "bb_r0_far_01", "bb_r1_far_00"}) {
		_, msg, ok := billboard_cloud_write(&lib, far, name, {0, 0, 0}, places_at(2), context.temp_allocator)
		testing.expectf(t, ok, "%s: %s", name, msg)
	}
	testing.expect_value(t, len(lib.props), stock_roots + 3)

	dropped := billboard_strip(&lib, "bb_r0_", context.temp_allocator)
	testing.expect_value(t, dropped, 2)
	testing.expect_value(t, len(lib.props), stock_roots + 1)
	testing.expect_value(t, blocks(&lib), stock_blocks + 1)
	testing.expect(t, prop_lib_find(&lib, "bb_r1_far_00") != nil, "another route's cloud was stripped")
	testing.expect(t, prop_lib_find(&lib, "cloud_beta") != nil, "the venue's own art was stripped")

	// And a second export of route 0 is a no-op on the file it already wrote.
	testing.expect_value(t, billboard_strip(&lib, "bb_r0_", context.temp_allocator), 0)
}

// The index buffer is `ushort`, so a cloud has a hard card cap. The caller chunks
// well below it; the writer refuses rather than wrapping silently.
@(test)
a_cloud_refuses_to_overflow_its_index_buffer :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib)
	templates := billboard_templates(&lib, context.temp_allocator)
	far, _ := billboard_template_pick(templates, true)

	_, _, ok := billboard_cloud_write(&lib, far, "bb_r0_far_00", {0, 0, 0}, places_at(BILLBOARD_CARDS_MAX + 1), context.temp_allocator,
	)
	testing.expect(t, !ok, "a cloud past the ushort cap was written anyway")
}

// A venue whose art draws no treesheet card has no template to clone, and that is
// an answer rather than an error: shibuya ships none, and nor need a pack.
@(test)
a_library_with_no_treesheet_art_offers_no_template :: proc(t: ^testing.T) {
	b: Prop_Test_Builder
	lib: Prop_Library
	two_tier_library(&b, &lib)

	material := lib.by_id["sheet_material"]
	testing.expect(t, material != nil, "the fixture has no material to repoint")
	if material == nil {
		return
	}
	pssg_set_attr_string(&lib.file, material, "shaderGroup", "#object.fx", context.temp_allocator)

	templates := billboard_templates(&lib, context.temp_allocator)
	testing.expect_value(t, len(templates), 0)
	_, near_ok := billboard_template_pick(templates, false)
	_, far_ok := billboard_template_pick(templates, true)
	testing.expect(t, !near_ok && !far_ok, "a tier resolved off art that draws no cards")
}
