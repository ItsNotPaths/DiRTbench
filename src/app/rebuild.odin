package main

// The geometry rebuild, off the main thread.
//
// Resampling the ribbon, triangulating the terrain field and scattering the
// trees take long enough that doing them inside the frame stalls the panels and
// the camera with them. One worker per document does that work instead: the main
// thread copies what the job reads, hands it over, and goes on drawing. A
// finished job lands at the top of a later frame, which is where the GPU uploads
// happen — those have to be on this thread.
//
// What the worker touches is its own. The spline and the terrain controls are
// copied in, because the main thread reads and writes them every frame. The
// terrain field is moved in and moved back, because nothing outside a rebuild
// ever reads it. The document's ribbon is borrowed read-only, and only
// rebuild_land ever replaces it.
//
// rebuild_geometry (document.odin) is still the synchronous path, and is still
// what the CLI, the exporter and the tests use.
//
// --- the preview pass ---
//
// The ground is by far the slowest of the three, and nearly all of that is the
// interior point set: its cost goes as 1/cell^2. So a stage whose ground takes
// longer than PREVIEW_MIN_MS gets a coarse pass first, at PREVIEW_CELL times the
// cell, landed as soon as it is ready; the full-resolution pass follows on the
// next dispatch. Keep editing and you keep getting coarse ground, and the fine
// one arrives once you stop.
//
// A preview is *only* what is drawn. It never touches the document's own field —
// the exporter, the picking and the scatter all read that, and it stays at full
// resolution throughout — and it never derives the sculpt controls, which belong
// to the document's cell and not to this pass's. Nothing a preview produces can
// reach a deployed route.

import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import "../geo"

// One document's worker and the job in its hands. See handoff.odin for the
// rule `state` enforces.
Rebuilder :: struct {
	worker: ^thread.Thread,
	wake:   sync.Sema,
	state:  Handoff_State,
	stop:   bool,
	job:    Rebuild_Job,
	// The coarse pass's own field, kept across previews so a pure sculpt change
	// re-evaluates its heights instead of rebuilding it. Never the document's.
	preview_field: geo.Terrain_Field,
	// How long the last full-resolution ground took. Nothing is previewed until
	// one has been timed, so a stage that rebuilds quickly never flickers.
	ground_ms:     f64,
}

// The coarse pass's cell, as a multiple of the document's. Three is about a
// ninth of the interior points and still reads as the same landscape: the rim
// is every ribbon sample either way, so the road edge is exact in both.
PREVIEW_CELL :: f32(3)
PREVIEW_MIN_MS :: 80.0

// The rebuild, in and out. The input half is filled at dispatch, the output half
// by the worker, and rebuild_land swaps the output into the document.
Rebuild_Job :: struct {
	spline:     geo.Spline,          // copy, freed on landing
	terrain:    geo.Terrain,         // copy; the worker may renumber its controls
	veg_params: geo.Veg_Params,
	roughness:  f32,
	look:       geo.Look, // the venue's editor colours; see Venue_Doc.look
	ribbon_gen: u64,                 // what the rebuilt ribbon is numbered
	held:       []geo.Cross_Section, // the document's ribbon, borrowed when the road is not rebuilt
	do_road:    bool,
	do_ground:  bool,
	do_veg:     bool,
	// Coarse ground only: no controls derived, no scatter, and the field that
	// comes back is the rebuilder's rather than the document's.
	preview:    bool,
	// The document's control set as it stood at dispatch. A document that has
	// moved on from this — a load, a regenerate, a flatten — must not have the
	// job's copy written back over it. See rebuild_land.
	base_gen:   u64,
	base_count: int,

	ribbon:      []geo.Cross_Section,
	road_mesh:   geo.Tri_Mesh,
	field:       geo.Terrain_Field, // moved in, moved back
	ground_mesh: geo.Tri_Mesh,
	ground_ms:   f64, // the full-resolution ground's cost, for the preview gate
	veg:         []geo.Veg_Instance,
	veg_mesh:    geo.Tri_Mesh,
	card_kinds:  [geo.Billboard_Tier][]geo.Billboard_Kind, // borrowed; the venue art outlives the job
	cards:       []geo.Billboard_Card,
	card_mesh:   geo.Tri_Mesh,
}

// --- the main thread ---------------------------------------------------------

// Land a finished job, then start the next one. Returns true when the control
// set was renumbered, because no view's node index survives that.
rebuild_tick :: proc(doc: ^Venue_Doc, dragging, point_drag: bool) -> (controls_moved: bool) {
	r := &doc.rebuild
	if sync.atomic_load(&r.state) == .Done {
		controls_moved = rebuild_land(doc)
	}
	if sync.atomic_load(&r.state) == .Idle {
		rebuild_dispatch(doc, dragging, point_drag)
	}
	return
}

// Wait for the worker and take whatever it has. Everything that needs the
// document's geometry current and correct right now — an export, a close, a load
// that replaces the spline — goes through this first.
rebuild_join :: proc(doc: ^Venue_Doc) {
	r := &doc.rebuild
	for sync.atomic_load(&r.state) == .Running {
		thread.yield()
	}
	if sync.atomic_load(&r.state) == .Done {
		rebuild_land(doc)
	}
}

// End the worker. Called from doc_delete, so a document never outlives a thread
// reading it.
rebuild_stop :: proc(doc: ^Venue_Doc) {
	r := &doc.rebuild
	// Deferred, so a document that never grew a worker still frees it.
	defer {
		geo.terrain_field_delete(&r.preview_field)
		r.preview_field = {}
	}
	if r.worker == nil {
		return
	}
	rebuild_join(doc)
	sync.atomic_store(&r.stop, true)
	sync.sema_post(&r.wake)
	thread.join(r.worker)
	thread.destroy(r.worker)
	r.worker = nil
}

// The field a job trades with: a preview swaps the rebuilder's own, everything
// else the document's. Dispatch takes from here and landing returns to here.
job_field :: proc(doc: ^Venue_Doc, preview: bool) -> ^geo.Terrain_Field {
	return preview ? &doc.rebuild.preview_field : &doc.terrain_field
}

// What is stale, copied, and handed over. The deferral rules are the
// synchronous path's: the terrain waits out a point drag because the road has to
// follow the gizmo live, and the scatter waits out any drag at all.
rebuild_dispatch :: proc(doc: ^Venue_Doc, dragging, point_drag: bool) {
	r := &doc.rebuild
	ground := doc.dirty_terrain && !point_drag
	// Coarse first, and only once per edit: clearing `preview_due` while leaving
	// `dirty_terrain` set is what makes the next dispatch the full-resolution one.
	preview := ground && doc.terrain_preview_due && r.ground_ms >= PREVIEW_MIN_MS
	veg := !preview && !dragging && (doc.veg_dirty || doc.veg_gen != doc.ribbon_gen || doc.dirty_road)
	if !doc.dirty_road && !ground && !veg {
		return
	}
	// The row_m clamp is the slider's, not the rebuild's, so it stays here.
	geo.terrain_ensure(&doc.terrain, doc.ribbon, doc.roughness)

	r.job = Rebuild_Job {
		spline     = spline_snapshot(doc.spline),
		terrain    = terrain_snapshot(doc.terrain),
		veg_params = doc.veg,
		card_kinds = venue_art_card_kinds(doc),
		roughness  = doc.roughness,
		look       = doc.look,
		ribbon_gen = doc.ribbon_gen + (doc.dirty_road ? 1 : 0),
		held       = doc.ribbon,
		do_road    = doc.dirty_road,
		do_ground  = ground,
		do_veg     = veg,
		preview    = preview,
		base_gen   = doc.terrain.controls_gen,
		base_count = len(doc.terrain.controls),
	}
	// A preview leaves the document's field where it is, so picking and the
	// exporter keep reading full-resolution ground while the coarse one draws.
	home := job_field(doc, preview)
	r.job.field = home^
	home^ = {}
	// Cleared here, not on landing: an edit made while the job runs re-sets them,
	// and the next tick dispatches again on top of the result.
	doc.dirty_road = false
	if preview {
		doc.terrain_preview_due = false
	} else if ground {
		doc.dirty_terrain = false
	}
	if veg {
		doc.veg_dirty = false
	}

	rebuild_worker_start(doc)
	sync.atomic_store(&r.state, Handoff_State.Running)
	sync.sema_post(&r.wake)
}

// Swap the result into the document and upload the two meshes.
rebuild_land :: proc(doc: ^Venue_Doc) -> (controls_moved: bool) {
	r := &doc.rebuild
	j := &r.job

	if j.do_road {
		delete(doc.ribbon)
		doc.ribbon = j.ribbon
		doc.ribbon_gen = j.ribbon_gen
		geo.gpu_mesh_unload(&doc.road)
		doc.road = geo.gpu_mesh_upload(j.road_mesh)
	}
	home := job_field(doc, j.preview)
	geo.terrain_field_delete(home)
	home^ = j.field

	if j.do_ground {
		if !j.preview {
			controls_moved = rebuild_land_controls(doc, j)
			r.ground_ms = j.ground_ms
		}
		geo.gpu_mesh_unload(&doc.terrain_mesh)
		doc.terrain_mesh = geo.gpu_mesh_upload(j.ground_mesh)
	}
	if j.do_veg {
		veg_cache_clear(doc)
		doc.veg_cache = j.veg
		doc.veg_mesh = geo.gpu_mesh_upload(j.veg_mesh)
		doc.card_cache = j.cards
		doc.card_mesh = geo.gpu_mesh_upload(j.card_mesh)
		doc.veg_gen = j.ribbon_gen
	}

	geo.tri_mesh_delete(&j.road_mesh)
	geo.tri_mesh_delete(&j.ground_mesh)
	geo.tri_mesh_delete(&j.veg_mesh)
	geo.tri_mesh_delete(&j.card_mesh)
	geo.spline_free(&j.spline)
	delete(j.terrain.controls)
	geo.floors_delete(&j.terrain)
	j^ = {}
	sync.atomic_store(&r.state, Handoff_State.Idle)
	return
}

// Whose control set wins.
//
// The controls carry the sculpt offsets, and the brush writes those every frame
// of a drag, so a job's copy of them is only ever authoritative when the job is
// what produced the set. Three cases: the document moved on under the job and
// the job is thrown away; the job renumbered the set and owns it; or neither,
// and the live set stands untouched.
rebuild_land_controls :: proc(doc: ^Venue_Doc, j: ^Rebuild_Job) -> (moved: bool) {
	t := &doc.terrain
	if t.controls_gen != j.base_gen || len(t.controls) != j.base_count {
		// A load or a regenerate landed while the job ran. Its ground is of the
		// old sculpt, so ask for another.
		doc.dirty_terrain = true
		doc.veg_dirty = true
		return
	}
	if j.terrain.controls_gen == j.base_gen && len(j.terrain.controls) == j.base_count {
		return // the worker reused the set; the live offsets are the newer ones
	}
	delete(t.controls)
	t.controls = j.terrain.controls
	t.controls_gen = j.terrain.controls_gen
	t.controls_reach = j.terrain.controls_reach
	t.controls_cell = j.terrain.controls_cell
	t.controls_spacing = j.terrain.controls_spacing
	j.terrain.controls = nil
	return true
}

// The live control set copied exactly — offsets, signature and all.
//
// Not geo.terrain_clone, which drops the untouched controls and clears the
// signature. The worker has to see the same set the document has, or every frame
// of a sculpt re-derives the controls and re-triangulates the field behind them.
terrain_snapshot :: proc(t: geo.Terrain) -> (out: geo.Terrain) {
	out = t
	out.controls = slice.clone_to_dynamic(t.controls[:])
	geo.floors_copy(&out, t)
	return
}

spline_snapshot :: proc(sp: geo.Spline) -> geo.Spline {
	return {
		points = slice.clone_to_dynamic(sp.points[:]),
		guards = slice.clone_to_dynamic(sp.guards[:]),
		next_id = sp.next_id,
		next_guard_id = sp.next_guard_id,
	}
}

// --- the worker --------------------------------------------------------------

// Started on the first dispatch. A headless document never dispatches, so it
// never grows a thread.
rebuild_worker_start :: proc(doc: ^Venue_Doc) {
	r := &doc.rebuild
	if r.worker != nil {
		return
	}
	r.worker = thread.create(rebuild_worker)
	r.worker.data = doc
	thread.start(r.worker)
}

rebuild_worker :: proc(t: ^thread.Thread) {
	doc := (^Venue_Doc)(t.data)
	r := &doc.rebuild
	for {
		sync.sema_wait(&r.wake)
		if sync.atomic_load(&r.stop) {
			return
		}
		rebuild_job_run(&r.job)
		// This thread's own arena. The frame loop's free_all cannot reach it.
		free_all(context.temp_allocator)
		sync.atomic_store(&r.state, Handoff_State.Done)
	}
}

rebuild_job_run :: proc(j: ^Rebuild_Job) {
	ribbon := j.held
	if j.do_road {
		j.ribbon = geo.build_ribbon(j.spline, allocator = context.allocator, detach = j.terrain.detach)
		ribbon = j.ribbon
		j.road_mesh = geo.build_tri_mesh(ribbon, j.roughness, j.look, context.allocator)
	}
	if j.do_ground {
		j.ground_mesh = geo.tri_mesh_make(context.allocator)
		start := time.now()
		rebuild_job_ground(j, ribbon)
		j.ground_ms = time.duration_milliseconds(time.since(start))
	}
	if j.do_veg {
		j.veg = geo.veg_generate(ribbon, &j.terrain, j.veg_params, j.roughness, context.allocator)
		j.veg_mesh = geo.veg_build_mesh(j.veg, context.allocator)
		j.cards = geo.billboards_generate(
			ribbon, &j.terrain, j.veg_params, j.roughness, j.veg,
			j.card_kinds[.Near], j.card_kinds[.Far], context.allocator,
		)
		j.card_mesh = geo.billboards_build_mesh(j.cards, context.allocator)
	}
}

// The CPU half of geo.terrain_mesh_rebuild. Everything but the upload.
//
// A preview asks for the same build at a coarser interior spacing. Nothing else
// scales with it: the sculpt offsets, the reach and the warp are read as they
// stand, which is why the coarse ground sits where the fine one will.
rebuild_job_ground :: proc(j: ^Rebuild_Job, ribbon: []geo.Cross_Section) {
	if !j.terrain.enabled || len(ribbon) < 2 {
		return
	}
	arc := geo.ribbon_arc(ribbon)
	if arc[len(ribbon) - 1] <= 0 {
		return
	}
	ds := geo.sample_spacing(ribbon)
	geo.terrain_field_ensure(
		&j.field, &j.terrain, ribbon, arc, ds, j.roughness, j.ribbon_gen,
		cell_scale = j.preview ? PREVIEW_CELL : 1,
	)
	geo.build_terrain_mesh(&j.ground_mesh, &j.terrain, &j.field, ribbon, j.roughness, j.look)
}
