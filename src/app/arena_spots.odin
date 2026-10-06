package main

// The points an arena route's mode reads: its start ring, and on Transporter
// its flags and drop zones. Selected, placed, moved and deleted in the arena
// window (arena_view.odin); stored on Venue_Route; written by arena.odin.

import "core:fmt"
import "core:math"
import "../gfx"
import "../ui"

Arena_Spot_Kind :: enum u8 {
	Start,
	Flag,
	Drop_Zone,
}

ARENA_SPOT_NAMES := [Arena_Spot_Kind]string {
	.Start     = "start",
	.Flag      = "flag",
	.Drop_Zone = "drop zone",
}

ARENA_START_COL := [Arena_Mode]gfx.Color {
	.Outbreak    = {120, 220, 90, 255},
	.Transporter = {90, 170, 255, 255},
}

ARENA_GOAL_COL := [2]gfx.Color{{240, 80, 60, 255}, {70, 220, 220, 255}} // flag, drop zone
ARENA_SEL_COL :: gfx.Color{255, 140, 70, 255}

// `component_transporter` heights, by a goal's `post` (its trigger's
// instance_id). Stock uses 14 m flags and 6 m drop zones.
ARENA_POST_HEIGHTS := [?]f32{2, 4, 6, 8, 10, 14, 18, 20, 25, 30}
ARENA_FLAG_POST :: 5
ARENA_DROP_ZONE_POST :: 2

// --- selection ----------------------------------------------------------------

// The route a route window is on, or -1: a layout window, or a route the
// project manager has since removed. Looked up by id every time, since a
// removal shifts the indices.
arena_window_route :: proc(ed: ^Editor) -> int {
	return ed.kind == .Arena_Route ? route_index(ed.doc.routes[:], ed.stage_id) : -1
}

// The window's route when the selection is on it, or -1.
selected_arena_route :: proc(ed: ^Editor) -> int {
	ri := arena_window_route(ed)
	if (ed.sel.kind == .Start || ed.sel.kind == .Goal) && ed.sel.idx == ri {
		return ri
	}
	return -1
}

// Select the window's route, and look at its start when it has one.
arena_focus_route :: proc(ed: ^Editor) {
	ri := arena_window_route(ed)
	if ri < 0 {
		return
	}
	ed.sel = {kind = .Start, idx = ri}
	if start := ed.doc.routes[ri].party_start; start.placed {
		ed.cam.target = start.pos
		ed.cam.distance = 90
	}
}

// The selected route's start, or -1. Selects the route even when its start
// is not placed yet, so the inspector can offer to place it.
selected_start :: proc(ed: ^Editor) -> int {
	return ed.sel.kind == .Start ? selected_arena_route(ed) : -1
}

// The selected goal as route and index, or -1s.
selected_goal :: proc(ed: ^Editor) -> (ri, gi: int) {
	ri = selected_arena_route(ed)
	if ed.sel.kind != .Goal || ri < 0 || ed.sel.sub < 0 || ed.sel.sub >= len(ed.doc.routes[ri].goals) {
		return -1, -1
	}
	return ri, ed.sel.sub
}

// --- drawing ------------------------------------------------------------------

// One slot's centre in world space.
@(private = "file")
start_slot :: proc(start: Arena_Spot, slot: [2]f32) -> gfx.Vector3 {
	s, c := math.sin(start.yaw), math.cos(start.yaw)
	return start.pos + slot.x * gfx.Vector3{c, 0, -s} + slot.y * gfx.Vector3{s, 0, c}
}

// The ring of 8 cars, and an arrow along its heading.
@(private = "file")
draw_start_ring :: proc(start: Arena_Spot, mode_key: string, selected: bool) {
	mode, known := arena_mode_of(mode_key)
	if !known || !start.placed {
		return
	}
	col := selected ? ARENA_SEL_COL : ARENA_START_COL[mode]
	for slot in ARENA_START_RING {
		at := start_slot(start, slot)
		draw_world_box(at - {1, 0.75, 1}, at + {1, 0.75, 1}, col)
	}
	tip := start_slot(start, {0, 8})
	gfx.DrawLine3D(start.pos, tip, col)
	gfx.DrawSphere(tip, 0.6, col)
	gfx.DrawSphere(start.pos, 1, col)
}

@(private = "file")
goal_height :: proc(goal: Arena_Goal) -> f32 {
	return ARENA_POST_HEIGHTS[clamp(int(goal.post), 0, len(ARENA_POST_HEIGHTS) - 1)]
}

// A post at its stock height, and a square on the ground round its foot.
@(private = "file")
draw_goal :: proc(goal: Arena_Goal, selected: bool) {
	col := selected ? ARENA_SEL_COL : ARENA_GOAL_COL[goal.drop_zone ? 1 : 0]
	top := goal.pos + {0, goal_height(goal), 0}
	gfx.DrawLine3D(goal.pos, top, col)
	gfx.DrawSphere(top, 0.8, col)
	draw_world_box(goal.pos - {3, 0, 3}, goal.pos + {3, 0.1, 3}, col)
}

// The window's route only: another route's spots are another window's.
draw_arena_spots :: proc(ed: ^Editor) {
	ri := arena_window_route(ed)
	if ri < 0 {
		return
	}
	route := ed.doc.routes[ri]
	_, sel_gi := selected_goal(ed)
	draw_start_ring(route.party_start, route.mode, selected_start(ed) == ri)
	for goal, gi in route.goals {
		draw_goal(goal, gi == sel_gi)
	}
	ghost, have := ed.spot_ghost.?
	kind, placing := ed.spot_placing.?
	if !have || !placing {
		return
	}
	if kind == .Start {
		draw_start_ring(ghost, ed.doc.routes[ri].mode, true)
	} else {
		draw_goal(spot_goal(kind, ghost.pos), true)
	}
}

// --- picking ------------------------------------------------------------------

// The nearest of the window's route's start and goals under the ray.
pick_arena_spot :: proc(ed: ^Editor, ray: gfx.Ray) -> (sel: Selection, dist: f32) {
	dist = max(f32)
	ri := arena_window_route(ed)
	if ri < 0 {
		return
	}
	{
		route := ed.doc.routes[ri]
		if start := route.party_start; start.placed {
			hit := gfx.GetRayCollisionSphere(ray, start.pos, 3)
			for slot in ARENA_START_RING {
				at := start_slot(start, slot)
				if h := gfx.GetRayCollisionBox(ray, at - {1, 0.75, 1}, at + {1, 0.75, 1}); h.hit && (!hit.hit || h.distance < hit.distance) {
					hit = h
				}
			}
			if hit.hit && hit.distance < dist {
				sel, dist = {kind = .Start, idx = ri}, hit.distance
			}
		}
		for goal, gi in route.goals {
			hit := gfx.GetRayCollisionBox(ray, goal.pos - {1.5, 0, 1.5}, goal.pos + {1.5, goal_height(goal), 1.5})
			if hit.hit && hit.distance < dist {
				sel, dist = {kind = .Goal, idx = ri, sub = gi}, hit.distance
			}
		}
	}
	return
}

// --- moving -------------------------------------------------------------------

// Move and turn a start, or move a goal. Starts turn by yaw only, read back off
// the heading; both drop onto the ground.
arena_spot_gizmo :: proc(ed: ^Editor, cam: gfx.Camera3D) -> (shown, used: bool) {
	op, space := gizmo_op_space(ed.gizmo_mode)
	if ri := selected_start(ed); ri >= 0 && ed.doc.routes[ri].party_start.placed {
		start := &ed.doc.routes[ri].party_start
		rot := gfx.QuaternionFromAxisAngle({0, 1, 0}, start.yaw)
		pos, turned, moved := ui.gizmo_manipulate_xform(start.pos, rot, cam, op, space)
		if moved {
			forward := gfx.Vector3RotateByQuaternion({0, 0, 1}, turned)
			start.pos, start.yaw = pos, math.atan2(forward.x, forward.z)
			start_drop(ed, start)
			mark_edited(ed.doc)
		}
		return true, moved
	}
	if ri, gi := selected_goal(ed); ri >= 0 {
		goal := &ed.doc.routes[ri].goals[gi]
		pos, _, moved := ui.gizmo_manipulate_xform(goal.pos, gfx.Quaternion(1), cam, .Translate, space)
		if moved {
			goal.pos = ground_under(ed, pos)
			mark_edited(ed.doc)
		}
		return true, moved
	}
	return false, false
}

// The ground straight below (or above) `at`, or `at` where there is none.
@(private = "file")
ground_under :: proc(ed: ^Editor, at: gfx.Vector3) -> gfx.Vector3 {
	if hit, ok := arena_pick_ground(ed, {position = at + {0, 200, 0}, direction = {0, -1, 0}}); ok {
		return hit
	}
	return at
}

// Stand the ring over the highest ground under any of its slots, at the stock
// lift. Left where it is when no slot is over ground.
@(private = "file")
start_drop :: proc(ed: ^Editor, start: ^Arena_Spot) {
	top, found := min(f32), false
	for slot in ARENA_START_RING {
		at := start_slot(start^, slot)
		if hit, ok := arena_pick_ground(ed, {position = at + {0, 200, 0}, direction = {0, -1, 0}}); ok {
			top, found = max(top, hit.y), true
		}
	}
	if found {
		start.pos.y = top + ARENA_START_LIFT
	}
}

arena_spot_delete :: proc(ed: ^Editor) -> bool {
	ri, gi := selected_goal(ed)
	if ri < 0 {
		return false
	}
	ordered_remove(&ed.doc.routes[ri].goals, gi)
	ed.sel = {kind = .Start, idx = ri}
	mark_edited(ed.doc)
	return true
}

// --- placing ------------------------------------------------------------------

@(private = "file")
spot_goal :: proc(kind: Arena_Spot_Kind, pos: [3]f32) -> Arena_Goal {
	drop := kind == .Drop_Zone
	return {pos = pos, drop_zone = drop, post = drop ? ARENA_DROP_ZONE_POST : ARENA_FLAG_POST}
}

// Twin of prop_set_placing (props.odin). Only one placing mode at a time.
arena_spot_set_placing :: proc(ed: ^Editor, kind: Arena_Spot_Kind, on: bool) {
	ed.spot_placing = on ? kind : nil
	ed.prop_placing = nil
}

// Where the spot being placed would land under the cursor.
arena_spot_ghost_update :: proc(ed: ^Editor, ray: gfx.Ray) {
	ed.spot_ghost = nil
	ri := arena_window_route(ed)
	if ri < 0 {
		ed.spot_placing = nil
	}
	kind, placing := ed.spot_placing.?
	if !placing {
		return
	}
	at, hit := arena_pick_ground(ed, ray)
	if !hit {
		return
	}
	ghost := Arena_Spot{pos = at, yaw = ed.doc.routes[ri].party_start.yaw, placed = true}
	if kind == .Start {
		start_drop(ed, &ghost)
	}
	ed.spot_ghost = ghost
}

// Twin of prop_place_input (props.odin). A start is placed once; flags and
// drop zones keep the mode on, since a route wants several.
arena_spot_place_input :: proc(ed: ^Editor, nav, ui_mouse, ui_keys: bool) -> bool {
	kind, placing := ed.spot_placing.?
	if !placing {
		return false
	}
	if (!ui_keys && gfx.IsKeyPressed(.ESCAPE)) || (!nav && !ui_mouse && gfx.IsMouseButtonPressed(.RIGHT)) {
		ed.spot_placing = nil
		return true
	}
	if nav || ui_mouse || !gfx.IsMouseButtonPressed(.LEFT) {
		return true
	}
	ghost, ok := ed.spot_ghost.?
	if !ok {
		set_status(&ed.status, "point at the ground to place it there", false)
		return true
	}
	ri := arena_window_route(ed)
	route := &ed.doc.routes[ri]
	if kind == .Start {
		route.party_start = ghost
		ed.spot_placing = nil
		ed.sel = {kind = .Start, idx = ri}
	} else {
		append(&route.goals, spot_goal(kind, ghost.pos))
	}
	mark_edited(ed.doc)
	set_status(&ed.status, fmt.tprintf("%s placed", ARENA_SPOT_NAMES[kind]), true)
	return true
}

// --- the inspector ----------------------------------------------------------------

// The window's route: its start, its goals, and the ways to set them.
draw_route_spots :: proc(ed: ^Editor) {
	ri := arena_window_route(ed)
	if ri < 0 {
		return
	}
	route := &ed.doc.routes[ri]
	mode, known := arena_mode_of(route.mode)
	if !known {
		return
	}
	ui.igSeparatorText(fmt.ctprintf("%s  %s", route.id, ARENA_MODE_LABEL[mode]))
	start := &route.party_start
	if start.placed {
		ui.im_text(fmt.ctprintf("start (%.1f, %.1f, %.1f)", start.pos.x, start.pos.y, start.pos.z))
		deg := math.to_degrees(start.yaw)
		if ui.igSliderFloat("heading", &deg, -180, 180, "%.0f deg", ui.IM_SLIDER_NONE) {
			start.yaw = math.to_radians(deg)
			mark_edited(ed.doc)
		}
	} else {
		ui.im_text_colored(WARN_COL, "no start placed")
	}
	draw_place_button(ed, .Start)
	ui.im_same_line()
	if ui.im_button("Use stock start") {
		stock, msg, ok := arena_stock_start(ed.doc.arena.donor_dir, mode)
		if ok {
			start^ = stock
			mark_edited(ed.doc)
		}
		set_status(&ed.status, ok ? "start set to stock route_0's" : msg, ok)
	}

	if mode == .Transporter {
		flags, drops := arena_goal_counts(route^)
		ui.im_text(fmt.ctprintf("%d flags, %d drop zones", flags, drops))
		draw_place_button(ed, .Flag)
		ui.im_same_line()
		draw_place_button(ed, .Drop_Zone)
		if ui.im_button("Use stock flags and drop zones") {
			stock, msg, ok := arena_stock_goals(ed.doc.arena.donor_dir)
			if ok {
				clear(&route.goals)
				append(&route.goals, ..stock)
				mark_edited(ed.doc)
				msg = fmt.tprintf("%d stock flags and drop zones", len(stock))
			}
			set_status(&ed.status, msg, ok)
		}
	}
	if kind, placing := ed.spot_placing.?; placing {
		ui.im_text_colored(MINE_COL, fmt.ctprintf("click the ground to place a %s; Esc or right-click stops", ARENA_SPOT_NAMES[kind]))
	}

	if _, gi := selected_goal(ed); gi >= 0 {
		goal := &route.goals[gi]
		ui.igSeparatorText(fmt.ctprintf("%s %d", goal.drop_zone ? "Drop zone" : "Flag", gi))
		post := i32(clamp(int(goal.post), 0, len(ARENA_POST_HEIGHTS) - 1))
		if ui.igSliderInt("post", &post, 0, i32(len(ARENA_POST_HEIGHTS) - 1),
			fmt.ctprintf("%.0f m", ARENA_POST_HEIGHTS[post]), ui.IM_SLIDER_NONE) {
			goal.post = post
			mark_edited(ed.doc)
		}
		if ui.im_button(fmt.ctprintf("Delete %s", goal.drop_zone ? "drop zone" : "flag")) {
			arena_spot_delete(ed)
		}
	}
}

@(private = "file")
draw_place_button :: proc(ed: ^Editor, kind: Arena_Spot_Kind) {
	placing := ed.spot_placing == kind
	if ui.im_button(fmt.ctprintf("%s %s###place_%v", placing ? "Stop" : "Place", ARENA_SPOT_NAMES[kind], kind)) {
		arena_spot_set_placing(ed, kind, !placing)
	}
}

