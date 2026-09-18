package main

// The Dirt 3 target's placement files: `trees.bin`, `ornaments.bin`, their XML
// siblings and `objects.ens`.
//
// Two sources feed them and one pipeline carries both. The vegetation scatter
// is bound to the base venue's own tree meshes by the table below, then handed
// on as placements exactly like the props placed by hand (export_dirt3_props.odin).
// Nothing here invents an asset: meshes, bounds and rigid bodies all come from
// the base venue's own art, read into our structs and written back out from
// them, never patched in place.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import d3 "../d3"
import "../geo"
import "../gfx"

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

// Which row a scatter kind is placed on. One row per mesh: no stock placement
// file repeats a filename in its reference table, over all 218 read.
D3_Prop_Binding :: struct {
	kind: geo.Prop_Kind,
	mesh: int,
}

// A mesh's rigid body in `objecttypes.pssg`: the entity id is the mesh name and
// the uri appends `.max`, on every stock route read.
d3_prop_entity_uri :: proc(mesh: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"objecttypes.pssg#", mesh, ".max"}, allocator)
}

// The two node shapes a rigid body takes in `objects.ens`: one entity
// reference per mesh, one instance per body.
d3_ens_reference_node :: proc(entity, mesh: string, allocator := context.temp_allocator) -> d3.Ens_Node {
	attrs := make([]d3.Ens_Attr, 3, allocator)
	attrs[0] = {name = "id", value = entity}
	attrs[1] = {name = "uri", value = d3_prop_entity_uri(mesh, allocator)}
	attrs[2] = {name = "allocAlt", value = "5"}
	return {tag = "TEMPLATEENTITYREFERENCE", attrs = attrs, content = .Self_Close}
}

d3_ens_body_node :: proc(id, entity: string, instance: d3.D3_Placement_Instance, allocator := context.temp_allocator) -> d3.Ens_Node {
	attrs := make([]d3.Ens_Attr, 3, allocator)
	attrs[0] = {name = "id", value = id}
	attrs[1] = {name = "uri", value = fmt.aprintf("#%s", entity, allocator = allocator)}
	attrs[2] = {name = "instance_tag", value = fmt.aprintf("%d", instance.instance_tag, allocator = allocator)}
	children := make([]d3.Ens_Node, 1, allocator)
	children[0] = d3.Ens_Placement_Transform(instance, allocator)
	return {tag = "TEMPLATEBASICENTITYINSTANCE", attrs = attrs, content = .Children, children = children}
}

// `instance_tag` runs one ahead of `instance_id`, which is the id `track.vis`
// addresses the drawable by.
d3_placement_instance :: proc(row, id: int, basis: [3][3]f32, pos: [3]f32) -> d3.D3_Placement_Instance {
	return {
		reference_id = u32(row),
		instance_id  = u32(id),
		instance_tag = u32(id + 1),
		basis        = basis,
		position     = pos,
	}
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
	meshes: []d3.D3_Placement_Reference,
	bindings: []D3_Prop_Binding,
	msg: string,
	ok: bool,
) {
	wanted: [geo.Prop_Kind]bool
	for prop in props {
		wanted[prop.kind] = true
	}

	rows := make([dynamic]d3.D3_Placement_Reference, allocator)
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
			append(&rows, reference)
		}
		append(&bound, D3_Prop_Binding{kind = kind, mesh = row})
	}
	if len(bound) == 0 {
		return nil, nil, "no vegetation to place", false
	}
	return rows[:], bound[:], "", true
}

// --- emission ----------------------------------------------------------------

// The scatter as placements, so one pipeline writes both it and the props
// placed by hand. Binding order groups the output by species, which is the
// order the file has always been written in; stock files interleave, so the
// grouping is a convenience rather than a rule.
d3_scatter_placements :: proc(
	props: []geo.Veg_Instance,
	meshes: []d3.D3_Placement_Reference,
	bindings: []D3_Prop_Binding,
	allocator := context.temp_allocator,
) -> []Prop_Instance {
	out := make([dynamic]Prop_Instance, 0, len(props), allocator)
	for binding in bindings {
		for prop in props {
			if prop.kind != binding.kind {
				continue
			}
			append(&out, Prop_Instance{
				ref   = {kind = .Trees, name = meshes[binding.mesh].filename},
				pos   = prop.pos,
				rot   = gfx.QuaternionFromAxisAngle({0, 1, 0}, prop.yaw),
				scale = prop.scale,
			})
		}
	}
	return out[:]
}

// The scatter resolved against the donor's art: the tree rows it needs, and
// itself as placements on them. With no scatter the donor's rows are kept as
// they are — its own trees stand along the old road, so the file is still
// rewritten empty of their instances.
@(private = "file")
d3_prop_resolve :: proc(
	props: []geo.Veg_Instance,
	references: []d3.D3_Placement_Reference,
	bodies: map[string]string,
) -> (
	rows: []d3.D3_Placement_Reference,
	scatter: []Prop_Instance,
	msg: string,
	ok: bool,
) {
	if len(props) == 0 {
		return references, nil, "", true
	}
	meshes, bindings, bind_msg, bind_ok := d3_prop_bindings(props, references, bodies)
	if !bind_ok {
		return nil, nil, bind_msg, false
	}
	return meshes, d3_scatter_placements(props, meshes, bindings), "", true
}

@(private = "file")
D3_Placement_Out :: struct {
	name: string,
	data: []u8,
}

// `trees.bin`/`trees.xml`, `ornaments.bin`/`ornaments.xml`, and a rigid body in
// `objects.ens` for every one of ours that has one.
//
// Both placement files are written from our own structs rather than patched:
// the scatter and the hand-placed props (props.odin) share each file with the
// reference rows the donor route already had. The donor's own instances are
// dropped either way — they stand where the old route ran.
//
// Runs before the route files, because `track.vis` censuses both files for its
// tag-2 and tag-3 objects and must see what this stage actually has.
d3_write_placements :: proc(
	out: ^d3.Export_Job,
	route_dir: string,
	props: []geo.Veg_Instance,
	placed: []Prop_Instance,
) -> (msg: string, ok: bool) {
	tree_refs, ornament_refs, bodies, art_msg, art_ok := d3_donor_art(route_dir)
	if !art_ok {
		return art_msg, false
	}
	// The libraries and the physics file sit at the venue base, one level above
	// the route we take the rest of this art from.
	base_dir := filepath.dir(route_dir)
	venue_bodies := d3_place_venue_bodies(base_dir, &bodies)
	tree_rows, scatter, resolve_msg, resolved := d3_prop_resolve(props, tree_refs, bodies)
	if !resolved {
		return resolve_msg, false
	}
	species := len(scatter) > 0 ? len(tree_rows) : 0

	// One list from here down. The scatter goes first, so its instance ids are
	// the low ones and a hand-placed tree numbers on from the last of them.
	all := make([dynamic]Prop_Instance, 0, len(scatter)+len(placed), context.temp_allocator)
	append(&all, ..scatter)
	append(&all, ..placed)
	donor_rows: [Prop_Lib_Kind][]d3.D3_Placement_Reference
	donor_rows[.Trees], donor_rows[.Objects] = tree_rows, ornament_refs
	rows, placements, place_msg, placed_ok := d3_place_resolve(all[:], donor_rows, base_dir)
	if !placed_ok {
		return place_msg, false
	}
	// Only ornaments honour capacity; trees are written at their exact count.
	d3_place_capacities(rows[.Objects], placements[.Objects])

	written := make([dynamic]D3_Placement_Out, context.temp_allocator)
	for file in ([]struct{name: string, format: d3.D3_Placement_Format, refs: []d3.D3_Placement_Reference, insts: []d3.D3_Placement_Instance}{
		{"trees.bin", .Trees, rows[.Trees], placements[.Trees]},
		{"ornaments.bin", .Ornaments, rows[.Objects], placements[.Objects]},
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

	nodes, bodied := d3_placement_ens(rows, placements, bodies)
	if len(nodes) > 0 {
		append(&written, D3_Placement_Out{"objects.ens", d3.Ens_Emit(nodes, context.temp_allocator)})
	}

	for file in written {
		if write_msg, wrote := d3.Write_Out(out, file.name, file.data); !wrote {
			return write_msg, false
		}
	}
	return fmt.tprintf(
		"%d species, %d scattered trees; %d placed props (%d ornaments); objects.ens: %d records, %d of %d placements given a body (%d entity types off the venue)",
		species, len(scatter), len(placed),
		len(placements[.Objects]), len(nodes), bodied, len(all), venue_bodies,
	), true
}

// The donor route's placement art: both reference tables and its rigid-body map.
@(private = "file")
d3_donor_art :: proc(route_dir: string) -> (
	tree_refs, ornament_refs: []d3.D3_Placement_Reference,
	bodies: map[string]string,
	msg: string,
	ok: bool,
) {
	donor_trees, trees_ok := d3_stock_file(route_dir, "trees.bin")
	donor_ornaments, ornaments_ok := d3_stock_file(route_dir, "ornaments.bin")
	donor_ens, ens_ok := d3_stock_file(route_dir, "objects.ens")
	if !(trees_ok && ornaments_ok && ens_ok) {
		return nil, nil, nil, "the base route has no trees.bin, ornaments.bin and objects.ens to take its art from", false
	}
	ref_msg: string
	tree_refs, ref_msg, trees_ok = d3.Placement_References(donor_trees, context.temp_allocator)
	if !trees_ok {
		return nil, nil, nil, fmt.tprintf("trees.bin: %s", ref_msg), false
	}
	ornament_refs, ref_msg, ornaments_ok = d3.Placement_References(donor_ornaments, context.temp_allocator)
	if !ornaments_ok {
		return nil, nil, nil, fmt.tprintf("ornaments.bin: %s", ref_msg), false
	}
	bodies, ens_ok = d3_prop_bodies(donor_ens)
	if !ens_ok {
		return nil, nil, nil, "the base route's objects.ens did not parse", false
	}
	return tree_refs, ornament_refs, bodies, "", true
}

// Record ids are per file, so the two cannot collide inside one objects.ens.
@(private = "file")
D3_ENS_PREFIX := [Prop_Lib_Kind]string {
	.Objects = "dirtbench_orn",
	.Trees   = "dirtbench_tree",
}

// Every rigid body this stage places, both files sharing one set of entity
// declarations. The donor's own records are dropped: they are the base venue's
// hay bales, fences and power lines standing along the old road, and keeping
// them leaves collision with nothing drawn on it. `frontend_track/route_0`
// ships 139 bytes with no records at all, so the empty form is stock.
@(private = "file")
d3_placement_ens :: proc(
	rows: [Prop_Lib_Kind][]d3.D3_Placement_Reference,
	placements: [Prop_Lib_Kind][]d3.D3_Placement_Instance,
	bodies: map[string]string,
) -> (nodes: []d3.Ens_Node, bodied: int) {
	out := make([dynamic]d3.Ens_Node, context.temp_allocator)
	declared := make(map[string]bool, context.temp_allocator)
	for kind in Prop_Lib_Kind {
		kind_nodes, kind_bodied := d3_place_ens_nodes(
			placements[kind], rows[kind], bodies, &declared, D3_ENS_PREFIX[kind],
		)
		append(&out, ..kind_nodes)
		bodied += kind_bodied
	}
	return out[:], bodied
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
