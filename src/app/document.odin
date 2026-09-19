package main

// The document: a venue, and every cache derived from it.
//
// One Venue_Doc per open venue, shared by every window looking at it. The
// caches — ribbon, road mesh, terrain mesh, vegetation — are rebuilt from the
// spline whenever a dirty flag is set, once per tick rather than once per
// window (see docs_rebuild in main.odin). Nothing here knows about a camera,
// a cursor or a window.

import "core:strings"
import "../geo"
import "../gfx"

GROUND_Y :: 0.0

// How long a save/load result stays on screen, seconds.
STATUS_LINGER :: 8.0

// The venue, and everything derived from it. One per open venue, shared by
// every window looking at it — which is what makes an edit in one window show
// up in the others with nothing to synchronise.
Venue_Doc :: struct {
	// Which venue is open, "" when it is a loose stage out of maps/. Saving
	// writes back to the venue. Which *stage* is not here: a document is the
	// whole road graph, and the window (or the headless command) says which
	// stage of it is being looked at or exported.
	open_venue:    string,
	// The venue's name at the moment it was opened. The file it saves back to
	// is named for it, and so is everything shown about it, neither of which
	// the id can answer. A rename updates it here as well as on disk.
	venue_name:    string,
	// The stock venue this one derives its art from, "<location>/<venue>", or ""
	// for a loose stage. The prop libraries are read out of it, and the tree
	// species come off it too (geo.veg_preset_for_base).
	base:          string,
	// The venue's stage list. It belongs to venue.json and is written back when
	// the road is saved. The project manager edits it here while a window has
	// the venue open; a stage window's `route_sel` indexes it.
	routes:        [dynamic]Venue_Route,
	// Travels with `routes`: the list alone cannot say which ids are retired.
	next_route:    int,
	// How this venue's thumbnail is framed (Venue_Shot). Edited here while a
	// window is open and written back with the road, exactly like `routes`.
	shot:          Venue_Shot,
	spline:        geo.Spline,
	// The one scan of the game install, borrowed. The app owns it and every
	// document reads the same one, so a rescan in any window is seen by all of
	// them. Headless CLI paths point this at a local.
	install:       ^Install_Scan,
	gen:           Gen_Params,
	gen_live:      bool, // regenerate while a slider is being dragged
	debug_export:  bool, // write to out/ instead of into the game (export.odin)

	// Geometry. `ribbon`, `road` and `terrain_mesh` are caches rebuilt from
	// `spline` (and `terrain`) whenever `dirty` is set — never read them without
	// going through mark_dirty/rebuild.
	ribbon:        []geo.Cross_Section,
	// Ticks on every ribbon rebuild. The terrain's world grid is keyed on it, so
	// dragging a terrain control reuses the grid instead of rebuilding it.
	ribbon_gen:    u64,
	road:          geo.Gpu_Mesh,
	terrain:       geo.Terrain,
	terrain_field: geo.Terrain_Field,
	terrain_mesh:  geo.Gpu_Mesh,
	material:      gfx.Material,
	// Two flags, not one: the road is cheap to rebuild and the terrain is not.
	dirty_road:    bool,
	dirty_terrain: bool,
	// Every change to a saved field ticks this. The dirty flags above cannot
	// stand in for it: a rebuild clears them every frame. An edit that does not
	// call mark_dirty must call mark_edited.
	edits:         u64,
	saved_edits:   u64, // `edits` when this was last written home
	snapshot_edits: u64, // `edits` when the crash snapshot was last written
	// Baseline road/cliff jitter, 0..1. Held at zero: the game roughens each
	// surface itself. Per-point offsets are the only way to add any.
	roughness:     f32,

	// How the co-driver calls a corner. The knobs are the venue's, because they
	// describe the calling and not the stage being called; the notes themselves
	// live on the window, generated from its compiled stage (Stage_Cache).
	pace:          geo.Pace_Params,
	timing:        Timing_Params,

	// Vegetation scatter (vegetation.odin). Part of the document, handed to the
	// export target and drawn as placeholder shapes in the viewport.
	veg:           geo.Veg_Params,
	// The generated scatter, cached so it is drawn every frame but regenerated only
	// when a veg knob changes or the ribbon rebuilds — generating rebuilds the
	// terrain field, too costly per frame. Persistent-allocated; freed on shutdown.
	veg_cache:     []geo.Veg_Instance,
	// The same scatter as a mesh, uploaded once per rebuild. The trees are far too
	// many vertices for the frame's overlay batch, which handles and nodes share.
	veg_mesh:      geo.Gpu_Mesh,
	veg_gen:       u64, // ribbon_gen the cache was built at; a mismatch forces a refresh
	veg_dirty:     bool,
	// The card billboards (billboards.odin), regenerated on the same tick as the
	// scatter. Sizes come off the venue's art when that has been
	// read and off geo's nominal pair when it has not, so the preview can be the
	// right shape in the wrong size. The export never uses these.
	card_cache:    []geo.Billboard_Card,
	card_mesh:     geo.Gpu_Mesh,

	// Props placed by hand (props.odin). Saved with the road; drawn from the
	// base venue's own libraries, which `venue_art` parses on first ask.
	props:         [dynamic]Prop_Instance,
	venue_art:     Venue_Art,

	// ImGui edits this in place, so it is a fixed C string.
	stage_name:    [64]u8,

	// The worker that rebuilds all of the above, and the job in its hands.
	// Interactive windows go through it (rebuild.odin); the CLI and the tests
	// call rebuild_geometry below and never start a thread.
	rebuild:       Rebuilder,
}

// The last save/load/export result, shown for STATUS_LINGER seconds. One per
// window: a message belongs to the window whose action produced it.
Status :: struct {
	// Copied, because the messages come off the temp allocator, which is reset
	// every frame.
	text: [256]u8,
	ok:   bool,
	at:   f64, // gfx.GetTime() when set
}

// --- geometry cache ---------------------------------------------------------

// Call after *any* mutation of the spline or of roughness. The terrain is
// carved to the road — its inner edge is the verge seam — so a spline edit
// invalidates it too. Cheap: the rebuilds happen at the top of the next frame.
mark_dirty :: proc(doc: ^Venue_Doc) {
	doc.dirty_road = true
	doc.dirty_terrain = true
	doc.veg_dirty = true
	doc.edits += 1
}

// A vegetation knob: the scatter is regenerated, the road is not.
mark_veg_dirty :: proc(doc: ^Venue_Doc) {
	doc.veg_dirty = true
	doc.edits += 1
}

// An edit with nothing to rebuild: a marker, a pin, a stage name, a timing
// number. Nothing in the viewport changes, but the file on disk is now behind.
mark_edited :: proc(doc: ^Venue_Doc) {
	doc.edits += 1
}

// Whether anything has changed since the last save home.
doc_unsaved :: proc(doc: ^Venue_Doc) -> bool {
	return doc.edits != doc.saved_edits
}

// The document came off disk, so nothing in it is unsaved yet. Loading ticks
// `edits` on its way through mark_dirty, which is why this is not simply zero.
doc_loaded :: proc(doc: ^Venue_Doc) {
	doc.saved_edits = doc.edits
	doc.snapshot_edits = 0
}

// The document is on disk again. Its crash snapshot is stale from here, which
// recovery_doc_saved acts on — nothing in this file knows that folder exists.
doc_saved :: proc(doc: ^Venue_Doc) {
	doc.saved_edits = doc.edits
	doc.snapshot_edits = 0
}

// For edits that leave the ribbon alone: sculpt controls, terrain sliders. These
// still move the ground under the trees, so the scatter is stale too — but the
// ribbon_gen it keys on has not ticked, hence the explicit flag.
mark_terrain_dirty :: proc(doc: ^Venue_Doc) {
	doc.dirty_terrain = true
	doc.veg_dirty = true
	doc.edits += 1
}

// Clearing, not just freeing: the slice outlives the memory otherwise, and the
// next delete frees it a second time.
veg_cache_clear :: proc(doc: ^Venue_Doc) {
	delete(doc.veg_cache)
	doc.veg_cache = nil
	geo.gpu_mesh_unload(&doc.veg_mesh)
	delete(doc.card_cache)
	doc.card_cache = nil
	geo.gpu_mesh_unload(&doc.card_mesh)
}

// Resample the ribbon and re-upload whichever mesh went stale, here and now.
// The ribbon is kept because picking and the handle overlay both read it, and it
// is the input to both meshes.
//
// This is the blocking rebuild. An editor window never calls it — its document's
// worker does the same work off the frame (rebuild.odin) — so what is left is
// the export path, which needs the geometry correct before it reads it, and
// anything headless. `dragging` skips the terrain half, the way the worker does
// while a point gizmo is held. Returns true when the control set was renumbered,
// because no view's node index survives that.
rebuild_geometry :: proc(doc: ^Venue_Doc, dragging := false) -> (controls_moved: bool) {
	if doc.dirty_road {
		delete(doc.ribbon)
		doc.ribbon = geo.build_ribbon(doc.spline, allocator = context.allocator)
		doc.ribbon_gen += 1
		geo.road_mesh_rebuild(&doc.road, doc.ribbon, doc.roughness)
		doc.dirty_road = false
	}
	if doc.dirty_terrain && !dragging {
		before := geo.terrain_node_count(&doc.terrain)
		geo.terrain_ensure(&doc.terrain, doc.ribbon, doc.roughness)
		controls_moved = geo.terrain_node_count(&doc.terrain) != before
		geo.terrain_mesh_rebuild(
			&doc.terrain_mesh, &doc.terrain_field, &doc.terrain,
			doc.ribbon, doc.roughness, doc.ribbon_gen,
		)
		doc.dirty_terrain = false
	}
	return
}

// --- status line ------------------------------------------------------------

// ImGui edits a name in place, so every name the editor shows it is a fixed
// byte buffer rather than a string. These two are the only way in and out.
set_buf :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
}

buf_text :: proc(buf: []u8) -> string {
	return string(cstring(raw_data(buf)))
}

set_status :: proc(s: ^Status, msg: string, ok: bool) {
	set_buf(s.text[:], msg)
	s.ok = ok
	s.at = gfx.GetTime()
}

status_text :: proc(s: ^Status) -> (text: cstring, ok: bool) {
	if s.text[0] == 0 || gfx.GetTime() - s.at > STATUS_LINGER {
		return nil, false
	}
	return cstring(raw_data(s.text[:])), true
}

set_stage_name :: proc(doc: ^Venue_Doc, name: string) {
	set_buf(doc.stage_name[:], name)
}

// Point the document at the stock venue it derives its art from. Both things
// that art decides are set here: the tree species of the scatter, and where the
// prop libraries are read from.
doc_set_base :: proc(doc: ^Venue_Doc, base: string) {
	if doc.base != base {
		venue_art_free(doc) // this art belongs to the old base
	}
	delete(doc.base)
	doc.base = strings.clone(base)
	doc.veg.preset = geo.veg_preset_for_base(base)
}

// Grow the road at `g`. With a point selected the new node is its child, which
// is a branch when that point already had one. With no selection it appends to
// the tail, the old behaviour.
grow_road :: proc(sp: ^geo.Spline, from: int, g: gfx.Vector3) -> int {
	if from < 0 || from >= len(sp.points) {
		return geo.append_point(sp, g)
	}
	idx := geo.extrude_point(sp, from)
	if idx < 0 || idx >= len(sp.points) {
		return idx
	}
	p := &sp.points[idx]
	p.xform.translation = g
	// Extruding the head grows backwards, so that node is aimed at its child
	// instead of away from a parent it does not have.
	if p.parent >= 0 {
		p.xform.rotation = geo.heading_quat(sp.points[p.parent].xform.translation, g)
	} else if child := geo.first_child(sp^, idx); child >= 0 {
		p.xform.rotation = geo.heading_quat(g, sp.points[child].xform.translation)
	}
	return idx
}

// --- road edits ---------------------------------------------------------------

seed_spline :: proc(sp: ^geo.Spline) {
	clear(&sp.points)
	// a short starter road with a rise and a gentle bend to show it off
	seeds := [?]gfx.Vector3{{0, 0, 0}, {0, 2, 32}, {12, 5, 60}, {26, 6, 88}}
	for pos, i in seeds {
		rot := gfx.Quaternion(1)
		if i > 0 {
			rot = geo.heading_quat(seeds[i - 1], pos)
		}
		geo.spline_push(sp, geo.make_point(pos, rot, geo.DEFAULT_WIDTH, parent = i - 1))
	}
	if len(sp.points) > 1 {
		sp.points[0].xform.rotation = sp.points[1].xform.rotation
	}
}

// Sensible knobs for a fresh document. Not a constant, because the terrain and
// the route list own allocations that must not be shared between documents.
doc_defaults :: proc() -> Venue_Doc {
	return Venue_Doc{
		gen = GEN_DEFAULTS,
		gen_live = true,
		// The game adds its own per-surface roughness, and every stock track is
		// geometrically smooth, so the baseline is flat. Per-point offsets still
		// add on top (see geo: eff = global + cs.roughness).
		roughness = 0,
		terrain = geo.TERRAIN_DEFAULTS,
		pace = geo.PACE_DEFAULTS,
		timing = TIMING_DEFAULTS,
		veg = geo.VEG_DEFAULTS,
	}
}
