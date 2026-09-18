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
gltf_material_colour :: proc(m: geo.Mat_Id) -> gfx.Color {
	switch m {
	case .Road:     return geo.ROAD_COL
	case .RoadSand: return geo.ROAD_COL_SAND
	case .Cliff:    return geo.CLIFF_TOP
	case .Terrain:  return geo.TERRAIN_FLAT
	}
	return geo.ROAD_COL
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
		bits := transmute(u32)f
		append(buf, u8(bits), u8(bits >> 8), u8(bits >> 16), u8(bits >> 24))
	}
	return v
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

// --- the export --------------------------------------------------------------

export_gltf :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	// The same geometry the props were scattered on, or they import floating.
	g := export_drawn(job)
	// One primitive per material actually present, in job order — which is the
	// order `order` is sorted in, so each group is one contiguous run.
	used := make([dynamic]geo.Mat_Id, context.temp_allocator)
	for mat in geo.Mat_Id {
		if g.counts[mat] > 0 {
			append(&used, mat)
		}
	}

	buf := make([dynamic]byte, context.temp_allocator)
	views := make([dynamic]Gltf_View, context.temp_allocator) // 3 per primitive: pos, nrm, uv

	run_start := 0
	for mat in used {
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

		pv := gltf_push(&buf, pos[:], 3, "VEC3")
		gltf_bounds(&pv, pos[:])
		append(&views, pv)
		append(&views, gltf_push(&buf, nrm[:], 3, "VEC3"))
		append(&views, gltf_push(&buf, uv[:], 2, "VEC2"))
	}

	bin_name := fmt.tprintf("%s.bin", job.name)
	bin_path, _ := filepath.join({job.out, bin_name}, context.temp_allocator)
	if werr := os.write_entire_file(bin_path, buf[:]); werr != nil {
		return fmt.tprintf("could not write %s: %v", bin_path, werr), false
	}

	b := strings.builder_make(context.temp_allocator)
	w(&b, "{\n")
	w(&b, "\"asset\":{\"version\":\"2.0\",\"generator\":\"dirtbench\"},\n")
	w(&b, "\"scene\":0,\n")

	// Node 0 is the stage mesh; one node per prop follows it.
	w(&b, "\"scenes\":[{\"nodes\":[")
	for i in 0 ..< 1 + len(job.props) {
		if i > 0 {
			w(&b, ",")
		}
		fmt.sbprintf(&b, "%d", i)
	}
	w(&b, "]}],\n")

	w(&b, "\"nodes\":[\n")
	w(&b, "{\"name\":")
	w_str(&b, job.name)
	w(&b, ",\"mesh\":0}")
	for p in job.props {
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
	w_str(&b, job.name)
	w(&b, ",\"primitives\":[\n")
	for _, i in used {
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
	for mat, i in used {
		if i > 0 {
			w(&b, ",\n")
		}
		c := gltf_material_colour(mat)
		w(&b, "{\"name\":")
		w_str(&b, fmt.tprintf("%v", mat))
		w(&b, ",\"doubleSided\":false,\"pbrMetallicRoughness\":{\"baseColorFactor\":")
		w_floats(&b, f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 1)
		w(&b, ",\"metallicFactor\":0.0,\"roughnessFactor\":0.9}}")
	}
	w(&b, "\n],\n")

	w(&b, "\"buffers\":[{\"uri\":")
	w_str(&b, bin_name)
	fmt.sbprintf(&b, ",\"byteLength\":%d", len(buf))
	w(&b, "}],\n")

	w(&b, "\"bufferViews\":[\n")
	for v, i in views {
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
	for v, i in views {
		if i > 0 {
			w(&b, ",\n")
		}
		w(&b, "{")
		fmt.sbprintf(&b, "\"bufferView\":%d,\"componentType\":%d,\"count\":%d,\"type\":", i, GLTF_F32, v.count)
		w_str(&b, v.kind)
		if v.bounds {
			w(&b, ",\"min\":")
			w_floats(&b, v.lo[0], v.lo[1], v.lo[2])
			w(&b, ",\"max\":")
			w_floats(&b, v.hi[0], v.hi[1], v.hi[2])
		}
		w(&b, "}")
	}
	w(&b, "\n]\n}\n")

	gltf_path, _ := filepath.join({job.out, fmt.tprintf("%s.gltf", job.name)}, context.temp_allocator)
	if werr := os.write_entire_file(gltf_path, transmute([]byte)strings.to_string(b)); werr != nil {
		return fmt.tprintf("could not write %s: %v", gltf_path, werr), false
	}

	prop_note := ""
	if len(job.props) > 0 {
		prop_note = fmt.tprintf(", %d prop markers", len(job.props))
	}
	return fmt.tprintf("exported %d tris%s to %s.gltf", len(g.order), prop_note, job.name), true
}
