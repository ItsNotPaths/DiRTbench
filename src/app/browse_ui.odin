package main

// The browse panel: what is published on dirtbench.paths.place, and the button
// that brings a copy of one here.
//
// Its own floating window, for the same reason the upload panel has one: the
// venue list under it is rebuilt whenever anything is downloaded, and a panel
// inside a row would move with the row.
//
// Nothing here logs in. A download needs no account, and the panel asks for
// none, so the only thing it ever knows about the user is what they typed into
// the search box.

import "core:fmt"
import "core:strings"
import "../net"
import "../ui"

// What the panel is asking for. The page is held here rather than read back out
// of the answer: Next is a question, and the answer to it has not arrived yet.
Browse_Form :: struct {
	query: [128]u8,
	sort:  Browse_Sort,
	page:  int,
}

// The floating window, drawn once a frame after the project manager's own.
draw_browse_window :: proc(app: ^App) {
	ps := &app.screen
	if !ps.browse_open {
		return
	}
	ui.igSetNextWindowSize({520, 560}, .FirstUseEver)
	ui.igSetNextWindowPos({140, 100}, .FirstUseEver, {0, 0})
	open := true
	if ui.igBegin("Browse " + UPLOAD_HOST + "###browse_window", &open, ui.IM_WINDOW_NONE) {
		draw_browse(app)
	}
	ui.igEnd()
	if !open {
		ps.browse_open = false
	}
}

@(private = "file")
draw_browse :: proc(app: ^App) {
	f := &app.screen.browse
	br := &app.browser
	if !net.available() {
		ui.im_text_colored(WARN_COL, "libcurl is not installed on this machine")
		return
	}

	ui.igSetNextItemWidth(300)
	// Enter searches. Every keystroke would be a request, and the site counts
	// requests.
	if ui.igInputText(
		"###browse_q", raw_data(f.query[:]), len(f.query),
		ui.IM_INPUT_TEXT_ENTER_RETURNS_TRUE, nil, nil,
	) {
		browse_ask(app, 1)
	}
	ui.im_same_line()
	ui.igBeginDisabled(browse_busy(br))
	if ui.im_button("Search") {
		browse_ask(app, 1)
	}
	ui.igEndDisabled()
	ui.im_text_colored(DIM_COL, "pine, rally*, !loop, user: a, b, rating:>=4")

	for sort, i in Browse_Sort {
		if i > 0 {
			ui.im_same_line()
		}
		if ui.igRadioButton_Bool(BROWSE_SORTS[sort].label, f.sort == sort) && f.sort != sort {
			f.sort = sort
			browse_ask(app, 1)
		}
	}

	ui.igSeparator()
	// Everything but the two lines the footer needs.
	list_h := -ui.igGetFrameHeightWithSpacing() * 2
	ui.igBeginChild_Str("###browse_list", {0, list_h}, ui.IM_CHILD_NONE, ui.IM_WINDOW_NONE)
	draw_browse_rows(app)
	ui.igEndChild()
	draw_browse_footer(app)
}

@(private = "file")
draw_browse_rows :: proc(app: ^App) {
	br := &app.browser
	if len(br.results.venues) == 0 {
		// A failed search says why in the footer, so the list says nothing.
		switch {
		case browse_busy(br) || !br.asked:
			ui.im_text_colored(DIM_COL, "looking...")
		case br.ok:
			ui.im_text_colored(DIM_COL, "nothing published matches that.")
		}
		return
	}
	for venue in br.results.venues {
		draw_browse_row(app, venue)
	}
}

// One published venue: what it is, and the one thing that can be done with it.
@(private = "file")
draw_browse_row :: proc(app: ^App, l: Browse_Listing) {
	ps := &app.screen
	br := &app.browser
	// By the id the game installs under: that is the one that has to be free
	// here, and two listings may carry the same one.
	mine, have := venue_for(ps, l.venue_id)
	update := have && venue_is_copy_of(mine^, l.slug)
	// An update rewrites the file under the venue. A window holding it would
	// save its own copy over the new one later, so it is asked for first.
	held := update && venue_doc_for(app, l.venue_id) != nil

	ui.im_text(fmt.ctprint(l.title))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("by %s, installs as %s", l.author, l.venue_id))
	ui.im_text_colored(DIM_COL, fmt.ctprint(browse_row_text(l)))

	getting := br.getting == l.slug
	ui.igBeginDisabled(browse_busy(br) || held || (have && !update))
	if ui.im_button(fmt.ctprintf("%s###get_%s", update ? "Update" : "Download", l.slug)) {
		browse_download(br, l.slug)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	switch {
	case getting:
		ui.im_text_colored(DIM_COL, "downloading...")
	case held:
		ui.im_text_colored(WARN_COL, fmt.ctprintf("close the %s window first", l.venue_id))
	case update:
		ui.im_text_colored(MINE_COL, fmt.ctprintf("you have this as %s", l.venue_id))
	case have:
		ui.im_text_colored(WARN_COL, fmt.ctprintf("you already have a venue named %s", l.venue_id))
	case:
		ui.im_text_colored(DIM_COL, fmt.ctprint(l.page_url))
	}
	ui.igSeparator()
}

// The measured figures, which the site works out of the document itself rather
// than believing what an uploader claims. A zero is a figure it could not
// measure, not a venue with no stages.
browse_row_text :: proc(l: Browse_Listing, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if l.stages > 0 {
		fmt.sbprintf(&b, "%d stages", l.stages)
	} else {
		fmt.sbprint(&b, "stages not measured")
	}
	if l.length_m > 0 {
		fmt.sbprintf(&b, ", %.1f km", f32(l.length_m) / 1000)
	}
	fmt.sbprintf(&b, ", %d downloads", l.downloads)
	if l.rating.count > 0 {
		fmt.sbprintf(&b, ", rated %.1f by %d", l.rating.average, l.rating.count)
	}
	if l.version > 1 {
		fmt.sbprintf(&b, ", %d versions", l.version)
	}
	return strings.to_string(b)
}

// Where the last answer left things, and the way to the next page.
@(private = "file")
draw_browse_footer :: proc(app: ^App) {
	br := &app.browser
	f := &app.screen.browse
	if br.message != "" {
		ui.im_text_colored(br.ok ? DIM_COL : WARN_COL, fmt.ctprint(br.message))
	} else if br.results.total > 0 {
		ui.im_text_colored(
			DIM_COL,
			fmt.ctprintf("%d venues, page %d of %d", br.results.total, br.results.page, br.results.pages),
		)
	}
	ui.igBeginDisabled(browse_busy(br) || f.page <= 1)
	if ui.im_button("Previous") {
		browse_ask(app, f.page - 1)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	ui.igBeginDisabled(browse_busy(br) || br.results.page >= br.results.pages)
	if ui.im_button("Next") {
		browse_ask(app, f.page + 1)
	}
	ui.igEndDisabled()
}

@(private = "file")
browse_ask :: proc(app: ^App, page: int) {
	f := &app.screen.browse
	f.page = max(1, page)
	browse_search(&app.browser, buf_text(f.query[:]), f.sort, f.page)
}

// The panel's first question, asked when it is opened rather than when the tool
// starts: a user who never browses never makes a request.
browse_opened :: proc(app: ^App) {
	if !app.browser.asked && !browse_busy(&app.browser) && net.available() {
		browse_ask(app, 1)
	}
}

// --- between frames -------------------------------------------------------------

// Claim a finished request. Here rather than in the panel because what a
// download decides — a new venue in maps/ — outlives whichever panel is open,
// and because the list the project manager is drawing is rebuilt by it.
app_service_browse :: proc(app: ^App) {
	br := &app.browser
	if !browse_tick(br) {
		return
	}
	delete(br.message)
	br.message = ""
	br.ok = br.job.answer != .Failed
	switch br.job.kind {
	case .Search:
		browse_claim_search(br)
	case .Download:
		browse_claim_download(app, br)
	}
	browse_job_free(&br.job)
}

@(private = "file")
browse_claim_search :: proc(br: ^Browser) {
	if br.job.answer == .Failed {
		br.message = strings.clone(br.job.message)
		return
	}
	br.asked = true
	// A 304 says the page on screen is still the answer, so it stays.
	if br.job.answer == .Unchanged {
		return
	}
	if msg, kept := browse_keep(br); !kept {
		br.ok = false
		br.message = strings.clone(msg)
	}
}

@(private = "file")
browse_claim_download :: proc(app: ^App, br: ^Browser) {
	delete(br.getting)
	br.getting = ""
	if br.job.answer != .Fresh {
		br.message = strings.clone(br.job.message)
		set_status(&app.status, br.job.message, false)
		return
	}
	id, msg, ok := browse_install(&app.install, br.job.slug, transmute([]u8)br.job.body)
	if ok {
		msg = fmt.tprintf("%s is yours to drive, %s", id, br.job.message)
	}
	br.ok = ok
	br.message = strings.clone(msg)
	set_status(&app.status, msg, ok)
	app.screen.reload_pending = ok
}
