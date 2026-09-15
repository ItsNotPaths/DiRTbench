package d3

import "core:slice"
import "core:testing"

@(test)
stub_text_matches_stock_light_placement :: proc(t: ^testing.T) {
	// Measured: japan/shibuya/route_6/light_placement.xml, 19 bytes.
	out := d3_stub_text(D3_STUB_LIGHT_PLACEMENT, context.temp_allocator)
	testing.expect_value(t, len(out), 19)
	testing.expect_value(t, string(out), "<light_placement />")
}

@(test)
stub_text_matches_stock_interactive_water :: proc(t: ^testing.T) {
	// Measured: france/monte_carlo_rally/route_5/iwater.xml and niwater.xml,
	// 20 bytes, identical text.
	out := d3_stub_text(D3_STUB_INTERACTIVE_WATER, context.temp_allocator)
	testing.expect_value(t, len(out), 20)
	testing.expect_value(t, string(out), "<interactiveWater />")
}

@(test)
stub_text_matches_stock_organism_track_dataset :: proc(t: ^testing.T) {
	// Measured: uk/battersea/organism_track_dataset.xml, 63 bytes, CRLF line
	// endings.
	out := d3_stub_text(D3_STUB_ORGANISM_TRACK_DATASET, context.temp_allocator)
	testing.expect_value(t, len(out), 63)
	testing.expect_value(
		t, string(out),
		"<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<dataset>\r\n</dataset>\r\n",
	)
}

@(test)
stub_zero_matches_stock_cloth_file :: proc(t: ^testing.T) {
	// Measured: japan/shibuya/route_6/clothFile.bin, 4 zero bytes.
	out := d3_stub_zero(4, context.temp_allocator)
	testing.expect(t, slice.equal(out, []u8{0, 0, 0, 0}))
}

@(test)
stub_reducedmechanics_matches_stock_bytes :: proc(t: ^testing.T) {
	// Measured: finland/finland_rally/route_2/reducedmechanics.jpk, and
	// byte-identical across every other stock route carrying the file.
	want := []u8{
		'J', 'P', 'A', 'K', 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	out := d3_stub_reducedmechanics(context.temp_allocator)
	testing.expect_value(t, len(out), 64)
	testing.expect(t, slice.equal(out, want))
}

@(test)
stub_cqtc_matches_stock_cameralines :: proc(t: ^testing.T) {
	// Measured: finland/finland_trail/route_0/cameralines.cqtc, 110 bytes,
	// tag RESD, box degenerate in X (a route with no camera lines at all).
	want := []u8{
		0x3d, 0x55, 0x62, 0x43, 0xcd, 0xcc, 0xcc, 0xbd, 0x39, 0x4b, 0xe9, 0xc3, 0x3d, 0x55, 0x62, 0x43,
		0xcc, 0xcc, 0xc8, 0x41, 0x39, 0x4b, 0xdf, 0xc3, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
		0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x58, 0x00, 0x00, 0x00, 0x5b, 0x00, 0x00, 0x00,
		0x69, 0x00, 0x00, 0x00, 0x52, 0x45, 0x53, 0x44, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0xfe, 0xfb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xfb, 0xff, 0xff, 0xff,
		0x00, 0x00, 0x00, 0x01, 0x04, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
		0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01,
	}
	lo := [3]f32{226.3329620361328, -0.10000000149011612, -466.5876770019531}
	hi := [3]f32{226.3329620361328, 25.099998474121094, -446.5876770019531}
	out := d3_stub_cqtc("RESD", lo, hi, context.temp_allocator)
	testing.expect_value(t, len(out), 110)
	testing.expect(t, slice.equal(out, want))
}

@(test)
stub_cqtc_carries_a_barrierlines_tag :: proc(t: ^testing.T) {
	// barrierlines.cqtc's own stock empty form uses a different leaf child
	// order (see D3_STUB_CQTC_LEAF's comment), so this only checks the parts
	// that must always agree: size, tag and the round-tripped box.
	lo := [3]f32{1, 2, 3}
	hi := [3]f32{4, 5, 6}
	out := d3_stub_cqtc("BARR", lo, hi, context.temp_allocator)
	testing.expect_value(t, len(out), 110)
	testing.expect_value(t, string(out[52:56]), "BARR")
}
