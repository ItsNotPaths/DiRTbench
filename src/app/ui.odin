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
import "core:os"
import "core:path/filepath"
import rl "../gfx"
import "../geo"
import "../ui"

// --- actions ----------------------------------------------------------------

// Saves under the (sanitised) name in the buffer, and writes the sanitised name
// back so the field always shows the filename that actually exists on disk.
do_save :: proc(ed: ^Editor) {
	// A stage opened from one of our venues belongs to it. Saving it into
	// maps/ under whatever the name field says would quietly fork the document.
	if ed.open_venue != "" {
		path := venue_road_path(ed.open_venue)
		msg, ok := save_stage_to(ed.spline, path, ed.veg, ed.timing)
		if ok {
			// The markers are the stage, and they live in venue.json. Saving the
			// road without them would drop the start and finish lines.
			msg, ok = venue_markers_save(ed.open_venue, ed.start, ed.finish)
		}
		if ok {
			msg = fmt.tprintf("saved %s road network and stage lines", ed.open_venue)
		}
		set_status(ed, msg, ok)
		return
	}
	name := sanitise_stage_name(stage_name_text(ed))
	set_stage_name(ed, name)
	msg, ok := save_stage(ed.spline, name, ed.veg, ed.timing)
	set_status(ed, msg, ok)
}

// Export what is on screen, so the stage name doubles as the item and map name.
// `rebuild_geometry` first because the terrain rebuild is deferred while a point
// gizmo is dragged: a stale `terrain_field` would export the previous ribbon's
// ground. Nothing is dragging when a menu is open, so this is a no-op in
// practice and a guard against ever calling export from elsewhere.
do_export :: proc(ed: ^Editor, target: ^Export_Target) {
	name := sanitise_stage_name(stage_name_text(ed))
	set_stage_name(ed, name)
	rebuild_geometry(ed)
	msg, ok := export_stage(ed, name, target)
	set_status(ed, msg, ok)
}

do_load :: proc(ed: ^Editor, name: string) {
	msg, ok := load_stage(&ed.spline, name, &ed.veg, &ed.timing)
	if ok {
		set_stage_name(ed, name)
		ed.sel = {} // indices from the old spline mean nothing now
		geo.terrain_invalidate(&ed.terrain) // and so do the lattice's absolute heights
		mark_dirty(ed)
	}
	set_status(ed, msg, ok)
}

do_new :: proc(ed: ^Editor) {
	seed_spline(&ed.spline)
	ed.timing = TIMING_DEFAULTS
	ed.sel = {}
	geo.terrain_invalidate(&ed.terrain)
	set_stage_name(ed, "untitled")
	mark_dirty(ed)
	set_status(ed, "new stage", true)
}

// Regenerating reallocates spline.points, so it must never run while the gizmo
// holds a pointer into that array — hence the gizmo_active guard at each call.
do_generate :: proc(ed: ^Editor, frame_camera: bool) {
	msg, ok := generate_stage(&ed.spline, ed.gen)
	if ok {
		ed.sel = {}
		geo.terrain_invalidate(&ed.terrain)
		mark_dirty(ed)
		if frame_camera {
			frame_spline(&ed.cam, ed.spline)
		}
	}
	set_status(ed, msg, ok)
}

// --- UI ---------------------------------------------------------------------

draw_menubar :: proc(ed: ^Editor) {
	if !ui.igBeginMainMenuBar() {
		return
	}
	defer ui.igEndMainMenuBar()

	if ui.igBeginMenu("File", true) {
		if ed.open_venue != "" && ui.igMenuItem_Bool("Close editor", nil, false, true) {
			ed.quit = true
		}
		if ed.open_venue != "" {
			label: cstring = ed.stage_mode ? "Edit venue geometry" : "Edit stage start/finish"
			if ui.igMenuItem_Bool(label, nil, false, true) {
				ed.stage_mode = !ed.stage_mode
				ed.sel = {}
				set_status(
					ed,
					ed.stage_mode ? "stage mode: S sets the start line, F the finish; the road is read-only" : "venue mode: the road is editable again",
					true,
				)
			}
			ui.igSeparator()
		}
		if ed.open_venue == "" && ui.igMenuItem_Bool("New", nil, false, true) {
			do_new(ed)
		}
		if ui.igMenuItem_Bool("Save", "Ctrl+S", false, len(ed.spline.points) >= 2) {
			do_save(ed)
		}
		if ed.open_venue == "" && ui.igBeginMenu("Load", true) {
			stages := list_stages()
			if len(stages) == 0 {
				ui.igBeginDisabled(true)
				ui.igMenuItem_Bool("(no stages in maps/)", nil, false, true)
				ui.igEndDisabled()
			}
			for name in stages {
				label := fmt.ctprint(name)
				if ui.igMenuItem_Bool(label, nil, name == stage_name_text(ed), true) {
					do_load(ed, name)
				}
			}
			ui.igEndMenu()
		}
		ui.igSeparator()
		if ed.open_venue == "" && ui.igBeginMenu("Export to", len(ed.spline.points) >= 2) {
			for &t in EXPORT_TARGETS {
				label := fmt.ctprint(t.label)
				if ui.igMenuItem_Bool(label, nil, false, true) {
					do_export(ed, &t)
				}
			}
			ui.igEndMenu()
		}
		if ed.open_venue == "" && ui.igMenuItem_Bool("Export targets...", nil, ed.show_targets, true) {
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
			install_scan_rescan(&ed.install)
			set_status(ed, install_scan_status_text(&ed.install), ed.install.found)
		}
		ui.igEndMenu()
	}
	if ui.igBeginMenu("View", true) {
		if ui.igMenuItem_Bool("Stage generator", nil, ed.show_gen, true) {
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
draw_status_text :: proc(ed: ^Editor) {
	msg, shown := status_text(ed)
	if !shown {
		return
	}
	green := ui.Im_Vec4{0.45, 0.85, 0.5, 1}
	red := ui.Im_Vec4{1.0, 0.45, 0.4, 1}
	ui.im_text_colored(ed.status_ok ? green : red, msg)
}

// A floating, closable panel: `igBegin` with a p_open gives it an X, and the
// menubar toggle brings it back. Not drawn at all while closed.
draw_generator :: proc(ed: ^Editor) {
	if !ed.show_gen {
		return
	}
	ui.igSetNextWindowPos({330, 34}, .FirstUseEver, {0, 0})
	ui.igSetNextWindowSize({340, 0}, .FirstUseEver)
	if !ui.igBegin("Stage generator", &ed.show_gen, ui.IM_WINDOW_ALWAYS_AUTO_RESIZE) {
		ui.igEnd() // still required when collapsed
		return
	}
	defer ui.igEnd()

	ui.im_text("Same seed and settings always give the same stage.")
	ui.igSpacing()

	// `changed` must not short-circuit: every widget has to be drawn every
	// frame, so collect the results rather than folding with ||=.
	changed := false
	g := &ed.gen

	if ui.igInputInt("seed", &g.seed, 1, 16, ui.IM_INPUT_TEXT_NONE) {changed = true}
	ui.im_same_line()
	if ui.im_button("Randomise") {
		g.seed = rl.GetRandomValue(0, 999999)
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
		ed.gen = GEN_DEFAULTS
		changed = true
	}
	ui.im_same_line()
	ui.igCheckbox("live", &ed.gen_live)

	// Live regeneration is what makes the sliders legible, but it rebuilds the
	// point array; doing that mid-drag would pull the array out from under the
	// gizmo's pointer.
	if changed && ed.gen_live && !ed.gizmo_active {
		do_generate(ed, false)
	}
}

draw_inspector :: proc(ed: ^Editor) {
	ui.igSetNextWindowPos({12, 34}, .FirstUseEver, {0, 0})
	ui.igSetNextWindowSize({300, 0}, .FirstUseEver)
	if !ui.igBegin("Inspector", nil, ui.IM_WINDOW_ALWAYS_AUTO_RESIZE) {
		ui.igEnd()
		return
	}
	defer ui.igEnd()

	ui.igSeparatorText(ed.open_venue != "" ? "Venue road network" : "Stage")
	if ed.open_venue != "" {
		ui.im_text(fmt.ctprint(ed.open_venue))
	} else {
		ui.igInputText("name", raw_data(ed.stage_name[:]), len(ed.stage_name), ui.IM_INPUT_TEXT_CHARS_NO_BLANK, nil, nil)
	}
	ui.igBeginDisabled(len(ed.spline.points) < 2)
	if ui.im_button("Save") {
		do_save(ed)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	ui.igBeginDisabled(len(ed.spline.points) < 2 || !geo.is_linear(ed.spline))
	if ui.im_button("Reverse") {
		geo.reverse_spline(&ed.spline)
		ed.sel = {}
		mark_dirty(ed)
		set_status(ed, "reversed driving direction", true)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	if ui.im_button("Generate...") {
		ed.show_gen = true
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d points", len(ed.spline.points)))

	draw_status_text(ed)

	ui.igSeparatorText("Gizmo")
	if ui.igRadioButton_Bool("Move (1)", ed.gizmo_mode == .Move) {
		ed.gizmo_mode = .Move
	}
	ui.im_same_line()
	if ui.igRadioButton_Bool("Rotate (2)", ed.gizmo_mode == .Rotate) {
		ed.gizmo_mode = .Rotate
	}

	draw_terrain_section(ed)
	draw_point_section(ed)
	draw_timing_section(ed)
	draw_pace_section(ed)
	draw_veg_section(ed)

	ui.igSeparatorText("Controls")
	ui.im_text("LMB select point or terrain node")
	ui.im_text("Shift+drag gizmo extrudes a point")
	ui.im_text("RMB insert on road / append on ground")
	ui.im_text("DEL remove")
	ui.im_text("Alt+LMB pan, Alt+RMB orbit, wheel zoom")
}

draw_timing_section :: proc(ed:^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Timing gates",ui.IM_TREE_NODE_DEFAULT_OPEN) { return }
	ui.igSliderInt("checkpoint density",&ed.timing.checkpoint_count,0,20,"%d",ui.IM_SLIDER_NONE)
	ui.igSliderFloat("start/end buffer",&ed.timing.buffer_m,0,500,"%.0f m",ui.IM_SLIDER_NONE)
}

// Global mesh settings. Every control here changes geometry, so each marks the
// caches dirty; the rebuild happens once, at the top of the next frame.
draw_terrain_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Terrain", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	if ui.igSliderInt("topo resolution", &ed.topo, TOPO_MIN, TOPO_MAX, "%d /segment", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	// Global baseline for the road's vertical roughness (and the cliff jitter). Each
	// control point can offset this locally — see the Selected point section. The
	// absolute displacement is hard-capped at 7 in (ROUGH_MAX_M); this only scales
	// up to that.
	if ui.igSliderFloat("roughness", &ed.roughness, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.im_button(ed.wireframe ? "Wireframe: on" : "Wireframe: off") {
		ed.wireframe = !ed.wireframe
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d tris", ed.road.tris + ed.terrain_mesh.tris))

	draw_terrain_mesh_section(ed)
}

// The out-of-stage mesh. Rows and columns resize the lattice, which discards
// the sculpt — the nodes are indexed rather than positioned, so there is no
// meaning-preserving way to reinterpret them at another resolution.
draw_terrain_mesh_section :: proc(ed: ^Editor) {
	t := &ed.terrain
	if ui.igCheckbox("terrain", &t.enabled) {
		if !t.enabled && ed.sel.kind == .Node {
			ed.sel = {} // its handle just went away
		}
		mark_terrain_dirty(ed)
	}
	if !t.enabled {
		return
	}
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d tris", ed.terrain_mesh.tris))

	if ui.igSliderFloat("reach", &t.reach_m, 8, geo.TERRAIN_REACH_MAX, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed)
	}
	// How far the road pulls the ground with it before the lattice takes over.
	// Must stay inside the reach, or the seam never resolves to the lattice at
	// all. Too narrow and the terrain terraces rather than sloping.
	if ui.igSliderFloat("blend", &t.blend_m, 1, max(t.reach_m, 2), "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed)
	}
	t.blend_m = min(t.blend_m, t.reach_m)
	// Spacing of the interior points the ground is triangulated from.
	if ui.igSliderFloat("cell", &t.cell_m, 1, 32, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_terrain_dirty(ed)
	}

	// These reseed the lattice, which the node gizmo is writing into. Same guard,
	// and same reason, as the generator's `live` checkbox.
	ui.igBeginDisabled(ed.gizmo_active)
	defer ui.igEndDisabled()

	rows := c.int(t.rows)
	cols := c.int(t.cols)
	if ui.igSliderInt("nodes along", &rows, 2, geo.TERRAIN_ROWS_MAX, "%d", ui.IM_SLIDER_NONE) {
		t.rows = int(rows)
		geo.terrain_invalidate(t)
		mark_terrain_dirty(ed)
	}
	if ui.igSliderInt("nodes across", &cols, 1, geo.TERRAIN_COLS_MAX, "%d", ui.IM_SLIDER_NONE) {
		t.cols = int(cols)
		geo.terrain_invalidate(t)
		mark_terrain_dirty(ed)
	}

	if ui.im_button("Flatten to verge") {
		geo.terrain_invalidate(t)
		mark_terrain_dirty(ed)
	}
}

// Everything that belongs to the one selected control point.
draw_point_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Selected point", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	sel := selected_point(ed)
	if sel < 0 {
		if ed.sel.kind == .Node {
			ui.im_text(fmt.ctprintf("terrain node selected (%s side)", ed.sel.side == 0 ? "left" : "right"))
			ui.im_text("drag its vertical handle to sculpt")
		} else {
			ui.im_text("no point selected")
		}
		return
	}
	p := &ed.spline.points[sel]
	ui.im_text(fmt.ctprintf("point %d of %d", sel, len(ed.spline.points)))

	if ui.igDragFloat3("position", cast(^[3]f32)&p.xform.translation, 0.1, 0, 0, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.igSliderFloat("width", &p.width, 2, 32, "%.1f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	// Per-node roughness offset, added to the global slider (both clamped to [0,1]
	// where the road is displaced). Negative smooths this stretch below the stage
	// baseline; positive roughens it. The 7-inch cap still applies regardless.
	if ui.igSliderFloat("roughness offset", &p.roughness, -1, 1, "%+.2f", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}

	ui.igSeparatorText("Cliffs")
	if ui.igSliderFloat("left height", &p.cliff_l, 0, geo.CLIFF_HEIGHT_MAX, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.igSliderFloat("left span", &p.span_l, 0, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.igSliderFloat("right height", &p.cliff_r, 0, geo.CLIFF_HEIGHT_MAX, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.igSliderFloat("right span", &p.span_r, 0, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	// Taper and angle are shared by both sides, like the shape of the cliff
	// rather than the size of it.
	if ui.igSliderFloat("taper", &p.cliff_taper, 0, 100, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	if ui.igSliderFloat("angle", &p.cliff_angle, geo.CLIFF_ANGLE_MIN, geo.CLIFF_ANGLE_MAX, "%.1f deg", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}

	ui.igSpacing()
	if ui.im_button("Delete point") {
		geo.remove_point(&ed.spline, sel)
		ed.sel = {}
		mark_dirty(ed)
	}
}

// Pace notes derived from the spline. The sliders are the placement "numbers";
// changing any dirties the road cache, which recomputes the notes.
draw_pace_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Pace notes", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	pp := &ed.pace
	// Corner sensitivity: the largest radius still called a corner. Bigger = more
	// gentle bends get a number.
	if ui.igSliderFloat("call radius", &pp.r_on, 40, 400, "%.0f m", ui.IM_SLIDER_NONE) {
		pp.r_off = max(pp.r_off, pp.r_on + 20)
		mark_dirty(ed)
	}
	// How far ahead of the feature the call fires.
	if ui.igSliderFloat("lead", &pp.lead_m, 0, 120, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	// Straight length that turns "into" into a spoken distance.
	if ui.igSliderFloat("into gap", &pp.into_m, 4, 120, "%.0f m", ui.IM_SLIDER_NONE) {
		mark_dirty(ed)
	}
	ui.igSpacing()
	pace_ready := len(ed.clips) > 0
	ui.igBeginDisabled(!pace_ready || len(ed.notes) == 0)
	if ui.im_button(ed.previewing ? "Stop ride" : "Preview ride") {
		preview_toggle(ed)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	// Direct playback test: bypasses the ride/queue entirely, so a silent result
	// here points at the audio device, not our sequencing.
	if ui.im_button("Test clip") {
		if snd, ok := ed.clips["hairpin-left"]; ok {
			rl.PlaySound(snd)
		}
	}
	ui.igSliderFloat("speed", &ed.preview_speed, 5, 80, "%.0f m/s", ui.IM_SLIDER_NONE)
	ui.im_text(fmt.ctprintf("audio device: %s", rl.IsAudioDeviceReady() ? "ready" : "NOT ready"))
	if !pace_ready {
		ui.im_text("(no clips found in pacenotes/)")
	} else if ed.previewing {
		nextm := ed.preview_next < len(ed.notes) ? ed.notes[ed.preview_next].station - ed.preview_s : 0
		ui.im_text(fmt.ctprintf("riding %.0f m  (next call in %.0f m)", ed.preview_s, max(0, nextm)))
	} else {
		ui.im_text(fmt.ctprintf("%d clips loaded", len(ed.clips)))
	}
	ui.igSpacing()

	ui.im_text(fmt.ctprintf("%d notes", len(ed.notes)))

	// Auto-resize inspector, so cap the list; the preview is where you live with
	// the full stream anyway.
	PACE_LIST_MAX :: 30
	for nt, i in ed.notes {
		if i >= PACE_LIST_MAX {
			ui.im_text(fmt.ctprintf("... +%d more", len(ed.notes) - PACE_LIST_MAX))
			break
		}
		ui.im_text(fmt.ctprintf("%6.0fm  %s", nt.station, geo.pace_note_text(nt)))
	}
}

// Vegetation scatter. Every knob flags the cache dirty; veg_refresh regenerates it
// (and the viewport shapes) at the top of the next frame. The scatter is saved with
// the stage and handed to the export target, so nothing here touches geometry.
draw_veg_section :: proc(ed: ^Editor) {
	if !ui.igCollapsingHeader_TreeNodeFlags("Vegetation", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	v := &ed.veg
	if ui.igCheckbox("vegetation", &v.enabled) {
		ed.veg_dirty = true
	}
	if !v.enabled {
		return
	}

	// Preset: which stock species pool the scatter draws from.
	for p in geo.Veg_Preset {
		if ui.igRadioButton_Bool(geo.VEG_PRESET_NAMES[p], v.preset == p) {
			v.preset = p
			ed.veg_dirty = true
		}
		if p != max(geo.Veg_Preset) {
			ui.im_same_line()
		}
	}

	if ui.igSliderFloat("density", &v.density, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {
		ed.veg_dirty = true
	}
	// "Prioritise near the road, only slightly": at 0 the scatter is even; at 1 the
	// far tree line is thinned by up to that fraction. The default is deliberately low.
	if ui.igSliderFloat("road bias", &v.road_bias, 0, 1, "%.2f", ui.IM_SLIDER_NONE) {
		ed.veg_dirty = true
	}
	if ui.igSliderInt("seed", &v.seed, 1, 999, "%d", ui.IM_SLIDER_NONE) {
		ed.veg_dirty = true
	}

	ui.igSpacing()
	ui.im_text(fmt.ctprintf("%d trees", len(ed.veg_cache)))
	if !ed.terrain.enabled {
		ui.im_text("(terrain off: trees ride the road edge)")
	}
}

// One row per target: what it does and where it writes. Also the place the
// debug detour is turned on, and the one place `dirtbench.conf` is named, so
// someone who has not written one can see what they are missing.
draw_targets :: proc(ed: ^Editor) {
	if !ed.show_targets {
		return
	}
	ui.igSetNextWindowPos({330, 34}, .FirstUseEver, {0, 0})
	ui.igSetNextWindowSize({430, 0}, .FirstUseEver)
	if !ui.igBegin("Export targets", &ed.show_targets, ui.IM_WINDOW_ALWAYS_AUTO_RESIZE) {
		ui.igEnd()
		return
	}
	defer ui.igEnd()

	ui.igCheckbox("Write to out/ instead of the game", &ed.debug_export)
	ui.igSpacing()

	for &t in EXPORT_TARGETS {
		ui.igSeparatorText(fmt.ctprint(t.label))
		ui.im_text(fmt.ctprint(t.blurb))
		dest, installing, dest_msg, dest_ok := export_dest(ed, stage_name_text(ed), &t)
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

// Records the finished ImGui frame into the window's swapchain pass: upload
// outside any pass, then draw inside one. A nil pass (minimized window) draws
// nothing.
render_imgui :: proc(window: ^rl.Window) {
	ui.imgui_backend_prepare(rl.ImGuiCommandBuffer())
	if pass := rl.BeginImGuiPass(); pass != nil {
		ui.imgui_backend_draw(rl.ImGuiCommandBuffer(), pass)
		rl.EndImGuiPass(pass)
	}
}
