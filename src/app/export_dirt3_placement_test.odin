package main

import "core:math"
import "core:testing"
import d3 "../d3"
import "../geo"

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
	testing.expect_value(t, meshes[bindings[0].mesh].reference.filename, "dougfir_tall_01_a")
	testing.expect_value(t, meshes[bindings[0].mesh].entity_id, "dougfir_tall_01_a")
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
		testing.expect_value(t, mesh.reference.reference_id, u32(i))
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
	testing.expect(t, meshes[bindings[0].mesh].reference.filename != meshes[bindings[1].mesh].reference.filename)
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
	testing.expect_value(t, meshes[bindings[0].mesh].reference.filename, "fir_snow_01_a")
	testing.expect_value(t, meshes[bindings[1].mesh].reference.filename, "fir_snow_01_a")
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
// tree by instance_id, and its ens body joins on instance_tag.
@(test)
prop_instances_number_densely_and_carry_yaw_and_scale :: proc(t: ^testing.T) {
	bindings := []D3_Prop_Binding{
		{kind = .Conifer_Tall, mesh = 0},
		{kind = .Thorn_Bush, mesh = 1},
	}
	props := []geo.Veg_Instance{
		{kind = .Thorn_Bush, scale = 1},
		{kind = .Conifer_Tall, pos = {1, 2, 3}, yaw = math.PI/2, scale = 2},
	}
	instances := d3_prop_instances(props, bindings)
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
