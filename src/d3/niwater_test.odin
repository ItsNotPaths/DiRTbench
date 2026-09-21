package d3

import "core:strings"
import "core:testing"

// A stock `niwater.pssg` cut down by `tools/water_fixture.py`: the two shader
// libraries, the three textures with 16x16 stub payloads, and one stock lake.
// Trimmed by a separate implementation, so the writer below is checked against
// a file it did not produce.
//
// The lake is load-bearing twice over. `pssg_types` scans the tree rather than
// the schema, so a donor with no geometry cannot say what a DATABLOCKSTREAM is;
// and it gives these tests a stock body to watch being dropped.
//
// Not in the repository, for the same reason as the Moosylvania fixture: see
// credits.txt. The load survives its absence and the tests report it.
D3_FIXTURE_WATER :: #load("../../assets/d3/water-materials.pssg", []u8) or_else []u8{}

WATER_FIXTURE_MISSING :: "assets/d3/water-materials.pssg is not in the repository; see credits.txt"

// A square, wound so the two triangles face +Y like every stock water face.
test_water_square :: proc(name: string, y, half: f32, allocator := context.allocator) -> D3_Water_Body {
	points := make([][2]f32, 4, allocator)
	points[0] = {-half, -half}
	points[1] = {-half, half}
	points[2] = {half, -half}
	points[3] = {half, half}
	tris := make([][3]u32, 2, allocator)
	tris[0] = {0, 1, 2}
	tris[1] = {3, 2, 1}
	return {name = name, y = y, points = points, tris = tris}
}

test_water_read :: proc(t: ^testing.T, bytes: []u8) -> (Pssg_File, bool) {
	file, msg, ok := pssg_read(bytes, context.temp_allocator)
	testing.expect(t, ok, msg)
	return file, ok
}

@(test)
niwater_xml_with_no_bodies_is_the_stock_stub :: proc(t: ^testing.T) {
	out := d3_niwater_xml(nil, context.temp_allocator)
	testing.expect_value(t, string(out), D3_STUB_INTERACTIVE_WATER)
}

@(test)
niwater_xml_numbers_its_patches_from_zero :: proc(t: ^testing.T) {
	bodies := []D3_Water_Body {
		test_water_square("water_00", 0, 10, context.temp_allocator),
		test_water_square("water_01", 0, 10, context.temp_allocator),
	}
	got := string(d3_niwater_xml(bodies, context.temp_allocator))
	want := "<interactiveWater>\r\n" +
		"  <interactiveWaterPatch index=\"0\" uri=\"niwater.pssg#water_00\" type=\"water\" />\r\n" +
		"  <interactiveWaterPatch index=\"1\" uri=\"niwater.pssg#water_01\" type=\"water\" />\r\n" +
		"</interactiveWater>"
	testing.expect_value(t, got, want)
}

// A file with no bodies pairs with an empty patch list, and that pairing
// faults at load wherever `waterdefs` survive.
@(test)
niwater_refuses_to_build_an_empty_scene :: proc(t: ^testing.T) {
	_, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, nil, context.temp_allocator)
	testing.expect(t, !ok, "a water file with no bodies was built")
	testing.expect(t, strings.contains(msg, "faults at load"), msg)
}

@(test)
niwater_writes_one_rendernode_per_body :: proc(t: ^testing.T) {
	bodies := []D3_Water_Body {
		test_water_square("water_00", -1.5, 30, context.temp_allocator),
		test_water_square("water_01", 4, 10, context.temp_allocator),
	}
	out, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, bodies, context.temp_allocator)
	testing.expect(t, ok, msg)
	if !ok { return }
	file, read_ok := test_water_read(t, out)
	if !read_ok { return }

	all := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &all)
	drawn := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]int, context.temp_allocator)
	blocks, sets := 0, 0
	for node in all {
		if node.name == "RENDERNODE" { append(&drawn, pssg_attr_string(&file, node, "id")) }
		if node.name == "DATABLOCK" { blocks += 1 }
		if node.name == "SEGMENTSET" { sets += 1 }
		id := pssg_attr_string(&file, node, "id")
		if id != "" { seen[id] += 1 }
	}
	testing.expect_value(t, len(drawn), 2)
	testing.expect_value(t, blocks, 2)
	testing.expect_value(t, sets, 2)
	testing.expect_value(t, drawn[0], "water_00")
	testing.expect_value(t, drawn[1], "water_01")
	// The donor's own lake goes with them. Ours is a derived venue and the
	// donor's coordinates are somewhere else entirely in our world.
	testing.expect(
		t,
		pssg_walk_first_by_id(&file, file.root, "RENDERNODE", "lake_8") == nil,
		"the donor's own lake survived into our stage",
	)
	textures := 0
	for node in all { if node.name == "TEXTURE" { textures += 1 } }
	testing.expect_value(t, textures, 3)
	// A duplicate id hangs the load, and minted ids must not collide with the
	// donor's own.
	for id, count in seen {
		testing.expectf(t, count == 1, "id %q appears %d times", id, count)
	}
}

// Every count a reader trusts is derived from the same buffer it describes.
@(test)
niwater_counts_agree_with_the_buffers :: proc(t: ^testing.T) {
	body := test_water_square("water_00", 2, 25, context.temp_allocator)
	out, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, []D3_Water_Body{body}, context.temp_allocator)
	testing.expect(t, ok, msg)
	if !ok { return }
	file, read_ok := test_water_read(t, out)
	if !read_ok { return }

	all := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &all)
	for node in all {
		switch node.name {
		case "DATABLOCK":
			size, _ := pssg_attr_u32(&file, node, "size")
			count, _ := pssg_attr_u32(&file, node, "elementCount")
			streams, _ := pssg_attr_u32(&file, node, "streamCount")
			testing.expect_value(t, streams, u32(6))
			testing.expect_value(t, count, u32(4))
			testing.expect_value(t, size, u32(4 * D3_WATER_STRIDE))
			data := pssg_walk_first(node, "DATABLOCKDATA")
			testing.expect(t, data != nil, "a DATABLOCK with no payload")
			if data != nil { testing.expect_value(t, len(data.data), int(size)) }
		case "RENDERINDEXSOURCE":
			count, _ := pssg_attr_u32(&file, node, "count")
			highest, _ := pssg_attr_u32(&file, node, "maximumIndex")
			testing.expect_value(t, count, u32(6))
			testing.expect_value(t, highest, u32(3))
			data := pssg_walk_first(node, "INDEXSOURCEDATA")
			testing.expect(t, data != nil, "an index source with no payload")
			if data != nil { testing.expect_value(t, len(data.data), int(count) * 2) }
		}
	}
}

// Water is the exception to dirt3-pssg-flat-bbox: stock water nodes are flat
// in Y and draw.
@(test)
niwater_boxes_are_the_vertex_extent_and_stay_flat :: proc(t: ^testing.T) {
	body := test_water_square("water_00", -3, 20, context.temp_allocator)
	out, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, []D3_Water_Body{body}, context.temp_allocator)
	testing.expect(t, ok, msg)
	if !ok { return }
	file, read_ok := test_water_read(t, out)
	if !read_ok { return }

	node := pssg_walk_first_by_id(&file, file.root, "RENDERNODE", "water_00")
	testing.expect(t, node != nil, "the body was not written")
	if node == nil { return }
	box := pssg_walk_first(node, "BOUNDINGBOX")
	testing.expect(t, box != nil, "the body has no box")
	if box == nil || len(box.data) < 24 { return }
	lo, hi: [3]f32
	for k in 0 ..< 3 {
		lo[k] = binary_load_f32(box.data, k * 4, .Big)
		hi[k] = binary_load_f32(box.data, 12 + k * 4, .Big)
	}
	testing.expect_value(t, lo, [3]f32{-20, -3, -20})
	testing.expect_value(t, hi, [3]f32{20, -3, 20})
}

@(test)
niwater_refuses_a_body_it_cannot_draw :: proc(t: ^testing.T) {
	bad := test_water_square("water_00", 0, 20, context.temp_allocator)
	bad.tris = bad.tris[:0]
	_, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, []D3_Water_Body{bad}, context.temp_allocator)
	testing.expect(t, !ok, "an untriangulated body was accepted")
	testing.expect(t, strings.contains(msg, "water_00"), msg)

	thin := test_water_square("water_01", 0, 20, context.temp_allocator)
	thin.points[2][0] = -20
	thin.points[3][0] = -20
	_, thin_msg, thin_ok := d3_niwater_build(D3_FIXTURE_WATER, []D3_Water_Body{thin}, context.temp_allocator)
	testing.expect(t, !thin_ok, "a body with no width was accepted")
	testing.expect(t, strings.contains(thin_msg, "thin"), thin_msg)

	over := test_water_square("water_02", 0, 20, context.temp_allocator)
	over.tris[0] = {0, 1, 9}
	_, over_msg, over_ok := d3_niwater_build(D3_FIXTURE_WATER, []D3_Water_Body{over}, context.temp_allocator)
	testing.expect(t, !over_ok, "a triangle pointing past the last vertex was accepted")
	testing.expect(t, strings.contains(over_msg, "indexes point"), over_msg)
}

// The xml addresses a body by name, so two of a name would draw one and lose
// the other, and two nodes of an id hang the load outright.
@(test)
niwater_refuses_two_bodies_of_one_name :: proc(t: ^testing.T) {
	bodies := []D3_Water_Body {
		test_water_square("pond", 0, 20, context.temp_allocator),
		test_water_square("pond", 0, 30, context.temp_allocator),
	}
	_, msg, ok := d3_niwater_build(D3_FIXTURE_WATER, bodies, context.temp_allocator)
	testing.expect(t, !ok, "two bodies of one name were accepted")
	testing.expect(t, strings.contains(msg, "pond"), msg)
}
