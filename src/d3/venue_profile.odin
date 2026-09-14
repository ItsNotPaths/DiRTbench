package d3

// Venue-specific graphics data is embedded as a deliberately small profile:
// shader metadata and texture names, never texture or model payloads. Adding a
// venue is data work, one more template plus its manifest rows.

import "core:fmt"
import "core:strconv"
import "core:strings"

D3_PROFILE_TEXT :: #load("../../assets/d3/profiles.txt")
D3_MOOSYLVANIA_MATERIALS :: #load("../../assets/d3/moosylvania-materials.pssg")

D3_MATERIAL_KEY := [Collision_Material]string {
	.Road      = "road",
	.Cliff     = "cliff",
	.Terrain   = "terrain",
	.Road_Sand = "road_sand",
}

D3_Venue_Profile :: struct {
	id:        string,
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
	case "tiles_x", "tiles_z":
		count, parsed := strconv.parse_int(value)
		if !parsed || count < 1 { return fmt.tprintf("malformed tile count %s in built-in Dirt 3 profile", field), false }
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
		if !parsed { return fmt.tprintf("malformed colour %s in built-in Dirt 3 profile", field), false }
		profile.colour[material] = colour
	}
	return "", true
}

d3_profile_complete :: proc(profile: D3_Venue_Profile) -> (msg: string, ok: bool) {
	if len(profile.template) < 8 || profile.lod == "" || profile.batch == "" {
		return "incomplete built-in Dirt 3 profile", false
	}
	// The cap goes when we generate track.vis ourselves; until then a stage
	// owns exactly the tag-0 slots the donor route already had.
	if profile.tiles_x < 1 || profile.tiles_z < 1 || profile.tiles_x*profile.tiles_z > D3_TILE_MAX {
		return fmt.tprintf("built-in Dirt 3 profile must name a tile grid of at most %d cells", D3_TILE_MAX), false
	}
	for material in Collision_Material {
		if profile.visual[material] == "" || profile.collision[material] == "" {
			return "incomplete built-in Dirt 3 material mapping", false
		}
	}
	return "", true
}

d3_profile_builtin :: proc() -> (profile: D3_Venue_Profile, msg: string, ok: bool) {
	profile.template = transmute([]u8)D3_MOOSYLVANIA_MATERIALS
	text := string(D3_PROFILE_TEXT)
	prefix: string
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") { continue }
		eq := strings.index_byte(line, '=')
		if eq < 0 { return profile, "malformed built-in Dirt 3 profile", false }
		key := strings.trim_space(line[:eq]); value := strings.trim_space(line[eq+1:])
		if key == "default" {
			profile.id = value
			prefix = strings.concatenate({value,"."}, context.temp_allocator)
			continue
		}
		if prefix == "" { return profile, "built-in Dirt 3 profile must name its default venue first", false }
		if !strings.has_prefix(key, prefix) { continue }
		if assign_msg,assigned := d3_profile_assign(&profile, key[len(prefix):], value); !assigned {
			return profile, assign_msg, false
		}
	}
	msg, ok = d3_profile_complete(profile)
	return
}
