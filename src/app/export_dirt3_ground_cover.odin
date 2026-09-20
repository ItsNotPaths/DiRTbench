package main

// The Dirt 3 target's ground cover: the scatter surface `grass.grs` describes,
// built from the venue's own terrain.
//
// Export only. Nothing here draws in the editor — the grass exists as a few
// numbers the game scatters cards over, and a preview of it would be a second
// implementation of the engine's scatter rather than a view of ours.
//
// Venue scope, like `tracksplit.pssg`, and for the same reason: `grass.grs`
// sits one level above a route and every route of the venue shares it. It is
// built out of `job.venue`, which is the whole road network and identical
// whichever stage is being exported, so every stage agrees on the cell list
// without being told to. That matters because the cell boxes are also the
// route's `track.vis` tag-1 boxes, and the two have to be the same bytes.
//
// Where the cover goes is `veg_field_y`'s answer, the same test that decides
// whether a tree may stand somewhere: on the terrain, past `VEG_CLEAR` from
// every road corridor, inside `reach_m`, off any pad that clears its cover.
// `su` is measured **from the verge seam**, and the seam is the outer end of
// the gutter, bank and cliff stack, so all three are excluded by construction
// rather than by filtering triangles on their material.

import "core:fmt"
import "core:math"
import "core:slice"
import d3 "../d3"
import "../geo"

// The engine allocates its card pool and its zone slots once, at load, from
// `maxitems` and `zones` in the venue's `ground_cover.xml`, and doubles both.
// We write that file (d3/ground_cover.odin), so the budget is a constant on
// both sides rather than the least any venue happens to grant.
D3_GC_CARD_BUDGET :: d3.GC_XML_MAX_ITEMS * 2
D3_GC_ZONE_BUDGET :: d3.GC_XML_ZONES * 2
D3_GC_DRAW_M :: f32(210) // and the draw distance that file asks for
// Solve well under both rather than up against them. Stock sits at 1.0 to 1.2
// times a 210 m disc and leans on the frustum and the distance culls to bring
// the real figure down; we have no reason to spend that margin.
D3_GC_HEADROOM :: f32(0.75)

// Stock cells run about 21 m across. Grown, never shrunk, until the zone
// budget is satisfied.
D3_GC_CELL_M :: f32(20)
// A cell wider than this cannot hold the ground lattice at its own pitch
// within the 256 points one byte can index, and coarsening the lattice
// instead would reopen the gap at the verge. So the zone budget gives up
// here and says so, rather than quietly trading the thing anyone can see.
D3_GC_CELL_MAX_M :: D3_GC_PITCH_M * D3_GC_QUADS_MAX

// The lattice the engine walks over each triangle. Stock runs 0.3 to 4.5 m.
D3_GC_STEP_MIN :: f32(0.4)
D3_GC_STEP_MAX :: f32(4.5)

// A cover type whose cards are wider than this is scenery, not grass:
// Finland's type 8 is an 8 m reed strip, and carpeting a venue with it would
// look nothing like ground cover.
D3_GC_CARD_MAX_M :: f32(2)
// And one whose cards are smaller than this is a speck. What the eye reads as
// foliage is ground covered, not cards placed, and those are different
// numbers: Finland's type 7 is a 0.36 m tuft of 0.14 m2, so even 1.5 cards
// per square metre leaves four fifths of the ground bare and the verge looks
// thin however hard the budget is spent. Its type 5 is 1.62 m2, eleven times
// the foliage per card.
D3_GC_CARD_MIN_M2 :: f32(0.25)

// How close to the verge cover starts. Not `VEG_CLEAR`, which is a tree's
// clearance: a trunk and a canopy need room, grass needs the verge, and a
// tree-sized setback reads as a bare strip from the car.
D3_GC_CLEAR_M :: f32(1)

// How far out cover reaches, whatever the terrain does. The card budget is
// absolute — a 210 m view is a 210 m view however wide the corridor is — so
// ground past this is paid for out of the verge's own density, and the verge
// is the only part anyone sees from a car.
D3_GC_COVER_M :: f32(25)

// The ground lattice, in metres. Quads need all four corners clear of the
// road to exist at all, so a coarse lattice rounds the inner edge of the
// cover outward by up to its own pitch. Kept off the cell size for that
// reason: the cell size answers to the zone budget and has no business
// setting how close the grass gets.
D3_GC_PITCH_M :: f32(2)
// (quads + 1) ^ 2 points per cell, and a triangle indexes them with one byte.
D3_GC_QUADS_MAX :: 15

// Bands out from the verge, each growing its own cover type at its own
// lattice. Two problems, one mechanism: a single type over the whole corridor
// reads as one plant repeated, and a single lattice spends as much of the
// card budget on ground 40 m out as on the verge you drive past.
//
// Fractions of the covered width, not of the terrain's reach, so a corridor
// narrower than D3_GC_COVER_M still gets four bands instead of one band and
// three empty ones.
D3_GC_BAND_EDGE := [4]f32{0.25, 0.45, 0.70, 1.00}
// And each band's lattice, relative to the innermost. Cards go as 1/step^2,
// so a gentle ratio still thins fast: at 2.5 the outer band is a sixth the
// density of the verge. Steeper than this and the verge hides its own ground
// several times over while the band behind it reads as bare.
D3_GC_BAND_STEP := [4]f32{1.0, 1.35, 1.85, 2.5}
D3_GC_BANDS :: len(D3_GC_BAND_EDGE)

@(private)
Gc_Quad :: struct {
	col, row: int,        // on the ground-sample lattice
	y:        [4]f32,     // ground height at each corner, in lattice order
	band:     int,        // which distance band its middle falls in
	su:       f32,        // how far out from the verge its nearest corner sits
}

// One ground sample: its height, and how far out from the verge seam it sits.
@(private)
Gc_Sample :: struct {
	y, su: f32,
}

// One eligible cover type: its index and its mean card face area.
@(private = "file")
Gc_Pick :: struct {
	t:    int,
	area: f32,
}

// One cover type per band, **biggest cards nearest the road**. The verge is
// the only ground anyone looks at, so it gets the art that hides the most of
// itself per card; the specks go to the outer bands or go unused.
//
// Fewer types than bands is fine — a venue whose art offers two shares them
// round — and one type is still better than refusing. A venue whose art is
// all specks falls back to them rather than growing nothing.
@(private)
d3_ground_cover_types :: proc(
	template: []u8,
) -> (
	cover: [D3_GC_BANDS]u8, area: [D3_GC_BANDS]f32, msg: string, ok: bool,
) {
	slots, slots_ok := d3.Ground_Cover_Slots(template)
	if !slots_ok { return {}, {}, "the venue's grass.grs declares no cover types", false }
	width, card, _ := d3.Ground_Cover_Card_Size(template)

	grass := make([dynamic]Gc_Pick, 0, d3.GRS_TYPES, context.temp_allocator)
	specks := make([dynamic]Gc_Pick, 0, d3.GRS_TYPES, context.temp_allocator)
	for t in 0 ..< d3.GRS_TYPES {
		if slots[t] == 0 || width[t] > D3_GC_CARD_MAX_M { continue }
		append(card[t] >= D3_GC_CARD_MIN_M2 ? &grass : &specks, Gc_Pick{t, card[t]})
	}
	eligible := len(grass) > 0 ? grass : specks
	if len(eligible) == 0 {
		return {}, {}, "the venue's ground cover art has no type whose cards are grass sized", false
	}
	slice.sort_by(eligible[:], proc(a, b: Gc_Pick) -> bool { return a.area > b.area })
	cards := 0
	for band in 0 ..< D3_GC_BANDS {
		pick := eligible[min(band, len(eligible)-1)]
		cover[band] = u8(pick.t)
		area[band] = pick.area
		cards += slots[pick.t]
	}
	return cover, area, fmt.tprintf(
		"%d cover types over %d bands, %d cards, %d speck types left out",
		min(len(eligible), D3_GC_BANDS), D3_GC_BANDS, cards, len(grass) > 0 ? len(specks) : 0,
	), true
}

// Ground samples on a lattice of `pitch`, keyed by lattice position. Only the
// points a tree could stand on are in here, each with how far out from the
// verge seam it lies.
@(private = "file")
d3_ground_cover_samples :: proc(
	vf: ^geo.Veg_Field, lo, hi: [2]f32, pitch: f32,
) -> (
	ground: map[[2]int]Gc_Sample, cols, rows: int,
) {
	cols = int((hi[0]-lo[0]) / pitch) + 2
	rows = int((hi[1]-lo[1]) / pitch) + 2
	ground = make(map[[2]int]Gc_Sample, cols*rows/8, context.temp_allocator)
	for col in 0 ..< cols {
		for row in 0 ..< rows {
			p := [2]f32{lo[0] + f32(col)*pitch, lo[1] + f32(row)*pitch}
			y, su, inside := geo.veg_field_ground(vf, p, D3_GC_CLEAR_M, .Cover)
			if !inside { continue }
			ground[{col, row}] = {y = y, su = su}
		}
	}
	return
}

// Quads across a cell of `cell_m`, at the ground lattice's own pitch. Kept to
// what one byte can index.
@(private)
d3_ground_cover_quads_per_cell :: proc(cell_m: f32) -> int {
	return clamp(int(math.round(cell_m / D3_GC_PITCH_M)), 1, D3_GC_QUADS_MAX)
}

// Which band a point `su` metres out from the verge belongs to, and whether it
// gets cover at all. `width` is how far out cover reaches here.
@(private)
d3_ground_cover_band :: proc(su, width: f32) -> (band: int, covered: bool) {
	if su > width { return 0, false }
	for edge, i in D3_GC_BAND_EDGE {
		if su <= width * edge { return i, true }
	}
	return D3_GC_BANDS - 1, true
}

// A quad exists where all four of its corners are plantable ground. Anything
// touching the road corridor, a verge or the void loses its quad rather than
// being clipped: the scatter surface is an approximation of the ground, not a
// second copy of the terrain mesh.
@(private)
d3_ground_cover_quads :: proc(
	ground: map[[2]int]Gc_Sample, cols, rows: int, width: f32,
) -> []Gc_Quad {
	out := make([dynamic]Gc_Quad, 0, len(ground), context.temp_allocator)
	for col in 0 ..< cols-1 {
		for row in 0 ..< rows-1 {
			a, has_a := ground[{col, row}]
			b, has_b := ground[{col+1, row}]
			c, has_c := ground[{col+1, row+1}]
			d, has_d := ground[{col, row+1}]
			if !(has_a && has_b && has_c && has_d) { continue }
			band, covered := d3_ground_cover_band((a.su + b.su + c.su + d.su) / 4, width)
			if !covered { continue }
			append(&out, Gc_Quad{
				col = col, row = row,
				y = {a.y, b.y, c.y, d.y},
				band = band,
				su = min(a.su, b.su, c.su, d.su),
			})
		}
	}
	return out[:]
}

// One cell as the budget sweep sees it: where it sits, and its ground
// **weighted by band** — a square metre in the third band costs 1/2.25^2 of
// what one on the verge costs, because its lattice is that much coarser.
@(private)
Gc_Zone :: struct {
	centre: [2]f32,
	area:   f32,
}

// The most cells any one 210 m disc holds, and the most cards. Both are swept
// from the cells' own centres, which is where the camera is: a stage is driven
// along the ground its cover sits on. The area sum is cards per unit lattice,
// and one square root turns the worst disc into the lattice that fits the
// budget.
@(private)
d3_ground_cover_worst_disc :: proc(zones: []Gc_Zone) -> (cells: int, ground: f32) {
	for origin in zones {
		n, a := 0, f32(0)
		for other in zones {
			dx, dz := other.centre[0]-origin.centre[0], other.centre[1]-origin.centre[1]
			if dx*dx + dz*dz <= D3_GC_DRAW_M*D3_GC_DRAW_M {
				n += 1
				a += other.area
			}
		}
		cells = max(cells, n)
		ground = max(ground, a)
	}
	return
}

// Everything the writer needs, for one cell size. Returned rather than written
// so the solve can throw a layout away and try a coarser one.
@(private)
Gc_Layout :: struct {
	cells:   []d3.Ground_Cell,
	zones:   []Gc_Zone, // one per cell, in cell order
	// How close to the verge the cover actually got. The lattice rounds the
	// inner edge outward, so this is the number to read when the grass looks
	// like it starts too far from the road — not D3_GC_CLEAR_M, which is only
	// what was asked for.
	inner_m: f32,
}

@(private)
d3_ground_cover_layout :: proc(
	quads: []Gc_Quad, lo: [2]f32, pitch: f32, per_cell: int, cover: [D3_GC_BANDS]u8,
) -> Gc_Layout {
	// A cell is `per_cell` quads across on the same lattice, so cells tile
	// exactly and a quad belongs to one of them.
	buckets := make(map[[2]int][dynamic]Gc_Quad, 256, context.temp_allocator)
	for quad in quads {
		key := [2]int{quad.col / per_cell, quad.row / per_cell}
		if key not_in buckets {
			buckets[key] = make([dynamic]Gc_Quad, 0, per_cell*per_cell, context.temp_allocator)
		}
		bucket := &buckets[key]
		append(bucket, quad)
	}

	out := Gc_Layout{
		cells   = make([]d3.Ground_Cell, len(buckets), context.temp_allocator),
		zones   = make([]Gc_Zone, len(buckets), context.temp_allocator),
		inner_m = max(f32),
	}
	for quad in quads { out.inner_m = min(out.inner_m, quad.su) }
	// Iteration order over a map is not stable, and the cell list is written
	// into every route's track.vis: sort by lattice key, row then column, so
	// two exports of the same venue produce the same file.
	keys := make([dynamic][2]int, 0, len(buckets), context.temp_allocator)
	for key in buckets { append(&keys, key) }
	slice.sort_by(keys[:], proc(a, b: [2]int) -> bool {
		return a[1] < b[1] || (a[1] == b[1] && a[0] < b[0])
	})

	for key, index in keys {
		bucket := buckets[key]
		// Points are shared inside a cell, so a 4x4 patch is 25 of them rather
		// than 128. The index map is local to the cell, as the format requires.
		local := make(map[[2]int]u16, 64, context.temp_allocator)
		points := make([dynamic][3]f32, 0, 32, context.temp_allocator)
		tris := make([dynamic]d3.Ground_Tri, 0, 2*len(bucket), context.temp_allocator)
		point_of :: proc(
			local: ^map[[2]int]u16, points: ^[dynamic][3]f32, lo: [2]f32, pitch: f32,
			col, row: int, y: f32,
		) -> u16 {
			if at, seen := local[{col, row}]; seen { return at }
			at := u16(len(points))
			append(points, [3]f32{lo[0] + f32(col)*pitch, y, lo[1] + f32(row)*pitch})
			local[{col, row}] = at
			return at
		}
		for quad in bucket {
			a := point_of(&local, &points, lo, pitch, quad.col, quad.row, quad.y[0])
			b := point_of(&local, &points, lo, pitch, quad.col+1, quad.row, quad.y[1])
			c := point_of(&local, &points, lo, pitch, quad.col+1, quad.row+1, quad.y[2])
			d := point_of(&local, &points, lo, pitch, quad.col, quad.row+1, quad.y[3])
			grows := cover[quad.band]
			append(&tris, d3.Ground_Tri{i = {a, b, c}, cover = grows})
			append(&tris, d3.Ground_Tri{i = {a, c, d}, cover = grows})
			// Weighted by the band's own lattice, so the solve below can work
			// in one number per cell.
			m := D3_GC_BAND_STEP[quad.band]
			out.zones[index].area += pitch * pitch / (m * m)
		}
		out.cells[index] = {points = points[:], tris = tris[:]}
		sum := [2]f32{}
		for p in points { sum += {p.x, p.z} }
		out.zones[index].centre = sum / f32(len(points))
	}
	return out
}

// Grow the cell until a 210 m disc holds fewer cells than the zone budget
// allows. The ground lattice grows with it, so points per cell hold. An empty
// layout means no ground clear of the road and its verges at this cell size.
@(private = "file")
d3_ground_cover_solve :: proc(
	vf: ^geo.Veg_Field, lo, hi: [2]f32, cover: [D3_GC_BANDS]u8,
) -> (
	layout: Gc_Layout, cell_m: f32, worst_cells: int, worst_ground: f32,
) {
	cell_m = D3_GC_CELL_M
	zone_target := int(f32(D3_GC_ZONE_BUDGET) * D3_GC_HEADROOM)
	for {
		per_cell := d3_ground_cover_quads_per_cell(cell_m)
		pitch := cell_m / f32(per_cell)
		ground, cols, rows := d3_ground_cover_samples(vf, lo, hi, pitch)
		quads := d3_ground_cover_quads(ground, cols, rows, min(vf.reach, D3_GC_COVER_M))
		if len(quads) == 0 { return {}, cell_m, 0, 0 }
		layout = d3_ground_cover_layout(quads, lo, pitch, per_cell, cover)
		worst_cells, worst_ground = d3_ground_cover_worst_disc(layout.zones)
		if worst_cells <= zone_target || cell_m >= D3_GC_CELL_MAX_M { return }
		next := cell_m * math.sqrt(f32(worst_cells) / f32(zone_target))
		cell_m = min(math.ceil(next), D3_GC_CELL_MAX_M)
	}
}

// Writes `grass.grs` into the venue directory. A venue whose terrain is off,
// or whose ground is all road and verge, writes nothing and says so: no cover
// is an ordinary outcome, not a failed export.
d3_write_ground_cover :: proc(
	job: ^Export_Job,
) -> (
	cells: int, msg: string, ok: bool,
) {
	if job.venue_dir == "" { return 0, "not written: a loose road has no venue", true }
	if len(job.venue.order) == 0 { return 0, "not written: no venue surface", true }

	template, template_msg, template_ok := d3.Ground_Cover_Template(job.venue_dir)
	if !template_ok { return 0, template_msg, false }
	cover, card_area, cover_msg, cover_ok := d3_ground_cover_types(template)
	if !cover_ok { return 0, cover_msg, false }

	geometry := &job.venue
	arc := geo.ribbon_arc(geometry.ribbon)
	ds := geo.sample_spacing(geometry.ribbon)
	vf := geo.veg_field_make(&geometry.terrain, geometry.ribbon, arc, ds, job.roughness)
	if !vf.ok { return 0, "not written: the venue has no terrain to grow cover on", true }

	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for p in geometry.mesh.pos {
		lo[0] = min(lo[0], p.x); hi[0] = max(hi[0], p.x)
		lo[1] = min(lo[1], p.z); hi[1] = max(hi[1], p.z)
	}
	if lo[0] > hi[0] { return 0, "not written: the venue surface has no extent", true }

	layout, cell_m, worst_cells, worst_ground := d3_ground_cover_solve(&vf, lo, hi, cover)
	if len(layout.cells) == 0 {
		return 0, "not written: no ground clear of the road and its verges", true
	}
	if worst_cells > D3_GC_ZONE_BUDGET {
		return 0, fmt.tprintf(
			"a 210 m view holds %d cover cells and the engine has %d slots, even at %.0f m cells",
			worst_cells, D3_GC_ZONE_BUDGET, cell_m,
		), false
	}

	// The lattice the engine walks over each triangle. Cards per triangle are
	// its area over the step squared, so the worst disc's band-weighted area
	// sets one inner lattice and every band is a fixed multiple of it.
	budget := f32(D3_GC_CARD_BUDGET) * D3_GC_HEADROOM
	inner := clamp(math.sqrt(worst_ground / budget), D3_GC_STEP_MIN, D3_GC_STEP_MAX)
	// A type outside every band stays zero, which Ground_Cover_Build reads as
	// "keep the donor's own lattice": we do not grow it, so its number is not
	// ours to set.
	steps: [d3.GRS_TYPES]f32
	for band in 0 ..< D3_GC_BANDS {
		steps[cover[band]] = clamp(inner * D3_GC_BAND_STEP[band], D3_GC_STEP_MIN, D3_GC_STEP_MAX)
	}

	data, build_msg, built := d3.Ground_Cover_Build(template, layout.cells, steps, context.temp_allocator)
	if !built { return 0, build_msg, false }
	out := d3.Export_Job{Out = job.venue_dir, Backup = job.installing}
	if write_msg, written := d3.Write_Out(&out, "grass.grs", data); !written {
		return 0, write_msg, false
	}
	// And the budget the solve above assumed, so the engine allocates what we
	// spent rather than whatever the base venue asked for.
	budget_xml, xml_ok := d3.Ground_Cover_Xml(context.temp_allocator)
	if !xml_ok { return 0, "could not build ground_cover.xml", false }
	if write_msg, written := d3.Write_Out(&out, "ground_cover.xml", budget_xml); !written {
		return 0, write_msg, false
	}
	return len(layout.cells), fmt.tprintf(
		"%s; %s; %.0f m cells, cover from %.1f m out to %.0f m, "+
		"lattice %.2f m at the verge out to %.2f m, ground hidden %.0f%% to %.0f%%; "+
		"worst view %d cells and %.0f cards of %d",
		cover_msg, build_msg, cell_m, layout.inner_m, min(vf.reach, D3_GC_COVER_M),
		steps[cover[0]], steps[cover[D3_GC_BANDS-1]],
		card_area[0] / (steps[cover[0]]*steps[cover[0]]) * 100,
		card_area[D3_GC_BANDS-1] / (steps[cover[D3_GC_BANDS-1]]*steps[cover[D3_GC_BANDS-1]]) * 100,
		worst_cells, math.floor(worst_ground / (inner*inner)), D3_GC_CARD_BUDGET,
	), true
}
