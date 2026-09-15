package d3

// Builds an all-visible track.vis for an existing stock Dirt 3 route, from
// the route's own real files rather than from an existing track.vis. Every
// object is always visible (see d3_vis_build_single_cell); the point is to
// test whether our own census of a stock stage's drawables is complete and
// correctly boxed, with a real stock stage as the immediate diff.
//
// Ground cover and ground clutter are not included. Both place their
// instances through a GPU instance stream this codebase does not decode yet
// (see docs/dirt3-vis-format.md, tags 1 and 7); the mesh-shaped boxes on
// their PSSG render nodes are local to the prototype, not world positions.
// Crowd, interactive water and lights (tags 4, 6, 8) are not included either;
// their placement files are not decoded here.
//
// Writing tag-2 (ornament) boxes with a made-up id crashes DiRT 3, always the
// same address (dirt3_game.exe+0x940c17) — unless the id is real. A tag-2 id
// is an opaque per-route registration handle assigned once at
// level-authoring time, not a file position, and merely avoiding collisions
// isn't enough (a random unclaimed id neither crashes nor draws anything).
// Two sources give a real id: `objects.ens`'s `staticVis="1"` entities carry
// their own id as `instanceID`, exact game-wide
// (`d3_append_ens_static_vis_objects`); `ornaments.bin` itself carries no id
// anywhere, but its plain-text sibling `ornaments.xml` does, as an explicit
// `instance_id` attribute, exact against stock `track.vis`
// (`d3_append_ornaments_with_donor_ids`). `D3_Ornaments_Id_Mode.Donor` with
// both sources is the full, crash-free recipe. See
// docs/dirt3-vis-format.md "The ornaments crash" and memory
// dirt3-ornaments-vis-crash.
//
// `ornaments_mode` on `d3_stock_route_all_visible_objects` picks how
// `ornaments.bin` gets its ids — see D3_Ornaments_Id_Mode.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// A stock PSSG can nest several "NODE" elements before the one that actually
// groups the tiles — Michigan's tracksplit.pssg has an empty decoy NODE
// directly under ROOTNODE, ahead of the real one — so the surface node must
// be found by its own `id` attribute, not by first match on element type.
@(private = "file")
d3_pssg_find_node_by_id :: proc(file: ^Pssg_File, node: ^Pssg_Node, type_name, id: string) -> ^Pssg_Node {
	if node == nil { return nil }
	if node.name == type_name && pssg_attr_string(file, node, "id") == id { return node }
	for child in node.children {
		if found := d3_pssg_find_node_by_id(file, child, type_name, id); found != nil { return found }
	}
	return nil
}

// Every tile box on a `tracksplit.pssg`/`routesplit.pssg` surface node, read
// straight off the file's own BOUNDINGBOX children (big-endian, like every
// PSSG float payload) rather than recomputed from our own tiling. In file
// order; the caller applies whatever registration order the engine expects.
d3_pssg_surface_tile_boxes :: proc(file: ^Pssg_File, allocator := context.allocator) -> (boxes: []D3_Tile_Box, ok: bool) {
	surface := d3_pssg_find_node_by_id(file, file.root, "NODE", "surface")
	if surface == nil || len(surface.children) <= 2 { return nil, false }

	out := make([dynamic]D3_Tile_Box, allocator)
	for tile in surface.children[2:] {
		if len(tile.children) <= 2 { continue }
		lo, hi: [3]f32
		seen := false
		for render in tile.children[2:] {
			box := pssg_walk_first(render, "BOUNDINGBOX")
			if box == nil || len(box.data) != 24 { continue }
			for k in 0 ..< 3 {
				low_bits, _ := pssg_be_u32(box.data, k*4)
				high_bits, _ := pssg_be_u32(box.data, 12+k*4)
				low, high := transmute(f32)low_bits, transmute(f32)high_bits
				if !seen { lo[k] = low; hi[k] = high } else { lo[k] = min(lo[k], low); hi[k] = max(hi[k], high) }
			}
			seen = true
		}
		if seen { append(&out, D3_Tile_Box{lo, hi}) }
	}
	return out[:], true
}

@(private = "file")
d3_read_or_fail :: proc(path: string, allocator := context.allocator) -> (data: []u8, msg: string, ok: bool) {
	read, err := os.read_entire_file(path, allocator)
	if err != nil { return nil, fmt.tprintf("could not read %s: %v", path, err), false }
	return read, "", true
}

@(private = "file")
d3_read_pssg_tile_boxes :: proc(path: string, allocator := context.allocator) -> (boxes: []D3_Tile_Box, msg: string, ok: bool) {
	data, read_msg, read_ok := d3_read_or_fail(path, context.temp_allocator)
	if !read_ok { return nil, read_msg, false }
	file, pssg_msg, pssg_ok := pssg_read(data, context.temp_allocator)
	if !pssg_ok { return nil, fmt.tprintf("%s: %s", path, pssg_msg), false }
	defer pssg_delete(&file, context.temp_allocator)
	tiles, tiles_ok := d3_pssg_surface_tile_boxes(&file, allocator)
	if !tiles_ok { return nil, fmt.tprintf("%s: no tiled surface node", path), false }
	return tiles, "", true
}

// Every instance of one placement file (`trees.bin` or `ornaments.bin`),
// appended as VIS objects of `tag`, indexed by file order — the only order
// available; the real engine's registration order for these two tags is
// unconfirmed. See docs/dirt3-vis-format.md.
@(private = "file")
d3_append_placement_objects :: proc(
	out: ^[dynamic]D3_Vis_Object,
	path: string,
	tag: u32,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, fmt.tprintf("%s: not a recognised placement file", path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, fmt.tprintf("%s: %s", path, read_msg), false }

	for inst, i in instances {
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, fmt.tprintf("%s: instance %d names an unknown reference %d", path, i, inst.reference_id), false
		}
		append(out, D3_Vis_Object{tag = tag, index = u32(i), lo = lo, hi = hi})
		added += 1
	}
	return added, "", true
}

// Every `<instance ...>` tag's `instance_id` attribute in `ornaments.xml`, in
// file order. This plain-text sibling of `ornaments.bin` (which ships
// alongside it on every route) carries the real per-route tag-2 id
// explicitly — confirmed exact against stock `track.vis` for every instance
// present there. `ornaments.bin` itself carries no such field (checked and
// ruled out: its own `instance_tag` at instance offset +76 is a different,
// unrelated number). File order matches `ornaments.bin`'s own instance table
// order exactly (same positions, cross-checked), so index i here names the
// same placement as `ornaments.bin` instance i. See
// docs/dirt3-vis-format.md, "The ornaments crash".
d3_ornaments_xml_instance_ids :: proc(data: []u8, allocator := context.allocator) -> (ids: []u32, ok: bool) {
	text := string(data)
	out := make([dynamic]u32, allocator)
	pos := 0
	for {
		start := strings.index(text[pos:], "<instance ")
		if start < 0 { break }
		start += pos
		end := strings.index(text[start:], "/>")
		if end < 0 { return nil, false }
		end += start
		tag := text[start:end]
		attr_at := strings.index(tag, `instance_id="`)
		if attr_at < 0 { return nil, false }
		attr_at += len(`instance_id="`)
		close_quote := strings.index_byte(tag[attr_at:], '"')
		if close_quote < 0 { return nil, false }
		id, id_ok := strconv.parse_int(tag[attr_at:attr_at+close_quote])
		if !id_ok { return nil, false }
		append(&out, u32(id))
		pos = end + 2
	}
	return out[:], true
}

// `ornaments.bin`'s own instances, tag 2, with their real id read straight
// from `ornaments.xml` (see d3_ornaments_xml_instance_ids). Only instances
// whose id is actually present in `donor_vis_path`'s own tag-2 section are
// included — a route's `ornaments.xml` holds every authored placement, but a
// given route's `track.vis` only registers the subset relevant to it (162 vs
// 291's worth spread across sources on Michigan route_3; 157 of 162 present,
// 5 legitimately absent). No box-distance guessing: the id is exact, so
// inclusion is exact set membership, not a nearest match — see
// [[dirt3-ornaments-vis-crash]] for why a wrong id here is dangerous and
// leaving an object out of tag 2 entirely is the confirmed-safe fallback.
@(private = "file")
d3_append_ornaments_with_donor_ids :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ornaments_path, ornaments_xml_path, donor_vis_path: string,
) -> (
	added, skipped: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ornaments_path, context.temp_allocator)
	if !data_ok { return 0, 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, 0, fmt.tprintf("%s: not a recognised placement file", ornaments_path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, 0, fmt.tprintf("%s: %s", ornaments_path, read_msg), false }

	xml_data, xml_read_msg, xml_read_ok := d3_read_or_fail(ornaments_xml_path, context.temp_allocator)
	if !xml_read_ok { return 0, 0, xml_read_msg, false }
	xml_ids, xml_ok := d3_ornaments_xml_instance_ids(xml_data, context.temp_allocator)
	if !xml_ok { return 0, 0, fmt.tprintf("%s: could not read every instance_id", ornaments_xml_path), false }
	if len(xml_ids) != len(instances) {
		return 0, 0, fmt.tprintf("%s has %d instances but %s has %d", ornaments_path, len(instances), ornaments_xml_path, len(xml_ids)), false
	}

	donor_data, donor_read_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
	if !donor_read_ok { return 0, 0, donor_read_msg, false }
	donor_boxes, donor_ok := d3_vis_read_tag_boxes(donor_data, 2, context.temp_allocator)
	if !donor_ok { return 0, 0, fmt.tprintf("%s: too short to hold a Dirt 3 VIS section 3", donor_vis_path), false }

	for inst, i in instances {
		id := xml_ids[i]
		if _, present := donor_boxes[id]; !present {
			skipped += 1
			continue
		}
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, skipped, fmt.tprintf("%s: instance %d names an unknown reference %d", ornaments_path, i, inst.reference_id), false
		}
		append(out, D3_Vis_Object{tag = 2, index = id, lo = lo, hi = hi})
		added += 1
	}
	return added, skipped, "", true
}

// Picked well clear of both the made-up sequential range that's confirmed to
// crash (0..161 on Michigan route_3) and every real id observed on any route
// sampled (max ~2011, see [[dirt3-ornaments-vis-crash]]) — the point is to
// test whether an arbitrary, merely-unclaimed id is safe, not to dodge a
// specific collision.
D3_ORNAMENT_RANDOM_ID_BASE :: u32(10_000)
D3_ORNAMENT_RANDOM_ID_SPAN :: u32(60_000)

// `ornaments.bin`'s own instances, tag 2, with ids picked at random rather
// than recovered from anywhere real — an experiment, not a fix: donor-borrowed
// and objects.ens ids are the only ones confirmed safe so far (see
// [[dirt3-ornaments-vis-crash]]). `avoid` is every id already claimed
// elsewhere in this build (so this never collides with objects.ens's real
// entries); each instance still gets its own real box.
@(private = "file")
d3_append_ornaments_with_random_ids :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ornaments_path: string,
	avoid: map[u32]bool,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ornaments_path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, fmt.tprintf("%s: not a recognised placement file", ornaments_path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, fmt.tprintf("%s: %s", ornaments_path, read_msg), false }

	used := make(map[u32]bool, context.temp_allocator)
	for id in avoid { used[id] = true }

	for inst, i in instances {
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, fmt.tprintf("%s: instance %d names an unknown reference %d", ornaments_path, i, inst.reference_id), false
		}
		id: u32
		for {
			id = D3_ORNAMENT_RANDOM_ID_BASE + u32(rand.int31_max(i32(D3_ORNAMENT_RANDOM_ID_SPAN)))
			if !used[id] { break }
		}
		used[id] = true
		append(out, D3_Vis_Object{tag = 2, index = id, lo = lo, hi = hi})
		added += 1
	}
	return added, "", true
}

// The route's `objects.ens` static-vis entities: real per-tag ids straight
// from the file's own `instanceID` attribute (see d3_ens_static_vis_ids),
// paired with a real box borrowed from `donor_vis_path`'s own tag-2 section.
// The id is confirmed exact game-wide; nothing shipped gives an independent
// box for it, so this is skipped entirely with no donor.
@(private = "file")
d3_append_ens_static_vis_objects :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ens_path, donor_vis_path: string,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ens_path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	nodes, parse_ok := d3_ens_parse(data, context.temp_allocator)
	if !parse_ok { return 0, fmt.tprintf("%s: not a recognised objects.ens file", ens_path), false }
	ids, ids_ok := d3_ens_static_vis_ids(nodes, context.temp_allocator)
	if !ids_ok { return 0, fmt.tprintf("%s: a staticVis entity is missing its instanceID", ens_path), false }
	if len(ids) == 0 { return 0, "", true }

	donor_data, donor_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
	if !donor_read_ok { return 0, donor_msg, false }
	donor_boxes, donor_ok := d3_vis_read_tag_boxes(donor_data, 2, context.temp_allocator)
	if !donor_ok { return 0, fmt.tprintf("%s: too short to hold a Dirt 3 VIS section 3", donor_vis_path), false }

	for id in ids {
		box, found := donor_boxes[id]
		if !found { return added, fmt.tprintf("%s: instanceID %d has no tag-2 box in donor %s", ens_path, id, donor_vis_path), false }
		append(out, D3_Vis_Object{tag = 2, index = id, lo = box.lo, hi = box.hi})
		added += 1
	}
	return added, "", true
}

// How `ornaments.bin`'s own instances get their tag-2 id.
// `Skip`: leave them out of tag 2 entirely (confirmed safe).
// `Donor`: nearest-box match against `donor_vis_path` (confirmed safe; the
// donor must already carry the real answer, so this only works for existing,
// unmodified content).
// `Random`: an unclaimed id picked with no real source at all — an
// experiment to see whether *any* unclaimed id is safe, or whether it has to
// trace back to something real. See [[dirt3-ornaments-vis-crash]].
D3_Ornaments_Id_Mode :: enum { Skip, Donor, Random }

// `ornaments.bin`'s own instances for one `D3_Ornaments_Id_Mode`. `out` must
// already hold every `objects.ens` object, so `Random` can avoid colliding
// with those real ids.
@(private = "file")
d3_ornaments_step :: proc(
	out: ^[dynamic]D3_Vis_Object,
	mode: D3_Ornaments_Id_Mode,
	route_dir, donor_vis_path: string,
) -> (
	added, skipped: int,
	desc: string,
	ok: bool,
) {
	switch mode {
	case .Skip:
		return 0, 0, "skipped", true
	case .Donor:
		if donor_vis_path == "" {
			return 0, 0, "ornaments.bin needs a donor to recover its real tag-2 ids from (see d3_append_ornaments_with_donor_ids)", false
		}
		ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)
		ornaments_xml_path, _ := filepath.join({route_dir, "ornaments.xml"}, context.temp_allocator)
		added, skipped, add_msg, add_ok := d3_append_ornaments_with_donor_ids(out, ornaments_path, ornaments_xml_path, donor_vis_path)
		if !add_ok { return 0, 0, add_msg, false }
		return added, skipped, fmt.tprintf("%d real ids, %d not in donor's tag-2 set", added, skipped), true
	case .Random:
		avoid := make(map[u32]bool, context.temp_allocator)
		for obj in out^ { if obj.tag == 2 { avoid[obj.index] = true } }
		ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)
		added, add_msg, add_ok := d3_append_ornaments_with_random_ids(out, ornaments_path, avoid)
		if !add_ok { return 0, 0, add_msg, false }
		return added, 0, fmt.tprintf("%d, random unclaimed ids", added), true
	}
	return 0, 0, "", true
}

// Every object this codebase can currently derive a safe header count for:
// tag-0 tile boxes (venue tracksplit then route routesplit, engine reverse
// order) and every tree. `venue_dir` is the location
// directory tracksplit.pssg lives in; `route_dir` is the route inside it.
// `ornaments_mode` controls `ornaments.bin`'s own instances (`Donor` requires
// `donor_vis_path`). `donor_vis_path`, when non-empty, also pulls in every
// `objects.ens` static-vis entity with its real id (see
// d3_append_ens_static_vis_objects) — gathered first so `Random` can avoid
// colliding with those real ids.
d3_stock_route_all_visible_objects :: proc(
	route_dir, venue_dir, donor_vis_path: string,
	ornaments_mode: D3_Ornaments_Id_Mode,
	allocator := context.allocator,
) -> (
	objects: []D3_Vis_Object,
	msg: string,
	ok: bool,
) {
	out := make([dynamic]D3_Vis_Object, allocator)
	defer if !ok { delete(out) }

	// The venue's tracksplit tiles hold the low indices, the route's own
	// routesplit tiles the high ones (Moosylvania: 0..28 then 38..69, the
	// "lead" a route's own retile must offset by) — two ascending blocks, not
	// one list reversed as a unit. Reversing the whole concatenation instead
	// of each source on its own scrambles which real drawable an index names,
	// which is exactly what emptied the terrain on the first drive of this.
	tracksplit_path, _ := filepath.join({venue_dir, "tracksplit.pssg"}, context.temp_allocator)
	routesplit_path, _ := filepath.join({route_dir, "routesplit.pssg"}, context.temp_allocator)
	tile_total := 0
	next_index := u32(0)
	for path in ([]string{tracksplit_path, routesplit_path}) {
		tiles, tile_msg, tile_ok := d3_read_pssg_tile_boxes(path, context.temp_allocator)
		if !tile_ok { return nil, tile_msg, false }
		tile_total += len(tiles)
		// Within one source, the engine enumerates tile nodes in reverse
		// traversal order.
		for i in 0 ..< len(tiles) {
			box := tiles[len(tiles)-1-i]
			append(&out, D3_Vis_Object{tag = 0, index = next_index, lo = box.lo, hi = box.hi})
			next_index += 1
		}
	}

	trees_path, _ := filepath.join({route_dir, "trees.bin"}, context.temp_allocator)
	trees_added, trees_msg, trees_ok := d3_append_placement_objects(&out, trees_path, 3)
	if !trees_ok { return nil, trees_msg, false }

	// Gathered before ornaments.bin so D3_Ornaments_Id_Mode.Random can avoid
	// colliding with these real ids.
	ens_added := 0
	if donor_vis_path != "" {
		ens_path, _ := filepath.join({route_dir, "objects.ens"}, context.temp_allocator)
		added, ens_msg, ens_ok := d3_append_ens_static_vis_objects(&out, ens_path, donor_vis_path)
		if !ens_ok { return nil, ens_msg, false }
		ens_added = added
	}

	_, _, ornaments_mode_msg, ornaments_ok := d3_ornaments_step(&out, ornaments_mode, route_dir, donor_vis_path)
	if !ornaments_ok { return nil, ornaments_mode_msg, false }

	if len(out) == 0 { return nil, "found no objects to make visible", false }
	return out[:], fmt.tprintf(
		"tag 0 (surface): %d tiles; tag 2 (ornaments.bin): %s; tag 2 (objects.ens static-vis): %d; tag 3 (trees): %d",
		tile_total, ornaments_mode_msg, ens_added, trees_added,
	), true
}

// `donor_vis_path`, when non-empty, floors every tag's header count at the
// donor file's own count for that tag — see d3_vis_build_single_cell. Pass
// the route's own stock backup to keep a tag whose derived count is known to
// undersell the real one (ornaments) from sizing the game's allocation too
// small.
d3_stock_route_all_visible_vis :: proc(
	route_dir, venue_dir, donor_vis_path: string,
	ornaments_mode: D3_Ornaments_Id_Mode,
	allocator := context.allocator,
) -> (
	out: []u8,
	msg: string,
	ok: bool,
) {
	objects, objects_msg, objects_ok := d3_stock_route_all_visible_objects(route_dir, venue_dir, donor_vis_path, ornaments_mode, context.temp_allocator)
	if !objects_ok { return nil, objects_msg, false }

	header_floor: [16]u32
	donor_msg := "no donor"
	if donor_vis_path != "" {
		donor_data, donor_read_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
		if !donor_read_ok { return nil, donor_read_msg, false }
		floor_ok: bool
		header_floor, floor_ok = d3_vis_read_header_tag_counts(donor_data)
		if !floor_ok { return nil, fmt.tprintf("%s: too short to hold a Dirt 3 VIS header", donor_vis_path), false }
		donor_msg = fmt.tprintf("header floors from %s", donor_vis_path)
	}

	built, build_msg, built_ok := d3_vis_build_single_cell(objects, header_floor, allocator)
	if !built_ok { return nil, build_msg, false }
	return built, fmt.tprintf("%s -- %s -- %s", objects_msg, donor_msg, build_msg), true
}

// `--dirt3-vis-allvisible <route_dir> <venue_dir> [--donor track.vis] [--ornaments skip|donor|random] [-o out.vis]`:
// build an all-visible track.vis for an existing stock route from its own
// files. Never touches the route directly; installing the result is a manual
// step.
dirt3_vis_allvisible_headless :: proc(route_dir, venue_dir, donor_vis_path, out_path: string, ornaments_mode: D3_Ornaments_Id_Mode) -> (msg: string, ok: bool) {
	data, build_msg, built := d3_stock_route_all_visible_vis(route_dir, venue_dir, donor_vis_path, ornaments_mode, context.allocator)
	if !built { return build_msg, false }
	defer delete(data)
	if write_err := os.write_entire_file(out_path, data); write_err != nil {
		return fmt.tprintf("could not write %s: %v", out_path, write_err), false
	}
	return fmt.tprintf("%s -> %s (%d bytes)\n%s", route_dir, out_path, len(data), build_msg), true
}
