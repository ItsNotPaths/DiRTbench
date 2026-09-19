package d3

// Venue-specific graphics data, kept deliberately small: shader metadata and
// texture names, never texture or model payloads.
//
// The profile lives in the base venue's content pack, not in our venue. See
// material_pack.odin. Nothing in the export path names one of our venues: the
// base venue decides the shader names, and everything else here is our own
// convention.
//
// One parser and one writer cover the file, so a round trip is a free test.

import "core:fmt"
import "core:strconv"
import "core:strings"

// A shader template with no venue behind it, for the tests and for the debug
// converters that run without a venue open. Provenance: shader metadata read
// out of the Moosylvania fixture venue, carrying no texture or geometry
// payload. See credits.txt. A real export refuses to run on this.
D3_FIXTURE_MATERIALS :: #load("../../assets/d3/moosylvania-materials.pssg")
D3_FIXTURE_ID :: "fixture"

// The two files a pack is made of.
D3_PROFILE_FILE :: "profile.txt"
D3_MATERIALS_FILE :: "materials.pssg"

// A pack is shared and outlives the build that wrote it, so it says which build
// that was. Raise this whenever the extraction changes, and every pack already
// on disk is rebuilt instead of silently reused.
D3_PACK_STAMP :: 4

// The profile's row names. Two tables because the two enums are two keyspaces,
// spelling the same four names today: every surface that exists also has a look
// of its own. A drawn-only material joins the first table and not the second.
D3_DRAW_KEY := [Draw_Material]string {
	.Road       = "road",
	.Cliff      = "cliff",
	.Terrain    = "terrain",
	.Road_Paved = "road_paved",
}

D3_SURFACE_KEY := [Collision_Surface]string {
	.Road       = "road",
	.Cliff      = "cliff",
	.Terrain    = "terrain",
	.Road_Paved = "road_paved",
}

D3_Venue_Profile :: struct {
	id:        string,
	pack:      int,
	template:  []u8,
	visual:    [Draw_Material]string,
	colour:    [Draw_Material][4]u8,
	// The far end of the material's texture mix. A drawn vertex gets
	// `lerp(colour, colour_b, blend)`, so `colour_b == colour` switches the mix
	// off and reproduces a single-texture surface byte for byte. See
	// geo.Tri_Mesh.blend.
	colour_b:  [Draw_Material][4]u8,
	lod:       string,
	batch:     string,
	tiles_x:   int,
	tiles_z:   int,
	// The texture the paved material was built from, recorded so a palette edit
	// can be spotted: the material lives inside materials.pssg, so changing the
	// texture means rebuilding the pack, not rewriting a row. Empty means the
	// venue offered none and the paved road draws with the loose road's art.
	paved_texture: string,
	collision: [Collision_Surface]string,
}

D3_Profile_Field :: enum {
	Visual,
	Colour,
	Colour_B,
	Collision,
}

d3_hex_nibble :: proc(c: u8) -> (u8, bool) {
	if c >= '0' && c <= '9' { return c-'0', true }
	if c >= 'a' && c <= 'f' { return c-'a'+10, true }
	if c >= 'A' && c <= 'F' { return c-'A'+10, true }
	return 0, false
}

d3_colour_parse :: proc(text: string) -> (out: [4]u8, ok: bool) {
	if len(text) != 8 { return out, false }
	for i in 0..<4 { hi,a:=d3_hex_nibble(text[i*2]); lo,b:=d3_hex_nibble(text[i*2+1]); if !a||!b{return out,false}; out[i]=hi<<4|lo }
	return out, true
}

// `road`, `road_colour` and `road_collision` all address the Road rows. Which
// keyspace the name lands in is decided by the suffix: `_collision` names a
// surface, everything else names a drawn material. The two tables spell the same
// names today and are free to stop.
d3_profile_field :: proc(key: string) -> (name: string, field: D3_Profile_Field) {
	name = key
	if strings.has_suffix(key, "_colour_b")  { name = strings.trim_suffix(key, "_colour_b");  field = .Colour_B }
	if strings.has_suffix(key, "_colour")    { name = strings.trim_suffix(key, "_colour");    field = .Colour }
	if strings.has_suffix(key, "_collision") { name = strings.trim_suffix(key, "_collision"); field = .Collision }
	return
}

d3_draw_material :: proc(name: string) -> (Draw_Material, bool) {
	for candidate in Draw_Material {
		if D3_DRAW_KEY[candidate] == name { return candidate, true }
	}
	return .Road, false
}

d3_collision_surface :: proc(name: string) -> (Collision_Surface, bool) {
	for candidate in Collision_Surface {
		if D3_SURFACE_KEY[candidate] == name { return candidate, true }
	}
	return .Road, false
}

d3_profile_assign :: proc(profile: ^D3_Venue_Profile, field, value: string) -> (msg: string, ok: bool) {
	switch field {
	case "lod":   profile.lod = value;   return "", true
	case "batch": profile.batch = value; return "", true
	case "pack":
		stamp, parsed := strconv.parse_int(value)
		if !parsed { return fmt.tprintf("malformed pack stamp %s in Dirt 3 profile", value), false }
		profile.pack = stamp
		return "", true
	case "paved_texture":
		profile.paved_texture = value
		return "", true
	case "tiles_x", "tiles_z":
		count, parsed := strconv.parse_int(value)
		if !parsed || count < 1 { return fmt.tprintf("malformed tile count %s in Dirt 3 profile", field), false }
		if field == "tiles_x" { profile.tiles_x = count } else { profile.tiles_z = count }
		return "", true
	}
	// A row this build does not know is ignored, not refused: a profile written
	// by a later one has to stay loadable.
	name, kind := d3_profile_field(field)
	switch kind {
	case .Collision:
		if surface, known := d3_collision_surface(name); known { profile.collision[surface] = value }
	case .Visual:
		if material, known := d3_draw_material(name); known { profile.visual[material] = value }
	case .Colour, .Colour_B:
		material, known := d3_draw_material(name)
		if !known { break }
		colour, parsed := d3_colour_parse(value)
		if !parsed { return fmt.tprintf("malformed colour %s in Dirt 3 profile", field), false }
		if kind == .Colour { profile.colour[material] = colour } else { profile.colour_b[material] = colour }
	}
	return "", true
}

d3_profile_complete :: proc(profile: D3_Venue_Profile) -> (msg: string, ok: bool) {
	if len(profile.template) < 8 || profile.lod == "" || profile.batch == "" {
		return "incomplete Dirt 3 profile", false
	}
	if profile.tiles_x < 1 || profile.tiles_z < 1 || profile.tiles_x*profile.tiles_z > D3_TILE_MAX {
		return fmt.tprintf("a Dirt 3 profile must name a tile grid of at most %d cells", D3_TILE_MAX), false
	}
	for material in Draw_Material {
		if profile.visual[material] == "" { return "incomplete Dirt 3 material mapping", false }
	}
	for surface in Collision_Surface {
		if profile.collision[surface] == "" { return "incomplete Dirt 3 surface mapping", false }
	}
	return "", true
}

// The profile's strings all point into one clone of `raw`, so the whole profile
// lives exactly as long as `allocator` does.
d3_profile_parse :: proc(
	raw: string,
	template: []u8,
	allocator := context.temp_allocator,
) -> (
	profile: D3_Venue_Profile,
	msg: string,
	ok: bool,
) {
	profile.template = template
	// Colours seed from the defaults, so a profile written before a colour field
	// existed reads as that default instead of as black. The stamp deliberately
	// does not seed: a file with no stamp has to read as stale. See D3_PACK_STAMP.
	defaults := d3_profile_defaults()
	profile.colour = defaults.colour
	profile.colour_b = defaults.colour_b
	text := strings.clone(raw, allocator)
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "#") { continue }
		eq := strings.index_byte(line, '=')
		if eq < 0 { return profile, "malformed Dirt 3 profile", false }
		key := strings.trim_space(line[:eq]); value := strings.trim_space(line[eq+1:])
		if key == "default" {
			profile.id = value
			continue
		}
		if profile.id == "" { return profile, "a Dirt 3 profile must name its default venue first", false }
		if !strings.has_prefix(key, profile.id) { continue }
		field := key[len(profile.id):]
		if !strings.has_prefix(field, ".") { continue }
		if assign_msg,assigned := d3_profile_assign(&profile, field[1:], value); !assigned {
			return profile, assign_msg, false
		}
	}
	msg, ok = d3_profile_complete(profile)
	return
}

// The same grammar the parser reads, so a profile survives a round trip through
// disk unchanged.
d3_profile_text :: proc(profile: D3_Venue_Profile, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Written by dirtbench from the base venue's tracksplit.pssg.\n")
	fmt.sbprintf(&b, "default = %s\n", profile.id)
	fmt.sbprintf(&b, "%s.pack = %d\n", profile.id, profile.pack)
	strings.write_string(&b, "\n# What draws each material: a SHADERINSTANCE id in materials.pssg beside\n")
	strings.write_string(&b, "# this file, and the two ends of its texture mix as argb.\n")
	for material in Draw_Material {
		key := D3_DRAW_KEY[material]
		colour := profile.colour[material]
		colour_b := profile.colour_b[material]
		fmt.sbprintf(&b, "%s.%s = %s\n", profile.id, key, profile.visual[material])
		fmt.sbprintf(
			&b,
			"%s.%s_colour = %02x%02x%02x%02x\n",
			profile.id, key, colour[0], colour[1], colour[2], colour[3],
		)
		fmt.sbprintf(
			&b,
			"%s.%s_colour_b = %02x%02x%02x%02x\n",
			profile.id, key, colour_b[0], colour_b[1], colour_b[2], colour_b[3],
		)
	}
	strings.write_string(&b, "\n# How each surface drives: a four-character code from surface_materials.xml\n")
	strings.write_string(&b, "# at the install root. A separate list, because a material and a surface are\n")
	strings.write_string(&b, "# not the same thing — see Draw_Material in d3/api.odin.\n")
	for surface in Collision_Surface {
		fmt.sbprintf(
			&b, "%s.%s_collision = %s\n",
			profile.id, D3_SURFACE_KEY[surface], profile.collision[surface],
		)
	}
	strings.write_string(&b, "\n")
	fmt.sbprintf(&b, "%s.paved_texture = %s\n", profile.id, profile.paved_texture)
	fmt.sbprintf(&b, "%s.tiles_x = %d\n", profile.id, profile.tiles_x)
	fmt.sbprintf(&b, "%s.tiles_z = %d\n", profile.id, profile.tiles_z)
	fmt.sbprintf(&b, "%s.lod = %s\n", profile.id, profile.lod)
	fmt.sbprintf(&b, "%s.batch = %s\n", profile.id, profile.batch)
	return strings.to_string(b)
}

// Everything a profile holds that the base venue does not decide: how a
// material is tinted, which collision code it maps to, and how the route is
// tiled. `visual`, `lod`, `batch` and `id` are the base venue's to fill in.
d3_profile_defaults :: proc() -> (profile: D3_Venue_Profile) {
	profile.pack = D3_PACK_STAMP
	profile.tiles_x = 8
	profile.tiles_z = 4
	for material in Draw_Material { profile.colour[material] = {0x00, 0xff, 0xff, 0x00} }
	for surface in Collision_Surface { profile.collision[surface] = "GLD*" }
	profile.colour[.Terrain] = {0x00, 0xff, 0x00, 0x00}
	profile.collision[.Terrain] = "GRS*"
	profile.collision[.Cliff] = "ROK*"
	// Tarmac is in 18 of the 22 stock venues. The four without it are the snow
	// ones, whose hard surface is concrete; their palette says so.
	profile.collision[.Road_Paved] = "TSD*"
	// A surface with nothing to fade into keeps one texture: colour_b == colour.
	profile.colour_b = profile.colour
	// The road edge takes the value stock gives its grass materials. Both bytes
	// are measured off stock infield instances rather than invented, which is the
	// rule for this channel — an invented value draws black or blown-out ground.
	// Which channel the shader reads, and which way, is what the first drive on a
	// painted road settles; see docs/dirt3-pssg.md.
	profile.colour_b[.Road] = profile.colour[.Terrain]
	profile.colour_b[.Road_Paved] = profile.colour[.Terrain]
	return
}

// The venue-less profile. Tests and the debug converters use it; a stage export
// takes the open venue's profile instead.
d3_profile_fixture :: proc() -> (profile: D3_Venue_Profile, msg: string, ok: bool) {
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
