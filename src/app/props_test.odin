package main

// Hand-placed props: what survives a save, and what a click can hit.
//
// Nothing here opens a prop library. The geometry side is d3's (prop_lib_test);
// this is the document's half — the placements themselves.

import "core:os"
import "core:strings"
import "core:testing"
import "../geo"
import "../gfx"

@(test)
props_round_trip_through_road_json :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.spline_free(&doc.spline)
	defer props_free(&doc)
	seed_spline(&doc.spline)
	prop_place(&doc, {kind = .Objects_Pssg, name = "core_barr_haybale_e"}, .Object, {12, 3, -40})
	prop_place(&doc, {kind = .Trees_Pssg, name = "birch_full_01_a"}, .Ornament, {0, 1, 0})
	doc.props[0].rot = gfx.QuaternionFromAxisAngle({0, 1, 0}, 1.2)
	doc.props[0].scale = 2.5

	path := "/tmp/claude-1000/dirtbench-props-roundtrip.json"
	defer os.remove(path)
	if _, ok := save_road(&doc, path); !ok {
		testing.fail_now(t, "could not write the road")
	}

	back := doc_defaults()
	defer geo.spline_free(&back.spline)
	defer props_free(&back)
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back")
	}
	testing.expect_value(t, len(back.props), 2)
	testing.expect_value(t, back.props[0].ref.name, "core_barr_haybale_e")
	testing.expect_value(t, back.props[0].ref.kind, Prop_Lib_Kind.Objects_Pssg)
	testing.expect_value(t, back.props[0].pos, gfx.Vector3{12, 3, -40})
	testing.expect_value(t, back.props[0].scale, f32(2.5))
	testing.expect(
		t,
		gfx.Vector3Distance(
			gfx.Vector3RotateByQuaternion({1, 0, 0}, back.props[0].rot),
			gfx.Vector3RotateByQuaternion({1, 0, 0}, doc.props[0].rot),
		) < 1e-5,
		"the prop came back facing a different way",
	)
	// Which library a prop came from is part of its identity: the two files are
	// separate namespaces, and a tree resolved against objects.pssg is a miss.
	testing.expect_value(t, back.props[1].ref.kind, Prop_Lib_Kind.Trees_Pssg)
	// So is the role. It decides whether the prop gets an objects.ens body, and
	// the two placements above were dropped from different browsers.
	testing.expect_value(t, back.props[0].role, Prop_Role.Object)
	testing.expect_value(t, back.props[1].role, Prop_Role.Ornament)

	// A second load must not stack them up.
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back twice")
	}
	testing.expect_value(t, len(back.props), 2)
}

// A road with no props opens with none, whatever the document held.
@(test)
a_road_without_props_loads_as_none :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.spline_free(&doc.spline)
	defer props_free(&doc)
	seed_spline(&doc.spline)

	path := "/tmp/claude-1000/dirtbench-props-absent.json"
	defer os.remove(path)
	if _, ok := save_road(&doc, path); !ok {
		testing.fail_now(t, "could not write the road")
	}

	back := doc_defaults()
	defer geo.spline_free(&back.spline)
	defer props_free(&back)
	prop_place(&back, {kind = .Objects_Pssg, name = "left_over"}, .Object, {1, 1, 1})
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back")
	}
	testing.expect_value(t, len(back.props), 0)
}
