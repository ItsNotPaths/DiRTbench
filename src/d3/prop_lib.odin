package d3

// A venue's prop library: the meshes in `objects.pssg` (ornaments and physics
// props) and `trees.pssg`. Both files sit at the venue base, one level above
// `route_n`, and are shared by every route of that venue.
//
// A placement names a prop by bare name. `ornaments.bin` and `trees.bin` do it
// directly; `objects.ens` does it through `objecttypes.pssg`. Here the name is
// the key: a node in the file's `NODE` library whose `id` is `"<name> Root"`.
//
// Only what the editor draws is read: positions and triangles at LOD0. Normals,
// colours, UVs and every texture reference are skipped — the viewport shades a
// prop flat off its own face normals, so none of the art is needed to place one.
//
// Under a prop root: a node nicknamed `lod` whose direct render instances are
// LOD0, a `LODRENDERINSTANCES` block holding the cheaper levels, then variant
// nodes the entity layer switches between. Trees nest their levels one deeper
// as `_xt` / `_x0` / `_x2` / `_xs`, `_xt` most detailed. Every transform in a
// prop is identity, so the geometry is straight model space.

import "core:os"
import "core:slice"
import "core:strings"

// Most detailed first. A tree's levels are sub-nodes with these suffixes rather
// than a LODRENDERINSTANCES block.
PROP_LOD_SUFFIXES :: [?]string{"_xt", "_x0", "_x2", "_xs"}

// One prop, by the name a placement file uses.
Prop_Entry :: struct {
	name: string, // the root's id, less " Root"
	root: ^Pssg_Node,
}

// One library file, parsed and indexed. `data` is the file bytes and the PSSG
// borrows them, so both are owned here and freed together.
Prop_Library :: struct {
	data:  []u8,
	file:  Pssg_File,
	by_id: map[string]^Pssg_Node,
	props: [dynamic]Prop_Entry, // sorted by name
}

// One prop's drawn geometry, merged over its draw calls. Model space, metres.
Prop_Mesh :: struct {
	pos:  [][3]f32,
	tris: []u32, // three indices into `pos` per triangle
	lo:   [3]f32,
	hi:   [3]f32,
}

prop_lib_open :: proc(
	path: string, allocator := context.allocator,
) -> (lib: Prop_Library, msg: string, ok: bool) {
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return lib, "could not read the prop library", false
	}
	file, read_msg, read_ok := pssg_read(data, allocator)
	if !read_ok {
		delete(data, allocator)
		return lib, read_msg, false
	}
	lib.data = data
	lib.file = file
	prop_lib_bind(&lib, allocator)
	return lib, "", true
}

// Index a parsed library: every id, and every prop root. Split out from the
// open so a test can bind a hand-built file without going through bytes.
prop_lib_bind :: proc(lib: ^Prop_Library, allocator := context.allocator) {
	lib.by_id = make(map[string]^Pssg_Node, allocator)
	lib.props = make([dynamic]Prop_Entry, allocator)
	prop_lib_index(lib, lib.file.root)

	for child in lib.file.root.children {
		if child.name != "LIBRARY" || pssg_attr_string(&lib.file, child, "type") != "NODE" {
			continue
		}
		for node in child.children {
			id := pssg_attr_string(&lib.file, node, "id")
			if id == "" {
				continue
			}
			name := strings.trim_space(strings.trim_suffix(id, " Root"))
			append(&lib.props, Prop_Entry{name = name, root = node})
		}
	}
	slice.sort_by(lib.props[:], proc(a, b: Prop_Entry) -> bool { return a.name < b.name })
}

prop_lib_delete :: proc(lib: ^Prop_Library, allocator := context.allocator) {
	delete(lib.props)
	delete(lib.by_id)
	pssg_delete(&lib.file, allocator)
	delete(lib.data, allocator)
	lib^ = {}
}

// Every node with an `id`, so a `source` or `dataBlock` reference resolves in
// one lookup. First wins: stock files repeat an id only on the generated
// tokens, and a draw call names the real one.
prop_lib_index :: proc(lib: ^Prop_Library, node: ^Pssg_Node) {
	if node == nil {
		return
	}
	if id := pssg_attr_string(&lib.file, node, "id"); id != "" {
		if _, seen := lib.by_id[id]; !seen {
			lib.by_id[id] = node
		}
	}
	for child in node.children {
		prop_lib_index(lib, child)
	}
}

prop_lib_find :: proc(lib: ^Prop_Library, name: string) -> ^Pssg_Node {
	for entry in lib.props {
		if entry.name == name {
			return entry.root
		}
	}
	return nil
}

// The label a walk records for a node: its nickname, else its id, else the
// element name. The LOD rules below are written against these.
prop_node_label :: proc(lib: ^Prop_Library, node: ^Pssg_Node) -> string {
	if nick := pssg_attr_string(&lib.file, node, "nickname"); nick != "" {
		return nick
	}
	if id := pssg_attr_string(&lib.file, node, "id"); id != "" {
		return id
	}
	return node.name
}

// One draw call found under a prop: which source it reads, which LOD suffix the
// path to it carried, and whether that path went through LODRENDERINSTANCES —
// which is what makes it a cheaper level rather than LOD0.
Prop_Draw :: struct {
	source: string,
	suffix: string,
	cheap:  bool,
}

// Collect the draw calls under the prop's `lod` child. `depth` counts nodes
// below the root, and the `lod` test is on depth 1: a prop's variant nodes sit
// beside that child, not under it.
prop_collect :: proc(
	lib: ^Prop_Library,
	node: ^Pssg_Node,
	depth: int,
	under_lod, under_lod_list: bool,
	lod_suffix: string,
	out: ^[dynamic]Prop_Draw,
) {
	label := prop_node_label(lib, node)
	lod := under_lod || (depth == 1 && strings.has_prefix(label, "lod"))
	listed := under_lod_list || node.name == "LODRENDERINSTANCES"
	suffix := lod_suffix
	for s in PROP_LOD_SUFFIXES {
		if strings.has_suffix(label, s) {
			suffix = s
		}
	}
	if lod && node.name == "RENDERSTREAMINSTANCE" {
		for child in node.children {
			if child.name != "RENDERINSTANCESOURCE" {
				continue
			}
			src := strings.trim_prefix(pssg_attr_string(&lib.file, child, "source"), "#")
			if src != "" {
				append(out, Prop_Draw{source = src, suffix = suffix, cheap = listed})
			}
		}
	}
	for child in node.children {
		prop_collect(lib, child, depth + 1, lod, listed, suffix, out)
	}
}

// Which draw calls are LOD0. A tree picks the most detailed suffix present and
// keeps the unsuffixed calls with it; anything else keeps the calls that are
// not in a LODRENDERINSTANCES block.
prop_lod0 :: proc(draws: []Prop_Draw, allocator := context.temp_allocator) -> []Prop_Draw {
	keep := ""
	for s in PROP_LOD_SUFFIXES {
		for d in draws {
			if !d.cheap && d.suffix == s {
				keep = s
				break
			}
		}
		if keep != "" {
			break
		}
	}
	out := make([dynamic]Prop_Draw, allocator)
	for d in draws {
		if d.cheap || (keep != "" && d.suffix != "" && d.suffix != keep) {
			continue
		}
		append(&out, d)
	}
	return out[:]
}

// The positions and triangles of one draw call. The vertex stream is whichever
// DATABLOCK holds a float3 `Vertex`; every other stream is skipped.
prop_draw_geometry :: proc(
	lib: ^Prop_Library, source_id: string, allocator := context.temp_allocator,
) -> (pos: [][3]f32, idx: []u32, ok: bool) {
	source, found := lib.by_id[source_id]
	if !found {
		return nil, nil, false
	}
	index := pssg_walk_first(source, "RENDERINDEXSOURCE")
	if index == nil {
		return nil, nil, false
	}
	blob := pssg_walk_first(index, "INDEXSOURCEDATA")
	count, has_count := pssg_attr_u32(&lib.file, index, "count")
	format := pssg_attr_string(&lib.file, index, "format")
	if blob == nil || !has_count || (format != "ushort" && format != "uint") {
		return nil, nil, false
	}
	istride := format == "ushort" ? 2 : 4
	if !binary_range(len(blob.data), 0, int(count) * istride) {
		return nil, nil, false
	}
	idx = make([]u32, int(count), allocator)
	for i in 0 ..< int(count) {
		if istride == 2 {
			idx[i] = u32(binary_load_u16(blob.data, i * 2, .Big))
		} else {
			idx[i] = binary_load_u32(blob.data, i * 4, .Big)
		}
	}

	for stream in source.children {
		if stream.name != "RENDERSTREAM" {
			continue
		}
		block_id := strings.trim_prefix(pssg_attr_string(&lib.file, stream, "dataBlock"), "#")
		block, block_found := lib.by_id[block_id]
		if !block_found {
			continue
		}
		total, has_total := pssg_attr_u32(&lib.file, block, "elementCount")
		payload := pssg_walk_first(block, "DATABLOCKDATA")
		if !has_total || total == 0 || payload == nil {
			continue
		}
		for decl in block.children {
			render_type := pssg_attr_string(&lib.file, decl, "renderType")
			if decl.name != "DATABLOCKSTREAM" ||
			   (render_type != "Vertex" && render_type != "SkinnableVertex") ||
			   pssg_attr_string(&lib.file, decl, "dataType") != "float3" {
				continue
			}
			off, has_off := pssg_attr_u32(&lib.file, decl, "offset")
			vstride, has_stride := pssg_attr_u32(&lib.file, decl, "stride")
			if !has_off || !has_stride || vstride < 12 {
				continue
			}
			last := int(off) + int(total - 1) * int(vstride)
			if !binary_range(len(payload.data), last, 12) {
				continue
			}
			pos = make([][3]f32, int(total), allocator)
			for i in 0 ..< int(total) {
				at := int(off) + i * int(vstride)
				pos[i] = {
					binary_load_f32(payload.data, at, .Big),
					binary_load_f32(payload.data, at + 4, .Big),
					binary_load_f32(payload.data, at + 8, .Big),
				}
			}
			return pos, idx, true
		}
	}
	return nil, nil, false
}

// One prop's LOD0 geometry, its draw calls merged into a single mesh. Nothing
// is welded: a prop is drawn and never simulated, so merging vertices would
// cost more than the triangles it saves.
prop_lib_mesh :: proc(
	lib: ^Prop_Library, name: string, allocator := context.allocator,
) -> (mesh: Prop_Mesh, ok: bool) {
	root := prop_lib_find(lib, name)
	if root == nil {
		return mesh, false
	}
	draws := make([dynamic]Prop_Draw, context.temp_allocator)
	prop_collect(lib, root, 0, false, false, "", &draws)

	pos := make([dynamic][3]f32, context.temp_allocator)
	tris := make([dynamic]u32, context.temp_allocator)
	for draw in prop_lod0(draws[:]) {
		part_pos, part_idx, part_ok := prop_draw_geometry(lib, draw.source)
		if !part_ok {
			continue
		}
		base := u32(len(pos))
		append(&pos, ..part_pos)
		// Whole triangles only: an out-of-range index drops its triangle, not
		// itself, or every index after it slips into the wrong triangle.
		for t := 0; t + 2 < len(part_idx); t += 3 {
			a, b, c := part_idx[t], part_idx[t + 1], part_idx[t + 2]
			if int(max(a, b, c)) < len(part_pos) {
				append(&tris, base + a, base + b, base + c)
			}
		}
	}
	if len(pos) == 0 || len(tris) == 0 {
		return mesh, false
	}
	mesh.pos = slice.clone(pos[:], allocator)
	mesh.tris = slice.clone(tris[:], allocator)
	mesh.lo, mesh.hi = mesh.pos[0], mesh.pos[0]
	for p in mesh.pos {
		for k in 0 ..< 3 {
			mesh.lo[k] = min(mesh.lo[k], p[k])
			mesh.hi[k] = max(mesh.hi[k], p[k])
		}
	}
	return mesh, true
}

prop_mesh_delete :: proc(mesh: ^Prop_Mesh, allocator := context.allocator) {
	delete(mesh.pos, allocator)
	delete(mesh.tris, allocator)
	mesh^ = {}
}
