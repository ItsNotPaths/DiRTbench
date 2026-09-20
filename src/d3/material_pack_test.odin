package d3

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
profile_survives_a_round_trip_through_its_own_text :: proc(t: ^testing.T) {
	want, want_msg, want_ok := d3_profile_fixture()
	testing.expect(t, want_ok, want_msg); if !want_ok { return }

	text := d3_profile_text(want, context.temp_allocator)
	got, msg, ok := d3_profile_parse(text, want.template, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }

	testing.expect_value(t, got.id, want.id)
	testing.expect_value(t, got.lod, want.lod)
	testing.expect_value(t, got.batch, want.batch)
	testing.expect_value(t, got.tiles_x, want.tiles_x)
	testing.expect_value(t, got.tiles_z, want.tiles_z)
	for material in Draw_Material {
		testing.expect_value(t, got.visual[material], want.visual[material])
		testing.expect_value(t, got.colour[material], want.colour[material])
		testing.expect_value(t, got.colour_b[material], want.colour_b[material])
	}
	for surface in Collision_Surface {
		testing.expect_value(t, got.collision[surface], want.collision[surface])
	}
}

// The fixture is a PSSG of the same shape as a venue's tracksplit, so it
// exercises the whole extraction without needing the user's install.
@(test)
pack_extract_yields_a_template_the_exporter_can_build_from :: proc(t: ^testing.T) {
	source := transmute([]u8)D3_FIXTURE_MATERIALS
	pack, profile_text, msg, ok := d3_pack_build(source, "somevenue", D3_Pack_Art{}, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect(t, len(pack) <= len(source), "a pack must never be larger than the file it came from")

	profile, parse_msg, parsed := d3_profile_parse(profile_text, pack, context.temp_allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	testing.expect_value(t, profile.id, "somevenue")
	// Road and terrain must not collapse onto one name while the source offers
	// two, or every stage draws in one flat colour.
	testing.expect(t, profile.visual[.Road] != profile.visual[.Terrain])
	// The fixture carries shader metadata and no art, so there is no rock to
	// point a cliff material at. The cliff must fall back to a material that
	// exists rather than name one nothing answers to.
	testing.expect(t, profile.visual[.Cliff] != D3_CLIFF_MATERIAL)

	file, read_msg, read_ok := pssg_read(pack, context.temp_allocator)
	testing.expect(t, read_ok, read_msg); if !read_ok { return }

	kinds := make([dynamic]string, context.temp_allocator)
	for child in file.root.children {
		testing.expect_value(t, child.name, "LIBRARY")
		append(&kinds, pssg_attr_string(&file, child, "type"))
	}
	testing.expect_value(t, len(kinds), len(d3_pack_libraries))
	for want, i in d3_pack_libraries { testing.expect_value(t, kinds[i], want) }

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)
	named := make(map[string]int, context.temp_allocator)
	for node in nodes { named[node.name] += 1 }
	testing.expect_value(t, named["TEXTURE"], 0)
	testing.expect_value(t, named["TEXTUREIMAGEBLOCKDATA"], 0)
	// One live instance of each, because pssg_types reads ids off real nodes.
	once := [?]string{"DATABLOCK", "SEGMENTSET", "RENDERNODE", "RENDERSTREAMINSTANCE"}
	for kind in once { testing.expect_value(t, named[kind], 1) }

	// A routesplit names textures across files. A local `#name` would resolve to
	// nothing once the pack's own shaders land in one.
	for node in nodes {
		if node.name != "SHADERINPUT" { continue }
		texture := pssg_attr_string(&file, node, "texture")
		if texture == "" { continue }
		testing.expect(t, !strings.has_prefix(texture, "#"), texture)
		testing.expect(t, strings.contains(texture, "tracksplit.pssg#"), texture)
	}

	shaders := make(map[string]bool, context.temp_allocator)
	for node in nodes {
		if node.name == "SHADERINSTANCE" { shaders[pssg_attr_string(&file, node, "id")] = true }
	}
	testing.expect(t, shaders[profile.lod]); testing.expect(t, shaders[profile.batch])
	for material in Draw_Material { testing.expect(t, shaders[profile.visual[material]]) }
}

@(test)
pack_refuses_a_source_without_the_shader_groups_it_needs :: proc(t: ^testing.T) {
	_, _, msg, ok := d3_pack_build([]u8{'P', 'S', 'S', 'G'}, "somevenue", D3_Pack_Art{}, context.temp_allocator)
	testing.expect(t, !ok, "a truncated PSSG must not produce a pack")
	testing.expect(t, msg != "")
}

@(test)
shader_base_name_drops_only_a_numeric_suffix :: proc(t: ^testing.T) {
	testing.expect_value(t, d3_shader_base("grass_01!2"), "grass_01")
	testing.expect_value(t, d3_shader_base("grass_01"), "grass_01")
	testing.expect_value(t, d3_shader_base("Material #39"), "Material #39")
	testing.expect_value(t, d3_shader_base("odd!"), "odd!")
	testing.expect_value(t, d3_unref("#terrain_infield.fx"), "terrain_infield.fx")
}

// An export that names shaders needs a venue behind them.
@(test)
export_refuses_a_job_with_no_profile :: proc(t: ^testing.T) {
	job := Export_Job{Name = "nowhere", Out = ""}
	msg, ok := export_dirt3(&job)
	testing.expect(t, !ok, "an export with no profile must be refused")
	testing.expect(t, strings.contains(msg, "venue"), msg)
}

// A pack written before the stamp existed must read as stale, not as current.
// Reused silently, an old pack outlives every venue that shares it.
@(test)
profile_without_a_stamp_reads_as_stale :: proc(t: ^testing.T) {
	want, want_msg, want_ok := d3_profile_fixture()
	testing.expect(t, want_ok, want_msg); if !want_ok { return }
	testing.expect_value(t, want.pack, D3_PACK_STAMP)

	text := d3_profile_text(want, context.temp_allocator)
	stamp := fmt.tprintf("%s.pack = %d\n", want.id, D3_PACK_STAMP)
	old, _ := strings.replace(text, stamp, "", 1, context.temp_allocator)
	testing.expect(t, old != text, "the stamp line must be in the written profile")

	got, msg, ok := d3_profile_parse(old, want.template, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, got.pack, 0)
}

// The roadside material fades the ground into the road, and both its ends have
// to be exactly what they fade between: its first texture is the one the road
// edge draws, its second the one the ground draws. Anything else swaps one hard
// edge for two fainter ones, which is worse than the edge.
//
// Read out of the built pack rather than off the call that made it, because the
// clone is where a slot can be repointed wrongly and still look fine.
@(test)
the_roadside_ends_where_its_neighbours_begin :: proc(t: ^testing.T) {
	pack, profile_text, msg, ok := d3_pack_build(
		transmute([]u8)D3_FIXTURE_MATERIALS, "somevenue", D3_Pack_Art{}, context.temp_allocator,
	)
	testing.expect(t, ok, msg); if !ok { return }
	profile, parse_msg, parsed := d3_profile_parse(profile_text, pack, context.temp_allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	testing.expect_value(t, profile.visual[.Roadside], D3_ROADSIDE_MATERIAL)

	file, read_msg, read_ok := pssg_read(pack, context.temp_allocator)
	testing.expect(t, read_ok, read_msg); if !read_ok { return }
	instances := d3_library(&file, "SHADERINSTANCE")

	road := d3_material_texture(&file, instances, profile.visual[.Road], d3_infield_diffuse[0])
	ground := d3_material_texture(&file, instances, profile.visual[.Terrain], d3_infield_diffuse[0])
	near := d3_material_texture(&file, instances, D3_ROADSIDE_MATERIAL, d3_infield_diffuse[0])
	far := d3_material_texture(&file, instances, D3_ROADSIDE_MATERIAL, d3_infield_diffuse[1])

	testing.expect(t, road != "" && ground != "", "the two neighbours must name textures")
	testing.expect(t, road != ground, "a venue drawing one texture for both has nothing to fade")
	testing.expect_value(t, near, road)
	testing.expect_value(t, far, ground)
}

// Every material we draw the ground with shares one baked ambient-occlusion map
// and one colour map.
//
// `terrain_infield.fx` samples both at ST, and ST is one map over the whole
// venue, so two materials carrying different ones tint the ground by two
// unrelated images. They agree near the ST origin and drift apart across the
// map — driven, that reads as gravel meeting gravel of another shade, further
// along the road each time. It shipped that way once.
@(test)
every_ground_material_shares_one_baked_art :: proc(t: ^testing.T) {
	pack, profile_text, msg, ok := d3_pack_build(
		transmute([]u8)D3_FIXTURE_MATERIALS, "somevenue", D3_Pack_Art{}, context.temp_allocator,
	)
	testing.expect(t, ok, msg); if !ok { return }
	profile, parse_msg, parsed := d3_profile_parse(profile_text, pack, context.temp_allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }

	file, read_msg, read_ok := pssg_read(pack, context.temp_allocator)
	testing.expect(t, read_ok, read_msg); if !read_ok { return }
	instances := d3_library(&file, "SHADERINSTANCE")

	for parameter in d3_shared_art {
		want, from := "", Draw_Material.Road
		for material in Draw_Material {
			got := d3_material_texture(&file, instances, profile.visual[material], parameter)
			testing.expectf(t, got != "", "%v names no art at %#x", material, parameter)
			if want == "" {
				want, from = got, material
				continue
			}
			testing.expectf(t, got == want,
				"%v draws with %q at %#x and %v with %q: two images over one venue",
				from, want, parameter, material, got)
		}
	}
}

// And the two textures the roadside fades between keep the tiling of the
// materials they came from — the road's in the slot holding the road's texture,
// the ground's in the slot holding the ground's. Same grain either side of the
// join, not the same texture drawn at half the size.
@(test)
the_roadside_keeps_each_texture_at_its_own_scale :: proc(t: ^testing.T) {
	pack, profile_text, msg, ok := d3_pack_build(
		transmute([]u8)D3_FIXTURE_MATERIALS, "somevenue", D3_Pack_Art{}, context.temp_allocator,
	)
	testing.expect(t, ok, msg); if !ok { return }
	profile, parse_msg, parsed := d3_profile_parse(profile_text, pack, context.temp_allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }

	file, read_msg, read_ok := pssg_read(pack, context.temp_allocator)
	testing.expect(t, read_ok, read_msg); if !read_ok { return }
	instances := d3_library(&file, "SHADERINSTANCE")
	tiling :: proc(file: ^Pssg_File, instances: ^Pssg_Node, id: string, parameter: u32) -> []u8 {
		instance := pssg_walk_first_by_id(file, instances, "SHADERINSTANCE", id)
		if instance == nil { return nil }
		input := d3_input_at(file, instance, parameter)
		return input == nil ? nil : input.data
	}
	road := tiling(&file, instances, profile.visual[.Road], D3_MAP_UV[0])
	ground := tiling(&file, instances, profile.visual[.Terrain], D3_MAP_UV[0])
	near := tiling(&file, instances, D3_ROADSIDE_MATERIAL, D3_MAP_UV[0])
	far := tiling(&file, instances, D3_ROADSIDE_MATERIAL, D3_MAP_UV[1])

	testing.expect(t, len(road) > 0 && len(ground) > 0, "both neighbours must name a tiling")
	testing.expect(t, slice.equal(near, road), "the road's texture must tile as the road tiles it")
	testing.expect(t, slice.equal(far, ground), "the ground's must tile as the ground tiles it")
}
