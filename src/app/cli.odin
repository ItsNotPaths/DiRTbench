package main

// Every `--dirt3-*` / `--venue-*` / `--export` / `--pacenotes` /`--hectic`
// command dirtbench answers with no window: one-shot converters and probes
// that write into `out/` or into a route directory, never a GUI concern. Each
// implementation lives beside the thing it tests (install.odin, venue.odin,
// export.odin); what stays here is the flag dispatch itself, plus the handful
// of probes with no other home.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import d3 "../d3"
import "../geo"

// `--export <stage> [--target <id>] [--terrain]` exports a saved stage and exits,
// without ever opening a window. Anything else falls through to the editor.
run_cli :: proc() -> (handled: bool) {
	args := os.args[1:]
	if len(args) >= 2 && args[0] == "--pacenotes" {
		pacenotes_headless(args[1], len(args) > 2 && args[2] == "--reverse")
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
	// `--venue-new <id> --base <venue> [--name <shown>]`: the New venue button
	// without a window. Writes nothing into the game.
	if len(args) >= 1 && args[0] == "--venue-new" {
		id, base, display := "", "", ""
		if len(args) >= 2 {
			id = args[1]
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
			case "--name":
				if i + 1 >= len(args) {
					fmt.println("--name needs a display name")
					os.exit(1)
				}
				i += 1
				display = args[i]
			case:
				fmt.printfln("unknown flag %q", args[i])
				os.exit(1)
			}
		}
		if id == "" || base == "" {
			fmt.println("usage: dirtbench --venue-new <id> --base <venue> [--name <shown>]")
			os.exit(1)
		}
		os.exit(venue_new_headless(id, base, display) ? 0 : 1)
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
	// `--dirt3-dump <track.jpk|x.vcqtc> [-o out.obj]`: read a stock Dirt 3
	// collision file and write an OBJ. Reads the game, writes nothing into it.
	if len(args) >= 2 && args[0] == "--dirt3-dump" {
		out := "out/dirt3-collision.obj"
		if len(args) >= 4 && args[2] == "-o" {
			out = args[3]
		}
		dir := filepath.dir(out)
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err)
			os.exit(1)
		}
		msg, ok := d3.Dump(args[1], out)
		fmt.println(msg)
		os.exit(0 if ok else 1)
	}
	// `--dirt3-raise <track.jpk> <metres> [-o out.jpk]`: lift a stock collision
	// archive. The flying-car test — proves the game loads our bytes.
	if len(args) >= 3 && args[0] == "--dirt3-raise" {
		dy, _ := strconv.parse_f64(args[2])
		out := "out/track.jpk"
		if len(args) >= 5 && args[3] == "-o" {
			out = args[4]
		}
		dir := filepath.dir(out)
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err)
			os.exit(1)
		}
		msg, ok := d3.Raise(args[1], f32(dy), out)
		fmt.println(msg)
		os.exit(0 if ok else 1)
	}
	// `--dirt3-ramp [-o track.jpk]`: writer milestone and first custom-geometry
	// test. Produces a fresh collision archive; it does not touch the game.
	if len(args) >= 1 && args[0] == "--dirt3-ramp" {
		out := "out/dirt3-ramp.jpk"
		if len(args) >= 3 && args[1] == "-o" { out = args[2] }
		dir := filepath.dir(out)
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err)
			os.exit(1)
		}
		msg, ok := d3.Ramp(out)
		fmt.println(msg)
		os.exit(0 if ok else 1)
	}
	// Fresh, multi-chunk collision used to prove archive-level spatial lookup.
	// It is straight in XZ for an unguided car and wobbles only vertically.
	if len(args) >= 1 && args[0] == "--dirt3-partition-strip" {
		out := "out/dirt3-partition-strip.jpk"
		if len(args) >= 3 && args[1] == "-o" { out = args[2] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Partition_Strip(out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	// `--dirt3-flat <min-x> <max-x> <min-z> <max-z> <y> [-o track.jpk]`:
	// emit a fresh rectangular collision plane without touching a game install.
	if len(args) >= 1 && args[0] == "--dirt3-flat" {
		if len(args)<6 {
			fmt.println("usage: dirtbench --dirt3-flat <min-x> <max-x> <min-z> <max-z> <y> [-o track.jpk]")
			os.exit(1)
		}
		values:[5]f64
		for text,i in args[1:6] {
			value,valid:=strconv.parse_f64(text)
			if !valid || value!=value || math.abs(value)>3.4028234e38 {
				fmt.printfln("invalid finite number %q",text); os.exit(1)
			}
			values[i]=value
		}
		out:="out/dirt3-flat.jpk"
		if len(args)==8 && args[6]=="-o" { out=args[7] } else if len(args)!=6 {
			fmt.println("usage: dirtbench --dirt3-flat <min-x> <max-x> <min-z> <max-z> <y> [-o track.jpk]")
			os.exit(1)
		}
		if err:=os.make_directory_all(filepath.dir(out)); err!=nil && err!=os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v",err); os.exit(1)
		}
		msg,ok:=d3.Flat(f32(values[0]),f32(values[1]),f32(values[2]),f32(values[3]),f32(values[4]),out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	if len(args) >= 2 && args[0] == "--dirt3-partition-strip-on" {
		out := "out/dirt3-partition-strip-on-stock.jpk"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Partition_Strip_On_Stock(args[1],out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	if len(args) >= 2 && args[0] == "--dirt3-ramp-on" {
		out := "out/dirt3-ramp-on-stock.jpk"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Ramp_On_Stock(args[1], out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	if len(args) >= 2 && args[0] == "--dirt3-bridge-bump" {
		out := "out/dirt3-bridge-bump.jpk"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Bridge_Bump(args[1], out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	// `--dirt3-routesplit <track.jpk> [-o routesplit.pssg]`: the visual surface
	// that matches a collision archive, tiled the way the stock route files are.
	if len(args) >= 2 && args[0] == "--dirt3-routesplit" {
		out := "out/routesplit.pssg"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Routesplit(args[1], out)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	// `--dirt3-vis-allvisible <route_dir> <venue_dir> [--donor track.vis] [--ornaments skip|donor|random] [-o out.vis]`:
	// build an all-visible track.vis for an existing stock route from its own
	// files (tracksplit/routesplit tiles, trees, ornaments — see
	// vis_allvisible.odin for what is and is not covered). `--donor` floors
	// every tag's header count at that file's own counts, so a tag this
	// codebase undersells cannot undersize the game's own allocation for it,
	// and also pulls in `objects.ens`'s real-id static-vis entities.
	// `--ornaments` picks how `ornaments.bin`'s own instances get a tag-2 id:
	// `donor` (default, needs `--donor`), `skip` (leave them out), or
	// `random` (an unclaimed id with no real source — see
	// D3_Ornaments_Id_Mode). Never touches the route directly.
	if len(args) >= 3 && args[0] == "--dirt3-vis-allvisible" {
		out := "out/track.vis"
		donor := ""
		ornaments_mode := d3.D3_Ornaments_Id_Mode.Donor
		for i := 3; i < len(args); i += 1 {
			switch args[i] {
			case "-o":
				if i+1 >= len(args) { fmt.println("-o needs a path"); os.exit(1) }
				i += 1; out = args[i]
			case "--donor":
				if i+1 >= len(args) { fmt.println("--donor needs a path"); os.exit(1) }
				i += 1; donor = args[i]
			case "--ornaments":
				if i+1 >= len(args) { fmt.println("--ornaments needs skip|donor|random"); os.exit(1) }
				i += 1
				switch args[i] {
				case "skip": ornaments_mode = .Skip
				case "donor": ornaments_mode = .Donor
				case "random": ornaments_mode = .Random
				case: fmt.printfln("--ornaments: unknown mode %q", args[i]); os.exit(1)
				}
			case:
				fmt.printfln("unknown flag %q", args[i]); os.exit(1)
			}
		}
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Vis_All_Visible(args[1], args[2], donor, out, ornaments_mode)
		fmt.println(msg); os.exit(0 if ok else 1)
	}
	// `--dirt3-rewrite <stock track.jpk> [-o rewritten.jpk]`: rebuild every
	// stock chunk through our encoder, preserving the spatial archive layout.
	if len(args) >= 2 && args[0] == "--dirt3-rewrite" {
		out := "out/dirt3-rewritten.jpk"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		if err := os.make_directory_all(filepath.dir(out)); err != nil && err != os.General_Error.Exist {
			fmt.printfln("could not create the output directory: %v", err); os.exit(1)
		}
		msg, ok := d3.Rewrite(args[1], out)
		fmt.println(msg)
		os.exit(0 if ok else 1)
	}
	// `--dirt3-michigan-treeplace <route dir> [-o outdir]`: exercise
	// d3.d3_placement_relocate against a real stock route. Empties trees.bin
	// and ornaments.bin, then places 5 maple trees (reference 12,
	// "maple_large_01_a") across the road just ahead of Michigan Rally
	// route_5's start line. Never writes into the route itself — dropping the
	// result into the game is a manual step.
	if len(args) >= 2 && args[0] == "--dirt3-michigan-treeplace" {
		out := "out/michigan-treeplace"
		if len(args) >= 4 && args[2] == "-o" { out = args[3] }
		msg, ok := dirt3_michigan_treeplace_headless(args[1], out)
		fmt.println(msg)
		os.exit(0 if ok else 1)
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
	route := ""
	venue := ""
	for i := 2; i < len(args); i += 1 {
		switch args[i] {
		case "--terrain":
			terrain = true
		case "--debug-out":
			debug_out = true
		case "--route":
			if i + 1 >= len(args) {
				fmt.println("--route needs <venue>/<route_n>")
				os.exit(1)
			}
			i += 1
			route = args[i]
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
	msg, ok := export_headless(args[1], target, terrain, debug_out, route, venue)
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
	layout, layout_ok := d3.d3_placement_layout(new_trees)
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
	new_trees, trees_msg, trees_ok := d3.d3_placement_relocate(trees_data, instances, context.temp_allocator)
	if !trees_ok { return fmt.tprintf("trees.bin: %s", trees_msg), false }
	new_ornaments, ornaments_msg, ornaments_ok := d3.d3_placement_relocate(ornaments_data, nil, context.temp_allocator)
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

// `--pacenotes <stage>`: load a stage, generate the notes and print them. No
// window, no GL — the generator is pure, so this is the way to eyeball the
// placement numbers while tuning.
hectic_headless :: proc(stage: string, s0, s1: f32) {
	sp: geo.Spline
	defer delete(sp.points)
	if msg, ok := load_stage(&sp, stage); !ok {
		fmt.println(msg)
		os.exit(1)
	}
	ribbon := geo.build_ribbon(sp, geo.SAMPLES_PER_SEG, context.allocator)
	defer delete(ribbon)
	geo.pace_debug_flips(ribbon, geo.PACE_DEFAULTS, s0, s1)
	free_all(context.temp_allocator)
}

pacenotes_headless :: proc(stage: string, reverse: bool) {
	sp: geo.Spline
	defer delete(sp.points)
	if msg, ok := load_stage(&sp, stage); !ok {
		fmt.println(msg)
		os.exit(1)
	}
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
		fmt.printf("%8.0f m  %s\n", nt.station, geo.pace_note_text(nt))
	}
	free_all(context.temp_allocator)
}
