package main

// Tests for the hand-rolled parsers. These are the pieces that fail *quietly*:
// a config parser that mis-splits a line points the tool at the wrong game
// directory, and a cliff envelope off by a metre just looks like terrain.
// Everything else in this package fails loudly, in the viewport, on the frame
// you break it.
//
// Run with `odin test src/app`.

import "core:testing"
import "../geo"

// --- config grammar ----------------------------------------------------------

@(test)
config_reads_every_shape :: proc(t: ^testing.T) {
	src := "# a comment\n\nitems_dir = /games/My Documents/Items\noffset=0 8 0\n   spaced   =   v   \n"
	it := Config_Iter{src}

	k, v, ok := config_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, k, "items_dir")
	// A value runs to the end of the line, spaces and all: game paths contain them.
	testing.expect_value(t, v, "/games/My Documents/Items")

	k, v, ok = config_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, k, "offset")
	testing.expect_value(t, v, "0 8 0")

	k, v, ok = config_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, k, "spaced")
	testing.expect_value(t, v, "v")

	_, _, ok = config_next(&it)
	testing.expect(t, !ok, "the iterator must end after the last entry")
}

@(test)
config_reports_a_line_with_no_equals :: proc(t: ^testing.T) {
	it := Config_Iter{"garbage\n"}
	k, v, ok := config_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, k, "garbage")
	// Empty value is how a caller tells a malformed line from a real entry.
	testing.expect_value(t, v, "")
}

@(test)
config_value_may_contain_equals :: proc(t: ^testing.T) {
	it := Config_Iter{"maps_dir = C:/x=y/Maps\n"}
	k, v, _ := config_next(&it)
	testing.expect_value(t, k, "maps_dir")
	testing.expect_value(t, v, "C:/x=y/Maps")
}

// --- zip ---------------------------------------------------------------------

// --- cliff envelope ----------------------------------------------------------

@(test)
cliff_envelope_covers_its_span_and_no_more :: proc(t: ^testing.T) {
	// span 100, taper 20: plateau out to 30 m either side, zero at 50 m.
	testing.expect_value(t, geo.cliff_envelope(0, 100, 20), 1)
	testing.expect_value(t, geo.cliff_envelope(30, 100, 20), 1)
	testing.expect_value(t, geo.cliff_envelope(-30, 100, 20), 1) // symmetric about the point
	testing.expect_value(t, geo.cliff_envelope(50, 100, 20), 0)
	testing.expect_value(t, geo.cliff_envelope(80, 100, 20), 0)

	mid := geo.cliff_envelope(40, 100, 20)
	testing.expect(t, mid > 0 && mid < 1, "the taper must actually ramp")

	testing.expect_value(t, geo.cliff_envelope(0, 0, 20), 0) // no span, no cliff

	// A taper wider than half the span degenerates to a bump, never inverting.
	for d in ([]f32{0, 10, 24, 25, 40}) {
		v := geo.cliff_envelope(d, 50, 90)
		testing.expect(t, v >= 0 && v <= 1, "a fat taper must stay in [0,1]")
	}
	testing.expect_value(t, geo.cliff_envelope(0, 50, 90), 1)
	testing.expect_value(t, geo.cliff_envelope(25, 50, 90), 0)
}

// --- helper ------------------------------------------------------------------

// Raw-deflate `src` by round-tripping it through zlib and stripping the 2-byte
// header and 4-byte checksum, which is exactly the bare stream a zip member
// holds. Odin's core has an inflater but no deflater, so the fixture is built

// --- road edges at rest ------------------------------------------------------

// `parent` and `weld` are array positions in memory and point ids in the file.
// The two agree until a point is deleted, which is why every venue looked fine
// until one had been: a reader with only the file in front of it has nothing
// but the ids to go on.
//
// Three points whose ids are nothing like their positions, chained 0 <- 1 <- 2,
// with the last welded back to the first.
@(private = "file")
gapped_road :: proc(allocator := context.allocator) -> Venue_Road {
	pts := make([]Stage_Point, 3, allocator)
	pts[0] = {id = 40, parent = -1, weld = -1, pos = {0, 0, 0}, rot = {0, 0, 0, 1}, width = 8}
	pts[1] = {id = 41, parent = 40, weld = -1, pos = {0, 0, 10}, rot = {0, 0, 0, 1}, width = 8}
	pts[2] = {id = 99, parent = 41, weld = 40, pos = {0, 0, 20}, rot = {0, 0, 0, 1}, width = 8}
	return Venue_Road{points = pts}
}

@(test)
road_edges_survive_a_write_as_ids :: proc(t: ^testing.T) {
	road := gapped_road()
	defer delete(road.points)
	doc := Venue_Doc{}
	defer doc_delete(&doc)
	msg, ok := doc_load_road(&doc, road)
	testing.expectf(t, ok, "a road whose ids are not its indices would not load: %s", msg)

	// In memory the edges are positions.
	testing.expect_value(t, doc.spline.points[1].parent, 0)
	testing.expect_value(t, doc.spline.points[2].parent, 1)
	testing.expect_value(t, doc.spline.points[2].weld, 0)

	// On the way out they are ids again, so an independent reader can follow
	// them. Writing the position here is what made every upload fail.
	out := road_block(&doc, context.allocator)
	defer delete(out.points)
	testing.expect_value(t, out.points[0].parent, -1)
	testing.expect_value(t, out.points[1].parent, 40)
	testing.expect_value(t, out.points[2].parent, 41)
	testing.expect_value(t, out.points[2].weld, 40)
}

// The round trip is the property that matters: load, write, load again, and the
// graph is the same graph.
@(test)
a_gapped_road_round_trips :: proc(t: ^testing.T) {
	road := gapped_road()
	defer delete(road.points)
	first := Venue_Doc{}
	defer doc_delete(&first)
	msg, ok := doc_load_road(&first, road)
	testing.expectf(t, ok, "the road would not load: %s", msg)

	written := road_block(&first, context.allocator)
	defer delete(written.points)

	second := Venue_Doc{}
	defer doc_delete(&second)
	reload_msg, reloaded := doc_load_road(&second, written)
	testing.expectf(t, reloaded, "a written road would not load back: %s", reload_msg)

	testing.expect_value(t, len(second.spline.points), len(first.spline.points))
	for p, i in second.spline.points {
		testing.expect_value(t, p.id, first.spline.points[i].id)
		testing.expect_value(t, p.parent, first.spline.points[i].parent)
		testing.expect_value(t, p.weld, first.spline.points[i].weld)
	}
}

// A parent naming a point that is not in the file is the failure the site
// caught. The tool has to refuse it too, rather than resolve it to a position.
@(test)
a_road_edge_naming_no_point_is_refused :: proc(t: ^testing.T) {
	road := gapped_road()
	defer delete(road.points)
	doc := Venue_Doc{}
	defer doc_delete(&doc)

	road.points[2].parent = 70 // no such id, and a valid position in a 3-point road
	_, ok := doc_load_road(&doc, road)
	testing.expect(t, !ok, "a parent naming no point was accepted")

	// A parent later in the array is refused too: build_ribbon reads a parent's
	// frame before the point that hangs off it.
	road.points[2].parent = 41
	road.points[1].parent = 99
	_, ok = doc_load_road(&doc, road)
	testing.expect(t, !ok, "a parent further down the array was accepted")
}
