package main

// Export: a sculpted stage -> a playable stage in some game.
//
// Nothing in this file knows about any one game. The pipeline splits in two:
//
//   1. Here, `build_export_job` collects everything a stage is, in world space,
//      metres, Y up: the triangle soup (each triangle tagged with a `Mat_Id`),
//      the scattered props (each tagged with a `Prop_Kind`), the pace notes at
//      their arc stations, and the ribbon those stations were measured along.
//   2. One `Export_Target` turns that job into files a game can open. A target
//      owns its own material table, its own prop table and its own backend
//      tool. See export_gltf.odin for the simplest one, and
//      export_dirt3.odin for the one this tool exists for.
//
// Adding a game means adding one file holding one `Export_Target`, and one row
// in `EXPORT_TARGETS`. Nothing else in the editor changes.
//
// Where the files land is `export_dest`: by default straight into the game, so
// the next thing you do is drive it. `out/` is the debug detour.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import d3 "../d3"
import "../geo"

export_dirt3 :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	if job.profile == nil {
		return job.profile_msg, false
	}
	route := make([]d3.Route_Sample, len(job.ribbon), context.temp_allocator)
	for section, i in job.ribbon {
		half := section.width/2
		left := section.pos-section.right*half
		right := section.pos+section.right*half
		route[i] = {
			Centre = {section.pos.x,section.pos.y,section.pos.z},
			Left = {left.x,left.y,left.z},
			Right = {right.x,right.y,right.z},
		}
	}
	timing := timing_markers(job.ribbon,job.timing)
	markers := make([]d3.Progress_Marker,len(timing),context.temp_allocator)
	for marker,i in timing {
		kind:d3.Progress_Marker_Kind
		switch marker.kind {
		case .Start: kind=.Start
		case .Checkpoint: kind=.Checkpoint
		case .Finish: kind=.Finish
		}
		markers[i]={Kind=kind,Distance=marker.station}
	}
	collision := collision_from_mesh(job.mesh, job.order, context.temp_allocator)
	return d3.Export(&d3.Export_Job{Name=job.name,Out=job.out,Backup=job.installing,Route=route,Markers=markers,Collision=collision,Profile=job.profile})
}

// The triangle soup, in material order, as a target-agnostic collision list.
// Every Dirt 3 file that names geometry reads from this, at route or venue
// scope alike.
collision_from_mesh :: proc(mesh: geo.Tri_Mesh, order: []int, allocator := context.temp_allocator) -> []d3.Collision_Triangle {
	collision := make([]d3.Collision_Triangle, len(order), allocator)
	for triangle, i in order {
		material: d3.Collision_Material
		switch mesh.mat[triangle] {
		case .Road:     material = .Road
		case .Cliff:    material = .Cliff
		case .Terrain:  material = .Terrain
		case .RoadSand: material = .Road_Sand
		}
		for corner in 0..<3 {
			p := mesh.pos[triangle*3+corner]
			collision[i].Points[corner] = {p.x,p.y,p.z}
		}
		collision[i].Material = material
	}
	return collision
}

// --- the job -----------------------------------------------------------------

// One stage, flattened into everything an exporter could want and nothing a
// game-specific one. Every position is world space; the target applies its own
// anchor offset if it has one.
Export_Job :: struct {
	name:   string,          // stage name, already filesystem-safe
	out:    string,          // the directory the files land in, already created
	// True when `out` is inside the installed game, so a writer knows to keep a
	// copy of whatever it overwrites.
	installing: bool,
	mesh:   geo.Tri_Mesh,        // road + verges + terrain, each triangle tagged
	order:  []int,           // triangle indices, sorted by material
	counts: [geo.Mat_Id]int,     // population of each material group
	props:  []geo.Veg_Instance,  // scattered vegetation; empty when disabled
	ribbon: []geo.Cross_Section, // for targets that place things along the road
	// Which shaders the stage draws with, resolved from the open venue or from
	// the venue the selected route lives in. Only the Dirt 3 target needs it,
	// so a failure to resolve one is carried rather than raised.
	profile:     ^d3.Venue_Profile,
	profile_msg: string,
	notes:  []geo.Pace_Note,     // pace notes at their arc stations
	pace:   geo.Pace_Params,     // what `notes` was generated from, for a target that
	                         // writes notes rather than baked audio
	timing: Timing_Params,
}

// --- targets -----------------------------------------------------------------

Export_Target :: struct {
	id:       string, // stable; used by --target
	label:    string, // menu text
	blurb:    string, // one line, for the Export targets window
	// True when the target writes files the game itself loads, so its natural
	// home is the selected route inside the install. False for a target whose
	// output the game could not open anyway.
	installs: bool,
	run:      proc(job: ^Export_Job) -> (msg: string, ok: bool),
}

// The games we can export to. Order is menu order.
EXPORT_TARGETS := []Export_Target {
	{
		id = "gltf",
		label = "glTF 2.0",
		blurb = "Plain mesh + prop markers, for Blender or any other DCC tool. Always out/.",
		run = export_gltf,
	},
	{
		id = "dirt3",
		label = "Dirt 3",
		blurb = "Native route files, written over the selected route so you can drive it.",
		installs = true,
		run = export_dirt3,
	},
}

find_target :: proc(id: string) -> (^Export_Target, bool) {
	for &t in EXPORT_TARGETS {
		if t.id == id {
			return &t, true
		}
	}
	return nil, false
}

// --- paths -------------------------------------------------------------------

// The directory holding our own executable. `maps/`, `out/`
// and the per-target config are all resolved against it, so a dev build and a
// release build each keep their own.
exe_dir :: proc(allocator := context.temp_allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		return strings.clone(".", allocator) // cwd is the only sensible fallback
	}
	return strings.clone(filepath.dir(exe), allocator)
}

out_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({exe_dir(), "out"}, allocator)
	return joined
}



// --- shelling out ------------------------------------------------------------

// Run a command to completion and capture its output. Returns the tool's own
// stderr on failure, which is where its diagnostics go.
run_tool :: proc(exe: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, ..args)

	state, stdout, stderr, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("could not run %s: %v", filepath.base(exe), err), false
	}
	if !state.exited || state.exit_code != 0 {
		detail := strings.trim_space(string(stderr))
		if detail == "" {
			detail = strings.trim_space(string(stdout))
		}
		return fmt.tprintf("%s exit %d: %s", filepath.base(exe), state.exit_code, detail), false
	}
	return strings.trim_space(string(stdout)), true
}

// --- building the job --------------------------------------------------------

// Road + verges + (if enabled) terrain, in one soup, each triangle tagged.
// Reuses the viewport's own builders: one source of geometry.
//
// The terrain is included as a *driveable* surface, not scenery — a target that
// makes the mesh its own collision must not let a car that leaves the road fall
// through the void.
build_export_mesh :: proc(ed: ^Editor, allocator := context.allocator) -> geo.Tri_Mesh {
	m := geo.build_tri_mesh(ed.ribbon, ed.topo, ed.roughness, allocator)
	if ed.terrain.enabled && len(ed.terrain_field.tris) > 0 {
		geo.build_terrain_mesh(&m, &ed.terrain, &ed.terrain_field)
	}
	return m
}

// Triangle indices sorted by material, and the population of each group. A
// counting sort: stable within a group, and it visits each triangle twice.
//
// Every target we have binds a material per *contiguous run* of faces, so face
// order must already agree with material order. It is also what lets a target
// chop the soup into pieces: any contiguous slice of `order` is still sorted.
sort_faces_by_material :: proc(
	tm: geo.Tri_Mesh,
	allocator := context.temp_allocator,
) -> (
	order: []int,
	counts: [geo.Mat_Id]int,
) {
	for mat in tm.mat {
		counts[mat] += 1
	}
	starts: [geo.Mat_Id]int
	acc := 0
	for mat in geo.Mat_Id {
		starts[mat] = acc
		acc += counts[mat]
	}
	order = make([]int, len(tm.mat), allocator)
	for mat, tri in tm.mat {
		order[starts[mat]] = tri
		starts[mat] += 1
	}
	return order, counts
}

// Everything the editor holds, flattened for a target. Temp-allocated: valid for
// the duration of one export.
build_export_job :: proc(ed: ^Editor, name: string) -> (job: Export_Job, msg: string, ok: bool) {
	if len(ed.spline.points) < 2 {
		return job, "nothing to export: a stage needs at least 2 points", false
	}

	job.name = name
	job.mesh = build_export_mesh(ed, context.temp_allocator)
	job.order, job.counts = sort_faces_by_material(job.mesh)
	if len(job.order) == 0 {
		return job, "nothing to export: the mesh has no triangles", false
	}
	job.ribbon = ed.ribbon
	job.timing = ed.timing
	// glTF needs no shaders, so a missing profile is only fatal for the target
	// that names them.
	job.profile, job.profile_msg, _ = export_profile(&ed.install, ed.open_venue, context.temp_allocator)
	job.props = geo.veg_generate(
		ed.ribbon,
		&ed.terrain,
		ed.veg,
		ed.topo,
		ed.roughness,
		context.temp_allocator,
	)

	// The headless path leaves ed.pace zero-valued, which would read as "every
	// knob at zero" rather than "unset".
	job.pace = ed.pace.smooth_m != 0 ? ed.pace : geo.PACE_DEFAULTS
	notes := make([dynamic]geo.Pace_Note, context.temp_allocator)
	geo.pace_generate(ed.ribbon, job.pace, &notes)
	job.notes = notes[:]

	return job, "", true
}

// Where a target's files land.
//
// Default: straight into the selected route inside the installed game, because
// the next thing anyone does with a route is drive it. Each file we overwrite is
// backed up once (see `d3_backup_once`).
//
// `out/<stage>/` is the debug detour: **Export targets > Write to out/ instead**,
// or `--debug-out` headless. A target that does not write game files (glTF) goes
// there unconditionally, since the game could not open its output anyway.
// Pure: it creates nothing, so the Export targets panel can ask every frame.
export_dest :: proc(
	ed: ^Editor,
	name: string,
	target: ^Export_Target,
) -> (
	dir: string,
	installing: bool,
	msg: string,
	ok: bool,
) {
	if target.installs && !ed.debug_export {
		// A stage opened from one of our venues goes to that venue's own route
		// directory inside the game. That directory only exists once the venue
		// has been deployed, which is a separate step and does not exist yet —
		// so say so, rather than creating a directory the game never reads.
		if ed.open_venue != "" {
			route, deployed := venue_deploy_dir(ed, ed.open_venue, ed.open_stage)
			if !deployed {
				return "", false, fmt.tprintf(
					"%s is not in the game yet; tick Write to out/ until deploying exists",
					ed.open_venue,
				), false
			}
			return route, true, "", true
		}
		route := install_scan_route_dir(&ed.install)
		if route == "" {
			return "", false, "no route selected: open one from Dirt 3 > Install_Scan, or tick Write to out/", false
		}
		return route, true, "", true
	}
	// Two venues can both hold a `route_0`, so the debug detour keeps them
	// apart by venue.
	if ed.open_venue != "" {
		dir, _ = filepath.join({out_dir(), ed.open_venue, name}, context.temp_allocator)
	} else {
		dir, _ = filepath.join({out_dir(), name}, context.temp_allocator)
	}
	return dir, false, "", true
}

// Build the job and hand it to one target. Returns a status-line message.
export_stage :: proc(ed: ^Editor, name: string, target: ^Export_Target) -> (msg: string, ok: bool) {
	job, jmsg, jok := build_export_job(ed, name)
	if !jok {
		return jmsg, false
	}
	dest, installing, dmsg, dok := export_dest(ed, name, target)
	if !dok {
		return dmsg, false
	}
	job.out, job.installing = dest, installing
	had_orig := false
	if installing {
		if infos, err := os.read_all_directory_by_path(dest, context.temp_allocator); err == nil {
			for info in infos {
				if strings.has_suffix(info.name, ".orig") {
					had_orig = true
					break
				}
			}
		}
	}
	if err := os.make_directory_all(dest); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dest, err), false
	}

	run_msg, run_ok := target.run(&job)
	if !run_ok {
		return run_msg, false
	}
	if had_orig {
		return fmt.tprintf(
			"warning: route already had .orig backups and is not stock; %s -> %s",
			run_msg,
			dest,
		), true
	}
	return fmt.tprintf("%s -> %s", run_msg, dest), true
}

// --- headless ----------------------------------------------------------------

// `dirtbench --export <stage> [--target <id>] [--terrain] [--venue <id>]
// [--route <venue>/<route_n>] [--debug-out]`: run the pipeline on a saved stage
// without opening a window, for scripting and for testing an export without a
// display.
//
// `<stage>` names a stage in `maps/`, or one of `--venue <id>`'s stages. Writes
// into the game like the GUI does, so an installing target needs a destination —
// a deployed `--venue`, or a `--route` already in the game — unless
// `--debug-out` sends it to `out/` instead.
//
// It reproduces the CPU half of `rebuild_geometry` and nothing else. Everything
// export touches is CPU-side — `Gpu_Mesh` is only ever the viewport's copy — so
// no GL context is needed, and none is created.
export_headless :: proc(
	stage: string,
	target_id: string,
	terrain: bool,
	debug_out: bool,
	route: string,
	venue: string,
) -> (
	msg: string,
	ok: bool,
) {
	target, found := find_target(target_id)
	if !found {
		ids := make([dynamic]string, 0, len(EXPORT_TARGETS), context.temp_allocator)
		for t in EXPORT_TARGETS {
			append(&ids, t.id)
		}
		return fmt.tprintf(
			"unknown export target %q; have %s",
			target_id,
			strings.join(ids[:], ", ", context.temp_allocator),
		), false
	}

	// The install scan is the only thing that knows where the game is, so a
	// headless export into it needs the scan too.
	ed := Editor {
		topo      = geo.SAMPLES_PER_SEG,
		roughness = 0.5,
		terrain   = geo.TERRAIN_DEFAULTS,
		pace      = geo.PACE_DEFAULTS,
		veg       = geo.VEG_DEFAULTS,
	}
	ed.terrain.enabled = terrain
	ed.debug_export = debug_out
	install_scan_init(&ed.install)
	defer install_scan_delete(&ed.install)
	// `--venue <id>` names one of ours and `stage` is its stage; `--route
	// <venue>/<route_n>` names a route already in the game. They are the two
	// destinations an install can have, and only one applies at a time.
	if venue != "" {
		ed.open_venue, ed.open_stage = venue, stage
	} else if route != "" {
		if m, sok := install_scan_select(&ed.install, route); !sok {
			return m, false
		}
	}
	defer delete(ed.spline.points)
	defer geo.terrain_delete(&ed.terrain)
	defer geo.terrain_field_delete(&ed.terrain_field)

	load :: proc(ed: ^Editor, stage: string) -> (msg: string, ok: bool) {
		if ed.open_venue != "" {
			p, pmsg, pok := venue_load(ed.open_venue, context.temp_allocator)
			if !pok { return pmsg, false }
			// A venue stage is compiled out of the road graph, not read from a
			// document of its own.
			stage, cmsg, cok := venue_compile_route(
				p, ed.open_stage, &ed.veg, &ed.timing, context.allocator,
			)
			if !cok { return cmsg, false }
			delete(ed.spline.points)
			ed.spline = stage
			return cmsg, true
		}
		return load_stage(&ed.spline, stage, &ed.veg, &ed.timing)
	}
	if m, lok := load(&ed, stage); !lok {
		return m, false
	}
	ed.ribbon = geo.build_ribbon(ed.spline, int(ed.topo), context.allocator)
	defer delete(ed.ribbon)
	ed.ribbon_gen = 1

	if ed.terrain.enabled {
		geo.terrain_ensure(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
		arc := geo.ribbon_arc(ed.ribbon)
		ds := geo.sample_spacing(ed.ribbon)
		geo.terrain_field_ensure(
			&ed.terrain_field,
			&ed.terrain,
			ed.ribbon,
			arc,
			ds,
			ed.topo,
			ed.roughness,
			ed.ribbon_gen,
		)
	}
	return export_stage(&ed, stage, target)
}
