package d3

import "core:slice"
import "core:testing"

// A minimal, hand-built objects.ens-shaped file: not real game bytes, but it
// exercises every one of the three node shapes (self-close, text, children)
// and a self-closing child nested inside a container, which is all the real
// format's five tag kinds reduce to.
d3_test_ens_file :: proc() -> []u8 {
	return transmute([]u8)string(
		ENS_HEADER +
		"\t\t<TEMPLATEENTITYREFERENCE id=\"alpha\" uri=\"objecttypes.pssg#alpha.max\" allocAlt=\"5\" />\r\n" +
		"\t\t<TEMPLATEENTITYINSTANCE id=\"alpha_00\" instanceID=\"0\" uri=\"#alpha\" instance_tag=\"100\">\r\n" +
		"\t\t\t<TEMPLATETRANSFORM>1 0 0 0 0 1 0 0 0 0 1 0 10 20 30 1 </TEMPLATETRANSFORM>\r\n" +
		"\t\t</TEMPLATEENTITYINSTANCE>\r\n" +
		"\t\t<TEMPLATEBASICENTITYINSTANCE id=\"tree_00\" uri=\"#pine\" instance_tag=\"200\">\r\n" +
		"\t\t\t<TEMPLATETRANSFORM>1 0 0 0 0 1 0 0 0 0 1 0 5 5 5 1 </TEMPLATETRANSFORM>\r\n" +
		"\t\t</TEMPLATEBASICENTITYINSTANCE>\r\n" +
		"\t\t<TEMPLATECLOTHTYPEPOOL id=\"cloth1\" file=\"tape.xml\" shaderfront=\"objects.pssg#front\" shaderback=\"objects.pssg#back\" />\r\n" +
		"\t\t<TEMPLATECLOTHINSTANCE id=\"tape_00\" uri=\"#cloth1\" startsActive=\"0\" collisionDetection=\"1\">\r\n" +
		"\t\t\t<TEMPLATECLOTHATTACHINSTANCE instance=\"#pole_00\" name=\"leftA\" />\r\n" +
		"\t\t\t<TEMPLATECLOTHATTACHINSTANCE instance=\"#pole_01\" name=\"rightA\" />\r\n" +
		"\t\t</TEMPLATECLOTHINSTANCE>\r\n" +
		ENS_FOOTER,
	)
}

@(test)
ens_static_vis_ids_reads_only_flagged_instances :: proc(t: ^testing.T) {
	nodes := []Ens_Node{
		{tag = "TEMPLATEENTITYINSTANCE", attrs = []Ens_Attr{{"instanceID", "411"}, {"staticVis", "1"}}},
		{tag = "TEMPLATEENTITYINSTANCE", attrs = []Ens_Attr{{"instanceID", "412"}}}, // not flagged
		{tag = "TEMPLATEBASICENTITYINSTANCE", attrs = []Ens_Attr{{"instanceID", "413"}, {"staticVis", "1"}}}, // wrong tag
		{tag = "TEMPLATEENTITYINSTANCE", attrs = []Ens_Attr{{"instanceID", "588"}, {"staticVis", "1"}}},
	}
	ids, ok := d3_ens_static_vis_ids(nodes, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0], u32(411))
	testing.expect_value(t, ids[1], u32(588))
}

@(test)
ens_static_vis_ids_fails_closed_without_an_instance_id :: proc(t: ^testing.T) {
	nodes := []Ens_Node{
		{tag = "TEMPLATEENTITYINSTANCE", attrs = []Ens_Attr{{"staticVis", "1"}}}, // flagged, no instanceID
	}
	_, ok := d3_ens_static_vis_ids(nodes, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
ens_round_trips_byte_exact :: proc(t: ^testing.T) {
	original := d3_test_ens_file()
	nodes, parse_ok := d3_ens_parse(original, context.temp_allocator)
	testing.expect(t, parse_ok)
	testing.expect_value(t, len(nodes), 5)

	rebuilt := d3_ens_emit(nodes, context.temp_allocator)
	testing.expect(t, slice.equal(rebuilt, original))
}

@(test)
ens_parse_reads_every_node_shape :: proc(t: ^testing.T) {
	nodes, ok := d3_ens_parse(d3_test_ens_file(), context.temp_allocator)
	testing.expect(t, ok)

	testing.expect_value(t, nodes[0].tag, "TEMPLATEENTITYREFERENCE")
	testing.expect_value(t, nodes[0].content, Ens_Content.Self_Close)
	uri, uri_ok := ens_attr(nodes[0], "uri")
	testing.expect(t, uri_ok)
	testing.expect_value(t, uri, "objecttypes.pssg#alpha.max")

	testing.expect_value(t, nodes[1].tag, "TEMPLATEENTITYINSTANCE")
	testing.expect_value(t, nodes[1].content, Ens_Content.Children)
	testing.expect_value(t, len(nodes[1].children), 1)
	testing.expect_value(t, nodes[1].children[0].tag, "TEMPLATETRANSFORM")
	testing.expect_value(t, nodes[1].children[0].content, Ens_Content.Text)
	testing.expect_value(t, nodes[1].children[0].text, "1 0 0 0 0 1 0 0 0 0 1 0 10 20 30 1 ")

	instance_id, id_ok := ens_attr(nodes[1], "instanceID")
	testing.expect(t, id_ok)
	testing.expect_value(t, instance_id, "0")

	// TEMPLATEBASICENTITYINSTANCE: same Children shape, no instanceID at all.
	_, basic_has_instance_id := ens_attr(nodes[2], "instanceID")
	testing.expect(t, !basic_has_instance_id)

	testing.expect_value(t, nodes[4].tag, "TEMPLATECLOTHINSTANCE")
	testing.expect_value(t, len(nodes[4].children), 2)
	testing.expect_value(t, nodes[4].children[0].content, Ens_Content.Self_Close)
	name, name_ok := ens_attr(nodes[4].children[1], "name")
	testing.expect(t, name_ok)
	testing.expect_value(t, name, "rightA")
}

// The safe way to rewrite objects.ens: parse, filter/append plain Odin
// slices, re-emit — never bespoke per-field bookkeeping, since every record
// here is self-contained (no offsets or a shared string pool to keep in
// step, unlike trees.bin/ornaments.bin).
@(test)
ens_edit_by_filtering_and_appending_nodes :: proc(t: ^testing.T) {
	nodes, ok := d3_ens_parse(d3_test_ens_file(), context.temp_allocator)
	testing.expect(t, ok)

	kept := make([dynamic]Ens_Node, context.temp_allocator)
	for n in nodes {
		id, has_id := ens_attr(n, "id")
		if has_id && id == "alpha_00" { continue } // remove this one instance
		append(&kept, n)
	}
	append(&kept, Ens_Node{
		tag = "TEMPLATEENTITYINSTANCE",
		attrs = []Ens_Attr{{"id", "alpha_01"}, {"instanceID", "1"}, {"uri", "#alpha"}, {"instance_tag", "101"}},
		content = .Children,
		children = []Ens_Node{{
			tag = "TEMPLATETRANSFORM", content = .Text,
			text = "1 0 0 0 0 1 0 0 0 0 1 0 40 20 30 1 ",
		}},
	})

	rebuilt, rebuilt_ok := d3_ens_parse(d3_ens_emit(kept[:], context.temp_allocator), context.temp_allocator)
	testing.expect(t, rebuilt_ok)
	testing.expect_value(t, len(rebuilt), 5) // 4 originals minus 1 removed, plus 1 added

	found_old, found_new := false, false
	for n in rebuilt {
		id, has_id := ens_attr(n, "id")
		if !has_id { continue }
		if id == "alpha_00" { found_old = true }
		if id == "alpha_01" { found_new = true }
	}
	testing.expect(t, !found_old)
	testing.expect(t, found_new)
}
