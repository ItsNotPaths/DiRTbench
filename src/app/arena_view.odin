package main

// An arena window. It shares the camera, the menubar and the docks with the
// venue and stage windows, and nothing that assumes a road: there is no
// rebuild, no gizmo on road points, and no stage cache.

import "core:fmt"
import "../gfx"
import "../ui"

// Twin of stage_frame and venue_frame (view.odin): the same frame order, minus
// everything that reads the road.
arena_frame :: proc(ed: ^Editor) {
	gfx.BeginWindowFrame(&ed.window)
	ui_mouse := ui.imgui_want_capture_mouse()
	ui_keys := ui.imgui_want_capture_keyboard()
	editor_hotkeys(ed, ui_keys)

	nav := alt_held()
	camera_step(ed, ui_mouse, nav)
	cam3d := to_camera3d(ed.cam)
	draw_arena_scene(ed, cam3d)

	ui.imgui_backend_begin()
	draw_menubar(ed)
	draw_arena_inspector(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	gfx.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}

// Twin of draw_venue_scene (scene.odin). The ground and the baseline props
// come with items 4 and 5 of docs/plan-party-levels.md.
draw_arena_scene :: proc(ed: ^Editor, cam3d: gfx.Camera3D) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	gfx.EndMode3D()
}

draw_arena_inspector :: proc(ed: ^Editor) {
	open := sidebar_begin("Arena", .Left)
	defer sidebar_end(open)
	if !open {
		return
	}
	ui.igSeparatorText(fmt.ctprint(ed.doc.venue_name))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("on %s/%s", ARENA_BASE, ARENA_BASE_ROUTE))
	draw_status_text(&ed.status)

	ui.igSeparatorText("Routes")
	for route in ed.doc.routes {
		label := route.mode
		if mode, known := arena_mode_of(route.mode); known {
			label = ARENA_MODE_LABEL[mode]
		}
		ui.im_text(fmt.ctprintf("%s  %s", route.id, route.name))
		ui.im_same_line()
		ui.im_text_colored(DIM_COL, fmt.ctprint(label))
	}
	ui.im_text_colored(DIM_COL, "Add, remove and rename routes in the project manager.")
}
