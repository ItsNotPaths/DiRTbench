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
// Drawing this screen touches nothing. Deploy is a separate button, and its
// preflight is read-only: applying is the opt-in.

import "core:fmt"
import "core:os"
import "core:strings"
import d3 "../d3"
import "../geo"
import "../ui"
import "../gfx"

DIM_COL :: ui.Im_Vec4{0.62, 0.62, 0.66, 1.0}
WARN_COL :: ui.Im_Vec4{0.90, 0.72, 0.38, 1.0}
MINE_COL :: ui.Im_Vec4{0.58, 0.82, 0.62, 1.0}

// One stage's editable name. ImGui edits a fixed buffer in place, so the screen
// keeps one per stage rather than re-reading the name out of the document every
// frame, which would wipe whatever is half typed.
Stage_Row :: struct {
	venue: string, // both owned; together they are the row's identity
	route: string,
	name:  [64]u8,
}

// What the screen is doing. The new-venue form is modal in spirit: while it is
// up, the list is still drawn but nothing else is actionable.
Venues_Screen :: struct {
	venues:       []Venue,
	adding:       bool,
	name_buf:     [64]u8, // ImGui edits these in place, so they are fixed buffers
	display_buf:  [64]u8,
	// The vanilla venue the new one clones its art from, by **id**, not by index
	// into `install.venues`: any deploy, revert or Rescan install rebuilds that
	// array, and an index would then name a different venue. "" for none picked.
	base_venue:   string,
	base_route:   string,
	error:        string, // why the last create was refused
	deploy_ready: string, // venue whose read-only preflight was just shown
	delete_ready: string, // second click confirms project deletion
	stage_ready:  string, // "<venue>/<route>" whose removal a second click confirms
	stages_open:  string, // the one venue showing its stage list, "" for none
	rows:         [dynamic]Stage_Row,
	// Re-read `venues` between frames. Reloading mid-frame frees the array the
	// row loop is walking.
	reload_pending: bool,
}

venues_screen_init :: proc(ps: ^Venues_Screen) {
	venues_screen_reload(ps)
}

venues_screen_delete :: proc(ps: ^Venues_Screen) {
	venues_free(ps.venues)
	delete(ps.base_venue)
	delete(ps.base_route)
	delete(ps.error)
	delete(ps.deploy_ready)
	delete(ps.delete_ready)
	delete(ps.stage_ready)
	delete(ps.stages_open)
	for row in ps.rows {
		delete(row.venue)
		delete(row.route)
	}
	delete(ps.rows)
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

	draw_recovery_rows(app)

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
		ps.reload_pending = true
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
	stage_rows_sweep(app)
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

// What answering a recovery row asks for.
@(private = "file")
Recovery_Answer :: enum {
	None,
	Swap, // Restore, or Undo: the same operation from either side
	Drop, // Discard, or Keep: throw the set-aside copy away
}

// What the last run left behind, and the two buttons that deal with it. Drawn
// from what is on disk (`app.recovery`), so it survives quitting and reappears
// until it is answered. Nothing here is destructive: until Discard or Keep,
// both versions exist.
@(private = "file")
draw_recovery_rows :: proc(app: ^App) {
	answer := Recovery_Answer.None
	at := -1
	for set, i in app.recovery {
		if row := draw_recovery_row(app, set, i); row != .None {
			answer, at = row, i
		}
	}
	// After the loop: either answer rewrites the list being walked.
	switch answer {
	case .None:
	case .Swap:
		msg, ok := recovery_swap(&app.recovery[at])
		set_status(&app.status, ok ? "swapped" : msg, ok)
		app_recovery_reload(app)
	case .Drop:
		recovery_discard(&app.recovery[at])
		set_status(&app.status, "the set-aside copy is gone", true)
		app_recovery_reload(app)
	}
}

@(private = "file")
draw_recovery_row :: proc(app: ^App, set: Recovery_Set, i: int) -> Recovery_Answer {
	recovered := set.state == .Recovered
	defer ui.igSeparator()

	clock := recovery_clock_text(set.at)
	headline := fmt.ctprintf(
		"dirtbench closed without saving. %d documents from %s can be brought back.",
		len(set.docs), clock,
	)
	if !recovered {
		headline = fmt.ctprintf(
			"%d documents recovered from %s are the ones on disk now.", len(set.docs), clock,
		)
	}
	ui.im_text_colored(recovered ? WARN_COL : MINE_COL, headline)
	for doc in set.docs {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("    venue %s", doc.id))
	}

	if held, blocked := recovery_blocked_by(app.docs[:], set); blocked {
		ui.im_text_colored(WARN_COL, fmt.ctprintf("close the %s window first", held))
		return .None
	}
	if ui.im_button(fmt.ctprintf("%s###rec_swap_%d", recovered ? "Restore" : "Undo recovery", i)) {
		return .Swap
	}
	ui.im_same_line()
	if ui.im_button(fmt.ctprintf("%s###rec_drop_%d", recovered ? "Discard" : "Keep", i)) {
		return .Drop
	}
	return .None
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
		// Re-export, for a road edited since it was last written.
		if ui.im_button(fmt.ctprintf("Update in game###publish_%s", p.id)) {
			msg, ok := venue_publish(&app.install, p^)
			set_status(&app.status, msg, ok)
			if ok {
				install_scan_rescan(&app.install)
			}
		}
		ui.im_same_line()
		if ui.im_button(fmt.ctprintf("Revert deployment###revert_%s", p.id)) {
			msg, ok := venue_revert(&app.install, p^)
			set_status(&app.status, msg, ok)
			if ok {
				install_scan_rescan(&app.install)
			}
		}
		return
	}
	// Publishing a venue compiles its stages out of the road graph first. Until
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
	if ui.im_button(fmt.ctprintf("Deploy to game###apply_%s", p.id)) {
		msg, ok := venue_publish(&app.install, p^)
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
	ui.im_text_colored(MINE_COL, fmt.ctprint(pack_text(p.base, p.base_route)))
	deployed := false
	if venue, found := d3.install_venue(&app.install.install, p.location, p.id); found {
		deployed = d3.venue_playable(venue^)
	}
	ui.im_text_colored(
		deployed ? MINE_COL : DIM_COL,
		deployed ? "deployed" : "not deployed",
	)

	open := venue_window(app, p.id, .Venue) != nil
	if ui.im_button(fmt.ctprintf("%s###open_%s", open ? "Show road network" : "Edit road network", p.id)) {
		open_window_request(app, p.id, "")
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
			ps.reload_pending = ok
		}
	}
	draw_venue_stages(app, p)
	ui.igSpacing()
}

// The stage list, and the only place stages are listed or edited. A venue
// window edits the road; it says nothing about the stages that use it.
//
// The list comes from the open document when a window has one, because that is
// the copy being edited. venue.json otherwise.
venue_stages :: proc(app: ^App, venue_id: string) -> []Venue_Route {
	if doc := venue_doc_for(app, venue_id); doc != nil {
		return doc.routes[:]
	}
	for &p in app.screen.venues {
		if p.id == venue_id {
			return p.routes
		}
	}
	return nil
}

// The name buffer for this stage, seeded from the list the first time it is
// asked for. Seeded once and not again: after that the buffer is what the user
// is typing, and the list is what they last committed.
@(private = "file")
stage_row :: proc(ps: ^Venues_Screen, venue_id: string, route: Venue_Route) -> ^Stage_Row {
	for &row in ps.rows {
		if row.venue == venue_id && row.route == route.id {
			return &row
		}
	}
	append(&ps.rows, Stage_Row{venue = strings.clone(venue_id), route = strings.clone(route.id)})
	row := &ps.rows[len(ps.rows) - 1]
	set_buf(row.name[:], route.name)
	return row
}

// Drop the buffers of stages that are gone, so a re-used id gets a fresh one.
@(private = "file")
stage_rows_sweep :: proc(app: ^App) {
	ps := &app.screen
	for i := len(ps.rows) - 1; i >= 0; i -= 1 {
		row := ps.rows[i]
		if route_index(venue_stages(app, row.venue), row.route) >= 0 {
			continue
		}
		delete(row.venue)
		delete(row.route)
		unordered_remove(&ps.rows, i)
	}
}

// Where a stage-list edit lands. Each verb below takes one of two paths:
//
//   a window is open   the document takes it, live in every window on that
//                      venue. Its save writes road.json and venue.json as a
//                      pair, which is what stops a marker reaching venue.json
//                      ahead of the road it was placed on.
//   no window          nothing else holds the list, so venue.json is written
//                      now, off a temp copy. The strings in that copy belong to
//                      the venue list, and the temp allocator frees nothing, so
//                      the edit verbs can delete into it freely.
@(private = "file")
stage_list_copy :: proc(p: ^Venue) -> [dynamic]Venue_Route {
	out := make([dynamic]Venue_Route, 0, len(p.routes) + 1, context.temp_allocator)
	append(&out, ..p.routes)
	return out
}

// Persist an edit made on a temp copy, and re-read the screen from disk.
@(private = "file")
stage_list_write :: proc(app: ^App, venue_id: string, routes: []Venue_Route, next_route: int) {
	msg, ok := venue_routes_save(venue_id, routes, next_route)
	if ok {
		msg = fmt.tprintf("%s now has %d stages", venue_id, len(routes))
	}
	set_status(&app.status, msg, ok)
	app.screen.reload_pending = ok
}

@(private = "file")
stage_add :: proc(app: ^App, p: ^Venue) {
	if doc := venue_doc_for(app, p.id); doc != nil {
		routes_add(&doc.routes, &doc.next_route)
		set_status(&app.status, fmt.tprintf("added a stage to %s, not saved yet", p.id), true)
		return
	}
	routes := stage_list_copy(p)
	next := p.next_route
	routes_add(&routes, &next, context.temp_allocator)
	stage_list_write(app, p.id, routes[:], next)
}

@(private = "file")
stage_remove :: proc(app: ^App, p: ^Venue, route_id: string) {
	if doc := venue_doc_for(app, p.id); doc != nil {
		routes_remove(&doc.routes, route_index(doc.routes[:], route_id))
		set_status(&app.status, fmt.tprintf("removed %s from %s, not saved yet", route_id, p.id), true)
		return
	}
	routes := stage_list_copy(p)
	routes_remove(&routes, route_index(routes[:], route_id), context.temp_allocator)
	stage_list_write(app, p.id, routes[:], p.next_route)
}

@(private = "file")
stage_rename :: proc(app: ^App, p: ^Venue, route_id, name: string) {
	if doc := venue_doc_for(app, p.id); doc != nil {
		route_rename(&doc.routes, route_index(doc.routes[:], route_id), name)
		set_status(&app.status, fmt.tprintf("renamed %s, not saved yet", route_id), true)
		return
	}
	routes := stage_list_copy(p)
	route_rename(&routes, route_index(routes[:], route_id), name, context.temp_allocator)
	stage_list_write(app, p.id, routes[:], p.next_route)
}

// One arrow drops the stage list open. One venue's list at a time: the manager
// lists every venue, and several lists open at once buries the row below.
@(private = "file")
draw_venue_stages :: proc(app: ^App, p: ^Venue) {
	ps := &app.screen
	shown := ps.stages_open == p.id
	if ui.igArrowButton(fmt.ctprintf("###stages_%s", p.id), shown ? .Up : .Down) {
		delete(ps.stages_open)
		ps.stages_open = shown ? "" : strings.clone(p.id)
		shown = !shown
	}
	if !shown {
		return
	}
	for route in venue_stages(app, p.id) {
		draw_stage_row(app, p, route)
	}
	if ui.im_button(fmt.ctprintf("Add stage###add_stage_%s", p.id)) {
		stage_add(app, p)
	}
}

// Open, rename, state, remove. A name commits when the field loses focus or
// Enter is pressed, not per keystroke: without a window open every commit is a
// write to venue.json.
@(private = "file")
draw_stage_row :: proc(app: ^App, p: ^Venue, route: Venue_Route) {
	ps := &app.screen
	open := venue_window(app, p.id, .Stage, route.id) != nil
	if ui.im_button(fmt.ctprintf("%s###open_stage_%s_%s", open ? "Show" : "Edit", p.id, route.id)) {
		open_window_request(app, p.id, route.id)
	}
	ui.im_same_line()

	row := stage_row(ps, p.id, route)
	ui.igSetNextItemWidth(170)
	ui.igInputText(
		fmt.ctprintf("###name_%s_%s", p.id, route.id),
		raw_data(row.name[:]), len(row.name), ui.IM_INPUT_TEXT_NONE, nil, nil,
	)
	if ui.igIsItemDeactivatedAfterEdit() {
		stage_rename(app, p, route.id, buf_text(row.name[:]))
	}
	ui.im_same_line()
	ui.im_text_colored(
		route_has_markers(route) ? (open ? MINE_COL : DIM_COL) : WARN_COL,
		route_has_markers(route) ? fmt.ctprint(route.id) : fmt.ctprintf("%s, no lines", route.id),
	)

	ui.im_same_line()
	key := fmt.tprintf("%s/%s", p.id, route.id)
	confirming := ps.stage_ready == key
	if ui.im_button(fmt.ctprintf("%s###del_stage_%s_%s", confirming ? "Sure?" : "Remove", p.id, route.id)) {
		delete(ps.stage_ready)
		ps.stage_ready = ""
		if confirming {
			stage_remove(app, p, route.id)
		} else {
			ps.stage_ready = strings.clone(key)
		}
	}
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
	for venue in vs.install.venues {
		if !venue_is_base(venue) {
			continue
		}
		if _, ours := venue_for(ps, venue.id); ours {
			continue
		}
		if ui.igRadioButton_Bool(fmt.ctprint(venue.id), ps.base_venue == venue.id) {
			delete(ps.base_venue)
			delete(ps.base_route)
			ps.base_venue = strings.clone(venue.id)
			ps.base_route = strings.clone(first_playable_route(venue))
		}
	}

	if ps.error != "" {
		ui.im_text_colored(WARN_COL, fmt.ctprint(ps.error))
	}

	// Looked up every frame rather than held: a rescan between the pick and the
	// click can take the base away, and then there is nothing to clone.
	base, have_base := install_venue_by_id(vs, ps.base_venue)
	ui.igBeginDisabled(!have_base || ps.base_route == "")
	if ui.im_button("Create") {
		spec := fmt.tprintf("%s/%s", base.location, base.id)
		p, msg, ok := venue_create(
			vs,
			id,
			buf_text(ps.display_buf[:]),
			spec,
			ps.base_route,
		)
		delete(ps.error)
		ps.error = ""
		if !ok {
			ps.error = strings.clone(msg)
		} else {
			venue_free(p)
			ps.adding = false
			ps.name_buf, ps.display_buf = {}, {}
			ps.reload_pending = true
			set_status(&app.status, fmt.tprintf("created %s from %s", id, spec), true)
		}
	}
	ui.igEndDisabled()
	ui.igSpacing()
}

@(private = "file")
first_playable_route :: proc(venue: d3.Venue) -> string {
	for route in venue.routes {
		if d3.route_playable(route) {
			return route.id
		}
	}
	return ""
}

// A vanilla venue by id. Ids are unique across an install, so the location is
// not part of the lookup.
@(private = "file")
install_venue_by_id :: proc(vs: ^Install_Scan, id: string) -> (venue: d3.Venue, found: bool) {
	if !vs.found || id == "" {
		return
	}
	for v in vs.install.venues {
		if v.id == id {
			return v, true
		}
	}
	return
}

// --- opening -----------------------------------------------------------------

venue_doc_load :: proc(doc: ^Venue_Doc, p: ^Venue) -> (msg: string, ok: bool) {
	if load_msg, loaded := doc_load_road(doc, p.road); !loaded {
		return load_msg, false
	}
	routes_free(&doc.routes)
	doc.routes = venue_routes(p^)
	doc.next_route = p.next_route
	delete(doc.open_venue)
	doc.open_venue = strings.clone(p.id)
	// The trees come with the art: the base venue picks the species, not the user.
	doc_set_base(doc, p.base)
	set_stage_name(doc, p.id)
	mark_dirty(doc)
	doc_loaded(doc)
	return "", true
}

// The open document for this venue, or nil. One document per venue however
// many windows are on it: two caches behind one road would disagree the moment
// either window edited.
venue_doc_for :: proc(app: ^App, venue_id: string) -> ^Venue_Doc {
	for doc in app.docs {
		if doc.open_venue == venue_id {
			return doc
		}
	}
	return nil
}

// The window of this kind on this venue, or nil. One road-network window per
// venue, and one window per stage, so a stage window is matched on its stage
// as well as on its venue.
venue_window :: proc(app: ^App, venue_id: string, kind: View_Kind, stage_id := "") -> ^Editor {
	for ed in app.editors {
		if ed.doc.open_venue != venue_id || ed.kind != kind {
			continue
		}
		if kind == .Stage && ed.stage_id != stage_id {
			continue
		}
		return ed
	}
	return nil
}

// The document for this venue, loaded if no window has it open yet.
venue_doc_open :: proc(app: ^App, p: ^Venue) -> (doc: ^Venue_Doc, msg: string, ok: bool) {
	if existing := venue_doc_for(app, p.id); existing != nil {
		return existing, "", true
	}
	doc = doc_new(app)
	if load_msg, loaded := venue_doc_load(doc, p); !loaded {
		doc_delete(doc)
		free(doc)
		return nil, load_msg, false
	}
	append(&app.docs, doc)
	return doc, "", true
}

// Give back a document no window ended up looking at. Only the failure path
// between opening a document and creating its window needs this; every other
// release goes through editors_detach.
venue_doc_release :: proc(app: ^App, doc: ^Venue_Doc) {
	for ed in app.editors {
		if ed.doc == doc {
			return
		}
	}
	for d, i in app.docs {
		if d == doc {
			unordered_remove(&app.docs, i)
			break
		}
	}
	doc_delete(doc)
	free(doc)
}

// Ask for a window. One request per frame is enough: it is serviced before the
// next one is drawn, so a second click cannot overwrite an unserviced first.
open_window_request :: proc(app: ^App, venue_id, stage_id: string) {
	set_buf(app.open_request.venue[:], venue_id)
	set_buf(app.open_request.stage[:], stage_id)
}

// Act on the button pressed during the last frame.
//
// Opening a window creates an ImGui context and makes it current, and it
// repoints gfx's active window. Neither may happen inside another window's
// frame: the project manager would go on to call ImGui::Render against a
// context that never had NewFrame, and draw into a command buffer that does not
// exist. That is a segfault, and it is what this indirection exists to stop.
app_service_open_request :: proc(app: ^App) {
	id := buf_text(app.open_request.venue[:])
	if id == "" {
		return
	}
	stage_id := buf_text(app.open_request.stage[:])
	defer app.open_request = {}
	p, found := venue_for(&app.screen, id)
	if !found {
		set_status(&app.status, fmt.tprintf("%s is no longer there", id), false)
		return
	}
	if stage_id != "" {
		open_stage_window(app, p, stage_id)
	} else {
		open_venue_window(app, p)
	}
}

// One window on a document, in the window list. nil when the window would not
// open; the document is the caller's to give back. The editor is
// heap-allocated because gfx holds a pointer to the window inside it.
editor_open :: proc(app: ^App, doc: ^Venue_Doc, kind: View_Kind, title: cstring) -> ^Editor {
	ed := new(Editor)
	ed^ = view_defaults()
	ed.app = app
	ed.kind = kind
	ed.doc = doc
	if !editor_window_open(ed, title) {
		set_status(&app.status, "could not open an editor window", false)
		free(ed)
		return nil
	}
	append(&app.editors, ed)
	return ed
}

// The venue's road network, in a window beside the project manager.
//
// The document comes first and the window second, so a venue that will not load
// costs no window. A window that will not open gives the document back.
open_venue_window :: proc(app: ^App, p: ^Venue) {
	if existing := venue_window(app, p.id, .Venue); existing != nil {
		gfx.RaiseWindow(&existing.window)
		return
	}
	doc, doc_msg, doc_ok := venue_doc_open(app, p)
	if !doc_ok {
		set_status(&app.status, fmt.tprintf("could not open %s: %s", p.id, doc_msg), false)
		return
	}
	if editor_open(app, doc, .Venue, fmt.ctprintf("dirtbench — %s", p.id)) == nil {
		venue_doc_release(app, doc)
		return
	}
	set_status(&app.status, fmt.tprintf("opened %s in a new window", p.id), true)
}

// One stage of a venue, in a window of its own: the same document, and a view
// that moves nothing but that stage's two lines.
open_stage_window :: proc(app: ^App, p: ^Venue, stage_id: string) {
	if existing := venue_window(app, p.id, .Stage, stage_id); existing != nil {
		gfx.RaiseWindow(&existing.window)
		return
	}
	doc, doc_msg, doc_ok := venue_doc_open(app, p)
	if !doc_ok {
		set_status(&app.status, fmt.tprintf("could not open %s: %s", p.id, doc_msg), false)
		return
	}
	if route_index(doc.routes[:], stage_id) < 0 {
		set_status(&app.status, fmt.tprintf("%s has no stage %s", p.id, stage_id), false)
		venue_doc_release(app, doc)
		return
	}
	ed := editor_open(app, doc, .Stage, fmt.ctprintf("dirtbench — %s / %s", p.id, stage_id))
	if ed == nil {
		venue_doc_release(app, doc)
		return
	}
	ed.stage_id = strings.clone(stage_id)
	stage_resync(ed)
	set_status(&app.status, fmt.tprintf("opened %s / %s", p.id, stage_id), true)
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
	// Between frames: a reload frees the venue array the row loop is walking.
	if app.screen.reload_pending {
		venues_screen_reload(&app.screen)
		app.screen.reload_pending = false
	}
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
			app.screen.reload_pending = true
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
