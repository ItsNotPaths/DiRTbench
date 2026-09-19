package main

// dirtbench — a DiRT 3 rally road editor.
//
// The process. One project-manager window (venues_ui.odin), one scan of the
// game install, and the windows opened from it: a venue's road network, and one
// per stage of that venue. Picking the world comes before drawing a road in it.
//
// One process rather than one per venue, because a stage window has to see its
// venue's live terrain, and that is free when the windows share a document and
// expensive when they do not. Documents live in document.odin, windows in
// view.odin, and what a window draws in scene.odin.

import "core:fmt"
import "../geo"
import "../ui"
import "../gfx"

WINDOW_W :: 1280

WINDOW_H :: 800

PROJECT_MANAGER_W :: 560

PROJECT_MANAGER_H :: 720

// The process. One project-manager window, one scan of the game install, and
// however many venue editors are open over it. Everything in here is shared;
// everything per-venue is in Editor.
App :: struct {
	window:  gfx.Window,
	imgui:   rawptr,
	install: Install_Scan,
	screen:  Venues_Screen,
	editors: [dynamic]^Editor,
	// One document per open venue, shared by every window onto it.
	docs:    [dynamic]^Venue_Doc,
	// The window a button asked to open, serviced between frames. See
	// app_service_open_request for why it cannot happen inside one.
	open_request: Open_Request,
	// The venue whose Upload button was pressed, serviced between frames for
	// the same reason: the thumbnail render draws a scene of its own.
	upload_request: [64]u8,
	// The one upload in flight, and the last one's answer (upload.odin).
	uploader: Uploader,
	// The browse panel's one request in flight, and the listing on screen
	// (browse.odin).
	browser: Browser,
	status:  Status,
	show_demo: bool,
	quit:    bool,
	// Crash recovery (recovery.odin): when the next snapshot is due, and what
	// the last run left behind.
	recovery_at:  f64,
	recovery:     []Recovery_Set,
	// One audio device per process, so one clip bank and one playback queue.
	// Whichever window starts a ride preview owns them until it stops.
	clips:        map[string]gfx.Sound, // basename -> decoded OGG
	play_q:       [dynamic]gfx.Sound,   // clips to play back-to-back
	play_i:       int,
	play_started: bool,
}

// Which window a project-manager button asked for: a venue's road graph, or
// one stage of it. Buffers rather than strings, because the venue list is
// reloaded between the click and the open and a borrowed id would dangle.
Open_Request :: struct {
	venue: [64]u8,
	stage: [64]u8, // "" opens the road-network window
}

// A fresh document, with its GPU geometry. Its window comes separately: the
// document outlives any one window onto it.
doc_new :: proc(app: ^App) -> ^Venue_Doc {
	doc := new(Venue_Doc)
	doc^ = doc_defaults()
	doc.install = &app.install
	doc.material = gfx.LoadMaterialDefault()
	set_stage_name(doc, "untitled")
	seed_spline(&doc.spline)
	mark_dirty(doc)
	return doc
}

// Free what the document owns, including its GPU meshes. Takes a pointer rather
// than owning the box, so a headless caller can put a document on the stack.
doc_delete :: proc(doc: ^Venue_Doc) {
	// Before anything it reads is freed.
	rebuild_stop(doc)
	gfx.UnloadMaterial(doc.material)
	geo.gpu_mesh_unload(&doc.road)
	geo.gpu_mesh_unload(&doc.terrain_mesh)
	geo.terrain_delete(&doc.terrain)
	geo.terrain_field_delete(&doc.terrain_field)
	delete(doc.ribbon)
	veg_cache_clear(doc)
	geo.spline_free(&doc.spline)
	delete(doc.open_venue)
	delete(doc.venue_name)
	delete(doc.base)
	props_free(doc)
	venue_art_free(doc)
	routes_free(&doc.routes)
}

// This window's own allocations. The document is not one of them.
view_delete :: proc(ed: ^Editor) {
	delete(ed.terrain_brush_mask)
	delete(ed.terrain_brush_offsets)
	delete(ed.road_brush_weight)
	delete(ed.road_brush_snap)
	delete(ed.floor_draw)
	delete(ed.stage_id)
	for role in Prop_Role {
		prop_preview_clear(&ed.prop_browse[role].preview)
	}
	stage_cache_clear(ed)
}

editor_window_open :: proc(ed: ^Editor, title: cstring) -> bool {
	if !gfx.CreateWindow(&ed.window, WINDOW_W, WINDOW_H, title) {
		return false
	}
	ctx := ui.imgui_backend_setup(
		true, gfx.NativeWindow(&ed.window), gfx.GpuDevice(), gfx.WindowSwapchainFormat(&ed.window),
	)
	if ctx == nil {
		gfx.DestroyWindow(&ed.window)
		return false
	}
	gfx.SetWindowImGui(&ed.window, ctx)
	// Only the project manager saves a layout. Every context writing the same
	// .ini means the last window closed decides where all of them sit.
	ui.imgui_backend_set_ini(ctx, nil)
	ed.imgui = ctx
	return true
}

// Drop `ed` from the window list, and its document from the document list when
// no other window is left on it. Returns the document to free, or nil.
//
// The removal has to happen before the survivor scan, or the scan reads the
// entry belonging to the window being closed. Split out from editor_close so
// this can be tested without a GPU.
editors_detach :: proc(app: ^App, ed: ^Editor) -> ^Venue_Doc {
	doc := ed.doc
	for e, i in app.editors {
		if e == ed {
			unordered_remove(&app.editors, i)
			break
		}
	}
	for other in app.editors {
		if other.doc == doc {
			return nil
		}
	}
	for d, i in app.docs {
		if d == doc {
			unordered_remove(&app.docs, i)
			break
		}
	}
	return doc
}

// Close one window and free it. The document goes too, once no other window is
// looking at it — it holds the meshes, which are the largest thing here.
editor_close :: proc(app: ^App, ed: ^Editor) {
	if ed.previewing {
		preview_stop(ed) // the ride owns the one audio device until it ends
	}
	orphan := editors_detach(app, ed)
	view_delete(ed)
	if ed.imgui != nil {
		ui.imgui_backend_shutdown(ed.imgui)
	}
	gfx.DestroyWindow(&ed.window)
	free(ed)
	if orphan != nil {
		doc_delete(orphan)
		free(orphan)
	}
}

main :: proc() {
	if run_cli() {
		return
	}
	app := App{}
	if !gfx.CreateWindow(&app.window, PROJECT_MANAGER_W, PROJECT_MANAGER_H, "dirtbench — project manager") {
		fmt.println("could not create SDL window")
		return
	}
	defer gfx.DestroyWindow(&app.window)
	// Process-wide in the renderer, so this covers every window opened later.
	gfx.SetClipPlanes(CAM_NEAR, CAM_FAR)

	app.imgui = ui.imgui_backend_setup(
		true, gfx.NativeWindow(&app.window), gfx.GpuDevice(), gfx.WindowSwapchainFormat(&app.window),
	)
	if app.imgui == nil {
		fmt.println("could not initialize Dear ImGui")
		return
	}
	gfx.SetWindowImGui(&app.window, app.imgui)
	defer ui.imgui_backend_shutdown(app.imgui)

	// One audio device and one clip bank for the process. Decoding the pace-note
	// clips again per editor window would be the same bytes three times over.
	gfx.InitAudioDevice()
	defer gfx.CloseAudioDevice()
	gfx.SetMasterVolume(1.0)
	app.clips = pace_audio_load()
	defer pace_audio_unload(&app.clips)
	app.play_q = make([dynamic]gfx.Sound)
	defer delete(app.play_q)

	// Anything the last run left behind is claimed before the first frame, so
	// the project manager's first draw already shows it.
	recovery_promote(recovery_root())
	app.recovery = recovery_pending(recovery_root())
	defer recovery_pending_delete(app.recovery)

	install_scan_init(&app.install)
	defer install_scan_delete(&app.install)
	defer uploader_delete(&app.uploader)
	defer browser_delete(&app.browser)
	venues_screen_init(&app.screen)
	defer venues_screen_delete(&app.screen)
	// Defers run last-first, so the delete is written above the loop that has
	// to run before it. Written the other way round, the loop walks the freed
	// array and closes garbage.
	defer delete(app.editors)
	defer delete(app.docs)
	defer for len(app.editors) > 0 {
		editor_close(&app, app.editors[len(app.editors) - 1])
	}

	for !gfx.WindowShouldClose(&app.window) && !app.quit {
		gfx.PollWindowEvents()
		venues_editors_reap(&app)
		draw_venues_frame(&app)
		app_service_open_request(&app)
		app_service_upload_request(&app)
		docs_rebuild(&app)
		for ed in app.editors {
			editor_frame(ed)
		}
		app_recovery_tick(&app)
		free_all(context.temp_allocator)
	}
	// A run that ends on its own clears its snapshots. A folder left behind is
	// therefore a run that did not.
	recovery_clear_live(recovery_root())
	free_all(context.temp_allocator)
}

// The crash snapshot on its timer. The clock and the document list belong to the
// loop; recovery.odin knows documents and folders, not the app that holds them.
app_recovery_tick :: proc(app: ^App) {
	now := gfx.GetTime()
	if now < app.recovery_at {
		return
	}
	app.recovery_at = now + RECOVERY_INTERVAL
	recovery_snapshot(recovery_root(), app.docs[:])
}

// Re-read what is set aside. Every answer to a recovery row goes through this,
// so the rows are never a memory of what the folder used to hold.
app_recovery_reload :: proc(app: ^App) {
	recovery_pending_delete(app.recovery)
	app.recovery = recovery_pending(recovery_root())
}

// Whether any window onto this document is mid-drag, and whether any of those
// drags is moving a road point. Both deferral tests read these: a drag in one
// window must not have its terrain rebuilt out from under it by another
// window's frame.
doc_drag_state :: proc(app: ^App, doc: ^Venue_Doc) -> (dragging, point_drag: bool) {
	for ed in app.editors {
		if ed.doc != doc || !ed.gizmo_active {
			continue
		}
		dragging = true
		point_drag ||= ed.sel.kind == .Point
	}
	return
}

// No window's node index survives a renumbering of the control set.
clear_node_selections :: proc(app: ^App, doc: ^Venue_Doc) {
	for ed in app.editors {
		if ed.doc == doc && ed.sel.kind == .Node {
			ed.sel = {}
			terrain_brush_clear(ed)
		}
	}
}

// One rebuild per document per tick, not one per window. This is the whole
// mechanism behind live update: two windows onto a venue read the same meshes,
// so an edit in either appears in both with nothing to synchronise.
//
// The rebuild itself runs on the document's worker (rebuild.odin). All that
// happens here is landing whatever it finished and handing it the next job, so a
// slow venue costs this loop a mesh upload rather than the whole rebuild.
docs_rebuild :: proc(app: ^App) {
	for doc in app.docs {
		dragging, point_drag := doc_drag_state(app, doc)
		if rebuild_tick(doc, dragging, point_drag) {
			clear_node_selections(app, doc)
		}
	}
}
