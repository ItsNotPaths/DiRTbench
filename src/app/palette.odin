package main

// A base venue's palette: the part of its art the tool cannot read off the art.
//
//     assets/d3/palettes/<location>_<venue>.txt   baked into the binary
//     build/content-packs/<id>/palette.txt        the pack's own, layered on top
//
// Everything else about a venue's materials is derived — `d3_pack_build` reads
// the base venue's tracksplit and picks a road, a ground and a cliff out of it
// by measurement. Two things resist that, and they are what this file holds.
//
// **A paving texture cannot be found by name.** Codemasters number their road
// textures rather than describing them, so `fin_tra_bas_13_d` (tarmac) reads
// exactly like `fin_tra_bas_01_d` (gravel). Searching shader instance names for
// "tarmac" finds nothing in finland_rally, norway, michigan_trail or kenya_trail:
// Finland keeps its tarmac materials in a *route* file, which the pack never
// opens. Rock got away with a name rule (`_rck_`, `_fea_`); paving does not.
//
// **The code behind "paved" is venue business.** It is `TSD*` in most venues and
// `CON*` in the snow ones, which have no tarmac at all.
//
// A row may be absent, and absent is a real answer rather than a hole: a venue
// with no paving texture draws its paved road with the loose road's material and
// differs only in how it drives.
//
// The baked copies are defaults, not the truth. Anyone shipping a content pack
// of their own drops a `palette.txt` beside its `pack.json` and names their own
// art, without a build of this tool.

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strconv"
import "core:strings"
import "../geo"
import "../gfx"
import d3 "../d3"

PALETTE_FILE :: "palette.txt"
PALETTE_EXT :: ".txt"

// The palettes that ship with the tool, one per base-eligible stock venue.
// Baked rather than installed beside the binary, for the same reason the
// co-driver clips are: a release is one file to copy, and a palette cannot be
// half-installed.
PALETTES := #load_directory("../../assets/d3/palettes")

// A surface's two texture layers, in the order a ground material holds them:
// the first is what it draws at weight 0, the second at weight 1. One name fills
// both, which is a surface that does not blend.
Layers :: struct {
	a, b: string,
}

Palette :: struct {
	loose:           Layers,
	paved:           Layers,
	ground:          Layers,
	paved_collision: string,
	// The editor's own colours for this venue's ground, as `rrggbb`. Viewport
	// only — the game never sees them. Rows the file leaves out keep Finland's,
	// so a palette can restate one colour and inherit the rest.
	look:            geo.Look,
}

// The file name a base venue's palette takes. `<location>/<venue>` cannot be a
// file name, so the separator becomes an underscore.
palette_name :: proc(base: string, allocator := context.temp_allocator) -> string {
	flat, _ := strings.replace_all(base, "/", "_", allocator)
	return strings.concatenate({flat, PALETTE_EXT}, allocator)
}

// Apply `text`'s rows over whatever `out` already holds. Layering rather than
// replacing is what lets a pack override one row and inherit the rest.
//
// Keys outside our namespaces are ignored, so a palette written for a later
// build still loads. Anything under `colour.` that this build cannot use comes
// back in `bad` instead — a bad value or an unknown slot name there is a typo
// far more often than it is a version gap, and a dropped colour is invisible:
// the venue simply draws in Finland's and nothing says why.
palette_apply :: proc(
	text: string,
	out: ^Palette,
	allocator := context.temp_allocator,
) -> (bad: []string) {
	rejected := make([dynamic]string, context.temp_allocator)
	it := Config_Iter{rest = text}
	for key, value in config_next(&it) {
		switch key {
		case "loose.texture":   out.loose.a  = strings.clone(value, allocator)
		case "loose.texture2":  out.loose.b  = strings.clone(value, allocator)
		case "paved.texture":   out.paved.a  = strings.clone(value, allocator)
		case "paved.texture2":  out.paved.b  = strings.clone(value, allocator)
		case "ground.texture":  out.ground.a = strings.clone(value, allocator)
		case "ground.texture2": out.ground.b = strings.clone(value, allocator)
		case "paved.collision": out.paved_collision = strings.clone(value, allocator)
		case:
			if !strings.has_prefix(key, "colour.") { continue }
			slot := palette_colour_slot(&out.look, key[len("colour."):])
			if slot == nil {
				append(&rejected, key)
				continue
			}
			rgb, parsed := palette_rgb(value)
			if !parsed {
				append(&rejected, key)
				continue
			}
			slot^ = rgb
		}
	}
	return rejected[:]
}

// Which colour a `colour.<name>` row writes, or nil for a name this build does
// not know. A pointer rather than an enum and a table: the names are the
// struct's own field names, and one list of them is easier to keep honest than
// two.
palette_colour_slot :: proc(look: ^geo.Look, name: string) -> ^gfx.Color {
	switch name {
	case "road":          return &look.road
	case "road_paved":    return &look.road_paved
	case "terrain":       return &look.terrain
	case "terrain_steep": return &look.terrain_steep
	case "cliff_top":     return &look.cliff_top
	case "cliff_bot":     return &look.cliff_bot
	case "bank":          return &look.bank
	case "gutter":        return &look.gutter
	}
	return nil
}

// `rrggbb`. Opaque always: these are tints on solid ground, and a half-alpha
// one would read as a bug in the viewport rather than as a colour.
palette_rgb :: proc(text: string) -> (out: gfx.Color, ok: bool) {
	if len(text) != 6 { return }
	value, parsed := strconv.parse_u64_of_base(text, 16)
	if !parsed { return }
	return {u8(value >> 16), u8(value >> 8), u8(value), 255}, true
}

// The palette for a base venue: the baked one, then the pack's own over it.
//
// `pack_id` is the content pack directory to look in, which is the base id for
// every pack that exists today. Empty skips the override.
palette_for :: proc(base, pack_id: string, allocator := context.temp_allocator) -> (out: Palette) {
	out.look = geo.DEFAULT_LOOK
	want := palette_name(base, context.temp_allocator)
	for file in PALETTES {
		if file.name != want { continue }
		palette_apply(string(file.data), &out, allocator)
		break
	}
	if pack_id == "" { return }
	path, _ := filepath.join({content_pack_dir(pack_id, context.temp_allocator), PALETTE_FILE}, context.temp_allocator)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		// The baked palettes are checked by their own test. A pack's own file is
		// not, so its rejected rows are said out loud rather than dropped.
		for key in palette_apply(string(data), &out, allocator) {
			fmt.eprintfln("%s: ignoring %s, which is not a colour this build knows", path, key)
		}
	}
	return
}

// What the pack builder needs from the palette while it is cloning materials.
//
// A surface naming one texture gets it in both layers, which is what a material
// with nothing to blend between looks like. A surface naming none keeps whatever
// the venue's own art measured out to, which is how this behaved before the
// palette said anything.
palette_art :: proc(p: Palette) -> d3.Pack_Art {
	pair :: proc(l: Layers) -> [2]string {
		return {l.a, l.b != "" ? l.b : l.a}
	}
	return {loose = pair(p.loose), paved = pair(p.paved), ground = pair(p.ground)}
}

// Lay the palette's rows over a profile the pack build produced. Only the rows
// the palette owns move; everything else stays as the tracksplit measured it.
//
// This runs on every load rather than only on a rebuild, so editing a palette
// takes effect the next time a venue is opened. The one row it cannot fix that
// way is the paving texture, which is baked into a material inside
// materials.pssg — `content_pack_profile` compares it and rebuilds instead.
palette_over_profile :: proc(p: Palette, profile: ^d3.Venue_Profile) {
	if p.paved_collision != "" { profile.collision[.Road_Paved] = p.paved_collision }
}
