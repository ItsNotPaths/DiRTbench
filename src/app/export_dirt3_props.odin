package main

// Placements on the way out: the props placed by hand (props.odin) and the
// vegetation scatter, which export_dirt3_placement.odin hands over in the same
// form so that one pipeline writes both.
//
// A placement file names a mesh through a reference row, so every placement
// needs one. Two sources, in this order: the row the file already keeps for
// that mesh — the donor's, or the one the scatter's binding chose — and failing
// that a row synthesized from the venue's own library, quoting the box that
// library declares. Nothing invents an asset: a venue can only place what its
// base art ships, which is what the browser lists.
//
// A placement gets collision when the venue has an entity type for its mesh,
// and is scenery otherwise. finland_rally covers 51 of its 70 meshes.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import d3 "../d3"
import "../gfx"

// The 3x3 a placement file stores, from a rotation and a uniform scale.
//
// The file applies its matrix as `local * M` — stock rows read as the images of
// the basis vectors under that — so what it stores is the transpose of the
// rotation the viewport draws with. Scale is uniform and rides in the same nine
// numbers.
d3_prop_basis :: proc(rot: gfx.Quaternion, scale: f32) -> [3][3]f32 {
	m := gfx.QuaternionToMatrix(rot)
	out: [3][3]f32
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			out[row][col] = m[col, row] * scale
		}
	}
	return out
}

// The reference rows and instances of both placement files, hand-placed props
// only. The libraries open only for a mesh no donor row covers, and close
// before this returns — nothing returned borrows their memory.
d3_place_resolve :: proc(
	placed: []Prop_Instance,
	donor_rows: [Prop_Lib_Kind][]d3.D3_Placement_Reference,
	base_dir: string,
) -> (
	rows: [Prop_Lib_Kind][]d3.D3_Placement_Reference,
	placements: [Prop_Lib_Kind][]d3.D3_Placement_Instance,
	msg: string,
	ok: bool,
) {
	libs, lib_msg, lib_ok := d3_place_libraries(placed, donor_rows, base_dir)
	defer for &entry in libs {
		if entry.open {
			d3.Prop_Lib_Delete(&entry.lib)
		}
	}
	if !lib_ok {
		return rows, placements, lib_msg, false
	}
	for kind in Prop_Lib_Kind {
		lib := libs[kind].open ? &libs[kind].lib : nil
		kind_rows, row_of, place_msg, place_ok := d3_place_references(placed, kind, donor_rows[kind], lib)
		if !place_ok {
			return rows, placements, place_msg, false
		}
		rows[kind] = kind_rows
		placements[kind] = d3_place_instances(placed, kind, row_of)
	}
	return rows, placements, "", true
}

// The reference rows and the row each placed mesh lands on.
//
// `rows` starts as whatever the file is already keeping — the scatter's chosen
// species for trees, the donor's whole table for ornaments — and grows by one
// row per mesh neither of those covers. Ids stay dense and ascending, which
// the writer validates.
d3_place_references :: proc(
	placed: []Prop_Instance,
	kind: Prop_Lib_Kind,
	rows: []d3.D3_Placement_Reference,
	lib: ^d3.Prop_Library,
	allocator := context.temp_allocator,
) -> (
	out: []d3.D3_Placement_Reference,
	row_of: map[string]int,
	msg: string,
	ok: bool,
) {
	grown := make([dynamic]d3.D3_Placement_Reference, 0, len(rows) + len(placed), allocator)
	append(&grown, ..rows)
	row_of = make(map[string]int, allocator)
	for row, i in grown {
		row_of[row.filename] = i
	}
	for inst in placed {
		if inst.ref.kind != kind {
			continue
		}
		if _, seen := row_of[inst.ref.name]; seen {
			continue
		}
		if lib == nil {
			return nil, nil, fmt.tprintf("the base venue's library is needed to place %s", inst.ref.name), false
		}
		lo, hi, bounds_ok := d3.Prop_Lib_Bounds(lib, inst.ref.name)
		if !bounds_ok {
			return nil, nil, fmt.tprintf("the base venue's art has no prop named %s", inst.ref.name), false
		}
		row_of[inst.ref.name] = len(grown)
		append(&grown, d3.D3_Placement_Reference{
			reference_id = u32(len(grown)),
			filename     = inst.ref.name,
			bounds_min   = lo,
			bounds_max   = hi,
		})
	}
	return grown[:], row_of, "", true
}

// The placements of one kind as instances, ids dense from zero in the order
// they are written — which is what `track.vis` addresses a drawable by.
d3_place_instances :: proc(
	placed: []Prop_Instance,
	kind: Prop_Lib_Kind,
	row_of: map[string]int,
	allocator := context.temp_allocator,
) -> []d3.D3_Placement_Instance {
	out := make([dynamic]d3.D3_Placement_Instance, 0, len(placed), allocator)
	for inst in placed {
		if inst.ref.kind != kind {
			continue
		}
		row, found := row_of[inst.ref.name]
		if !found {
			continue
		}
		append(&out, d3_placement_instance(
			row, len(out),
			d3_prop_basis(inst.rot, inst.scale),
			{inst.pos.x, inst.pos.y, inst.pos.z},
		))
	}
	return out[:]
}

// Raise every row's registration capacity over what is actually placed against
// it. Only ornaments honour capacity — trees are written at their exact cooked
// count — and a row whose capacity is under its own instance count is refused
// by the writer. No stock reference is an exact fit: across 10381 of them the
// slack runs from 1 to 2092.
d3_place_capacities :: proc(
	rows: []d3.D3_Placement_Reference, instances: []d3.D3_Placement_Instance,
) {
	for &row in rows {
		placed: u32
		for inst in instances {
			if inst.reference_id == row.reference_id {
				placed += 1
			}
		}
		row.instance_capacity = max(row.instance_capacity, placed + 1)
	}
}

// The rigid body of every placed prop the donor route gives one. Mirrors the
// scatter's records; a prop with no body is placed as scenery and the car
// drives through it.
//
// Driven off the instances rather than the placements, so a body and its
// drawable cannot describe different transforms.
// `declared` is the whole file's set of entity references, so one mesh is
// declared once however many records name it. `prefix` keeps record ids apart
// between the files this is called for.
d3_place_ens_nodes :: proc(
	instances: []d3.D3_Placement_Instance,
	rows: []d3.D3_Placement_Reference,
	bodies: map[string]string,
	declared: ^map[string]bool,
	prefix: string,
	allocator := context.temp_allocator,
) -> (nodes: []d3.Ens_Node, bodied: int) {
	out := make([dynamic]d3.Ens_Node, 0, len(instances) * 2, allocator)
	for inst, i in instances {
		mesh := rows[inst.reference_id].filename
		entity, has_body := bodies[mesh]
		if !has_body {
			continue
		}
		if !(declared^)[entity] {
			declared[entity] = true
			append(&out, d3_ens_reference_node(entity, mesh, allocator))
		}
		id := fmt.aprintf("%s_%d", prefix, i, allocator = allocator)
		append(&out, d3_ens_body_node(id, entity, inst, allocator))
		bodied += 1
	}
	return out[:], bodied
}

// Entity types the venue declares that the donor route never placed, added to
// the donor's own map. `objecttypes.pssg` is the physics layer and is not PSSG
// at all: it is the same CSSGXml text as `objects.ens`, so the same parser
// reads it, and its ids are `<mesh>.max`.
//
// Best effort. A venue whose file will not parse keeps the donor's bodies and
// the props it did not cover are placed as scenery.
d3_place_venue_bodies :: proc(base_dir: string, bodies: ^map[string]string) -> (added: int) {
	if base_dir == "" {
		return
	}
	path, _ := filepath.join({base_dir, "objecttypes.pssg"}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	nodes, parsed := d3.Ens_Parse(data, context.temp_allocator)
	if !parsed {
		return
	}
	for node in nodes {
		if node.tag != "TEMPLATEENTITY" {
			continue
		}
		id, has_id := d3.Ens_Attr_Value(node, "id")
		if !has_id {
			continue
		}
		mesh := strings.trim_suffix(id, ".max")
		if mesh == id {
			continue
		}
		if _, known := bodies[mesh]; known {
			continue
		}
		bodies[mesh] = mesh
		added += 1
	}
	return
}

D3_Place_Library :: struct {
	lib:  d3.Prop_Library,
	open: bool,
}

// The base venue's prop libraries, opened only when a placement needs a row no
// donor table has. Two files of up to 30 MB, so an export that places nothing
// new never touches them.
d3_place_libraries :: proc(
	placed: []Prop_Instance, rows: [Prop_Lib_Kind][]d3.D3_Placement_Reference, base_dir: string,
) -> (libs: [Prop_Lib_Kind]D3_Place_Library, msg: string, ok: bool) {
	for inst in placed {
		if libs[inst.ref.kind].open {
			continue
		}
		known := false
		for row in rows[inst.ref.kind] {
			if row.filename == inst.ref.name {
				known = true
				break
			}
		}
		if known {
			continue
		}
		if base_dir == "" {
			return libs, "placing a prop needs the base venue directory its art lives in", false
		}
		path, _ := filepath.join({base_dir, PROP_LIB_FILES[inst.ref.kind]}, context.temp_allocator)
		lib, lib_msg, lib_ok := d3.Prop_Lib_Open(path)
		if !lib_ok {
			return libs, fmt.tprintf("%s: %s", PROP_LIB_FILES[inst.ref.kind], lib_msg), false
		}
		libs[inst.ref.kind] = {lib = lib, open = true}
	}
	return libs, "", true
}
