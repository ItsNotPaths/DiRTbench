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
import "../gfx"

DIM_COL :: ui.Im_Vec4{0.62, 0.62, 0.66, 1.0}
WARN_COL :: ui.Im_Vec4{0.90, 0.72, 0.38, 1.0}
MINE_COL :: ui.Im_Vec4{0.58, 0.82, 0.62, 1.0}

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

draw_venues_screen :: proc(app: ^App) {
	ps := &app.screen
	vs := &app.install

	ui.igSetNextWindowPos({0, 22}, .Always, {0, 0})
	ui.igSetNextWindowSize({f32(gfx.GetScreenWidth()), f32(gfx.GetScreenHeight() - 22)}, .Always)
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
		draw_new_venue(app)
	}

	ui.igSeparatorText("Yours")
	mine := 0
	for &p in ps.venues {
		draw_venue_row(app, &p)
		mine += 1
	}
	if mine == 0 {
		ui.im_text_colored(DIM_COL, "(none yet — New venue starts one)")
	}

	draw_status_text(&app.status)
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
draw_venue_deployment :: proc(app: ^App, p: ^Venue, deployed: bool) {
	ps := &app.screen
	if deployed {
		if ui.im_button(fmt.ctprintf("Revert deployment###revert_%s", p.id)) {
			msg, ok := venue_revert(&app.install, p^)
			set_status(&app.status, msg, ok)
			if ok {
				install_scan_rescan(&app.install)
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
			set_status(&app.status, compile_msg, false)
			delete(ps.deploy_ready)
			ps.deploy_ready = ""
			return
		}
		venue_compiled_delete(stages, context.temp_allocator)
		msg, ok := venue_deploy_preflight(&app.install, p^)
		msg = fmt.tprintf("%s; %s", compile_msg, msg)
		set_status(&app.status, msg, ok)
		delete(ps.deploy_ready)
		ps.deploy_ready = ok ? strings.clone(p.id) : ""
	}
	if ps.deploy_ready != p.id {
		return
	}
	ui.im_same_line()
	if ui.im_button(fmt.ctprintf("Apply deploy###apply_%s", p.id)) {
		msg, ok := venue_deploy(&app.install, p^)
		set_status(&app.status, msg, ok)
		delete(ps.deploy_ready)
		ps.deploy_ready = ""
		if ok {
			install_scan_rescan(&app.install)
		}
	}
}

@(private = "file")
draw_venue_row :: proc(app: ^App, p: ^Venue) {
	ps := &app.screen
	label := fmt.ctprintf("%s###venue_%s", p.id, p.id)
	if !ui.igCollapsingHeader_TreeNodeFlags(label, ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	ui.im_text_colored(MINE_COL, fmt.ctprintf("art from %s/%s", p.base, p.base_route))
	deployed := false
	if venue, found := d3.install_venue(&app.install.install, p.location, p.id); found {
		deployed = d3.venue_playable(venue^)
	}
	ui.im_text_colored(
		deployed ? MINE_COL : DIM_COL,
		deployed ? "deployed" : "not deployed",
	)

	open := venue_editor_open(app, p.id) != nil
	if ui.im_button(fmt.ctprintf("%s###open_%s", open ? "Show editor" : "Edit road network", p.id)) {
		set_buf(app.open_request[:], p.id)
	}
	ui.im_same_line()
	draw_venue_deployment(app, p, deployed)
	ui.im_same_line()
	confirming := ps.delete_ready == p.id
	if ui.im_button(fmt.ctprintf("%s###delete_%s", confirming ? "Confirm delete" : "Delete...", p.id)) {
		if !confirming {
			delete(ps.delete_ready)
			ps.delete_ready = strings.clone(p.id)
		} else {
			msg, ok := venue_delete(&app.install, p^)
			set_status(&app.status, msg, ok)
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
draw_new_venue :: proc(app: ^App) {
	ps := &app.screen
	vs := &app.install

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
			set_status(&app.status, fmt.tprintf("created %s from %s", id, spec), true)
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

// --- opening -----------------------------------------------------------------

open_venue_doc :: proc(doc: ^Venue_Doc, p: ^Venue) -> (msg: string, ok: bool) {
	path := venue_road_path(p.id)
	migrating := false
	// One-time compatibility bridge for projects made before venues owned a
	// road.json: their first route was the road document.
	if !os.exists(path) && len(p.stages) > 0 {
		path = venue_stage_path(p.id, p.stages[0])
		migrating = true
	}
	if load_msg, loaded := load_road(doc, path); !loaded {
		return load_msg, false
	}
	routes_free(&doc.routes)
	doc.routes = venue_routes(p^)
	if migrating {
		if save_msg, saved := save_road(doc, venue_road_path(p.id)); !saved {
			return fmt.tprintf("opened old road but could not migrate it: %s", save_msg), false
		}
		p.version = VENUE_VERSION
		if save_msg, saved := venue_save(p^); !saved {
			return fmt.tprintf("migrated road but could not update venue: %s", save_msg), false
		}
	}
	delete(doc.open_venue)
	delete(doc.open_stage)
	doc.open_venue = strings.clone(p.id)
	doc.open_stage = ""
	set_stage_name(doc, p.id)
	mark_dirty(doc)
	return "", true
}

// An editor for this venue, or nil. One window per venue: two views of the
// same road with two caches behind them would disagree the moment either edits.
venue_editor_open :: proc(app: ^App, venue_id: string) -> ^Editor {
	for editor in app.editors {
		if editor.doc.open_venue == venue_id {
			return editor
		}
	}
	return nil
}

// Act on the button pressed during the last frame.
//
// Opening a window creates an ImGui context and makes it current, and it
// repoints gfx's active window. Neither may happen inside another window's
// frame: the project manager would go on to call ImGui::Render against a
// context that never had NewFrame, and draw into a command buffer that does not
// exist. That is a segfault, and it is what this indirection exists to stop.
app_service_open_request :: proc(app: ^App) {
	id := buf_text(app.open_request[:])
	if id == "" {
		return
	}
	defer app.open_request = {}
	p, found := venue_for(&app.screen, id)
	if !found {
		set_status(&app.status, fmt.tprintf("%s is no longer there", id), false)
		return
	}
	open_venue_window(app, p)
}

// Open a venue in a window of its own, beside the project manager. The editor
// is heap-allocated because gfx holds a pointer to the window inside it.
open_venue_window :: proc(app: ^App, p: ^Venue) {
	if existing := venue_editor_open(app, p.id); existing != nil {
		gfx.RaiseWindow(&existing.window)
		return
	}
	ed := new(Editor)
	ed^ = view_defaults()
	ed.app = app
	if !editor_window_open(ed, fmt.ctprintf("dirtbench — %s", p.id)) {
		set_status(&app.status, "could not open an editor window", false)
		free(ed)
		return
	}
	ed.doc = doc_new(app)
	append(&app.docs, ed.doc)
	append(&app.editors, ed)
	if msg, ok := open_venue_doc(ed.doc, p); !ok {
		set_status(&app.status, fmt.tprintf("could not open %s: %s", p.id, msg), false)
		editor_close(app, ed)
		return
	}
	select_route(ed, len(ed.doc.routes) > 0 ? 0 : -1)
	set_status(&app.status, fmt.tprintf("opened %s in a new window", p.id), true)
}

// Drop editors whose window the user closed. Their geometry is the largest
// thing this process holds, so it goes as soon as the window does.
venues_editors_reap :: proc(app: ^App) {
	for i := len(app.editors) - 1; i >= 0; i -= 1 {
		ed := app.editors[i]
		if gfx.WindowShouldClose(&ed.window) || ed.quit {
			editor_close(app, ed)
		}
	}
}

// One frame of the project manager window. Deliberately not the editor's frame
// with panels swapped: there is no camera, no gizmo and no geometry here, and a
// window that shares a loop with the editor ends up sharing its state too.
draw_venues_frame :: proc(app: ^App) {
	gfx.BeginWindowFrame(&app.window)
	gfx.ClearBackground({22, 24, 29, 255})

	ui.imgui_backend_begin()
	draw_venues_menubar(app)
	draw_venues_screen(app)
	if app.show_demo {
		ui.igShowDemoWindow(&app.show_demo)
	}
	render_imgui(&app.window)

	gfx.EndWindowFrame(&app.window)
}

@(private = "file")
draw_venues_menubar :: proc(app: ^App) {
	if !ui.igBeginMainMenuBar() {
		return
	}
	defer ui.igEndMainMenuBar()

	if ui.igBeginMenu("File", true) {
		if ui.igMenuItem_Bool("Rescan install", nil, false, true) {
			install_scan_rescan(&app.install)
			venues_screen_reload(&app.screen)
			set_status(&app.status, install_scan_status_text(&app.install), app.install.found)
		}
		ui.igSeparator()
		if ui.igMenuItem_Bool("Quit", "Esc", false, true) {
			app.quit = true
		}
		ui.igEndMenu()
	}
	if ui.igBeginMenu("View", true) {
		if ui.igMenuItem_Bool("ImGui demo window", nil, app.show_demo, true) {
			app.show_demo = !app.show_demo
		}
		ui.igEndMenu()
	}
}
