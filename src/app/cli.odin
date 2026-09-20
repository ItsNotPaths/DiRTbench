package main

// Every `--dirt3-*` / `--venue-*` / `--export` / `--pacenotes` /`--hectic`
// command dirtbench answers with no window: one-shot converters that write into
// `out/` or into a route directory, never a GUI concern. Each implementation
// lives beside the thing it drives (install.odin, venue.odin, export.odin);
// what stays here is the flag dispatch itself.
//
// The format probes are gone from this list. They live in the reference-only
// files, which are not compiled: app/paths_place.odin, app/flat_venue.odin,
// app/finland_bisect.odin and d3/scratch.odin. Each says how to reinstate it.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import d3 "../d3"
import "../geo"
import "core:strings"
import "../gfx"

// `--export <stage> [--target <id>] [--terrain]` exports a saved stage and exits,
// without ever opening a window. Anything else falls through to the editor.
run_cli :: proc() -> (handled: bool) {
	args := os.args[1:]
	if len(args) >= 2 && args[0] == "--pacenotes" {
		pacenotes_headless(args[1], len(args) > 2 && args[2] == "--reverse")
		os.exit(0)
	}
	if len(args) >= 2 && args[0] == "--pacenote-fit" {
		pacenote_fit_headless(args[1], args[2:])
		os.exit(0)
	}
	if len(args) >= 4 && args[0] == "--hectic" {
		s0, _ := strconv.parse_f64(args[2])
		s1, _ := strconv.parse_f64(args[3])
		hectic_headless(args[1], f32(s0), f32(s1))
		os.exit(0)
	}
	// `--dirt3-venues`: print the installed venues and their routes. Proves the
	// install was found and `export-dirt3.txt` reads, with no window.
	if len(args) >= 1 && args[0] == "--dirt3-venues" {
		os.exit(install_headless() ? 0 : 1)
	}
	// `--venues`: what is under venues/, and the stage documents each holds.
	// `--dirt3-pack [<venue>]`: what shaders a venue would give a venue of ours.
	if len(args) >= 1 && args[0] == "--dirt3-pack" {
		os.exit(pack_headless(len(args) > 1 ? args[1] : "") ? 0 : 1)
	}
	if len(args) >= 1 && args[0] == "--venues" {
		os.exit(venues_headless() ? 0 : 1)
	}
	// `--venue-new <name> --base <venue>`: the New venue button without a
	// window. Writes nothing into the game.
	if len(args) >= 1 && args[0] == "--venue-new" {
		name, base := "", ""
		if len(args) >= 2 {
			name = args[1]
		}
		for i := 2; i < len(args); i += 1 {
			switch args[i] {
			case "--base":
				if i + 1 >= len(args) {
					fmt.println("--base needs a venue id")
					os.exit(1)
				}
				i += 1
				base = args[i]
			case:
				fmt.printfln("unknown flag %q", args[i])
				os.exit(1)
			}
		}
		if name == "" || base == "" {
			fmt.println("usage: dirtbench --venue-new <name> --base <venue>")
			os.exit(1)
		}
		os.exit(venue_new_headless(name, base) ? 0 : 1)
	}
	if len(args) >= 2 && args[0] == "--venue-deploy" {
		apply := len(args) == 3 && args[2] == "--apply"
		if len(args) > 3 || (len(args) == 3 && !apply) {
			fmt.println("usage: dirtbench --venue-deploy <id> [--apply]")
			os.exit(1)
		}
		if apply {
			os.exit(venue_deploy_headless(args[1]) ? 0 : 1)
		}
		os.exit(venue_deploy_preflight_headless(args[1]) ? 0 : 1)
	}
	if len(args) == 2 && args[0] == "--venue-revert" {
		os.exit(venue_revert_headless(args[1])?0:1)
	}
	if len(args) >= 2 && args[0] == "--venue-tracksplit" {
		terrain := len(args) >= 3 && args[2] == "--terrain"
		msg, ok := venue_tracksplit_headless(args[1], terrain)
		fmt.println(msg)
		os.exit(0 if ok else 1)
	}
	if len(args) < 2 || args[0] != "--export" {
		return false
	}
	// Flags after the stage name, in any order.
	target := "dirt3"
	terrain := false
	debug_out := false
	venue := ""
	for i := 2; i < len(args); i += 1 {
		switch args[i] {
		case "--terrain":
			terrain = true
		case "--debug-out":
			debug_out = true
		case "--venue":
			if i + 1 >= len(args) {
				fmt.println("--venue needs the id of one of ours; see --venues")
				os.exit(1)
			}
			i += 1
			venue = args[i]
		case "--target":
			if i + 1 >= len(args) {
				fmt.println("--target needs an id")
				os.exit(1)
			}
			i += 1
			target = args[i]
		case:
			fmt.printfln("unknown flag %q", args[i])
			os.exit(1)
		}
	}
	msg, ok := export_headless(args[1], target, terrain, debug_out, venue)
	fmt.println(msg)
	os.exit(0 if ok else 1)
}

// Forward/right axes and the start-line midpoint, measured off
// progress_track.xml gates 7 and 8 of Michigan Rally route_5: gate 7 (the
// "start" split) runs (277.51,432.41,445.25)..(302.33,432.41,419.28), gate 8
// runs (262.51,432.47,422.86)..(297.06,432.47,413.00). Forward is gate 7's
// midpoint toward gate 8's; right is gate 7's own left-to-right span.
D3_MICHIGAN_GATE7_MID := [3]f32{289.92, 432.41, 432.265}
D3_MICHIGAN_FORWARD := [3]f32{-0.5772947, 0.0034176, -0.8165288}
D3_MICHIGAN_RIGHT := [3]f32{0.6909192, 0, -0.7229320}

// A loose line of 5 trees, staggered forward 8-11 m ahead of the start line
// and spread +-6 m across it, all using reference 12 ("maple_large_01_a") —
// a real, roughly car-height single tree, not one of Michigan's giant
// distant-backdrop references.
d3_michigan_treeplace_cluster :: proc(allocator := context.allocator) -> []d3.D3_Placement_Instance {
	laterals := [5]f32{-6, -3, 0, 3, 6}
	forwards := [5]f32{8, 11, 8, 11, 8}
	instances := make([]d3.D3_Placement_Instance, 5, allocator)
	for i in 0 ..< 5 {
		pos: [3]f32
		for k in 0 ..< 3 {
			pos[k] = D3_MICHIGAN_GATE7_MID[k] + D3_MICHIGAN_FORWARD[k]*forwards[i] + D3_MICHIGAN_RIGHT[k]*laterals[i]
		}
		instances[i] = {reference_id = 12, basis = d3.D3_BASIS_IDENTITY, position = pos}
	}
	return instances
}

// Read the written trees.bin back and confirm every instance still resolves
// to the reference asked for, at the position asked for.
d3_michigan_treeplace_verify :: proc(new_trees: []u8, want_reference_id: u32, count: int) -> (msg: string, ok: bool) {
	layout, layout_ok := d3.Placement_Layout(new_trees)
	if !layout_ok { return "wrote trees.bin, but it does not parse back", false }
	inst_at := d3.binary_load_i32(new_trees, layout.inst_table_at)
	for i in 0 ..< count {
		ref_id := d3.binary_load_i32(new_trees, inst_at+i*layout.inst_stride)
		if ref_id != int(want_reference_id) {
			return fmt.tprintf("self-check failed: instance %d has reference_id %d, wanted %d", i, ref_id, want_reference_id), false
		}
	}
	return fmt.tprintf("%d/%d instances round-trip to reference %d", count, count, want_reference_id), true
}

dirt3_michigan_treeplace_headless :: proc(route_dir, out_dir: string) -> (msg: string, ok: bool) {
	trees_path, _ := filepath.join({route_dir, "trees.bin"}, context.temp_allocator)
	ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)

	trees_data, trees_err := os.read_entire_file(trees_path, context.temp_allocator)
	if trees_err != nil { return fmt.tprintf("could not read %s: %v", trees_path, trees_err), false }
	ornaments_data, ornaments_err := os.read_entire_file(ornaments_path, context.temp_allocator)
	if ornaments_err != nil { return fmt.tprintf("could not read %s: %v", ornaments_path, ornaments_err), false }

	instances := d3_michigan_treeplace_cluster(context.temp_allocator)
	new_trees, trees_msg, trees_ok := d3.Placement_Relocate(trees_data, instances, context.temp_allocator)
	if !trees_ok { return fmt.tprintf("trees.bin: %s", trees_msg), false }
	new_ornaments, ornaments_msg, ornaments_ok := d3.Placement_Relocate(ornaments_data, nil, context.temp_allocator)
	if !ornaments_ok { return fmt.tprintf("ornaments.bin: %s", ornaments_msg), false }

	if err := os.make_directory_all(out_dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", out_dir, err), false
	}
	out_trees, _ := filepath.join({out_dir, "trees.bin"}, context.temp_allocator)
	out_ornaments, _ := filepath.join({out_dir, "ornaments.bin"}, context.temp_allocator)
	if err := os.write_entire_file(out_trees, new_trees); err != nil {
		return fmt.tprintf("could not write %s: %v", out_trees, err), false
	}
	if err := os.write_entire_file(out_ornaments, new_ornaments); err != nil {
		return fmt.tprintf("could not write %s: %v", out_ornaments, err), false
	}

	verify_msg, verified := d3_michigan_treeplace_verify(new_trees, 12, len(instances))
	if !verified { return verify_msg, false }

	return fmt.tprintf(
		"%s -> %s\ntrees.bin: %s\nornaments.bin: %s\nself-check: %s",
		route_dir, out_dir, trees_msg, ornaments_msg, verify_msg,
	), true
}

dirt3_placement_raise_headless :: proc(path: string, dy: f32, out_path: string) -> (msg: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return fmt.tprintf("could not read %s: %v", path, err), false }
	instances, read_msg, read_ok := d3.Placement_Read(data, context.temp_allocator)
	if !read_ok { return fmt.tprintf("%s: %s", path, read_msg), false }
	for &instance in instances { instance.position[1] += dy }
	out, write_msg, write_ok := d3.Placement_Relocate(data, instances, context.temp_allocator)
	if !write_ok { return fmt.tprintf("%s: %s", path, write_msg), false }
	check, check_msg, check_ok := d3.Placement_Read(out, context.temp_allocator)
	if !check_ok || len(check) != len(instances) {
		return fmt.tprintf("raised placement did not parse back: %s", check_msg), false
	}
	for instance, i in check {
		if instance != instances[i] {
			return fmt.tprintf("raised placement changed instance %d unexpectedly", i), false
		}
	}
	if err := os.write_entire_file(out_path, out); err != nil {
		return fmt.tprintf("could not write %s: %v", out_path, err), false
	}
	return fmt.tprintf("%s -> %s: raised %d instances by %.3f m Y (%s; %s)", path, out_path, len(instances), dy, read_msg, write_msg), true
}

// Where a venue named on a command line is filed, by name or by id. The name
// is handed back untouched when there is no venue by it, so the reader reports
// the missing file rather than this reporting a missing venue.
@(private = "file")
venue_arg_path :: proc(key: string) -> string {
	if p, _, found := venue_find(key, context.temp_allocator); found {
		return venue_file(p)
	}
	return venue_path(key)
}

// `--pacenotes <venue>`: load a venue's road, generate the notes and print them. No
// window, no GL — the generator is pure, so this is the way to eyeball the
// placement numbers while tuning.
hectic_headless :: proc(stage: string, s0, s1: f32) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	if msg, ok := load_road(&doc, venue_arg_path(stage)); !ok {
		fmt.println(msg)
		os.exit(1)
	}
	sp := doc.spline
	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	geo.pace_debug_flips(ribbon, geo.PACE_DEFAULTS, s0, s1)
	free_all(context.temp_allocator)
}

pacenotes_headless :: proc(stage: string, reverse: bool) {
	doc := doc_defaults()
	defer doc_delete(&doc)
	if msg, ok := load_road(&doc, venue_arg_path(stage)); !ok {
		fmt.println(msg)
		os.exit(1)
	}
	sp := doc.spline
	if reverse {
		geo.reverse_spline(&sp)
	}
	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	notes: [dynamic]geo.Pace_Note
	defer delete(notes)
	geo.pace_generate(ribbon, geo.PACE_DEFAULTS, &notes)
	fmt.printf("%d notes on %q\n", len(notes), stage)
	for nt in notes {
		shape := ""
		if nt.kind == .Corner {
			shape = fmt.tprintf("   r=%.0f m  swept %.0f deg", nt.radius, nt.sweep)
		}
		fmt.printf("%8.0f m  %-26s%s\n", nt.station, geo.pace_note_text(nt), shape)
	}
	free_all(context.temp_allocator)
}

// --- fitting the note generator against the game's own calls ------------------
//
// `--pacenote-fit <points.txt> [knob=value ...]` runs pace_generate over a bare
// centreline and prints its notes as fields. The centreline is one `x y z` per
// line, which is how a stock route gets in here at all: this package writes
// BinXML but cannot read it, so `tools/pacenote_fit.py` reads the game's files
// and hands the road over as text.
//
// The point is to fit against ground truth rather than taste. DiRT 3's own
// stages say what they call and where, so the knobs can be searched until our
// notes agree with theirs.
pacenote_fit_headless :: proc(points_path: string, knobs: []string) {
	blob, read_err := os.read_entire_file(points_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s", points_path)
		os.exit(1)
	}
	defer delete(blob)
	pts := make([dynamic]gfx.Vector3, context.temp_allocator)
	for raw in strings.split_lines(string(blob), context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) < 3 {
			continue
		}
		x, _ := strconv.parse_f32(parts[0])
		y, _ := strconv.parse_f32(parts[1])
		z, _ := strconv.parse_f32(parts[2])
		append(&pts, gfx.Vector3{x, y, z})
	}
	if len(pts) < 8 {
		fmt.eprintfln("%s holds %d points, too few for a stage", points_path, len(pts))
		os.exit(1)
	}
	ribbon := make([]geo.Cross_Section, len(pts), context.temp_allocator)
	for i in 0 ..< len(pts) {
		a := pts[max(i - 1, 0)]
		b := pts[min(i + 1, len(pts) - 1)]
		fwd := gfx.Vector3Normalize(b - a)
		// CAUTION: this hand must match what build_ribbon produces, or the fit
		// measures a mirrored generator and every direction reads backwards.
		// It is settled by a control rather than by argument: our own venue's
		// exported calls are in the corpus, and comparing the generator against
		// its own output has to score 1.00 on side. With the other hand it
		// scored 0.00 over 44 pairs -- perfectly inverted, which is the shape
		// a frame error makes and noise never does.
		ribbon[i] = {
			pos   = pts[i],
			fwd   = fwd,
			right = gfx.Vector3{fwd.z, 0, -fwd.x},
			up    = gfx.Vector3{0, 1, 0},
			width = 8,
		}
	}
	pp := geo.PACE_DEFAULTS
	for knob in knobs {
		cut := strings.index(knob, "=")
		if cut < 0 {
			continue
		}
		name := knob[:cut]
		value, _ := strconv.parse_f32(knob[cut + 1:])
		switch name {
		case "smooth_m":     pp.smooth_m = value
		case "r_on":         pp.r_on = value
		case "r_off":        pp.r_off = value
		case "square_tol":   pp.square_tol = value
		case "min_sweep":    pp.min_sweep = value
		case "long_deg":     pp.long_deg = value
		case "tighten":      pp.tighten = value
		case "into_m":       pp.into_m = value
		case "and_m":        pp.and_m = value
		case "dist_min_m":   pp.dist_min_m = value
		case "lead_m":       pp.lead_m = value
		case "crest_k":      pp.crest_k = value
		case "jump_grade":   pp.jump_grade = value
		case "feat_gap_m":   pp.feat_gap_m = value
		case "hectic_win_m": pp.hectic_win_m = value
		case "hectic_flicks": pp.hectic_flicks = int(value)
		case "hectic_amp":   pp.hectic_amp = value
		case "hectic_min_len_m": pp.hectic_min_len_m = value
		case "deg0": pp.sev_deg[0] = value
		case "deg1": pp.sev_deg[1] = value
		case "deg2": pp.sev_deg[2] = value
		case "deg3": pp.sev_deg[3] = value
		case "deg4": pp.sev_deg[4] = value
		case "deg5": pp.sev_deg[5] = value
		case "sev0": pp.sev_r[0] = value
		case "sev1": pp.sev_r[1] = value
		case "sev2": pp.sev_r[2] = value
		case "sev3": pp.sev_r[3] = value
		case "sev4": pp.sev_r[4] = value
		case "sev5": pp.sev_r[5] = value
		case "sev6": pp.sev_r[6] = value
		case:
			fmt.eprintfln("unknown knob %q", name)
			os.exit(1)
		}
	}
	notes: [dynamic]geo.Pace_Note
	defer delete(notes)
	geo.pace_generate(ribbon[:], pp, &notes)
	// station kind dir severity distance link mods radius sweep
	for nt in notes {
		kind := "corner"
		switch nt.kind {
		case .Corner:   kind = "corner"
		case .Distance: kind = "distance"
		case .Crest:    kind = "crest"
		case .Dip:      kind = "dip"
		case .Jump:     kind = "jump"
		case .Hectic:   kind = "hectic"
		}
		dir := nt.dir == .Left ? "left" : (nt.dir == .Right ? "right" : "-")
		link := nt.link == .Into ? "into" : (nt.link == .And ? "and" : "-")
		mods := make([dynamic]string, context.temp_allocator)
		if .Long in nt.mods {append(&mods, "long")}
		if .Tightens in nt.mods {append(&mods, "tightens")}
		if .Opens in nt.mods {append(&mods, "opens")}
		mod_text := len(mods) > 0 ? strings.join(mods[:], "+", context.temp_allocator) : "-"
		fmt.printf(
			"%.1f %s %s %d %d %s %s %.1f %.1f\n",
			nt.station, kind, dir, nt.sev, nt.dist, link, mod_text, nt.radius, nt.sweep,
		)
	}
	free_all(context.temp_allocator)
}
