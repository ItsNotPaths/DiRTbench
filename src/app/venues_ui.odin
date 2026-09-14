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
import "core:strings"
import d3 "../d3"
import "../ui"
import rl "vendor:raylib"

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
}

venues_screen_init :: proc(ps: ^Venues_Screen) {
	ps.base_venue, ps.base_route = -1, -1
	venues_screen_reload(ps)
}

venues_screen_delete :: proc(ps: ^Venues_Screen) {
	venues_free(ps.venues)
	delete(ps.error)
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
	ui.igSetNextWindowSize({520, 0}, .FirstUseEver)
	if !ui.igBegin("Install_Scan", nil, ui.IM_WINDOW_NONE) {
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
draw_venue_row :: proc(ed: ^Editor, p: ^Venue) {
	ps := &ed.screen
	label := fmt.ctprintf("%s  (%d stages)###venue_%s", p.id, len(p.stages), p.id)
	if !ui.igCollapsingHeader_TreeNodeFlags(label, ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return
	}
	ui.im_text_colored(MINE_COL, fmt.ctprintf("art from %s/%s", p.base, p.base_route))

	for route, i in p.stages {
		name := i < len(p.names.stages) ? p.names.stages[i] : route
		if ui.im_button(fmt.ctprintf("Open %s — %s###open_%s_%s", route, name, p.id, route)) {
			open_venue_stage(ed, p, route)
		}
	}
	if ui.im_button(fmt.ctprintf("Add route###addroute_%s", p.id)) {
		route, msg, ok := venue_add_stage(p, "")
		if !ok {
			set_status(ed, msg, false)
		} else {
			// The reload frees the list `p` points into, so build the message
			// before it, not after.
			done := fmt.tprintf("%s: added %s", p.id, route)
			venues_screen_reload(ps)
			set_status(ed, done, true)
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
			// A venue with no route cannot be opened, so seed one. A failure
			// here leaves the venue on disk with no stages, which the screen
			// shows and Add route fixes.
			_, add_msg, added := venue_add_stage(&p, "")
			venue_free(p)
			if !added {
				ps.error = strings.clone(add_msg)
			}
			ps.adding = false
			ps.name_buf, ps.display_buf = {}, {}
			venues_screen_reload(ps)
			set_status(ed, fmt.tprintf("created %s from %s", id, spec), added)
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

open_venue_stage :: proc(ed: ^Editor, p: ^Venue, route: string) {
	path := venue_stage_path(p.id, route)
	if msg, ok := load_stage_from(&ed.spline, path, &ed.veg, &ed.timing); !ok {
		set_status(ed, msg, false)
		return
	}
	delete(ed.open_venue)
	delete(ed.open_stage)
	ed.open_venue = strings.clone(p.id)
	ed.open_stage = strings.clone(route)
	set_stage_name(ed, route)
	ed.mode = .Editor
	mark_dirty(ed)
	set_status(ed, fmt.tprintf("%s / %s", p.id, route), true)
}

// One frame of the venue screen. Deliberately not the editor's frame with
// panels swapped: there is no camera, no gizmo and no geometry here, and a mode
// that shares a loop with the editor ends up sharing its state too.
draw_venues_frame :: proc(ed: ^Editor) {
	rl.BeginDrawing()
	rl.ClearBackground({22, 24, 29, 255})

	ui.rlImGuiBegin()
	draw_venues_menubar(ed)
	draw_venues_screen(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	ui.rlImGuiEnd()

	rl.EndDrawing()
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
