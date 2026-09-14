package main

// dirtbench — a DiRT 3 rally road editor.
//
// Editor slice: raylib viewport with an orbiting camera over a smooth,
// tangent-driven road ribbon. The road is a chain of oriented control points
// (geo/spline.odin); selecting one shows a translate+rotate gizmo (gizmo.odin,
// over the ImGuizmo binding in ui/) so it can be steered, sloped and banked.
// Right-click inserts a point into the road under the cursor, or appends one on
// open ground. Panels are Dear ImGui, through ui/imgui.odin.
//
// dirtbench boots into the venue screen (venues_ui.odin), not here: a road
// with no venue around it is what produced every runtime failure so far, so
// picking the world comes before drawing in it. A finished road goes to an
// export target (export.odin), and the editor does not know which game that is.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import d3 "../d3"
import "../geo"
import "../ui"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

WINDOW_W :: 1280
WINDOW_H :: 800

GROUND_Y :: 0.0

// Render distance: 10x rlgl's stock 0.01..1000, so a multi-kilometre stage is
// visible end to end. Near moves with far, keeping the far/near ratio — and so
// the depth-buffer precision — exactly as it was.
CAM_NEAR :: 0.1
CAM_FAR :: 10_000.0

// How far the wheel can pull the camera back. Tracks CAM_FAR.
CAM_DIST_MIN :: 5.0
CAM_DIST_MAX :: 8000.0

// Ground grid, sized to the new view distance: slices * spacing metres across.
GRID_SLICES :: 256
GRID_SPACING :: 32

// Camera feel (dialled back 3x from the initial values).
ORBIT_SENS :: 0.00167 // radians per pixel of MMB drag
PAN_SENS :: 0.0005    // world units per pixel, scaled by distance
ZOOM_SENS :: 0.1      // fraction of distance per wheel notch

// --- Editor state -----------------------------------------------------------

Orbit_Camera :: struct {
	target:   rl.Vector3,
	distance: f32,
	yaw:      f32, // orbit angle about +Y
	pitch:    f32, // elevation
}

// Which manipulation the gizmo offers. Bound to the 1 / 2 keys.
Gizmo_Mode :: enum {
	Move,
	Rotate,
}

// What the gizmo is pointed at. A bare index cannot say, now that a spline
// control point and a terrain lattice node are both selectable.
Sel_Kind :: enum {
	None,
	Point, // idx indexes geo.Spline points
	Node,  // idx indexes one side's lattice, r*cols + c; `side` says which
}

Selection :: struct {
	kind: Sel_Kind,
	idx:  int,
	side: int,
}

// What the window is showing. Boot is Venues; the editor is what you get
// after opening a route inside a venue.
App_Mode :: enum {
	Venues,
	Editor,
}

// How long a save/load result stays on screen, seconds.
STATUS_LINGER :: 8.0

// Global tessellation density: ribbon samples per spline segment. Also drives
// how many vertical rows a cliff face gets (see cliff_rows).
TOPO_MIN :: 2
TOPO_MAX :: 48

Editor :: struct {
	mode:          App_Mode,
	screen:        Venues_Screen,
	// Which venue stage the editor has open, "" when it is a loose stage out of
	// maps/. Saving writes back to the venue.
	open_venue:  string,
	open_stage:    string,
	// Start and finish of the venue's first stage, while its road is open. They
	// belong to venue.json and are written back when the road is saved.
	start:         geo.Road_Marker,
	finish:        geo.Road_Marker,
	// Editing a stage, not the venue. A stage is two markers on the venue road
	// and nothing else, so the road itself is read-only here: no insert, no
	// branch, no weld, no delete, and the gizmo does not move a control point.
	stage_mode:    bool,
	spline:        geo.Spline,
	cam:           Orbit_Camera,
	sel:           Selection,
	gizmo_active:  bool,
	gizmo_hovered: bool,
	gizmo_mode:    Gizmo_Mode,
	show_demo:     bool,
	show_gen:      bool, // the Stage generator panel; toggled from the menubar
	show_targets:  bool, // the Export targets panel
	debug_export:  bool, // write to out/ instead of into the game (export.odin)
	gen:           Gen_Params,
	install:       Install_Scan,
	gen_live:      bool, // regenerate while a slider is being dragged
	quit:          bool,

	// Geometry. `ribbon`, `road` and `terrain_mesh` are caches rebuilt from
	// `spline` (and `terrain`) whenever `dirty` is set — never read them without
	// going through mark_dirty/rebuild.
	ribbon:        []geo.Cross_Section,
	// Ticks on every ribbon rebuild. The terrain's world grid is keyed on it, so
	// dragging a lattice node reuses the grid instead of rebuilding it.
	ribbon_gen:    u64,
	road:          geo.Gpu_Mesh,
	terrain:       geo.Terrain,
	terrain_field: geo.Terrain_Field,
	terrain_mesh:  geo.Gpu_Mesh,
	material:      rl.Material,
	// Two flags, not one: the road is cheap to rebuild and the terrain is not.
	dirty_road:    bool,
	dirty_terrain: bool,
	topo:          c.int, // ribbon samples per spline segment
	roughness:     f32,   // global roughness: road vertical jitter + cliff jitter, 0..1
	wireframe:     bool,

	// Pace notes, derived from the ribbon (pacenote.odin). Recomputed with the
	// road, since both are caches of the spline.
	pace:          geo.Pace_Params,
	notes:         [dynamic]geo.Pace_Note,
	timing:        Timing_Params,

	// Vegetation scatter (vegetation.odin). Part of the document, handed to the
	// export target and drawn as placeholder shapes in the viewport.
	veg:           geo.Veg_Params,
	// The generated scatter, cached so it is drawn every frame but regenerated only
	// when a veg knob changes or the ribbon rebuilds — generating rebuilds the
	// terrain field, too costly per frame. Persistent-allocated; freed on shutdown.
	veg_cache:     []geo.Veg_Instance,
	veg_gen:       u64, // ribbon_gen the cache was built at; a mismatch forces a refresh
	veg_dirty:     bool,

	// Preview ride: a cursor advances along the spline by arc, firing each note's
	// VO clips as it passes the trigger station.
	previewing:    bool,
	preview_speed: f32, // metres/second
	preview_s:     f32, // current arc station
	preview_pos:   rl.Vector3,
	preview_next:  int, // index of the next note to fire
	preview_last:  int, // index of the last note fired (for the HUD), or -1
	clips:         map[string]rl.Sound, // basename -> decoded OGG
	play_q:        [dynamic]rl.Sound,   // clips to play back-to-back
	play_i:        int,
	play_started:  bool,

	// ImGui edits this buffer in place, so it is a fixed C string, not a string.
	stage_name:    [64]u8,
	// Result of the last save/load. Copied, because the messages come off the
	// temp allocator, which is reset every frame.
	status:        [256]u8,
	status_ok:     bool,
	status_at:     f64, // rl.GetTime() when set
}

// --- selection --------------------------------------------------------------

// The selected control point, or -1. Validates the index: an edit or a load can
// shrink the spline under a stale selection.
selected_point :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Point && ed.sel.idx >= 0 && ed.sel.idx < len(ed.spline.points) {
		return ed.sel.idx
	}
	return -1
}

// The selected node's index into `node_pos` (see terrain_node_world), or -1.
selected_node :: proc(ed: ^Editor, node_pos: []rl.Vector3) -> int {
	if ed.sel.kind != .Node || len(node_pos) == 0 {
		return -1
	}
	i := ed.sel.side * geo.terrain_node_count(&ed.terrain) + ed.sel.idx
	if i < 0 || i >= len(node_pos) {
		return -1 // lattice was resized under the selection
	}
	return i
}

// --- geometry cache ---------------------------------------------------------

// Call after *any* mutation of the spline or of topo/roughness. The terrain is
// carved to the road — its inner edge is the verge seam — so a spline edit
// invalidates it too. Cheap: the rebuilds happen at the top of the next frame.
mark_dirty :: proc(ed: ^Editor) {
	ed.dirty_road = true
	ed.dirty_terrain = true
	ed.veg_dirty = true
}

// For edits that leave the ribbon alone: lattice nodes, terrain sliders. These
// still move the ground under the trees, so the scatter is stale too — but the
// ribbon_gen it keys on has not ticked, hence the explicit flag.
mark_terrain_dirty :: proc(ed: ^Editor) {
	ed.dirty_terrain = true
	ed.veg_dirty = true
}

geometry_stale :: proc(ed: ^Editor) -> bool {
	return ed.dirty_road || ed.dirty_terrain
}

// Resample the ribbon and re-upload whichever mesh went stale. The ribbon is
// kept because picking and the handle overlay both read it, and it is the input
// to both meshes.
//
// The terrain is several times the road's triangle count, so rebuilding it every
// frame of a control-point drag is the one thing that makes a big stage feel
// sluggish. Defer it: the road follows the gizmo live, the terrain snaps to it on
// release. Dragging a *lattice node* is exempt — the terrain is the only thing
// changing, and watching it move is the entire point.
//
// `gizmo_active` is last frame's value here, which is what we want: the frame a
// drag ends it is already false, so the deferred rebuild lands immediately.
rebuild_geometry :: proc(ed: ^Editor) {
	if ed.dirty_road {
		delete(ed.ribbon)
		ed.ribbon = geo.build_ribbon(ed.spline, int(ed.topo), context.allocator)
		ed.ribbon_gen += 1
		geo.road_mesh_rebuild(&ed.road, ed.ribbon, ed.topo, ed.roughness)
		if geo.is_linear(ed.spline) {
			geo.pace_generate(ed.ribbon, ed.pace, &ed.notes)
		} else {
			clear(&ed.notes)
		}
		ed.dirty_road = false
	}
	if ed.dirty_terrain && !(ed.gizmo_active && ed.sel.kind == .Point) {
		// Terrain, vegetation and pace notes become stage products once a path
		// through the venue graph is chosen. Do not join independent branches
		// into an accidental mega-ribbon in the meantime.
		if !geo.is_linear(ed.spline) {
			geo.gpu_mesh_unload(&ed.terrain_mesh)
			delete(ed.veg_cache)
			ed.dirty_terrain = false
			return
		}
		geo.terrain_ensure(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
		geo.terrain_mesh_rebuild(
			&ed.terrain_mesh, &ed.terrain_field, &ed.terrain,
			ed.ribbon, ed.topo, ed.roughness, ed.ribbon_gen,
		)
		ed.dirty_terrain = false
	}
}

// Regenerate the vegetation cache when it is stale — a knob moved (`veg_dirty`) or
// the ribbon rebuilt under it (`veg_gen` behind `ribbon_gen`). A no-op otherwise,
// so it is safe to call every frame. Generating rebuilds the terrain field, which
// is why the result is cached rather than produced live.
veg_refresh :: proc(ed: ^Editor) {
	if !geo.is_linear(ed.spline) {
		delete(ed.veg_cache)
		ed.veg_gen = ed.ribbon_gen
		ed.veg_dirty = false
		return
	}
	if !ed.veg_dirty && ed.veg_gen == ed.ribbon_gen {
		return
	}
	// Generating rebuilds the terrain field, so defer while a gizmo drags — the
	// trees snap to the new ground on release, the same way the terrain mesh does
	// for a point drag. `gizmo_active` is last frame's value, so the release frame
	// lands the rebuild.
	if ed.gizmo_active {
		return
	}
	delete(ed.veg_cache)
	ed.veg_cache = geo.veg_generate(ed.ribbon, &ed.terrain, ed.veg, ed.topo, ed.roughness)
	ed.veg_gen = ed.ribbon_gen
	ed.veg_dirty = false
}

// --- status line ------------------------------------------------------------

set_status :: proc(ed: ^Editor, msg: string, ok: bool) {
	n := min(len(msg), len(ed.status) - 1)
	copy(ed.status[:n], msg[:n])
	ed.status[n] = 0
	ed.status_ok = ok
	ed.status_at = rl.GetTime()
}

status_text :: proc(ed: ^Editor) -> (text: cstring, ok: bool) {
	if ed.status[0] == 0 || rl.GetTime() - ed.status_at > STATUS_LINGER {
		return nil, false
	}
	return cstring(raw_data(ed.status[:])), true
}

// The stage name as ImGui left it in the buffer: NUL-terminated, unsanitised.
stage_name_text :: proc(ed: ^Editor) -> string {
	return string(cstring(raw_data(ed.stage_name[:])))
}

set_stage_name :: proc(ed: ^Editor, name: string) {
	n := min(len(name), len(ed.stage_name) - 1)
	copy(ed.stage_name[:n], name[:n])
	ed.stage_name[n] = 0
}

// --- Camera -----------------------------------------------------------------

to_camera3d :: proc(oc: Orbit_Camera) -> rl.Camera3D {
	cpitch := math.cos(oc.pitch)
	offset := rl.Vector3{
		math.sin(oc.yaw) * cpitch,
		math.sin(oc.pitch),
		math.cos(oc.yaw) * cpitch,
	}
	pos := oc.target + offset * oc.distance
	return rl.Camera3D{
		position   = pos,
		target     = oc.target,
		up         = {0, 1, 0},
		fovy       = 55,
		projection = .PERSPECTIVE,
	}
}

// Alt is the viewport-navigation modifier: Alt+LMB pans (ground plane only),
// Alt+RMB orbits, and the wheel zooms — the only control that moves the camera
// vertically. While Alt is held the gizmo ignores the mouse (see gizmo_enable)
// so an Alt-drag that starts on a gizmo axis still navigates.
alt_held :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
}

update_camera :: proc(oc: ^Orbit_Camera) {
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		oc.distance *= (1 - wheel * ZOOM_SENS)
		oc.distance = clamp(oc.distance, CAM_DIST_MIN, CAM_DIST_MAX)
	}
	if !alt_held() {
		return
	}
	delta := rl.GetMouseDelta()
	if rl.IsMouseButtonDown(.LEFT) {
		cam := to_camera3d(oc^)
		fwd := rl.Vector3Normalize(cam.target - cam.position)
		// `right` is cross(fwd, worldUp), so it already lies in the ground plane.
		right := rl.Vector3Normalize(rl.Vector3CrossProduct(fwd, cam.up))
		// Flatten camera-up onto the ground plane so panning never changes height;
		// the wheel is the only thing that moves the camera vertically. Near a
		// top-down pitch the projection degenerates, so fall back to flat forward.
		up := rl.Vector3CrossProduct(right, fwd)
		up_flat := rl.Vector3{up.x, 0, up.z}
		if rl.Vector3Length(up_flat) < 1e-4 {
			up_flat = rl.Vector3{fwd.x, 0, fwd.z}
		}
		up_flat = rl.Vector3Normalize(up_flat)

		speed := oc.distance * PAN_SENS
		oc.target = oc.target + right * (-delta.x * speed)
		oc.target = oc.target + up_flat * (delta.y * speed)
	} else if rl.IsMouseButtonDown(.RIGHT) {
		oc.yaw -= delta.x * ORBIT_SENS
		oc.pitch += delta.y * ORBIT_SENS
		oc.pitch = clamp(oc.pitch, -1.5, 1.5)
	}
}

// --- Picking ----------------------------------------------------------------

ray_ground :: proc(ray: rl.Ray) -> (hit: rl.Vector3, ok: bool) {
	if abs(ray.direction.y) < 1e-6 {
		return {}, false
	}
	t := (GROUND_Y - ray.position.y) / ray.direction.y
	if t < 0 {
		return {}, false
	}
	return ray.position + ray.direction * t, true
}

// nearest control point the ray strikes, or -1. The distance comes back too, so
// a click can be arbitrated against a terrain node hit (see pick_terrain_node).
pick_point :: proc(sp: geo.Spline, ray: rl.Ray) -> (idx: int, dist: f32) {
	idx = -1
	dist = max(f32)
	for p, i in sp.points {
		c := rl.GetRayCollisionSphere(ray, p.xform.translation, geo.handle_radius(p.width))
		if c.hit && c.distance < dist {
			dist = c.distance
			idx = i
		}
	}
	return
}

// first ribbon quad the ray hits. Returns the parent segment, the hit point,
// and the road frame there (for orienting an inserted point). ok=false on miss.
pick_ribbon :: proc(
	ribbon: []geo.Cross_Section,
	ray: rl.Ray,
) -> (
	seg: int,
	at: rl.Vector3,
	frame: geo.Cross_Section,
	ok: bool,
) {
	best_dist := max(f32)
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		la, ra := geo.xsec_ends(ribbon[i])
		lb, rb := geo.xsec_ends(ribbon[i + 1])
		c := rl.GetRayCollisionQuad(ray, la, ra, rb, lb)
		if c.hit && c.distance < best_dist {
			best_dist = c.distance
			seg = ribbon[i].seg
			at = c.point
			frame = ribbon[i]
			ok = true
		}
	}
	return
}

// --- Rendering --------------------------------------------------------------

draw_centreline :: proc(ribbon: []geo.Cross_Section) {
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		rl.DrawLine3D(ribbon[i].pos, ribbon[i + 1].pos, {235, 200, 60, 255})
	}
}

// Grow the road at `g`. With a point selected the new node is its child, which
// is a branch when that point already had one. With no selection it appends to
// the tail, the old behaviour.
grow_road :: proc(sp: ^geo.Spline, from: int, g: rl.Vector3) -> int {
	if from < 0 || from >= len(sp.points) {
		return geo.append_point(sp, g)
	}
	idx := geo.extrude_point(sp, from)
	if idx < 0 || idx >= len(sp.points) {
		return idx
	}
	p := &sp.points[idx]
	p.xform.translation = g
	// Extruding the head grows backwards, so that node is aimed at its child
	// instead of away from a parent it does not have.
	if p.parent >= 0 {
		p.xform.rotation = geo.heading_quat(sp.points[p.parent].xform.translation, g)
	} else if child := geo.first_child(sp^, idx); child >= 0 {
		p.xform.rotation = geo.heading_quat(g, sp.points[child].xform.translation)
	}
	return idx
}

// A start or finish line, drawn across the road where it sits.
draw_marker :: proc(sp: geo.Spline, m: geo.Road_Marker, col: rl.Color) {
	if !geo.marker_valid(sp, m) {
		return
	}
	cs := geo.sample_edge(sp, m.from, m.to, clamp(m.t, 0, 1))
	l, r := geo.xsec_ends(cs)
	rl.DrawLine3D(l, r, col)
	rl.DrawLine3D(l, l + cs.up * 4, col)
	rl.DrawLine3D(r, r + cs.up * 4, col)
}

draw_handles :: proc(sp: geo.Spline, selected: int) {
	for p, i in sp.points {
		// A weld is an edge with no ribbon handle of its own, so draw the join
		// itself or there is no way to see that a loop is closed.
		if p.weld >= 0 && p.weld < len(sp.points) {
			rl.DrawLine3D(
				p.xform.translation,
				sp.points[p.weld].xform.translation,
				{255, 200, 90, 255},
			)
		}
		l, r := geo.point_ends(p)
		rl.DrawLine3D(l, r, {200, 210, 225, 255}) // rung
		hcol := i == selected ? rl.Color{255, 120, 60, 255} : rl.Color{120, 200, 255, 255}
		rl.DrawSphere(p.xform.translation, geo.handle_radius(p.width), hcol)
		// forward + up ticks so orientation is legible
		fwd_tip := p.xform.translation + geo.point_forward(p) * (p.width * 0.5)
		up_tip := p.xform.translation + geo.point_up(p) * (p.width * 0.4)
		rl.DrawLine3D(p.xform.translation, fwd_tip, {120, 255, 150, 255})
		rl.DrawLine3D(p.xform.translation, up_tip, {150, 180, 255, 255})
	}
}

// --- Main -------------------------------------------------------------------

seed_spline :: proc(sp: ^geo.Spline) {
	clear(&sp.points)
	// a short starter road with a rise and a gentle bend to show it off
	seeds := [?]rl.Vector3{{0, 0, 0}, {0, 2, 32}, {12, 5, 60}, {26, 6, 88}}
	for pos, i in seeds {
		rot := rl.Quaternion(1)
		if i > 0 {
			rot = geo.heading_quat(seeds[i - 1], pos)
		}
		append(&sp.points, geo.make_point(pos, rot, geo.DEFAULT_WIDTH, parent = i - 1))
	}
	if len(sp.points) > 1 {
		sp.points[0].xform.rotation = sp.points[1].xform.rotation
	}
}

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

main :: proc() {
	if run_cli() {
		return
	}
	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(WINDOW_W, WINDOW_H, "dirtbench")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	// Must come after InitWindow: rlgl installs its defaults there.
	rlgl.SetClipPlanes(CAM_NEAR, CAM_FAR)

	ui.rlImGuiSetup(true) // dark theme
	defer ui.rlImGuiShutdown()

	// Audio must come up before LoadSound. The pace-note clips are decoded here.
	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()
	rl.SetMasterVolume(1.0)

	ed := Editor{
		cam = {target = {10, 3, 48}, distance = 110, yaw = 0.6, pitch = 0.6},
		gen = GEN_DEFAULTS,
		gen_live = true,
		topo = geo.SAMPLES_PER_SEG,
		roughness = 0.5,
		terrain = geo.TERRAIN_DEFAULTS,
		preview_speed = 30, // ~108 km/h
		pace = geo.PACE_DEFAULTS,
		timing = TIMING_DEFAULTS,
		veg = geo.VEG_DEFAULTS,
	}
	ed.notes = make([dynamic]geo.Pace_Note)
	defer delete(ed.notes)
	ed.play_q = make([dynamic]rl.Sound)
	defer delete(ed.play_q)
	ed.clips = pace_audio_load()
	defer pace_audio_unload(&ed.clips)

	install_scan_init(&ed.install)
	defer install_scan_delete(&ed.install)
	venues_screen_init(&ed.screen)
	defer venues_screen_delete(&ed.screen)
	defer delete(ed.open_venue)
	defer delete(ed.open_stage)
	set_stage_name(&ed, "untitled")
	seed_spline(&ed.spline)
	defer delete(ed.spline.points)

	ed.material = rl.LoadMaterialDefault()
	defer rl.UnloadMaterial(ed.material)
	defer geo.gpu_mesh_unload(&ed.road)
	defer geo.gpu_mesh_unload(&ed.terrain_mesh)
	defer geo.terrain_delete(&ed.terrain)
	defer geo.terrain_field_delete(&ed.terrain_field)
	defer delete(ed.ribbon)
	defer delete(ed.veg_cache)
	mark_dirty(&ed)

	for !rl.WindowShouldClose() && !ed.quit {
		// The venue screen is its own frame: no viewport, no camera, no
		// geometry rebuild. Opening a route switches the mode and the next
		// frame is the editor's.
		if ed.mode == .Venues {
			draw_venues_frame(&ed)
			continue
		}

		// ImGui gets first refusal on input: a click on a panel, or a keypress
		// into a text field, must never also reach the viewport behind it.
		ui_mouse := ui.imgui_want_capture_mouse()
		ui_keys := ui.imgui_want_capture_keyboard()

		// 1 = move, 2 = rotate, Ctrl+S = save
		if !ui_keys {
			if rl.IsKeyPressed(.ONE) {
				ed.gizmo_mode = .Move
			}
			if rl.IsKeyPressed(.TWO) {
				ed.gizmo_mode = .Rotate
			}
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			if ctrl && rl.IsKeyPressed(.S) && len(ed.spline.points) >= 2 {
				do_save(&ed)
			}
		}

		// Alt owns the mouse for camera navigation; the gizmo must not grab it.
		nav := alt_held()
		ui.gizmo_enable(!nav)
		if !ui_mouse && (nav || !ed.gizmo_active) {
			update_camera(&ed.cam)
		}
		cam3d := to_camera3d(ed.cam)
		ray := rl.GetScreenToWorldRay(rl.GetMousePosition(), cam3d)

		// Shift + grabbing the gizmo extrudes: duplicate the selected point and
		// drag the copy outward, growing the spline at its ends. This must run
		// before gizmo_manipulate, which processes the press later this frame,
		// so the drag latches onto the copy. gizmo_hovered is last frame's
		// probe, which is accurate at the instant of the press.
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if rl.IsMouseButtonPressed(.LEFT) &&
		   shift && !nav && !ui_mouse && !ed.gizmo_active && !ed.stage_mode &&
		   selected_point(&ed) >= 0 &&
		   ed.gizmo_hovered {
			ed.sel = {kind = .Point, idx = geo.extrude_point(&ed.spline, ed.sel.idx)}
			mark_dirty(&ed)
		}

		// One rebuild per frame, after every mutation above has landed.
		if geometry_stale(&ed) {
			rebuild_geometry(&ed)
		}
		// Regenerate the scatter if a rebuild (or a veg edit) invalidated it.
		veg_refresh(&ed)

		// Advance the preview ride and fire pace-note clips. Cheap when idle.
		// The ride moves the camera target, so rebuild the view matrix from it.
		preview_update(&ed)
		if ed.previewing {
			cam3d = to_camera3d(ed.cam)
		}

		// Node handles are derived from the ribbon and the lattice, so they are
		// recomputed after the rebuild and shared by drawing, picking and the
		// gizmo. Temp-allocated: valid for this frame only.
		node_pos := geo.terrain_node_world(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
		sel_node := selected_node(&ed, node_pos)

		rl.BeginDrawing()
		rl.ClearBackground({26, 28, 34, 255})
		rl.BeginMode3D(cam3d)
		rl.DrawGrid(GRID_SLICES, GRID_SPACING)
		geo.gpu_mesh_draw(ed.terrain_mesh, ed.material, ed.wireframe)
		geo.gpu_mesh_draw(ed.road, ed.material, ed.wireframe)
		// After the opaque ground, so the translucent canopies blend over it.
		geo.veg_draw(ed.veg_cache)
		draw_centreline(ed.ribbon)
		draw_timing_markers(timing_markers(ed.ribbon,ed.timing))
		geo.draw_terrain_nodes(&ed.terrain, node_pos, sel_node)
		draw_handles(ed.spline, selected_point(&ed))
		draw_marker(ed.spline, ed.start, {110, 255, 140, 255})
		draw_marker(ed.spline, ed.finish, {255, 110, 110, 255})
		if ed.previewing {
			rl.DrawSphere(ed.preview_pos, 2.0, {255, 210, 80, 255})
		}
		rl.EndMode3D()

		// Ride HUD: the current call, so firing is visible even with audio off.
		if ed.previewing && ed.preview_last >= 0 && ed.preview_last < len(ed.notes) {
			txt := fmt.ctprintf("%s", geo.pace_note_text(ed.notes[ed.preview_last]))
			tw := rl.MeasureText(txt, 40)
			rl.DrawText(txt, (rl.GetScreenWidth() - tw) / 2, 40, 40, {255, 220, 120, 255})
		}

		// --- ImGui frame (the gizmo both draws and reports interaction) ----
		// ImGuizmo draws into an ImGui draw list, so it lives here rather than
		// inside BeginMode3D, and projects itself with the camera's matrices.
		ui.rlImGuiBegin()
		ui.gizmo_begin_frame()
		ui.gizmo_set_orthographic(false)
		ui.gizmo_set_rect(0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))

		gizmo_used := false
		if pi := selected_point(&ed); pi >= 0 && !ed.stage_mode {
			gizmo_used = gizmo_manipulate(&ed.spline.points[pi], cam3d, ed.gizmo_mode)
			if gizmo_used {
				mark_dirty(&ed) // dragging moves a point, so the mesh is stale
			}
		} else if sel_node >= 0 {
			// Height only, so the gizmo offers one vertical handle and the node's
			// XZ stays derived from the ribbon.
			y, used := ui.gizmo_manipulate_height(node_pos[sel_node], cam3d)
			if used {
				geo.terrain_set_node(&ed.terrain, ed.sel.side, ed.sel.idx, y)
				mark_terrain_dirty(&ed)
			}
			gizmo_used = used
		}
		ed.gizmo_active = gizmo_used
		ed.gizmo_hovered = ui.gizmo_is_over()

		draw_menubar(&ed)
		draw_inspector(&ed)
		draw_generator(&ed)
		draw_targets(&ed)
		if ed.show_demo {
			ui.igShowDemoWindow(&ed.show_demo)
		}
		ui.rlImGuiEnd()

		// --- input (now that gizmo interaction for this frame is known) ----
		// A click arbitrates between a control point and a terrain node by depth,
		// so whichever handle is actually in front wins.
		if rl.IsMouseButtonPressed(.LEFT) && !gizmo_used && !nav && !ui_mouse {
			pi, pd := pick_point(ed.spline, ray)
			ni, nd := geo.pick_terrain_node(node_pos, geo.terrain_node_radius(&ed.terrain), ray)
			switch {
			case ni >= 0 && (pi < 0 || nd < pd):
				count := geo.terrain_node_count(&ed.terrain)
				ed.sel = {kind = .Node, side = ni / count, idx = ni % count}
			case pi >= 0:
				ed.sel = {kind = .Point, idx = pi}
			case:
				ed.sel = {}
			}
		}
		// Edits below resize spline.points, which can reallocate it. The gizmo
		// holds a raw pointer into that array while dragging, so never mutate
		// the array mid-drag.
		// S and F drop the start and finish lines wherever the cursor is on the
		// road. Placing one again just moves it; there is only ever one of each.
		if !ui_keys && !nav && ed.stage_mode {
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			line := !ctrl && rl.IsKeyPressed(.S) ? &ed.start : rl.IsKeyPressed(.F) ? &ed.finish : nil
			if line != nil {
				if _, _, frame, hit := pick_ribbon(ed.ribbon, ray); hit {
					line^ = {from = frame.e_from, to = frame.e_to, t = frame.t}
					set_status(&ed, line == &ed.start ? "start line placed" : "finish line placed", true)
				} else {
					set_status(&ed, "point at the road to place a line there", false)
				}
			}
		}
		if !gizmo_used && !ui_mouse && !ed.stage_mode {
			// Right-click, in priority order: another control point welds the
			// selection into it and closes a loop, the ribbon inserts, and bare
			// ground grows the road from the selected point rather than from
			// whatever happens to sit last in the array.
			if rl.IsMouseButtonPressed(.RIGHT) && !nav {
				sel := selected_point(&ed)
				target, _ := pick_point(ed.spline, ray)
				switch {
				case target >= 0 && sel >= 0 && target != sel:
					if ed.spline.points[sel].weld == target {
						geo.unweld_point(&ed.spline, sel)
					} else {
						_ = geo.weld_points(&ed.spline, sel, target)
					}
					mark_dirty(&ed)
				case target >= 0:
					ed.sel = {kind = .Point, idx = target}
				case:
					if seg, at, frame, ok := pick_ribbon(ed.ribbon, ray); ok {
						ed.sel = {kind = .Point, idx = geo.insert_point(&ed.spline, seg, at, frame)}
						mark_dirty(&ed)
					} else if g, gok := ray_ground(ray); gok {
						ed.sel = {kind = .Point, idx = grow_road(&ed.spline, sel, g)}
						mark_dirty(&ed)
					}
				}
			}
			// Only a control point can be deleted. A lattice node is a slot, not an
			// object: removing one would mean resizing the grid.
			if pi := selected_point(&ed); rl.IsKeyPressed(.DELETE) && !ui_keys && pi >= 0 {
				geo.remove_point(&ed.spline, pi)
				ed.sel = {}
				mark_dirty(&ed)
			}
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
