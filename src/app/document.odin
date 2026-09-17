package main

// The document: a venue, and every cache derived from it.
//
// One Venue_Doc per open venue, shared by every window looking at it. The
// caches — ribbon, road mesh, terrain mesh, vegetation — are rebuilt from the
// spline whenever a dirty flag is set, once per tick rather than once per
// window (see docs_rebuild in main.odin). Nothing here knows about a camera,
// a cursor or a window.

import "core:c"
import "../geo"
import "../gfx"

GROUND_Y :: 0.0

// How long a save/load result stays on screen, seconds.
STATUS_LINGER :: 8.0

// Global tessellation density: ribbon samples per spline segment. Also drives
// how many vertical rows a cliff face gets (see cliff_rows).
TOPO_MIN :: 2

TOPO_MAX :: 48

// The venue, and everything derived from it. One per open venue, shared by
// every window looking at it — which is what makes an edit in one window show
// up in the others with nothing to synchronise.
Venue_Doc :: struct {
	// Which venue is open, "" when it is a loose stage out of maps/. Saving
	// writes back to the venue.
	open_venue:    string,
	open_stage:    string,
	// The venue's stage list. It belongs to venue.json and is written back when
	// the road is saved. A view's `route_sel` indexes it.
	routes:        [dynamic]Venue_Route,
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
	topo:          c.int, // ribbon samples per spline segment
	roughness:     f32,   // global roughness: road vertical jitter + cliff jitter, 0..1

	// Pace notes, derived from the ribbon (pacenote.odin). Recomputed with the
	// road, since both are caches of the spline. These belong to a stage rather
	// than to a venue and move to the stage view once it exists; a branched
	// venue road produces none at all (see geo.is_linear).
	pace:          geo.Pace_Params,
	notes:         [dynamic]geo.Pace_Note,
	timing:        Timing_Params,

	// Vegetation scatter (vegetation.odin). Part of the document, handed to the
	// export target and drawn as placeholder shapes in the viewport.
	veg:           geo.Veg_Params,
	// The generated scatter, cached so it is drawn every frame but regenerated only
	// when a veg knob changes or the ribbon rebuilds — generating rebuilds the
	// terrain field, too costly per frame. Persistent-allocated; freed on shutdown.
	veg_cache:     []geo.Veg_Instance,
	veg_gen:       u64, // ribbon_gen the cache was built at; a mismatch forces a refresh
	veg_dirty:     bool,

	// ImGui edits this in place, so it is a fixed C string.
	stage_name:    [64]u8,
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

// Call after *any* mutation of the spline or of topo/roughness. The terrain is
// carved to the road — its inner edge is the verge seam — so a spline edit
// invalidates it too. Cheap: the rebuilds happen at the top of the next frame.
mark_dirty :: proc(doc: ^Venue_Doc) {
	doc.dirty_road = true
	doc.dirty_terrain = true
	doc.veg_dirty = true
}

// For edits that leave the ribbon alone: sculpt controls, terrain sliders. These
// still move the ground under the trees, so the scatter is stale too — but the
// ribbon_gen it keys on has not ticked, hence the explicit flag.
mark_terrain_dirty :: proc(doc: ^Venue_Doc) {
	doc.dirty_terrain = true
	doc.veg_dirty = true
}

geometry_stale :: proc(doc: ^Venue_Doc) -> bool {
	return doc.dirty_road || doc.dirty_terrain
}

// Clearing, not just freeing: the slice outlives the memory otherwise, and the
// next delete frees it a second time.
veg_cache_clear :: proc(doc: ^Venue_Doc) {
	delete(doc.veg_cache)
	doc.veg_cache = nil
}

// Resample the ribbon and re-upload whichever mesh went stale. The ribbon is
// kept because picking and the handle overlay both read it, and it is the input
// to both meshes.
//
// The terrain is several times the road's triangle count, so rebuilding it every
// frame of a control-point drag is the one thing that makes a big stage feel
// sluggish. Defer it: the road follows the gizmo live, the terrain snaps to it on
// release. Dragging a terrain control is exempt — the terrain is the only thing
// changing, and watching it move is the entire point.
//
// `dragging` is "some window is dragging a point gizmo", computed from last
// frame's state, which is what we want: the frame a drag ends it is already
// false, so the deferred rebuild lands immediately. Returns true when the
// control set was renumbered, because no view's node index survives that.
rebuild_geometry :: proc(doc: ^Venue_Doc, dragging := false) -> (controls_moved: bool) {
	if doc.dirty_road {
		delete(doc.ribbon)
		doc.ribbon = geo.build_ribbon(doc.spline, int(doc.topo), context.allocator)
		doc.ribbon_gen += 1
		geo.road_mesh_rebuild(&doc.road, doc.ribbon, doc.topo, doc.roughness)
		if geo.is_linear(doc.spline) {
			geo.pace_generate(doc.ribbon, doc.pace, &doc.notes)
		} else {
			clear(&doc.notes)
		}
		doc.dirty_road = false
	}
	if doc.dirty_terrain && !dragging {
		before := geo.terrain_node_count(&doc.terrain)
		geo.terrain_ensure(&doc.terrain, doc.ribbon, doc.topo, doc.roughness)
		controls_moved = geo.terrain_node_count(&doc.terrain) != before
		geo.terrain_mesh_rebuild(
			&doc.terrain_mesh, &doc.terrain_field, &doc.terrain,
			doc.ribbon, doc.topo, doc.roughness, doc.ribbon_gen,
		)
		doc.dirty_terrain = false
	}
	return
}

// Regenerate the vegetation cache when it is stale — a knob moved (`veg_dirty`)
// or the ribbon rebuilt under it (`veg_gen` behind `ribbon_gen`). A no-op
// otherwise, so it is safe to call every frame. Generating rebuilds the terrain
// field, which is why the result is cached rather than produced live.
veg_refresh :: proc(doc: ^Venue_Doc, dragging := false) {
	if !doc.veg_dirty && doc.veg_gen == doc.ribbon_gen {
		return
	}
	// Generating rebuilds the terrain field, so defer while a gizmo drags — the
	// trees snap to the new ground on release, the same way the terrain mesh does
	// for a point drag. `dragging` is last frame's value, so the release frame
	// lands the rebuild.
	if dragging {
		return
	}
	veg_cache_clear(doc)
	doc.veg_cache = geo.veg_generate(doc.ribbon, &doc.terrain, doc.veg, doc.topo, doc.roughness)
	doc.veg_gen = doc.ribbon_gen
	doc.veg_dirty = false
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

// The stage name as ImGui left it in the buffer: NUL-terminated, unsanitised.
stage_name_text :: proc(doc: ^Venue_Doc) -> string {
	return buf_text(doc.stage_name[:])
}

set_stage_name :: proc(doc: ^Venue_Doc, name: string) {
	set_buf(doc.stage_name[:], name)
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
		append(&sp.points, geo.make_point(pos, rot, geo.DEFAULT_WIDTH, parent = i - 1))
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
		topo = geo.SAMPLES_PER_SEG,
		roughness = 0.5,
		terrain = geo.TERRAIN_DEFAULTS,
		pace = geo.PACE_DEFAULTS,
		timing = TIMING_DEFAULTS,
		veg = geo.VEG_DEFAULTS,
	}
}
