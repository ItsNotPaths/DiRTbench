package main

// The Dirt 3 target's card billboards: the stage's cards (geo/billboards.odin)
// grafted into the venue's own `trees.pssg` (d3/tree_cloud.odin) and handed on as
// placements.
//
// The art is the pack's: a deployed venue directory holds either the stock
// venue's `trees.pssg` or the pack's copy out of `local/`, decided once per entry
// at deploy time (content_pack.odin), so reading what is there is what makes this
// pack-correct.
//
// Read the **live** file, never the `.orig`. `trees.pssg` is venue-scoped and the
// clouds are per route, so a route strips the clouds under its own prefix and
// leaves every other root standing. Taking the donor would wipe another stage's
// clouds while its `trees.bin` still named them, and a placement naming a missing
// mesh hangs the load.
//
// `track.vis` needs nothing: the census reads `trees.bin` after this has run
// (d3/track_vis.odin), so each cloud gets its tag-3 box and mask bit for free.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import d3 "../d3"
import "../geo"

// How much road one cloud covers. A cloud is one drawable with one box: a single
// cloud over a whole stage would never cull, and stock sections its own into 6 to
// 18 per route.
D3_BILLBOARD_CHUNK_M :: f32(1000)
// And a hard ceiling per cloud, under the writer's own `ushort` cap so a dense
// chunk splits rather than failing the export.
D3_BILLBOARD_CHUNK_CARDS :: 12000

// The prefix every id of this route's clouds starts with, which is what a
// re-export strips and what keeps two stages of one venue out of each other's way.
d3_billboard_prefix :: proc(route_index: int) -> string {
	return fmt.tprintf("dirtbench_bb_r%d_", route_index)
}

// The card shapes one tier's template offers. Empty when the venue's art has no
// cloud of that tier to clone, which is a reason to write no cards rather than an
// error: shibuya ships none, and nor need a pack.
d3_billboard_kinds :: proc(
	templates: []d3.Billboard_Template, band: bool, allocator := context.temp_allocator,
) -> []geo.Billboard_Kind {
	template, ok := d3.billboard_template_pick(templates, band)
	if !ok {
		return nil
	}
	sizes := d3.billboard_template_sizes(template, context.temp_allocator)
	out := make([]geo.Billboard_Kind, len(sizes), allocator)
	for size, i in sizes {
		out[i] = {size[0], size[1]}
	}
	return out
}

// Cards to clouds: one cloud per tier per chunk of road. `cards` is sorted by arc
// in place, so a cloud's box covers one stretch of road rather than the whole
// stage.
d3_billboard_chunks :: proc(
	cards: []geo.Billboard_Card, allocator := context.temp_allocator,
) -> (out: [][]geo.Billboard_Card) {
	slice.sort_by(cards, proc(a, b: geo.Billboard_Card) -> bool {
		if a.tier != b.tier {
			return a.tier < b.tier
		}
		return a.arc < b.arc
	})
	chunks := make([dynamic][]geo.Billboard_Card, allocator)
	start := 0
	for i in 1 ..= len(cards) {
		split := i == len(cards)
		if !split {
			split = cards[i].tier != cards[start].tier ||
			        cards[i].arc - cards[start].arc > D3_BILLBOARD_CHUNK_M ||
			        i - start >= D3_BILLBOARD_CHUNK_CARDS
		}
		if split {
			append(&chunks, cards[start:i])
			start = i
		}
	}
	return chunks[:]
}

// One chunk as places in a cloud's local space, plus where that cloud stands.
//
// The template's card list and the generator's kind list are the same list in the
// same order (d3_billboard_kinds), so a card's `kind` is its template index.
d3_billboard_places :: proc(
	chunk: []geo.Billboard_Card, allocator := context.temp_allocator,
) -> (places: []d3.Billboard_Place, centre: [3]f32) {
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	for card in chunk {
		p := [3]f32{card.pos.x, card.pos.y, card.pos.z}
		for axis in 0 ..< 3 {
			lo[axis] = min(lo[axis], p[axis])
			hi[axis] = max(hi[axis], p[axis])
		}
	}
	centre = (lo + hi) * 0.5
	places = make([]d3.Billboard_Place, len(chunk), allocator)
	for card, i in chunk {
		places[i] = {
			pos   = [3]f32{card.pos.x, card.pos.y, card.pos.z} - centre,
			card  = card.kind,
			scale = card.scale,
		}
	}
	return
}

// Write this route's clouds into the venue's `trees.pssg` and say what they are.
//
// No clouds and no error when there is nothing to write: the checkbox is off, or
// the venue's art ships no card cloud to clone. A previous export's clouds are
// stripped either way, so turning the checkbox off and exporting removes them.
d3_write_billboards :: proc(
	venue_dir: string,
	stage: ^Export_Geometry,
	veg: geo.Veg_Params,
	roughness: f32,
	// The scatter this stage places. The near tier stands where these are not, so
	// it is the same list the placement files were given and not a second one.
	trees: []geo.Veg_Instance,
	route_index: int,
	installing: bool,
) -> (
	clouds: []d3.Billboard_Cloud,
	msg: string,
	ok: bool,
) {
	if venue_dir == "" {
		return nil, "not written: a loose road has no venue to hold the art", true
	}
	path, _ := filepath.join({venue_dir, "trees.pssg"}, context.temp_allocator)
	if !os.exists(path) {
		return nil, "not written: this venue has no trees.pssg", true
	}
	// The live file, not `d3.Stock_Path`: see the note at the top of this file.
	lib, lib_msg, opened := d3.prop_lib_open(path, context.temp_allocator)
	if !opened {
		return nil, fmt.tprintf("%s: %s", path, lib_msg), false
	}
	defer d3.prop_lib_delete(&lib, context.temp_allocator)

	prefix := d3_billboard_prefix(route_index)
	dropped := d3.billboard_strip(&lib, prefix, context.temp_allocator)

	templates := d3.billboard_templates(&lib)
	near_kinds := d3_billboard_kinds(templates, false)
	far_kinds := d3_billboard_kinds(templates, true)
	cards := geo.billboards_generate(
		stage.ribbon, &stage.terrain, veg, roughness, trees,
		near_kinds, far_kinds, context.temp_allocator,
	)

	if len(cards) == 0 {
		if dropped == 0 {
			return nil, "not written: nothing to place", true
		}
		if write_msg, wrote := d3_billboard_save(path, &lib, installing); !wrote {
			return nil, write_msg, false
		}
		return nil, fmt.tprintf("%d clouds removed", dropped), true
	}

	written := make([dynamic]d3.Billboard_Cloud, context.temp_allocator)
	counts: [geo.Billboard_Tier]int
	for chunk, i in d3_billboard_chunks(cards) {
		tier := chunk[0].tier
		template, have := d3.billboard_template_pick(templates, tier == .Far)
		if !have {
			continue // the generator was given no kinds for this tier, so this cannot happen
		}
		places, centre := d3_billboard_places(chunk)
		name := fmt.tprintf("%s%s_%02d", prefix, tier == .Far ? "far" : "near", i)
		cloud, cloud_msg, cloud_ok := d3.billboard_cloud_write(
			&lib, template, name, centre, places, context.temp_allocator,
		)
		if !cloud_ok {
			return nil, cloud_msg, false
		}
		append(&written, cloud)
		counts[tier] += cloud.cards
	}
	if write_msg, wrote := d3_billboard_save(path, &lib, installing); !wrote {
		return nil, write_msg, false
	}
	return written[:], fmt.tprintf(
		"%d clouds, %d wall cards and %d tree cards (%d replaced)",
		len(written), counts[.Far], counts[.Near], dropped,
	), true
}

// Serialise the library over the venue's own file. Never in place: a deployed
// `trees.pssg` is a hardlink onto the stock venue's, and a write through it would
// edit the installed game.
@(private = "file")
d3_billboard_save :: proc(path: string, lib: ^d3.Prop_Library, installing: bool) -> (msg: string, ok: bool) {
	data, wrote := d3.pssg_write(&lib.file, context.temp_allocator)
	if !wrote {
		return fmt.tprintf("%s: the grafted library would not serialise", path), false
	}
	if installing {
		if backup_msg, backed := d3.Backup_Once(path); !backed {
			return backup_msg, false
		}
	}
	return d3.atomic_write_file(path, data)
}
