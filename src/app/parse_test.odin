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
