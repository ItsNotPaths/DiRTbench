package d3

// Dirt 3 visibility file. Two trees and a mask: section 1 cuts the route into
// view cells and section 4 writes that same subdivision out as boxes, section 3
// is a spatial tree over the drawables, and section 2 holds one mask for each
// cell saying what that cell's groups draw. Every mask bit is set for now, so
// the file culls by box and not yet by cell.

import "core:fmt"
import "core:os"
import "core:path/filepath"

D3_VIS_HEADER_SIZE :: 128

// One drawable the engine can test independently of the mask: its tag, its
// per-tag registration index (not a file position — see the format doc), and
// its world-space box.
D3_Vis_Object :: struct {
	tag:    u32,
	index:  u32,
	lo, hi: [3]f32,
}

d3_vis_object_bounds :: proc(objects: []D3_Vis_Object) -> (lo, hi: [3]f32) {
	lo = objects[0].lo; hi = objects[0].hi
	for obj in objects[1:] {
		for k in 0..<3 { lo[k] = min(lo[k], obj.lo[k]); hi[k] = max(hi[k], obj.hi[k]) }
	}
	return
}

// --- the view cell tree -----------------------------------------------------
//
// Section 1 is a kd-tree over the route and section 4 is the same subdivision
// written out as boxes, so one build answers both: a child is its parent's box
// cut at the parent's own split plane, with 0 mismatches over the 176408
// internal nodes of the install. A camera resolves to one leaf, and that leaf's
// mask is what decides a group the frustum fully contains.
//
// Cells only earn their size where a camera can be, which is on or just over
// the route's own surface. Everywhere else stays one big cell, which is why
// stock cells run from 10 m on a side to 2.5 km.
//
// CAUTION: the band is the route's surface, not every tag-0 box. Tag 0 also
// holds the venue LOD and its skirt, which reach 2 km past the road in every
// direction. Subdividing that spends the budget on ground no camera visits:
// measured on dirtbench route_0, 78% of 4096 cells sat more than 800 m from the
// road, the node cap was hit, and cells came out at 76 m rather than the 32 m
// asked for.

D3_VIS_CELL_SIZE :: 32 // metres; stock's cells run 10 to 47 m on a side

// Air over the surface that still holds a camera. Bonnet, chase and replay
// cameras all sit inside this band.
D3_VIS_CELL_HEADROOM :: 24

// Child indices are 13 bits, so 8191 nodes and 4096 cells is the ceiling.
D3_VIS_CELL_NODES_MAX :: 8191

// The split plane is a 20-bit fraction of the root box, not of the node's own.
D3_VIS_PLANE_SCALE :: (1<<20)-1

@(private = "file")
D3_Vis_Cell :: struct {
	lo, hi:    [3]f32,
	axis:      int, // -1 on a leaf
	plane:     f32,
	min_child: int, // the maximum-side child is min_child - 1
	mask_at:   int, // a leaf's coded mask, relative to section 2's start
}

@(private = "file")
d3_vis_cell_holds_a_camera :: proc(cell: D3_Vis_Cell, band: []D3_Vis_Object) -> bool {
	for box in band {
		if cell.lo[0] >= box.hi[0] || cell.hi[0] <= box.lo[0] { continue }
		if cell.lo[2] >= box.hi[2] || cell.hi[2] <= box.lo[2] { continue }
		if cell.lo[1] >= box.hi[1]+D3_VIS_CELL_HEADROOM || cell.hi[1] <= box.lo[1] { continue }
		return true
	}
	return false
}

// Breadth first, so the two children of a node always land on consecutive
// indices — the file states only the minimum side and takes the maximum side
// as one less.
@(private = "file")
d3_vis_cell_tree :: proc(lo, hi: [3]f32, band: []D3_Vis_Object, allocator := context.allocator) -> []D3_Vis_Cell {
	cells := make([dynamic]D3_Vis_Cell, 0, 64, allocator)
	append(&cells, D3_Vis_Cell{lo = lo, hi = hi, axis = -1})
	for at := 0; at < len(cells); at += 1 {
		if len(cells)+2 > D3_VIS_CELL_NODES_MAX { break }
		cell := cells[at]
		axis := 0
		for k in 1..<3 { if cell.hi[k]-cell.lo[k] > cell.hi[axis]-cell.lo[axis] { axis = k } }
		if cell.hi[axis]-cell.lo[axis] <= D3_VIS_CELL_SIZE { continue }
		if !d3_vis_cell_holds_a_camera(cell, band) { continue }

		mid := (cell.lo[axis]+cell.hi[axis])/2
		max_lo := cell.lo; max_lo[axis] = mid
		min_hi := cell.hi; min_hi[axis] = mid
		cells[at].axis = axis; cells[at].plane = mid; cells[at].min_child = len(cells)+1
		append(&cells, D3_Vis_Cell{lo = max_lo, hi = cell.hi, axis = -1})
		append(&cells, D3_Vis_Cell{lo = cell.lo, hi = min_hi, axis = -1})
	}
	return cells[:]
}

@(private = "file")
d3_vis_plane_field :: proc(plane, lo, hi: f32) -> u32 {
	if hi <= lo { return 0 }
	at := i64(f64(plane-lo)/f64(hi-lo)*f64(D3_VIS_PLANE_SCALE) + 0.5)
	return u32(clamp(at, 0, D3_VIS_PLANE_SCALE))
}

// Section 1's records. A leaf opens with a zero and names its coded mask; the
// high byte of the third u16 is 1 for the coded storage. A node packs its
// children, axis and quantized plane into the three u16s.
@(private = "file")
d3_vis_write_cells :: proc(w: ^Binary_Writer, cells: []D3_Vis_Cell, section_2: int, lo, hi: [3]f32) {
	for cell in cells {
		if cell.axis < 0 {
			at := section_2+cell.mask_at
			binary_write_u16(w, 0)
			binary_write_u16(w, u16(at))
			binary_write_u16(w, u16(u32(at)>>16) | 0x100)
			continue
		}
		max_child := cell.min_child-1
		field := d3_vis_plane_field(cell.plane, lo[cell.axis], hi[cell.axis])
		binary_write_u16(w, u16(cell.min_child) | u16(cell.axis)<<13 | u16(max_child>>12&1)<<15)
		binary_write_u16(w, u16(max_child&0x0fff) | u16(field>>16)<<12)
		binary_write_u16(w, u16(field&0xffff))
	}
	binary_align(w, 16)
}

// --- what a cell sees -------------------------------------------------------
//
// How far a cell reaches. Stock's own masks put a cliff right here for every
// tag that is not terrain: measured over the partial cells of the finland,
// kenya and norway rally routes, ornaments and tree models are 65-81% visible
// at 200 m, 19-32% at 300 and 0-14% at 400. Past that the far forest is
// billboard clouds, whose one huge box keeps them in reach of every cell.
//
// Drawing tree models a kilometre out as well as the clouds over the same
// ground is what an all-visible mask does, and the two then fight.
D3_VIS_REACH :: f32(400)

@(private = "file")
d3_vis_in_reach :: proc(cell_lo, cell_hi, lo, hi: [3]f32) -> bool {
	gap := f32(0)
	for k in ([2]int{0, 2}) {
		side := max(lo[k]-cell_hi[k], cell_lo[k]-hi[k], 0)
		gap += side*side
	}
	return gap <= D3_VIS_REACH*D3_VIS_REACH
}

// Terrain is never cut. There are only tens of surface tiles, so culling them
// buys nothing, and stock still draws 30 to 55% of them at 1200 m. Their bits
// are the same in every cell, so they and the group bits over them are laid
// down once and every cell starts from that.
@(private = "file")
d3_vis_surface_mask :: proc(mask: []u8, groups: []D3_Vis_Group) {
	lit := make([]bool, len(groups), context.temp_allocator)
	for at := len(groups)-1; at >= 0; at -= 1 {
		group := groups[at]
		for obj, j in group.own {
			if obj.tag != 0 { continue }
			bit := group.first_bit+1+j
			mask[bit/8] |= 1<<u8(bit&7)
			lit[at] = true
		}
		if group.min_child != 0 && (lit[at+1] || lit[group.min_child]) { lit[at] = true }
		if lit[at] { mask[group.first_bit/8] |= 1<<u8(group.first_bit&7) }
	}
}

// Adds everything else this cell reaches. A group's box contains its subtree,
// so a group out of reach takes its whole subtree with it and never looks at an
// object. A group's own bit gates that subtree, so it is the OR of what is
// under it.
@(private = "file")
d3_vis_cell_mask :: proc(mask: []u8, cell_lo, cell_hi: [3]f32, groups: []D3_Vis_Group, at: int) -> (lit: bool) {
	group := groups[at]
	if !d3_vis_in_reach(cell_lo, cell_hi, group.lo, group.hi) { return false }
	for obj, j in group.own {
		if obj.tag == 0 || !d3_vis_in_reach(cell_lo, cell_hi, obj.lo, obj.hi) { continue }
		bit := group.first_bit+1+j
		mask[bit/8] |= 1<<u8(bit&7)
		lit = true
	}
	if group.min_child != 0 {
		if d3_vis_cell_mask(mask, cell_lo, cell_hi, groups, at+1) { lit = true }
		if d3_vis_cell_mask(mask, cell_lo, cell_hi, groups, group.min_child) { lit = true }
	}
	if lit { mask[group.first_bit/8] |= 1<<u8(group.first_bit&7) }
	return
}

// Section 2's storage: a token byte, then either a repeated byte or that many
// verbatim bytes. Runs and literals both stop at 127. Stock gives every leaf a
// record of its own — no two leaves of any stock file share one offset — so
// identical masks are coded again rather than pointed at twice.
@(private = "file")
d3_vis_mask_encode :: proc(out: ^[dynamic]u8, mask: []u8) {
	literal := 0 // start of the bytes still waiting to be copied verbatim
	for at := 0; at < len(mask); {
		run := 1
		for at+run < len(mask) && mask[at+run] == mask[at] && run < 127 { run += 1 }
		if run < 3 { at += run; continue }
		d3_vis_mask_literal(out, mask[literal:at])
		append(out, 0x80|u8(run)); append(out, mask[at])
		at += run
		literal = at
	}
	d3_vis_mask_literal(out, mask[literal:])
}

@(private = "file")
d3_vis_mask_literal :: proc(out: ^[dynamic]u8, bytes: []u8) {
	for at := 0; at < len(bytes); {
		n := min(127, len(bytes)-at)
		append(out, u8(n))
		append(out, ..bytes[at:at+n])
		at += n
	}
}

// One coded mask for each leaf, each started from the shared surface bits.
// Each leaf's `mask_at` is set to its record's start inside the coded bytes;
// `visible` counts the set bits, for the build message.
@(private = "file")
d3_vis_code_masks :: proc(cells: []D3_Vis_Cell, groups: []D3_Vis_Group, mask_bytes: int) -> (coded: [dynamic]u8, visible: int) {
	surface_bits := make([]u8, mask_bytes, context.temp_allocator)
	d3_vis_surface_mask(surface_bits, groups)
	mask := make([]u8, mask_bytes, context.temp_allocator)
	coded = make([dynamic]u8, 0, 64*len(cells), context.temp_allocator)
	for &cell in cells {
		if cell.axis >= 0 { continue }
		copy(mask, surface_bits)
		d3_vis_cell_mask(mask, cell.lo, cell.hi, groups, 0)
		for b in mask { visible += card(transmute(bit_set[0..<8;u8])b) }
		cell.mask_at = len(coded)
		d3_vis_mask_encode(&coded, mask)
		for len(coded)%16 != 0 { append(&coded, 0) }
	}
	return
}

// --- the group tree ---------------------------------------------------------
//
// Section 3 is a spatial tree over the drawables. The engine tests a group's
// box once and takes its whole subtree from the mask, or skips it; only a group
// the frustum cuts falls back to testing every box the group holds. One group
// over everything is that fallback, on every object of every frame.
//
// Stock's shape, measured over the 60147 groups of all 113 files: the root box
// is the tight bound of every object, each child is its parent halved on the
// parent's longest axis with the maximum side written first, and an object that
// crosses the cut stays on the parent. So a group box is a spatial cell, not a
// bound of its contents, and it contains its subtree by construction.

// Objects at or below which a group stops splitting. Stock averages 12 boxes
// per group.
D3_VIS_GROUP_LOAD :: 16

// A zero-extent box never crosses a cut, so a cluster of them would halve the
// box forever. Stock's deepest group tree is 14.
D3_VIS_GROUP_DEPTH :: 32

@(private = "file")
D3_Vis_Group :: struct {
	lo, hi:    [3]f32,
	own:       []D3_Vis_Object, // the boxes this group carries itself
	depth:     u16,
	min_child: int,             // 0 on a leaf; the maximum-side child is the next record
	first_bit: int,             // where this group's bit run starts in every mask
}

// Emits this group, then its two subtrees, depth first. `objects` is reordered
// in place so every group owns one contiguous run of it.
@(private = "file")
d3_vis_group_split :: proc(groups: ^[dynamic]D3_Vis_Group, objects: []D3_Vis_Object, lo, hi: [3]f32, depth: u16) -> int {
	at := len(groups)
	append(groups, D3_Vis_Group{lo = lo, hi = hi, own = objects, depth = depth})
	if len(objects) <= D3_VIS_GROUP_LOAD || depth >= D3_VIS_GROUP_DEPTH { return at }

	axis := 0
	for k in 1..<3 { if hi[k]-lo[k] > hi[axis]-lo[axis] { axis = k } }
	mid := (lo[axis]+hi[axis])/2

	// Partition three ways: the crossers this group keeps, then the maximum
	// side, then the minimum side.
	crossers := 0
	for i in 0..<len(objects) {
		if objects[i].lo[axis] < mid && objects[i].hi[axis] > mid {
			objects[crossers], objects[i] = objects[i], objects[crossers]; crossers += 1
		}
	}
	upper := crossers
	for i in crossers..<len(objects) {
		if objects[i].lo[axis] >= mid {
			objects[upper], objects[i] = objects[i], objects[upper]; upper += 1
		}
	}
	if crossers == len(objects) { return at } // nothing descends, so splitting gains nothing

	groups[at].own = objects[:crossers]
	max_lo := lo; max_lo[axis] = mid
	min_hi := hi; min_hi[axis] = mid
	d3_vis_group_split(groups, objects[crossers:upper], max_lo, hi, depth+1)
	min_child := d3_vis_group_split(groups, objects[upper:], lo, min_hi, depth+1)
	groups[at].min_child = min_child
	return at
}

// Sets where each group's bit run starts. Bits run breadth first over the
// group tree — the group's own bit, then one for each box it holds — while
// section 3 is written depth first, which is why every record states its own
// run.
@(private = "file")
d3_vis_group_bits :: proc(groups: []D3_Vis_Group) -> (total: int) {
	order := make([dynamic]int, 0, len(groups), context.temp_allocator)
	defer delete(order)
	append(&order, 0)
	for at := 0; at < len(order); at += 1 {
		group := &groups[order[at]]
		group.first_bit = total
		total += 1+len(group.own)
		if group.min_child != 0 { append(&order, order[at]+1); append(&order, group.min_child) }
	}
	return
}

// Section 3's records, depth first, each chained to the next through its own
// offset field.
@(private = "file")
d3_vis_write_groups :: proc(w: ^Binary_Writer, groups: []D3_Vis_Group, section_3: int) -> (tag_counts: [16]u32) {
	group_at := section_3
	for group, i in groups {
		size := 48+32*len(group.own)
		next, next_size := 0, 0
		if i < len(groups)-1 { next = group_at+size; next_size = 48+32*len(groups[i+1].own) }
		for k in 0..<3 { binary_write_f32(w, group.lo[k]) }
		binary_write_u16(w, u16(group.first_bit/8)); binary_write_u16(w, u16(group.first_bit%8))
		for k in 0..<3 { binary_write_f32(w, group.hi[k]) }
		binary_write_u16(w, u16(i)); binary_write_u16(w, u16(len(group.own)))
		binary_write_u32(w, u32(next))
		binary_write_u16(w, u16(next_size)); binary_write_u16(w, group.depth)
		binary_write_u32(w, 0)
		binary_write_u32(w, group.min_child != 0 ? 2 : 0)
		for obj in group.own {
			for k in 0..<3 { binary_write_f32(w, obj.lo[k]) }
			binary_write_u32(w, obj.tag)
			for k in 0..<3 { binary_write_f32(w, obj.hi[k]) }
			binary_write_u32(w, obj.index)
			if obj.tag < 16 { tag_counts[obj.tag] += 1 }
		}
		group_at += size
	}
	return
}

// The sixteen per-tag counts at 0x40..0x7F of any track.vis, stock or ours —
// only the header needs to parse, so this reads far less than a full file.
d3_vis_read_header_tag_counts :: proc(data: []u8) -> (counts: [16]u32, ok: bool) {
	if len(data) < D3_VIS_HEADER_SIZE { return {}, false }
	for tag in 0..<16 { counts[tag] = binary_load_u32(data, 0x40+tag*4) }
	return counts, true
}

@(private = "file")
d3_vis_tag_span :: proc(counts: [16]u32) -> int {
	n := 0
	for c in counts { if c > 0 { n += 1 } }
	return n
}

// Every object of `tag` in a real (possibly multi-group) track.vis, keyed by
// its per-tag id. Section 3 chains every group in the file through its own
// "offset of the next group" field regardless of tree nesting, so following
// that chain visits every object without needing to walk the BSP itself. Used
// to borrow a real box for an id this codebase can derive independently of
// `ornaments.bin` —
// see vis_allvisible.odin's objects.ens objects.
d3_vis_read_tag_boxes :: proc(data: []u8, tag: u32, allocator := context.allocator) -> (boxes: map[u32]D3_Tile_Box, ok: bool) {
	if len(data) < D3_VIS_HEADER_SIZE { return nil, false }
	out := make(map[u32]D3_Tile_Box, allocator)
	at := int(binary_load_u32(data, 0x1c))
	for {
		if !binary_range(len(data), at, 48) { delete(out); return nil, false }
		box_count := int(binary_load_u16(data, at+30))
		for i in 0 ..< box_count {
			item_at := at + 48 + i*32
			if !binary_range(len(data), item_at, 32) { delete(out); return nil, false }
			if binary_load_u32(data, item_at+12) != tag { continue }
			id := binary_load_u32(data, item_at+28)
			box: D3_Tile_Box
			for k in 0 ..< 3 { box.lo[k] = binary_load_f32(data, item_at+k*4); box.hi[k] = binary_load_f32(data, item_at+16+k*4) }
			out[id] = box
		}
		next := int(binary_load_u32(data, at+32))
		if next == 0 { break }
		at = next
	}
	return out, true
}

// `header_floor` raises a tag's header count (0x40+tag*4) to at least this
// value even when `objects` holds fewer of that tag. The game reads that
// count to size an allocation it fills from its own independently-built
// per-tag item list, with no bound check against the size. A floor borrowed
// from a donor file's real count is a safety margin for a tag this codebase
// cannot yet derive a correct count for on its own.
// `band` is the route's own drivable surface, the ground a camera follows. It
// decides where cells are cut and nothing else; an empty one leaves the whole
// route as a single cell.
d3_vis_build :: proc(objects, band: []D3_Vis_Object, header_floor := [16]u32{}, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	if len(objects) == 0 { return nil, "Dirt 3 VIS needs at least one object", false }
	if len(objects) > 65535 { return nil, "Dirt 3 VIS has too many objects for one group's box count", false }

	// The tree reorders what it is given, so it gets a copy of the caller's.
	ordered := make([]D3_Vis_Object, len(objects), context.temp_allocator)
	copy(ordered, objects)
	lo, hi := d3_vis_object_bounds(ordered)
	groups := make([dynamic]D3_Vis_Group, 0, 64, context.temp_allocator)
	d3_vis_group_split(&groups, ordered, lo, hi, 0)
	if len(groups) > 65535 { return nil, "Dirt 3 VIS has too many groups to index", false }
	for group in groups {
		// a record must fit the u16 next-size field of the record before it
		if 48+32*len(group.own) > 65535 { return nil, "a Dirt 3 VIS group keeps too many crossers for one record", false }
	}
	total_bits := d3_vis_group_bits(groups[:])

	cells := d3_vis_cell_tree(lo, hi, band, context.temp_allocator)
	leaves := (len(cells)+1)/2 // every split adds two nodes and one leaf

	// One bit for each group and one for each box. VIS masks are padded to 16
	// bytes; unused padding bits stay zero.
	mask_bytes, aligned := binary_align_up((total_bits+7)/8, 16)
	if !aligned { return nil, "could not align Dirt 3 VIS mask", false }

	// Section 2 is coded before section 1, because a leaf record names where
	// its own mask starts.
	coded, visible := d3_vis_code_masks(cells, groups[:], mask_bytes)

	section_1 := D3_VIS_HEADER_SIZE
	section_2, cells_aligned := binary_align_up(section_1+6*len(cells), 16)
	if !cells_aligned { return nil, "could not align Dirt 3 VIS cell tree", false }
	section_3 := section_2+len(coded)
	section_3_size := 48*len(groups)+32*len(objects)
	section_4 := section_3+section_3_size

	w := binary_writer(allocator)
	defer if !ok { binary_writer_delete(&w) }
	_, reserved := binary_reserve(&w, D3_VIS_HEADER_SIZE)
	if !reserved { return nil, "could not reserve Dirt 3 VIS header", false }

	// Section 1: the cell tree.
	if section_3 > 0x00ffffff { return nil, "Dirt 3 VIS mask offset exceeds 24 bits", false }
	d3_vis_write_cells(&w, cells, section_2, lo, hi)

	// Section 2: the coded masks, one for each cell.
	binary_write(&w, coded[:])

	// Section 3: the group tree.
	tag_counts := d3_vis_write_groups(&w, groups[:], section_3)

	// Section 4: the same subdivision as boxes, one for each node, no occluder
	// hulls.
	for cell, i in cells {
		for k in 0..<3 { binary_write_f32(&w, cell.lo[k]) }
		for k in 0..<3 { binary_write_f32(&w, cell.hi[k]) }
		binary_write_u32(&w, 0); binary_write_u32(&w, u32(i))
	}
	if !w.ok || len(w.data) != section_4+32*len(cells) { return nil, "could not encode Dirt 3 VIS sections", false }

	// Header.
	binary_patch_u32(&w, 0x00, 4)
	binary_patch_u32(&w, 0x04, u32(len(cells))); binary_patch_u32(&w, 0x08, u32(leaves))
	binary_patch_u32(&w, 0x0c, u32(len(groups))); binary_patch_u32(&w, 0x10, u32(mask_bytes))
	binary_patch_u32(&w, 0x14, u32(section_1)); binary_patch_u32(&w, 0x18, u32(section_2))
	binary_patch_u32(&w, 0x1c, u32(section_3)); binary_patch_u32(&w, 0x2c, u32(section_4))
	for k in 0..<3 { binary_patch_f32(&w, 0x20+k*4, lo[k]); binary_patch_f32(&w, 0x30+k*4, hi[k]) }
	for tag in 0..<16 { binary_patch_u32(&w, 0x40+tag*4, max(tag_counts[tag], header_floor[tag])) }
	if !w.ok { return nil, "could not finalize Dirt 3 VIS header", false }

	out = w.data[:]
	w.data = nil
	return out, fmt.tprintf(
		"%d view cells seeing %.0f%% of %d objects across %d tags, in a tree of %d groups",
		leaves, 100*f32(visible)/f32(leaves*total_bits), len(objects),
		d3_vis_tag_span(tag_counts), len(groups),
	), true
}

// --- the census -------------------------------------------------------------
//
// VIS is venue-scoped: the engine numbers the venue tracksplit's tiles first
// and the route's own routesplit tiles after, one ascending run each, and a
// route-only file therefore names the wrong drawable for every index. So the
// objects are censused off the files themselves after both PSSGs are written,
// never derived from the collision soup a second time.
//
// Tag 0 is the surface. Tag 3 is `trees.bin`, whose own `instance_id` is the
// real tag-3 id. Tag 2 is deliberately absent: `ornaments.bin` does not carry
// its tag-2 id at all (that lives in `ornaments.xml`), and a wrong id there is
// a confirmed crash while leaving an object out of tag 2 is confirmed safe.
//
// The two tag-0 runs are contiguous, so the route's lead is exactly the venue
// tracksplit's tile count. Measured over every playable stock route in the
// install: tag-0 count equals venue tiles plus route tiles exactly, and the
// route's own tile boxes match that window with 0.000 m error, on all 94
// routes that ship a routesplit. The only stock file that disagrees is
// `moosylvania_rally/route_3`, in an unregistered dev venue the game cannot
// load. Tag 0 addresses surfaces by slot position, so this is the number that
// decides whether the terrain draws at all.

// Every instance of a placement file as an object of `tag`, indexed by its
// cooked id: trees are tag 3, ornaments tag 2.
@(private = "file")
d3_vis_append_placements :: proc(out: ^[dynamic]D3_Vis_Object, path: string, tag: u32) -> (added: int, msg: string, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return 0, fmt.tprintf("could not read %s: %v", path, read_err), false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, fmt.tprintf("%s: not a recognised placement file", path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, fmt.tprintf("%s: %s", path, read_msg), false }
	for inst, i in instances {
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, fmt.tprintf("%s: instance %d names an unknown reference %d", path, i, inst.reference_id), false
		}
		append(out, D3_Vis_Object{tag = tag, index = inst.instance_id, lo = lo, hi = hi})
		added += 1
	}
	return added, "", true
}

// Every drawable this route registers, in the engine's own registration order.
// `venue_dir` holds `tracksplit.pssg`; `route_dir` holds `routesplit.pssg` and
// the two placement files.
//
// `ground_cover` adds tag 1 off `venue_dir/grass.grs`. Its cell boxes are the
// tag-1 boxes, the same bytes in the same order, on all 164905 stock cells of
// the install — so the two are one list and neither is derived from the other.
// Off unless this export wrote that file: the donor's hardlinked copy
// describes the base venue's ground, not ours.
d3_vis_census_objects :: proc(
	route_dir, venue_dir: string,
	ground_cover := false,
	allocator := context.allocator,
) -> (
	objects: []D3_Vis_Object,
	band: []D3_Vis_Object,
	msg: string,
	ok: bool,
) {
	out := make([dynamic]D3_Vis_Object, allocator)
	defer if !ok { delete(out) }

	// Two ascending runs, not one list reversed as a unit: reversing the
	// concatenation scrambles which real drawable an index names.
	tracksplit, _ := filepath.join({venue_dir, "tracksplit.pssg"}, context.temp_allocator)
	routesplit, _ := filepath.join({route_dir, "routesplit.pssg"}, context.temp_allocator)
	venue_tiles, route_tiles := 0, 0
	for path, source in ([]string{tracksplit, routesplit}) {
		tiles, tile_msg, tile_ok := d3_read_surface_tile_boxes(path, context.temp_allocator)
		if !tile_ok { return nil, nil, tile_msg, false }
		if source == 0 { venue_tiles = len(tiles) } else { route_tiles = len(tiles) }
		// Within one source the engine enumerates tile nodes in reverse
		// traversal order.
		for i in 0 ..< len(tiles) {
			box := tiles[len(tiles)-1-i]
			append(&out, D3_Vis_Object{tag = 0, index = u32(len(out)), lo = box.lo, hi = box.hi})
		}
	}

	cover := 0
	if ground_cover {
		path, _ := filepath.join({venue_dir, "grass.grs"}, context.temp_allocator)
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil { return nil, nil, fmt.tprintf("could not read %s: %v", path, read_err), false }
		boxes, boxes_msg, boxes_ok := d3_ground_cover_boxes(data, context.temp_allocator)
		if !boxes_ok { return nil, nil, fmt.tprintf("%s: %s", path, boxes_msg), false }
		for box, i in boxes {
			append(&out, D3_Vis_Object{tag = 1, index = u32(i), lo = box.lo, hi = box.hi})
		}
		cover = len(boxes)
	}

	// A route without either file is not an error — 14 stock routes ship no
	// trees — so a missing one contributes nothing.
	counted: [2]int
	for file, i in ([]struct{name: string, tag: u32}{{"ornaments.bin", 2}, {"trees.bin", 3}}) {
		path, _ := filepath.join({route_dir, file.name}, context.temp_allocator)
		if !os.exists(path) { continue }
		added, add_msg, add_ok := d3_vis_append_placements(&out, path, file.tag)
		if !add_ok { return nil, nil, add_msg, false }
		counted[i] = added
	}

	if len(out) == 0 { return nil, nil, "found no drawables to make visible", false }
	// The route's own tiles are the second of the two tag-0 runs, and they are
	// the drivable ground a camera follows. The venue's tracksplit tiles are
	// the LOD and its skirt, which reach kilometres past the road.
	return out[:], out[venue_tiles:venue_tiles+route_tiles], fmt.tprintf(
		"tag 0: %d venue tiles + %d route tiles; tag 1: %d cover cells; tag 2: %d ornaments; tag 3: %d trees",
		venue_tiles, route_tiles, cover, counted[0], counted[1],
	), true
}

d3_vis_census_build :: proc(
	route_dir, venue_dir: string,
	ground_cover := false,
	allocator := context.allocator,
) -> (
	out: []u8,
	msg: string,
	ok: bool,
) {
	objects, band, objects_msg, objects_ok := d3_vis_census_objects(
		route_dir, venue_dir, ground_cover, context.temp_allocator,
	)
	if !objects_ok { return nil, objects_msg, false }

	// Every tag declares exactly what section 3 holds. 103 of the 104 stock
	// routes do, and the game walks each tag's sub-range by this count: a slot
	// declared past what we wrote is never filled, keeps whatever the fresh
	// allocation held, and is freed anyway at teardown.
	//
	// Tag 2 is the one real exception. Dynamic ENS drawables take a
	// registration slot without receiving a box, so the count has to cover
	// their instance ids — ours, never a donor's.
	floor: [16]u32
	ens_msg := "no objects.ens to size tag 2 against"
	if ens_path, _ := filepath.join({route_dir, "objects.ens"}, context.temp_allocator);
	   os.exists(ens_path) {
		data, read_err := os.read_entire_file(ens_path, context.temp_allocator)
		if read_err != nil { return nil, fmt.tprintf("could not read %s: %v", ens_path, read_err), false }
		nodes, parsed := d3_ens_parse(data, context.temp_allocator)
		if !parsed { return nil, "objects.ens did not parse, so tag 2 cannot be sized", false }
		span := d3_ens_instance_id_span(nodes)
		floor[2] = span
		ens_msg = fmt.tprintf("tag 2 sized to %d ens instance ids", span)
	}

	built, build_msg, built_ok := d3_vis_build(objects, band, floor, allocator)
	if !built_ok { return nil, build_msg, false }
	return built, fmt.tprintf("%s; %s; %s", objects_msg, ens_msg, build_msg), true
}

// Runs after both PSSGs are written, because it censuses them.
d3_write_track_vis :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	dir, dir_msg, dir_ok := d3_out_dir(job)
	if !dir_ok { return dir_msg, false }
	if job.Venue_Dir == "" { return "track.vis needs the venue directory tracksplit.pssg lives in", false }
	data, detail, built := d3_vis_census_build(dir, job.Venue_Dir, job.Ground_Cover)
	if !built { return detail, false }
	defer delete(data)
	if write_msg, written := d3_write_out(job, "track.vis", data); !written { return write_msg, false }
	return detail, true
}
