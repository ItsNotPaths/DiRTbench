package d3

import "core:strings"
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
	_, assigned := d3_profile_assign(&profile, "road_paved_collision", "TSD*")
	testing.expect(t, assigned)
	testing.expect_value(t, profile.collision[.Road_Paved], "TSD*")
	_, parsed := d3_profile_assign(&profile, "terrain_colour", "00ff00")
	testing.expect(t, !parsed, "a short colour must not pass as zeroes")

	// `_colour` is a suffix of `_colour_b`, so the two ends of the texture mix
	// have to be told apart by the longer match, not by whichever runs first.
	_, near := d3_profile_assign(&profile, "road_colour", "00ffff00")
	_, far := d3_profile_assign(&profile, "road_colour_b", "00112233")
	testing.expect(t, near && far)
	testing.expect_value(t, profile.colour[.Road], [4]u8{0x00, 0xff, 0xff, 0x00})
	testing.expect_value(t, profile.colour_b[.Road], [4]u8{0x00, 0x11, 0x22, 0x33})
}

// A profile from before the texture mix existed has no `_colour_b` rows. Read as
// written, its second end would be all zeroes and every road would fade to black
// at the edges, with nothing to see in the file that says so.
@(test)
a_profile_missing_its_colour_rows_reads_as_the_default :: proc(t: ^testing.T) {
	want, want_msg, want_ok := d3_profile_fixture()
	testing.expect(t, want_ok, want_msg); if !want_ok { return }

	text := d3_profile_text(want, context.temp_allocator)
	trimmed := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.contains(line, "_colour") { continue }
		append(&trimmed, line)
	}
	old := strings.join(trimmed[:], "\n", context.temp_allocator)
	testing.expect(t, !strings.contains(old, "_colour"), "the colour rows must be gone")

	got, msg, ok := d3_profile_parse(old, want.template, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	for material in Collision_Material {
		testing.expect_value(t, got.colour[material], want.colour[material])
		testing.expect_value(t, got.colour_b[material], want.colour_b[material])
	}
}
