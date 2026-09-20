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

// One hue per inspector section, so a panel is known by its colour before its
// label is read. Terrain keeps ImGui's own blue.
VEG_COL :: ui.Im_Vec4{0.30, 0.72, 0.36, 1.0}
GUARD_COL :: ui.Im_Vec4{0.62, 0.42, 0.24, 1.0}
OBJECT_COL :: ui.Im_Vec4{0.86, 0.29, 0.29, 1.0}
ORNAMENT_COL :: ui.Im_Vec4{0.82, 0.66, 0.16, 1.0}
TERRAIN_COL :: ui.Im_Vec4{0.26, 0.59, 0.98, 1.0}

// The generator's own two sections. Its third is Side guards, which borrows
// GUARD_COL: the same hue as the sidebar panel that edits what it lays down.
SHAPE_COL :: ui.Im_Vec4{0.64, 0.45, 0.90, 1.0}
ROAD_COL :: ui.Im_Vec4{0.22, 0.72, 0.70, 1.0}

// --- actions ----------------------------------------------------------------

// The document goes home to its venue file. The road and the markers that make
// the stages go down together, so neither can land without the other.
do_save :: proc(ed: ^Editor) {
	msg, ok := save_road(ed.doc, venue_path(sanitise_venue_name(ed.doc.venue_name)))
	if ok {
		msg = fmt.tprintf("saved %s", ed.doc.venue_name)
		recovery_doc_saved(recovery_root(), ed.doc)
		// The project manager holds its own copy of the document, and both
		// deploy and every reopen read that copy rather than the file. It has
		// to be told the file moved under it, or a start line saved here is
		// invisible to both.
		ed.app.screen.reload_pending = true
	}
	set_status(&ed.status, msg, ok)
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
		ui.igSeparator()
		if ui.igMenuItem_Bool("Export targets...", nil, ed.show_targets, true) {
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
		if ed.kind == .Venue && ui.igMenuItem_Bool("Thumbnail", nil, ed.show_thumb, true) {
			ed.show_thumb = !ed.show_thumb
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

	if ui.im_section_begin("Shape", SHAPE_COL) {
		if ui.igSliderFloat("length", &g.length_m, 400, 8000, "%.0f m", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("curviness", &g.curviness, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("hairpins", &g.hairpins, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("hilliness", &g.hilliness, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("banking", &g.bank, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		ui.im_section_end()
	}

	if ui.im_section_begin("Road", ROAD_COL) {
		if ui.igSliderFloat("min width", &g.width_min, 3, 20, "%.1f m", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("max width", &g.width_max, 3, 20, "%.1f m", ui.IM_SLIDER_NONE) {changed = true}
		// Sliders can cross; keep the pair ordered rather than letting the
		// generator emit a negative width range.
		if g.width_max < g.width_min {
			g.width_max = g.width_min
		}
		if ui.igSliderFloat("point spacing", &g.spacing_m, 8, 60, "%.0f m", ui.IM_SLIDER_NONE) {changed = true}
		ui.im_section_end()
	}

	if ui.im_section_begin("Side guards", GUARD_COL) {
		if ui.igSliderFloat("cliff", &g.guard_cliff, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("bank", &g.guard_bank, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		if ui.igSliderFloat("gutter", &g.guard_gutter, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {changed = true}
		draw_guard_share_text(g^)
		ui.im_section_end()
	}

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

// What the three weights add up to on the road. They are shares of one edge,
// so a total over 1 is scaled down rather than clipped, and the slider readings
// stop matching what lands.
draw_guard_share_text :: proc(g: Gen_Params) {
	shares := gen_guard_shares(g)
	bare := f32(1)
	for w in shares {
		bare -= w
	}
	if bare > 0.005 {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%.0f%% of each edge is bare verge", bare * 100))
		return
	}
	ui.im_text_colored(DIM_COL, fmt.ctprintf(
		"every edge covered: %.0f/%.0f/%.0f%% cliff/bank/gutter",
		shares[.Cliff] * 100, shares[.Bank] * 100, shares[.Gutter] * 100,
	))
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
			fmt.ctprintf("%s is no longer a stage of %s", ed.stage_id, ed.doc.venue_name),
		)
		ui.im_text("close this window")
		return
	}

	ui.igSeparatorText(fmt.ctprint(route.name))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("%s / %s", ed.doc.venue_name, route.id))
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
	draw_setup_section(ed, route)

	// The gates are drawn on this stage's ribbon, but their numbers are the
	// venue's, so a change here moves every stage's gates.
	ui.im_text_colored(DIM_COL, "gates below are venue-wide")
	draw_timing_section(ed)
	draw_pace_section(ed)

	ui.igSeparatorText("Controls")
	ui.im_text("point at the road and press S for the start line")
	ui.im_text("F sets the finish, P drops a pin, U the setup pin.")
	ui.im_text("The road is read-only here.")
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

// Where the setup screen stands. Without one the game puts it on the start
// grid, which is what every stage did before there was a pin for it.
draw_setup_section :: proc(ed: ^Editor, route: ^Venue_Route) {
	ui.igSeparatorText("Setup pin")
	if !geo.marker_valid(ed.doc.spline, route.setup) {
		ui.im_text_colored(DIM_COL, "none — the setup screen sits on the start grid")
		return
	}
	ui.im_text(fmt.ctprintf("edge %d-%d", route.setup.from, route.setup.to))
	ui.im_same_line()
	if ui.im_button("Remove###setup") {
		route.setup = {from = -1, to = -1}
		mark_edited(ed.doc)
		set_status(&ed.status, "setup pin removed", true)
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
	ui.igSeparatorText("Venue road network")
	ui.im_text(fmt.ctprint(ed.doc.venue_name))
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
	// Window state, not document state: how a brush falls off is how this window
	// is being driven, and nothing in the venue remembers it.
	ui.igSliderFloat(
		"road brush falloff", &ed.road_brush_taper, 0, 1, "%.2f", ui.IM_SLIDER_NONE,
	)
	ui.im_text_colored(DIM_COL, "1 ramps the whole reach, 0 moves it as a block")

	draw_guards_section(ed)
	draw_terrain_section(ed)
	draw_veg_section(ed)
	draw_props_sections(ed)

	ui.igSeparatorText("Controls")
	ui.im_text("LMB select point or terrain node")
	ui.im_text("Terrain node: RMB+LMB drag sizes the brush, release RMB to raise/lower")
	ui.im_text("Road point: RMB+LMB drag sizes a selection, then drag the gizmo to move it all")
	ui.im_text("  the falloff above shares the move out; clicking away drops the selection")
	ui.im_text("Floors: draw one from the Terrain panel; Del removes a corner")
	ui.im_text("Props: pick one in the Objects or Ornaments panel, B places, Del removes")
	ui.im_text("Shift+drag gizmo extrudes a point")
	ui.im_text("RMB insert on road / append on ground")
	ui.im_text("DEL remove")
	ui.im_text("Alt+LMB pan, Alt+RMB orbit, wheel zoom")
}

// --- side guards ---------------------------------------------------------------

GUARD_KIND_LABEL := [geo.Guard_Kind]cstring {
	.Cliff  = "Cliff",
	.Bank   = "Bank",
	.Gutter = "Gutter",
}

// How many guards run past the selected control point. The per-point block uses
// it to say where their sliders went.
guards_here :: proc(ed: ^Editor, sel: int) -> (n: int) {
	for g in ed.doc.spline.guards {
		if geo.guard_reaches(ed.doc.spline, g, sel) { n += 1 }
	}
	return
}

// Cliffs, snow banks and gutters: every guard that runs past the selected
// control point, and one slider set each.
//
// The point is that these are **not** per-point sliders. A guard covering five
// nodes shows the same numbers at all five, and moving one moves the whole run.
// Its own panel rather than a block under the selection, because a node inside
// three guards carries far more rows than a selection footer can hold.
draw_guards_section :: proc(ed: ^Editor) {
	if !ui.im_section_begin("Side guards", GUARD_COL) {
		return
	}
	defer ui.im_section_end()
	sp := &ed.doc.spline
	sel := selected_point(ed)
	ui.im_text_colored(DIM_COL, fmt.ctprintf("%d in this venue", len(sp.guards)))
	if sel < 0 {
		ui.im_text_colored(DIM_COL, "select a road point to see the guards along it")
		return
	}

	// The kind and side the Add button would use. Radio rows rather than a
	// combo: the bindings have no combo, and six choices fit on two lines.
	for kind in geo.Guard_Kind {
		if ui.igRadioButton_Bool(GUARD_KIND_LABEL[kind], ed.guard_kind == kind) {
			ed.guard_kind = kind
		}
		ui.im_same_line()
	}
	if ui.im_button(ed.guard_side == 0 ? "on the left" : "on the right") {
		ed.guard_side = 1 - ed.guard_side
	}
	if ui.im_button(fmt.ctprintf("Add %s at point %d", GUARD_KIND_LABEL[ed.guard_kind], sel)) {
		geo.guard_add(sp, geo.guard_make(ed.guard_kind, ed.guard_side, sel))
		mark_dirty(ed.doc)
	}

	shown := 0
	// By index, because the sliders write through: a guard removed mid-list
	// would shift everything after it, so the delete is taken on the way out.
	remove := -1
	for i in 0 ..< len(sp.guards) {
		if !geo.guard_reaches(sp^, sp.guards[i], sel) {
			continue
		}
		shown += 1
		if draw_guard(ed, i, sel) {
			remove = i
		}
	}
	if remove >= 0 {
		geo.guard_remove(sp, remove)
		mark_dirty(ed.doc)
	}
	if shown == 0 {
		ui.im_text_colored(DIM_COL, "no guard reaches this point")
	}
}

// One guard's slider set. Returns true when its Delete was pressed — the caller
// takes the guard out, because removing it here would invalidate the loop.
//
// Every label carries `##<id>` so two guards on one point do not share a widget
// identity. The id is the guard's own, so a slider keeps its drag across a
// delete somewhere else in the list.
draw_guard :: proc(ed: ^Editor, idx, sel: int) -> (remove: bool) {
	sp := &ed.doc.spline
	g := &sp.guards[idx]
	tag := g.id
	ui.igSeparatorText(fmt.ctprintf(
		"%s, %s side", GUARD_KIND_LABEL[g.kind], g.side == 0 ? "left" : "right",
	))
	if g.at == sel {
		ui.im_text_colored(DIM_COL, "anchored here")
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("anchored at point %d", g.at))
		ui.im_same_line()
		// Re-centring is how a run is shaped end to end: drag the span out from
		// whichever node the middle of it should sit on.
		if ui.im_button(fmt.ctprintf("Move here##%d", tag)) {
			g.at = sel
			mark_dirty(ed.doc)
		}
	}

	size_max, size_label := f32(geo.CLIFF_HEIGHT_MAX), cstring("height")
	switch g.kind {
	case .Cliff:
		size_max, size_label = geo.CLIFF_HEIGHT_MAX, "height"
	case .Bank:
		size_max, size_label = geo.BANK_HEIGHT_MAX, "height"
	case .Gutter:
		size_max, size_label = geo.GUTTER_DEPTH_MAX, "depth"
	}
	if ui.igSliderFloat(
		fmt.ctprintf("%s##%d", size_label, tag), &g.size, 0, size_max, "%.2f m", ui.IM_SLIDER_NONE,
	) {
		mark_dirty(ed.doc)
	}
	// Span is the whole run, tapers included, measured along the road from the
	// anchor. Every point it reaches shows this same slider.
	if ui.igSliderFloat(
		fmt.ctprintf("span##%d", tag), &g.span, 0, 400, "%.0f m", ui.IM_SLIDER_NONE,
	) {
		mark_dirty(ed.doc)
	}
	if ui.igSliderFloat(
		fmt.ctprintf("taper##%d", tag), &g.taper, 0, 100, "%.0f m", ui.IM_SLIDER_NONE,
	) {
		mark_dirty(ed.doc)
	}
	#partial switch g.kind {
	case .Bank, .Gutter:
		// How far out it reaches. Floored at its own size where the geometry is
		// built, so neither can come out a vertical wall at the road edge.
		w_max := g.kind == .Bank ? f32(geo.BANK_WIDTH_MAX) : f32(geo.GUTTER_WIDTH_MAX)
		if ui.igSliderFloat(
			fmt.ctprintf("width##%d", tag), &g.width, 0, w_max, "%.1f m", ui.IM_SLIDER_NONE,
		) {
			mark_dirty(ed.doc)
		}
	case .Cliff:
		if ui.igSliderFloat(
			fmt.ctprintf("angle##%d", tag), &g.angle,
			geo.CLIFF_ANGLE_MIN, geo.CLIFF_ANGLE_MAX, "%.1f deg", ui.IM_SLIDER_NONE,
		) {
			mark_dirty(ed.doc)
		}
	}
	// The face, not the road. Held at zero a cliff is a smooth ramp, which is
	// what every stage looked like before this existed. A gutter has none: it is
	// a cut drain, not rock.
	if g.kind != .Gutter {
		if ui.igSliderFloat(
			fmt.ctprintf("roughness##%d", tag), &g.rough, 0, 1, "%.2f", ui.IM_SLIDER_NONE,
		) {
			mark_dirty(ed.doc)
		}
	}
	return ui.im_button(fmt.ctprintf("Delete guard##%d", tag))
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
	if !ui.im_section_begin("Terrain", TERRAIN_COL) {
		return
	}
	defer ui.im_section_end()
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
	// Lifts the ground away from the road, on top of the sculpt rather than in
	// place of it: the nodes keep whatever the user dragged them to.
	if ui.igSliderFloat("warp up", &t.warp_m, 0, 120, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed.doc)
	}
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

// What a pad does besides cutting the ground (geo.Floor_Opts). One widget for
// the pad being drawn and the pad selected, so the args you set before drawing
// are the ones you change afterwards, under the same names.
draw_floor_opts :: proc(o: ^geo.Floor_Opts) -> (changed: bool) {
	if ui.igCheckbox("no trees", &o.no_trees) {
		changed = true
	}
	if ui.igCheckbox("no ground cover", &o.no_cover) {
		changed = true
	}
	return
}

// Drawing a floor, and the count of them. What one selected floor is worth
// tweaking lives in the selection block.
draw_floor_section :: proc(ed: ^Editor) {
	t := &ed.doc.terrain
	ui.igSeparatorText("Floors")
	if ed.floor_drawing {
		ui.im_text(fmt.ctprintf("%d corners placed", len(ed.floor_draw)))
		ui.im_text("click the ground for each corner")
		ui.im_text("click the first corner to close it, Esc drops it")
		draw_floor_opts(&ed.floor_opts)
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
	draw_floor_opts(&ed.floor_opts)
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
	.Point      = 8,
	.Node       = 3,
	.Floor      = 8,
	.Floor_Vert = 8,
	.Prop       = 7,
}

// Never more than half the dock: an eight-row point on a short window would
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
	if draw_floor_opts(&f.opts) {
		mark_terrain_dirty(ed.doc)
	}
	ui.im_text_colored(DIM_COL, "RMB an edge adds a corner, Del removes")
	if ui.im_button("Delete floor") {
		ed.sel = {kind = .Floor, idx = fi}
		floor_delete(ed)
	}
}

// What the road is made of from this point forward.
//
// Three buttons rather than a slider, because a surface is not a quantity, and
// **inherit** is the useful default: a hint carries into every node downstream
// of it, so most points should state nothing and one edit should move a whole
// run. That is also why the resolved surface is spelled out under the buttons —
// on an inheriting point there is otherwise nothing on screen saying which
// surface you are actually looking at.
SURFACE_LABEL := [geo.Road_Surface]cstring {
	.None  = "inherit",
	.Loose = "loose",
	.Paved = "paved",
}

draw_surface_control :: proc(ed: ^Editor, sel: int) {
	p := &ed.doc.spline.points[sel]
	ui.im_text("surface")
	for surface in geo.Road_Surface {
		ui.igSameLine(0, -1)
		if ui.igRadioButton_Bool(SURFACE_LABEL[surface], p.surface == surface) && p.surface != surface {
			p.surface = surface
			mark_dirty(ed.doc)
		}
	}
	if p.surface != .None {
		ui.im_text_colored(DIM_COL, "and every point downstream, until one says otherwise")
		return
	}
	resolved := geo.point_surfaces(ed.doc.spline, context.temp_allocator)
	if sel < len(resolved) {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("reads as %s from upstream", SURFACE_LABEL[resolved[sel]]))
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
	// The road surface only, and the cliffs have their own below. A per-node
	// offset from the global slider (both clamped to [0,1] where the road is
	// displaced): negative smooths this stretch below the stage baseline,
	// positive roughens it. The 7-inch cap still applies regardless.
	if ui.igSliderFloat("road roughness", &p.roughness, -1, 1, "%+.2f", ui.IM_SLIDER_NONE) {
		mark_dirty(ed.doc)
	}
	draw_surface_control(ed, sel)

	// Cliffs, banks and gutters are not here. They are their own objects, shared
	// by every point they run past, and they have their own panel — see
	// draw_guards_section.
	if n := guards_here(ed, sel); n > 0 {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%d side guard%s here, in the Side guards panel", n, n == 1 ? "" : "s"))
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
	if !ui.im_section_begin("Vegetation", VEG_COL) {
		return
	}
	defer ui.im_section_end()
	v := &ed.doc.veg
	if ui.igCheckbox("vegetation", &v.enabled) {
		mark_veg_dirty(ed.doc)
	}
	// Above the early return on purpose. The wall of cards hides the void past
	// the terrain, which a stage with no trees at all still has; the near tier
	// needs the scatter, and takes care of that itself.
	if ui.igCheckbox("distant billboards", &v.billboards) {
		// The card sizes come off the venue's own sheets, so read the art now
		// rather than previewing the nominal pair until a browser is opened.
		if v.billboards && ed.doc.venue_art.state == .Unloaded {
			venue_art_load(ed.doc)
		}
		mark_veg_dirty(ed.doc)
	}
	if v.billboards {
		near := 0
		for card in ed.doc.card_cache {
			if card.tier == .Near {
				near += 1
			}
		}
		ui.im_text(fmt.ctprintf(
			"%d wall cards over %.0f m, %d tree cards",
			len(ed.doc.card_cache) - near, geo.BILLBOARD_WALL_M, near,
		))
		if ed.doc.venue_art.state != .Ready {
			ui.im_text_colored(DIM_COL, "sized off nominal cards until the venue's art is read")
		}
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

	for &t in EXPORT_TARGETS {
		ui.igSeparatorText(fmt.ctprint(t.label))
		ui.im_text(fmt.ctprint(t.blurb))
		dest, installing, dest_msg, dest_ok := export_dest(ed.doc, ed.stage_id, &t)
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
	if !ed.show_gen && !ed.show_targets && !ed.show_thumb {
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
	if ed.show_thumb {
		draw_thumbnail_panel(ed)
	}
	if ed.show_targets {
		draw_targets(ed)
	}
}

// How this venue's picture is framed. The framing is the viewport's, so there
// is nothing here to aim with: move the camera the way the camera is always
// moved, and press the button.
//
// What is saved is where the camera stood and which way it faced. No image,
// because the picture is rendered from this when the venue is uploaded and can
// then never be out of date with the road.
draw_thumbnail_panel :: proc(ed: ^Editor) {
	sidebar_section("Thumbnail", &ed.show_thumb)

	ui.im_text("The picture the site shows for this venue.")
	shot := &ed.doc.shot
	if shot.set {
		ui.im_text_colored(
			DIM_COL,
			fmt.ctprintf("Saved from %.0f, %.0f, %.0f", shot.pos[0], shot.pos[1], shot.pos[2]),
		)
	} else {
		ui.im_text_colored(DIM_COL, "No view saved. The whole road gets framed from above.")
	}
	ui.igSpacing()

	// The thumbnail is square and the viewport is not, so this is measured
	// against the picture that will be taken rather than against what is on
	// screen. A view with none of the road in it cannot be saved: the point of
	// a thumbnail is to show the venue.
	cam := to_camera3d(ed.cam)
	framed := thumbnail_framed(ed.doc, cam)
	if framed < THUMB_MIN_FRAMED {
		ui.im_text_colored(WARN_COL, "The road is not in this view.")
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%.0f%% of the road is in frame.", framed * 100))
	}

	ui.igBeginDisabled(framed < THUMB_MIN_FRAMED)
	if ui.im_button("Use this view") {
		shot^ = {set = true, pos = cam.position, yaw = ed.cam.yaw, pitch = ed.cam.pitch}
		mark_edited(ed.doc)
		set_status(&ed.status, "thumbnail view saved; save the venue to keep it", true)
	}
	ui.igEndDisabled()
	if shot.set {
		ui.im_same_line()
		if ui.im_button("Clear") {
			shot^ = {}
			mark_edited(ed.doc)
			set_status(&ed.status, "thumbnail view cleared", true)
		}
	}
	ui.igSpacing()
	ui.im_text_colored(DIM_COL, "Uploading is in the project manager.")
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
