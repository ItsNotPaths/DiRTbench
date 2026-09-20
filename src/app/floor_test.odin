package main

// A floor that flattens is a ceiling on the ground, with one exception
// (geo/floor.odin). These pin the rule from both sides — what it may lower and
// what it must leave alone — and that each arg acts on its own.

import "core:os"
import "core:slice"
import "../gfx"
import "core:testing"
import "../geo"

// A square pad, and a synthetic field of points standing at `y` over it.
//
// A point with one leg of weight 1 and a `u` past the blend band reads back at
// exactly that leg's seam height, so a test can put the ground wherever it wants
// without building a road to carry it there.
test_floor_terrain :: proc() -> geo.Terrain {
	t := geo.TERRAIN_DEFAULTS
	t.enabled = true
	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	geo.floor_add(&t, square, 10)
	return t
}

test_field_point :: proc(x, z, y: f32) -> geo.Terrain_Point {
	p := geo.Terrain_Point{x = x, z = z, n = 1}
	p.legs[0] = {u = 1000, seam_y = y, w = 1}
	return p
}

@(test)
a_floor_holds_its_own_level_and_fades_out :: proc(t: ^testing.T) {
	terrain := test_floor_terrain()
	defer geo.terrain_delete(&terrain)

	// Inside: the pad's own height, whatever the ground is doing.
	level, inside, ok := geo.terrain_floor_level(&terrain, {20, 20}, 25)
	testing.expect(t, ok, "a point in the middle of the outline found no floor")
	testing.expect_value(t, level, f32(10))
	testing.expect(t, inside, "a point in the middle of the outline read as outside")

	// Still the pad's height with the ground below it — the ceiling is min(y,
	// level), so this one cuts nothing.
	level, _, _ = geo.terrain_floor_level(&terrain, {20, 20}, 4)
	testing.expect_value(t, level, f32(10))
	testing.expect_value(t, min(f32(4), level), f32(4))

	// Outside, past the falloff: no floor reaches, and not "inside" either.
	level, inside, ok = geo.terrain_floor_level(&terrain, {20, -geo.FLOOR_FALLOFF - 1}, 25)
	testing.expect(t, !ok, "a floor reached past its own falloff")
	testing.expect_value(t, level, f32(25))
	testing.expect(t, !inside, "a point clear of the outline read as inside")

	// In the falloff band: between the two, and never above the ground it found.
	level, _, _ = geo.terrain_floor_level(&terrain, {20, -geo.FLOOR_FALLOFF * 0.5}, 25)
	testing.expect(t, level > 10 && level < 25, "the falloff did not blend the pad out")
}

@(test)
a_concave_outline_keeps_its_notch_outside :: proc(t: ^testing.T) {
	// An L: the missing quarter is the notch at (30, 30).
	poly := [][2]f32{{0, 0}, {40, 0}, {40, 20}, {20, 20}, {20, 40}, {0, 40}}
	testing.expect(t, geo.poly_signed_dist(poly, {10, 10}) < 0, "the corner of the L read as outside")
	testing.expect(t, geo.poly_signed_dist(poly, {30, 30}) > 0, "the notch read as inside")
	testing.expect(t, geo.poly_signed_dist(poly, {50, 10}) > 0, "a point clear of the L read as inside")
}

@(test)
the_lower_of_two_overlapping_floors_wins :: proc(t: ^testing.T) {
	terrain := test_floor_terrain()
	defer geo.terrain_delete(&terrain)
	over := [][2]f32{{10, 10}, {60, 10}, {60, 60}, {10, 60}}
	geo.floor_add(&terrain, over, 4)

	level, _, _ := geo.terrain_floor_level(&terrain, {20, 20}, 25)
	testing.expect_value(t, level, f32(4))
	// And where only the first reaches, the first still holds.
	level, _, _ = geo.terrain_floor_level(&terrain, {5, 5}, 25)
	testing.expect_value(t, level, f32(10))
}

// The divot: a dip that already sat below the pad, surrounded by ground the pad
// cut. It rises to meet the pad, but never by more than FLOOR_LIFT.
@(test)
a_divot_inside_a_cut_pad_is_lifted_but_only_so_far :: proc(t: ^testing.T) {
	terrain := test_floor_terrain()
	defer geo.terrain_delete(&terrain)
	f: geo.Terrain_Field
	defer geo.terrain_field_delete(&f)

	// 0: high ground the pad cuts. 1: a shallow dip. 2: a deep hole. 3: the rim.
	append(&f.pts, test_field_point(20, 20, 25))
	append(&f.pts, test_field_point(21, 20, 9.5))
	append(&f.pts, test_field_point(22, 20, 2))
	append(&f.pts, geo.Terrain_Point{x = 23, z = 20, y = 30, fixed = true})
	append(&f.tris, [3]u32{0, 1, 2}, [3]u32{1, 2, 3})

	ys := geo.terrain_floor_heights(&terrain, &f)
	testing.expect_value(t, ys[0], f32(10))           // cut to the pad
	testing.expect_value(t, ys[1], f32(10))           // 0.5 m dip, closed
	testing.expect_value(t, ys[2], f32(2 + geo.FLOOR_LIFT)) // 8 m hole, lifted 1 m and no more
	testing.expect_value(t, ys[3], f32(30))           // the verge seam, untouched
}

// The gate. With nothing cut nearby the pad is simply hanging over the ground,
// and hanging is all it does.
@(test)
a_floor_over_untouched_ground_lifts_nothing :: proc(t: ^testing.T) {
	terrain := test_floor_terrain()
	defer geo.terrain_delete(&terrain)
	f: geo.Terrain_Field
	defer geo.terrain_field_delete(&f)

	for x in ([]f32{18, 20, 22}) {
		append(&f.pts, test_field_point(x, 20, 9.6))
	}
	append(&f.tris, [3]u32{0, 1, 2})

	ys := geo.terrain_floor_heights(&terrain, &f)
	for y, i in ys {
		testing.expectf(t, y == 9.6, "point %d was lifted to %.2f by a floor that cut nothing", i, y)
	}
}

// The flat storage's one real cost: every run after an edit has to still name
// its own outline.
@(test)
editing_one_outline_leaves_the_others_whole :: proc(t: ^testing.T) {
	terrain := test_floor_terrain()
	defer geo.terrain_delete(&terrain)
	second := [][2]f32{{100, 100}, {140, 100}, {140, 140}, {100, 140}}
	i := geo.floor_add(&terrain, second, 5)

	geo.floor_vert_insert(&terrain, 0, 0, {20, -5})
	testing.expect_value(t, terrain.floors[0].count, 5)
	testing.expect_value(t, terrain.floors[i].count, 4)
	testing.expect_value(t, geo.floor_verts(&terrain, terrain.floors[i])[0], [2]f32{100, 100})

	testing.expect(t, geo.floor_vert_remove(&terrain, 0, 0))
	testing.expect_value(t, geo.floor_verts(&terrain, terrain.floors[i])[0], [2]f32{100, 100})

	geo.floor_remove(&terrain, 0)
	testing.expect_value(t, len(terrain.floors), 1)
	testing.expect_value(t, len(terrain.floor_pts), 4)
	testing.expect_value(t, geo.floor_verts(&terrain, terrain.floors[0])[2], [2]f32{140, 140})

	// An outline may not be cut below a triangle.
	terrain.floors[0].count = 3
	testing.expect(t, !geo.floor_vert_remove(&terrain, 0, 0))
}

// A pad that clears its foliage is off the terrain as far as the scatter is
// concerned — the same answer the road corridor gets — and the arg is the only
// thing that decides it. Trees and ground cover answer separately: a levelled
// patch may keep its grass and lose the trees standing in it.
@(test)
a_floor_can_clear_the_foliage_standing_on_it :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	seeds := [?]gfx.Vector3{{0, 0, 0}, {0, 0, 100}, {0, 0, 200}, {0, 0, 300}}
	for pos, i in seeds {
		rot := i > 0 ? geo.heading_quat(seeds[i - 1], pos) : gfx.Quaternion(1)
		geo.spline_push(&sp, geo.make_point(pos, rot, geo.DEFAULT_WIDTH, parent = i - 1))
	}

	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)
	// A square well clear of the road, so nothing but the pad can reject it.
	pad := [][2]f32{{30, 100}, {60, 100}, {60, 200}, {30, 200}}
	fi := geo.floor_add(&terrain, pad, 0, {flatten = true, no_trees = true})

	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	arc := geo.ribbon_arc(ribbon, context.allocator)
	defer delete(arc)
	vf := geo.veg_field_make(&terrain, ribbon, arc, geo.sample_spacing(ribbon), 0)
	testing.expect(t, vf.ok, "no vegetation field to test against")

	on_pad := [2]f32{45, 150}
	beside_it := [2]f32{20, 150}

	_, plantable := geo.veg_field_y(&vf, on_pad)
	testing.expect(t, !plantable, "a pad that clears its foliage still took a tree")
	_, plantable = geo.veg_field_y(&vf, beside_it)
	testing.expect(t, plantable, "the ground beside the pad lost its trees too")

	// Its cover was never cleared, so the same spot still grows grass.
	_, _, covered := geo.veg_field_ground(&vf, on_pad, D3_GC_CLEAR_M, .Cover)
	testing.expect(t, covered, "a pad that clears only its trees took the grass too")

	terrain.floors[fi].no_trees = false
	_, plantable = geo.veg_field_y(&vf, on_pad)
	testing.expect(t, plantable, "the arg is off and the pad still refused a tree")

	terrain.floors[fi].no_cover = true
	_, _, covered = geo.veg_field_ground(&vf, on_pad, D3_GC_CLEAR_M, .Cover)
	testing.expect(t, !covered, "a pad that clears its cover still grew grass")
}

@(test)
floors_round_trip_through_road_json :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.terrain_delete(&doc.terrain)
	defer geo.spline_free(&doc.spline)
	seed_spline(&doc.spline)
	doc.terrain.enabled = true
	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	i := geo.floor_add(&doc.terrain, square, 12)
	doc.terrain.floors[i].falloff = 3
	doc.terrain.floors[i].no_trees = true
	doc.terrain.floors[i].no_cover = false

	path := "/tmp/claude-1000/dirtbench-floor-roundtrip.json"
	defer os.remove(path)
	if _, ok := save_road(&doc, path); !ok {
		testing.fail_now(t, "could not write the road")
	}

	back := doc_defaults()
	defer geo.terrain_delete(&back.terrain)
	defer geo.spline_free(&back.spline)
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back")
	}
	testing.expect_value(t, len(back.terrain.floors), 1)
	testing.expect_value(t, back.terrain.floors[0].y, f32(12))
	testing.expect_value(t, back.terrain.floors[0].falloff, f32(3))
	testing.expect_value(t, back.terrain.floors[0].no_trees, true)
	testing.expect_value(t, back.terrain.floors[0].no_cover, false)
	testing.expect_value(t, back.terrain.floors[0].flatten, true)
	testing.expect(
		t,
		slice.equal(geo.floor_verts(&back.terrain, back.terrain.floors[0]), square),
		"the outline came back with different corners",
	)

	// A second load must not stack them up.
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back twice")
	}
	testing.expect_value(t, len(back.terrain.floors), 1)
}

// Water on a pad, and the level it stands at. A pad cuts the ground and never
// lifts it, so the surface has to sit above the pad's own height or it draws
// nothing: water is one-sided. See docs/dirt3-water.md.
@(test)
water_on_a_floor_round_trips_and_stands_above_its_bed :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.terrain_delete(&doc.terrain)
	defer geo.spline_free(&doc.spline)
	seed_spline(&doc.spline)
	doc.terrain.enabled = true
	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	i := geo.floor_add(&doc.terrain, square, -6, {water = true, water_depth = 2.5})
	testing.expect(t, i >= 0, "the pad was not added")

	level, wet := geo.floor_water_level(doc.terrain.floors[i])
	testing.expect(t, wet, "a flooded pad reported no water")
	testing.expect_value(t, level, f32(-3.5))

	path := "/tmp/claude-1000/dirtbench-floor-water.json"
	defer os.remove(path)
	if _, ok := save_road(&doc, path); !ok {
		testing.fail_now(t, "could not write the road")
	}
	back := doc_defaults()
	defer geo.terrain_delete(&back.terrain)
	defer geo.spline_free(&back.spline)
	if _, ok := load_road(&back, path); !ok {
		testing.fail_now(t, "could not read the road back")
	}
	testing.expect_value(t, len(back.terrain.floors), 1)
	testing.expect_value(t, back.terrain.floors[0].water, true)
	testing.expect_value(t, back.terrain.floors[0].water_depth, f32(2.5))
	// This one only floods: the arg it was made without must stay off.
	testing.expect_value(t, back.terrain.floors[0].flatten, false)
}

// The args are independent. A pad with everything but `flatten` leaves the
// ground exactly where it found it, and still clears and floods it.
@(test)
a_pad_that_does_not_flatten_leaves_the_ground_alone :: proc(t: ^testing.T) {
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)
	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	fi := geo.floor_add(
		&terrain, square, 10,
		{no_trees = true, no_cover = true, water = true, water_depth = 2},
	)

	_, _, ok := geo.terrain_floor_level(&terrain, {20, 20}, 25)
	testing.expect(t, !ok, "a pad that does not flatten still held a level")

	f: geo.Terrain_Field
	defer geo.terrain_field_delete(&f)
	append(&f.pts, test_field_point(20, 20, 25))
	append(&f.pts, test_field_point(21, 20, 2))
	append(&f.tris, [3]u32{0, 0, 1})
	ys := geo.terrain_floor_heights(&terrain, &f)
	testing.expect_value(t, ys[0], f32(25)) // not cut
	testing.expect_value(t, ys[1], f32(2))  // not lifted

	testing.expect(
		t, geo.terrain_floor_clears(&terrain, {20, 20}, .Trees),
		"a pad that does not flatten stopped clearing its trees",
	)
	level, wet := geo.floor_water_level(terrain.floors[fi])
	testing.expect(t, wet, "a pad that does not flatten stopped holding water")
	testing.expect_value(t, level, f32(12))
}

// A dry pad is the default, and a pad flooded with no depth would lie flush
// with its own bed, where nothing can see it.
@(test)
a_floor_is_dry_until_it_is_flooded :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.terrain_delete(&doc.terrain)
	defer geo.spline_free(&doc.spline)
	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	i := geo.floor_add(&doc.terrain, square, 3)
	_, wet := geo.floor_water_level(doc.terrain.floors[i])
	testing.expect(t, !wet, "a pad nobody flooded came back wet")

	doc.terrain.floors[i].water = true
	level, now_wet := geo.floor_water_level(doc.terrain.floors[i])
	testing.expect(t, now_wet, "a flooded pad reported no water")
	testing.expect_value(t, level, f32(3) + geo.FLOOR_WATER_MIN)
}

// Delaunay spans the convex hull, so the L's notch comes back covered. Those
// triangles are dropped, and every kept face is wound to point +Y. The area
// check binds both ways: a hull leak overshoots, a dropped interior falls short.
@(test)
a_concave_floor_triangulates_inside_itself_only :: proc(t: ^testing.T) {
	poly := [][2]f32{{0, 0}, {40, 0}, {40, 20}, {20, 20}, {20, 40}, {0, 40}}
	tris, ok := geo.floor_triangulate(poly, context.temp_allocator)
	testing.expect(t, ok, "the L did not triangulate")
	area: f32
	for tri in tris {
		a, b, c := poly[tri[0]], poly[tri[1]], poly[tri[2]]
		up := (b[1] - a[1]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[1] - a[1])
		testing.expect(t, up > 0, "a face is wound away from +Y")
		area += up / 2
	}
	testing.expect_value(t, area, f32(1200))
}

// A road that predates the block opens with no pads, whatever the document held.
@(test)
a_road_without_floors_loads_as_none :: proc(t: ^testing.T) {
	doc := doc_defaults()
	defer geo.terrain_delete(&doc.terrain)
	defer geo.spline_free(&doc.spline)
	seed_spline(&doc.spline)
	doc.terrain.enabled = true

	path := "/tmp/claude-1000/dirtbench-floorless-road.json"
	defer os.remove(path)
	if _, ok := save_road(&doc, path); !ok {
		testing.fail_now(t, "could not write the road")
	}

	square := [][2]f32{{0, 0}, {40, 0}, {40, 40}, {0, 40}}
	geo.floor_add(&doc.terrain, square, 12)
	if _, ok := load_road(&doc, path); !ok {
		testing.fail_now(t, "could not read the road back")
	}
	testing.expect_value(t, len(doc.terrain.floors), 0)
	testing.expect_value(t, len(doc.terrain.floor_pts), 0)
}
