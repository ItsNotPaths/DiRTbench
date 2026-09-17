package main

// dirtbench — a DiRT 3 rally road editor.
//
// Editor slice: SDL_GPU viewport with an orbiting camera over a smooth,
// tangent-driven road ribbon. The road is a chain of oriented control points
// (geo/spline.odin); selecting one shows a translate+rotate gizmo (gizmo.odin,
// over the ImGuizmo binding in ui/) so it can be steered, sloped and banked.
// Right-click inserts a point into the road under the cursor, or appends one on
// open ground. Panels are Dear ImGui, through ui/imgui.odin.
//
// dirtbench boots into the project manager (venues_ui.odin), which is window 0
// of one process. Opening a venue gives it an editor window beside it, over an
// Editor of its own: picking the world comes before drawing a road in it. One
// process, because a stage window has to see the venue's live terrain, and that
// is free when they share a cache and expensive when they do not. A finished
// road goes to an export target (export.odin), and the editor does not know
// which game that is.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "../geo"
import "../ui"
import rl "../gfx"

WINDOW_W :: 1280
WINDOW_H :: 800
PROJECT_MANAGER_W :: 560
PROJECT_MANAGER_H :: 720

GROUND_Y :: 0.0

// Render distance: near 0.1, far 10km, so a multi-kilometre stage is visible
// end to end. Near moves with far, keeping the far/near ratio — and so the
// depth-buffer precision — exactly as it was.
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
// control point and a world-space terrain control are both selectable.
Sel_Kind :: enum {
	None,
	Point, // idx indexes geo.Spline points
	Node,  // idx indexes geo.Terrain.controls
}

Selection :: struct {
	kind: Sel_Kind,
	idx:  int,
}

Terrain_Brush_Phase :: enum {
	None,
	Size,
	Move,
}

// How long a save/load result stays on screen, seconds.
STATUS_LINGER :: 8.0

// Global tessellation density: ribbon samples per spline segment. Also drives
// how many vertical rows a cliff face gets (see cliff_rows).
TOPO_MIN :: 2
TOPO_MAX :: 48

// The process. One project-manager window, one scan of the game install, and
// however many venue editors are open over it. Everything in here is shared;
// everything per-venue is in Editor.
App :: struct {
	window:  rl.Window,
	imgui:   rawptr,
	install: Install_Scan,
	screen:  Venues_Screen,
	editors: [dynamic]^Editor,
	// The venue a button asked to open, serviced between frames. See
	// app_service_open_request for why it cannot happen inside one.
	open_request: [64]u8,
	status:  Status,
	show_demo: bool,
	quit:    bool,
	// One audio device per process, so one clip bank and one playback queue.
	// Whichever window starts a ride preview owns them until it stops.
	clips:        map[string]rl.Sound, // basename -> decoded OGG
	play_q:       [dynamic]rl.Sound,   // clips to play back-to-back
	play_i:       int,
	play_started: bool,
}

Editor :: struct {
	// This editor's own window. Heap-allocated with the Editor, because gfx
	// keeps a pointer to it in its window list.
	window:        rl.Window,
	imgui:         rawptr,
	app:           ^App,
	// Which venue stage the editor has open, "" when it is a loose stage out of
	// maps/. Saving writes back to the venue.
	open_venue:  string,
	open_stage:    string,
	// The venue's stage list, while its road is open. It belongs to venue.json
	// and is written back when the road is saved. `route_sel` indexes it, or is
	// -1 when the venue has no stages yet.
	routes:        [dynamic]Venue_Route,
	route_sel:     int,
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
	terrain_brush_phase: Terrain_Brush_Phase,
	terrain_brush_radius: f32,
	terrain_brush_radius_start: f32,
	terrain_brush_mouse_y: f32,
	terrain_brush_anchor_offset: f32,
	terrain_brush_mask: [dynamic]bool,
	terrain_brush_offsets: [dynamic]f32,
	show_demo:     bool,
	show_gen:      bool, // the Stage generator panel; toggled from the menubar
	show_targets:  bool, // the Export targets panel
	debug_export:  bool, // write to out/ instead of into the game (export.odin)
	gen:           Gen_Params,
	// The one scan of the game install, borrowed. The project manager owns it
	// and every editor window reads the same one, so a rescan in any window is
	// seen by all of them. Headless CLI paths point this at a local.
	install:       ^Install_Scan,
	gen_live:      bool, // regenerate while a slider is being dragged
	quit:          bool,

	// Geometry. `ribbon`, `road` and `terrain_mesh` are caches rebuilt from
	// `spline` (and `terrain`) whenever `dirty` is set — never read them without
	// going through mark_dirty/rebuild.
	ribbon:        []geo.Cross_Section,
	// Ticks on every ribbon rebuild. The terrain's world grid is keyed on it, so
	// dragging a terrain control reuses the grid instead of rebuilding it.
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

	// ImGui edits these buffers in place, so they are fixed C strings.
	stage_name:    [64]u8,
	route_name:    [64]u8,
	status:        Status,
}

// The last save/load/export result, shown for STATUS_LINGER seconds. One per
// window: a message belongs to the window whose action produced it.
Status :: struct {
	// Copied, because the messages come off the temp allocator, which is reset
	// every frame.
	text: [256]u8,
	ok:   bool,
	at:   f64, // rl.GetTime() when set
}

// --- selection --------------------------------------------------------------

// The stage the marker keys act on, or nil. Validates the index, because
// removing a stage can leave the selection past the end of the list.
selected_route :: proc(ed: ^Editor) -> ^Venue_Route {
	if ed.route_sel < 0 || ed.route_sel >= len(ed.routes) {
		return nil
	}
	return &ed.routes[ed.route_sel]
}

// Point the stage list at `i`, and refresh the name field from whatever is
// there now. The field is the only editable copy of the name, so it has to
// follow the selection or a rename lands on the wrong stage.
select_route :: proc(ed: ^Editor, i: int) {
	ed.route_sel = i
	if r := selected_route(ed); r != nil {
		set_buf(ed.route_name[:], r.name)
	} else {
		ed.route_name = {}
	}
}

add_route :: proc(ed: ^Editor) {
	append(&ed.routes, Venue_Route{
		id     = route_id_free(ed.routes[:], context.allocator),
		name   = strings.clone(fmt.tprintf("STAGE %d", len(ed.routes) + 1)),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
	})
	select_route(ed, len(ed.routes) - 1)
}

// Ordered, so the stages keep the order the menu will show them in. The id is
// not reused until route_id_free hands it out again.
remove_route :: proc(ed: ^Editor, i: int) {
	if i < 0 || i >= len(ed.routes) {
		return
	}
	delete(ed.routes[i].id)
	delete(ed.routes[i].name)
	ordered_remove(&ed.routes, i)
	select_route(ed, min(i, len(ed.routes) - 1))
}

// The selected control point, or -1. Validates the index: an edit or a load can
// shrink the spline under a stale selection.
selected_point :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Point && ed.sel.idx >= 0 && ed.sel.idx < len(ed.spline.points) {
		return ed.sel.idx
	}
	return -1
}

// The selected node's index into `node_pos` (see terrain_node_world), or -1.
selected_node :: proc(ed: ^Editor, node_pos: []rl.Vector3, node_active: []bool) -> int {
	if ed.sel.kind != .Node || len(node_pos) == 0 {
		return -1
	}
	i := ed.sel.idx
	if i < 0 || i >= len(node_pos) || (len(node_active) == len(node_pos) && !node_active[i]) {
		return -1 // controls were regenerated under the selection
	}
	return i
}

terrain_brush_clear :: proc(ed: ^Editor) {
	ed.terrain_brush_phase = .None
	clear(&ed.terrain_brush_mask)
	clear(&ed.terrain_brush_offsets)
}

terrain_brush_select :: proc(ed: ^Editor, node_pos: []rl.Vector3, selected: int) {
	resize(&ed.terrain_brush_mask, len(node_pos))
	for &affected in ed.terrain_brush_mask {
		affected = false
	}
	if selected < 0 || selected >= len(node_pos) {
		return
	}
	centre := node_pos[selected]
	r2 := ed.terrain_brush_radius * ed.terrain_brush_radius
	for p, i in node_pos {
		dx, dz := p.x - centre.x, p.z - centre.z
		ed.terrain_brush_mask[i] = i == selected || dx * dx + dz * dz <= r2
	}
}

terrain_brush_snapshot :: proc(ed: ^Editor) {
	resize(&ed.terrain_brush_offsets, len(ed.terrain.controls))
	for c, i in ed.terrain.controls {
		ed.terrain_brush_offsets[i] = c.offset
	}
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

// For edits that leave the ribbon alone: sculpt controls, terrain sliders. These
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
// release. Dragging a terrain control is exempt — the terrain is the only thing
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
		old_node_count := geo.terrain_node_count(&ed.terrain)
		geo.terrain_ensure(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
		if ed.sel.kind == .Node && geo.terrain_node_count(&ed.terrain) != old_node_count {
			ed.sel = {}
		}
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
// Clearing, not just freeing: the slice outlives the memory otherwise, and the
// next delete frees it a second time.
veg_cache_clear :: proc(ed: ^Editor) {
	delete(ed.veg_cache)
	ed.veg_cache = nil
}

veg_refresh :: proc(ed: ^Editor) {
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
	veg_cache_clear(ed)
	ed.veg_cache = geo.veg_generate(ed.ribbon, &ed.terrain, ed.veg, ed.topo, ed.roughness)
	ed.veg_gen = ed.ribbon_gen
	ed.veg_dirty = false
}

// --- status line ------------------------------------------------------------

// ImGui edits a name in place, so every name the editor shows it is a fixed
// byte buffer rather than a string. These two are the only way in and out.
set_buf :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
}

buf_text :: proc(buf: []u8) -> string {
	return string(cstring(raw_data(buf)))
}

set_status :: proc(s: ^Status, msg: string, ok: bool) {
	set_buf(s.text[:], msg)
	s.ok = ok
	s.at = rl.GetTime()
}

status_text :: proc(s: ^Status) -> (text: cstring, ok: bool) {
	if s.text[0] == 0 || rl.GetTime() - s.at > STATUS_LINGER {
		return nil, false
	}
	return cstring(raw_data(s.text[:])), true
}

// The stage name as ImGui left it in the buffer: NUL-terminated, unsanitised.
stage_name_text :: proc(ed: ^Editor) -> string {
	return buf_text(ed.stage_name[:])
}

set_stage_name :: proc(ed: ^Editor, name: string) {
	set_buf(ed.stage_name[:], name)
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

// Every stage's lines. The selected one is drawn bright and the rest dim, so a
// new stage is placed against the ones already using this road.
draw_route_markers :: proc(ed: ^Editor) {
	for route, i in ed.routes {
		lit := i == ed.route_sel
		start := rl.Color{110, 255, 140, 255} if lit else {60, 120, 80, 255}
		finish := rl.Color{255, 110, 110, 255} if lit else {120, 60, 60, 255}
		draw_marker(ed.spline, route.start, start)
		draw_marker(ed.spline, route.finish, finish)
	}
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

// Sensible knobs for a fresh editor. Not a constant, because the terrain and
// the route list own allocations that must not be shared between editors.
editor_defaults :: proc() -> Editor {
	return Editor{
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
}

// The window and the GPU geometry that hangs off it. Separate from
// editor_defaults so the headless CLI paths can build an Editor without one.
editor_window_open :: proc(ed: ^Editor, title: cstring) -> bool {
	if !rl.CreateWindow(&ed.window, WINDOW_W, WINDOW_H, title) {
		return false
	}
	ctx := ui.imgui_backend_setup(
		true, rl.NativeWindow(&ed.window), rl.GpuDevice(), rl.WindowSwapchainFormat(&ed.window),
	)
	if ctx == nil {
		rl.DestroyWindow(&ed.window)
		return false
	}
	rl.SetWindowImGui(&ed.window, ctx)
	// Only the project manager saves a layout. Every context writing the same
	// .ini means the last window closed decides where all of them sit.
	ui.imgui_backend_set_ini(ctx, nil)
	ed.imgui = ctx

	ed.notes = make([dynamic]geo.Pace_Note)
	ed.material = rl.LoadMaterialDefault()
	set_stage_name(ed, "untitled")
	seed_spline(&ed.spline)
	mark_dirty(ed)
	return true
}

// Everything the editor allocated, window or not.
editor_delete :: proc(ed: ^Editor) {
	rl.UnloadMaterial(ed.material)
	geo.gpu_mesh_unload(&ed.road)
	geo.gpu_mesh_unload(&ed.terrain_mesh)
	geo.terrain_delete(&ed.terrain)
	geo.terrain_field_delete(&ed.terrain_field)
	delete(ed.ribbon)
	veg_cache_clear(ed)
	delete(ed.terrain_brush_mask)
	delete(ed.terrain_brush_offsets)
	delete(ed.notes)
	delete(ed.spline.points)
	delete(ed.open_venue)
	delete(ed.open_stage)
	routes_free(&ed.routes)
}

// Close one editor window and free it. The Editor is heap-allocated, so this
// owns the free as well.
editor_close :: proc(ed: ^Editor) {
	editor_delete(ed)
	if ed.imgui != nil {
		ui.imgui_backend_shutdown(ed.imgui)
		ed.imgui = nil
	}
	rl.DestroyWindow(&ed.window)
	free(ed)
}

main :: proc() {
	if run_cli() {
		return
	}
	app := App{}
	if !rl.CreateWindow(&app.window, PROJECT_MANAGER_W, PROJECT_MANAGER_H, "dirtbench — project manager") {
		fmt.println("could not create SDL window")
		return
	}
	defer rl.DestroyWindow(&app.window)
	// Process-wide in the renderer, so this covers every window opened later.
	rl.SetClipPlanes(CAM_NEAR, CAM_FAR)

	app.imgui = ui.imgui_backend_setup(
		true, rl.NativeWindow(&app.window), rl.GpuDevice(), rl.WindowSwapchainFormat(&app.window),
	)
	if app.imgui == nil {
		fmt.println("could not initialize Dear ImGui")
		return
	}
	rl.SetWindowImGui(&app.window, app.imgui)
	defer ui.imgui_backend_shutdown(app.imgui)

	// One audio device and one clip bank for the process. Decoding the pace-note
	// clips again per editor window would be the same bytes three times over.
	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()
	rl.SetMasterVolume(1.0)
	app.clips = pace_audio_load()
	defer pace_audio_unload(&app.clips)
	app.play_q = make([dynamic]rl.Sound)
	defer delete(app.play_q)

	install_scan_init(&app.install)
	defer install_scan_delete(&app.install)
	venues_screen_init(&app.screen)
	defer venues_screen_delete(&app.screen)
	// Defers run last-first, so the delete is written above the loop that has
	// to run before it. Written the other way round, the loop walks the freed
	// array and closes garbage.
	defer delete(app.editors)
	defer for ed in app.editors {
		editor_close(ed)
	}

	for !rl.WindowShouldClose(&app.window) && !app.quit {
		rl.PollWindowEvents()
		venues_editors_reap(&app)
		draw_venues_frame(&app)
		app_service_open_request(&app)
		for ed in app.editors {
			editor_frame(ed)
		}
		free_all(context.temp_allocator)
	}
}

// One frame of one editor window. Input, one geometry rebuild, the scene, the
// panels, then the input that needed to know what the gizmo did.
editor_frame :: proc(ed: ^Editor) {
	rl.BeginWindowFrame(&ed.window)
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
			do_save(ed)
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
	   selected_point(ed) >= 0 &&
	   ed.gizmo_hovered {
		ed.sel = {kind = .Point, idx = geo.extrude_point(&ed.spline, ed.sel.idx)}
		mark_dirty(ed)
	}

	// One rebuild per frame, after every mutation above has landed.
	if geometry_stale(ed) {
		rebuild_geometry(ed)
	}
	// Regenerate the scatter if a rebuild (or a veg edit) invalidated it.
	veg_refresh(ed)

	// Advance the preview ride and fire pace-note clips. Cheap when idle.
	// The ride moves the camera target, so rebuild the view matrix from it.
	preview_update(ed)
	if ed.previewing {
		cam3d = to_camera3d(ed.cam)
	}

	// Node handles come from the world-space terrain controls, so they are
	// recomputed after the rebuild and shared by drawing, picking and the
	// gizmo. Temp-allocated: valid for this frame only.
	node_pos := geo.terrain_node_world(&ed.terrain, ed.ribbon, ed.topo, ed.roughness)
	node_active := geo.terrain_node_active_mask(&ed.terrain, node_pos)
	sel_node := selected_node(ed, node_pos, node_active)
	if ed.sel.kind == .Node && sel_node < 0 {
		ed.sel = {}
		terrain_brush_clear(ed)
	}

	rl.ClearBackground({26, 28, 34, 255})
	rl.BeginMode3D(cam3d)
	rl.DrawGrid(GRID_SLICES, GRID_SPACING)
	geo.gpu_mesh_draw(ed.terrain_mesh, ed.material, ed.wireframe)
	geo.gpu_mesh_draw(ed.road, ed.material, ed.wireframe)
	// Handles first: they share one fixed-size batch with the scenery, which
	// grows with the stage, and what does not fit is dropped (see
	// batch_has_room). Losing the far trees is a nuisance; losing the handles
	// makes the editor unusable.
	draw_centreline(ed.ribbon)
	draw_timing_markers(timing_markers(ed.ribbon,ed.timing))
	draw_handles(ed.spline, selected_point(ed))
	geo.draw_terrain_nodes(&ed.terrain, node_pos, node_active, ed.terrain_brush_mask[:], sel_node)
	geo.veg_draw(ed.veg_cache)
	draw_route_markers(ed)
	if ed.previewing {
		rl.DrawSphere(ed.preview_pos, 2.0, {255, 210, 80, 255})
	}
	rl.EndMode3D()

	// --- ImGui frame (the gizmo both draws and reports interaction) ----
	// ImGuizmo draws into an ImGui draw list, so it lives here rather than
	// inside BeginMode3D, and projects itself with the camera's matrices.
	ui.imgui_backend_begin()
	// Show the current call even when pace-note audio is disabled.
	if ed.previewing && ed.preview_last >= 0 && ed.preview_last < len(ed.notes) {
		txt := fmt.ctprintf("%s", geo.pace_note_text(ed.notes[ed.preview_last]))
		ui.draw_overlay_text_centered(txt, 40, 40, f32(rl.GetScreenWidth()), 0xff78dcff)
	}
	if ed.terrain_brush_phase != .None {
		brush_count := 0
		for selected in ed.terrain_brush_mask {
			if selected { brush_count += 1 }
		}
		txt := fmt.ctprintf("terrain brush: %d controls  %.0f m", brush_count, ed.terrain_brush_radius)
		ui.draw_overlay_text_centered(txt, 40, 72, f32(rl.GetScreenWidth()), 0xff50beff)
	}
	// ImGuizmo holds one file-static drag state for the whole process, so only
	// the focused window may run it. A second editor window manipulating in the
	// same frame would clobber this one's drag part way through.
	focused := rl.WindowFocused(&ed.window)
	ui.gizmo_begin_frame()
	ui.gizmo_set_orthographic(false)
	ui.gizmo_set_rect(0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))

	// ImGuizmo answers gizmo_is_over out of the state its last manipulate call
	// left behind, so with nothing selected it keeps reporting a hover over the
	// gizmo that used to be there — right on top of the handle just deselected,
	// which would then refuse every click that tries to select it again.
	gizmo_used, gizmo_shown := false, false
	if pi := selected_point(ed); pi >= 0 && !ed.stage_mode && focused {
		gizmo_shown = true
		gizmo_used = gizmo_manipulate(&ed.spline.points[pi], cam3d, ed.gizmo_mode)
		if gizmo_used {
			mark_dirty(ed) // dragging moves a point, so the mesh is stale
		}
	} else if sel_node >= 0 && focused {
		gizmo_shown = true
		mouse := rl.GetMousePosition()
		left_down := rl.IsMouseButtonDown(.LEFT)
		right_down := rl.IsMouseButtonDown(.RIGHT)

		// RMB joining the node drag starts brush sizing, and may join again
		// mid-move to re-size without dropping the node. Movement before the
		// first join is intentional single-node editing; a later join keeps
		// the moved offsets and re-anchors on them.
		if ed.terrain_brush_phase != .Size && left_down && right_down {
			ed.terrain_brush_phase = .Size
			ed.terrain_brush_mouse_y = mouse.y
			ed.terrain_brush_radius_start = ed.terrain_brush_radius
			ed.terrain_brush_anchor_offset = ed.terrain.controls[ed.sel.idx].offset
			terrain_brush_select(ed, node_pos, sel_node)
		}

		// ImGuizmo owns the original LMB drag. It must keep receiving every frame,
		// including brush sizing and movement, or it resumes later with the whole
		// accumulated mouse delta and snaps the anchor node. Brush phases discard
		// its output but let its internal drag state advance and release normally.
		gizmo_y, gizmo_dragging := ui.gizmo_manipulate_height(node_pos[sel_node], cam3d)

		switch ed.terrain_brush_phase {
		case .Size:
			gizmo_used = true
			// ImGuizmo may have owned LMB immediately before RMB entered brush
			// mode. Pin its last value throughout sizing: this phase changes only
			// the affected set, never terrain height.
			if ed.sel.idx >= 0 && ed.sel.idx < len(ed.terrain.controls) {
				ed.terrain.controls[ed.sel.idx].offset = ed.terrain_brush_anchor_offset
			}
			if !left_down {
				terrain_brush_clear(ed)
			} else if right_down {
				world_per_pixel := ed.cam.distance * 2 * math.tan(math.to_radians(cam3d.fovy * 0.5)) /
					f32(max(rl.GetScreenHeight(), 1))
				brush_per_pixel := clamp(world_per_pixel * 2, f32(0.1), f32(2))
				ed.terrain_brush_radius = clamp(ed.terrain_brush_radius_start +
					(ed.terrain_brush_mouse_y - mouse.y) * brush_per_pixel,
					f32(0), ed.terrain.reach_m * 4)
				terrain_brush_select(ed, node_pos, sel_node)
			} else {
				ed.terrain_brush_phase = .Move
				ed.terrain_brush_mouse_y = mouse.y
				terrain_brush_snapshot(ed)
			}
		case .Move:
			gizmo_used = true
			if !left_down {
				terrain_brush_clear(ed)
			} else {
				world_per_pixel := ed.cam.distance * 2 * math.tan(math.to_radians(cam3d.fovy * 0.5)) /
					f32(max(rl.GetScreenHeight(), 1))
				move_per_pixel := clamp(world_per_pixel, f32(0.01), f32(1))
				dy := (ed.terrain_brush_mouse_y - mouse.y) * move_per_pixel
				for &c, i in ed.terrain.controls {
					if i < len(ed.terrain_brush_mask) && i < len(ed.terrain_brush_offsets) &&
					   ed.terrain_brush_mask[i] {
						c.offset = ed.terrain_brush_offsets[i] + dy
					}
				}
				mark_terrain_dirty(ed)
			}
		case .None:
			// Height only, so an ordinary LMB drag keeps the single-control gizmo.
			if gizmo_dragging {
				geo.terrain_set_node(&ed.terrain, ed.sel.idx, gizmo_y)
				mark_terrain_dirty(ed)
			}
			gizmo_used = gizmo_dragging
		}
	}
	if !focused && ed.terrain_brush_phase != .None {
		terrain_brush_clear(ed)
	}
	ed.gizmo_active = gizmo_used
	ed.gizmo_hovered = gizmo_shown && ui.gizmo_is_over()

	draw_menubar(ed)
	draw_inspector(ed)
	draw_generator(ed)
	draw_targets(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	// --- input (now that gizmo interaction for this frame is known) ----
	// A click arbitrates between a control point and a terrain node by depth,
	// so whichever handle is actually in front wins.
	if rl.IsMouseButtonPressed(.LEFT) && !gizmo_used && !ed.gizmo_hovered && !nav && !ui_mouse {
		pi, pd := pick_point(ed.spline, ray)
		ni, nd := geo.pick_terrain_node(node_pos, node_active, geo.terrain_node_radius(&ed.terrain), ray)
		switch {
		case ni >= 0 && (pi < 0 || nd < pd):
			ed.sel = {kind = .Node, idx = ni}
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
		if route := selected_route(ed); route != nil {
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			start := !ctrl && rl.IsKeyPressed(.S)
			line := start ? &route.start : rl.IsKeyPressed(.F) ? &route.finish : nil
			if line != nil {
				if _, _, frame, hit := pick_ribbon(ed.ribbon, ray); hit {
					line^ = {from = frame.e_from, to = frame.e_to, t = frame.t}
					set_status(&ed.status, start ? "start line placed" : "finish line placed", true)
				} else {
					set_status(&ed.status, "point at the road to place a line there", false)
				}
			}
		}
	}
	if !gizmo_used && !ui_mouse && !ed.stage_mode {
		// Right-click, in priority order: another control point welds the
		// selection into it and closes a loop, the ribbon inserts, and bare
		// ground grows the road from the selected point rather than from
		// whatever happens to sit last in the array.
		if rl.IsMouseButtonPressed(.RIGHT) && !nav {
			sel := selected_point(ed)
			target, _ := pick_point(ed.spline, ray)
			switch {
			case target >= 0 && sel >= 0 && target != sel:
				if ed.spline.points[sel].weld == target {
					geo.unweld_point(&ed.spline, sel)
				} else {
					_ = geo.weld_points(&ed.spline, sel, target)
				}
				mark_dirty(ed)
			case target >= 0:
				ed.sel = {kind = .Point, idx = target}
			case:
				if seg, at, frame, ok := pick_ribbon(ed.ribbon, ray); ok {
					ed.sel = {kind = .Point, idx = geo.insert_point(&ed.spline, seg, at, frame)}
					mark_dirty(ed)
				} else if g, gok := ray_ground(ray); gok {
					ed.sel = {kind = .Point, idx = grow_road(&ed.spline, sel, g)}
					mark_dirty(ed)
				}
			}
		}
		// Only a road point can be deleted. Terrain controls are generated from
		// the terrain region rather than individually added or removed.
		if pi := selected_point(ed); rl.IsKeyPressed(.DELETE) && !ui_keys && pi >= 0 {
			geo.remove_point(&ed.spline, pi)
			ed.sel = {}
			mark_dirty(ed)
		}
	}

	rl.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}
