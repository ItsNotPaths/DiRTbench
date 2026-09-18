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
D3_PACK_STAMP :: 1

D3_MATERIAL_KEY := [Collision_Material]string {
	.Road      = "road",
	.Cliff     = "cliff",
	.Terrain   = "terrain",
	.Road_Sand = "road_sand",
}

D3_Venue_Profile :: struct {
	id:        string,
	pack:      int,
	template:  []u8,
	visual:    [Collision_Material]string,
	colour:    [Collision_Material][4]u8,
	lod:       string,
	batch:     string,
	tiles_x:   int,
	tiles_z:   int,
	collision: [Collision_Material]string,
}

D3_Profile_Field :: enum {
	Visual,
	Colour,
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

// `road`, `road_colour` and `road_collision` all address the Road material.
d3_profile_field :: proc(key: string) -> (material: Collision_Material, field: D3_Profile_Field, ok: bool) {
	name := key
	if strings.has_suffix(key, "_colour")    { name = strings.trim_suffix(key, "_colour");    field = .Colour }
	if strings.has_suffix(key, "_collision") { name = strings.trim_suffix(key, "_collision"); field = .Collision }
	for candidate in Collision_Material {
		if D3_MATERIAL_KEY[candidate] == name { return candidate, field, true }
	}
	return .Road, field, false
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
	case "tiles_x", "tiles_z":
		count, parsed := strconv.parse_int(value)
		if !parsed || count < 1 { return fmt.tprintf("malformed tile count %s in Dirt 3 profile", field), false }
		if field == "tiles_x" { profile.tiles_x = count } else { profile.tiles_z = count }
		return "", true
	}
	material, kind, known := d3_profile_field(field)
	if !known { return "", true }
	switch kind {
	case .Visual:    profile.visual[material] = value
	case .Collision: profile.collision[material] = value
	case .Colour:
		colour, parsed := d3_colour_parse(value)
		if !parsed { return fmt.tprintf("malformed colour %s in Dirt 3 profile", field), false }
		profile.colour[material] = colour
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
	for material in Collision_Material {
		if profile.visual[material] == "" || profile.collision[material] == "" {
			return "incomplete Dirt 3 material mapping", false
		}
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
	strings.write_string(&b, "# Values are PSSG SHADERINSTANCE ids in materials.pssg beside this file.\n")
	fmt.sbprintf(&b, "default = %s\n", profile.id)
	fmt.sbprintf(&b, "%s.pack = %d\n", profile.id, profile.pack)
	for material in Collision_Material {
		key := D3_MATERIAL_KEY[material]
		colour := profile.colour[material]
		fmt.sbprintf(&b, "%s.%s = %s\n", profile.id, key, profile.visual[material])
		fmt.sbprintf(
			&b,
			"%s.%s_colour = %02x%02x%02x%02x\n",
			profile.id, key, colour[0], colour[1], colour[2], colour[3],
		)
		fmt.sbprintf(&b, "%s.%s_collision = %s\n", profile.id, key, profile.collision[material])
	}
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
	for material in Collision_Material {
		profile.colour[material] = {0x00, 0xff, 0xff, 0x00}
		profile.collision[material] = "GLD*"
	}
	profile.colour[.Terrain] = {0x00, 0xff, 0x00, 0x00}
	profile.collision[.Terrain] = "GRS*"
	profile.collision[.Cliff] = "ROK*"
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
	for material in Collision_Material { profile.visual[material] = "dirt_pebbles_01" }
	profile.visual[.Terrain] = "grass_01"
	msg, ok = d3_profile_complete(profile)
	return
}
