package main

import "core:math"
import "core:testing"
import "../geo"
import "../gfx"

// A straight chain of `n` points, 20 m apart along +Z, flat and level.
road_brush_fixture :: proc(n: int) -> (doc: Venue_Doc) {
	for i in 0 ..< n {
		at := gfx.Vector3{0, 0, f32(i) * 20}
		rot := gfx.Quaternion(1)
		if i > 0 {
			rot = geo.heading_quat({0, 0, f32(i - 1) * 20}, at)
		}
		geo.spline_push(&doc.spline, geo.make_point(at, rot, geo.DEFAULT_WIDTH, parent = i - 1))
	}
	return
}

// `n` points on a 20 m circle, each aimed at the next. Consecutive points are
// ~21 m apart, and the head and the tail are that far apart too, so welding
// them closes a ring whose short way round is one edge.
road_ring_fixture :: proc(n: int) -> (doc: Venue_Doc) {
	for i in 0 ..< n {
		a := f32(i) * 2 * math.PI / f32(n)
		at := gfx.Vector3{math.cos(a) * 20, 0, math.sin(a) * 20}
		geo.spline_push(&doc.spline, geo.make_point(at, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
	for i in 0 ..< n {
		nxt := (i + 1) %% n
		doc.spline.points[i].xform.rotation = geo.heading_quat(
			doc.spline.points[i].xform.translation,
			doc.spline.points[nxt].xform.translation,
		)
	}
	return
}

// One gizmo drag of the anchor, as the gizmo would leave it: shifted by `by`
// and turned by `turn` in the anchor's own frame.
road_brush_drag :: proc(ed: ^Editor, anchor: int, by: gfx.Vector3, turn := gfx.Quaternion(1)) {
	base := ed.road_brush_snap[anchor]
	road_brush_move(
		ed, anchor,
		{translation = base.pos + by, rotation = base.rot * turn},
	)
}

road_brush_free :: proc(ed: ^Editor, doc: ^Venue_Doc) {
	delete(ed.road_brush_weight)
	delete(ed.road_brush_snap)
	delete(doc.spline.points)
}

// Distance is measured along the road and the weight tapers across it, so the
// anchor takes the whole move and the far end of the reach takes none.
@(test)
road_brush_falls_off_along_the_road :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6) // 0..100 m
	ed := Editor{doc = &doc, road_brush = {radius = 60}, road_brush_taper = 1}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	testing.expect_value(t, len(ed.road_brush_weight), 6)
	testing.expect_value(t, ed.road_brush_weight[0], f32(1))
	testing.expect(t, ed.road_brush_weight[1] < 1, "20 m along should take less than the anchor")
	testing.expect(
		t,
		ed.road_brush_weight[2] < ed.road_brush_weight[1],
		"the falloff should keep falling",
	)
	testing.expect_value(t, ed.road_brush_weight[3], f32(0)) // 60 m: the edge of the reach
	testing.expect_value(t, ed.road_brush_weight[4], f32(0))
	testing.expect_value(t, ed.road_brush_weight[5], f32(0))

	// A zero reach is a single-point brush, not an empty one.
	ed.road_brush.radius = 0
	road_brush_select(&ed, 2)
	testing.expect_value(t, ed.road_brush_weight[2], f32(1))
	testing.expect_value(t, ed.road_brush_weight[1], f32(0))
}

// Falloff at 0 is the hard edge the terrain brush cuts: everything in reach
// takes the whole move, everything past it takes none.
@(test)
road_brush_taper_zero_is_a_hard_edge :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 50}, road_brush_taper = 0}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	for i in 0 ..< 3 {
		testing.expect_value(t, ed.road_brush_weight[i], f32(1)) // 0, 20, 40 m
	}
	testing.expect_value(t, ed.road_brush_weight[3], f32(0)) // 60 m
}

// A weld is road, so the brush runs over it into what it joins. The fixture is
// a closed ring: over the weld the last point is one edge from the first, and
// the long way round it is five.
@(test)
road_brush_reaches_over_a_weld :: proc(t: ^testing.T) {
	doc := road_ring_fixture(6) // six 21 m edges
	ed := Editor{doc = &doc, road_brush = {radius = 50}, road_brush_taper = 0}
	defer road_brush_free(&ed, &doc)

	// Unwelded the ring is still a chain, so the far end is five edges away.
	road_brush_select(&ed, 0)
	testing.expect_value(t, ed.road_brush_weight[2], f32(1)) // 42 m
	testing.expect_value(t, ed.road_brush_weight[4], f32(0)) // 84 m the only way there
	testing.expect_value(t, ed.road_brush_weight[5], f32(0)) // 106 m

	testing.expect(t, geo.weld_points(&doc.spline, 5, 0), "the fixture did not close")
	road_brush_select(&ed, 0)
	testing.expect_value(t, ed.road_brush_weight[5], f32(1)) // 21 m over the weld
	testing.expect_value(t, ed.road_brush_weight[4], f32(1)) // 42 m
	testing.expect_value(t, ed.road_brush_weight[3], f32(0)) // 63 m, the far side either way

}

// A move is measured from the snapshot, so dragging back and forth replaces the
// move rather than stacking on it, and every point takes its own share of it.
@(test)
road_brush_move_is_weighted_and_absolute :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 50}, road_brush_taper = 0}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	road_brush_snapshot(&ed)
	road_brush_drag(&ed, 0, {0, 10, 0})
	testing.expect_value(t, doc.spline.points[0].xform.translation.y, f32(10))
	testing.expect_value(t, doc.spline.points[2].xform.translation.y, f32(10))
	testing.expect_value(t, doc.spline.points[3].xform.translation.y, f32(0))

	road_brush_drag(&ed, 0, {0, 4, 0})
	testing.expect_value(t, doc.spline.points[0].xform.translation.y, f32(4))
	testing.expect_value(t, doc.spline.points[3].xform.translation.y, f32(0))

	// A move the gizmo made sideways travels the selection the same way a
	// lift does: the axis is the gizmo's business, the share is the brush's.
	road_brush_drag(&ed, 0, {12, 0, 0})
	testing.expect_value(t, doc.spline.points[0].xform.translation.x, f32(12))
	testing.expect_value(t, doc.spline.points[2].xform.translation.x, f32(12))
	testing.expect_value(t, doc.spline.points[3].xform.translation.x, f32(0))
	testing.expect_value(t, doc.spline.points[0].xform.translation.y, f32(0))
}

// The point of the falloff: a climb whose control points are pitched into it,
// rather than one that flattens at every point and pulses the gradient between
// them. The pitch each point ends at is the slope of the road through it.
@(test)
road_brush_pitches_the_points_it_lifts :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 100}, road_brush_taper = 1}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	road_brush_snapshot(&ed)
	for p in doc.spline.points {
		testing.expect(t, abs(geo.point_forward(p).y) < 1e-5, "the fixture should start level")
	}

	road_brush_drag(&ed, 0, {0, 30, 0})
	for i in 1 ..< 5 {
		p := doc.spline.points[i]
		slope := road_point_tangent(doc.spline, i)
		fwd := geo.point_forward(p)
		want := gfx.Vector3Normalize(slope)
		testing.expect(
			t,
			gfx.Vector3Distance(fwd, want) < 1e-3,
			"a lifted point was not pitched onto the slope through it",
		)
		testing.expect(t, fwd.y < 0, "the road falls away from the anchor, so it should pitch down")
	}
}

// The frame's roll about its own heading: the angle from the level up for that
// heading to the up the point actually carries.
point_roll :: proc(p: geo.Point) -> f32 {
	f := geo.point_forward(p)
	right_ref := gfx.Vector3Normalize(gfx.Vector3CrossProduct({0, 1, 0}, f))
	up_ref := gfx.Vector3CrossProduct(f, right_ref)
	up := geo.point_up(p)
	return math.atan2(
		gfx.Vector3DotProduct(gfx.Vector3CrossProduct(up_ref, up), f),
		gfx.Vector3DotProduct(up_ref, up),
	)
}

// Turning a point is the shortest arc onto its new slope, applied in world
// space, so whatever bank it was carrying comes along rather than being
// flattened out. Its up vector must tilt — it is pitched now — but its roll
// about its own heading must not move.
@(test)
road_brush_keeps_the_bank_it_found :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 100}, road_brush_taper = 1}
	defer road_brush_free(&ed, &doc)

	bank := f32(math.to_radians(f32(20)))
	p := &doc.spline.points[2]
	p.xform.rotation = gfx.QuaternionFromAxisAngle(geo.point_forward(p^), bank) * p.xform.rotation
	testing.expect(t, abs(point_roll(p^) - bank) < 1e-4, "the fixture did not bank")

	road_brush_select(&ed, 0)
	road_brush_snapshot(&ed)
	road_brush_drag(&ed, 0, {0, 30, 0})

	after := doc.spline.points[2]
	testing.expect(t, abs(point_roll(after) - bank) < 1e-3, "the bank was flattened by the lift")
	testing.expect(t, geo.point_forward(after).y < -0.1, "the point was not pitched onto the fall")
	testing.expect(
		t,
		abs(gfx.Vector3DotProduct(geo.point_up(after), geo.point_forward(after))) < 1e-3,
		"the frame lost its right angle",
	)
}

// A lone point has no edge either side, so there is no slope to turn it onto
// and no reason for the lift to produce a NaN.
@(test)
road_brush_lifts_a_lone_point :: proc(t: ^testing.T) {
	doc := road_brush_fixture(1)
	ed := Editor{doc = &doc, road_brush = {radius = 50}, road_brush_taper = 1}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	road_brush_snapshot(&ed)
	road_brush_drag(&ed, 0, {0, 7, 0})
	testing.expect_value(t, doc.spline.points[0].xform.translation.y, f32(7))
	testing.expect(t, geo.point_forward(doc.spline.points[0]).y == 0, "a lone point was turned")
}

// A roll of the anchor is a roll of every point about its own heading, not
// about the anchor's. The fixture is a ring so the two are not the same thing:
// a point a third of the way round it faces nothing like the anchor does.
@(test)
road_brush_shares_a_turn_in_each_points_own_frame :: proc(t: ^testing.T) {
	doc := road_ring_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 80}, road_brush_taper = 1}
	defer road_brush_free(&ed, &doc)

	road_brush_select(&ed, 0)
	road_brush_snapshot(&ed)
	for p in doc.spline.points {
		testing.expect(t, abs(point_roll(p)) < 1e-4, "the ring should start level")
	}

	bank := f32(math.to_radians(f32(20)))
	fwd := geo.point_forward(doc.spline.points[0])
	road_brush_drag(&ed, 0, {}, gfx.QuaternionFromAxisAngle({0, 0, 1}, bank))
	testing.expect(
		t,
		gfx.Vector3Distance(geo.point_forward(doc.spline.points[0]), fwd) < 1e-4,
		"a roll about the heading should not have changed the heading",
	)

	for i in 0 ..< len(doc.spline.points) {
		want := bank * ed.road_brush_weight[i]
		got := point_roll(doc.spline.points[i])
		testing.expectf(
			t,
			abs(got - want) < 1e-3,
			"point %d rolled %.4f rad, wanted its %.2f share of %.4f",
			i, got, ed.road_brush_weight[i], bank,
		)
	}
}

// The selection hangs off one anchor and names array positions, so it is
// dropped the moment either stops being true. Clicking empty ground already
// clears ed.sel; this is what turns that into a cleared selection.
@(test)
road_brush_selection_drops_when_it_stops_naming_its_road :: proc(t: ^testing.T) {
	doc := road_brush_fixture(6)
	ed := Editor{doc = &doc, road_brush = {radius = 50}, road_brush_taper = 0}
	defer road_brush_free(&ed, &doc)

	live :: proc(ed: ^Editor) -> bool {
		return len(ed.road_brush_weight) > 0
	}

	ed.sel = {kind = .Point, idx = 1}
	road_brush_select(&ed, 1)
	road_brush_resolve(&ed)
	testing.expect(t, live(&ed), "the selection should survive its own anchor")

	// Clicking empty ground, or anything that is not a road point.
	ed.sel = {}
	road_brush_resolve(&ed)
	testing.expect(t, !live(&ed), "an empty selection should have dropped it")

	// Selecting a different point.
	ed.sel = {kind = .Point, idx = 1}
	road_brush_select(&ed, 1)
	ed.sel = {kind = .Point, idx = 3}
	road_brush_resolve(&ed)
	testing.expect(t, !live(&ed), "another point should have dropped it")

	// An edit that renumbers the array under it. The anchor keeps its id and
	// its index here, so only the count gives the insert away.
	ed.sel = {kind = .Point, idx = 5}
	road_brush_select(&ed, 5)
	geo.spline_inject(&doc.spline, 0, doc.spline.points[0])
	ed.sel = {kind = .Point, idx = 5}
	road_brush_resolve(&ed)
	testing.expect(t, !live(&ed), "an insert should have dropped it")
}
