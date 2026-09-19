package d3

// Card billboard clouds in a venue's `trees.pssg`. A distant forest is one baked
// mesh of camera-facing cards placed by a single row in `trees.bin`; the format is
// in docs/dirt3-tree-billboards.md and this is the writer.
//
// Nothing is authored from nothing. A cloud is a clone of a template cloud in the
// same file, so every attribute id, the node shape and the shader reference are
// known-good; every card is a clone of one of that template's cards, so no UV is
// invented and the sheet's own aspect ratios survive.
//
// That makes the template cloud the authoring interface: a pack ships a
// `trees.pssg` with a root named `dirtbench_sheet_near` or `dirtbench_sheet_far`
// on its own sheet and needs no code here. Without one the largest stock cloud of
// the right kind is cloned instead.
//
// Two traps, each of which hangs the load with no fault and no log line:
//
//   * every id inside a clone has to be renamed, `lod`/`default`/`rigidbody`
//     included — they carry `id` attributes as well as nicknames;
//   * `track.vis`'s sixteen tag budgets at 0x40 must never be rebuilt from the
//     boxes. Nothing here writes vis at all; the census reads `trees.bin` after
//     the fact (track_vis.odin).

import "core:fmt"
import "core:mem"
import "core:strings"

// Classifies stock art only. A template found by name is taken on its name alone,
// because a pack may spell its own shader group differently.
BILLBOARD_SHADER_GROUP :: "treesheet_foliage.fx"

// The names a pack declares its own template clouds under.
BILLBOARD_TEMPLATE_NEAR :: "dirtbench_sheet_near"
BILLBOARD_TEMPLATE_FAR :: "dirtbench_sheet_far"

// A card taking this much of the sheet's `u` or more is a whole band of forest,
// less is one tree out of a column atlas. This sorts the tiers, not the name.
BILLBOARD_BAND_U :: f32(0.6)

// The stride and streams of a card vertex, fixed by the format: the anchor point
// repeated in all four corners, a flat tint, the atlas coordinate, and the corner
// offset in metres. The shader builds the quad from the last two.
BILLBOARD_STRIDE :: 24

// A cloud is one drawable with `ushort` indices, so four vertices per card caps
// it here. The caller chunks well below this; the writer refuses rather than
// wrapping.
BILLBOARD_CARDS_MAX :: 16384

// One card of a template: the atlas rectangle it is cut from, its corner offsets
// in metres, and its tint.
Billboard_Template_Card :: struct {
	st:     [4][2][2]f32, // per corner: the atlas coordinate, then the offset in metres
	colour: u32,
	w, h:   f32,
	band:   bool,
}

// A cloud to clone from, and the cards it holds.
Billboard_Template :: struct {
	name:   string,
	root:   ^Pssg_Node,
	source: ^Pssg_Node, // the RENDERDATASOURCE the draw reads
	block:  ^Pssg_Node, // its stride-24 DATABLOCK
	shader: string,     // the SHADERINSTANCE reference, verbatim
	cards:  []Billboard_Template_Card,
	band:   bool, // what most of its cards are
}

// One card to write, in the cloud's own local space.
Billboard_Place :: struct {
	pos:   [3]f32,
	card:  int, // which of the template's cards this clones
	scale: f32,
}

// One written cloud, as `trees.bin` needs it: a reference row quotes the bounds
// and an instance stands the whole thing at its centre.
Billboard_Cloud :: struct {
	name:   string,
	centre: [3]f32,   // where the instance stands
	lo, hi: [3]f32,   // the mesh bounds, local to `centre`
	cards:  int,
}

// --- reading a template ------------------------------------------------------

// The float3 `Vertex` stream of a DATABLOCK: where it starts and how far apart
// its elements are.
@(private = "file")
billboard_vertex_stream :: proc(file: ^Pssg_File, block: ^Pssg_Node) -> (offset, stride: u32, ok: bool) {
	for decl in block.children {
		if decl.name != "DATABLOCKSTREAM" ||
		   pssg_attr_string(file, decl, "renderType") != "Vertex" ||
		   pssg_attr_string(file, decl, "dataType") != "float3" {
			continue
		}
		off, has_off := pssg_attr_u32(file, decl, "offset")
		str, has_stride := pssg_attr_u32(file, decl, "stride")
		if has_off && has_stride {
			return off, str, true
		}
	}
	return 0, 0, false
}

// The offsets of the two `ST` streams, in declaration order: the atlas
// coordinate, then the corner offset in metres.
@(private = "file")
billboard_st_streams :: proc(file: ^Pssg_File, block: ^Pssg_Node) -> (a, b: u32, ok: bool) {
	found := 0
	for decl in block.children {
		if decl.name != "DATABLOCKSTREAM" || pssg_attr_string(file, decl, "renderType") != "ST" {
			continue
		}
		off, has_off := pssg_attr_u32(file, decl, "offset")
		if !has_off {
			continue
		}
		switch found {
		case 0:
			a = off
		case 1:
			b = off
		case:
			return a, b, true
		}
		found += 1
	}
	return a, b, found >= 2
}

@(private = "file")
billboard_half :: proc(data: []u8, at: int) -> f32 {
	return f32(transmute(f16)binary_load_u16(data, at, .Big))
}

// Every card of one draw. Four vertices to a card, all at one point, so the
// corner offsets are the only thing that gives a card its size.
@(private = "file")
billboard_read_cards :: proc(
	file: ^Pssg_File, block: ^Pssg_Node, allocator := context.temp_allocator,
) -> []Billboard_Template_Card {
	_, stride, has_vertex := billboard_vertex_stream(file, block)
	st0, st1, has_st := billboard_st_streams(file, block)
	count, has_count := pssg_attr_u32(file, block, "elementCount")
	payload := pssg_walk_first(block, "DATABLOCKDATA")
	if !has_vertex || !has_st || !has_count || payload == nil || stride != BILLBOARD_STRIDE {
		return nil
	}
	out := make([dynamic]Billboard_Template_Card, allocator)
	for base := 0; base + 3 < int(count); base += 4 {
		card: Billboard_Template_Card
		u_lo, u_hi := max(f32), min(f32)
		bad := false
		for corner in 0 ..< 4 {
			at := (base + corner) * BILLBOARD_STRIDE
			if !binary_range(len(payload.data), at, BILLBOARD_STRIDE) {
				bad = true
				break
			}
			card.st[corner][0] = {
				billboard_half(payload.data, at + int(st0)),
				billboard_half(payload.data, at + int(st0) + 2),
			}
			card.st[corner][1] = {
				billboard_half(payload.data, at + int(st1)),
				billboard_half(payload.data, at + int(st1) + 2),
			}
			u_lo = min(u_lo, card.st[corner][0][0])
			u_hi = max(u_hi, card.st[corner][0][0])
			card.w = max(card.w, 2 * abs(card.st[corner][1][0]))
			card.h = max(card.h, 2 * abs(card.st[corner][1][1]))
		}
		if bad || card.w <= 0 || card.h <= 0 {
			continue
		}
		card.colour = binary_load_u32(payload.data, base * BILLBOARD_STRIDE + 12, .Big)
		card.band = u_hi - u_lo >= BILLBOARD_BAND_U
		append(&out, card)
	}
	return out[:]
}

// Every cloud in the library that could be cloned, decoded. A cloud is a prop
// root with exactly one draw call, whose data block is the card layout; the
// shader group is checked only so a stock tree species is not mistaken for one.
billboard_templates :: proc(
	lib: ^Prop_Library, allocator := context.temp_allocator,
) -> []Billboard_Template {
	sheets := make(map[string]bool, 0, context.temp_allocator)
	defer delete(sheets)
	for id, node in lib.by_id {
		if node.name != "SHADERINSTANCE" {
			continue
		}
		group := strings.trim_prefix(pssg_attr_string(&lib.file, node, "shaderGroup"), "#")
		if strings.contains(group, BILLBOARD_SHADER_GROUP) {
			sheets[id] = true
		}
	}

	out := make([dynamic]Billboard_Template, allocator)
	for entry in lib.props {
		draws := make([dynamic]^Pssg_Node, context.temp_allocator)
		billboard_collect_draws(entry.root, &draws)
		if len(draws) != 1 {
			continue
		}
		rsi := draws[0]
		shader := pssg_attr_string(&lib.file, rsi, "shader")
		named := entry.name == BILLBOARD_TEMPLATE_NEAR || entry.name == BILLBOARD_TEMPLATE_FAR
		if !named && !sheets[strings.trim_prefix(shader, "#")] {
			continue
		}
		source, block, resolved := billboard_draw_data(lib, rsi)
		if !resolved {
			continue
		}
		cards := billboard_read_cards(&lib.file, block, allocator)
		if len(cards) == 0 {
			continue
		}
		bands := 0
		for card in cards {
			if card.band {
				bands += 1
			}
		}
		append(&out, Billboard_Template {
			name   = entry.name,
			root   = entry.root,
			source = source,
			block  = block,
			shader = shader,
			cards  = cards,
			band   = bands * 2 >= len(cards),
		})
	}
	return out[:]
}

// Templates own their card lists, so a caller that did not take them out of the
// temp allocator frees them here.
billboard_templates_delete :: proc(templates: []Billboard_Template, allocator := context.temp_allocator) {
	for template in templates {
		delete(template.cards, allocator)
	}
	delete(templates, allocator)
}

@(private = "file")
billboard_collect_draws :: proc(node: ^Pssg_Node, out: ^[dynamic]^Pssg_Node) {
	if node == nil {
		return
	}
	if node.name == "RENDERSTREAMINSTANCE" {
		append(out, node)
	}
	for child in node.children {
		billboard_collect_draws(child, out)
	}
}

// The data source a draw reads and the block behind its first stream.
@(private = "file")
billboard_draw_data :: proc(
	lib: ^Prop_Library, rsi: ^Pssg_Node,
) -> (source, block: ^Pssg_Node, ok: bool) {
	instance := pssg_walk_first(rsi, "RENDERINSTANCESOURCE")
	if instance == nil {
		return nil, nil, false
	}
	found: bool
	source, found = lib.by_id[strings.trim_prefix(pssg_attr_string(&lib.file, instance, "source"), "#")]
	if !found {
		return nil, nil, false
	}
	stream := pssg_walk_first(source, "RENDERSTREAM")
	if stream == nil {
		return nil, nil, false
	}
	block, found = lib.by_id[strings.trim_prefix(pssg_attr_string(&lib.file, stream, "dataBlock"), "#")]
	return source, block, found
}

// The template for one tier. A pack's declared cloud wins on its name alone,
// failing that the largest pool of the right kind — a mixed cloud is a misread of
// the layout rather than a tier. `band` true is the wall's whole-sheet forest
// bands, false the near tier's single trees.
billboard_template_pick :: proc(
	templates: []Billboard_Template, band: bool,
) -> (pick: ^Billboard_Template, ok: bool) {
	want := band ? BILLBOARD_TEMPLATE_FAR : BILLBOARD_TEMPLATE_NEAR
	for &candidate in templates {
		if candidate.name == want {
			return &candidate, true
		}
	}
	for &candidate in templates {
		if candidate.band != band {
			continue
		}
		if pick == nil || len(candidate.cards) > len(pick.cards) {
			pick = &candidate
		}
	}
	return pick, pick != nil
}

// The card sizes a template offers, for the generator to pick among.
billboard_template_sizes :: proc(
	template: ^Billboard_Template, allocator := context.temp_allocator,
) -> (out: [][2]f32) {
	out = make([][2]f32, len(template.cards), allocator)
	for card, i in template.cards {
		out[i] = {card.w, card.h}
	}
	return
}

// --- writing a cloud ---------------------------------------------------------

// The stride-24 vertex block and the `ushort` index block of one cloud.
@(private = "file")
billboard_payloads :: proc(
	file: ^Pssg_File,
	block: ^Pssg_Node,
	template: ^Billboard_Template,
	places: []Billboard_Place,
	allocator := context.allocator,
) -> (vertices, indices: []u8, ok: bool) {
	st0, st1, has_st := billboard_st_streams(file, block)
	if !has_st {
		return nil, nil, false
	}
	vertices = make([]u8, len(places) * 4 * BILLBOARD_STRIDE, allocator)
	indices = make([]u8, len(places) * 6 * 2, allocator)
	for place, i in places {
		if place.card < 0 || place.card >= len(template.cards) {
			delete(vertices, allocator)
			delete(indices, allocator)
			return nil, nil, false
		}
		card := template.cards[place.card]
		for corner in 0 ..< 4 {
			at := (i * 4 + corner) * BILLBOARD_STRIDE
			for axis in 0 ..< 3 {
				binary_store_f32(vertices, at + axis * 4, place.pos[axis], .Big)
			}
			binary_store_u32(vertices, at + 12, card.colour, .Big)
			binary_store_u16(vertices, at + int(st0), d3_half(card.st[corner][0][0]), .Big)
			binary_store_u16(vertices, at + int(st0) + 2, d3_half(card.st[corner][0][1]), .Big)
			binary_store_u16(vertices, at + int(st1), d3_half(card.st[corner][1][0] * place.scale), .Big)
			binary_store_u16(vertices, at + int(st1) + 2, d3_half(card.st[corner][1][1] * place.scale), .Big)
		}
		base := u16(i * 4)
		for corner, k in ([6]u16{0, 1, 2, 2, 3, 0}) {
			binary_store_u16(indices, (i * 6 + k) * 2, base + corner, .Big)
		}
	}
	return vertices, indices, true
}

// The cloud's local bounds, wide enough for a card turned any way around: the
// card is rotated about world up by the shader, so its width applies on both
// horizontal axes.
@(private = "file")
billboard_bounds :: proc(
	template: ^Billboard_Template, places: []Billboard_Place,
) -> (lo, hi: [3]f32) {
	lo = {max(f32), max(f32), max(f32)}
	hi = {min(f32), min(f32), min(f32)}
	for place in places {
		card := template.cards[place.card]
		pad := [3]f32{card.w, card.h, card.w} * (0.5 * place.scale)
		for axis in 0 ..< 3 {
			lo[axis] = min(lo[axis], place.pos[axis] - pad[axis])
			hi[axis] = max(hi[axis], place.pos[axis] + pad[axis])
		}
	}
	return
}

@(private = "file")
billboard_child :: proc(node: ^Pssg_Node, names: ..string) -> ^Pssg_Node {
	if node == nil {
		return nil
	}
	for child in node.children {
		for name in names {
			if child.name == name {
				return child
			}
		}
	}
	return nil
}

@(private = "file")
billboard_library :: proc(file: ^Pssg_File, kind: string) -> ^Pssg_Node {
	for child in file.root.children {
		if child.name == "LIBRARY" && pssg_attr_string(file, child, "type") == kind {
			return child
		}
	}
	return nil
}

// Graft one cloud into the library: a root in `NODE`, its data source wrapped in a
// `SEGMENTSET`, its vertex block in `RENDERINTERFACEBOUND`. Every id written starts
// with `name`, which is what lets a re-export strip its own clouds and leave every
// other route's alone.
billboard_cloud_write :: proc(
	lib: ^Prop_Library,
	template: ^Billboard_Template,
	name: string,
	centre: [3]f32,
	places: []Billboard_Place,
	allocator := context.allocator,
) -> (
	cloud: Billboard_Cloud,
	msg: string,
	ok: bool,
) {
	if len(places) == 0 {
		return cloud, fmt.tprintf("%s: no cards to write", name), false
	}
	if len(places) > BILLBOARD_CARDS_MAX {
		return cloud, fmt.tprintf(
			"%s: %d cards overflow a ushort index buffer; the caller has to chunk smaller",
			name, len(places),
		), false
	}
	file := &lib.file
	nodes := billboard_library(file, "NODE")
	segments := billboard_library(file, "SEGMENTSET")
	bounds := billboard_library(file, "RENDERINTERFACEBOUND")
	if nodes == nil || segments == nil || bounds == nil || len(segments.children) == 0 {
		return cloud, "this trees.pssg has no node, segment and data block libraries to graft into", false
	}

	vertices, indices, built := billboard_payloads(file, template.block, template, places, allocator)
	if !built {
		return cloud, fmt.tprintf("%s: could not build the card payloads", name), false
	}
	lo, hi := billboard_bounds(template, places)

	source_id := fmt.tprintf("%s_source", name)
	block_id := fmt.tprintf("%s_block", name)

	root := pssg_clone_node(template.root, allocator)
	pssg_set_attr_string(file, root, "id", fmt.tprintf("%s Root", name), allocator)
	// Every id in the clone has to be renamed. `lod`, `default` and `rigidbody`
	// carry ids as well as nicknames, and a duplicate id hangs the load with no
	// fault and no log line. billboard_duplicate_id below is the backstop.
	billboard_rename(file, root, name, allocator)

	// The template's `lod` and `_x0` boxes are symmetric cubes smaller than the
	// cloud they hold, so neither is the cull box. Use one that contains ours:
	// bigger can only cull less.
	reach := f32(0)
	for axis in 0 ..< 3 {
		reach = max(reach, abs(lo[axis]), abs(hi[axis]))
	}
	lod := billboard_child(root, "NODE")
	level := billboard_child(lod, "NODE", "RENDERNODE")
	draw := billboard_child(level, "RENDERNODE")
	rsi := billboard_child(draw, "RENDERSTREAMINSTANCE")
	instance := billboard_child(rsi, "RENDERINSTANCESOURCE")
	if lod == nil || level == nil || draw == nil || rsi == nil || instance == nil {
		pssg_node_delete(root, allocator)
		delete(vertices, allocator)
		delete(indices, allocator)
		return cloud, fmt.tprintf("%s is not shaped like a card cloud", template.name), false
	}
	// A box each, never one slice twice: pssg_set_data takes ownership, and two
	// nodes owning one allocation is a double free.
	cull_lo, cull_hi := [3]f32{-reach, -reach, -reach}, [3]f32{reach, reach, reach}
	pssg_set_data(billboard_child(lod, "BOUNDINGBOX"), pssg_box_bytes(cull_lo, cull_hi, allocator), allocator)
	pssg_set_data(billboard_child(level, "BOUNDINGBOX"), pssg_box_bytes(cull_lo, cull_hi, allocator), allocator)
	pssg_set_data(billboard_child(draw, "BOUNDINGBOX"), pssg_box_bytes(lo, hi, allocator), allocator)
	pssg_set_attr_string(file, rsi, "id", fmt.tprintf("%s_draw", name), allocator)
	pssg_set_attr_string(file, rsi, "indices", fmt.tprintf("#%s", source_id), allocator)
	pssg_set_attr_string(file, rsi, "shader", template.shader, allocator)
	pssg_set_attr_string(file, instance, "source", fmt.tprintf("#%s", source_id), allocator)

	source := pssg_clone_node(template.source, allocator)
	pssg_set_attr_string(file, source, "id", source_id, allocator)
	index := pssg_walk_first(source, "RENDERINDEXSOURCE")
	blob := billboard_child(index, "INDEXSOURCEDATA")
	if index == nil || blob == nil {
		pssg_node_delete(root, allocator)
		pssg_node_delete(source, allocator)
		delete(vertices, allocator)
		delete(indices, allocator)
		return cloud, fmt.tprintf("%s has no index source to clone", template.name), false
	}
	pssg_set_attr_string(file, index, "id", fmt.tprintf("%s_index", name), allocator)
	pssg_set_attr_u32(file, index, "count", u32(len(places) * 6), allocator)
	pssg_set_attr_u32(file, index, "maximumIndex", u32(len(places) * 4 - 1), allocator)
	pssg_set_data(blob, indices, allocator)
	streams := 0
	for stream in source.children {
		if stream.name != "RENDERSTREAM" {
			continue
		}
		pssg_set_attr_string(file, stream, "id", fmt.tprintf("%s_stream_%d", name, streams), allocator)
		pssg_set_attr_string(file, stream, "dataBlock", fmt.tprintf("#%s", block_id), allocator)
		streams += 1
	}

	block := pssg_clone_node(template.block, allocator)
	pssg_set_attr_string(file, block, "id", block_id, allocator)
	pssg_set_attr_u32(file, block, "size", u32(len(vertices)), allocator)
	pssg_set_attr_u32(file, block, "elementCount", u32(len(places) * 4), allocator)
	pssg_set_data(billboard_child(block, "DATABLOCKDATA"), vertices, allocator)

	// `segmentCount` is how many data sources the holder carries, and the donor
	// may carry two or three. Stock never disagrees; a holder that declares more
	// than it holds hangs the load looking up a source that is not there.
	holder := pssg_clone_node(segments.children[0], allocator)
	for child in holder.children {
		pssg_node_delete(child, allocator)
	}
	clear(&holder.children)
	append(&holder.children, source)
	pssg_set_attr_string(file, holder, "id", fmt.tprintf("%s_segments", name), allocator)
	pssg_set_attr_u32(file, holder, "segmentCount", u32(len(holder.children)), allocator)

	append(&nodes.children, root)
	append(&segments.children, holder)
	append(&bounds.children, block)
	prop_lib_rebind(lib, allocator)
	if clash, clashed := billboard_duplicate_id(lib); clashed {
		return cloud, fmt.tprintf(
			"grafting %s left two nodes with the id %s, which hangs the load; the template %s has a node shape this writer does not rename",
			name, clash, template.name,
		), false
	}
	return Billboard_Cloud {
		name = name, centre = centre, lo = lo, hi = hi, cards = len(places),
	}, "", true
}

// Any id the file now holds twice. Cheap over a file this size, and it turns the
// worst trap in the format into a message: a template with a node shape the
// rename below does not cover would otherwise hang the game on the loading
// screen with nothing in any log.
billboard_duplicate_id :: proc(lib: ^Prop_Library) -> (clash: string, clashed: bool) {
	seen := make(map[string]bool, 0, context.temp_allocator)
	defer delete(seen)
	walk :: proc(file: ^Pssg_File, node: ^Pssg_Node, seen: ^map[string]bool) -> (string, bool) {
		if id := pssg_attr_string(file, node, "id"); id != "" {
			if id in seen {
				return id, true
			}
			seen[id] = true
		}
		for child in node.children {
			if found, dup := walk(file, child, seen); dup {
				return found, true
			}
		}
		return "", false
	}
	return walk(&lib.file, lib.file.root, &seen)
}

// Rename the ids inside a cloned root: the three nicknamed variant nodes, and the
// two LOD levels, whose nickname the engine matches on and whose id has to move
// with it. Anything else carrying an id is a template shape this does not know, and
// billboard_duplicate_id catches that rather than shipping it.
@(private = "file")
billboard_rename :: proc(
	file: ^Pssg_File, root: ^Pssg_Node, name: string, allocator := context.allocator,
) {
	rename :: proc(
		file: ^Pssg_File, node: ^Pssg_Node, name: string, allocator: mem.Allocator,
	) {
		nick := pssg_attr_string(file, node, "nickname")
		switch {
		case nick == "lod", nick == "default", nick == "rigidbody":
			pssg_set_attr_string(file, node, "id", fmt.tprintf("%s_%s", name, nick), allocator)
		case strings.has_suffix(nick, "_x0"), strings.has_suffix(nick, "_fo"):
			tag := fmt.tprintf("%s%s", name, nick[len(nick) - 3:])
			pssg_set_attr_string(file, node, "nickname", tag, allocator)
			pssg_set_attr_string(file, node, "id", tag, allocator)
		}
		for child in node.children {
			rename(file, child, name, allocator)
		}
	}
	rename(file, root, name, allocator)
}

// Drop every cloud written under `prefix`, out of all three libraries. Called
// first, on the live file: a route replaces its own clouds and leaves the other
// routes' standing. Dropping only the root would leave its vertex payload behind
// and the file would grow by a megabyte an export.
billboard_strip :: proc(lib: ^Prop_Library, prefix: string, allocator := context.allocator) -> (dropped: int) {
	for kind in ([]string{"NODE", "SEGMENTSET", "RENDERINTERFACEBOUND"}) {
		library := billboard_library(&lib.file, kind)
		if library == nil {
			continue
		}
		for i := len(library.children) - 1; i >= 0; i -= 1 {
			child := library.children[i]
			if !strings.has_prefix(pssg_attr_string(&lib.file, child, "id"), prefix) {
				continue
			}
			pssg_node_delete(child, allocator)
			ordered_remove(&library.children, i)
			if kind == "NODE" {
				dropped += 1
			}
		}
	}
	prop_lib_rebind(lib, allocator)
	return
}
