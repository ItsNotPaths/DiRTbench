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
	for material in Draw_Material { testing.expect(t, found[profile.visual[material]]) }
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
	for material in Draw_Material {
		testing.expect_value(t, got.colour[material], want.colour[material])
		testing.expect_value(t, got.colour_b[material], want.colour_b[material])
	}
}

// A row lands in one keyspace and leaves the other alone. The two tables spell
// the same four names today, so a parser that resolved the name once and used it
// for both would pass every test that exists and silently tie a drawn-only
// material to a surface code the moment the sets diverge.
@(test)
a_profile_row_lands_in_one_keyspace :: proc(t: ^testing.T) {
	profile: D3_Venue_Profile
	_, visual := d3_profile_assign(&profile, "road", "some_shader")
	_, code := d3_profile_assign(&profile, "road_collision", "TSD*")
	testing.expect(t, visual && code)
	testing.expect_value(t, profile.visual[.Road], "some_shader")
	testing.expect_value(t, profile.collision[.Road], "TSD*")

	// The names are separate tables, so a name in one and not the other is
	// ignored rather than resolved through the wrong one.
	_, unknown := d3_profile_assign(&profile, "no_such_material_collision", "GLD*")
	testing.expect(t, unknown, "an unknown row is ignored, not refused")
	for surface in Collision_Surface {
		testing.expect(t, profile.collision[surface] != "GLD*",
			"an unknown name must not fall through onto a real surface")
	}
}

// Completeness is checked per keyspace. A profile naming every shader but
// missing a code is incomplete, and so is the reverse, and the two say so
// differently — the message is the only thing that tells them apart on disk.
@(test)
completeness_is_checked_on_both_axes :: proc(t: ^testing.T) {
	full, full_msg, full_ok := d3_profile_fixture()
	testing.expect(t, full_ok, full_msg); if !full_ok { return }

	no_shader := full
	no_shader.visual[.Road_Paved] = ""
	msg, ok := d3_profile_complete(no_shader)
	testing.expect(t, !ok, "a profile missing a shader must not read as complete")
	testing.expect(t, strings.contains(msg, "material"), msg)

	no_code := full
	no_code.collision[.Road_Paved] = ""
	msg, ok = d3_profile_complete(no_code)
	testing.expect(t, !ok, "a profile missing a code must not read as complete")
	testing.expect(t, strings.contains(msg, "surface"), msg)
}
