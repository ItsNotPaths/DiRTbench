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
build_export_mesh :: proc(doc: ^Venue_Doc, allocator := context.allocator) -> geo.Tri_Mesh {
	m := geo.build_tri_mesh(doc.ribbon, doc.topo, doc.roughness, allocator)
	if doc.terrain.enabled && len(doc.terrain_field.tris) > 0 {
		geo.build_terrain_mesh(&m, &doc.terrain, &doc.terrain_field)
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
build_export_job :: proc(doc: ^Venue_Doc, name: string) -> (job: Export_Job, msg: string, ok: bool) {
	if len(doc.spline.points) < 2 {
		return job, "nothing to export: a stage needs at least 2 points", false
	}

	job.name = name
	job.mesh = build_export_mesh(doc, context.temp_allocator)
	job.order, job.counts = sort_faces_by_material(job.mesh)
	if len(job.order) == 0 {
		return job, "nothing to export: the mesh has no triangles", false
	}
	job.ribbon = doc.ribbon
	job.timing = doc.timing
	// glTF needs no shaders, so a missing profile is only fatal for the target
	// that names them.
	job.profile, job.profile_msg, _ = export_profile(doc.install, doc.open_venue, context.temp_allocator)
	job.props = geo.veg_generate(
		doc.ribbon,
		&doc.terrain,
		doc.veg,
		doc.topo,
		doc.roughness,
		context.temp_allocator,
	)

	// The headless path leaves doc.pace zero-valued, which would read as "every
	// knob at zero" rather than "unset".
	job.pace = doc.pace.smooth_m != 0 ? doc.pace : geo.PACE_DEFAULTS
	notes := make([dynamic]geo.Pace_Note, context.temp_allocator)
	geo.pace_generate(doc.ribbon, job.pace, &notes)
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
	doc: ^Venue_Doc,
	name: string,
	stage_id: string,
	target: ^Export_Target,
) -> (
	dir: string,
	installing: bool,
	msg: string,
	ok: bool,
) {
	if target.installs && !doc.debug_export {
		// A stage opened from one of our venues goes to that venue's own route
		// directory inside the game. That directory only exists once the venue
		// has been deployed, which is a separate step and does not exist yet —
		// so say so, rather than creating a directory the game never reads.
		if doc.open_venue != "" {
			route, deployed := venue_deploy_dir(doc, doc.open_venue, stage_id)
			if !deployed {
				return "", false, fmt.tprintf(
					"%s is not in the game yet; tick Write to out/ until deploying exists",
					doc.open_venue,
				), false
			}
			return route, true, "", true
		}
		route := install_scan_route_dir(doc.install)
		if route == "" {
			return "", false, "no route selected: open one from Dirt 3 > Install_Scan, or tick Write to out/", false
		}
		return route, true, "", true
	}
	// Two venues can both hold a `route_0`, so the debug detour keeps them
	// apart by venue.
	if doc.open_venue != "" {
		dir, _ = filepath.join({out_dir(), doc.open_venue, name}, context.temp_allocator)
	} else {
		dir, _ = filepath.join({out_dir(), name}, context.temp_allocator)
	}
	return dir, false, "", true
}

// Build the job and hand it to one target. Returns a status-line message.
//
// `stage_id` names which of the venue's stages this is, and is what picks the
// route directory inside the game. It is empty for a loose stage out of maps/,
// which has no venue and lands in the selected install route instead.
export_stage :: proc(
	doc: ^Venue_Doc, name, stage_id: string, target: ^Export_Target,
) -> (msg: string, ok: bool) {
	job, jmsg, jok := build_export_job(doc, name)
	if !jok {
		return jmsg, false
	}
	dest, installing, dmsg, dok := export_dest(doc, name, stage_id, target)
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
	roughness: f32 = 0.5,
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
	scan: Install_Scan
	doc := Venue_Doc {
		install   = &scan,
		topo      = geo.SAMPLES_PER_SEG,
		roughness = roughness,
		terrain   = geo.TERRAIN_DEFAULTS,
		pace      = geo.PACE_DEFAULTS,
		veg       = geo.VEG_DEFAULTS,
	}
	doc.debug_export = debug_out
	install_scan_init(doc.install)
	defer install_scan_delete(doc.install)
	// `--venue <id>` names one of ours and `stage` is its stage; `--route
	// <venue>/<route_n>` names a route already in the game. They are the two
	// destinations an install can have, and only one applies at a time.
	if venue != "" {
		doc.open_venue = venue
	} else if route != "" {
		if m, sok := install_scan_select(doc.install, route); !sok {
			return m, false
		}
	}
	defer delete(doc.spline.points)
	defer geo.terrain_delete(&doc.terrain)
	defer geo.terrain_field_delete(&doc.terrain_field)

	load :: proc(doc: ^Venue_Doc, stage: string) -> (msg: string, ok: bool) {
		if doc.open_venue != "" {
			p, pmsg, pok := venue_load(doc.open_venue, context.temp_allocator)
			if !pok { return pmsg, false }
			// A venue stage is compiled out of the road graph, not read from a
			// document of its own.
			compiled, cmsg, cok := venue_compile_route(p, stage, doc, context.allocator)
			if !cok { return cmsg, false }
			delete(doc.spline.points)
			doc.spline = compiled
			return cmsg, true
		}
		return load_road_named(doc, stage)
	}
	if m, lok := load(&doc, stage); !lok {
		return m, false
	}
	// The document owns the sculpt and the sliders. The flag only forces ground
	// on for a stage that has none.
	doc.terrain.enabled = doc.terrain.enabled || terrain
	doc.ribbon = geo.build_ribbon(doc.spline, int(doc.topo), context.allocator)
	defer delete(doc.ribbon)
	doc.ribbon_gen = 1

	if doc.terrain.enabled {
		geo.terrain_ensure(&doc.terrain, doc.ribbon, doc.topo, doc.roughness)
		arc := geo.ribbon_arc(doc.ribbon)
		ds := geo.sample_spacing(doc.ribbon)
		geo.terrain_field_ensure(
			&doc.terrain_field,
			&doc.terrain,
			doc.ribbon,
			arc,
			ds,
			doc.topo,
			doc.roughness,
			doc.ribbon_gen,
		)
	}
	// A `--venue` export names its stage; a loose one out of maps/ has none.
	return export_stage(&doc, stage, venue != "" ? stage : "", target)
}
