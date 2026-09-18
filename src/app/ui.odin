package main

// The editor's ImGui layer: the menubar, the floating panels, and the commands
// they invoke.
//
// Everything here reads and writes `Editor` (main.odin) and nothing else. It
// owns no state of its own, so a panel can be added, moved or deleted without
// touching the frame loop — `main` calls the four top-level `draw_*` procs and
// is otherwise unaware of what they draw.
//
// The `do_*` procs are the editor's verbs. They live here because the UI is what
// binds them, but they are plain procedures: `main` calls `do_save` directly for
// Ctrl+S, without going through a widget.

import "core:c"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../gfx"
import "../geo"
import "../ui"

// --- actions ----------------------------------------------------------------

// Saves under the (sanitised) name in the buffer, and writes the sanitised name
// back so the field always shows the filename that actually exists on disk.
do_save :: proc(ed: ^Editor) {
	// A stage opened from one of our venues belongs to it. Saving it into
	// maps/ under whatever the name field says would quietly fork the document.
	if ed.doc.open_venue != "" {
		path := venue_road_path(ed.doc.open_venue)
		msg, ok := save_road(ed.doc, path)
		if ok {
			// The markers are the stages, and they live in venue.json. Saving the
			// road without them would drop every start and finish line.
			msg, ok = venue_routes_save(ed.doc.open_venue, ed.doc.routes[:], ed.doc.next_route)
		}
		if ok {
			msg = fmt.tprintf("saved %s", ed.doc.open_venue)
			recovery_doc_saved(recovery_root(), ed.doc)
			// The project manager holds its own copy of venue.json, and both
			// deploy and every reopen read that copy rather than the file. It
			// has to be told the file moved under it, or a start line saved
			// here is invisible to both.
			ed.app.screen.reload_pending = true
		}
		set_status(&ed.status, msg, ok)
		return
	}
	name := sanitise_stage_name(stage_name_text(ed.doc))
	set_stage_name(ed.doc, name)
	msg, ok := save_road_named(ed.doc, name)
	if ok {
		recovery_doc_saved(recovery_root(), ed.doc)
	}
	set_status(&ed.status, msg, ok)
}

// The chain this window exports, and the name it exports under.
//
// Only a loose road out of maps/ exports from an editor window. A venue's
// stages are written by the project manager, which publishes all of them
// against one load of the road graph — see venue_export_all.
export_target_chain :: proc(ed: ^Editor) -> (chain: geo.Spline, name: string, ok: bool) {
	if ed.kind != .Stage || ed.doc.open_venue != "" {
		return
	}
	return ed.doc.spline, sanitise_stage_name(stage_name_text(ed.doc)), len(ed.doc.spline.points) >= 2
}

// The worker is joined and the rebuild finished first: an export reads the
// geometry, so it cannot run against a job still in flight or against a terrain
// deferred by a drag. Nothing is dragging when a menu is open, so in practice
// this only waits, and it is the guard against ever calling export elsewhere.
do_export :: proc(ed: ^Editor, target: ^Export_Target) {
	chain, name, ready := export_target_chain(ed)
	if !ready {
		set_status(&ed.status, "only a loose road out of maps/ exports here; a venue publishes from the project manager", false)
		return
	}
	set_stage_name(ed.doc, name)
	rebuild_join(ed.doc)
	rebuild_geometry(ed.doc)
	msg, ok := export_stage(ed.doc, chain, name, ed.stage_id, target)
	set_status(&ed.status, msg, ok)
}

do_load :: proc(ed: ^Editor, name: string) {
	// The sculpt comes out of the file, so it must not be invalidated after:
	// the loaded offsets are what the next rebuild re-attaches by position.
	msg, ok := load_road_named(ed.doc, name)
	if ok {
		set_stage_name(ed.doc, name)
		ed.sel = {} // indices from the old spline mean nothing now
		mark_dirty(ed.doc)
		doc_loaded(ed.doc)
	}
	set_status(&ed.status, msg, ok)
}

do_new :: proc(ed: ^Editor) {
	seed_spline(&ed.doc.spline)
	ed.doc.timing = TIMING_DEFAULTS
	ed.sel = {}
	geo.terrain_invalidate(&ed.doc.terrain)
	set_stage_name(ed.doc, "untitled")
	mark_dirty(ed.doc)
	set_status(&ed.status, "new stage", true)
}

// Regenerating reallocates spline.points, so it must never run while the gizmo
// holds a pointer into that array — hence the gizmo_active guard at each call.
do_generate :: proc(ed: ^Editor, frame_camera: bool) {
	msg, ok := generate_stage(&ed.doc.spline, ed.doc.gen)
	if ok {
		ed.sel = {}
		geo.terrain_invalidate(&ed.doc.terrain)
		mark_dirty(ed.doc)
		if frame_camera {
			frame_spline(&ed.cam, ed.doc.spline)
		}
	}
	set_status(&ed.status, msg, ok)
}

// --- the side docks ----------------------------------------------------------

// Panels are docked to the window edges, not floated over it: pinned under the
// menubar, full height, and neither movable nor resizable. Nothing a road is
// edited through should be draggable over the road.
SIDEBAR_W :: 360

SIDEBAR_FLAGS ::
	ui.IM_WINDOW_NO_TITLE_BAR |
	ui.IM_WINDOW_NO_RESIZE |
	ui.IM_WINDOW_NO_MOVE |
	ui.IM_WINDOW_NO_COLLAPSE |
	ui.IM_WINDOW_NO_SAVED_SETTINGS |
	ui.IM_WINDOW_NO_BRING_TO_FRONT

Sidebar_Side :: enum {
	Left,
	Right,
}

// Pin one dock to its edge. False when the window is not drawing this frame;
// `sidebar_end` is owed either way, and takes the same answer back.
sidebar_begin :: proc(name: cstring, side: Sidebar_Side) -> bool {
	top := ui.igGetFrameHeight() // the main menu bar
	w, h := f32(gfx.GetScreenWidth()), f32(gfx.GetScreenHeight())
	x: f32 = side == .Left ? 0 : w - SIDEBAR_W
	ui.igSetNextWindowPos({x, top}, .Always, {0, 0})
	ui.igSetNextWindowSize({SIDEBAR_W, h - top}, .Always)
	open := ui.igBegin(name, nil, SIDEBAR_FLAGS)
	if open {
		// A dock is a fixed width and the paths in it are not. Wrap rather than
		// run off the edge.
		ui.igPushTextWrapPos(0)
	}
	return open
}

sidebar_end :: proc(open: bool) {
	if open {
		ui.igPopTextWrapPos()
	}
	ui.igEnd()
}

// A section of a shared dock, and the close its own title bar used to carry.
sidebar_section :: proc(label: cstring, open: ^bool) {
	ui.igSeparatorText(label)
	if ui.im_button(fmt.ctprintf("Close###close%s", label)) {
		open^ = false
	}
}

// --- UI ---------------------------------------------------------------------

draw_menubar :: proc(ed: ^Editor) {
	if !ui.igBeginMainMenuBar() {
		return
	}
	defer ui.igEndMainMenuBar()

	if ui.igBeginMenu("File", true) {
		if ed.doc.open_venue != "" && ui.igMenuItem_Bool("Close editor", nil, false, true) {
			ed.quit = true
		}
		if ed.doc.open_venue == "" && ui.igMenuItem_Bool("New", nil, false, true) {
			do_new(ed)
		}
		if ui.igMenuItem_Bool("Save", "Ctrl+S", false, len(ed.doc.spline.points) >= 2) {
			do_save(ed)
		}
		if ed.doc.open_venue == "" && ui.igBeginMenu("Load", true) {
			stages := list_stages()
			if len(stages) == 0 {
				ui.igBeginDisabled(true)
				ui.igMenuItem_Bool("(no stages in maps/)", nil, false, true)
				ui.igEndDisabled()
			}
			for name in stages {
				label := fmt.ctprint(name)
				if ui.igMenuItem_Bool(label, nil, name == stage_name_text(ed.doc), true) {
					do_load(ed, name)
				}
			}
			ui.igEndMenu()
		}
		ui.igSeparator()
		_, _, exportable := export_target_chain(ed)
		if ed.doc.open_venue == "" && ui.igBeginMenu("Export to", exportable) {
			for &t in EXPORT_TARGETS {
				label := fmt.ctprint(t.label)
				if ui.igMenuItem_Bool(label, nil, false, true) {
					do_export(ed, &t)
				}
			}
			ui.igEndMenu()
		}
		if ed.doc.open_venue == "" && ui.igMenuItem_Bool("Export targets...", nil, ed.show_targets, true) {
			ed.show_targets = !ed.show_targets
		}
		ui.igSeparator()
		if ui.igMenuItem_Bool("Quit", "Esc", false, true) {
			ed.quit = true
		}
		ui.igEndMenu()
	}
	if ui.igBeginMenu("Dirt 3", true) {
		if ui.igMenuItem_Bool("Rescan install", nil, false, true) {
			install_scan_rescan(ed.doc.install)
			set_status(&ed.status, install_scan_status_text(ed.doc.install), ed.doc.install.found)
		}
		ui.igEndMenu()
	}
	if ui.igBeginMenu("View", true) {
		if ed.kind == .Venue && ui.igMenuItem_Bool("Road generator", nil, ed.show_gen, true) {
			ed.show_gen = !ed.show_gen
		}
		ui.igSeparator()
		if ui.igMenuItem_Bool("ImGui demo window", nil, ed.show_demo, true) {
			ed.show_demo = !ed.show_demo
		}
		ui.igEndMenu()
	}
}

// The last save/load/export result, green or red, for however long
// STATUS_LINGER allows. Drawn by the inspector and by the venue screen, which
// is why it is not inline in either.
draw_status_text :: proc(s: ^Status) {
	msg, shown := status_text(s)
	if !shown {
		return
	}
	green := ui.Im_Vec4{0.45, 0.85, 0.5, 1}
	red := ui.Im_Vec4{1.0, 0.45, 0.4, 1}
	ui.im_text_colored(s.ok ? green : red, msg)
}

// A section of the right dock, switched on from the menubar.
draw_generator :: proc(ed: ^Editor) {
	sidebar_section("Road generator", &ed.show_gen)

	ui.im_text("Same seed and settings always give the same road.")
	ui.igSpacing()

	// `changed` must not short-circuit: every widget has to be drawn every
	// frame, so collect the results rather than folding with ||=.
	changed := false
	g := &ed.doc.gen

	if ui.igInputInt("seed", &g.seed, 1, 16, ui.IM_INPUT_TEXT_NONE) {changed = true}
	ui.im_same_line()
	if ui.im_button("Randomise") {
		g.seed = rand.int31_max(1_000_000)
		changed = true
	}

	ui.igSeparatorText("Shape")
	if ui.igSliderFloat("length", &g.length_m, 400, 8000, "%.0f m", ui.IM_SLIDER_NONE) {changed = true}
	if ui.igSliderFloat("curviness", &g.curviness, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
	if ui.igSliderFloat("hairpins", &g.hairpins, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
	if ui.igSliderFloat("hilliness", &g.hilliness, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
	if ui.igSliderFloat("banking", &g.bank, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}

	ui.igSeparatorText("Road")
	if ui.igSliderFloat("min width", &g.width_min, 3, 20, "%.1f m", ui.IM_SLIDER_NONE) {changed = true}
	if ui.igSliderFloat("max width", &g.width_max, 3, 20, "%.1f m", ui.IM_SLIDER_NONE) {changed = true}
	// Sliders can cross; keep the pair ordered rather than letting the
	// generator emit a negative width range.
	if g.width_max < g.width_min {
		g.width_max = g.width_min
	}
	if ui.igSliderFloat("point spacing", &g.spacing_m, 8, 60, "%.0f m", ui.IM_SLIDER_NONE) {changed = true}

	ui.igSeparatorText("")
	if ui.im_button("Generate") {
		do_generate(ed, true)
	}
	ui.im_same_line()
	if ui.im_button("Reset settings") {
		ed.doc.gen = GEN_DEFAULTS
		changed = true
	}
	ui.im_same_line()
	ui.igCheckbox("live", &ed.doc.gen_live)

	// Live regeneration is what makes the sliders legible, but it rebuilds the
	// point array; doing that mid-drag would pull the array out from under the
	// gizmo's pointer.
	if changed && ed.doc.gen_live && !ed.gizmo_active {
		do_generate(ed, false)
	}
}

// A stage window's panel. The road is read-only here, so this is the stage and
// nothing else: its name, where its two lines sit, and whether the road between
// them compiles.
draw_stage_inspector :: proc(ed: ^Editor) {
	open := sidebar_begin("Stage", .Left)
	defer sidebar_end(open)
	if !open {
		return
	}

	route := selected_route(ed)
	if route == nil {
		ui.im_text_colored(
			WARN_COL,
			fmt.ctprintf("%s is no longer a stage of %s", ed.stage_id, ed.doc.open_venue),
		)
		ui.im_text("close this window")
		return
	}

	ui.igSeparatorText(fmt.ctprint(route.name))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("%s / %s", ed.doc.open_venue, route.id))
	ui.igBeginDisabled(len(ed.doc.spline.points) < 2)
	if ui.im_button("Save") {
		do_save(ed)
	}
	ui.igEndDisabled()
	draw_status_text(&ed.status)

	ui.igSeparatorText("Start and finish")
	ui.im_text_colored(
		route_has_markers(route^) ? MINE_COL : WARN_COL,
		route_has_markers(route^) ? "both lines placed" : "no lines yet",
	)
	msg := buf_text(ed.stage.msg[:])
	if ed.stage.state == .Ready {
		ui.im_text_colored(MINE_COL, fmt.ctprintf("%s, %.0f m", msg, ed.stage.length))
	} else {
		ui.im_text_colored(WARN_COL, fmt.ctprint(msg))
	}

	draw_pins_section(ed, route)

	// The gates are drawn on this stage's ribbon, but their numbers are the
	// venue's, so a change here moves every stage's gates.
	ui.im_text_colored(DIM_COL, "gates below are venue-wide")
	draw_timing_section(ed)
	draw_pace_section(ed)

	ui.igSeparatorText("Controls")
	ui.im_text("point at the road and press S for the start line")
	ui.im_text("F sets the finish, P drops a pin. The road is read-only here.")
	ui.im_text("Alt+LMB pan, Alt+RMB orbit, wheel zoom")
}

// The roads the stage is made to cross on its way. With none, the compile takes
// the shortest road from the start to the finish; each pin is one more road it
// has to take in, which is how the long way round is asked for.
draw_pins_section :: proc(ed: ^Editor, route: ^Venue_Route) {
	ui.igSeparatorText("Route pins")
	if len(route.pins) == 0 {
		ui.im_text_colored(DIM_COL, "none — the stage takes the shortest road")
	}
	remove := -1
	for pin, i in route.pins {
		ui.im_text(fmt.ctprintf("%d.  edge %d-%d", i + 1, pin.from, pin.to))
		ui.im_same_line()
		if ui.im_button(fmt.ctprintf("Remove###pin_%d", i)) {
			remove = i
		}
	}
	// After the loop: removing inside it would walk a list that just moved.
	if remove >= 0 {
		ordered_remove(&route.pins, remove)
		mark_edited(ed.doc)
		set_status(&ed.status, "pin removed", true)
	}
}

draw_inspector :: proc(ed: ^Editor) {
	open := sidebar_begin("Inspector", .Left)
	defer sidebar_end(open)
	if !open {
		return
	}

	// The selection block is held at the foot of the dock and everything else
	// scrolls under it, so what is selected is always in front of you and never
	// behind a collapsed header.
	foot := selection_block_height(ed)
	if ui.igBeginChild_Str("inspector_body", {0, -foot}, ui.IM_CHILD_NONE, ui.IM_WINDOW_NONE) {
		draw_inspector_body(ed)
	}
	ui.igEndChild()
	draw_selection_block(ed)
}

draw_inspector_body :: proc(ed: ^Editor) {
	ui.igSeparatorText(ed.doc.open_venue != "" ? "Venue road network" : "Stage")
	if ed.doc.open_venue != "" {
		ui.im_text(fmt.ctprint(ed.doc.open_venue))
	} else {
		if ui.igInputText("name", raw_data(ed.doc.stage_name[:]), len(ed.doc.stage_name), ui.IM_INPUT_TEXT_CHARS_NO_BLANK, nil, nil) {
			mark_edited(ed.doc)
		}
	}
	ui.igBeginDisabled(len(ed.doc.spline.points) < 2)
	if ui.im_button("Save") {
		do_save(ed)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	ui.igBeginDisabled(len(ed.doc.spline.points) < 2 || !geo.is_linear(ed.doc.spline))
	if ui.im_button("Reverse") {
		geo.reverse_spline(&ed.doc.spline)
		routes_reverse(ed.doc.routes[:])
		ed.sel = {}
		mark_dirty(ed.doc)
		set_status(&ed.status, "reversed driving direction", true)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	if ui.im_button("Generate...") {
		ed.show_gen = true
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d points", len(ed.doc.spline.points)))

	draw_status_text(&ed.status)

	ui.igSeparatorText("Gizmo")
	if ui.igRadioButton_Bool("Move (1)", ed.gizmo_mode == .Move) {
		ed.gizmo_mode = .Move
	}
	ui.im_same_line()
	if ui.igRadioButton_Bool("Rotate (2)", ed.gizmo_mode == .Rotate) {
		ed.gizmo_mode = .Rotate
	}

	draw_terrain_section(ed)
	draw_veg_section(ed)
	draw_props_sections(ed)

	ui.igSeparatorText("Controls")
	ui.im_text("LMB select point or terrain node")
	ui.im_text("Terrain: RMB+LMB drag sizes brush; release RMB to raise/lower")
	ui.im_text("Floors: draw one from the Terrain panel; Del removes a corner")
	ui.im_text("Props: pick one in the Objects or Ornaments panel, B places, Del removes")
	ui.im_text("Shift+drag gizmo extrudes a point")
	ui.im_text("RMB insert on road / append on ground")
	ui.im_text("DEL remove")
	ui.im_text("Alt+LMB pan, Alt+RMB orbit, wheel zoom")
}

// Gates are spread along one compiled stage, so this is a stage window's panel.
// The numbers behind it are the venue's, in road.json.
draw_timing_section :: proc(ed:^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Timing gates",ui.IM_TREE_NODE_DEFAULT_OPEN) { return }
	ui.im_text_colored(DIM_COL,fmt.ctprintf("%d checkpoints, fixed by the game",TIMING_CHECKPOINTS))
	if ui.igSliderFloat("start/end buffer",&ed.doc.timing.buffer_m,0,500,"%.0f m",ui.IM_SLIDER_NONE) {
		mark_edited(ed.doc)
	}
}

// Global mesh settings. Every control here changes geometry, so each marks the
// caches dirty; the rebuild happens once, at the top of the next frame.
draw_terrain_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Terrain", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	if ui.im_button(ed.wireframe ? "Wireframe: on" : "Wireframe: off") {
		ed.wireframe = !ed.wireframe
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d tris", ed.doc.road.tris + ed.doc.terrain_mesh.tris))

	draw_terrain_mesh_section(ed)
}

// The out-of-stage mesh. Sculpt controls are spaced directly in world XZ.
draw_terrain_mesh_section :: proc(ed: ^Editor) {
	t := &ed.doc.terrain
	if ui.igCheckbox("terrain", &t.enabled) {
		if !t.enabled && ed.sel.kind == .Node {
			ed.sel = {} // its handle just went away
		}
		mark_terrain_dirty(ed.doc)
	}
	if !t.enabled {
		return
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d tris", ed.doc.terrain_mesh.tris))

	if ui.igSliderFloat("reach", &t.reach_m, 8, geo.TERRAIN_REACH_MAX, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
	// How far the road pulls the ground with it before sculpt offsets take over.
	// Must stay inside the reach, or the seam never resolves to the controls at
	// all. Too narrow and the terrain terraces rather than sloping.
	if ui.igSliderFloat("blend", &t.blend_m, 1, max(t.reach_m, 2), "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
	t.blend_m = min(t.blend_m, t.reach_m)
	// Spacing of the interior points the ground is triangulated from.
	if ui.igSliderFloat("cell", &t.cell_m, 1, 32, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}

	// These regenerate controls, which the node gizmo is writing into. Same guard,
	// and same reason, as the generator's `live` checkbox.
	ui.igBeginDisabled(ed.gizmo_active)
	defer ui.igEndDisabled()

	if ui.igSliderFloat("node spacing", &t.row_m, geo.TERRAIN_ROW_M_MIN, geo.TERRAIN_ROW_M_MAX, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("(%d controls)", geo.terrain_node_count(t)))

	if ui.im_button("Flatten to verge") {
		geo.terrain_invalidate(t)
		mark_terrain_dirty(ed.doc)
	}

	draw_floor_section(ed)
}

// Drawing a floor, and the count of them. What one selected floor is worth
// tweaking lives in the selection block.
draw_floor_section :: proc(ed: ^Editor) {
	t := &ed.doc.terrain
	ui.igSeparatorText("Floors")
	if ed.floor_drawing {
		ui.im_text(fmt.ctprintf("%d corners placed", len(ed.floor_draw)))
		ui.im_text("click the ground for each corner")
		ui.im_text("Enter or RMB closes it, Esc drops it")
		if ui.im_button("Close") {
			floor_draw_close(ed)
		}
		ui.im_same_line()
		if ui.im_button("Cancel") {
			floor_draw_cancel(ed)
		}
		return
	}

	if ui.im_button("New floor") {
		floor_draw_begin(ed)
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d placed", len(t.floors)))
	if selected_floor(ed) < 0 {
		ui.im_text_colored(DIM_COL, "click one to select it")
	}
}

// --- the selection block ------------------------------------------------------

// What the block draws, in widget rows, so the dock knows how much to hold back
// for it. It is positioned before it is drawn and so cannot be measured; keep
// these in step with draw_selection_block.
@(rodata)
SEL_ROWS := [Sel_Kind]f32{
	.None       = 2,
	.Point      = 15,
	.Node       = 3,
	.Floor      = 7,
	.Floor_Vert = 7,
	.Prop       = 7,
}

// Never more than half the dock: a fifteen-row point on a short window would
// otherwise leave nothing above it to scroll.
selection_block_height :: proc(ed: ^Editor) -> f32 {
	avail := ui.igGetContentRegionAvail()
	return min(SEL_ROWS[ed.sel.kind] * ui.igGetFrameHeightWithSpacing(), avail.y * 0.5)
}

// The foot of the Inspector: whatever is selected, and the numbers that belong
// to it. One arm per Sel_Kind, and each is the only place its controls live —
// the sections above own the document, this owns the selection.
draw_selection_block :: proc(ed: ^Editor) {
	if !ui.igBeginChild_Str("selection", {0, 0}, ui.IM_CHILD_BORDERS, ui.IM_WINDOW_NONE) {
		ui.igEndChild()
		return
	}
	defer ui.igEndChild()

	switch ed.sel.kind {
	case .None:
		ui.igSeparatorText("Nothing selected")
		ui.im_text_colored(DIM_COL, "click a road point, a terrain node, a floor or a prop")
	case .Point:
		draw_point_selection(ed)
	case .Node:
		ui.igSeparatorText("Terrain control")
		ui.im_text_colored(DIM_COL, "drag its vertical handle to sculpt")
	case .Floor, .Floor_Vert:
		draw_floor_selection(ed)
	case .Prop:
		draw_prop_selection(ed)
	}
}

// Flat pads (geo/floor.odin). A pad is a ceiling on the ground, so the only
// numbers it carries are the height it holds and how far out it blends.
draw_floor_selection :: proc(ed: ^Editor) {
	fi := selected_floor(ed)
	if fi < 0 {
		return // deleted or reloaded under the selection
	}
	f := &ed.doc.terrain.floors[fi]
	_, v := selected_floor_vert(ed)
	ui.igSeparatorText(fmt.ctprintf("Floor %d", fi))
	ui.im_text(fmt.ctprintf("%d corners%s", f.count, v >= 0 ? fmt.ctprintf(", corner %d", v) : ""))
	if ui.igDragFloat("height", &f.y, 0.1, 0, 0, "%.1f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
	// Zero is a wall: the pad would meet the hillside at a vertical face, and
	// that face is exported as collision, not just drawn.
	if ui.igSliderFloat("falloff", &f.falloff, 0, 64, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
	if ui.igCheckbox("clear foliage", &f.clear_veg) {
		mark_terrain_dirty(ed.doc)
	}
	ui.im_text_colored(DIM_COL, "RMB an edge adds a corner, Del removes")
	if ui.im_button("Delete floor") {
		ed.sel = {kind = .Floor, idx = fi}
		floor_delete(ed)
	}
}

// Everything that belongs to the one selected control point.
draw_point_selection :: proc(ed: ^Editor) {
	sel := selected_point(ed)
	if sel < 0 {
		return // the spline shrank under the selection
	}
	p := &ed.doc.spline.points[sel]
	ui.igSeparatorText(fmt.ctprintf("Point %d of %d", sel, len(ed.doc.spline.points)))

	if ui.igDragFloat3("position", cast(^[3]f32)&p.xform.translation, 0.1, 0, 0, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat("width", &p.width, 2, 32, "%.1f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	// Per-node roughness offset, added to the global slider (both clamped to [0,1]
	// where the road is displaced). Negative smooths this stretch below the stage
	// baseline; positive roughens it. The 7-inch cap still applies regardless.
	if ui.igSliderFloat("roughness offset", &p.roughness, -1, 1, "%+.2f", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}

	ui.igSeparatorText("Cliffs")
	if ui.igSliderFloat("left height", &p.cliff_l, 0, geo.CLIFF_HEIGHT_MAX, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat("left span", &p.span_l, 0, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat("right height", &p.cliff_r, 0, geo.CLIFF_HEIGHT_MAX, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat("right span", &p.span_r, 0, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	// Taper and angle are shared by both sides, like the shape of the cliff
	// rather than the size of it.
	if ui.igSliderFloat("taper", &p.cliff_taper, 0, 100, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat("angle", &p.cliff_angle, geo.CLIFF_ANGLE_MIN, geo.CLIFF_ANGLE_MAX, "%.1f deg", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}

	ui.igSpacing()
	if ui.im_button("Delete point") {
		geo.remove_point(&ed.doc.spline, sel)
		ed.sel = {}
		mark_dirty(ed.doc)
	}
}

// Pace notes on the compiled stage, and the ride that calls them. A stage
// window's panel: the notes come from this window's ribbon, and the knobs are
// the venue's — they say how a corner is called, not which stage calls it.
// Nothing here marks geometry dirty; stage_notes_refresh compares the knobs.
draw_pace_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Pace notes", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	pp := &ed.doc.pace
	// Corner sensitivity: the largest radius still called a corner. Bigger = more
	// gentle bends get a number.
	if ui.igSliderFloat("call radius", &pp.r_on, 40, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		pp.r_off = max(pp.r_off, pp.r_on + 20)
	}
	// How far ahead of the feature the call fires.
	ui.igSliderFloat("lead", &pp.lead_m, 0, 120, "%.0f m", ui.IM_SLIDER_NONE)
	// Straight length that turns "into" into a spoken distance.
	ui.igSliderFloat("into gap", &pp.into_m, 4, 120, "%.0f m", ui.IM_SLIDER_NONE)
	ui.igSpacing()
	pace_ready := len(ed.app.clips) > 0
	ui.igBeginDisabled(!pace_ready || len(ed.stage.notes) == 0)
	if ui.im_button(ed.previewing ? "Stop ride" : "Preview ride") {
		preview_toggle(ed)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	// Direct playback test: bypasses the ride/queue entirely, so a silent result
	// here points at the audio device, not our sequencing.
	if ui.im_button("Test clip") {
		if snd, ok := ed.app.clips["hairpin-left"]; ok {
			gfx.PlaySound(snd)
		}
	}
	ui.igSliderFloat("speed", &ed.preview_speed, 5, 80, "%.0f m/s", ui.IM_SLIDER_NONE)
	ui.im_text(fmt.ctprintf("audio device: %s", gfx.IsAudioDeviceReady() ? "ready" : "NOT ready"))
	if !pace_ready {
		ui.im_text("(no clips found in pacenotes/)")
	} else if ed.previewing {
		nextm := ed.preview_next < len(ed.stage.notes) ? ed.stage.notes[ed.preview_next].station - ed.preview_s : 0
		ui.im_text(fmt.ctprintf("riding %.0f m  (next call in %.0f m)", ed.preview_s, max(0, nextm)))
	} else {
		ui.im_text(fmt.ctprintf("%d clips loaded", len(ed.app.clips)))
	}
	ui.igSpacing()

	ui.im_text(fmt.ctprintf("%d notes", len(ed.stage.notes)))

	// The dock scrolls, but a long stage is hundreds of calls. Cap the list; the
	// preview is where you live with the full stream anyway.
	PACE_LIST_MAX :: 30
	for nt, i in ed.stage.notes {
		if i >= PACE_LIST_MAX {
			ui.im_text(fmt.ctprintf("... +%d more", len(ed.stage.notes) - PACE_LIST_MAX))
			break
		}
		ui.im_text(fmt.ctprintf("%6.0fm  %s", nt.station, geo.pace_note_text(nt)))
	}
}

// Vegetation scatter. Every knob flags the cache dirty; the document's worker
// regenerates it (and the viewport shapes) and it lands a frame or two later. The
// scatter is saved with the stage and handed to the export target, so nothing
// here touches geometry.
draw_veg_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Vegetation", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	v := &ed.doc.veg
	if ui.igCheckbox("vegetation", &v.enabled) {
		mark_veg_dirty(ed.doc)
	}
	if !v.enabled {
		return
	}

	// Which species, and why it is not a choice: they belong to the base venue's
	// art, and a venue derives its art wholesale.
	ui.im_text_colored(DIM_COL, fmt.ctprintf("%s (from the base venue)", geo.VEG_PRESET_NAMES[v.preset]))

	if ui.igSliderFloat("density", &v.density, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {
		mark_veg_dirty(ed.doc)
	}
	// At 0 the scatter is even across the reach; at 1 the same trees are packed
	// against the verge and the tree line goes thin. Tree count barely moves.
	if ui.igSliderFloat("road bias", &v.road_bias, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {
		mark_veg_dirty(ed.doc)
	}
	if ui.igSliderInt("seed", &v.seed, 1, 999, "%d", ui.IM_SLIDER_NONE) {
		mark_veg_dirty(ed.doc)
	}

	ui.igSpacing()
	ui.im_text(fmt.ctprintf("%d trees", len(ed.doc.veg_cache)))
	if !ed.doc.terrain.enabled {
		ui.im_text("(terrain off: trees ride the road edge)")
	}
	// The overlay batch is a fixed buffer. The trees are a mesh and no longer in it,
	// so anything dropped here is a handle or a node line.
	if dropped := gfx.batch_dropped_verts(); dropped > 0 {
		ui.im_text(fmt.ctprintf("overlay batch full: %d verts dropped", dropped))
	}
}

// One row per target: what it does and where it writes. Also the place the
// debug detour is turned on, and the one place `dirtbench.conf` is named, so
// someone who has not written one can see what they are missing.
draw_targets :: proc(ed: ^Editor) {
	sidebar_section("Export targets", &ed.show_targets)

	ui.igCheckbox("Write to out/ instead of the game", &ed.doc.debug_export)
	ui.igSpacing()

	_, name, _ := export_target_chain(ed)
	for &t in EXPORT_TARGETS {
		ui.igSeparatorText(fmt.ctprint(t.label))
		ui.im_text(fmt.ctprint(t.blurb))
		dest, installing, dest_msg, dest_ok := export_dest(ed.doc, name, ed.stage_id, &t)
		if !dest_ok {
			ui.im_text_colored(DIM_COL, fmt.ctprint(dest_msg))
		} else if installing {
			ui.im_text(fmt.ctprintf("Into the game: %s", dest))
			ui.im_text_colored(DIM_COL, "Overwritten files are kept as <file>.orig.")
		} else {
			ui.im_text(fmt.ctprintf("Writes to %s", dest))
		}
		ui.igSpacing()
	}

	ui.igSeparator()
	conf := conf_path()
	if os.exists(conf) {
		ui.im_text(fmt.ctprintf("Config: %s", conf))
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("No %s yet", conf))
	}
}

// The venue window's right dock: whichever of the two optional panels the
// menubar has switched on, one above the other. Absent while both are off, so
// the road is uncovered on that side until something is asked for.
draw_venue_tools :: proc(ed: ^Editor) {
	if !ed.show_gen && !ed.show_targets {
		return
	}
	open := sidebar_begin("Venue tools", .Right)
	defer sidebar_end(open)
	if !open {
		return
	}

	if ed.show_gen {
		draw_generator(ed)
	}
	if ed.show_targets {
		draw_targets(ed)
	}
}

// Records the finished ImGui frame into the window's swapchain pass: upload
// outside any pass, then draw inside one. A nil pass (minimized window) draws
// nothing.
render_imgui :: proc(window: ^gfx.Window) {
	ui.imgui_backend_prepare(gfx.ImGuiCommandBuffer())
	if pass := gfx.BeginImGuiPass(); pass != nil {
		ui.imgui_backend_draw(gfx.ImGuiCommandBuffer(), pass)
		gfx.EndImGuiPass(pass)
	}
}
