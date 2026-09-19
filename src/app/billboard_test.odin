package main

// The card generator (geo/billboards.odin). What it has to get right is where a
// card stands, because a card in the wrong place is either inside the road, or
// floating, or not covering the void it exists to cover.

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import d3 "../d3"
import "../geo"
import "../gfx"

// The near tier's cards are 8 m wide, the wall's are 55 m: the two tiers as
// stock ships them.
@(private = "file")
NEAR_KINDS := []geo.Billboard_Kind{{8, 20}}
@(private = "file")
FAR_KINDS := []geo.Billboard_Kind{{55, 28}}

@(private = "file")
road_up_z :: proc(rise: f32) -> (sp: geo.Spline) {
	for z in ([]f32{0, 80, 160, 240, 320}) {
		pos := gfx.Vector3{0, rise * z / 320, z}
		geo.spline_push(
			&sp,
			geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = len(sp.points) - 1),
		)
	}
	return
}

// A road that forks and doubles back alongside itself, with two dead ends: the
// shape that catches a card cast from one leg onto another.
@(private = "file")
fork_road :: proc() -> (sp: geo.Spline) {
	seeds := [?]struct{pos: gfx.Vector3, parent: int}{
		{{0, 0, 0}, -1},
		{{0, 0, 80}, 0},
		{{0, 0, 160}, 1},
		{{40, 0, 120}, 1},
		{{40, 0, 40}, 3},
	}
	for s in seeds {
		rot := gfx.Quaternion(1)
		if s.parent >= 0 {
			rot = geo.heading_quat(seeds[s.parent].pos, s.pos)
		}
		geo.spline_push(&sp, geo.make_point(s.pos, rot, geo.DEFAULT_WIDTH, parent = s.parent))
	}
	return
}

@(private = "file")
Fixture :: struct {
	sp:     geo.Spline,
	ribbon: []geo.Cross_Section,
	terr:   geo.Terrain,
	seam_x: f32, // how far out the verge seam sits, on a road up +Z at x = 0
}

@(private = "file")
fixture_make :: proc(rise: f32 = 0) -> (f: Fixture) {
	return fixture_of(road_up_z(rise))
}

@(private = "file")
fixture_of :: proc(sp: geo.Spline) -> (f: Fixture) {
	f.sp = sp
	f.ribbon = geo.build_ribbon(f.sp, geo.SAMPLES_PER_SEG, context.allocator)
	f.terr = geo.TERRAIN_DEFAULTS
	f.terr.enabled = true
	geo.terrain_ensure(&f.terr, f.ribbon, 0)
	ds := geo.sample_spacing(f.ribbon)
	mid := len(f.ribbon) / 2
	f.seam_x = abs(geo.verge_seam(f.ribbon[mid], 0, geo.VERGE_ROWS, 0).x)
	return
}

@(private = "file")
fixture_delete :: proc(f: ^Fixture) {
	geo.terrain_delete(&f.terr)
	delete(f.ribbon)
	delete(f.sp.points)
}

// Every card of one tier, with the scatter the stage would really have under it:
// the near tier's rule is "where the trees are not".
@(private = "file")
cards_of :: proc(
	f: ^Fixture, veg: geo.Veg_Params, tier: geo.Billboard_Tier,
) -> []geo.Billboard_Card {
	trees := geo.veg_generate(f.ribbon, &f.terr, veg, 0)
	defer delete(trees)
	all := geo.billboards_generate(f.ribbon, &f.terr, veg, 0, trees, NEAR_KINDS, FAR_KINDS)
	defer delete(all)
	out := make([dynamic]geo.Billboard_Card, context.temp_allocator)
	for c in all {
		if c.tier == tier {
			append(&out, c)
		}
	}
	return out[:]
}

// The field the generator measures against, so a test can ask the same question.
@(private = "file")
field_of :: proc(f: ^Fixture) -> geo.Veg_Field {
	arc := geo.ribbon_arc(f.ribbon)
	return geo.veg_field_make(&f.terr, f.ribbon, arc, geo.sample_spacing(f.ribbon), 0)
}

// The wall stands in the void and nowhere else: past where the terrain gives out,
// or at most BILLBOARD_RIM_IN inside its bare edge. Measured against the *nearest*
// leg, because on a fork a fixed offset from one verge lands in another leg's
// terrain.
@(test)
the_wall_stands_only_in_the_void :: proc(t: ^testing.T) {
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.5, road_bias = 0.5, seed = 3}
	for road, which in ([]geo.Spline{road_up_z(0), fork_road()}) {
		f := fixture_of(road)
		defer fixture_delete(&f)
		vf := field_of(&f)

		cards := cards_of(&f, veg, .Far)
		testing.expectf(t, len(cards) > 20, "road %d: only %d wall cards", which, len(cards))
		on_terrain := 0
		for c in cards {
			su, in_range := geo.veg_field_su(&vf, {c.pos.x, c.pos.z})
			if !in_range {
				continue // deep void, which is exactly where a wall belongs
			}
			if su < f.terr.reach_m - geo.BILLBOARD_RIM_IN {
				on_terrain += 1
			}
			testing.expectf(t, su <= f.terr.reach_m + geo.BILLBOARD_WALL_M,
				"road %d: a wall card stands %.1f m out, past the %.0f m band",
				which, su, geo.BILLBOARD_WALL_M)
		}
		testing.expectf(t, on_terrain == 0,
			"road %d: %d of %d wall cards stand on terrain rather than in the void",
			which, on_terrain, len(cards))
	}
}

// And it closes at the ends. A stage whose wall runs down both verges and stops is
// open exactly where the driver is parked and looking around.
@(test)
the_wall_closes_at_both_ends :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)
	veg := geo.Veg_Params{billboards = true, density = 0.5, seed = 3}
	cards := cards_of(&f, veg, .Far)

	// Straight ahead of each end, where no verge ray can reach.
	behind, ahead := 0, 0
	for c in cards {
		if abs(c.pos.x) > 30 {
			continue
		}
		if c.pos.z < -f.terr.reach_m {
			behind += 1
		}
		if c.pos.z > 320 + f.terr.reach_m {
			ahead += 1
		}
	}
	testing.expectf(t, behind > 0 && ahead > 0,
		"the wall caps the start with %d cards and the finish with %d", behind, ahead)
}

// The wall follows the ground. Its height is probed just inside the terrain's edge
// and carried out, so on a road that climbs 40 m the far end's cards climb with it
// — a constant height would mean it is standing on the venue floor instead, which
// is where the silhouette it hides comes from.
@(test)
the_wall_follows_the_ground :: proc(t: ^testing.T) {
	f := fixture_make(40)
	defer fixture_delete(&f)
	veg := geo.Veg_Params{billboards = true, density = 0.5, seed = 3}
	cards := cards_of(&f, veg, .Far)

	low, high := f32(0), f32(0)
	lows, highs := 0, 0
	for c in cards {
		base := c.pos.y - c.h * 0.5
		if c.pos.z > 0 && c.pos.z < 60 {
			low += base
			lows += 1
		}
		if c.pos.z > 260 && c.pos.z < 320 {
			high += base
			highs += 1
		}
	}
	testing.expect(t, lows > 0 && highs > 0, "the wall does not run the length of the stage")
	climb := high / f32(highs) - low / f32(lows)
	testing.expectf(t, climb > 20,
		"the road climbs 40 m and the wall climbs %.1f m — it is not standing on the ground",
		climb)
}

// The near tier stands on terrain, and only where the model trees do not. Both
// halves matter: a card past the reach is floating over the void, which is the
// wall's job, and a card inside a tree is two things drawn in one place.
@(test)
near_cards_go_on_terrain_where_trees_are_not :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)
	vf := field_of(&f)
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.5, road_bias = 0.6, seed = 3}

	trees := geo.veg_generate(f.ribbon, &f.terr, veg, 0)
	defer delete(trees)
	cards := cards_of(&f, veg, .Near)
	testing.expect(t, len(cards) > 0, "no tree cards at all")

	for c in cards {
		su, in_range := geo.veg_field_su(&vf, {c.pos.x, c.pos.z})
		testing.expectf(t, in_range && su > 0 && su <= f.terr.reach_m,
			"a tree card stands %.1f m out, off the terrain it is supposed to be on", su)
		for tree in trees {
			d := math.hypot(c.pos.x - tree.pos.x, c.pos.z - tree.pos.z)
			testing.expectf(t, d >= tree.r + c.w * 0.5 - 0.01,
				"a %.1f m card stands %.1f m from the middle of a tree %.1f m across",
				c.w, d, tree.r * 2)
		}
	}
}

// Which is a rule with two ends. Thin the scatter out and the cards take over the
// ground it left; thicken it until the trees touch and there is nothing for them
// to do.
@(test)
near_cards_fill_in_for_missing_trees :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)

	base := geo.Veg_Params{enabled = true, billboards = true, density = 0.5, seed = 3}
	sparse, dense, none := base, base, base
	sparse.density = 0
	dense.density = 1
	none.enabled = false

	n_sparse := len(cards_of(&f, sparse, .Near))
	n_dense := len(cards_of(&f, dense, .Near))
	n_none := len(cards_of(&f, none, .Near))

	testing.expectf(t, n_dense < n_sparse,
		"a dense forest left %d cards and a sparse one %d — the trees are not being seen at all",
		n_dense, n_sparse)
	testing.expectf(t, n_none >= n_sparse,
		"with no trees at all %d cards were placed, against %d for a sparse scatter",
		n_none, n_sparse)
}

// Nothing lands on a road, on any leg of one. A card is cast outward from one
// verge, which on a branched route aims it at another leg's carriageway.
@(test)
no_card_lands_on_the_road :: proc(t: ^testing.T) {
	f := fixture_of(fork_road())
	defer fixture_delete(&f)
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 1, road_bias = 1, seed = 5}

	trees := geo.veg_generate(f.ribbon, &f.terr, veg, 0)
	defer delete(trees)
	cards := geo.billboards_generate(f.ribbon, &f.terr, veg, 0, trees, NEAR_KINDS, FAR_KINDS)
	defer delete(cards)
	testing.expect(t, len(cards) > 0, "nothing to test")

	for c in cards {
		for cs in f.ribbon {
			d := math.hypot(c.pos.x - cs.pos.x, c.pos.z - cs.pos.z)
			testing.expectf(t, d > cs.width * 0.5,
				"a %v card stands %.1f m from the centre of a %.1f m road", c.tier, d, cs.width)
		}
	}
}

// A branch is no denser than a straight road. Every leg casts over its own ground
// and the legs meeting at a junction cover the same ground twice.
@(test)
a_branch_is_no_denser_than_a_straight_road :: proc(t: ^testing.T) {
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 1, road_bias = 1, seed = 9}

	worst :: proc(sp: geo.Spline, veg: geo.Veg_Params, tier: geo.Billboard_Tier) -> int {
		f := fixture_of(sp)
		defer fixture_delete(&f)
		cells := make(map[[2]i32]int, 0, context.temp_allocator)
		defer delete(cells)
		out := 0
		for c in cards_of(&f, veg, tier) {
			key := [2]i32{i32(math.floor(c.pos.x / 8)), i32(math.floor(c.pos.z / 8))}
			cells[key] += 1
			out = max(out, cells[key])
		}
		return out
	}

	for tier in geo.Billboard_Tier {
		branch, straight := worst(fork_road(), veg, tier), worst(road_up_z(0), veg, tier)
		testing.expectf(t, branch <= straight + 2,
			"a branch packs %d %v cards into 8 m of ground where a straight road packs %d",
			branch, tier, straight)
	}
}

// Same seed, same cards. The list is not saved, it is regenerated on every load
// and on every export, so a drifting generator moves the forest under the driver.
@(test)
cards_are_deterministic :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.7, road_bias = 0.8, seed = 4}
	trees := geo.veg_generate(f.ribbon, &f.terr, veg, 0)
	defer delete(trees)

	a := geo.billboards_generate(f.ribbon, &f.terr, veg, 0, trees, NEAR_KINDS, FAR_KINDS)
	defer delete(a)
	b := geo.billboards_generate(f.ribbon, &f.terr, veg, 0, trees, NEAR_KINDS, FAR_KINDS)
	defer delete(b)

	testing.expectf(t, len(a) == len(b), "%d cards one run and %d the next", len(a), len(b))
	if len(a) != len(b) {
		return
	}
	testing.expect(t, slice.equal(a, b), "the same seed placed the cards differently")
}

// A venue with no trees.pssg is not an error. The checkbox is a request, and a
// stage that cannot honour it still has to export.
@(test)
a_venue_with_no_tree_art_still_exports :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)
	stage := Export_Geometry{ribbon = f.ribbon, terrain = f.terr}
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.5, seed = 1}

	clouds, msg, ok := d3_write_billboards(
		"build/out/billboard-test-empty", &stage, veg, 0, nil, 0, false,
	)
	testing.expectf(t, ok, "a venue with no trees.pssg failed the export: %s", msg)
	testing.expect_value(t, len(clouds), 0)

	// And so is a loose road, which has no venue directory at all.
	_, loose_msg, loose_ok := d3_write_billboards("", &stage, veg, 0, nil, 0, false)
	testing.expectf(t, loose_ok, "a loose road failed the export: %s", loose_msg)
}

// With the terrain switched off there is no field to read a height from. Cards
// still go out, riding the verge seam, because the void is wider than ever.
@(test)
cards_ride_the_verge_with_no_terrain :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_delete(&f)
	f.terr.enabled = false
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.5, seed = 1}

	cards := cards_of(&f, veg, .Far)
	testing.expect(t, len(cards) > 0, "no wall without terrain")
	for c in cards {
		base := c.pos.y - c.h * 0.5
		testing.expectf(t, abs(base + geo.BILLBOARD_SINK) < 30,
			"a wall card's base sits at %.1f m with the road at 0", base)
	}
}

// Finland Trail's own `trees.pssg`, off the machine-local install. Absent in a
// release environment, and the tests that want it skip rather than fail.
//
// The checkout's own config, not `conf_get`: that one looks beside the running
// binary, and a test binary lives in a temp directory of its own.
@(private = "file")
stock_trees_pssg :: proc() -> (path: string, ok: bool) {
	conf, _ := filepath.join({"build", CONF_NAME}, context.temp_allocator)
	data, err := os.read_entire_file(conf, context.temp_allocator)
	if err != nil {
		return "", false
	}
	root := ""
	it := Config_Iter{string(data)}
	for key, value in config_next(&it) {
		if key == D3_INSTALL_KEY {
			root = value
		}
	}
	if root == "" {
		return "", false
	}
	path, _ = filepath.join(
		{root, d3.LOCATIONS_SUBDIR, "finland/finland_trail/trees.pssg"}, context.temp_allocator,
	)
	return path, os.exists(path)
}

// --- clouds -------------------------------------------------------------------

@(private = "file")
test_card :: proc(tier: geo.Billboard_Tier, arc: f32) -> geo.Billboard_Card {
	return {pos = {arc, 0, 0}, tier = tier, kind = 0, scale = 1, w = 55, h = 28, arc = arc}
}

// One cloud is one drawable with one box, so a cloud covers a stretch of road
// rather than a stage: a box over the whole stage never culls. The tiers never
// share a cloud either — one RENDERSTREAMINSTANCE names one material, and their
// sheets differ.
@(test)
clouds_are_chunked_by_tier_and_by_road :: proc(t: ^testing.T) {
	cards := make([dynamic]geo.Billboard_Card, context.temp_allocator)
	for m in 0 ..< 60 {
		append(&cards, test_card(.Far, f32(m) * 100))  // 6 km of wall
		append(&cards, test_card(.Near, f32(m) * 100))
	}
	chunks := d3_billboard_chunks(cards[:])

	testing.expect(t, len(chunks) >= 12, "6 km of stage came out as one cloud a tier")
	for chunk in chunks {
		testing.expect(t, len(chunk) > 0, "an empty cloud")
		span := chunk[len(chunk) - 1].arc - chunk[0].arc
		testing.expectf(t, span <= D3_BILLBOARD_CHUNK_M,
			"a cloud covers %.0f m of road, past the %.0f m chunk", span, D3_BILLBOARD_CHUNK_M)
		testing.expect(t, len(chunk) <= D3_BILLBOARD_CHUNK_CARDS, "a cloud is over the card cap")
		for card in chunk {
			testing.expect(t, card.tier == chunk[0].tier, "one cloud carries both tiers")
		}
	}
}

// A cloud's cards are written in its own local space, around the centre its
// instance stands at. The bounds a reference row quotes are local too, so a wrong
// centre puts the whole forest somewhere else.
@(test)
a_cloud_is_written_around_its_own_centre :: proc(t: ^testing.T) {
	cards := []geo.Billboard_Card{test_card(.Far, 100), test_card(.Far, 300)}
	places, centre := d3_billboard_places(cards)

	testing.expect_value(t, centre, [3]f32{200, 0, 0})
	testing.expect_value(t, places[0].pos, [3]f32{-100, 0, 0})
	testing.expect_value(t, places[1].pos, [3]f32{100, 0, 0})
	testing.expect_value(t, places[0].scale, 1)
}

// Every route of a venue writes into one shared trees.pssg, so the ids have to
// say which route they belong to. A second stage exporting must not be able to
// strip the first one's clouds.
@(test)
cloud_ids_are_scoped_to_their_route :: proc(t: ^testing.T) {
	testing.expect_value(t, d3_billboard_prefix(3), "dirtbench_bb_r3_")
}

// The whole writer against a copy of real venue art. Run twice: a re-export has to
// replace its own clouds rather than pile more on, since every route of the venue
// shares the file.
//
// A copy, because a deployed trees.pssg is a hardlink onto the stock venue's own
// and nothing here may write near the install.
@(test)
the_writer_round_trips_against_real_venue_art :: proc(t: ^testing.T) {
	source, have_source := stock_trees_pssg()
	if !have_source {
		return
	}

	// The stock art has a template for both tiers, and its cards are trees rather
	// than a misread of some other stride-24 mesh.
	{
		lib, lib_msg, opened := d3.prop_lib_open(source, context.temp_allocator)
		testing.expectf(t, opened, "could not read the venue's trees.pssg: %s", lib_msg)
		if !opened {
			return
		}
		defer d3.prop_lib_delete(&lib, context.temp_allocator)
		templates := d3.billboard_templates(&lib)
		for band in ([2]bool{false, true}) {
			template, found := d3.billboard_template_pick(templates, band)
			testing.expectf(t, found, "no %s template in the stock art", band ? "wall" : "tree")
			if !found {
				continue
			}
			for card in template.cards {
				testing.expectf(t, card.w > 1 && card.h > 1,
					"%s has a %.1f by %.1f m card", template.name, card.w, card.h)
			}
		}
	}

	dir := "build/out/billboard-test-venue"
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		testing.expectf(t, false, "could not make %s: %v", dir, err)
		return
	}
	stock, read_err := os.read_entire_file(source, context.temp_allocator)
	testing.expectf(t, read_err == nil, "could not read the venue's trees.pssg: %v", read_err)
	if read_err != nil {
		return
	}
	target, _ := filepath.join({dir, "trees.pssg"}, context.temp_allocator)
	if err := os.write_entire_file(target, stock); err != nil {
		testing.expectf(t, false, "could not stage %s: %v", target, err)
		return
	}
	defer os.remove(target)

	// The stock art has a template for both tiers, and its cards are trees rather
	// than a misread of some other stride-24 mesh.
	{
		lib, lib_msg, opened := d3.prop_lib_open(source, context.temp_allocator)
		testing.expectf(t, opened, "could not read the venue's trees.pssg: %s", lib_msg)
		if !opened {
			return
		}
		defer d3.prop_lib_delete(&lib, context.temp_allocator)
		templates := d3.billboard_templates(&lib)
		for band in ([2]bool{false, true}) {
			template, found := d3.billboard_template_pick(templates, band)
			testing.expectf(t, found, "no %s template in the stock art", band ? "wall" : "tree")
			if !found {
				continue
			}
			for card in template.cards {
				testing.expectf(t, card.w > 1 && card.h > 1,
					"%s has a %.1f by %.1f m card", template.name, card.w, card.h)
			}
		}
	}

	f := fixture_make()
	defer fixture_delete(&f)
	stage := Export_Geometry{ribbon = f.ribbon, terrain = f.terr}
	veg := geo.Veg_Params{enabled = true, billboards = true, density = 0.6, road_bias = 0.8, seed = 2}

	run :: proc(dir: string, stage: ^Export_Geometry, veg: geo.Veg_Params) -> (clouds: int, cards: int, size: int, msg: string, ok: bool) {
		trees := geo.veg_generate(stage.ribbon, &stage.terrain, veg, 0)
		defer delete(trees)
		written, run_msg, run_ok := d3_write_billboards(dir, stage, veg, 0, trees, 0, false)
		if !run_ok {
			return 0, 0, 0, run_msg, false
		}
		for cloud in written {
			cards += cloud.cards
		}
		path, _ := filepath.join({dir, "trees.pssg"}, context.temp_allocator)
		info, stat_err := os.stat(path, context.temp_allocator)
		if stat_err != nil {
			return 0, 0, 0, "the file is gone", false
		}
		return len(written), cards, int(info.size), run_msg, true
	}

	first_clouds, first_cards, first_size, first_msg, first_ok := run(dir, &stage, veg)
	testing.expectf(t, first_ok, "the first export failed: %s", first_msg)
	if !first_ok {
		return
	}
	testing.expect(t, first_clouds > 0 && first_cards > 0, "nothing was written")
	testing.expect(t, first_size > len(stock), "the clouds did not make the file any bigger")

	second_clouds, second_cards, second_size, second_msg, second_ok := run(dir, &stage, veg)
	testing.expectf(t, second_ok, "the second export failed: %s", second_msg)
	if !second_ok {
		return
	}
	testing.expect_value(t, second_clouds, first_clouds)
	testing.expect_value(t, second_cards, first_cards)
	testing.expectf(t, second_size == first_size,
		"a re-export grew the file from %d to %d bytes, so it is piling clouds on",
		first_size, second_size)

	// And the result is a file the game's own container rules accept.
	data, err := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, err == nil, "the written file could not be read")
	if err != nil {
		return
	}
	lib, lib_msg, opened := d3.prop_lib_open(target, context.temp_allocator)
	testing.expectf(t, opened, "the written trees.pssg does not parse: %s", lib_msg)
	if !opened {
		return
	}
	defer d3.prop_lib_delete(&lib, context.temp_allocator)
	clash, clashed := d3.billboard_duplicate_id(&lib)
	testing.expectf(t, !clashed, "the written file holds the id %s twice, which hangs the load", clash)

	ours := 0
	for entry in lib.props {
		if strings.has_prefix(entry.name, d3_billboard_prefix(0)) {
			ours += 1
		}
	}
	testing.expect_value(t, ours, first_clouds)
	// Turning the checkbox off takes them out again.
	off := veg
	off.billboards = false
	_, _, clean_size, clean_msg, clean_ok := run(dir, &stage, off)
	testing.expectf(t, clean_ok, "the removing export failed: %s", clean_msg)
	testing.expectf(t, clean_size == len(stock),
		"removing the clouds left the file at %d bytes against the donor's %d", clean_size, len(stock))
}
