package main

// The upload panel, under a venue's row in the project manager.
//
// Everything it needs is either in the document or remembered in
// dirtbench.conf, with one exception: the password, which is typed every time
// and kept no longer than the request that uses it.
//
// The thumbnail is not framed here. A venue's shot is set in its own window,
// from the viewport, because that is where the venue can be seen; this panel
// only says whether one was saved and renders from it when the button is
// pressed.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../net"
import "../ui"

// The form's fields. Fixed buffers because ImGui edits them in place, and sized
// to what the site accepts so nothing is silently truncated on the way out.
Upload_Form :: struct {
	seeded:      string, // the venue these buffers were filled for
	user:        [32]u8,
	password:    [80]u8,
	title:       [128]u8,
	description: [4096]u8,
	changelog:   [320]u8,
	// An image to send instead of the rendered one. A path, not a picker: SDL
	// is built here without its dialog backend.
	image:       [512]u8,
}

upload_form_delete :: proc(f: ^Upload_Form) {
	delete(f.seeded)
	f^ = {}
}

// Fill the form for `p`, once per venue the panel is opened on. Not every
// frame: after the first fill the buffers are what the user is typing.
@(private = "file")
upload_form_seed :: proc(f: ^Upload_Form, p: ^Venue) {
	if f.seeded == p.id {
		return
	}
	delete(f.seeded)
	f^ = {seeded = strings.clone(p.id)}
	set_buf(f.user[:], upload_user())
	set_buf(f.title[:], p.names.venue != "" ? p.names.venue : p.id)
}

// Why the Upload button is dead, or "" when it is not. One message rather than
// a list: the first thing in the way is the thing to fix.
@(private = "file")
upload_blocked :: proc(app: ^App, f: ^Upload_Form, p: ^Venue) -> string {
	if upload_busy(&app.uploader) {
		return "an upload is already in flight"
	}
	if !net.available() {
		return "libcurl is not installed on this machine"
	}
	if doc := venue_doc_for(app, p.id); doc != nil && doc_unsaved(doc) {
		return "save the venue first — the site is sent the file on disk"
	}
	if !os.exists(venue_path(p.id)) {
		return fmt.tprintf("%s is not on disk", venue_path(p.id))
	}
	if strings.trim_space(buf_text(f.user[:])) == "" || buf_text(f.password[:]) == "" {
		return "a username and password are needed"
	}
	if strings.trim_space(buf_text(f.title[:])) == "" {
		return "the listing needs a name"
	}
	if img := strings.trim_space(buf_text(f.image[:])); img != "" && !os.exists(img) {
		return fmt.tprintf("no file at %s", img)
	}
	return ""
}

// The panel itself. Drawn under the venue's row, and only for the one venue
// whose panel is open.
draw_venue_upload :: proc(app: ^App, p: ^Venue) {
	ps := &app.screen
	if ps.upload_open != p.id {
		return
	}
	f := &ps.upload
	upload_form_seed(f, p)

	ui.igSeparatorText(fmt.ctprintf("Upload %s to dirtbench.paths.place", p.id))

	// A venue that came from the site is not ours to publish. The server would
	// refuse a version of somebody else's listing anyway; what it could not
	// catch is this being posted as a new listing under our own name.
	if p.source.slug != "" {
		ui.im_text_colored(
			WARN_COL,
			fmt.ctprintf("%s was downloaded from %s and belongs to its author.", p.id, p.source.site),
		)
		ui.im_text_colored(DIM_COL, fmt.ctprintf("Its listing is %s.", p.source.slug))
		return
	}

	ui.igSetNextItemWidth(260)
	ui.igInputText("user", raw_data(f.user[:]), len(f.user), ui.IM_INPUT_TEXT_CHARS_NO_BLANK, nil, nil)
	ui.igSetNextItemWidth(260)
	ui.igInputText("password", raw_data(f.password[:]), len(f.password), ui.IM_INPUT_TEXT_PASSWORD, nil, nil)
	ui.igSetNextItemWidth(260)
	ui.igInputText("name", raw_data(f.title[:]), len(f.title), ui.IM_INPUT_TEXT_NONE, nil, nil)
	ui.im_text_colored(DIM_COL, "Description")
	ui.igInputTextMultiline(
		"###upload_desc", raw_data(f.description[:]), len(f.description),
		{0, 90}, ui.IM_INPUT_TEXT_NONE, nil, nil,
	)

	slug := upload_slug(p.id)
	if slug != "" {
		ui.igSetNextItemWidth(260)
		ui.igInputText("changelog", raw_data(f.changelog[:]), len(f.changelog), ui.IM_INPUT_TEXT_NONE, nil, nil)
	}

	draw_upload_thumbnail(app, f, p)

	if slug == "" {
		ui.im_text_colored(DIM_COL, "Goes up as a new listing.")
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("Goes up as a new version of %s/venue/%s", UPLOAD_SITE, slug))
	}

	why := upload_blocked(app, f, p)
	ui.igBeginDisabled(why != "")
	if ui.im_button(fmt.ctprintf("Upload###upload_go_%s", p.id)) {
		set_buf(app.upload_request[:], p.id)
	}
	ui.igEndDisabled()
	if why != "" {
		ui.im_same_line()
		ui.im_text_colored(WARN_COL, fmt.ctprint(why))
	}
	draw_upload_result(app, p)
	ui.igSpacing()
}

// What picture will be sent, and the way to send a different one.
@(private = "file")
draw_upload_thumbnail :: proc(app: ^App, f: ^Upload_Form, p: ^Venue) {
	override := strings.trim_space(buf_text(f.image[:]))
	switch {
	case override != "":
		ui.im_text_colored(MINE_COL, fmt.ctprintf("Thumbnail: %s", filepath.base(override)))
	case p.shot.set:
		ui.im_text_colored(MINE_COL, "Thumbnail: rendered from this venue's saved view.")
	case:
		ui.im_text_colored(
			DIM_COL,
			"Thumbnail: no view saved, so the whole road is framed from above.",
		)
		ui.im_text_colored(DIM_COL, "Open the venue and use Thumbnail > Use this view to choose one.")
	}
	ui.igSetNextItemWidth(260)
	ui.igInputText("image file", raw_data(f.image[:]), len(f.image), ui.IM_INPUT_TEXT_NONE, nil, nil)
	ui.im_same_line()
	ui.im_text_colored(DIM_COL, "(blank renders one)")
}

// The last upload's answer, for as long as the job holding it is the one this
// venue started.
@(private = "file")
draw_upload_result :: proc(app: ^App, p: ^Venue) {
	up := &app.uploader
	if up.venue != p.id {
		return
	}
	// The busy test comes first: while the worker owns the job, nothing on this
	// thread may read a field of it, and `message` is one the worker writes.
	if upload_busy(up) {
		ui.im_text_colored(DIM_COL, "uploading...")
		return
	}
	if up.job.message == "" {
		return
	}
	ui.im_text_colored(up.job.ok ? MINE_COL : WARN_COL, fmt.ctprint(up.job.message))
	if up.job.url_out != "" {
		ui.im_text_colored(DIM_COL, fmt.ctprint(up.job.url_out))
	}
}

// --- between frames -------------------------------------------------------------

// Act on the Upload button pressed during the last frame.
//
// Not inside the frame, for the same reason opening a window is not: rendering
// the thumbnail acquires a command buffer and draws a scene, and the scene
// batch is process-wide. Started half way through the project manager's own
// frame, it would take that frame's geometry with it.
app_service_upload_request :: proc(app: ^App) {
	id := buf_text(app.upload_request[:])
	if id == "" {
		return
	}
	defer app.upload_request = {}
	ps := &app.screen
	p, found := venue_for_id(app, id)
	if !found {
		set_status(&app.status, fmt.tprintf("%s is no longer there", id), false)
		return
	}
	f := &ps.upload

	image := strings.trim_space(buf_text(f.image[:]))
	ours := false
	if image == "" {
		path, fitted, rendered, msg := upload_thumbnail_temp(app, p)
		if !rendered {
			set_status(&app.status, msg, false)
			return
		}
		image, ours = path, true
		// Say so rather than quietly publishing a different picture from the
		// one the venue was framed with.
		if fitted && p.shot.set {
			set_status(
				&app.status,
				"the saved view has none of the venue in it, so the whole road was framed instead",
				true,
			)
		}
	}

	upload_start(&app.uploader, p.id, Upload_Job{
		username    = strings.clone(strings.trim_space(buf_text(f.user[:]))),
		password    = strings.clone(buf_text(f.password[:])),
		title       = strings.clone(strings.trim_space(buf_text(f.title[:]))),
		description = strings.clone(buf_text(f.description[:])),
		changelog   = strings.clone(buf_text(f.changelog[:])),
		slug        = strings.clone(upload_slug(p.id)),
		level_path  = strings.clone(venue_path(p.id)),
		image_path  = strings.clone(image),
		image_ours  = ours,
	})
	// The job's clone is now the only copy: typed every time, kept no longer
	// than the request that uses it.
	f.password = {}
	set_status(&app.status, fmt.tprintf("uploading %s...", p.id), true)
}

// Render the thumbnail to a scratch file. The caller owns the path and deletes
// the file once the request that reads it has finished.
@(private = "file")
upload_thumbnail_temp :: proc(app: ^App, p: ^Venue) -> (path: string, fitted, ok: bool, msg: string) {
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		return "", false, false, "no temporary directory to render the thumbnail into"
	}
	joined, _ := filepath.join({dir, fmt.tprintf("dirtbench-%s.bmp", p.id)}, context.temp_allocator)
	used_fit, render_msg, rendered := thumbnail_render(app, p, joined)
	if !rendered {
		return "", used_fit, false, render_msg
	}
	return joined, used_fit, true, ""
}
