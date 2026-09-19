package main

// The base venue palettes: the rows the tool cannot measure off a venue's art.

import "core:strings"
import "core:testing"
import d3 "../d3"
import "../geo"
import "../gfx"

// A typo in a baked palette would be silent — the row is simply not applied, and
// the venue draws and drives as though the palette said nothing. So check every
// file that ships, rather than one of them.
@(test)
every_baked_palette_names_a_collision_code :: proc(t: ^testing.T) {
	testing.expect(t, len(PALETTES) > 0, "the palettes must be baked into the binary")
	for file in PALETTES {
		p: Palette
		bad := palette_apply(string(file.data), &p, context.temp_allocator)
		// A malformed colour row is the quiet failure: the venue just draws in
		// Finland's colours and nothing says why. This is what caught
		// `colour.gutter = 58524 6` before it shipped.
		for key in bad {
			testing.expectf(t, false, "%s: row %q does not read as a colour", file.name, key)
		}
		testing.expectf(t, p.paved_collision != "", "%s names no paved collision code", file.name)
		testing.expectf(t, len(p.paved_collision) == 4,
			"%s: %q is not a four-character surface code", file.name, p.paved_collision)
		// A texture is optional — a snow venue has no paving to point at — but a
		// present one has to look like a texture rather than a shader name.
		if p.paved_texture != "" {
			testing.expectf(t, strings.has_suffix(p.paved_texture, ".tga"),
				"%s: %q is not a texture name", file.name, p.paved_texture)
		}
	}
}

// A palette whose two road surfaces look alike is no use for authoring: you set
// a run to paved and nothing on screen changes. The first pass shipped exactly
// that — loose and paved sat 22 levels apart in the same grey, and the road read
// as solid grey however it was set.
@(test)
a_palette_keeps_its_two_roads_apart :: proc(t: ^testing.T) {
	// Measured per channel rather than summed: three small differences still
	// read as one colour, and it was a summed distance that let the first pass
	// through.
	SEPARATION :: 32
	apart :: proc(a, b: gfx.Color) -> int {
		return max(abs(int(a.r)-int(b.r)), abs(int(a.g)-int(b.g)), abs(int(a.b)-int(b.b)))
	}
	testing.expectf(t, apart(geo.DEFAULT_LOOK.road, geo.DEFAULT_LOOK.road_paved) >= SEPARATION,
		"the default loose and paved roads are %d apart", apart(geo.DEFAULT_LOOK.road, geo.DEFAULT_LOOK.road_paved))
	for file in PALETTES {
		p: Palette
		p.look = geo.DEFAULT_LOOK
		palette_apply(string(file.data), &p, context.temp_allocator)
		testing.expectf(t, apart(p.look.road, p.look.road_paved) >= SEPARATION,
			"%s: loose %v and paved %v are only %d apart",
			file.name, p.look.road, p.look.road_paved, apart(p.look.road, p.look.road_paved))
	}
}

// Every base-eligible stock venue ships one. A venue with no palette falls back
// to the profile defaults, which name tarmac — wrong for the four snow venues,
// and wrong in a way nothing would report.
@(test)
every_base_eligible_venue_has_a_palette :: proc(t: ^testing.T) {
	bases := [?]string{
		"finland/finland_rally", "finland/finland_trail",
		"kenya/kenya_rally", "kenya/kenya_trail",
		"norway/norway_rally", "norway/norway_trail",
		"usa/michigan_rally", "usa/michigan_trail",
		"france/monte_carlo_rally",
	}
	for base in bases {
		want := palette_name(base, context.temp_allocator)
		found := false
		for file in PALETTES { if file.name == want { found = true; break } }
		testing.expectf(t, found, "no baked palette %s for base %s", want, base)
	}
}

// A colour row this build cannot use is reported rather than dropped, whether
// the value is malformed or the slot name is unknown — under `colour.` both read
// as typos. A key outside our namespaces stays silent, because that one really
// is a palette from a later version.
@(test)
a_colour_row_this_build_cannot_use_is_reported :: proc(t: ^testing.T) {
	p: Palette
	p.look = geo.DEFAULT_LOOK
	bad := palette_apply(
		"colour.terrain = 11223 4\ncolour.nosuchthing = 112233\nlater.key = 5\n",
		&p, context.temp_allocator,
	)
	testing.expect_value(t, len(bad), 2) // the bad value and the unknown slot
	testing.expect_value(t, p.look.terrain, geo.DEFAULT_LOOK.terrain)

	good := palette_apply("colour.terrain = 112233\n", &p, context.temp_allocator)
	testing.expect_value(t, len(good), 0)
	testing.expect_value(t, p.look.terrain, gfx.Color{0x11, 0x22, 0x33, 255})
}

// Every colour slot has to be reachable by name, or a palette can never set it
// and the field is decoration. One list of names in one place; this is what
// keeps it honest.
@(test)
every_colour_slot_is_reachable_by_name :: proc(t: ^testing.T) {
	names := [?]string{
		"road", "road_paved", "terrain", "terrain_steep",
		"cliff_top", "cliff_bot", "bank", "gutter",
	}
	look: geo.Look
	seen := make(map[rawptr]bool, context.temp_allocator)
	for name in names {
		slot := palette_colour_slot(&look, name)
		testing.expectf(t, slot != nil, "no colour slot named %q", name)
		if slot == nil { continue }
		testing.expectf(t, !seen[rawptr(slot)], "%q names a slot another name already took", name)
		seen[rawptr(slot)] = true
	}
	testing.expect_value(t, len(seen), size_of(geo.Look)/size_of(gfx.Color))
	testing.expect(t, palette_colour_slot(&look, "tarmac") == nil)
}

// A pack's own file lays over the baked one row by row, so someone shipping
// custom art can change the texture and keep the code, or the other way round.
@(test)
a_palette_row_lays_over_the_one_below_it :: proc(t: ^testing.T) {
	p: Palette
	palette_apply("paved.texture = base_d.tga\npaved.collision = TSD*\n", &p, context.temp_allocator)
	testing.expect_value(t, p.paved_texture, "base_d.tga")
	testing.expect_value(t, p.paved_collision, "TSD*")

	palette_apply("# only the texture\npaved.texture = mine_d.tga\n", &p, context.temp_allocator)
	testing.expect_value(t, p.paved_texture, "mine_d.tga")
	testing.expect_value(t, p.paved_collision, "TSD*")

	// A row this build does not know must not stop it reading the ones it does.
	// A palette written for a later version has to stay loadable.
	palette_apply("iced.texture = later_d.tga\npaved.collision = CON*\n", &p, context.temp_allocator)
	testing.expect_value(t, p.paved_collision, "CON*")
	testing.expect_value(t, p.paved_texture, "mine_d.tga")
}

// The palette only owns the rows it names. Everything else on a profile was
// measured off the base venue's own tracksplit and must survive untouched.
@(test)
a_palette_moves_only_its_own_rows :: proc(t: ^testing.T) {
	profile: d3.Venue_Profile
	profile.visual[.Road] = "dirt_pebbles_01"
	profile.collision[.Road] = "GLD*"
	profile.collision[.Terrain] = "GRS*"
	profile.collision[.Road_Paved] = "TSD*"
	road := profile.visual[.Road]
	terrain := profile.collision[.Terrain]

	palette_over_profile(Palette{paved_collision = "CON*"}, &profile)
	testing.expect_value(t, profile.collision[.Road_Paved], "CON*")
	testing.expect_value(t, profile.visual[.Road], road)
	testing.expect_value(t, profile.collision[.Terrain], terrain)

	// An empty palette states nothing, so the profile's own default stands.
	profile.collision[.Road_Paved] = "TSD*"
	palette_over_profile(Palette{}, &profile)
	testing.expect_value(t, profile.collision[.Road_Paved], "TSD*")
}
