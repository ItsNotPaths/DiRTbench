package main

import "core:math"
import "core:testing"
import d3 "../d3"
import "../geo"

// Ground samples on a lattice, with `holes` knocked out of it. Mirrors what
// d3_ground_cover_samples returns when veg_field_y refuses a point. `su`
// climbs with the column, so a wide enough lattice crosses every band.
@(private = "file")
gc_lattice :: proc(cols, rows: int, holes: ..[2]int) -> map[[2]int]Gc_Sample {
	out := make(map[[2]int]Gc_Sample, cols*rows, context.temp_allocator)
	for col in 0 ..< cols {
		for row in 0 ..< rows {
			out[{col, row}] = {y = f32(col) + f32(row)/100, su = f32(col)}
		}
	}
	for hole in holes { delete_key(&out, hole) }
	return out
}

// A reach no lattice in these tests reaches, so every quad lands in band 0
// unless a test says otherwise.
@(private = "file") GC_FAR :: f32(10000)

// Quads across a cell in these tests. Not a production number: the real one
// comes off the cell size and the lattice pitch.
@(private = "file") GC_PER_CELL :: 4

@(test)
ground_cover_drops_a_quad_with_any_corner_off_the_ground :: proc(t: ^testing.T) {
	// One missing sample kills the four quads that touch it, and nothing else.
	full := d3_ground_cover_quads(gc_lattice(5, 5), 5, 5, GC_FAR)
	testing.expect_value(t, len(full), 16)

	holed := d3_ground_cover_quads(gc_lattice(5, 5, {2, 2}), 5, 5, GC_FAR)
	testing.expect_value(t, len(holed), 12)
	for quad in holed {
		touches := (quad.col == 2 || quad.col == 1) && (quad.row == 2 || quad.row == 1)
		testing.expectf(t, !touches, "quad at %d,%d uses the missing sample", quad.col, quad.row)
	}
}

@(test)
ground_cover_keeps_the_ground_height_at_every_corner :: proc(t: ^testing.T) {
	heights := gc_lattice(3, 3)
	quads := d3_ground_cover_quads(heights, 3, 3, GC_FAR)
	testing.expect_value(t, len(quads), 4)
	for quad in quads {
		testing.expect_value(t, quad.y[0], heights[{quad.col, quad.row}].y)
		testing.expect_value(t, quad.y[1], heights[{quad.col + 1, quad.row}].y)
		testing.expect_value(t, quad.y[2], heights[{quad.col + 1, quad.row + 1}].y)
		testing.expect_value(t, quad.y[3], heights[{quad.col, quad.row + 1}].y)
	}
}

@(test)
ground_cover_cells_tile_the_lattice_and_share_their_points :: proc(t: ^testing.T) {
	// Two cells wide, one deep, at the writer's own cell size.
	cols := 2*GC_PER_CELL + 1
	rows := GC_PER_CELL + 1
	pitch := f32(5)
	quads := d3_ground_cover_quads(gc_lattice(cols, rows), cols, rows, GC_FAR)
	layout := d3_ground_cover_layout(quads, {0, 0}, pitch, GC_PER_CELL, {1, 1, 1, 1})

	testing.expect_value(t, len(layout.cells), 2)
	for cell, i in layout.cells {
		// 4x4 quads is 32 triangles over 25 shared points, not 96 loose ones.
		testing.expectf(
			t, len(cell.tris) == 2*GC_PER_CELL*GC_PER_CELL,
			"cell %d has %d triangles", i, len(cell.tris),
		)
		testing.expectf(
			t, len(cell.points) == (GC_PER_CELL+1)*(GC_PER_CELL+1),
			"cell %d has %d points, so they are not shared", i, len(cell.points),
		)
		testing.expectf(
			t, len(cell.points) <= d3.GRS_CELL_VERTS_MAX,
			"cell %d has %d points and a triangle indexes them with one byte", i, len(cell.points),
		)
		for tri in cell.tris {
			for corner in 0 ..< 3 {
				testing.expect(t, int(tri.i[corner]) < len(cell.points))
			}
		}
		// Every quad contributes its own ground. Band 0 weighs 1, so at this
		// reach the weighted area is the real one.
		testing.expect_value(t, layout.zones[i].area, f32(GC_PER_CELL*GC_PER_CELL)*pitch*pitch)
	}
	// And the two cells sit side by side, one cell width apart.
	gap := layout.zones[1].centre[0] - layout.zones[0].centre[0]
	testing.expectf(
		t, math.abs(gap - pitch*GC_PER_CELL) < 0.01,
		"cells are %v apart, not one cell width", gap,
	)
}

@(test)
ground_cover_orders_its_cells_the_same_way_every_time :: proc(t: ^testing.T) {
	// The cell list is written into every route's track.vis as its tag-1
	// boxes, so two exports of one venue have to agree. Map iteration does
	// not, which is what the sort is for.
	cols, rows := 3*GC_PER_CELL + 1, 3*GC_PER_CELL + 1
	quads := d3_ground_cover_quads(gc_lattice(cols, rows), cols, rows, GC_FAR)
	first := d3_ground_cover_layout(quads, {0, 0}, 5, GC_PER_CELL, {0, 0, 0, 0})
	for _ in 0 ..< 8 {
		again := d3_ground_cover_layout(quads, {0, 0}, 5, GC_PER_CELL, {0, 0, 0, 0})
		testing.expect_value(t, len(again.cells), len(first.cells))
		for i in 0 ..< len(first.cells) {
			testing.expectf(
				t, again.zones[i].centre == first.zones[i].centre,
				"cell %d moved between two layouts of the same ground", i,
			)
		}
	}
	testing.expect_value(t, len(first.cells), 9)
	// Ascending by row, then column.
	for i in 1 ..< len(first.zones) {
		a, b := first.zones[i-1].centre, first.zones[i].centre
		testing.expect(t, b[1] > a[1] || (b[1] == a[1] && b[0] > a[0]))
	}
}

@(test)
ground_cover_worst_disc_takes_the_busiest_view_not_the_average :: proc(t: ^testing.T) {
	// Three cells in a clump and one far away. The clump is the worst view.
	clump := []Gc_Zone{
		{{0, 0}, 100}, {{10, 0}, 200}, {{0, 10}, 300}, {{5000, 5000}, 400},
	}
	cells, ground := d3_ground_cover_worst_disc(clump)
	testing.expect_value(t, cells, 3)
	testing.expect_value(t, ground, f32(600))

	// A cell exactly on the draw distance is in view; one past it is not.
	// Two cells at a time, because the sweep takes the worst origin and a cell
	// in the middle of a line would see both its neighbours.
	touching, _ := d3_ground_cover_worst_disc([]Gc_Zone{{{0, 0}, 1}, {{D3_GC_DRAW_M, 0}, 1}})
	testing.expect_value(t, touching, 2)
	apart, _ := d3_ground_cover_worst_disc([]Gc_Zone{{{0, 0}, 1}, {{D3_GC_DRAW_M + 1, 0}, 1}})
	testing.expect_value(t, apart, 1)
}

@(test)
ground_cover_puts_the_biggest_cards_nearest_the_road :: proc(t: ^testing.T) {
	// Finland's own shape. Type 7 is a 0.36 m tuft of 0.14 m2 — a speck, and
	// the verge covered in them reads as bare ground however many there are.
	// Type 8 is an 8 m reed strip, which is scenery. Neither belongs here.
	template := gc_app_template(
		{4, 6, 6, 5, 4, 4, 3, 4},
		{0.73, 1.44, 1.45, 0.96, 1.22, 1.10, 0.36, 7.00},
		{0.70, 1.01, 1.01, 1.12, 1.33, 1.18, 0.40, 1.05},
	)
	cover, area, msg, ok := d3_ground_cover_types(template)
	testing.expectf(t, ok, "no type chosen: %s", msg)
	// Descending card face area over the five that are grass: type 5 is
	// 1.62 m2, then 3 and 2 at 1.46, then 6 at 1.30.
	testing.expect_value(t, cover[0], u8(4))
	for band in 1 ..< D3_GC_BANDS {
		testing.expectf(
			t, area[band] <= area[band-1],
			"band %d hides %v m2 a card and band %d hides %v", band, area[band], band-1, area[band-1],
		)
	}
	// The speck and the reed strip are nowhere near the road.
	for band in 0 ..< D3_GC_BANDS {
		testing.expect(t, cover[band] != 6)
		testing.expect(t, cover[band] != 7)
	}

	// A venue whose art is all oversized gets a refusal, not a reed carpet.
	wide := gc_app_template(
		{4, 4, 4, 4, 4, 4, 4, 4}, {9, 9, 9, 9, 9, 9, 9, 9}, {1, 1, 1, 1, 1, 1, 1, 1},
	)
	_, _, _, any := d3_ground_cover_types(wide)
	testing.expect(t, !any)

	// A venue whose art is all specks grows them rather than nothing.
	tiny := gc_app_template(
		{0, 3, 0, 2, 0, 0, 0, 0}, {0.3, 0.3, 0.3, 0.4, 0.3, 0.3, 0.3, 0.3},
		{0.3, 0.3, 0.3, 0.4, 0.3, 0.3, 0.3, 0.3},
	)
	only, _, _, tiny_ok := d3_ground_cover_types(tiny)
	testing.expect(t, tiny_ok)
	testing.expect_value(t, only[0], u8(3)) // the least small of them

	// Fewer types than bands shares what there is. A type with no cards is
	// never one of them: no stock triangle anywhere enables one.
	two := gc_app_template(
		{0, 3, 0, 2, 0, 0, 0, 0}, {1.2, 1.2, 0.5, 0.6, 0.5, 0.5, 0.5, 0.5},
		{1.0, 1.0, 0.5, 0.8, 0.5, 0.5, 0.5, 0.5},
	)
	shared, _, _, shared_ok := d3_ground_cover_types(two)
	testing.expect(t, shared_ok)
	testing.expect_value(t, shared, [D3_GC_BANDS]u8{1, 3, 3, 3})
}

@(test)
ground_cover_bands_are_fractions_of_the_terrain_reach :: proc(t: ^testing.T) {
	// A narrow corridor gets narrow bands rather than one band and three
	// empty ones, which is what makes the taper work at any reach.
	for reach in ([]f32{20, 96, 400}) {
		at_verge, verge_covered := d3_ground_cover_band(0, reach)
		testing.expect_value(t, at_verge, 0)
		testing.expect(t, verge_covered)
		for band in 0 ..< D3_GC_BANDS {
			inside := reach * D3_GC_BAND_EDGE[band] - 0.01
			got, covered := d3_ground_cover_band(inside, reach)
			testing.expect(t, covered)
			testing.expectf(t, got <= band, "width %v: %v m fell past band %d", reach, inside, band)
		}
		// Past the covered width there is no cover at all, rather than a very
		// sparse band nobody sees paid for out of the verge's density.
		_, beyond := d3_ground_cover_band(reach*1.01, reach)
		testing.expect(t, !beyond)
	}
	// And the bands really do partition: each edge is further out than the last.
	for band in 1 ..< D3_GC_BANDS {
		testing.expect(t, D3_GC_BAND_EDGE[band] > D3_GC_BAND_EDGE[band-1])
		testing.expect(t, D3_GC_BAND_STEP[band] > D3_GC_BAND_STEP[band-1])
	}
}

@(test)
ground_cover_thins_with_distance_and_weighs_its_ground_for_it :: proc(t: ^testing.T) {
	// su climbs with the column in gc_lattice, so a short reach walks this
	// lattice through every band.
	cols, rows := 4*GC_PER_CELL + 1, GC_PER_CELL + 1
	quads := d3_ground_cover_quads(gc_lattice(cols, rows), cols, rows, 12)
	seen: [D3_GC_BANDS]int
	for quad in quads { seen[quad.band] += 1 }
	for band in 0 ..< D3_GC_BANDS {
		testing.expectf(t, seen[band] > 0, "band %d got no ground", band)
	}

	// The outer cells weigh less than the inner ones, because their lattice is
	// coarser and a square metre out there costs fewer cards.
	layout := d3_ground_cover_layout(quads, {0, 0}, 1, GC_PER_CELL, {0, 1, 2, 3})
	testing.expect(t, len(layout.cells) >= 2)
	testing.expectf(
		t, layout.zones[len(layout.zones)-1].area < layout.zones[0].area,
		"the far cell weighs %v and the near one %v",
		layout.zones[len(layout.zones)-1].area, layout.zones[0].area,
	)
	// And a far cell grows a different type from a near one.
	near_cover := layout.cells[0].tris[0].cover
	far_cover := layout.cells[len(layout.cells)-1].tris[0].cover
	testing.expect(t, near_cover != far_cover)
}

// A grass.grs template with nothing in it but the slot counts and card sizes
// the type pick reads.
@(private = "file")
gc_app_template :: proc(slots: [8]int, width: [8]f32, height: [8]f32) -> []u8 {
	CARD_REC :: 8 * 6 * 4
	NAME_REC :: 152
	CARDS_AT :: 16
	NAMES_AT :: CARDS_AT + 8*CARD_REC + 8*27*4
	data := make([]u8, NAMES_AT + 8*NAME_REC + 4, context.temp_allocator)
	d3.binary_store_u32(data, 0, 7)
	d3.binary_store_u32(data, 4, 8)
	for t in 0 ..< 8 {
		d3.binary_store_u32(data, NAMES_AT + t*NAME_REC + 128, u32(slots[t]))
		for s in 0 ..< slots[t] {
			d3.binary_store_f32(data, CARDS_AT + t*CARD_REC + s*24, width[t])
			d3.binary_store_f32(data, CARDS_AT + t*CARD_REC + s*24 + 4, height[t])
		}
	}
	return data
}

// The generator never looks at a triangle's material: the terrain field is
// measured from the verge seam, which is the outer end of the gutter, bank and
// cliff stack, so all three are already behind it. This pins that.
@(test)
ground_cover_never_reaches_a_gutter_bank_or_cliff :: proc(t: ^testing.T) {
	sp: geo.Spline
	for z in ([]f32{0, 80, 160, 240}) {
		geo.spline_push(&sp, geo.make_point(
			{0, 0, z}, 1, geo.DEFAULT_WIDTH, parent = len(sp.points)-1,
		))
	}
	defer geo.spline_free(&sp)
	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	geo.terrain_ensure(&terrain, ribbon, 0)
	defer geo.terrain_delete(&terrain)

	arc := geo.ribbon_arc(ribbon)
	vf := geo.veg_field_make(&terrain, ribbon, arc, geo.sample_spacing(ribbon), 0)
	testing.expect(t, vf.ok)

	mid := ribbon[len(ribbon)/2]
	seam := abs(geo.verge_seam(mid, 0, 0).x)
	// On the carriageway, on the verge, and just outside the seam: only the
	// last is ground the cover may use, and it has to clear VEG_CLEAR first.
	_, on_road := geo.veg_field_y(&vf, {0, mid.pos.z})
	testing.expect(t, !on_road)
	_, on_verge := geo.veg_field_y(&vf, {seam * 0.5, mid.pos.z})
	testing.expect(t, !on_verge)
	_, at_seam := geo.veg_field_y(&vf, {seam, mid.pos.z})
	testing.expect(t, !at_seam)
	_, clear := geo.veg_field_y(&vf, {seam + geo.VEG_CLEAR + 1, mid.pos.z})
	testing.expect(t, clear)
}


// The lattice is what decides how close to the road cover can start: a quad
// needs all four corners clear, so a coarse one rounds the inner edge outward
// by up to its own pitch. It answers to D3_GC_PITCH_M, never to the cell size,
// which is the zone budget's business.
@(test)
ground_cover_keeps_its_lattice_fine_whatever_the_cells_do :: proc(t: ^testing.T) {
	for cell_m in ([]f32{8, 20, 25, D3_GC_CELL_MAX_M}) {
		per_cell := d3_ground_cover_quads_per_cell(cell_m)
		pitch := cell_m / f32(per_cell)
		points := (per_cell + 1) * (per_cell + 1)
		testing.expectf(
			t, points <= d3.GRS_CELL_VERTS_MAX,
			"a %v m cell wants %d points and a triangle indexes them with one byte", cell_m, points,
		)
		testing.expectf(
			t, pitch <= D3_GC_PITCH_M*1.1,
			"a %v m cell samples the ground every %v m", cell_m, pitch,
		)
	}
	// And cover starts a metre off the verge, not a tree's clearance out.
	testing.expect(t, D3_GC_CLEAR_M < geo.VEG_CLEAR)
}
