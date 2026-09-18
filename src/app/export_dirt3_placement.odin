package main

// The Dirt 3 target's prop table: which of a base venue's own tree meshes each
// scatter kind is placed as. Nothing here invents an asset: meshes, bounds and
// rigid bodies come from the base venue's own `trees.bin` and `objects.ens`,
// so a derived venue scatters its biome's species without shipping anything.
// Read into our own structs and written back out from them, never patched in
// place.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import d3 "../d3"
import "../geo"

// Candidate meshes per scatter kind, most wanted first. Patterns, not names:
// the art follows one naming convention across venues, so a venue missing the
// first choice falls through to the next rather than losing the kind.
// Measured over all nine base-eligible venues: every kind each preset emits
// resolves to a collidable mesh, with no fallthrough past the last pattern.
D3_PROP_SPECIES := [geo.Prop_Kind][]string {
	.Conifer_Tall          = {"dougfir_tall", "fir_snow_0", "tree_whispy"},
	.Conifer_Medium        = {"dougfir_full", "dougfir_tall", "fir_snow_0"},
	.Conifer_Snow_Tall     = {"fir_snow", "dougfir_tall"},
	.Conifer_Snow_Medium   = {"fir_snow", "dougfir_full"},
	.Broadleaf_Big         = {"maple_large", "tree_a_", "birch_full", "tree_medium_01_a"},
	.Broadleaf_Tall        = {"birch_full", "aspen_forrest", "tree_medium"},
	.Broadleaf_Medium      = {"maple_full", "tree_medium", "tree_rockbank", "birch_full"},
	.Broadleaf_Bare_Medium = {"bare_tree", "kenya_tree_dead", "tree_pollarded", "tree_medium"},
	.Broadleaf_Bare_Small  = {"bare_tree", "tree_pollarded", "tree_rockbank", "tree_medium"},
	.Acacia_Big            = {"tree_a_", "tree_whispy", "tree_g_"},
	.Acacia_Medium         = {"tree_c_", "tree_d_", "tree_g_", "tree_a_"},
	.Thorn_Bush            = {"kenya_bush", "bush_medium", "bush_0", "maple_bush"},
}

// One mesh of the base venue's art, as a row of the file we write.
// `reference` is the donor's row renumbered, because reference ids must be
// dense and ascending. `entity_id` is the objects.ens reference its rigid
// bodies point at; instances reuse the donor's id rather than adding a second
// one for the same mesh.
//
// One row per mesh: no stock placement file repeats a filename in its
// reference table, over all 218 read.
D3_Prop_Mesh :: struct {
	reference: d3.D3_Placement_Reference,
	entity_id: string,
}

// Which mesh a scatter kind is placed as, by index into the mesh list.
D3_Prop_Binding :: struct {
	kind: geo.Prop_Kind,
	mesh: int,
}

// A mesh's rigid body in `objecttypes.pssg`: the entity id is the mesh name and
// the uri appends `.max`, on every stock route read.
d3_prop_entity_uri :: proc(mesh: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"objecttypes.pssg#", mesh, ".max"}, allocator)
}

// Which meshes this venue gives a rigid body: mesh name -> the `objects.ens`
// id to point an instance at. An `!n` suffix on the id is an authoring
// duplicate of the same mesh, so key and value can differ.
// Per venue, not global: `dougfir_tall_02_a` has a body in `finland_rally` and
// none in `michigan_trail`, so a species this file does not name is not a
// candidate.
d3_prop_bodies :: proc(ens: []u8, allocator := context.temp_allocator) -> (bodies: map[string]string, ok: bool) {
	nodes, parsed := d3.Ens_Parse(ens, context.temp_allocator)
	if !parsed {
		return nil, false
	}
	out := make(map[string]string, allocator)
	for node in nodes {
		if node.tag != "TEMPLATEENTITYREFERENCE" {
			continue
		}
		for attr in node.attrs {
			if attr.name != "id" {
				continue
			}
			name := attr.value
			if bang := strings.index_byte(name, '!'); bang >= 0 {
				name = name[:bang]
			}
			if _, seen := out[name]; !seen {
				out[name] = attr.value
			}
		}
	}
	return out, true
}

// The first reference whose mesh this venue gives a body, by pattern
// priority. `exclude` skips already-claimed meshes; nil excludes nothing.
@(private = "file")
d3_prop_pick :: proc(
	references: []d3.D3_Placement_Reference,
	bodies: map[string]string,
	patterns: []string,
	exclude: map[string]bool,
) -> int {
	for pattern in patterns {
		for reference, i in references {
			if reference.filename in bodies &&
			   !exclude[reference.filename] &&
			   strings.has_prefix(reference.filename, pattern) {
				return i
			}
		}
	}
	return -1
}

// Bind every kind the scatter produced to one of the venue's meshes. Only
// collidable meshes are candidates, so every tree we place stops the car —
// the venue's billboard and distant species carry no rigid body, and stock
// does not collide with them either.
// A kind prefers an unclaimed mesh, so sibling kinds land on different
// species; it reuses a claimed one rather than dropping the kind.
d3_prop_bindings :: proc(
	props: []geo.Veg_Instance,
	references: []d3.D3_Placement_Reference,
	bodies: map[string]string,
	allocator := context.temp_allocator,
) -> (
	meshes: []D3_Prop_Mesh,
	bindings: []D3_Prop_Binding,
	msg: string,
	ok: bool,
) {
	wanted: [geo.Prop_Kind]bool
	for prop in props {
		wanted[prop.kind] = true
	}

	rows := make([dynamic]D3_Prop_Mesh, allocator)
	bound := make([dynamic]D3_Prop_Binding, allocator)
	row_of := make(map[string]int, context.temp_allocator)
	claimed := make(map[string]bool, context.temp_allocator)
	for kind in geo.Prop_Kind {
		if !wanted[kind] {
			continue
		}
		chosen := d3_prop_pick(references, bodies, D3_PROP_SPECIES[kind], claimed)
		if chosen < 0 {
			chosen = d3_prop_pick(references, bodies, D3_PROP_SPECIES[kind], nil)
		}
		if chosen < 0 {
			return nil, nil, "this venue's art has no collidable mesh for one of the stage's species", false
		}
		reference := references[chosen]
		claimed[reference.filename] = true
		row, seen := row_of[reference.filename]
		if !seen {
			row = len(rows)
			row_of[reference.filename] = row
			reference.reference_id = u32(row)
			append(&rows, D3_Prop_Mesh{reference = reference, entity_id = bodies[reference.filename]})
		}
		append(&bound, D3_Prop_Binding{kind = kind, mesh = row})
	}
	if len(bound) == 0 {
		return nil, nil, "no vegetation to place", false
	}
	return rows[:], bound[:], "", true
}

// --- emission ----------------------------------------------------------------

// The scatter as placement instances, one reference at a time — order is
// free, most stock files interleave. Yaw and scale ride in the basis, which
// is where a placement file carries both; `instance_id` is the id `track.vis`
// tag 3 addresses this tree by.
d3_prop_instances :: proc(
	props: []geo.Veg_Instance,
	bindings: []D3_Prop_Binding,
	allocator := context.temp_allocator,
) -> []d3.D3_Placement_Instance {
	out := make([dynamic]d3.D3_Placement_Instance, 0, len(props), allocator)
	for binding in bindings {
		for prop in props {
			if prop.kind != binding.kind {
				continue
			}
			sin, cos := math.sin(prop.yaw)*prop.scale, math.cos(prop.yaw)*prop.scale
			append(&out, d3.D3_Placement_Instance{
				reference_id = u32(binding.mesh),
				instance_id  = u32(len(out)),
				instance_tag = u32(len(out)+1),
				basis        = {{cos, 0, -sin}, {0, prop.scale, 0}, {sin, 0, cos}},
				position     = {prop.pos.x, prop.pos.y, prop.pos.z},
			})
		}
	}
	return out[:]
}

// Every tree's rigid body, and nothing else.
//
// The donor's own records are dropped. They are the base venue's hay bales,
// fences and power lines standing along the old road, and keeping them leaves
// invisible collision once `ornaments.bin` is emptied.
// `frontend_track/route_0` ships 139 bytes with no references and no
// instances, so the empty form is stock.
//
// Built from the same instance slice `trees.bin` is written from, so physics
// and render cannot drift.
d3_prop_ens_nodes :: proc(
	meshes: []D3_Prop_Mesh,
	instances: []d3.D3_Placement_Instance,
	allocator := context.temp_allocator,
) -> (
	nodes: []d3.Ens_Node,
	msg: string,
	ok: bool,
) {
	out := make([dynamic]d3.Ens_Node, 0, len(meshes)+len(instances), allocator)
	for mesh in meshes {
		attrs := make([]d3.Ens_Attr, 3, allocator)
		attrs[0] = {name = "id", value = mesh.entity_id}
		attrs[1] = {name = "uri", value = d3_prop_entity_uri(mesh.reference.filename, allocator)}
		attrs[2] = {name = "allocAlt", value = "5"}
		append(&out, d3.Ens_Node{tag = "TEMPLATEENTITYREFERENCE", attrs = attrs, content = .Self_Close})
	}
	for instance, i in instances {
		if int(instance.reference_id) >= len(meshes) {
			return nil, "a placement names a mesh no binding covers", false
		}
		attrs := make([]d3.Ens_Attr, 3, allocator)
		attrs[0] = {name = "id", value = fmt.aprintf("dirtbench_veg_%d", i, allocator = allocator)}
		attrs[1] = {name = "uri", value = fmt.aprintf("#%s", meshes[instance.reference_id].entity_id, allocator = allocator)}
		attrs[2] = {name = "instance_tag", value = fmt.aprintf("%d", instance.instance_tag, allocator = allocator)}
		children := make([]d3.Ens_Node, 1, allocator)
		children[0] = d3.Ens_Placement_Transform(instance, allocator)
		append(&out, d3.Ens_Node{
			tag      = "TEMPLATEBASICENTITYINSTANCE",
			attrs    = attrs,
			content  = .Children,
			children = children,
		})
	}
	return out[:], fmt.tprintf("%d meshes, %d bodies, no donor records", len(meshes), len(instances)), true
}

// Resolve the scatter against the donor's art: the reference rows to write
// and the instances to place. With no props the donor's rows are kept as they
// are and nothing is placed — the donor's own trees stand along the old road,
// so the file is still rewritten empty of instances.
@(private = "file")
d3_prop_resolve :: proc(
	props: []geo.Veg_Instance,
	references: []d3.D3_Placement_Reference,
	donor_ens: []u8,
) -> (
	chosen: []d3.D3_Placement_Reference,
	meshes: []D3_Prop_Mesh,
	instances: []d3.D3_Placement_Instance,
	msg: string,
	ok: bool,
) {
	if len(props) == 0 {
		return references, nil, nil, "", true
	}
	bodies, bodies_ok := d3_prop_bodies(donor_ens)
	if !bodies_ok {
		return nil, nil, nil, "the base route's objects.ens did not parse", false
	}
	rows, bindings, bind_msg, bind_ok := d3_prop_bindings(props, references, bodies)
	if !bind_ok {
		return nil, nil, nil, bind_msg, false
	}
	meshes = rows
	picked := make([]d3.D3_Placement_Reference, len(meshes), context.temp_allocator)
	for mesh, i in meshes {
		picked[i] = mesh.reference
	}
	return picked, meshes, d3_prop_instances(props, bindings), "", true
}

@(private = "file")
D3_Placement_Out :: struct {
	name: string,
	data: []u8,
}

// `trees.bin`/`trees.xml`, an emptied `ornaments.bin`/`ornaments.xml`, and the
// rigid body of every tree appended to `objects.ens`. The ornament pair is
// rewritten because the donor's props stand where the old route ran; emptied
// is the honest form until the editor can place them.
// Runs before the route files, because `track.vis` censuses `trees.bin` for
// its tag-3 objects and must see the trees this stage actually has.
d3_write_placements :: proc(out: ^d3.Export_Job, route_dir: string, props: []geo.Veg_Instance) -> (msg: string, ok: bool) {
	donor_trees, trees_ok := d3_stock_file(route_dir, "trees.bin")
	donor_ornaments, ornaments_ok := d3_stock_file(route_dir, "ornaments.bin")
	donor_ens, ens_ok := d3_stock_file(route_dir, "objects.ens")
	if !(trees_ok && ornaments_ok && ens_ok) {
		return "the base route has no trees.bin, ornaments.bin and objects.ens to take its art from", false
	}

	references, ref_msg, ref_ok := d3.Placement_References(donor_trees, context.temp_allocator)
	if !ref_ok {
		return fmt.tprintf("trees.bin: %s", ref_msg), false
	}
	ornament_refs, ornament_msg, ornament_ok := d3.Placement_References(donor_ornaments, context.temp_allocator)
	if !ornament_ok {
		return fmt.tprintf("ornaments.bin: %s", ornament_msg), false
	}
	chosen, meshes, instances, resolve_msg, resolved := d3_prop_resolve(props, references, donor_ens)
	if !resolved {
		return resolve_msg, false
	}

	written := make([dynamic]D3_Placement_Out, context.temp_allocator)
	for file in ([]struct{name: string, format: d3.D3_Placement_Format, refs: []d3.D3_Placement_Reference, insts: []d3.D3_Placement_Instance}{
		{"trees.bin", .Trees, chosen, instances},
		{"ornaments.bin", .Ornaments, ornament_refs, nil},
	}) {
		data, build_msg, built := d3.Placement_Build(file.format, file.refs, file.insts, context.temp_allocator)
		if !built {
			return fmt.tprintf("%s: %s", file.name, build_msg), false
		}
		append(&written, D3_Placement_Out{file.name, data})
		xml, xml_msg, xml_built := d3.Placement_Xml_Build(file.format, file.refs, file.insts, context.temp_allocator)
		if !xml_built {
			return fmt.tprintf("%s: %s", file.name, xml_msg), false
		}
		name := strings.concatenate({strings.trim_suffix(file.name, ".bin"), ".xml"}, context.temp_allocator)
		append(&written, D3_Placement_Out{name, xml})
	}

	ens_msg := "unchanged, no trees to give a body"
	if len(instances) > 0 {
		nodes, nodes_msg, nodes_ok := d3_prop_ens_nodes(meshes, instances)
		if !nodes_ok {
			return nodes_msg, false
		}
		ens_msg = nodes_msg
		append(&written, D3_Placement_Out{"objects.ens", d3.Ens_Emit(nodes, context.temp_allocator)})
	}

	for file in written {
		if write_msg, wrote := d3.Write_Out(out, file.name, file.data); !wrote {
			return write_msg, false
		}
	}
	return fmt.tprintf(
		"%d species, %d trees; ornaments emptied; objects.ens: %s",
		len(meshes), len(instances), ens_msg,
	), true
}

@(private = "file")
d3_stock_file :: proc(dir, name: string) -> ([]u8, bool) {
	path := d3.Stock_Path(dir, name)
	if path == "" {
		return nil, false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}
