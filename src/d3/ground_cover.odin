package d3

// `grass.grs`: the baked ground-cover scatter. Venue scope, shared by every
// route of the venue. The engine reads a triangle mesh of the ground that
// should carry grass out of this file and sprinkles billboard cards over it at
// runtime; the cards themselves live in `ground_cover.pssg`.
//
// Format and the evidence for it: docs/dirt3-ground-cover.md. The parts that
// bind a writer:
//
//   - the four table offsets are hardcoded in the loader, so the type count is
//     8 whatever the header says, and the version must be exactly 7
//   - a cell's box is the `track.vis` tag-1 box of the same index, byte for
//     byte, in every route of the venue. 164905 of 164905 stock boxes agree
//   - a triangle addresses its cell's vertices with one byte, so a cell holds
//     at most 256 of them
//
// The card table, the per-slot scale and weight and the slot names are the
// base venue's art and are carried over from its own file unchanged. We write
// the cells and the per-type lattice step, nothing else. Same posture as
// `read_tracksplit_template`.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

D3_GRS_VERSION :: 7
D3_GRS_TYPES :: 8
D3_GRS_SLOTS :: 8

@(private = "file") CARD_REC :: D3_GRS_SLOTS * 6 * 4 // 192
@(private = "file") SCATTER_REC :: 27 * 4            // 108
@(private = "file") NAME_REC :: 152

@(private = "file") CARDS_AT :: 16
@(private = "file") SCATTER_AT :: CARDS_AT + D3_GRS_TYPES * CARD_REC     // 0x610
@(private = "file") NAMES_AT :: SCATTER_AT + D3_GRS_TYPES * SCATTER_REC  // 0x970
// One trailing u32 after the name blocks, holding the type count again.
@(private = "file") OFFSETS_AT :: NAMES_AT + D3_GRS_TYPES * NAME_REC + 4 // 0xe34

@(private = "file") CELL_HEAD :: 40
@(private = "file") CELL_ALIGN :: 16

// A triangle names its vertices with one byte each.
D3_GRS_CELL_VERTS_MAX :: 256

// Bits 0..2 are cover type A and bit 6 draws it; bits 3..5 are type B and bit 7
// draws it. We emit B only, which is what Monte Carlo, both Norways and Aspen
// do for every triangle they ship.
@(private = "file") FLAGS_B_ONLY :: u8(0x87)

// The two per-vertex fields we have not named. These are the values stock uses
// most: 0xff is half the bytes in the game, and 0x8410 is a neutral grey in
// RGB565 and the commonest u16 in Aspen and Monte Carlo.
@(private = "file") VERTEX_PAD :: u8(0xff)
@(private = "file") VERTEX_TINT :: u16(0x8410)

// Stock winds every ground triangle so the cross product of its first two
// edges, projected on xz, is **negative**: 439000 triangles over five venues
// and not one meaningful exception. The engine's scatter keeps the lattice
// points that fall inside a triangle, and that test reads the sign, so a
// triangle wound the other way yields no cards at all — the venue loads
// clean and grows nothing.
//
// The writer normalises rather than refusing: it holds the points, so it can
// see the winding, and one place knowing the rule beats every caller knowing
// it.
@(private = "file")
xz_cross :: proc(a, b, c: [3]f32) -> f32 {
	return (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
}

// One ground triangle, indexing its cell's own point list.
D3_Ground_Tri :: struct {
	i:     [3]u16,
	cover: u8, // 0..7, which of the eight cover types grows here
}

// One drawable patch of ground. Points are world space; the writer takes the
// box off them and quantises against it, so a caller never sees the encoding.
D3_Ground_Cell :: struct {
	points: [][3]f32,
	tris:   []D3_Ground_Tri,
}

d3_grs_version :: proc(data: []u8) -> (version: u32, ok: bool) {
	if len(data) < OFFSETS_AT { return 0, false }
	return binary_load_u32(data, 0), true
}

// The boxes a file declares, in cell order. This is the tag-1 object list the
// route's `track.vis` has to repeat, which is the only reason it is public.
d3_ground_cover_boxes :: proc(
	data: []u8, allocator := context.allocator,
) -> (
	boxes: []D3_Tile_Box, msg: string, ok: bool,
) {
	version, long_enough := d3_grs_version(data)
	if !long_enough { return nil, "too short to hold a grass.grs header", false }
	if version != D3_GRS_VERSION {
		return nil, fmt.tprintf("grass.grs version %d, the game reads only %d", version, D3_GRS_VERSION), false
	}
	count := int(binary_load_u32(data, 8))
	if !binary_range(len(data), OFFSETS_AT, count*4) {
		return nil, fmt.tprintf("grass.grs declares %d cells its offset table does not fit", count), false
	}
	out := make([]D3_Tile_Box, count, allocator)
	defer if !ok { delete(out, allocator) }
	for i in 0 ..< count {
		at := int(binary_load_u32(data, OFFSETS_AT + i*4))
		if !binary_range(len(data), at, CELL_HEAD) {
			return nil, fmt.tprintf("grass.grs cell %d starts past the end of the file", i), false
		}
		out[i] = {
			lo = {binary_load_f32(data, at+16), binary_load_f32(data, at+20), binary_load_f32(data, at+24)},
			hi = {binary_load_f32(data, at+28), binary_load_f32(data, at+32), binary_load_f32(data, at+36)},
		}
	}
	return out, fmt.tprintf("%d ground cover cells", count), true
}

// The base venue's own `grass.grs`, whose card table and slot names this
// writer keeps. Reading the `.orig` when there is one matters: a second export
// must take the donor's art, never its own previous output.
d3_ground_cover_template :: proc(dir: string) -> (data: []u8, msg: string, ok: bool) {
	path := d3_stock_path(dir, "grass.grs")
	if path == "" {
		return nil, fmt.tprintf("%s holds no grass.grs to take the cover art from", dir), false
	}
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return nil, fmt.tprintf("could not read %s: %v", path, read_err), false }
	version, long_enough := d3_grs_version(bytes)
	if !long_enough || version != D3_GRS_VERSION {
		return nil, fmt.tprintf("%s is not a version %d grass.grs", path, D3_GRS_VERSION), false
	}
	return bytes, "", true
}

// How many card slots each type declares, off the template's name table. A
// type with none draws nothing, and no stock triangle anywhere in the game
// enables one — so neither may ours.
d3_ground_cover_slots :: proc(template: []u8) -> (slots: [D3_GRS_TYPES]int, ok: bool) {
	if len(template) < OFFSETS_AT { return {}, false }
	for t in 0 ..< D3_GRS_TYPES {
		slots[t] = int(binary_load_u32(template, NAMES_AT + t*NAME_REC + 128))
	}
	return slots, true
}

// Mean card width and face area per type, off the template's card table.
// Width keeps the scatter off the types whose art is an 8 m reed strip; area
// is what decides how much ground a card actually hides, which is not the
// same question as how many of them there are.
d3_ground_cover_card_size :: proc(
	template: []u8,
) -> (
	width, area: [D3_GRS_TYPES]f32, ok: bool,
) {
	slots := d3_ground_cover_slots(template) or_return
	for t in 0 ..< D3_GRS_TYPES {
		if slots[t] == 0 { continue }
		w, a: f32
		for s in 0 ..< slots[t] {
			card_w := binary_load_f32(template, CARDS_AT + t*CARD_REC + s*24)
			card_h := binary_load_f32(template, CARDS_AT + t*CARD_REC + s*24 + 4)
			w += card_w
			a += card_w * card_h
		}
		width[t] = w / f32(slots[t])
		area[t] = a / f32(slots[t])
	}
	return width, area, true
}

// One cell: header, box, quantised points, then the triangles, each checked
// and rewound as it goes out.
@(private = "file")
gc_write_cell :: proc(
	w: ^Binary_Writer, cell: D3_Ground_Cell, index: int, slots: [D3_GRS_TYPES]int,
) -> (
	flipped: int, msg: string, ok: bool,
) {
	if len(cell.points) == 0 || len(cell.tris) == 0 {
		return 0, fmt.tprintf("ground cover cell %d is empty", index), false
	}
	if len(cell.points) > D3_GRS_CELL_VERTS_MAX {
		return 0, fmt.tprintf(
			"ground cover cell %d holds %d points; a triangle indexes them with one byte, so %d is the most",
			index, len(cell.points), D3_GRS_CELL_VERTS_MAX,
		), false
	}
	if len(cell.tris) > int(max(u16)) {
		return 0, fmt.tprintf("ground cover cell %d holds %d triangles", index, len(cell.tris)), false
	}

	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	for p in cell.points {
		for axis in 0 ..< 3 {
			lo[axis] = min(lo[axis], p[axis])
			hi[axis] = max(hi[axis], p[axis])
		}
	}

	binary_write_u16(w, u16(len(cell.points)))
	binary_write_u16(w, u16(len(cell.tris)))
	// The loader writes a vertex pointer and a triangle pointer into these
	// twelve bytes once the file is in memory. On disk they are zero.
	for _ in 0 ..< 12 { binary_write_u8(w, 0) }
	for axis in 0 ..< 3 { binary_write_f32(w, lo[axis]) }
	for axis in 0 ..< 3 { binary_write_f32(w, hi[axis]) }

	for p in cell.points {
		binary_write_u16(w, quantise(p.x, lo.x, hi.x, 65535))
		binary_write_u16(w, quantise(p.z, lo.z, hi.z, 65535))
		binary_write_u8(w, u8(quantise(p.y, lo.y, hi.y, 255)))
		binary_write_u8(w, VERTEX_PAD)
		binary_write_u16(w, VERTEX_TINT)
	}
	for tri, at in cell.tris {
		if tri.cover >= D3_GRS_TYPES {
			return 0, fmt.tprintf(
				"ground cover cell %d triangle %d names cover type %d", index, at, tri.cover,
			), false
		}
		if slots[tri.cover] == 0 {
			return 0, fmt.tprintf(
				"ground cover cell %d triangle %d grows cover type %d, which the venue's art gives no cards",
				index, at, tri.cover,
			), false
		}
		for corner in 0 ..< 3 {
			if int(tri.i[corner]) >= len(cell.points) {
				return 0, fmt.tprintf(
					"ground cover cell %d triangle %d names point %d of %d",
					index, at, tri.i[corner], len(cell.points),
				), false
			}
		}
		order := tri.i
		if xz_cross(cell.points[order[0]], cell.points[order[1]], cell.points[order[2]]) > 0 {
			order[1], order[2] = order[2], order[1]
			flipped += 1
		}
		for corner in 0 ..< 3 { binary_write_u8(w, u8(order[corner])) }
		binary_write_u8(w, FLAGS_B_ONLY | (tri.cover << 3))
	}
	return flipped, "", true
}

@(private = "file")
quantise :: proc(value, lo, hi: f32, scale: f32) -> u16 {
	span := hi - lo
	if span <= 0 { return 0 }
	q := math.round((value - lo) / span * scale)
	return u16(clamp(q, 0, scale))
}

// `template` supplies everything but the cells: the card table, the per-slot
// scale and weight, and the slot names. `step` overrides each type's lattice
// pitch in metres, which is the first number of its scatter triple and the one
// knob that sets how many cards a square metre of ground yields. A zero step
// leaves that type's pitch as the template has it: a type nothing grows keeps
// the donor's number, and a 0 m pitch never reaches the file.
d3_ground_cover_build :: proc(
	template: []u8,
	cells: []D3_Ground_Cell,
	step: [D3_GRS_TYPES]f32,
	allocator := context.allocator,
) -> (
	out: []u8, msg: string, ok: bool,
) {
	if len(template) < OFFSETS_AT {
		return nil, "the ground cover template is too short to hold its tables", false
	}
	if len(cells) == 0 { return nil, "ground cover needs at least one cell", false }
	slots, slots_ok := d3_ground_cover_slots(template)
	if !slots_ok { return nil, "the ground cover template declares no slot counts", false }

	w := binary_writer(allocator)
	defer binary_writer_delete(&w)
	flipped := 0

	// Header and the three art tables, verbatim, then our own cell count and
	// lattice steps over the top.
	binary_write(&w, template[:OFFSETS_AT])
	binary_patch_u32(&w, 8, u32(len(cells)))
	for t in 0 ..< D3_GRS_TYPES {
		if slots[t] == 0 || step[t] == 0 { continue }
		binary_patch_f32(&w, SCATTER_AT + t*SCATTER_REC, step[t])
	}

	// The offset table holds absolute file offsets; the loader turns them into
	// pointers in place by adding the buffer base.
	table, table_ok := binary_reserve(&w, len(cells)*4)
	if !table_ok { return nil, "could not reserve the ground cover offset table", false }
	binary_align(&w, CELL_ALIGN)

	for cell, index in cells {
		binary_patch_u32(&w, table + index*4, u32(len(w.data)))
		cell_flipped, cell_msg, cell_ok := gc_write_cell(&w, cell, index, slots)
		if !cell_ok { return nil, cell_msg, false }
		flipped += cell_flipped
		// Every cell but the last is padded; the file itself ends unpadded.
		if index != len(cells)-1 { binary_align(&w, CELL_ALIGN) }
	}

	if !w.ok { return nil, "the ground cover writer overran its buffer", false }
	points, tris := 0, 0
	for cell in cells { points += len(cell.points); tris += len(cell.tris) }
	wound := flipped == 0 ? "" : fmt.tprintf(", %d wound back the way the scatter reads", flipped)
	return slice.clone(w.data[:], allocator),
		fmt.tprintf(
			"%d cells, %d points, %d triangles%s, %d KB",
			len(cells), points, tris, wound, len(w.data)/1024,
		), true
}


// `ground_cover.xml`: what the engine sizes its card pool and its zone slots
// from, read once at load. BinXML, four elements, eight attributes, 400 to 420
// bytes in all nineteen venues that ship one.
//
// We write it rather than inheriting the base venue's, for one reason: the
// numbers in it are the budget our own scatter is solved against, and reading
// a donor's would mean solving against the least any venue grants (12000) so
// a pack built on Monte Carlo still fits. Writing it makes the budget a
// constant on both sides.
//
// The values are Finland Rally's, unchanged. Six stock venues ship exactly
// this, which is what makes it a known-good configuration rather than a guess:
// the pool is the largest the game ever asks for, and the draw distance and
// both cull pairs come with it.
D3_GC_XML_MAX_ITEMS :: 20000
D3_GC_XML_ZONES :: 160

d3_ground_cover_xml :: proc(allocator := context.allocator) -> (out: []u8, ok: bool) {
	root := bxml_node("ground_cover", nil, {
		bxml_node("system", bxml_attrs(
			{"maxitems", fmt.tprintf("%d", D3_GC_XML_MAX_ITEMS)},
			{"zones", fmt.tprintf("%d", D3_GC_XML_ZONES)},
		)),
		bxml_node("mainscene", bxml_attrs(
			{"draw_distance", "210"}, {"infield_cull", "0.7"}, {"edge_cull", "0.2"},
		)),
		bxml_node("rearviewmirror", bxml_attrs(
			{"draw_distance", "75.0"}, {"infield_cull", "1.3"}, {"edge_cull", "1.0"},
		)),
	})
	return bxml_build(root, allocator)
}
