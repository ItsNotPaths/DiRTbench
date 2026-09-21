package d3

import "core:strings"
import "core:testing"

// Shader metadata cut out of the stock Moosylvania venue: no texture or
// geometry payload, and see credits.txt. It lives in a _test.odin file so that
// `odin build` cannot put DiRT 3 bytes in a release binary. Reinstating
// refs/d3/scratch.odin means moving this back.
//
// Not in the repository, so the load has to survive its absence: a clone
// without it still builds, and the tests below report it instead of failing
// somewhere inside a parser.
D3_FIXTURE_MATERIALS :: #load("../../assets/d3/moosylvania-materials.pssg", string) or_else ""
D3_FIXTURE_ID :: "fixture"

FIXTURE_MISSING :: "assets/d3/moosylvania-materials.pssg is not in the repository; see credits.txt"

// The canary. Most of the d3 suite builds on one of the two DiRT 3 fixtures,
// so on a clone without them a great many tests fail at once; this one names
// the reason. Both files come out of a real install — see credits.txt.
@(test)
the_dirt3_fixtures_are_here :: proc(t: ^testing.T) {
	testing.expect(t, len(D3_FIXTURE_MATERIALS) > 0, FIXTURE_MISSING)
	testing.expect(t, len(D3_FIXTURE_WATER) > 0, WATER_FIXTURE_MISSING)
}

// The venue-less profile. A stage export takes the open venue's profile
// instead, and refuses to run on this one.
d3_profile_fixture :: proc() -> (profile: D3_Venue_Profile, msg: string, ok: bool) {
	if len(D3_FIXTURE_MATERIALS) == 0 {
		return {}, FIXTURE_MISSING, false
	}
	profile = d3_profile_defaults()
	profile.id = D3_FIXTURE_ID
	profile.template = transmute([]u8)D3_FIXTURE_MATERIALS
	profile.lod = "lod"
	profile.batch = "batchmaterial"
	for material in Draw_Material { profile.visual[material] = "dirt_pebbles_01" }
	profile.visual[.Terrain] = "grass_01"
	msg, ok = d3_profile_complete(profile)
	return
}

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
