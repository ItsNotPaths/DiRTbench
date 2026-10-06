package main

// An arena window. It shares the camera, the menubar and the docks with the
// venue and stage windows, and nothing that assumes a road: there is no
// rebuild, no gizmo on road points, and no stage cache.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../geo"
import "../gfx"
import "../ui"

// Twin of venue_frame and stage_frame (view.odin), for both arena windows: the
// layout one edits props, and a route one edits that route's spots, as a
// venue window edits the road and a stage window its own lines.
arena_frame :: proc(ed: ^Editor) {
	route_window := ed.kind == .Arena_Route
	gfx.BeginWindowFrame(&ed.window)
	ui_mouse := ui.imgui_want_capture_mouse()
	ui_keys := ui.imgui_want_capture_keyboard()
	editor_hotkeys(ed, ui_keys)

	nav := alt_held()
	ui.gizmo_enable(!nav)
	camera_step(ed, ui_mouse, nav)
	cam3d := to_camera3d(ed.cam)
	ray := gfx.GetScreenToWorldRay(gfx.GetMousePosition(), cam3d)
	if route_window {
		arena_spot_ghost_update(ed, ray)
	} else {
		prop_ghost_update(ed, ray)
	}
	draw_arena_scene(ed, cam3d)

	ui.imgui_backend_begin()
	gizmo_used := false
	if gizmo_frame_begin(ed) {
		shown := false
		if route_window {
			shown, gizmo_used = arena_spot_gizmo(ed, cam3d)
		} else if pi := selected_prop(ed); pi >= 0 {
			shown, gizmo_used = true, prop_gizmo(ed, pi, cam3d)
		}
		ed.gizmo_active = gizmo_used
		ed.gizmo_hovered = shown && ui.gizmo_is_over()
	}
	draw_menubar(ed)
	if route_window {
		draw_arena_route_inspector(ed)
	} else {
		draw_arena_inspector(ed)
		draw_venue_tools(ed)
	}
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	if route_window {
		arena_route_input(ed, ray, gizmo_used, nav, ui_mouse, ui_keys)
	} else {
		arena_input(ed, ray, gizmo_used, nav, ui_mouse, ui_keys)
	}

	gfx.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}

// Twin of draw_venue_scene (scene.odin).
draw_arena_scene :: proc(ed: ^Editor, cam3d: gfx.Camera3D) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	draw_arena_world(ed.doc, ed.wireframe)
	if ed.kind == .Arena_Route {
		draw_arena_spots(ed)
	}
	if bi := selected_baseline(ed); bi >= 0 {
		prop := ed.doc.arena.props[bi]
		if lo, hi, ok := prop_ref_world_bounds(ed.doc, prop.ref, prop.xform); ok {
			draw_world_box(lo, hi, {255, 140, 70, 255})
		}
	}
	if pi := selected_prop(ed); pi >= 0 {
		draw_prop_box(ed.doc, ed.doc.props[pi], {255, 140, 70, 255})
	}
	draw_prop_ghost(ed)
	gfx.EndMode3D()
}

// The arena itself, with nothing that belongs to editing: what the window and
// the thumbnail both draw. Twin of draw_world (scene.odin).
draw_arena_world :: proc(doc: ^Venue_Doc, wireframe: bool) {
	geo.gpu_mesh_draw(doc.arena.mesh, doc.material, wireframe)
	draw_arena_baseline(doc, wireframe)
	draw_props(doc, wireframe)
}

// Twin of editor_input (view.odin): a click picks the nearer of a baseline
// placement and a placed prop, and Delete takes whichever is selected.
@(private = "file")
arena_input :: proc(ed: ^Editor, ray: gfx.Ray, gizmo_used, nav, ui_mouse, ui_keys: bool) {
	if prop_place_input(ed, nav, ui_mouse, ui_keys) {
		return
	}
	if gfx.IsMouseButtonPressed(.LEFT) && !gizmo_used && !ed.gizmo_hovered && !nav && !ui_mouse {
		pi, pd := pick_prop(ed.doc, ray)
		bi, bd := arena_pick_baseline(ed.doc, ray)
		switch {
		case pi >= 0 && (bi < 0 || pd <= bd):
			ed.sel = {kind = .Prop, idx = pi}
		case bi >= 0:
			ed.sel = {kind = .Baseline, idx = bi}
		case:
			ed.sel = {}
		}
	}
	if !gfx.IsKeyPressed(.DELETE) || ui_keys {
		return
	}
	if pi := selected_prop(ed); pi >= 0 {
		prop_remove(ed.doc, pi)
		ed.sel = {}
	} else if bi := selected_baseline(ed); bi >= 0 {
		arena_set_removed(ed, bi, true)
	}
}

// Twin of arena_input for a route window: a click picks this route's spots,
// and Delete takes a selected goal. The layout is not touched here.
@(private = "file")
arena_route_input :: proc(ed: ^Editor, ray: gfx.Ray, gizmo_used, nav, ui_mouse, ui_keys: bool) {
	if arena_spot_place_input(ed, nav, ui_mouse, ui_keys) {
		return
	}
	if gfx.IsMouseButtonPressed(.LEFT) && !gizmo_used && !ed.gizmo_hovered && !nav && !ui_mouse {
		spot, _ := pick_arena_spot(ed, ray)
		ed.sel = spot.kind != .None ? spot : {kind = .Start, idx = arena_window_route(ed)}
	}
	if gfx.IsKeyPressed(.DELETE) && !ui_keys {
		arena_spot_delete(ed)
	}
}

@(private = "file")
draw_arena_route_inspector :: proc(ed: ^Editor) {
	open := sidebar_begin("Route", .Left)
	defer sidebar_end(open)
	if !open {
		return
	}
	ui.igSeparatorText(fmt.ctprintf("%s / %s", ed.doc.venue_name, ed.stage_id))
	draw_status_text(&ed.status)
	ri := arena_window_route(ed)
	if ri < 0 {
		ui.im_text_colored(WARN_COL, "this route is no longer in the arena")
		return
	}
	for problem in arena_route_problems(ed.doc.routes[ri]) {
		ui.im_text_colored(WARN_COL, fmt.ctprint(problem))
	}
	draw_route_spots(ed)
}

// The selected baseline placement, or -1.
selected_baseline :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Baseline && ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.arena.props) {
		return ed.sel.idx
	}
	return -1
}

draw_arena_inspector :: proc(ed: ^Editor) {
	open := sidebar_begin("Arena", .Left)
	defer sidebar_end(open)
	if !open {
		return
	}
	ui.igSeparatorText(fmt.ctprint(ed.doc.venue_name))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("on %s/%s", ARENA_BASE, ARENA_BASE_ROUTE))
	draw_status_text(&ed.status)

	ui.igSeparatorText("Routes")
	for route in ed.doc.routes {
		label := route.mode
		if mode, known := arena_mode_of(route.mode); known {
			label = ARENA_MODE_LABEL[mode]
		}
		ui.im_text(fmt.ctprintf("%s  %s  (%s)", route.id, route.name, label))
		for problem in arena_route_problems(route) {
			ui.im_text_colored(WARN_COL, fmt.ctprintf("  %s", problem))
		}
	}
	ui.im_text_colored(DIM_COL, "Each route's start and goals open from its Edit button in the project manager.")

	draw_prop_selection(ed)
	draw_baseline_selection(ed)
	draw_removed_list(ed)
	draw_props_sections(ed)
}

// One baseline placement: what it is, and the way out if its tier allows one.
draw_baseline_selection :: proc(ed: ^Editor) {
	bi := selected_baseline(ed)
	if bi < 0 {
		return
	}
	prop := ed.doc.arena.props[bi]
	ui.igSeparatorText(fmt.ctprintf("Baseline %d of %d", bi, len(ed.doc.arena.props)))
	ui.im_text(fmt.ctprint(prop.ref.name))
	ui.im_text_colored(DIM_COL, fmt.ctprintf("%s, stock Battersea", ARENA_TIER_NAMES[prop.tier]))
	ui.igBeginDisabled(prop.tier != .Delete_Only)
	if ui.im_button("Remove") {
		arena_set_removed(ed, bi, true)
	}
	ui.igEndDisabled()
}

// The removed baseline placements, each with the way back.
@(private = "file")
draw_removed_list :: proc(ed: ^Editor) {
	removed := 0
	for prop in ed.doc.arena.props {
		if prop.removed { removed += 1 }
	}
	if removed == 0 {
		return
	}
	ui.igSeparatorText(fmt.ctprintf("Removed (%d)", removed))
	for prop, i in ed.doc.arena.props {
		if !prop.removed {
			continue
		}
		if ui.im_button(fmt.ctprintf("Restore###restore%d", i)) {
			arena_set_removed(ed, i, false)
		}
		ui.im_same_line()
		ui.im_text(fmt.ctprint(prop.ref.name))
	}
}

// Take a baseline placement out, or put it back. Its collision goes with it,
// so the ground is rebuilt.
arena_set_removed :: proc(ed: ^Editor, i: int, removed: bool) {
	prop := &ed.doc.arena.props[i]
	if prop.tier != .Delete_Only {
		set_status(&ed.status, fmt.tprintf("%s is %s: it stays", prop.ref.name, ARENA_TIER_NAMES[prop.tier]), false)
		return
	}
	prop.removed = removed
	ed.sel = {}
	mark_edited(ed.doc)
	if msg, ok := arena_ground_rebuild(ed.doc); !ok {
		set_status(&ed.status, msg, false)
		return
	}
	set_status(&ed.status, fmt.tprintf("%s %s", removed ? "removed" : "restored", prop.ref.name), true)
}

// --- the ground ----------------------------------------------------------------

// An arena as the window holds it: the ground the export writes, which is the
// drawn ground plus the baked walls of every prop still standing, and the
// baseline placements, each marked removed or not. What the car drives on is
// what a prop is dropped on.
Arena_Doc :: struct {
	active:    bool,
	donor_dir: string, // stock route_0
	stock_jpk: []u8,
	tris:      [][3]gfx.Vector3,
	mesh:      geo.Gpu_Mesh,
	lo:        gfx.Vector3,
	hi:        gfx.Vector3,
	props:     []Arena_Prop, // parallel to the baseline's placements
	catalogue: []Prop_Ref,
}

Arena_Prop :: struct {
	ref:     Prop_Ref,
	xform:   gfx.Matrix,
	pos:     [3]f32,
	tier:    Arena_Tier,
	removed: bool,
}

arena_doc_free :: proc(a: ^Arena_Doc) {
	delete(a.donor_dir)
	delete(a.stock_jpk)
	delete(a.tris)
	geo.gpu_mesh_unload(&a.mesh)
	for prop in a.props {
		delete(prop.ref.name)
	}
	delete(a.props)
	for ref in a.catalogue {
		delete(ref.name)
	}
	delete(a.catalogue)
	a^ = {}
}

// Read the stock collision and the baseline, mark what the venue removed, and
// build the ground.
arena_doc_load :: proc(doc: ^Venue_Doc, p: Venue) -> (msg: string, ok: bool) {
	a := &doc.arena
	arena_doc_free(a)
	_, donor, found := venue_source(doc.install, p)
	if !found {
		return fmt.tprintf("%s/%s is not in the game", p.base, p.base_route), false
	}
	stock, read_err := os.read_entire_file(d3.Stock_Path(donor.dir, "track.jpk"), context.allocator)
	if read_err != nil {
		return fmt.tprintf("could not read the stock track.jpk: %v", read_err), false
	}
	base, baseline_msg, baseline_ok := arena_baseline()
	if !baseline_ok {
		delete(stock)
		return baseline_msg, false
	}
	// An entry that matches nothing is dropped here, so the next save drops it
	// from the file. The export refuses it until then.
	mask, _ := arena_removed_mask(base, p.road.removed)
	a.active, a.stock_jpk = true, stock
	a.donor_dir = strings.clone(donor.dir)
	a.props = make([]Arena_Prop, len(base.places))
	for place, i in base.places {
		a.props[i] = {
			ref     = {kind = place.ref.kind, name = strings.clone(place.ref.name)},
			xform   = arena_place_xform(place),
			pos     = place.pos,
			tier    = base.tiers[i],
			removed = mask[i],
		}
	}
	a.catalogue = make([]Prop_Ref, len(base.catalogue))
	for ref, i in base.catalogue {
		a.catalogue[i] = {kind = ref.kind, name = strings.clone(ref.name)}
	}
	return arena_ground_rebuild(doc)
}

// The ground again, from the stock collision minus what the baseline and the
// removals drop.
arena_ground_rebuild :: proc(doc: ^Venue_Doc) -> (msg: string, ok: bool) {
	a := &doc.arena
	base, baseline_msg, baseline_ok := arena_baseline()
	if !baseline_ok {
		return baseline_msg, false
	}
	mask := make([]bool, len(a.props), context.temp_allocator)
	for prop, i in a.props {
		mask[i] = prop.removed
	}
	tris, tris_msg, tris_ok := d3.Jpk_Triangles(a.stock_jpk, arena_jpk_drop(base, mask), context.temp_allocator)
	if !tris_ok {
		return tris_msg, false
	}
	delete(a.tris)
	geo.gpu_mesh_unload(&a.mesh)
	a.mesh = geo.gpu_mesh_upload(arena_ground_build(a, tris))
	return fmt.tprintf("%d ground and wall triangles", len(tris)), true
}

// The removed placements as the venue file names them. Not a transform: only
// the mesh and the position are read back (arena_removed_mask).
arena_removed_block :: proc(doc: ^Venue_Doc, allocator := context.temp_allocator) -> []Stage_Prop {
	n := 0
	for prop in doc.arena.props {
		if prop.removed { n += 1 }
	}
	out := make([]Stage_Prop, n, allocator)
	n = 0
	for prop in doc.arena.props {
		if prop.removed {
			out[n] = {
				name  = prop.ref.name,
				trees = prop.ref.kind == .Trees_Pssg,
				pos   = prop.pos,
				rot   = {0, 0, 0, 1},
				scale = 1,
			}
			n += 1
		}
	}
	return out
}

// Ground and walls, one colour each. Not by surface code: Battersea's codes
// change from one triangle to the next, and colouring by them reads as noise.
// Half the ground is flat at one height, so a sun alone draws it one grey:
// the ground also runs from low to high colour across its 5th..95th height.
ARENA_GROUND_LOW :: [3]f32{70, 92, 110}
ARENA_GROUND_HIGH :: [3]f32{196, 186, 150}
ARENA_WALL_COL :: [3]f32{182, 150, 118}
ARENA_SUN :: [3]f32{0.6, 0.55, 0.35}

@(private = "file")
arena_ground_colour :: proc(normal: gfx.Vector3, base: [3]f32) -> gfx.Color {
	// Two-sided: a wall wound either way lights the same.
	light := 0.4 + 0.6 * abs(linalg.dot(normal, linalg.normalize(gfx.Vector3(ARENA_SUN))))
	return {u8(min(base[0] * light, 255)), u8(min(base[1] * light, 255)), u8(min(base[2] * light, 255)), 255}
}

// The CPU half of arena_ground_rebuild: positions for picking, and a coloured
// mesh to upload.
arena_ground_build :: proc(g: ^Arena_Doc, tris: []d3.Write_Tri) -> (mesh: geo.Tri_Mesh) {
	g.tris = make([][3]gfx.Vector3, len(tris))
	g.lo, g.hi = max(f32), min(f32)
	mesh.pos = make([dynamic]gfx.Vector3, 0, len(tris) * 3, context.temp_allocator)
	mesh.col = make([dynamic]gfx.Color, 0, len(tris) * 3, context.temp_allocator)
	// Smooth normals: each ground corner takes the area-weighted sum of the
	// ground faces that share its position, welded at a centimetre. Walls stay
	// out, or every wall foot shades the ground beside it.
	Weld :: [3]i32
	weld :: proc(p: gfx.Vector3) -> Weld { return {i32(p.x * 100), i32(p.y * 100), i32(p.z * 100)} }
	face := make([]gfx.Vector3, len(tris), context.temp_allocator)
	shared := make(map[Weld]gfx.Vector3, len(tris) * 2, context.temp_allocator)
	heights := make([dynamic]f32, 0, len(tris), context.temp_allocator)
	for tri, i in tris {
		for p, k in tri.p {
			g.tris[i][k] = {p[0], p[1], p[2]}
			g.lo = linalg.min(g.lo, g.tris[i][k])
			g.hi = linalg.max(g.hi, g.tris[i][k])
		}
		a, b, c := g.tris[i][0], g.tris[i][1], g.tris[i][2]
		n := linalg.cross(b - a, c - a)
		if n.y < 0 { n = -n }
		face[i] = n
		if arena_steep(n) {
			continue
		}
		append(&heights, (a.y + b.y + c.y) / 3)
		for corner in g.tris[i] {
			// Read then write: `+=` on a key the map does not hold faults.
			key := weld(corner)
			shared[key] = shared[key] + n
		}
	}
	slice.sort(heights[:])
	low, high: f32 = 0, 1
	if len(heights) > 0 {
		low, high = heights[len(heights) * 5 / 100], heights[len(heights) * 95 / 100]
	}
	for tri, i in g.tris {
		steep := arena_steep(face[i])
		for corner in tri {
			n, base := face[i], ARENA_WALL_COL
			if !steep {
				t := clamp((corner.y - low) / max(high - low, 0.01), 0, 1)
				n, base = shared[weld(corner)], linalg.lerp(ARENA_GROUND_LOW, ARENA_GROUND_HIGH, t)
			}
			append(&mesh.pos, corner)
			append(&mesh.col, arena_ground_colour(linalg.normalize0(n), base))
		}
	}
	return
}

@(private = "file")
arena_steep :: proc(n: gfx.Vector3) -> bool {
	return linalg.normalize0(n).y < 0.5
}

// The draw matrix of a stored placement. The file's 3x3 is the transpose of
// the rotation, scale folded in (d3_prop_basis).
@(private = "file")
arena_place_xform :: proc(place: D3_Place) -> (m: gfx.Matrix) {
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			m[row, col] = place.basis[col][row]
		}
		m[row, 3] = place.pos[row]
	}
	m[3, 3] = 1
	return
}

// Twin of draw_props (props.odin), over the baseline.
@(private = "file")
draw_arena_baseline :: proc(doc: ^Venue_Doc, wireframe: bool) {
	if len(doc.arena.props) > 0 && doc.venue_art.state == .Unloaded {
		venue_art_load(doc)
	}
	for prop in doc.arena.props {
		if prop.removed {
			continue
		}
		if drawable, have := prop_drawable(doc, prop.ref); have {
			prop_draw_one(doc, drawable, prop.xform, wireframe)
		}
	}
}

// Twin of pick_prop (props.odin), over the baseline you can remove. The rest
// is click-through: nothing can be done to it, and the godray cards and
// shadow meshes have boxes that would swallow every click near them.
@(private = "file")
arena_pick_baseline :: proc(doc: ^Venue_Doc, ray: gfx.Ray) -> (idx: int, dist: f32) {
	idx, dist = -1, max(f32)
	for prop, i in doc.arena.props {
		if prop.removed || prop.tier != .Delete_Only {
			continue
		}
		lo, hi, ok := prop_ref_world_bounds(doc, prop.ref, prop.xform)
		if !ok {
			continue
		}
		hit := gfx.GetRayCollisionBox(ray, lo, hi)
		if hit.hit && hit.distance < dist {
			idx, dist = i, hit.distance
		}
	}
	return
}

// Twin of pick_ground (scene.odin), over the arena's collision.
arena_pick_ground :: proc(ed: ^Editor, ray: gfx.Ray) -> (at: gfx.Vector3, hit: bool) {
	best := max(f32)
	for tri in ed.doc.arena.tris {
		c := gfx.GetRayCollisionTriangle(ray, tri[0], tri[1], tri[2])
		if c.hit && c.distance < best {
			at, best = c.point, c.distance
		}
	}
	return at, best < max(f32)
}

// Frame the whole ground from above, the first time the window opens.
arena_camera_frame :: proc(ed: ^Editor) {
	g := ed.doc.arena
	if g.mesh.tris == 0 {
		return
	}
	ed.cam.target = (g.lo + g.hi) / 2
	ed.cam.distance = linalg.length(g.hi - g.lo) * 0.6
	ed.cam.pitch = 0.9
}
