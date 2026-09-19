package d3

// Dirt 3 visibility file, single-cell fallback shape: one view cell over
// every object's bounds, one group, every bit set. A section-1 list opening
// with a zero gives one cell over the whole route, so there is no BSP or PVS to
// generate. Section 3's boxes still cull independently of the mask, so a
// correct box and per-tag registration index matter even in this shape.

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
d3_vis_build_single_cell :: proc(objects: []D3_Vis_Object, header_floor := [16]u32{}, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	if len(objects) == 0 { return nil, "Dirt 3 VIS needs at least one object", false }
	if len(objects) > 65535 { return nil, "Dirt 3 VIS has too many objects for one group", false }

	// One group bit followed by one bit for each object. VIS masks are padded
	// to 16 bytes; unused padding bits stay zero.
	object_bits := 1+len(objects)
	mask_bytes, aligned := binary_align_up((object_bits+7)/8, 16)
	if !aligned { return nil, "could not align Dirt 3 VIS mask", false }
	section_1 := D3_VIS_HEADER_SIZE
	section_2 := section_1+16 // one 6-byte leaf record, padded
	section_3 := section_2+mask_bytes // raw one-cell mask
	group_size := 48+len(objects)*32
	section_4 := section_3+group_size
	lo, hi := d3_vis_object_bounds(objects)

	w := binary_writer(allocator)
	defer if !ok { binary_writer_delete(&w) }
	_, reserved := binary_reserve(&w, D3_VIS_HEADER_SIZE)
	if !reserved { return nil, "could not reserve Dirt 3 VIS header", false }

	// Section 1: one raw-mask leaf. Its first u16 is zero, the engine's
	// supported single-view-cell fallback. b/c hold the 24-bit mask offset.
	if section_2 > 0x00ffffff { return nil, "Dirt 3 VIS mask offset exceeds 24 bits", false }
	binary_write_u16(&w, 0)
	binary_write_u16(&w, u16(section_2))
	binary_write_u16(&w, u16(u32(section_2)>>16))
	binary_align(&w, 16)

	// Section 2: every object visible.
	mask_at, mask_ok := binary_reserve(&w, mask_bytes)
	if !mask_ok { return nil, "could not reserve Dirt 3 VIS mask", false }
	for bit in 0..<object_bits { w.data[mask_at+bit/8] |= 1<<u8(bit&7) }

	// Section 3: one leaf group over every object.
	for k in 0..<3 { binary_write_f32(&w, lo[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // group owns bit 0
	for k in 0..<3 { binary_write_f32(&w, hi[k]) }
	binary_write_u16(&w, 0); binary_write_u16(&w, u16(len(objects)))
	binary_write_u32(&w, 0) // no next group
	binary_write_u16(&w, 0); binary_write_u16(&w, 0) // next size, depth
	binary_write_u32(&w, 0); binary_write_u32(&w, 0) // reserved, leaf branch
	tag_counts: [16]u32
	for obj in objects {
		for k in 0..<3 { binary_write_f32(&w, obj.lo[k]) }
		binary_write_u32(&w, obj.tag)
		for k in 0..<3 { binary_write_f32(&w, obj.hi[k]) }
		binary_write_u32(&w, obj.index)
		if obj.tag < 16 { tag_counts[obj.tag] += 1 }
	}

	// Section 4: the one view-cell node bound, with no occluder hull.
	for k in 0..<3 { binary_write_f32(&w, lo[k]) }
	for k in 0..<3 { binary_write_f32(&w, hi[k]) }
	binary_write_u32(&w, 0); binary_write_u32(&w, 0)
	if !w.ok || len(w.data) != section_4+32 { return nil, "could not encode Dirt 3 VIS sections", false }

	// Header.
	binary_patch_u32(&w, 0x00, 4)
	binary_patch_u32(&w, 0x04, 1); binary_patch_u32(&w, 0x08, 1)
	binary_patch_u32(&w, 0x0c, 1); binary_patch_u32(&w, 0x10, u32(mask_bytes))
	binary_patch_u32(&w, 0x14, u32(section_1)); binary_patch_u32(&w, 0x18, u32(section_2))
	binary_patch_u32(&w, 0x1c, u32(section_3)); binary_patch_u32(&w, 0x2c, u32(section_4))
	for k in 0..<3 { binary_patch_f32(&w, 0x20+k*4, lo[k]); binary_patch_f32(&w, 0x30+k*4, hi[k]) }
	for tag in 0..<16 { binary_patch_u32(&w, 0x40+tag*4, max(tag_counts[tag], header_floor[tag])) }
	if !w.ok { return nil, "could not finalize Dirt 3 VIS header", false }

	out = w.data[:]
	w.data = nil
	return out, fmt.tprintf("1 view cell, %d objects across %d tags", len(objects), d3_vis_tag_span(tag_counts)), true
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
		if !tile_ok { return nil, tile_msg, false }
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
		if read_err != nil { return nil, fmt.tprintf("could not read %s: %v", path, read_err), false }
		boxes, boxes_msg, boxes_ok := d3_ground_cover_boxes(data, context.temp_allocator)
		if !boxes_ok { return nil, fmt.tprintf("%s: %s", path, boxes_msg), false }
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
		if !add_ok { return nil, add_msg, false }
		counted[i] = added
	}

	if len(out) == 0 { return nil, "found no drawables to make visible", false }
	return out[:], fmt.tprintf(
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
	objects, objects_msg, objects_ok := d3_vis_census_objects(
		route_dir, venue_dir, ground_cover, context.temp_allocator,
	)
	if !objects_ok { return nil, objects_msg, false }

	floor: [16]u32
	donor_msg := "no donor to floor the header counts against"
	if donor := d3_stock_path(route_dir, "track.vis"); donor != "" {
		data, read_err := os.read_entire_file(donor, context.temp_allocator)
		if read_err != nil { return nil, fmt.tprintf("could not read %s: %v", donor, read_err), false }
		counts, counts_ok := d3_vis_read_header_tag_counts(data)
		if !counts_ok { return nil, fmt.tprintf("%s: too short to hold a Dirt 3 VIS header", donor), false }
		// We write both PSSGs and both placement files, so tags 0, 2 and 3 are
		// counted from what we wrote. The donor's count is still the floor on
		// tag 2: dynamic ENS drawables consume registration slots that receive
		// no box, and the game sizes its allocations off the header count.
		//
		// Tag 1 joins them once we write `grass.grs`: flooring it to the
		// donor's cell count would declare cells our own file does not have.
		for tag in 0..<16 {
			if tag == 0 || tag == 3 { continue }
			if tag == 1 && ground_cover { continue }
			floor[tag] = counts[tag]
		}
		donor_msg = fmt.tprintf("tags 2, 4..15 floored against %s", filepath.base(donor))
	}
	// Our own dynamic entities on top of that. They receive no tag-2 box, so
	// the census above cannot see them, but their `instanceID` still has to
	// fall inside the count the header declares.
	ens_msg := "no objects.ens to floor tag 2 against"
	if ens_path, _ := filepath.join({route_dir, "objects.ens"}, context.temp_allocator);
	   os.exists(ens_path) {
		data, read_err := os.read_entire_file(ens_path, context.temp_allocator)
		if read_err != nil { return nil, fmt.tprintf("could not read %s: %v", ens_path, read_err), false }
		nodes, parsed := d3_ens_parse(data, context.temp_allocator)
		if !parsed { return nil, "objects.ens did not parse, so tag 2 cannot be sized", false }
		span := d3_ens_instance_id_span(nodes)
		floor[2] = max(floor[2], span)
		ens_msg = fmt.tprintf("tag 2 floored to %d for %d ens instance ids", floor[2], span)
	}

	built, build_msg, built_ok := d3_vis_build_single_cell(objects, floor, allocator)
	if !built_ok { return nil, build_msg, false }
	return built, fmt.tprintf("%s; %s; %s; %s", objects_msg, donor_msg, ens_msg, build_msg), true
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
