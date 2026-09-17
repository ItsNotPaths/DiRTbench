package main

// The venue screen. dirtbench boots here, not into the editor: a road with no
// venue around it is what produced every runtime failure so far, so picking the
// world comes before drawing in it.
//
// The list is the union of what the game registers and what `venues/` holds:
//
//   vanilla   greyed, not selectable. Stock content is read-only and there is no
//             code path here that writes into one.
//   yours     one of ours under `venues/`, openable in the editor.
//   orphan    a directory nobody registered, or a registration with no files.
//             Greyed and flagged. A stock install has five of them.
//
// Nothing on this screen touches the game. Deploying a venue into it is a
// separate, explicit step that does not exist yet; see docs/venue-projects.md.

import "core:fmt"
import "core:os"
import "core:strings"
import d3 "../d3"
import "../ui"
import rl "../gfx"

DIM_COL :: ui.Im_Vec4{0.62, 0.62, 0.66, 1.0}
WARN_COL :: ui.Im_Vec4{0.90, 0.72, 0.38, 1.0}
MINE_COL :: ui.Im_Vec4{0.58, 0.82, 0.62, 1.0}

Venue_Editor_Process :: struct {
	venue_id: string,
	process:  os.Process,
}

// What the screen is doing. The new-venue form is modal in spirit: while it is
// up, the list is still drawn but nothing else is actionable.
Venues_Screen :: struct {
	venues:       []Venue,
	adding:       bool,
	name_buf:     [64]u8, // ImGui edits these in place, so they are fixed buffers
	display_buf:  [64]u8,
	base_venue:   int, // index into install.venues, -1 for none picked
	base_route:   int,
	error:        string, // why the last create was refused
	deploy_ready: string, // venue whose read-only preflight was just shown
	delete_ready: string, // second click confirms project deletion
	editors:      [dynamic]Venue_Editor_Process,
}

venues_screen_init :: proc(ps: ^Venues_Screen) {
	ps.base_venue, ps.base_route = -1, -1
	venues_screen_reload(ps)
}

venues_screen_delete :: proc(ps: ^Venues_Screen) {
	venues_free(ps.venues)
	delete(ps.error)
	delete(ps.deploy_ready)
	delete(ps.delete_ready)
	for editor in ps.editors {
		delete(editor.venue_id)
	}
	delete(ps.editors)
	ps^ = {}
}

venues_screen_reload :: proc(ps: ^Venues_Screen) {
	venues_free(ps.venues)
	ps.venues = venues_list()
}

// Our venue with this id, if any. This is how a venue in the list is
// told from a vanilla one: dirtbench knows what it made, and does not have to
// guess from a baked manifest or a file timestamp (which lies — every stock
// route directory carries the install date, not the build date).
@(private = "file")
venue_for :: proc(ps: ^Venues_Screen, id: string) -> (^Venue, bool) {
	for &p in ps.venues {
		if p.id == id {
			return &p, true
		}
	}
	return nil, false
}

// --- the screen --------------------------------------------------------------

draw_venues_screen :: proc(ed: ^Editor) {
	ps := &ed.screen
	vs := &ed.install

	ui.igSetNextWindowPos({0, 22}, .Always, {0, 0})
	ui.igSetNextWindowSize({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight() - 22)}, .Always)
	flags := ui.IM_WINDOW_NO_TITLE_BAR | ui.IM_WINDOW_NO_RESIZE |
	         ui.IM_WINDOW_NO_MOVE | ui.IM_WINDOW_NO_COLLAPSE
	if !ui.igBegin("Project manager", nil, flags) {
		ui.igEnd()
		return
	}
	defer ui.igEnd()

	if !vs.found {
		draw_no_install(vs)
		return
	}

	c := d3.install_counts(vs.install)
	ui.im_text(fmt.ctprintf("%d venues, %d routes in the game", c.venues, c.routes))
	if c.orphan_venues > 0 || c.orphan_routes > 0 {
		ui.im_text_colored(
			WARN_COL,
			fmt.ctprintf(
				"%d venues and %d routes are half-installed",
				c.orphan_venues,
				c.orphan_routes,
			),
		)
	}
	if ui.im_button("Rescan") {
		install_scan_rescan(vs)
		venues_screen_reload(ps)
	}
	ui.im_same_line()
	if ui.im_button(ps.adding ? "Cancel" : "New venue...") {
		ps.adding = !ps.adding
		delete(ps.error)
		ps.error = ""
	}

	if ps.adding {
		draw_new_venue(ed)
	}

	ui.igSeparatorText("Yours")
	mine := 0
	for &p in ps.venues {
		draw_venue_row(ed, &p)
		mine += 1
	}
	if mine == 0 {
		ui.im_text_colored(DIM_COL, "(none yet — New venue starts one)")
	}

	draw_status_text(ed)
	ui.igSeparatorText("Stock — read-only")
	for venue in vs.install.venues {
		if _, ours := venue_for(ps, venue.id); ours {
			continue
		}
		draw_stock_row(ps, venue)
	}
}

@(private = "file")
draw_no_install :: proc(vs: ^Install_Scan) {
	ui.im_text_colored(WARN_COL, fmt.ctprintf("No Dirt 3 install: %s", vs.status))
	ui.igSpacing()
	ui.im_text("Point the tool at the game with a line like:")
	ui.im_text_colored(
		DIM_COL,
		fmt.ctprintf("  %s = /path/to/DiRT 3 Complete Edition", D3_INSTALL_KEY),
	)
	ui.im_text(fmt.ctprintf("in %s", conf_path()))
	ui.igSpacing()
	if ui.im_button("Rescan") {
		install_scan_rescan(vs)
	}
}

@(private = "file")
draw_venue_deployment :: proc(ed: ^Editor, p: ^Venue, deployed: bool) {
	ps := &ed.screen
	if deployed {
		if ui.im_button(fmt.ctprintf("Revert deployment###revert_%s", p.id)) {
			msg, ok := venue_revert(&ed.install, p^)
			set_status(ed, msg, ok)
			if ok {
				install_scan_rescan(&ed.install)
			}
		}
		return
	}
	// Exporting a venue compiles its stages out of the road graph first. Until
	// that succeeds there is nothing to deploy, so the failure is reported here
	// rather than half way through writing into the game.
	if ui.im_button(fmt.ctprintf("Preflight deploy###deploy_%s", p.id)) {
		stages, compile_msg, compiled := venue_compile(p^, context.temp_allocator)
		if !compiled {
			set_status(ed, compile_msg, false)
			delete(ps.deploy_ready)
			ps.deploy_ready = ""
			return
		}
		venue_compiled_delete(stages, context.temp_allocator)
		msg, ok := venue_deploy_preflight(&ed.install, p^)
		msg = fmt.tprintf("%s; %s", compile_msg, msg)
		set_status(ed, msg, ok)
		delete(ps.deploy_ready)
		ps.deploy_ready = ok ? strings.clone(p.id) : ""
	}
	if ps.deploy_ready != p.id {
		return
	}
	ui.im_same_line()
	if ui.im_button(fmt.ctprintf("Apply deploy###apply_%s", p.id)) {
		msg, ok := venue_deploy(&ed.install, p^)
		set_status(ed, msg, ok)
		delete(ps.deploy_ready)
		ps.deploy_ready = ""
		if ok {
			install_scan_rescan(&ed.install)
		}
	}
}

@(private = "file")
draw_venue_row :: proc(ed: ^Editor, p: ^Venue) {
	ps := &ed.screen
	label := fmt.ctprintf("%s###venue_%s", p.id, p.id)
	if !ui.igCollapsingHeader_TreeNodeFlags(label, ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	ui.im_text_colored(MINE_COL, fmt.ctprintf("art from %s/%s", p.base, p.base_route))
	deployed := false
	if venue, found := d3.install_venue(&ed.install.install, p.location, p.id); found {
		deployed = d3.venue_playable(venue^)
	}
	ui.im_text_colored(
		deployed ? MINE_COL : DIM_COL,
		deployed ? "deployed" : "not deployed",
	)

	active := venue_editor_running(ps, p.id)
	ui.igBeginDisabled(active)
	if ui.im_button(fmt.ctprintf("%s###open_%s", active ? "Editor open" : "Edit road network", p.id)) {
		launch_venue_editor(ed, p.id)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	draw_venue_deployment(ed, p, deployed)
	ui.im_same_line()
	confirming := ps.delete_ready == p.id
	if ui.im_button(fmt.ctprintf("%s###delete_%s", confirming ? "Confirm delete" : "Delete...", p.id)) {
		if !confirming {
			delete(ps.delete_ready)
			ps.delete_ready = strings.clone(p.id)
		} else {
			msg, ok := venue_delete(&ed.install, p^)
			set_status(ed, msg, ok)
			delete(ps.delete_ready)
			ps.delete_ready = ""
			if ok { venues_screen_reload(ps) }
		}
	}
	ui.igSpacing()
}

@(private = "file")
draw_stock_row :: proc(ps: ^Venues_Screen, venue: d3.Venue) {
	playable := d3.venue_playable(venue)
	registered, on_disk := 0, 0
	for route in venue.routes {
		if route.registered {
			registered += 1
		}
		if route.on_disk {
			on_disk += 1
		}
	}

	ui.igBeginDisabled(true)
	ui.im_text(fmt.ctprintf("%s / %s", venue.location, venue.id))
	ui.igEndDisabled()
	ui.im_same_line()
	switch {
	case !playable:
		ui.im_text_colored(WARN_COL, "not loadable")
	case registered != on_disk:
		ui.im_text_colored(
			WARN_COL,
			fmt.ctprintf("%d routes, %d registered, %d on disk", len(venue.routes), registered, on_disk),
		)
	case:
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%d routes", registered))
	}
}

// --- new venue ---------------------------------------------------------------

@(private = "file")
draw_new_venue :: proc(ed: ^Editor) {
	ps := &ed.screen
	vs := &ed.install

	ui.igSeparatorText("New venue")
	ui.igInputText("id", &ps.name_buf[0], len(ps.name_buf), ui.IM_INPUT_TEXT_CHARS_NO_BLANK, nil, nil)
	ui.igInputText("shown as", &ps.display_buf[0], len(ps.display_buf), ui.IM_INPUT_TEXT_NONE, nil, nil)

	id := sanitise_venue_id(buf_text(ps.name_buf[:]))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("directory and file_string: %s", id))

	ui.im_text("Art comes from:")
	for venue, vi in vs.install.venues {
		if !venue_is_base(venue) {
			continue
		}
		if _, ours := venue_for(ps, venue.id); ours {
			continue
		}
		if ui.igRadioButton_Bool(
			fmt.ctprintf("%s###base_%d", venue.id, vi),
			ps.base_venue == vi,
		) {
			ps.base_venue = vi
			ps.base_route = first_playable_route(venue)
		}
	}

	if ps.error != "" {
		ui.im_text_colored(WARN_COL, fmt.ctprint(ps.error))
	}

	ready := ps.base_venue >= 0 && ps.base_route >= 0
	ui.igBeginDisabled(!ready)
	if ui.im_button("Create") {
		base := vs.install.venues[ps.base_venue]
		spec := fmt.tprintf("%s/%s", base.location, base.id)
		p, msg, ok := venue_create(
			vs,
			id,
			buf_text(ps.display_buf[:]),
			spec,
			base.routes[ps.base_route].id,
		)
		delete(ps.error)
		ps.error = ""
		if !ok {
			ps.error = strings.clone(msg)
		} else {
			venue_free(p)
			ps.adding = false
			ps.name_buf, ps.display_buf = {}, {}
			venues_screen_reload(ps)
			set_status(ed, fmt.tprintf("created %s from %s", id, spec), true)
		}
	}
	ui.igEndDisabled()
	ui.igSpacing()
}

@(private = "file")
first_playable_route :: proc(venue: d3.Venue) -> int {
	for route, i in venue.routes {
		if d3.route_playable(route) {
			return i
		}
	}
	return -1
}

// An ImGui text buffer up to its NUL.
@(private = "file")
buf_text :: proc(buf: []u8) -> string {
	for b, i in buf {
		if b == 0 {
			return string(buf[:i])
		}
	}
	return string(buf)
}

// --- opening -----------------------------------------------------------------

open_venue_editor :: proc(ed: ^Editor, p: ^Venue) -> bool {
	path := venue_road_path(p.id)
	migrating := false
	// One-time compatibility bridge for projects made before venues owned a
	// road.json: their first route was the road document.
	if !os.exists(path) && len(p.stages) > 0 {
		path = venue_stage_path(p.id, p.stages[0])
		migrating = true
	}
	if msg, ok := load_stage_from(&ed.spline, path, &ed.veg, &ed.timing); !ok {
		set_status(ed, msg, false)
		return false
	}
	ed.start, ed.finish = venue_markers(p^)
	ed.stage_mode = false
	if migrating {
		if msg, ok := save_stage_to(ed.spline, venue_road_path(p.id), ed.veg, ed.timing); !ok {
			set_status(ed, fmt.tprintf("opened old road but could not migrate it: %s", msg), false)
			return false
		}
		p.version = VENUE_VERSION
		if msg, ok := venue_save(p^); !ok {
			set_status(ed, fmt.tprintf("migrated road but could not update venue: %s", msg), false)
			return false
		}
	}
	delete(ed.open_venue)
	delete(ed.open_stage)
	ed.open_venue = strings.clone(p.id)
	ed.open_stage = ""
	set_stage_name(ed, p.id)
	mark_dirty(ed)
	set_status(ed, fmt.tprintf("editing %s road network", p.id), true)
	return true
}

venue_editor_running :: proc(ps: ^Venues_Screen, venue_id: string) -> bool {
	for editor in ps.editors {
		if editor.venue_id == venue_id {
			return true
		}
	}
	return false
}

// Argument slices avoid platform-specific shell quoting.
launch_venue_editor :: proc(ed: ^Editor, venue_id: string) {
	if venue_editor_running(&ed.screen, venue_id) {
		set_status(ed, fmt.tprintf("%s already has an editor open", venue_id), false)
		return
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		set_status(ed, fmt.tprintf("could not locate dirtbench: %v", err), false)
		return
	}
	command := []string{exe, "--editor", venue_id}
	process, start_err := os.process_start({command = command})
	if start_err != nil {
		set_status(ed, fmt.tprintf("could not launch editor: %v", start_err), false)
		return
	}
	append(
		&ed.screen.editors,
		Venue_Editor_Process{venue_id = strings.clone(venue_id), process = process},
	)
	set_status(ed, fmt.tprintf("opened %s in a new editor window", venue_id), true)
}

venues_editors_reap :: proc(ps: ^Venues_Screen) {
	for i := len(ps.editors) - 1; i >= 0; i -= 1 {
		state, err := os.process_wait(ps.editors[i].process, timeout = 0)
		if err == nil && state.exited {
			delete(ps.editors[i].venue_id)
			unordered_remove(&ps.editors, i)
		}
	}
}

// One frame of the venue screen. Deliberately not the editor's frame with
// panels swapped: there is no camera, no gizmo and no geometry here, and a mode
// that shares a loop with the editor ends up sharing its state too.
draw_venues_frame :: proc(ed: ^Editor, window: ^rl.Window) {
	rl.BeginWindowFrame(window)
	rl.ClearBackground({22, 24, 29, 255})

	ui.imgui_backend_begin()
	draw_venues_menubar(ed)
	draw_venues_screen(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(window)

	rl.EndWindowFrame(window)
}

@(private = "file")
draw_venues_menubar :: proc(ed: ^Editor) {
	if !ui.igBeginMainMenuBar() {
		return
	}
	defer ui.igEndMainMenuBar()

	if ui.igBeginMenu("File", true) {
		if ui.igMenuItem_Bool("Rescan install", nil, false, true) {
			install_scan_rescan(&ed.install)
			venues_screen_reload(&ed.screen)
			set_status(ed, install_scan_status_text(&ed.install), ed.install.found)
		}
		ui.igSeparator()
		if ui.igMenuItem_Bool("Quit", "Esc", false, true) {
			ed.quit = true
		}
		ui.igEndMenu()
	}
	if ui.igBeginMenu("View", true) {
		if ui.igMenuItem_Bool("ImGui demo window", nil, ed.show_demo, true) {
			ed.show_demo = !ed.show_demo
		}
		ui.igEndMenu()
	}
}
