package d3

import "core:testing"

@(test)
fixture_dirt3_profile_is_self_contained :: proc(t: ^testing.T) {
	profile, msg, ok := d3_profile_fixture()
	testing.expect(t, ok, msg); if !ok { return }
	testing.expect_value(t, profile.id, D3_FIXTURE_ID)
	file, parse_msg, parsed := pssg_read(profile.template, context.allocator)
	testing.expect(t, parsed, parse_msg); if !parsed { return }
	defer pssg_delete(&file)
	found: map[string]bool
	defer delete(found)
	for library in file.root.children {
		if pssg_attr_string(&file, library, "type") != "SHADERINSTANCE" { continue }
		for instance in library.children { found[pssg_attr_string(&file, instance, "id")] = true }
	}
	testing.expect(t, len(file.root.children) >= 5, "profile must retain the scene/draw structural skeleton")
	testing.expect(t, found[profile.batch]); testing.expect(t, found[profile.lod])
	for material in Collision_Material { testing.expect(t, found[profile.visual[material]]) }
}

@(test)
profile_rows_address_materials_by_suffix :: proc(t: ^testing.T) {
	profile: D3_Venue_Profile
	_, assigned := d3_profile_assign(&profile, "road_sand_collision", "GLD*")
	testing.expect(t, assigned)
	testing.expect_value(t, profile.collision[.Road_Sand], "GLD*")
	_, parsed := d3_profile_assign(&profile, "terrain_colour", "00ff00")
	testing.expect(t, !parsed, "a short colour must not pass as zeroes")
}
