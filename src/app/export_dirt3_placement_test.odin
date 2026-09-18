package main

import "core:math"
import "core:testing"
import d3 "../d3"
import "../geo"
import "../gfx"

@(private = "file")
test_reference :: proc(id: u32, mesh: string) -> d3.D3_Placement_Reference {
	return {reference_id = id, filename = mesh, bounds_min = {-3, 0, -3}, bounds_max = {3, 18, 3}}
}

@(private = "file")
test_bodies :: proc(names: ..string) -> map[string]string {
	out := make(map[string]string, context.temp_allocator)
	for name in names {
		out[name] = name
	}
	return out
}

// Through the real codec rather than hand-typed text: objects.ens carries a
// fixed header and footer that d3_ens_parse checks for.
@(private = "file")
test_ens :: proc(ids: ..string) -> []u8 {
	nodes := make([]d3.Ens_Node, len(ids), context.temp_allocator)
	for id, i in ids {
		attrs := make([]d3.Ens_Attr, 2, context.temp_allocator)
		attrs[0] = {name = "id", value = id}
		attrs[1] = {name = "uri", value = "objecttypes.pssg#x.max"}
		nodes[i] = {tag = "TEMPLATEENTITYREFERENCE", attrs = attrs, content = .Self_Close}
	}
	return d3.Ens_Emit(nodes, context.temp_allocator)
}

@(private = "file")
test_props :: proc(kinds: ..geo.Prop_Kind) -> []geo.Veg_Instance {
	out := make([]geo.Veg_Instance, len(kinds), context.temp_allocator)
	for kind, i in kinds {
		out[i] = {kind = kind}
	}
	return out
}

// An `!n` suffix is an authoring duplicate of one mesh, so the body belongs to
// the bare name.
@(test)
prop_bodies_strips_the_authoring_suffix :: proc(t: ^testing.T) {
	bodies, ok := d3_prop_bodies(test_ens(
		"rural_house_yellow_a!0",
		"birch_full_01_a",
	))
	testing.expect(t, ok); if !ok { return }
	testing.expect_value(t, bodies["rural_house_yellow_a"], "rural_house_yellow_a!0")
	testing.expect_value(t, bodies["birch_full_01_a"], "birch_full_01_a")
	testing.expect(t, "rural_house_yellow_a!0" not_in bodies)
}

// The whole reason there is no committed mesh table: the same name carries a
// rigid body in finland_rally and none in michigan_trail, so only the venue's
// own objects.ens can answer, and a species it omits must not be placed.
@(test)
prop_bindings_only_use_meshes_this_venue_gives_a_body :: proc(t: ^testing.T) {
	references := []d3.D3_Placement_Reference{
		test_reference(0, "dougfir_tall_02_a"),
		test_reference(1, "dougfir_tall_01_a"),
	}
	meshes, bindings, msg, ok := d3_prop_bindings(
		test_props(.Conifer_Tall),
		references,
		test_bodies("dougfir_tall_01_a"), // _02_a is visual-only here
	)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(bindings), 1)
	testing.expect_value(t, meshes[bindings[0].mesh].filename, "dougfir_tall_01_a")
}

// Reference ids must be dense and ascending, whatever row the donor held them
// at, or d3_placement_build refuses the file.
@(test)
prop_bindings_renumber_references_from_zero :: proc(t: ^testing.T) {
	references := []d3.D3_Placement_Reference{
		test_reference(7, "bush_medium_01_a"),
		test_reference(9, "fir_snow_03_a"),
		test_reference(4, "fir_snow_01_a"),
	}
	meshes, bindings, msg, ok := d3_prop_bindings(
		test_props(.Conifer_Snow_Tall, .Conifer_Snow_Medium, .Thorn_Bush),
		references,
		test_bodies("bush_medium_01_a", "fir_snow_03_a", "fir_snow_01_a"),
	)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(bindings), 3)
	for mesh, i in meshes {
		testing.expect_value(t, mesh.reference_id, u32(i))
	}
}

// Sibling kinds must not collapse onto one mesh when the venue ships two of a
// family, or a stage's tall and medium firs are the same tree.
@(test)
prop_bindings_prefer_an_unclaimed_mesh :: proc(t: ^testing.T) {
	references := []d3.D3_Placement_Reference{
		test_reference(0, "fir_snow_01_a"),
		test_reference(1, "fir_snow_02_a"),
	}
	meshes, bindings, msg, ok := d3_prop_bindings(
		test_props(.Conifer_Snow_Tall, .Conifer_Snow_Medium),
		references,
		test_bodies("fir_snow_01_a", "fir_snow_02_a"),
	)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(bindings), 2)
	testing.expect(t, meshes[bindings[0].mesh].filename != meshes[bindings[1].mesh].filename)
}

// One mesh of a family is not a reason to drop a kind.
@(test)
prop_bindings_reuse_a_mesh_rather_than_drop_a_kind :: proc(t: ^testing.T) {
	references := []d3.D3_Placement_Reference{test_reference(0, "fir_snow_01_a")}
	meshes, bindings, msg, ok := d3_prop_bindings(
		test_props(.Conifer_Snow_Tall, .Conifer_Snow_Medium),
		references,
		test_bodies("fir_snow_01_a"),
	)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, len(bindings), 2)
	testing.expect_value(t, meshes[bindings[0].mesh].filename, "fir_snow_01_a")
	testing.expect_value(t, meshes[bindings[1].mesh].filename, "fir_snow_01_a")
	// One row, shared: no stock placement file repeats a filename in its
	// reference table, so two kinds on one mesh must not emit two rows.
	testing.expect_value(t, len(meshes), 1)
	testing.expect_value(t, bindings[0].mesh, bindings[1].mesh)
}

// A venue whose art has nothing for a species must say so rather than write a
// stage with the vegetation silently missing.
@(test)
prop_bindings_refuse_a_kind_with_no_candidate :: proc(t: ^testing.T) {
	references := []d3.D3_Placement_Reference{test_reference(0, "core_barr_haybale_e")}
	_, _, _, ok := d3_prop_bindings(
		test_props(.Conifer_Tall),
		references,
		test_bodies("core_barr_haybale_e"),
	)
	testing.expect(t, !ok, "a kind with no matching mesh must refuse")
}

// Ids must be dense from zero in emission order: track.vis tag 3 addresses a
// tree by instance_id, and its ens body joins on instance_tag. The scatter
// reaches the file as placements, so this covers both halves at once.
@(test)
prop_instances_number_densely_and_carry_yaw_and_scale :: proc(t: ^testing.T) {
	meshes := []d3.D3_Placement_Reference{test_reference(0, "conifer"), test_reference(1, "bush")}
	bindings := []D3_Prop_Binding{
		{kind = .Conifer_Tall, mesh = 0},
		{kind = .Thorn_Bush, mesh = 1},
	}
	props := []geo.Veg_Instance{
		{kind = .Thorn_Bush, scale = 1},
		{kind = .Conifer_Tall, pos = {1, 2, 3}, yaw = math.PI/2, scale = 2},
	}
	row_of := make(map[string]int, context.temp_allocator)
	row_of["conifer"], row_of["bush"] = 0, 1
	instances := d3_place_instances(d3_scatter_placements(props, meshes, bindings), .Trees, row_of)
	testing.expect_value(t, len(instances), 2)
	for inst, i in instances {
		testing.expect_value(t, inst.instance_id, u32(i))
		testing.expect_value(t, inst.instance_tag, u32(i+1))
	}
	// Binding order groups the output, so the conifer comes first.
	tree := instances[0]
	testing.expect_value(t, tree.reference_id, u32(0))
	testing.expect_value(t, tree.position, [3]f32{1, 2, 3})
	// Yaw pi/2 about +Y at scale 2: rows are the scaled basis vectors.
	testing.expect(t, abs(tree.basis[0][2] - -2) < 1e-5 && abs(tree.basis[2][0] - 2) < 1e-5)
	testing.expect_value(t, tree.basis[1][1], f32(2))
}

// Camera and cutscene idents are built from this, and the global cutscene
// files substitute it, so a wrong number aims a route at another's cameras.
@(test)
route_number_reads_the_id_and_falls_back_to_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, route_number("route_0"), 0)
	testing.expect_value(t, route_number("route_3"), 3)
	testing.expect_value(t, route_number("route_12"), 12)
	// A loose road out of maps/ has no stage id.
	testing.expect_value(t, route_number(""), 0)
	testing.expect_value(t, route_number("demo-rally"), 0)
	testing.expect_value(t, route_number("route_x"), 0)
	testing.expect_value(t, route_number("route_-1"), 0)
}

// --- hand-placed props ----------------------------------------------------------

@(private = "file")
test_placed :: proc(kind: Prop_Lib_Kind, name: string, pos: gfx.Vector3) -> Prop_Instance {
	return {ref = {kind = kind, name = name}, pos = pos, rot = gfx.Quaternion(1), scale = 1}
}

// The scatter and a hand-placed prop must write the same nine numbers for the
// same rotation, or the two disagree about which way a yaw turns.
@(test)
prop_basis_is_the_scatter_convention :: proc(t: ^testing.T) {
	yaw, scale := f32(0.7), f32(1.3)
	sin, cos := math.sin(yaw) * scale, math.cos(yaw) * scale
	scattered := [3][3]f32{{cos, 0, -sin}, {0, scale, 0}, {sin, 0, cos}}

	placed := d3_prop_basis(gfx.QuaternionFromAxisAngle({0, 1, 0}, yaw), scale)
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			testing.expectf(
				t, abs(placed[row][col] - scattered[row][col]) < 1e-6,
				"basis[%d][%d]: %v, scatter writes %v", row, col, placed[row][col], scattered[row][col],
			)
		}
	}
}

// A prop already in the file's table rides that row; one that is not gets a new
// row on the end, and the ids stay dense.
@(test)
placing_reuses_a_row_before_adding_one :: proc(t: ^testing.T) {
	rows := []d3.D3_Placement_Reference{test_reference(0, "pole_mesh"), test_reference(1, "core_barr_haybale_e")}
	placed := []Prop_Instance{
		test_placed(.Objects, "core_barr_haybale_e", {1, 0, 0}),
		test_placed(.Objects, "core_barr_haybale_e", {2, 0, 0}),
		test_placed(.Trees, "birch_full_01_a", {3, 0, 0}),
	}
	out, row_of, msg, ok := d3_place_references(placed, .Objects, rows, nil)
	testing.expect(t, ok, msg); if !ok { return }
	// Nothing new: the hay bale is already there and the tree is another file's.
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, row_of["core_barr_haybale_e"], 1)

	instances := d3_place_instances(placed, .Objects, row_of)
	testing.expect_value(t, len(instances), 2)
	testing.expect_value(t, instances[0].reference_id, u32(1))
	testing.expect_value(t, instances[1].instance_id, u32(1))
	testing.expect_value(t, instances[1].position, [3]f32{2, 0, 0})
}

// Trees share trees.bin with the scatter, and track.vis addresses a drawable by
// instance_id. The scatter leads the list, so a hand-placed tree numbers on
// from the last scattered one; placing it first would take an id the scatter
// already answers to.
@(test)
placed_trees_number_on_from_the_scatter :: proc(t: ^testing.T) {
	rows := []d3.D3_Placement_Reference{test_reference(0, "dougfir"), test_reference(1, "birch")}
	scatter := d3_scatter_placements(
		test_props(.Conifer_Tall, .Conifer_Tall),
		rows,
		[]D3_Prop_Binding{{kind = .Conifer_Tall, mesh = 0}},
	)
	all := make([dynamic]Prop_Instance, context.temp_allocator)
	append(&all, ..scatter)
	append(&all, test_placed(.Trees, "birch", {1, 0, 0}))

	_, row_of, msg, ok := d3_place_references(all[:], .Trees, rows, nil)
	testing.expect(t, ok, msg); if !ok { return }
	instances := d3_place_instances(all[:], .Trees, row_of)
	testing.expect_value(t, len(instances), 3)
	testing.expect_value(t, instances[2].reference_id, u32(1))
	testing.expect_value(t, instances[2].instance_id, u32(2))
	testing.expect_value(t, instances[2].instance_tag, u32(3))
}

// Without a library there is no box to quote, so a prop no table covers is
// refused rather than written with a zero box, which draws nothing.
@(test)
placing_an_unknown_prop_needs_the_library :: proc(t: ^testing.T) {
	rows := []d3.D3_Placement_Reference{test_reference(0, "pole_mesh")}
	placed := []Prop_Instance{test_placed(.Objects, "barrel_wood_a", {0, 0, 0})}
	_, _, _, ok := d3_place_references(placed, .Objects, rows, nil)
	testing.expect(t, !ok, "a prop with no row and no library was accepted")
}

// Capacity is a registration count, and the writer refuses a row that holds
// fewer slots than it has instances. No stock row is an exact fit either.
@(test)
capacity_clears_what_is_placed_against_it :: proc(t: ^testing.T) {
	rows := []d3.D3_Placement_Reference{test_reference(0, "a"), test_reference(1, "b")}
	rows[1].instance_capacity = 400
	instances := []d3.D3_Placement_Instance{
		{reference_id = 0}, {reference_id = 0}, {reference_id = 1},
	}
	d3_place_capacities(rows, instances)
	testing.expect_value(t, rows[0].instance_capacity, u32(3))
	// Already generous: a donor row keeps its own slack.
	testing.expect_value(t, rows[1].instance_capacity, u32(400))

	_, _, built := d3.Placement_Build(.Ornaments, rows, instances, context.temp_allocator)
	testing.expect(t, built, "the writer refused rows the capacity pass had cleared")
}

// One entity reference per mesh however many props name it, and a prop the
// venue gives no body is scenery rather than a record pointing nowhere.
@(test)
placed_bodies_declare_each_mesh_once :: proc(t: ^testing.T) {
	rows := []d3.D3_Placement_Reference{test_reference(0, "core_barr_haybale_e"), test_reference(1, "pole_mesh")}
	instances := []d3.D3_Placement_Instance{
		{reference_id = 0, instance_id = 0, instance_tag = 1},
		{reference_id = 0, instance_id = 1, instance_tag = 2},
		{reference_id = 1, instance_id = 2, instance_tag = 3},
	}
	declared := make(map[string]bool, context.temp_allocator)
	nodes, bodied := d3_place_ens_nodes(
		instances, rows, test_bodies("core_barr_haybale_e"), &declared, "test",
	)
	testing.expect_value(t, bodied, 2)
	refs, bodies := 0, 0
	for node in nodes {
		switch node.tag {
		case "TEMPLATEENTITYREFERENCE": refs += 1
		case "TEMPLATEBASICENTITYINSTANCE": bodies += 1
		}
	}
	testing.expect_value(t, refs, 1)
	testing.expect_value(t, bodies, 2)

	// A second call into the same file sees the reference is already declared.
	again, _ := d3_place_ens_nodes(instances[:1], rows, test_bodies("core_barr_haybale_e"), &declared, "test2")
	for node in again {
		testing.expect(t, node.tag != "TEMPLATEENTITYREFERENCE", "a mesh was declared twice in one objects.ens")
	}
}
