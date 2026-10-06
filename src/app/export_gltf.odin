package main

// The glTF 2.0 export target: the stage as plain geometry, for Blender or any
// other DCC tool.
//
// This is the target with no game behind it, so it is also the one that shows
// what an `Export_Job` is without a game's opinions folded in. It writes
// `out/<stage>.gltf` beside `out/<stage>.bin` and nothing else. No backend tool,
// no install step, no config file.
//
// What it does with each part of the job:
//
//   - the mesh becomes one glTF mesh with one primitive per `Mat_Id`, each
//     carrying POSITION / NORMAL / TEXCOORD_0. Non-indexed, flat-shaded, exactly
//     as the soup is built (mesh.odin), so the normals import as hard edges.
//   - each `Mat_Id` becomes a material tinted with the viewport's own colour, so
//     the import reads the way the editor looks. There are no textures.
//   - each prop becomes an empty node named after its `Prop_Kind`, positioned
//     and yawed. Blender imports those as empties, which is the right shape for
//     "put your own tree here".
//   - pace notes are ignored. They are a driving-line idea, and nothing in a DCC
//     tool consumes them.
//
// `--mesh` writes the same mesh as one .glb for a game server: the whole road
// network, no props, each material tagged with its collision surface.
//
// Coordinates pass straight through: glTF is right-handed, Y up, metres, and so
// is the editor. Buffer data is little-endian f32 throughout, which is what the
// f32 component type (5126) means and what every platform we build for is.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../gfx"
import "../geo"

GLTF_F32 :: 5126 // accessor componentType
GLTF_ARRAY_BUFFER :: 34962 // bufferView target for vertex attributes
GLTF_TRIANGLES :: 4 // primitive mode

// Base colour per material, straight off the viewport palette so an import looks
// like the editor. Alpha is always 1: the soup's own alpha is a preview device.
gltf_material_colour :: proc(m: geo.Mat_Id, look: geo.Look) -> gfx.Color {
	switch m {
	case .Road:       return look.road
	case .Road_Paved: return look.road_paved
	case .Cliff:      return look.cliff_top
	case .Terrain:    return look.terrain
	// Per material, and the roadside's whole point is that it varies per vertex.
	// Halfway between its two ends is the closest one colour gets.
	case .Roadside:   return geo.lerp_col(look.terrain, look.road, 0.5)
	case .Gutter:     return look.gutter
	case .Road_Change_Loose, .Road_Change_Paved: return geo.lerp_col(look.road, look.road_paved, 0.5)
	}
	return look.road
}

// --- the binary buffer -------------------------------------------------------

// One attribute's block in the .bin, and the accessor that will describe it.
// Written in job order, so `offset` is simply how much came before.
Gltf_View :: struct {
	offset: int,
	length: int,
	count:  int,    // elements, not floats
	kind:   string, // glTF accessor type: "VEC3", "VEC2"
	lo, hi: [3]f32, // component bounds; only written for POSITION
	bounds: bool,
}

// Append `n` floats and return the view describing them.
gltf_push :: proc(buf: ^[dynamic]byte, vals: []f32, comps: int, kind: string) -> Gltf_View {
	v := Gltf_View {
		offset = len(buf^),
		length = len(vals) * size_of(f32),
		count  = len(vals) / comps,
		kind   = kind,
	}
	for f in vals {
		gltf_u32(buf, transmute(u32)f)
	}
	return v
}

gltf_u32 :: proc(buf: ^[dynamic]byte, bits: u32) {
	append(buf, u8(bits), u8(bits >> 8), u8(bits >> 16), u8(bits >> 24))
}

// Per-component min/max over a VEC3 block. glTF requires these on POSITION, and
// importers use them to frame the scene.
gltf_bounds :: proc(v: ^Gltf_View, vals: []f32) {
	v.lo = {max(f32), max(f32), max(f32)}
	v.hi = {min(f32), min(f32), min(f32)}
	for i := 0; i + 2 < len(vals); i += 3 {
		for c in 0 ..< 3 {
			v.lo[c] = min(v.lo[c], vals[i + c])
			v.hi[c] = max(v.hi[c], vals[i + c])
		}
	}
	v.bounds = true
}

// --- JSON --------------------------------------------------------------------
//
// Hand-written rather than marshalled from structs, because glTF leans on
// *absent* keys: a prop node must have no `mesh`, and an accessor that is not a
// POSITION must have no `min`/`max`. A struct would emit both, and an importer
// would either attach a mesh that is not there or reject an empty bounds array.
//
// `fmt.sbprintf` reads `{` as the start of a format verb with no way to escape
// it, so every literal brace goes through `strings.write_string`.

@(private = "file")
w :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
}

// `[a, b, c]` from floats, at glTF's precision.
@(private = "file")
w_floats :: proc(b: ^strings.Builder, vals: ..f32) {
	w(b, "[")
	for v, i in vals {
		if i > 0 {
			w(b, ",")
		}
		fmt.sbprintf(b, "%.6f", v)
	}
	w(b, "]")
}

// JSON string literal. Stage and prop names reach here, and a stage name is
// already filesystem-safe, so only the structural characters can appear.
@(private = "file")
w_str :: proc(b: ^strings.Builder, s: string) {
	data, err := json.marshal(s, {}, context.temp_allocator)
	if err != nil {
		w(b, "\"\"")
		return
	}
	w(b, string(data))
}


// --- the mesh ----------------------------------------------------------------

// One primitive per material present, in `order`, so each is one contiguous
// run. Three views per primitive: POSITION, NORMAL, TEXCOORD_0.
Gltf_Buffer :: struct {
	used:  [dynamic]geo.Mat_Id,
	bytes: [dynamic]byte,
	views: [dynamic]Gltf_View,
}

gltf_buffer :: proc(g: ^Export_Geometry) -> (gb: Gltf_Buffer) {
	gb.used = make([dynamic]geo.Mat_Id, context.temp_allocator)
	gb.bytes = make([dynamic]byte, context.temp_allocator)
	gb.views = make([dynamic]Gltf_View, context.temp_allocator)
	for mat in geo.Mat_Id {
		if g.counts[mat] > 0 {
			append(&gb.used, mat)
		}
	}

	run_start := 0
	for mat in gb.used {
		n := g.counts[mat]
		chunk := g.order[run_start:run_start + n]
		run_start += n

		pos := make([dynamic]f32, 0, n * 9, context.temp_allocator)
		nrm := make([dynamic]f32, 0, n * 9, context.temp_allocator)
		uv := make([dynamic]f32, 0, n * 6, context.temp_allocator)
		for tri in chunk {
			for j in 0 ..< 3 {
				p := g.mesh.pos[tri * 3 + j]
				nv := g.mesh.nrm[tri * 3 + j]
				t := g.mesh.uv[tri * 3 + j]
				append(&pos, p.x, p.y, p.z)
				append(&nrm, nv.x, nv.y, nv.z)
				// glTF's V runs down from the top-left; the editor's runs up.
				append(&uv, t.x, 1 - t.y)
			}
		}

		pv := gltf_push(&gb.bytes, pos[:], 3, "VEC3")
		gltf_bounds(&pv, pos[:])
		append(&gb.views, pv)
		append(&gb.views, gltf_push(&gb.bytes, nrm[:], 3, "VEC3"))
		append(&gb.views, gltf_push(&gb.bytes, uv[:], 2, "VEC2"))
	}
	return
}

// Node 0 is the mesh; one node per prop follows it. An empty `bin_uri` is a
// .glb, whose buffer is its BIN chunk. `surfaces` tags each material with the
// collision surface it drives as.
gltf_json :: proc(
	gb: ^Gltf_Buffer,
	name: string,
	props: []geo.Veg_Instance,
	look: geo.Look,
	bin_uri: string,
	surfaces: bool,
) -> string {
	b := strings.builder_make(context.temp_allocator)
	w(&b, "{\n")
	w(&b, "\"asset\":{\"version\":\"2.0\",\"generator\":\"dirtbench\"},\n")
	w(&b, "\"scene\":0,\n")

	w(&b, "\"scenes\":[{\"nodes\":[")
	for i in 0 ..< 1 + len(props) {
		if i > 0 {
			w(&b, ",")
		}
		fmt.sbprintf(&b, "%d", i)
	}
	w(&b, "]}],\n")

	w(&b, "\"nodes\":[\n")
	w(&b, "{\"name\":")
	w_str(&b, name)
	w(&b, ",\"mesh\":0}")
	for p in props {
		w(&b, ",\n{\"name\":")
		w_str(&b, fmt.tprintf("%v", p.kind))
		w(&b, ",\"translation\":")
		w_floats(&b, p.pos.x, p.pos.y, p.pos.z)
		// Yaw about +Y as a quaternion: (0, sin(y/2), 0, cos(y/2)).
		w(&b, ",\"rotation\":")
		w_floats(&b, 0, math.sin(p.yaw * 0.5), 0, math.cos(p.yaw * 0.5))
		w(&b, ",\"scale\":")
		w_floats(&b, p.scale, p.scale, p.scale)
		w(&b, "}")
	}
	w(&b, "\n],\n")

	w(&b, "\"meshes\":[{\"name\":")
	w_str(&b, name)
	w(&b, ",\"primitives\":[\n")
	for _, i in gb.used {
		if i > 0 {
			w(&b, ",\n")
		}
		w(&b, "{\"attributes\":{")
		fmt.sbprintf(&b, "\"POSITION\":%d,\"NORMAL\":%d,\"TEXCOORD_0\":%d", i * 3, i * 3 + 1, i * 3 + 2)
		w(&b, "},")
		fmt.sbprintf(&b, "\"material\":%d,\"mode\":%d", i, GLTF_TRIANGLES)
		w(&b, "}")
	}
	w(&b, "\n]}],\n")

	w(&b, "\"materials\":[\n")
	for mat, i in gb.used {
		if i > 0 {
			w(&b, ",\n")
		}
		c := gltf_material_colour(mat, look)
		w(&b, "{\"name\":")
		w_str(&b, fmt.tprintf("%v", mat))
		w(&b, ",\"doubleSided\":false,\"pbrMetallicRoughness\":{\"baseColorFactor\":")
		w_floats(&b, f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 1)
		w(&b, ",\"metallicFactor\":0.0,\"roughnessFactor\":0.9}")
		if surfaces {
			w(&b, ",\"extras\":{\"surface\":")
			w_str(&b, fmt.tprintf("%v", MAT_EXPORT[mat].surface))
			w(&b, "}")
		}
		w(&b, "}")
	}
	w(&b, "\n],\n")

	w(&b, "\"buffers\":[{")
	if bin_uri != "" {
		w(&b, "\"uri\":")
		w_str(&b, bin_uri)
		w(&b, ",")
	}
	fmt.sbprintf(&b, "\"byteLength\":%d", len(gb.bytes))
	w(&b, "}],\n")

	w(&b, "\"bufferViews\":[\n")
	for v, i in gb.views {
		if i > 0 {
			w(&b, ",\n")
		}
		w(&b, "{")
		fmt.sbprintf(
			&b,
			"\"buffer\":0,\"byteOffset\":%d,\"byteLength\":%d,\"target\":%d",
			v.offset,
			v.length,
			GLTF_ARRAY_BUFFER,
		)
		w(&b, "}")
	}
	w(&b, "\n],\n")

	w(&b, "\"accessors\":[\n")
	for v, i in gb.views {
		if i > 0 {
			w(&b, ",\n")
		}
		w(&b, "{")
		fmt.sbprintf(&b, "\"bufferView\":%d,\"componentType\":%d,\"count\":%d,\"type\":", i, GLTF_F32, v.count)
		w_str(&b, v.kind)
		// Shortest round-trip form: a validator wants the exact extremes.
		if v.bounds {
			fmt.sbprintf(&b, ",\"min\":[%v,%v,%v]", v.lo[0], v.lo[1], v.lo[2])
			fmt.sbprintf(&b, ",\"max\":[%v,%v,%v]", v.hi[0], v.hi[1], v.hi[2])
		}
		w(&b, "}")
	}
	w(&b, "\n]\n}\n")
	return strings.to_string(b)
}

// --- the export --------------------------------------------------------------

export_gltf :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	// The same geometry the props were scattered on, or they import floating.
	g := export_drawn(job)
	gb := gltf_buffer(g)

	bin_name := fmt.tprintf("%s.bin", job.name)
	bin_path, _ := filepath.join({job.out, bin_name}, context.temp_allocator)
	if werr := os.write_entire_file(bin_path, gb.bytes[:]); werr != nil {
		return fmt.tprintf("could not write %s: %v", bin_path, werr), false
	}

	text := gltf_json(&gb, job.name, job.props, job.look, bin_name, false)
	gltf_path, _ := filepath.join({job.out, fmt.tprintf("%s.gltf", job.name)}, context.temp_allocator)
	if werr := os.write_entire_file(gltf_path, transmute([]byte)text); werr != nil {
		return fmt.tprintf("could not write %s: %v", gltf_path, werr), false
	}

	prop_note := ""
	if len(job.props) > 0 {
		prop_note = fmt.tprintf(", %d prop markers", len(job.props))
	}
	return fmt.tprintf("exported %d tris%s to %s.gltf", len(g.order), prop_note, job.name), true
}

// --- .glb --------------------------------------------------------------------

GLB_MAGIC :: 0x46546C67 // "glTF"
GLB_VERSION :: 2
GLB_CHUNK_JSON :: 0x4E4F534A
GLB_CHUNK_BIN :: 0x004E4942

// The binary container: a 12-byte header, then the JSON and BIN chunks, each
// padded to 4 bytes (JSON with spaces, BIN with zeros).
glb_bytes :: proc(text: string, bin: []byte) -> []byte {
	json_pad := (4 - len(text) % 4) % 4
	bin_pad := (4 - len(bin) % 4) % 4
	json_len := len(text) + json_pad
	bin_len := len(bin) + bin_pad
	out := make([dynamic]byte, 0, 28 + json_len + bin_len, context.temp_allocator)
	gltf_u32(&out, GLB_MAGIC)
	gltf_u32(&out, GLB_VERSION)
	gltf_u32(&out, u32(28 + json_len + bin_len))
	gltf_u32(&out, u32(json_len))
	gltf_u32(&out, GLB_CHUNK_JSON)
	append(&out, text)
	for _ in 0 ..< json_pad {
		append(&out, ' ')
	}
	gltf_u32(&out, u32(bin_len))
	gltf_u32(&out, GLB_CHUNK_BIN)
	append(&out, ..bin)
	for _ in 0 ..< bin_pad {
		append(&out, 0)
	}
	return out[:]
}

// `--mesh <venue.json> <out.glb>`: the venue's whole road network as one .glb,
// for a game server. Reads only the file it is given: no install, no config,
// no maps/. No props; the server reads `road.props` itself.
mesh_headless :: proc(venue_path, out_path: string) -> (msg: string, ok: bool) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	if msg, ok = load_road(&doc, venue_path); !ok {
		return
	}
	g, gmsg, built := build_geometry(&doc, doc.spline)
	defer export_geometry_delete(&g)
	if !built {
		return gmsg, false
	}
	gb := gltf_buffer(&g)
	// A fixed name, so the bytes depend on the document and not on its path.
	text := gltf_json(&gb, "venue", nil, doc.look, "", true)
	if werr := os.write_entire_file(out_path, glb_bytes(text, gb.bytes[:])); werr != nil {
		return fmt.tprintf("could not write %s: %v", out_path, werr), false
	}
	counts := make([dynamic]string, context.temp_allocator)
	for mat in gb.used {
		append(&counts, fmt.tprintf("%v %d", mat, g.counts[mat]))
	}
	return fmt.tprintf(
		"wrote %d tris to %s (%s)",
		len(g.order), out_path, strings.join(counts[:], ", ", context.temp_allocator),
	), true
}
