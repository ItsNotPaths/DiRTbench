package d3

// Static water — `niwater.pssg` and `niwater.xml`.
//
// One flat polygon per body, drawn by the base venue's own `water.fx`. The
// split is the one routesplit.odin uses: the donor supplies the schema, the two
// shader libraries, the three textures and every attribute id, and the scene,
// the draw calls and the vertex buffers are ours. The donor here is the base
// venue's `niwater.pssg` rather than its `tracksplit.pssg`, because no venue
// keeps water art in a tracksplit.
//
// Static water carries no `track.vis` tag, so nothing culls it and no bit has
// to move. Interactive water needs a tag-6 box per patch, and a new box shifts
// every later bit of every leaf mask, so none is written here.
//
// CAUTION: water is one-sided. It draws only from above, so a body level with
// the ground around it shows nothing. The ground inside the outline has to be
// cut below the surface, which the floor carrying it already does. See
// docs/dirt3-water.md.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Every stock water body maps ST over its own extent, u along +X and v along
// +Z, inside 0..1. (`_shore` groups run 1 unit per metre; none are emitted.)
D3_WATER_SHADER :: "water"
D3_WATER_TYPE :: "water"

// 44 bytes over 6 streams, which is what `water.fx` reads. `interactive_water`
// takes a seventh stream and a 48-byte stride; the layout follows the shader,
// not the file.
D3_WATER_STRIDE :: 44
D3_WATER_OFF_ST :: 16
D3_WATER_OFF_NORMAL :: 20
D3_WATER_OFF_TANGENT :: 28
D3_WATER_OFF_BINORMAL :: 36

// One draw call is indexed by ushort.
D3_WATER_MAX_VERTS :: 65536

// A body flat on both horizontal axes has no area to draw.
D3_WATER_MIN_EXTENT :: 0.1

// The frame every stock water vertex carries: normal +Y, tangent +X, binormal
// -Z, each a half4 whose w is 1.
D3_WATER_FRAME :: [3][4]f32{{0, 1, 0, 1}, {1, 0, 0, 1}, {0, 0, -1, 1}}

// One body of water: a closed outline in world XZ at one height, already
// triangulated. The caller triangulates because it is the one that knows the
// outline is a pad and not a coastline.
D3_Water_Body :: struct {
	name:   string,
	y:      f32,
	points: [][2]f32,
	tris:   [][3]u32,
}

d3_water_bounds :: proc(body: D3_Water_Body) -> (lo, hi: [3]f32) {
	lo = {max(f32), body.y, max(f32)}
	hi = {min(f32), body.y, min(f32)}
	for p in body.points {
		lo[0] = min(lo[0], p[0]); hi[0] = max(hi[0], p[0])
		lo[2] = min(lo[2], p[1]); hi[2] = max(hi[2], p[1])
	}
	return
}

// The vertex buffer for one body, flat at `body.y` in D3_WATER_FRAME's frame.
//
// The bounding box stays flat with it: water is the documented exception to
// dirt3-pssg-flat-bbox — every stock water node has min.y == max.y and draws,
// so padding would invent a thickness the format does not want.
d3_water_vertices :: proc(body: D3_Water_Body, lo, hi: [3]f32, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(body.points) * D3_WATER_STRIDE, allocator)
	span := [2]f32{max(hi[0] - lo[0], D3_WATER_MIN_EXTENT), max(hi[2] - lo[2], D3_WATER_MIN_EXTENT)}
	for p, i in body.points {
		at := i * D3_WATER_STRIDE
		binary_store_f32(out, at, p[0], .Big)
		binary_store_f32(out, at + 4, body.y, .Big)
		binary_store_f32(out, at + 8, p[1], .Big)
		binary_store_u32(out, at + 12, 0xff00_0000, .Big)
		binary_store_u16(out, at + D3_WATER_OFF_ST, d3_half((p[0] - lo[0]) / span[0]), .Big)
		binary_store_u16(out, at + D3_WATER_OFF_ST + 2, d3_half((p[1] - lo[2]) / span[1]), .Big)
		// Normal, tangent and binormal, three half4s back to back from +20.
		for vec, slot in D3_WATER_FRAME {
			base := at + D3_WATER_OFF_NORMAL + slot * 8
			for v, k in vec { binary_store_u16(out, base + k * 2, d3_half(v), .Big) }
		}
	}
	return out
}

d3_water_indices :: proc(body: D3_Water_Body, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(body.tris) * 6, allocator)
	for tri, i in body.tris {
		for k in 0 ..< 3 {
			binary_store_u16(out, i * 6 + k * 2, u16(tri[k]), .Big)
		}
	}
	return out
}

// The six streams of a `water.fx` draw, in the order stock writes them.
d3_water_streams :: proc(b: ^D3_Build) -> []^Pssg_Node {
	kinds := [6]struct {
		render_type, data_type: string,
		offset:                 u32,
	} {
		{"Vertex", "float3", 0},
		{"Color", "uint_color_argb", 12},
		{"ST", "half2", D3_WATER_OFF_ST},
		{"Normal", "half4", D3_WATER_OFF_NORMAL},
		{"Tangent", "half4", D3_WATER_OFF_TANGENT},
		{"Binormal", "half4", D3_WATER_OFF_BINORMAL},
	}
	out := make([dynamic]^Pssg_Node, b.allocator)
	for k in kinds {
		append(&out, d3_node(b, "DATABLOCKSTREAM", []Pssg_Set{
			{"renderType", k.render_type},
			{"dataType", k.data_type},
			{"offset", k.offset},
			{"stride", u32(D3_WATER_STRIDE)},
		}))
	}
	return out[:]
}

// A body a draw call can carry: enough geometry, indices in range, some area.
d3_water_body_check :: proc(b: ^D3_Build, body: D3_Water_Body, lo, hi: [3]f32) -> bool {
	if len(body.points) < 3 || len(body.tris) < 1 {
		d3_fail(b, fmt.tprintf("water body %q has %d points and %d triangles, so it draws nothing",
			body.name, len(body.points), len(body.tris)))
		return false
	}
	if len(body.points) > D3_WATER_MAX_VERTS {
		d3_fail(b, fmt.tprintf("water body %q has %d points, past the %d a ushort index reaches",
			body.name, len(body.points), D3_WATER_MAX_VERTS))
		return false
	}
	for tri in body.tris {
		for k in 0 ..< 3 {
			if int(tri[k]) >= len(body.points) {
				d3_fail(b, fmt.tprintf("water body %q indexes point %d of %d",
					body.name, tri[k], len(body.points)))
				return false
			}
		}
	}
	if hi[0] - lo[0] < D3_WATER_MIN_EXTENT || hi[2] - lo[2] < D3_WATER_MIN_EXTENT {
		d3_fail(b, fmt.tprintf("water body %q is %.2f x %.2f m, too thin to draw",
			body.name, hi[0] - lo[0], hi[2] - lo[2]))
		return false
	}
	return true
}

// One body: a DATABLOCK, a SEGMENTSET holding its draw call, and a RENDERNODE.
d3_water_body_nodes :: proc(b: ^D3_Build, body: D3_Water_Body, nodes: ^[dynamic]^Pssg_Node) {
	lo, hi := d3_water_bounds(body)
	if !d3_water_body_check(b, body, lo, hi) {
		return
	}

	block_id := pssg_mint(b.ids, b.allocator)
	source_id := pssg_mint(b.ids, b.allocator)
	index_id := pssg_mint(b.ids, b.allocator)
	set_id := pssg_mint(b.ids, b.allocator)
	instance_id := pssg_mint(b.ids, b.allocator)

	block_kids := make([dynamic]^Pssg_Node, b.allocator)
	for stream in d3_water_streams(b) { append(&block_kids, stream) }
	payload := d3_water_vertices(body, lo, hi, b.allocator)
	append(&block_kids, d3_node(b, "DATABLOCKDATA", nil, nil, payload))
	append(&b.blocks, d3_node(b, "DATABLOCK", []Pssg_Set{
		{"streamCount", u32(6)},
		{"size", u32(len(body.points) * D3_WATER_STRIDE)},
		{"elementCount", u32(len(body.points))},
		{"id", block_id},
	}, block_kids[:]))

	source_kids := make([dynamic]^Pssg_Node, b.allocator)
	append(&source_kids, d3_node(b, "RENDERINDEXSOURCE", []Pssg_Set{
		{"primitive", "triangles"},
		{"maximumIndex", u32(len(body.points) - 1)},
		{"format", "ushort"},
		{"count", u32(len(body.tris) * 3)},
		{"id", index_id},
	}, []^Pssg_Node{d3_node(b, "INDEXSOURCEDATA", nil, nil, d3_water_indices(body, b.allocator))}))
	for k in 0 ..< 6 {
		append(&source_kids, d3_node(b, "RENDERSTREAM", []Pssg_Set{
			{"dataBlock", d3_ref(block_id)},
			{"subStream", u32(k)},
			{"id", fmt.tprintf("%s_%d", source_id, k)},
		}))
	}
	append(&b.segments, d3_node(b, "SEGMENTSET", []Pssg_Set{
		{"segmentCount", u32(1)},
		{"id", set_id},
	}, []^Pssg_Node{d3_node(b, "RENDERDATASOURCE", []Pssg_Set{
		{"streamCount", u32(6)},
		{"primitive", "triangles"},
		{"id", source_id},
	}, source_kids[:])}))

	frame, frame_msg, frame_ok := pssg_frame(b.types, lo, hi, b.allocator)
	if !frame_ok {
		d3_fail(b, frame_msg)
		return
	}
	append(nodes, d3_node(b, "RENDERNODE", []Pssg_Set{
		{"stopTraversal", u32(0)},
		{"nickname", body.name},
		{"id", body.name},
	}, []^Pssg_Node{
		frame[0],
		frame[1],
		d3_node(b, "RENDERSTREAMINSTANCE", []Pssg_Set{
			{"sourceCount", u32(1)},
			{"indices", d3_ref(source_id)},
			{"streamCount", u32(0)},
			{"shader", d3_ref(D3_WATER_SHADER)},
			{"id", instance_id},
		}, []^Pssg_Node{d3_node(b, "RENDERINSTANCESOURCE", []Pssg_Set{{"source", d3_ref(source_id)}})}),
	}))
}

// The patch list. Plain text with CRLF, indices dense from zero, no trailing
// newline (stock's empty form has none). A patch's `type` selects the shader
// and must name the group the node it points at uses.
d3_niwater_xml :: proc(bodies: []D3_Water_Body, allocator := context.allocator) -> []u8 {
	if len(bodies) == 0 {
		return d3_stub_text(D3_STUB_INTERACTIVE_WATER, allocator)
	}
	out := strings.builder_make(allocator)
	strings.write_string(&out, "<interactiveWater>\r\n")
	for body, i in bodies {
		fmt.sbprintf(&out,
			"  <interactiveWaterPatch index=\"%d\" uri=\"niwater.pssg#%s\" type=\"%s\" />\r\n",
			i, body.name, D3_WATER_TYPE)
	}
	strings.write_string(&out, "</interactiveWater>")
	return out.buf[:]
}

// --- the file ----------------------------------------------------------------

// The libraries a stock `niwater.pssg` holds, in its order. The donor is
// rewritten in place rather than rebuilt: its schema, its two shader groups,
// its two shader instances and its three textures are all known-good, and
// every attribute id we mint a node with is read back off it.
D3_NIWATER_LIBRARIES :: []string{
	"SHADERINSTANCE", "SHADERGROUP", "SEGMENTSET", "RENDERINTERFACEBOUND", "NODE",
}

d3_niwater_library :: proc(file: ^Pssg_File, kind: string) -> ^Pssg_Node {
	for child in file.root.children {
		if child.name == "LIBRARY" && pssg_attr_string(file, child, "type") == kind {
			return child
		}
	}
	return nil
}

// Keep the children of `lib` whose node name is `keep`, drop the rest, then
// adopt `added`. Not pssg_set_children: that frees every old child, and the
// textures we are keeping are old children.
d3_niwater_relibrary :: proc(lib: ^Pssg_Node, keep: string, added: []^Pssg_Node, allocator: mem.Allocator) {
	kept := make([dynamic]^Pssg_Node, allocator)
	defer delete(kept)
	for child in lib.children {
		if child.name == keep {
			append(&kept, child)
		} else {
			pssg_node_delete(child, allocator)
		}
	}
	clear(&lib.children)
	// Added first, kept after: a stock RENDERINTERFACEBOUND opens with a
	// DATABLOCK, not a texture.
	for child in added { append(&lib.children, child) }
	for child in kept { append(&lib.children, child) }
}

// Every library, the `water` shader instance, and the water textures — what
// our minted nodes lean on.
d3_niwater_donor_check :: proc(file: ^Pssg_File) -> (textures: int, msg: string, ok: bool) {
	for kind in D3_NIWATER_LIBRARIES {
		if d3_niwater_library(file, kind) == nil {
			return 0, fmt.tprintf("the base venue's niwater.pssg has no %s library", kind), false
		}
	}
	shaders := d3_niwater_library(file, "SHADERINSTANCE")
	if pssg_walk_first_by_id(file, shaders, "SHADERINSTANCE", D3_WATER_SHADER) == nil {
		return 0, fmt.tprintf(
			"the base venue's niwater.pssg has no %q shader instance, so its water cannot be drawn",
			D3_WATER_SHADER), false
	}
	art := d3_niwater_library(file, "RENDERINTERFACEBOUND")
	for child in art.children { if child.name == "TEXTURE" { textures += 1 } }
	if textures == 0 {
		return 0, "the base venue's niwater.pssg carries no textures, and water art lives nowhere else", false
	}
	return textures, "", true
}

d3_water_nodes_delete :: proc(nodes: []^Pssg_Node, allocator: mem.Allocator) {
	for node in nodes { pssg_node_delete(node, allocator) }
}

// `niwater.pssg` for one stage: the donor's art and shaders, our bodies.
//
// At least one body is required: an empty scene pairs with an empty patch
// list, which faults at load wherever `waterdefs` survive. See
// d3_write_niwater.
d3_niwater_build :: proc(
	donor: []u8,
	bodies: []D3_Water_Body,
	allocator := context.allocator,
) -> (out: []u8, msg: string, ok: bool) {
	if len(bodies) == 0 {
		return nil, "a niwater.pssg with no bodies would pair with an empty patch list, which faults at load", false
	}
	file, read_msg, read_ok := pssg_read(donor, allocator)
	if !read_ok {
		return nil, fmt.tprintf("the base venue's niwater.pssg will not read: %s", read_msg), false
	}
	defer pssg_delete(&file, allocator)

	textures, donor_msg, donor_ok := d3_niwater_donor_check(&file)
	if !donor_ok {
		return nil, donor_msg, false
	}

	nodes := d3_niwater_library(&file, "NODE")
	root := pssg_walk_first(nodes, "ROOTNODE")
	if root == nil {
		return nil, "the base venue's niwater.pssg has no ROOTNODE", false
	}

	types := pssg_types(&file, allocator)
	defer delete(types.node_id); defer delete(types.attr_id)
	ids := pssg_ids(&file, allocator)
	defer pssg_ids_delete(&ids)

	b := D3_Build{
		file = &file, types = &types, ids = &ids,
		blocks = make([dynamic]^Pssg_Node, allocator),
		segments = make([dynamic]^Pssg_Node, allocator),
		allocator = allocator, ok = true,
	}
	defer delete(b.blocks); defer delete(b.segments)
	drawn := make([dynamic]^Pssg_Node, allocator); defer delete(drawn)

	seen := make(map[string]bool, allocator); defer delete(seen)
	for body in bodies {
		// A duplicate id hangs the load, and the xml addresses a body by name.
		if seen[body.name] {
			return nil, fmt.tprintf("two water bodies are both named %q", body.name), false
		}
		seen[body.name] = true
		d3_water_body_nodes(&b, body, &drawn)
		if !b.ok { break }
	}
	if !b.ok {
		d3_water_nodes_delete(b.blocks[:], allocator)
		d3_water_nodes_delete(b.segments[:], allocator)
		d3_water_nodes_delete(drawn[:], allocator)
		return nil, b.msg, false
	}

	pssg_set_children(d3_niwater_library(&file, "SEGMENTSET"), b.segments[:], allocator)
	d3_niwater_relibrary(d3_niwater_library(&file, "RENDERINTERFACEBOUND"), "TEXTURE", b.blocks[:], allocator)

	// A zero box and an identity transform, like every stock ROOTNODE; the
	// bounds live on the RENDERNODEs.
	frame, frame_msg, frame_ok := pssg_frame(&types, {0, 0, 0}, {0, 0, 0}, allocator)
	if !frame_ok {
		d3_water_nodes_delete(drawn[:], allocator)
		return nil, frame_msg, false
	}
	scene := make([dynamic]^Pssg_Node, allocator); defer delete(scene)
	append(&scene, frame[0]); append(&scene, frame[1])
	for node in drawn { append(&scene, node) }
	pssg_set_children(root, scene[:], allocator)

	bytes, wrote := pssg_write(&file, allocator)
	if !wrote {
		return nil, "the synthesized niwater.pssg would not serialize", false
	}
	return bytes, fmt.tprintf("%d water %s, %d textures kept",
		len(bodies), len(bodies) == 1 ? "body" : "bodies", textures), true
}

// `niwater.pssg` and `niwater.xml` for one route.
//
// The donor is the route's **own** `niwater.pssg`, read before it is
// overwritten. A venue of ours starts as a hardlink of the base route's files,
// so that file is the base venue's water art; on a second export it is our own
// previous output, which holds the same shaders and the same textures. Either
// way it is read once and replaced, and the write is a rename, so the hardlink
// the base venue shares is broken rather than followed.
//
// With no water this writes **nothing at all** and leaves the base venue's two
// lists alone, because they agree with each other and ours would not. A stage
// that drops its last body therefore keeps the previous file, which is the safe
// direction.
d3_write_niwater :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	dir, dir_msg, dir_ok := d3_out_dir(job)
	if !dir_ok {
		return dir_msg, false
	}
	path, _ := filepath.join({dir, "niwater.pssg"}, context.temp_allocator)

	if len(job.Water) == 0 {
		return "no water on this stage, so its files are left as they are", true
	}
	if !os.exists(path) {
		return "this route has no niwater.pssg, so the venue ships no water art to draw with", false
	}

	donor, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read %s: %v", path, read_err), false
	}
	built, build_msg, built_ok := d3_niwater_build(donor, job.Water, context.temp_allocator)
	if !built_ok {
		return build_msg, false
	}
	if pssg_msg, wrote := d3_write_out(job, "niwater.pssg", built); !wrote {
		return pssg_msg, false
	}
	xml := d3_niwater_xml(job.Water, context.temp_allocator)
	if xml_msg, wrote := d3_write_out(job, "niwater.xml", xml); !wrote {
		return xml_msg, false
	}
	// CAUTION: the interactive list has to go with it. Its patches carry
	// `ni*Border` indices into the **static** list, and one left pointing past
	// our shorter list crashes the load. No interactive water is emitted, so
	// the stub: no patches, no borders, nothing to dangle.
	stub := d3_stub_text(D3_STUB_INTERACTIVE_WATER, context.temp_allocator)
	if stub_msg, wrote := d3_write_out(job, "iwater.xml", stub); !wrote {
		return stub_msg, false
	}
	return build_msg, true
}
