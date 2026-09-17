package main

// One window onto a document, and the frame it draws.
//
// Everything a camera or a cursor touches lives on the Editor, so a second
// window over the same venue gets its own view of it and shares none of it.
// The document it looks at is in document.odin.
//
// The frame runs in order: input that needs nothing, the scene, the ImGui
// panels and the gizmo, then the input that had to wait to learn whether the
// gizmo took the mouse. Geometry is already current by then — docs_rebuild
// ran before any window drew.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "../geo"
import "../ui"
import "../gfx"

// Render distance: near 0.1, far 10km, so a multi-kilometre stage is visible
// end to end. Near moves with far, keeping the far/near ratio — and so the
// depth-buffer precision — exactly as it was.
CAM_NEAR :: 0.1

CAM_FAR :: 10_000.0

// How far the wheel can pull the camera back. Tracks CAM_FAR.
CAM_DIST_MIN :: 5.0

CAM_DIST_MAX :: 8000.0

// Camera feel (dialled back 3x from the initial values).
ORBIT_SENS :: 0.00167 // radians per pixel of MMB drag

PAN_SENS :: 0.0005    // world units per pixel, scaled by distance

ZOOM_SENS :: 0.1      // fraction of distance per wheel notch

// --- window state -------------------------------------------------------------

Orbit_Camera :: struct {
	target:   gfx.Vector3,
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

// One window onto a document. Everything a camera or a cursor touches lives
// here, so a second window over the same venue gets its own view of it and
// shares none of it.
Editor :: struct {
	// This window. Heap-allocated with the Editor, because gfx keeps a pointer
	// to it in its window list.
	window:        gfx.Window,
	imgui:         rawptr,
	app:           ^App,
	doc:           ^Venue_Doc,
	// Which stage this window acts on, or -1. Indexes `doc.routes`.
	route_sel:     int,
	// Editing a stage, not the venue. A stage is two markers on the venue road
	// and nothing else, so the road itself is read-only here: no insert, no
	// branch, no weld, no delete, and the gizmo does not move a control point.
	stage_mode:    bool,
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
	wireframe:     bool,
	quit:          bool,

	// Preview ride: a cursor advances along the spline by arc, firing each note's
	// VO clips as it passes the trigger station.
	previewing:    bool,
	preview_speed: f32, // metres/second
	preview_s:     f32, // current arc station
	preview_pos:   gfx.Vector3,
	preview_next:  int, // index of the next note to fire
	preview_last:  int, // index of the last note fired (for the HUD), or -1

	route_name:    [64]u8,
	status:        Status,
}

// --- selection --------------------------------------------------------------

// The stage the marker keys act on, or nil. Validates the index, because
// removing a stage can leave the selection past the end of the list.
selected_route :: proc(ed: ^Editor) -> ^Venue_Route {
	if ed.route_sel < 0 || ed.route_sel >= len(ed.doc.routes) {
		return nil
	}
	return &ed.doc.routes[ed.route_sel]
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
	append(&ed.doc.routes, Venue_Route{
		id     = route_id_free(ed.doc.routes[:], context.allocator),
		name   = strings.clone(fmt.tprintf("STAGE %d", len(ed.doc.routes) + 1)),
		start  = {from = -1, to = -1},
		finish = {from = -1, to = -1},
	})
	select_route(ed, len(ed.doc.routes) - 1)
}

// Ordered, so the stages keep the order the menu will show them in. The id is
// not reused until route_id_free hands it out again.
remove_route :: proc(ed: ^Editor, i: int) {
	if i < 0 || i >= len(ed.doc.routes) {
		return
	}
	delete(ed.doc.routes[i].id)
	delete(ed.doc.routes[i].name)
	ordered_remove(&ed.doc.routes, i)
	select_route(ed, min(i, len(ed.doc.routes) - 1))
}

// The selected control point, or -1. Validates the index: an edit or a load can
// shrink the spline under a stale selection.
selected_point :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Point && ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.spline.points) {
		return ed.sel.idx
	}
	return -1
}

// The selected node's index into `node_pos` (see terrain_node_world), or -1.
selected_node :: proc(ed: ^Editor, node_pos: []gfx.Vector3, node_active: []bool) -> int {
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

terrain_brush_select :: proc(ed: ^Editor, node_pos: []gfx.Vector3, selected: int) {
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
	resize(&ed.terrain_brush_offsets, len(ed.doc.terrain.controls))
	for c, i in ed.doc.terrain.controls {
		ed.terrain_brush_offsets[i] = c.offset
	}
}

// --- camera -------------------------------------------------------------------


to_camera3d :: proc(oc: Orbit_Camera) -> gfx.Camera3D {
	cpitch := math.cos(oc.pitch)
	offset := gfx.Vector3{
		math.sin(oc.yaw) * cpitch,
		math.sin(oc.pitch),
		math.cos(oc.yaw) * cpitch,
	}
	pos := oc.target + offset * oc.distance
	return gfx.Camera3D{
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
	return gfx.IsKeyDown(.LEFT_ALT) || gfx.IsKeyDown(.RIGHT_ALT)
}

update_camera :: proc(oc: ^Orbit_Camera) {
	if wheel := gfx.GetMouseWheelMove(); wheel != 0 {
		oc.distance *= (1 - wheel * ZOOM_SENS)
		oc.distance = clamp(oc.distance, CAM_DIST_MIN, CAM_DIST_MAX)
	}
	if !alt_held() {
		return
	}
	delta := gfx.GetMouseDelta()
	if gfx.IsMouseButtonDown(.LEFT) {
		cam := to_camera3d(oc^)
		fwd := gfx.Vector3Normalize(cam.target - cam.position)
		// `right` is cross(fwd, worldUp), so it already lies in the ground plane.
		right := gfx.Vector3Normalize(gfx.Vector3CrossProduct(fwd, cam.up))
		// Flatten camera-up onto the ground plane so panning never changes height;
		// the wheel is the only thing that moves the camera vertically. Near a
		// top-down pitch the projection degenerates, so fall back to flat forward.
		up := gfx.Vector3CrossProduct(right, fwd)
		up_flat := gfx.Vector3{up.x, 0, up.z}
		if gfx.Vector3Length(up_flat) < 1e-4 {
			up_flat = gfx.Vector3{fwd.x, 0, fwd.z}
		}
		up_flat = gfx.Vector3Normalize(up_flat)

		speed := oc.distance * PAN_SENS
		oc.target = oc.target + right * (-delta.x * speed)
		oc.target = oc.target + up_flat * (delta.y * speed)
	} else if gfx.IsMouseButtonDown(.RIGHT) {
		oc.yaw -= delta.x * ORBIT_SENS
		oc.pitch += delta.y * ORBIT_SENS
		oc.pitch = clamp(oc.pitch, -1.5, 1.5)
	}
}

// A fresh window's own state. The document it looks at is set separately.
view_defaults :: proc() -> Editor {
	return Editor{
		cam = {target = {10, 3, 48}, distance = 110, yaw = 0.6, pitch = 0.6},
		preview_speed = 30, // ~108 km/h
		route_sel = -1,
	}
}

// --- the frame ----------------------------------------------------------------

// World units per screen pixel at the camera's focus distance. Both brush
// phases scale their mouse delta by it, so a drag feels the same whether the
// camera is close in or pulled right back.
world_per_pixel :: proc(ed: ^Editor, cam3d: gfx.Camera3D) -> f32 {
	return ed.cam.distance * 2 * math.tan(math.to_radians(cam3d.fovy * 0.5)) /
		f32(max(gfx.GetScreenHeight(), 1))
}

// The terrain-node gizmo and the brush that grows out of it. Returns whether it
// owns the mouse this frame.
terrain_brush_gizmo :: proc(
	ed: ^Editor, node_pos: []gfx.Vector3, sel_node: int, cam3d: gfx.Camera3D,
) -> (used: bool) {
	mouse := gfx.GetMousePosition()
	left_down := gfx.IsMouseButtonDown(.LEFT)
	right_down := gfx.IsMouseButtonDown(.RIGHT)

	// RMB joining the node drag starts brush sizing, and may join again
	// mid-move to re-size without dropping the node. Movement before the
	// first join is intentional single-node editing; a later join keeps
	// the moved offsets and re-anchors on them.
	if ed.terrain_brush_phase != .Size && left_down && right_down {
		ed.terrain_brush_phase = .Size
		ed.terrain_brush_mouse_y = mouse.y
		ed.terrain_brush_radius_start = ed.terrain_brush_radius
		ed.terrain_brush_anchor_offset = ed.doc.terrain.controls[ed.sel.idx].offset
		terrain_brush_select(ed, node_pos, sel_node)
	}

	// ImGuizmo owns the original LMB drag. It must keep receiving every frame,
	// including brush sizing and movement, or it resumes later with the whole
	// accumulated mouse delta and snaps the anchor node. Brush phases discard
	// its output but let its internal drag state advance and release normally.
	gizmo_y, gizmo_dragging := ui.gizmo_manipulate_height(node_pos[sel_node], cam3d)

	switch ed.terrain_brush_phase {
	case .Size:
		used = true
		// ImGuizmo may have owned LMB immediately before RMB entered brush
		// mode. Pin its last value throughout sizing: this phase changes only
		// the affected set, never terrain height.
		if ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.terrain.controls) {
			ed.doc.terrain.controls[ed.sel.idx].offset = ed.terrain_brush_anchor_offset
		}
		if !left_down {
			terrain_brush_clear(ed)
		} else if right_down {
			world_per_pixel := ed.cam.distance * 2 * math.tan(math.to_radians(cam3d.fovy * 0.5)) /
				f32(max(gfx.GetScreenHeight(), 1))
			brush_per_pixel := clamp(world_per_pixel * 2, f32(0.1), f32(2))
			ed.terrain_brush_radius = clamp(ed.terrain_brush_radius_start +
				(ed.terrain_brush_mouse_y - mouse.y) * brush_per_pixel,
				f32(0), ed.doc.terrain.reach_m * 4)
			terrain_brush_select(ed, node_pos, sel_node)
		} else {
			ed.terrain_brush_phase = .Move
			ed.terrain_brush_mouse_y = mouse.y
			terrain_brush_snapshot(ed)
		}
	case .Move:
		used = true
		if !left_down {
			terrain_brush_clear(ed)
		} else {
			move_per_pixel := clamp(world_per_pixel(ed, cam3d), f32(0.01), f32(1))
			dy := (ed.terrain_brush_mouse_y - mouse.y) * move_per_pixel
			for &c, i in ed.doc.terrain.controls {
				if i < len(ed.terrain_brush_mask) && i < len(ed.terrain_brush_offsets) &&
				   ed.terrain_brush_mask[i] {
					c.offset = ed.terrain_brush_offsets[i] + dy
				}
			}
			mark_terrain_dirty(ed.doc)
		}
	case .None:
		// Height only, so an ordinary LMB drag keeps the single-control gizmo.
		if gizmo_dragging {
			geo.terrain_set_node(&ed.doc.terrain, ed.sel.idx, gizmo_y)
			mark_terrain_dirty(ed.doc)
		}
		used = gizmo_dragging
	}
	return
}

// The gizmo pass. ImGuizmo both draws and reports interaction, so this is one
// step rather than two, and it returns whether the gizmo took the mouse.
//
// ImGuizmo holds one file-static drag state for the whole process, so only the
// focused window may run it. A second editor window manipulating in the same
// frame would clobber this one's drag part way through.
//
// It also answers gizmo_is_over out of the state its last manipulate call left
// behind, so with nothing selected it keeps reporting a hover over the gizmo
// that used to be there — right on top of the handle just deselected, which
// would then refuse every click that tries to select it again. Hence
// `gizmo_shown`.
editor_gizmos :: proc(ed: ^Editor, cam3d: gfx.Camera3D, node_pos: []gfx.Vector3, sel_node: int) -> bool {
	focused := gfx.WindowFocused(&ed.window)
	ui.gizmo_begin_frame()
	ui.gizmo_set_orthographic(false)
	ui.gizmo_set_rect(0, 0, f32(gfx.GetScreenWidth()), f32(gfx.GetScreenHeight()))

	gizmo_used, gizmo_shown := false, false
	if pi := selected_point(ed); pi >= 0 && !ed.stage_mode && focused {
		gizmo_shown = true
		gizmo_used = gizmo_manipulate(&ed.doc.spline.points[pi], cam3d, ed.gizmo_mode)
		if gizmo_used {
			mark_dirty(ed.doc) // dragging moves a point, so the mesh is stale
		}
	} else if sel_node >= 0 && focused {
		gizmo_shown = true
		gizmo_used = terrain_brush_gizmo(ed, node_pos, sel_node, cam3d)
	}
	if !focused && ed.terrain_brush_phase != .None {
		terrain_brush_clear(ed)
	}
	ed.gizmo_active = gizmo_used
	ed.gizmo_hovered = gizmo_shown && ui.gizmo_is_over()
	return gizmo_used
}

// 1 = move, 2 = rotate, Ctrl+S = save.
editor_hotkeys :: proc(ed: ^Editor, ui_keys: bool) {
	if ui_keys {
		return
	}
	if gfx.IsKeyPressed(.ONE) {
		ed.gizmo_mode = .Move
	}
	if gfx.IsKeyPressed(.TWO) {
		ed.gizmo_mode = .Rotate
	}
	ctrl := gfx.IsKeyDown(.LEFT_CONTROL) || gfx.IsKeyDown(.RIGHT_CONTROL)
	if ctrl && gfx.IsKeyPressed(.S) && len(ed.doc.spline.points) >= 2 {
		do_save(ed)
	}
}

// S and F drop the start and finish lines wherever the cursor is on the road.
// Placing one again just moves it; there is only ever one of each.
place_stage_markers :: proc(ed: ^Editor, ray: gfx.Ray, nav, ui_keys: bool) {
	if ui_keys || nav || !ed.stage_mode {
		return
	}
	route := selected_route(ed)
	if route == nil {
		return
	}
	ctrl := gfx.IsKeyDown(.LEFT_CONTROL) || gfx.IsKeyDown(.RIGHT_CONTROL)
	start := !ctrl && gfx.IsKeyPressed(.S)
	line := start ? &route.start : gfx.IsKeyPressed(.F) ? &route.finish : nil
	if line == nil {
		return
	}
	if _, _, frame, hit := pick_ribbon(ed.doc.ribbon, ray); hit {
		line^ = {from = frame.e_from, to = frame.e_to, t = frame.t}
		set_status(&ed.status, start ? "start line placed" : "finish line placed", true)
	} else {
		set_status(&ed.status, "point at the road to place a line there", false)
	}
}

// Right-click, in priority order: another control point welds the selection
// into it and closes a loop, the ribbon inserts, and bare ground grows the road
// from the selected point rather than from whatever sits last in the array.
//
// Every edit here resizes spline.points, which can reallocate it. The gizmo
// holds a raw pointer into that array while dragging, so this runs only once
// the gizmo has released.
edit_road :: proc(ed: ^Editor, ray: gfx.Ray, gizmo_used, nav, ui_mouse, ui_keys: bool) {
	if gizmo_used || ui_mouse || ed.stage_mode {
		return
	}
	if gfx.IsMouseButtonPressed(.RIGHT) && !nav {
		sel := selected_point(ed)
		target, _ := pick_point(ed.doc.spline, ray)
		switch {
		case target >= 0 && sel >= 0 && target != sel:
			if ed.doc.spline.points[sel].weld == target {
				geo.unweld_point(&ed.doc.spline, sel)
			} else {
				_ = geo.weld_points(&ed.doc.spline, sel, target)
			}
			mark_dirty(ed.doc)
		case target >= 0:
			ed.sel = {kind = .Point, idx = target}
		case:
			if seg, at, frame, ok := pick_ribbon(ed.doc.ribbon, ray); ok {
				ed.sel = {kind = .Point, idx = geo.insert_point(&ed.doc.spline, seg, at, frame)}
				mark_dirty(ed.doc)
			} else if g, gok := ray_ground(ray); gok {
				ed.sel = {kind = .Point, idx = grow_road(&ed.doc.spline, sel, g)}
				mark_dirty(ed.doc)
			}
		}
	}
	// Only a road point can be deleted. Terrain controls are generated from the
	// terrain region rather than individually added or removed.
	if pi := selected_point(ed); gfx.IsKeyPressed(.DELETE) && !ui_keys && pi >= 0 {
		geo.remove_point(&ed.doc.spline, pi)
		ed.sel = {}
		mark_dirty(ed.doc)
	}
}

// The input that had to wait for the gizmo, because whether the gizmo took the
// mouse this frame decides whether anything else may.
editor_input :: proc(
	ed: ^Editor, ray: gfx.Ray, node_pos: []gfx.Vector3, node_active: []bool,
	gizmo_used, nav, ui_mouse, ui_keys: bool,
) {
	// A click arbitrates between a control point and a terrain node by depth,
	// so whichever handle is actually in front wins.
	if gfx.IsMouseButtonPressed(.LEFT) && !gizmo_used && !ed.gizmo_hovered && !nav && !ui_mouse {
		pi, pd := pick_point(ed.doc.spline, ray)
		ni, nd := geo.pick_terrain_node(node_pos, node_active, geo.terrain_node_radius(&ed.doc.terrain), ray)
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
	place_stage_markers(ed, ray, nav, ui_keys)
	edit_road(ed, ray, gizmo_used, nav, ui_mouse, ui_keys)
}

// One frame of one editor window. Input, the scene, the panels, then the input
// that needed to know what the gizmo did. The geometry is already current:
// docs_rebuild ran before any window drew.
editor_frame :: proc(ed: ^Editor) {
	gfx.BeginWindowFrame(&ed.window)
	// ImGui gets first refusal on input: a click on a panel, or a keypress
	// into a text field, must never also reach the viewport behind it.
	ui_mouse := ui.imgui_want_capture_mouse()
	ui_keys := ui.imgui_want_capture_keyboard()

	editor_hotkeys(ed, ui_keys)

	// Alt owns the mouse for camera navigation; the gizmo must not grab it.
	nav := alt_held()
	ui.gizmo_enable(!nav)
	if !ui_mouse && (nav || !ed.gizmo_active) {
		update_camera(&ed.cam)
	}
	cam3d := to_camera3d(ed.cam)
	ray := gfx.GetScreenToWorldRay(gfx.GetMousePosition(), cam3d)

	// Shift + grabbing the gizmo extrudes: duplicate the selected point and
	// drag the copy outward, growing the spline at its ends. This must run
	// before gizmo_manipulate, which processes the press later this frame,
	// so the drag latches onto the copy. gizmo_hovered is last frame's
	// probe, which is accurate at the instant of the press.
	shift := gfx.IsKeyDown(.LEFT_SHIFT) || gfx.IsKeyDown(.RIGHT_SHIFT)
	if gfx.IsMouseButtonPressed(.LEFT) &&
	   shift && !nav && !ui_mouse && !ed.gizmo_active && !ed.stage_mode &&
	   selected_point(ed) >= 0 &&
	   ed.gizmo_hovered {
		ed.sel = {kind = .Point, idx = geo.extrude_point(&ed.doc.spline, ed.sel.idx)}
		mark_dirty(ed.doc)
	}

	// Advance the preview ride and fire pace-note clips. Cheap when idle.
	// The ride moves the camera target, so rebuild the view matrix from it.
	preview_update(ed)
	if ed.previewing {
		cam3d = to_camera3d(ed.cam)
	}

	// Node handles come from the world-space terrain controls, so they are
	// recomputed after the rebuild and shared by drawing, picking and the
	// gizmo. Temp-allocated: valid for this frame only.
	node_pos := geo.terrain_node_world(&ed.doc.terrain, ed.doc.ribbon, ed.doc.topo, ed.doc.roughness)
	node_active := geo.terrain_node_active_mask(&ed.doc.terrain, node_pos)
	sel_node := selected_node(ed, node_pos, node_active)
	if ed.sel.kind == .Node && sel_node < 0 {
		ed.sel = {}
		terrain_brush_clear(ed)
	}

	draw_scene(ed, cam3d, node_pos, node_active, sel_node)

	// --- ImGui frame (the gizmo both draws and reports interaction) ----
	// ImGuizmo draws into an ImGui draw list, so it lives here rather than
	// inside BeginMode3D, and projects itself with the camera's matrices.
	ui.imgui_backend_begin()
	// Show the current call even when pace-note audio is disabled.
	if ed.previewing && ed.preview_last >= 0 && ed.preview_last < len(ed.doc.notes) {
		txt := fmt.ctprintf("%s", geo.pace_note_text(ed.doc.notes[ed.preview_last]))
		ui.draw_overlay_text_centered(txt, 40, 40, f32(gfx.GetScreenWidth()), 0xff78dcff)
	}
	if ed.terrain_brush_phase != .None {
		brush_count := 0
		for selected in ed.terrain_brush_mask {
			if selected { brush_count += 1 }
		}
		txt := fmt.ctprintf("terrain brush: %d controls  %.0f m", brush_count, ed.terrain_brush_radius)
		ui.draw_overlay_text_centered(txt, 40, 72, f32(gfx.GetScreenWidth()), 0xff50beff)
	}
	// ImGuizmo holds one file-static drag state for the whole process, so only
	gizmo_used := editor_gizmos(ed, cam3d, node_pos, sel_node)

	draw_menubar(ed)
	draw_inspector(ed)
	draw_generator(ed)
	draw_targets(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	editor_input(ed, ray, node_pos, node_active, gizmo_used, nav, ui_mouse, ui_keys)

	gfx.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}
