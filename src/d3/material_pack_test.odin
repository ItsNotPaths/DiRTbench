package d3

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
	for material in Collision_Material {
		testing.expect_value(t, got.visual[material], want.visual[material])
		testing.expect_value(t, got.collision[material], want.collision[material])
		testing.expect_value(t, got.colour[material], want.colour[material])
	}
}

// The fixture is a PSSG of the same shape as a venue's tracksplit, so it
// exercises the whole extraction without needing the user's install.
@(test)
pack_extract_yields_a_template_the_exporter_can_build_from :: proc(t: ^testing.T) {
	source := transmute([]u8)D3_FIXTURE_MATERIALS
	pack, profile_text, msg, ok := d3_pack_build(source, "somevenue", context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect(t, len(pack) <= len(source), "a pack must never be larger than the file it came from")

	profile, parse_msg, parsed := d3_profile_parse(profile_text, pack, context.temp_allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	testing.expect_value(t, profile.id, "somevenue")
	// Road and terrain must not collapse onto one name while the source offers
	// two, or every stage draws in one flat colour.
	testing.expect(t, profile.visual[.Road] != profile.visual[.Terrain])

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
	for material in Collision_Material { testing.expect(t, shaders[profile.visual[material]]) }
}

@(test)
pack_refuses_a_source_without_the_shader_groups_it_needs :: proc(t: ^testing.T) {
	_, _, msg, ok := d3_pack_build([]u8{'P', 'S', 'S', 'G'}, "somevenue", context.temp_allocator)
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
