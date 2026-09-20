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
import "core:strconv"
import "core:strings"
import d3 "../d3"
import "../geo"

// How far under the route's surface the venue LOD sits. Enough to beat depth
// precision at range, small enough that the step where the route's coverage
// ends is not a cliff.
D3_VENUE_LOD_DROP :: f32(2)

// A ground skirt around the venue LOD, because open sky where the ground
// should be blows the auto-exposure out and the screen goes black. Stock gives
// about 2 km in every direction — Finland's tracksplit spans 4600 by 2300 m
// for a road far smaller — so the skirt reaches well past the road network.
//
// Venue LOD only, so it is drawn and not driveable, like the rest of that
// layer. Deliberately coarse: it is horizon filler, and at this range the cell
// size costs nothing.
D3_VENUE_SKIRT_MARGIN :: f32(2000)
D3_VENUE_SKIRT_CELL :: f32(200)
// Gentle relief, so a 4 km plane does not read as a table top.
D3_VENUE_SKIRT_RELIEF :: f32(6)

// A tiled ground plane covering `lo`..`hi`, sunk to `y`, with deterministic
// per-corner relief so neighbouring cells share their edge heights.
venue_skirt :: proc(lo, hi: [2]f32, y: f32, allocator := context.temp_allocator) -> []d3.Collision_Triangle {
	nx := max(1, int((hi[0]-lo[0])/D3_VENUE_SKIRT_CELL))
	nz := max(1, int((hi[1]-lo[1])/D3_VENUE_SKIRT_CELL))
	height :: proc(ix, iz: int, y: f32) -> f32 {
		h := u32(ix)*73856093 ~ u32(iz)*19349663
		h ~= h >> 13
		h *= 1274126177
		h ~= h >> 16
		return y + (f32(h & 0xffff)/65535 - 0.5)*D3_VENUE_SKIRT_RELIEF
	}
	out := make([dynamic]d3.Collision_Triangle, 0, nx*nz*2, allocator)
	for iz in 0 ..< nz {
		z0 := lo[1] + (hi[1]-lo[1])*f32(iz)/f32(nz)
		z1 := lo[1] + (hi[1]-lo[1])*f32(iz+1)/f32(nz)
		for ix in 0 ..< nx {
			x0 := lo[0] + (hi[0]-lo[0])*f32(ix)/f32(nx)
			x1 := lo[0] + (hi[0]-lo[0])*f32(ix+1)/f32(nx)
			a := [3]f32{x0, height(ix, iz, y), z0}
			b := [3]f32{x1, height(ix+1, iz, y), z0}
			c := [3]f32{x1, height(ix+1, iz+1, y), z1}
			d := [3]f32{x0, height(ix, iz+1, y), z1}
			append(&out, d3.Collision_Triangle{Points = {a, c, b}, Draw = .Terrain, Surface = .Terrain})
			append(&out, d3.Collision_Triangle{Points = {a, d, c}, Draw = .Terrain, Surface = .Terrain})
		}
	}
	return out[:]
}

// The base venue's own `tracksplit.pssg`, whose art the splice keeps. A
// deployed venue starts as a hardlink to it, and `d3_backup_once` leaves a
// `.orig` beside it the first time we write, so the backup is the base file
// from the second export on.
read_tracksplit_template :: proc(dir: string) -> (data: []u8, msg: string, ok: bool) {
	path := d3.Stock_Path(dir, "tracksplit.pssg")
	if path == "" {
		return nil, fmt.tprintf("%s holds no tracksplit.pssg to splice onto", dir), false
	}
	read, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, fmt.tprintf("could not read %s: %v", path, err), false
	}
	return read, "", true
}

// The venue's terrain surface, spliced onto the base venue's own tracksplit:
// its shader libraries and texture payloads kept, its geometry replaced by the
// whole road network's.
//
// A material-pack-only tracksplit is not game-valid at venue scope — it leaves
// the game on the loading screen forever waiting on an asset that never
// resolves — so the base file is not optional.
export_dirt3_tracksplit :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	template, template_msg, template_ok := read_tracksplit_template(job.template_dir)
	if !template_ok {
		return template_msg, false
	}
	// Dropped below the route's own surface. Both files cover the same ground —
	// stock does too, on all 103 routes that ship a real view-cell tree — and
	// stock's per-cell mask draws only one of them. A single all-visible cell
	// cannot choose, so the two would z-fight; sinking the LOD lets the route
	// win everywhere it reaches. Remove this once the VIS has real cells.
	network := collision_from_mesh(job.venue.mesh, job.venue.order, context.temp_allocator)
	for &triangle in network {
		for &point in triangle.Points {
			point[1] -= D3_VENUE_LOD_DROP
		}
	}

	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	floor := max(f32)
	for triangle in network {
		for point in triangle.Points {
			lo[0] = min(lo[0], point[0]); hi[0] = max(hi[0], point[0])
			lo[1] = min(lo[1], point[2]); hi[1] = max(hi[1], point[2])
			floor = min(floor, point[1])
		}
	}
	skirt := venue_skirt(
		{lo[0]-D3_VENUE_SKIRT_MARGIN, lo[1]-D3_VENUE_SKIRT_MARGIN},
		{hi[0]+D3_VENUE_SKIRT_MARGIN, hi[1]+D3_VENUE_SKIRT_MARGIN},
		floor-D3_VENUE_LOD_DROP,
	)
	collision := make([]d3.Collision_Triangle, len(network)+len(skirt), context.temp_allocator)
	copy(collision, network)
	copy(collision[len(network):], skirt)

	return d3.Export_Venue_Geometry(&d3.Export_Job{
		Out       = job.venue_dir,
		Backup    = job.installing,
		Collision = collision,
		Profile   = job.profile,
	}, template)
}

export_dirt3 :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	if job.profile == nil {
		return job.profile_msg, false
	}
	// The venue surface first: `track.vis` censuses it together with the
	// route's own routesplit, so it has to be on disk and current before any
	// route file is written.
	tracksplit_msg := "not written: a loose road has no venue"
	if len(job.venue.order) > 0 {
		tracksplit_ok: bool
		if tracksplit_msg, tracksplit_ok = export_dirt3_tracksplit(job); !tracksplit_ok {
			return fmt.tprintf("tracksplit.pssg: %s", tracksplit_msg), false
		}
	}
	// Ground cover next, also venue scope, also before any route file:
	// `track.vis` censuses `grass.grs` for its tag-1 boxes, so that file has to
	// be on disk and current first. Export only — nothing draws it in the
	// editor (export_dirt3_ground_cover.odin).
	cover_cells, cover_msg, cover_ok := d3_write_ground_cover(job)
	if !cover_ok {
		return fmt.tprintf("grass.grs: %s", cover_msg), false
	}

	route := make([]d3.Route_Sample, len(job.stage.ribbon), context.temp_allocator)
	for section, i in job.stage.ribbon {
		half := section.width/2
		// Dirt 3's across-vector runs the other way from ours: on every stock
		// route cross(travel, right-left).y is negative, and ours was positive.
		// A swapped pair rotates the start grid 180 degrees, because
		// d3_grid_frame takes its tangent from left->right.
		left := section.pos+section.right*half
		right := section.pos-section.right*half
		route[i] = {
			Centre = {section.pos.x,section.pos.y,section.pos.z},
			Left = {left.x,left.y,left.z},
			Right = {right.x,right.y,right.z},
		}
	}

	// Nothing of ours may stand between the kickoff or finish camera and the
	// road it frames: both shots are of the car, and a tree in front of one
	// hides it. Culled here, before anything is placed or baked from the list.
	shots := d3.Camera_Start_Finish(route)
	props, props_cut := cull_camera_trees(shots, job.props)
	placed, placed_cut := cull_camera_props(shots, job.placed)

	// The clouds next, for the same reason: `trees.bin` names them and
	// `track.vis` censuses that file. A venue whose art has no card cloud to
	// clone writes none and says so, rather than failing the export.
	billboards, billboard_msg, billboard_ok := d3_write_billboards(
		job.venue_dir, export_drawn(job), job.veg, job.roughness, props, shots,
		job.route_index, job.installing,
	)
	if !billboard_ok {
		return fmt.tprintf("billboards: %s", billboard_msg), false
	}

	timing := timing_markers(job.stage.ribbon,job.timing)
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
	drawn := export_drawn(job)
	collision := collision_from_mesh(drawn.mesh, drawn.order, context.temp_allocator)
	water, water_msg, water_ok := export_water(&drawn.terrain, context.temp_allocator)
	if !water_ok {
		return fmt.tprintf("water: %s", water_msg), false
	}
	out := d3.Export_Job{
		Name = job.name, Out = job.out, Backup = job.installing,
		Route = route, Markers = markers, Collision = collision,
		Profile = job.profile, Venue_Dir = job.venue_dir,
		Route_Index = job.route_index, Ground_Cover = cover_cells > 0,
		Service = d3_route_sample(job.setup),
		Water = water,
	}
	// Before the route files: track.vis censuses both placement files for its
	// tag-2 and tag-3 objects, so they have to be the ones this stage has.
	placement_msg, placement_ok := d3_write_placements(
		&out, job.donor_route_dir, props, placed, billboards,
	)
	if !placement_ok {
		return fmt.tprintf("placements: %s", placement_msg), false
	}
	route_msg, route_ok := d3.Export(&out)
	if !route_ok {
		return route_msg, false
	}
	return fmt.tprintf(
		"tracksplit.pssg: %s; grass.grs: %s; %s; placements: %s; billboards: %s; %d trees and %d props out of the kickoff and finish shots",
		tracksplit_msg, cover_msg, route_msg, placement_msg, billboard_msg,
		props_cut, placed_cut,
	), true
}

// One body of standing water per flooded pad.
//
// A pad that cannot be triangulated fails the export rather than being
// dropped: dropped water disappears silently.
//
// Names are positional. Nothing outside `niwater.pssg` and `niwater.xml` refers
// to a body, and the two are written together from this same list.
export_water :: proc(
	t: ^geo.Terrain, allocator := context.allocator,
) -> (bodies: []d3.Water_Body, msg: string, ok: bool) {
	out := make([dynamic]d3.Water_Body, allocator)
	for f, i in t.floors {
		level, wet := geo.floor_water_level(f)
		if !wet {
			continue
		}
		poly := geo.floor_verts(t, f)
		tris, made := geo.floor_triangulate(poly, allocator)
		if !made {
			return nil, fmt.tprintf(
				"floor %d is flooded but its %d corners do not triangulate", i, f.count,
			), false
		}
		append(&out, d3.Water_Body{
			name   = fmt.tprintf("water_%02d", i),
			y      = level,
			points = poly,
			tris   = tris,
		})
	}
	return out[:], fmt.tprintf("%d flooded", len(out)), true
}

// The scatter, minus whatever stands in one of the two shots.
cull_camera_trees :: proc(
	shots: []d3.Camera_Shot, props: []geo.Veg_Instance,
) -> (kept: []geo.Veg_Instance, cut: int) {
	if len(shots) == 0 {
		return props, 0
	}
	out := make([dynamic]geo.Veg_Instance, 0, len(props), context.temp_allocator)
	for prop in props {
		if d3.Camera_Blocks(shots, {prop.pos.x, prop.pos.y, prop.pos.z}, prop.r) {
			continue
		}
		append(&out, prop)
	}
	return out[:], len(props) - len(out)
}

// The same for props placed by hand, trees only: a hay bale or a sign at the
// finish line is set dressing, and a stage author who put one there meant it.
// Their trunk radius is not in the placement, so one nominal canopy stands for
// every species.
CULL_PROP_R :: f32(2)

cull_camera_props :: proc(
	shots: []d3.Camera_Shot, placed: []Prop_Instance,
) -> (kept: []Prop_Instance, cut: int) {
	if len(shots) == 0 {
		return placed, 0
	}
	out := make([dynamic]Prop_Instance, 0, len(placed), context.temp_allocator)
	for prop in placed {
		blocked := prop.ref.kind == .Trees_Pssg &&
		           d3.Camera_Blocks(shots, {prop.pos.x, prop.pos.y, prop.pos.z}, CULL_PROP_R*prop.scale)
		if !blocked {
			append(&out, prop)
		}
	}
	return out[:], len(placed) - len(out)
}

// One slice of road as the Dirt 3 writer wants it, across-vector and all. Used
// for the setup pin, which is one slice rather than a whole ribbon.
d3_route_sample :: proc(section: Maybe(geo.Cross_Section)) -> Maybe(d3.Route_Sample) {
	cs, placed := section.?
	if !placed {
		return nil
	}
	half := cs.width/2
	left, right := cs.pos+cs.right*half, cs.pos-cs.right*half
	return d3.Route_Sample{
		Centre = {cs.pos.x, cs.pos.y, cs.pos.z},
		Left   = {left.x, left.y, left.z},
		Right  = {right.x, right.y, right.z},
	}
}

// What each of our materials draws with and drives as, in one place.
//
// `geo.Mat_Id` stays a **single** key per triangle: in the editor a triangle is
// one thing, and splitting it there would mean carrying two arrays that agree in
// every case that exists. The two axes are separated here instead, at the one
// boundary where a target needs them apart, because a target does not have to
// keep them together — a blended run of road is one drawn material over two
// codes, and a venue with no paving texture is two codes over one material.
//
// A `Mat_Id` therefore names the finest distinction that exists: add one for
// every (drawn, drives-as) pair the editor can make, and let this table say
// which pair it is.
MAT_EXPORT := [geo.Mat_Id]struct{draw: d3.Draw_Material, surface: d3.Collision_Surface} {
	.Road       = {.Road,       .Road},
	.Cliff      = {.Cliff,      .Cliff},
	.Terrain    = {.Terrain,    .Terrain},
	.Road_Paved = {.Road_Paved, .Road_Paved},
	// The first row where the two differ, and the reason they are two: a strip
	// of ground that draws with the road's texture still drives as ground.
	.Roadside   = {.Roadside,   .Terrain},
	// Drawn as road dirt and driven as ground. Whether a dirt gutter should also
	// *grip* like the road is a separate question from what it looks like, and
	// this changes only the second.
	.Gutter     = {.Gutter,     .Terrain},
	// One drawn material over two codes, which is the whole reason the two axes
	// are two. The paint crosses the change gradually; the grip cannot.
	.Road_Change_Loose = {.Road_Change, .Road},
	.Road_Change_Paved = {.Road_Change, .Road_Paved},
}

// The triangle soup, in material order, as a target-agnostic collision list.
// Every Dirt 3 file that names geometry reads from this, at route or venue
// scope alike.
collision_from_mesh :: proc(mesh: geo.Tri_Mesh, order: []int, allocator := context.temp_allocator) -> []d3.Collision_Triangle {
	collision := make([]d3.Collision_Triangle, len(order), allocator)
	for triangle, i in order {
		export := MAT_EXPORT[mesh.mat[triangle]]
		for corner in 0..<3 {
			p := mesh.pos[triangle*3+corner]
			collision[i].Points[corner] = {p.x,p.y,p.z}
			collision[i].Blend[corner] = mesh.blend[triangle*3+corner]
		}
		collision[i].Draw = export.draw
		collision[i].Surface = export.surface
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
	// The stage being exported: every route file comes from this.
	stage:  Export_Geometry,
	// The venue's whole road network, which the venue-scope terrain surface
	// comes from. Empty for a loose road out of maps/, which has no venue.
	venue:  Export_Geometry,
	props:  []geo.Veg_Instance,  // scattered vegetation; empty when disabled
	placed: []Prop_Instance,     // props placed by hand (props.odin)
	// What `props` was generated from. The card billboards are generated inside
	// the target instead, because their sizes come off the venue's own art
	// (export_dirt3_billboards.odin), so it needs the knobs rather than a list.
	veg:       geo.Veg_Params,
	roughness: f32,
	// The editor's colours for this venue's ground. Carried because the glTF
	// target paints its materials with them, so an import looks like the editor
	// it came out of. No game target reads it.
	look:      geo.Look,
	// Which shaders the stage draws with, resolved from the open venue or from
	// the venue the selected route lives in. Only the Dirt 3 target needs it,
	// so a failure to resolve one is carried rather than raised.
	profile:     ^d3.Venue_Profile,
	profile_msg: string,
	// Which route of its venue this is, parsed from a `route_n` id. Camera and
	// cutscene idents are built from it.
	route_index:     int,
	// See export_venue_dirs.
	venue_dir:       string,
	template_dir:    string,
	donor_route_dir: string,
	// Where the setup screen stands, from the stage's setup pin, resolved on
	// the venue road. Unset leaves it to the target's own default.
	setup:  Maybe(geo.Cross_Section),
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

// One spline's geometry, built the way the viewport builds it: the ribbon, the
// ground fitted to that ribbon, and the soup of both with every triangle
// tagged. This is the CPU half of `rebuild_geometry` and nothing else, so no GL
// context is involved and it runs headless.
//
// The terrain is included as a *driveable* surface, not scenery — a target that
// makes the mesh its own collision must not let a car that leaves the road fall
// through the void.
//
// An export builds this twice: once for the stage being exported, once for the
// venue's whole road network the terrain surface comes from. `terrain` is a
// clone of the document's because one Terrain cannot be fitted to two ribbons
// without smearing its sculpt — see geo.terrain_clone.
Export_Geometry :: struct {
	ribbon:  []geo.Cross_Section,
	terrain: geo.Terrain,
	field:   geo.Terrain_Field,
	mesh:    geo.Tri_Mesh,
	order:   []int, // triangle indices, sorted by material
	counts:  [geo.Mat_Id]int,
}

// Everything but `terrain` and `field` is temp-allocated; those two own heap
// arrays of their own.
export_geometry_delete :: proc(g: ^Export_Geometry) {
	geo.terrain_delete(&g.terrain)
	geo.terrain_field_delete(&g.field)
	g^ = {} // safe to delete twice
}

build_geometry :: proc(doc: ^Venue_Doc, spline: geo.Spline) -> (g: Export_Geometry, msg: string, ok: bool) {
	if len(spline.points) < 2 {
		return g, "nothing to export: a road needs at least 2 points", false
	}
	g.ribbon = geo.build_ribbon(spline, allocator = context.temp_allocator)
	g.terrain = geo.terrain_clone(&doc.terrain)
	if g.terrain.enabled {
		geo.terrain_ensure(&g.terrain, g.ribbon, doc.roughness)
		arc := geo.ribbon_arc(g.ribbon)
		ds := geo.sample_spacing(g.ribbon)
		// A fresh field is always rebuilt, so the generation only gets stored.
		geo.terrain_field_ensure(&g.field, &g.terrain, g.ribbon, arc, ds, doc.roughness, 1)
	}
	g.mesh = geo.build_tri_mesh(g.ribbon, doc.roughness, doc.look, context.temp_allocator)
	if g.terrain.enabled && len(g.field.tris) > 0 {
		geo.build_terrain_mesh(&g.mesh, &g.terrain, &g.field, g.ribbon, doc.roughness, doc.look)
	}
	g.order, g.counts = sort_faces_by_material(g.mesh)
	if len(g.order) == 0 {
		return g, "nothing to export: the mesh has no triangles", false
	}
	return g, "", true
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

// The geometry the ground comes from: the venue's whole road network when there
// is one, because a route draws and collides all of it, not just its own chain.
// Anything that must agree with the ground reads this, never `stage` — a tree
// placed off the stage field stands on ground the venue field built, and the
// two disagree by the height gap between the nearest chain leg and the nearest
// branch.
export_drawn :: proc(job: ^Export_Job) -> ^Export_Geometry {
	return len(job.venue.order) > 0 ? &job.venue : &job.stage
}

// Everything the editor holds, flattened for a target. `stage` is the one
// chain being exported, compiled out of `doc.spline`; a loose road out of
// maps/ is its own chain and passes itself.
//
// Temp-allocated, except the two geometries' terrain — release with
// export_job_delete.
build_export_job :: proc(doc: ^Venue_Doc, stage: geo.Spline, name: string) -> (job: Export_Job, msg: string, ok: bool) {
	job.name = name
	job.stage, msg, ok = build_geometry(doc, stage)
	if !ok {
		return
	}
	// The venue's whole road network, which the terrain surface is built from.
	// A loose road has no venue and is its own network, so it is not built twice.
	if doc.open_venue != "" {
		job.venue, msg, ok = build_geometry(doc, doc.spline)
		if !ok {
			return job, fmt.tprintf("road network: %s", msg), false
		}
	}
	job.timing = doc.timing
	// glTF needs no shaders, so a missing profile is only fatal for the target
	// that names them.
	if p, _, loaded := venue_of_doc(doc, context.temp_allocator); loaded {
		job.profile, job.profile_msg, _ = export_profile(doc.install, p, context.temp_allocator)
	} else {
		job.profile_msg = "this road belongs to no venue, so it has no shaders"
	}
	ground := export_drawn(&job)
	job.props = geo.veg_generate(
		ground.ribbon,
		&ground.terrain,
		doc.veg,
		doc.roughness,
		context.temp_allocator,
	)
	job.placed = doc.props[:]
	job.veg, job.roughness, job.look = doc.veg, doc.roughness, doc.look

	// The headless path leaves doc.pace zero-valued, which would read as "every
	// knob at zero" rather than "unset".
	job.pace = doc.pace.smooth_m != 0 ? doc.pace : geo.PACE_DEFAULTS
	notes := make([dynamic]geo.Pace_Note, context.temp_allocator)
	geo.pace_generate(job.stage.ribbon, job.pace, &notes)
	job.notes = notes[:]

	return job, "", true
}

export_job_delete :: proc(job: ^Export_Job) {
	export_geometry_delete(&job.stage)
	export_geometry_delete(&job.venue)
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
	stage_id: string,
	target: ^Export_Target,
) -> (
	dir: string,
	installing: bool,
	msg: string,
	ok: bool,
) {
	if target.installs && !doc.debug_export {
		// The stage goes to its venue's own route directory inside the game.
		// That directory only exists once the venue has been deployed, which is
		// a separate step — so say so, rather than creating a directory the
		// game never reads.
		route, deployed := venue_deploy_dir(doc, stage_id)
		if !deployed {
			return "", false, fmt.tprintf(
				"%s is not in the game yet; tick Write to out/ until deploying exists",
				doc.venue_name,
			), false
		}
		return route, true, "", true
	}
	// Two venues can both hold a `route_0`, so the debug detour keeps them
	// apart by venue. By name and not by id: out/ is somewhere a person looks.
	dir, _ = filepath.join(
		{out_dir(), sanitise_venue_name(doc.venue_name), stage_id}, context.temp_allocator,
	)
	return dir, false, "", true
}

// The directories a stage export reads its art from and writes venue-scope
// files to.
//
// `venue_dir` holds the `tracksplit.pssg` the game loads beside this route, so
// it is where `track.vis` censuses and where a venue export writes its own.
// `template_dir` holds the base venue's tracksplit, whose art the splice keeps;
// the debug detour separates the two, writing under `out/` while splicing the
// base's.
//
// `donor_route_dir` is the base route this stage takes its trees, ornaments and
// rigid bodies from. It is the base route in the install either way, never the
// output directory: an export must read stock art rather than its own last
// output, and the debug detour keeps no backup there to fall back to.
export_venue_dirs :: proc(doc: ^Venue_Doc, out: string, installing: bool) -> (venue_root, template_dir, donor_route_dir: string) {
	venue_root = filepath.dir(out)
	template_dir = venue_root
	donor_route_dir = out
	if p, _, loaded := venue_of_doc(doc, context.temp_allocator); loaded {
		if venue, route, found := venue_source(doc.install, p); found {
			donor_route_dir = route.dir
			if !installing {
				template_dir = venue.dir
			}
		}
	}
	return
}

// The stage's setup pin as a slice of road, or nothing when it has none or the
// road it named is gone. The venue graph, not the compiled stage: the setup
// screen is somewhere to stand, and nothing says it has to be on the stage.
route_setup_section :: proc(doc: ^Venue_Doc, stage_id: string) -> Maybe(geo.Cross_Section) {
	i := route_index(doc.routes[:], stage_id)
	if i < 0 {
		return nil
	}
	at, on_road := geo.marker_resolve(doc.spline, doc.routes[i].setup)
	if !on_road {
		return nil
	}
	return geo.sample_edge(doc.spline, at.from, at.to, clamp(at.t, 0, 1))
}

// The `n` of a `route_n` id.
route_number :: proc(stage_id: string) -> int {
	digits := strings.trim_prefix(stage_id, "route_")
	if digits == stage_id {
		return 0
	}
	n, parsed := strconv.parse_int(digits, 10)
	return parsed && n >= 0 ? n : 0
}

// Build the job and hand it to one target. Returns a status-line message.
//
// `stage` is the one chain being exported, compiled out of the venue's road
// graph. `doc.spline` stays the graph, because the venue surface is built from
// all of it.
//
// `stage_id` names which of the venue's stages this is, and is what picks the
// route directory inside the game. It is empty for a loose stage out of maps/,
// which has no venue and lands in the selected install route instead.
export_stage :: proc(
	doc: ^Venue_Doc, stage: geo.Spline, name, stage_id: string, target: ^Export_Target,
) -> (msg: string, ok: bool) {
	job, jmsg, jok := build_export_job(doc, stage, name)
	defer export_job_delete(&job)
	if !jok {
		return jmsg, false
	}
	dest, installing, dmsg, dok := export_dest(doc, stage_id, target)
	if !dok {
		return dmsg, false
	}
	job.out, job.installing = dest, installing
	job.route_index = route_number(stage_id)
	job.setup = route_setup_section(doc, stage_id)
	job.venue_dir, job.template_dir, job.donor_route_dir = export_venue_dirs(doc, dest, installing)
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
	if venue == "" {
		return "an export needs --venue <id>; see --venues", false
	}

	// The install scan is the only thing that knows where the game is, so a
	// headless export into it needs the scan too.
	scan: Install_Scan
	doc := Venue_Doc {
		install   = &scan,

		terrain   = geo.TERRAIN_DEFAULTS,
		pace      = geo.PACE_DEFAULTS,
		veg       = geo.VEG_DEFAULTS,
	}
	doc.debug_export = debug_out
	install_scan_init(doc.install)
	defer install_scan_delete(doc.install)
	defer geo.spline_free(&doc.spline)
	defer geo.terrain_delete(&doc.terrain)

	// `doc.spline` is the venue's whole road graph; `chain` is the one stage
	// being exported, compiled out of it.
	p, pmsg, pok := venue_find(venue, context.temp_allocator)
	if !pok { return pmsg, false }
	doc.open_venue = p.id
	doc.venue_name = p.name
	chain, cmsg, cok := venue_compile_route(p, stage, &doc, context.allocator)
	if !cok { return cmsg, false }
	defer geo.spline_free(&chain)
	// The document owns the sculpt and the sliders. The flag only forces ground
	// on for a road that has none.
	doc.terrain.enabled = doc.terrain.enabled || terrain
	return export_stage(&doc, chain, stage, stage, target)
}
