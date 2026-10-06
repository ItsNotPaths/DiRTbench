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

// Twin of stage_frame and venue_frame (view.odin): the same frame order, minus
// everything that reads the road.
arena_frame :: proc(ed: ^Editor) {
	gfx.BeginWindowFrame(&ed.window)
	ui_mouse := ui.imgui_want_capture_mouse()
	ui_keys := ui.imgui_want_capture_keyboard()
	editor_hotkeys(ed, ui_keys)

	nav := alt_held()
	ui.gizmo_enable(!nav)
	camera_step(ed, ui_mouse, nav)
	cam3d := to_camera3d(ed.cam)
	ray := gfx.GetScreenToWorldRay(gfx.GetMousePosition(), cam3d)
	prop_ghost_update(ed, ray)
	start_ghost_update(ed, ray)
	draw_arena_scene(ed, cam3d)

	ui.imgui_backend_begin()
	gizmo_used := false
	if gizmo_frame_begin(ed) {
		shown := true
		if pi := selected_prop(ed); pi >= 0 {
			gizmo_used = prop_gizmo(ed, pi, cam3d)
		} else if ri := selected_start(ed); ri >= 0 {
			gizmo_used = start_gizmo(ed, ri, cam3d)
		} else {
			shown = false
		}
		ed.gizmo_active = gizmo_used
		ed.gizmo_hovered = shown && ui.gizmo_is_over()
	}
	draw_menubar(ed)
	draw_arena_inspector(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	arena_input(ed, ray, gizmo_used, nav, ui_mouse, ui_keys)

	gfx.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}

// Twin of draw_venue_scene (scene.odin).
draw_arena_scene :: proc(ed: ^Editor, cam3d: gfx.Camera3D) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	geo.gpu_mesh_draw(ed.doc.arena.mesh, ed.doc.material, ed.wireframe)
	draw_arena_baseline(ed.doc, ed.wireframe)
	draw_props(ed.doc, ed.wireframe)
	for route, i in ed.doc.routes {
		draw_start_ring(route.party_start, route.mode, i == selected_start(ed))
	}
	if ghost, ok := ed.start_ghost.?; ok {
		if ri := selected_start(ed); ri >= 0 {
			draw_start_ring(ghost, ed.doc.routes[ri].mode, true)
		}
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

// Twin of editor_input (view.odin): a click picks the nearer of a baseline
// placement and a placed prop, and Delete takes whichever is selected.
@(private = "file")
arena_input :: proc(ed: ^Editor, ray: gfx.Ray, gizmo_used, nav, ui_mouse, ui_keys: bool) {
	if prop_place_input(ed, nav, ui_mouse, ui_keys) || start_place_input(ed, nav, ui_mouse, ui_keys) {
		return
	}
	if gfx.IsMouseButtonPressed(.LEFT) && !gizmo_used && !ed.gizmo_hovered && !nav && !ui_mouse {
		pi, pd := pick_prop(ed.doc, ray)
		bi, bd := arena_pick_baseline(ed.doc, ray)
		si, sd := pick_start(ed.doc, ray)
		switch {
		case si >= 0 && (pi < 0 || sd <= pd) && (bi < 0 || sd <= bd):
			ed.sel = {kind = .Start, idx = si}
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
	for route, i in ed.doc.routes {
		label := route.mode
		if mode, known := arena_mode_of(route.mode); known {
			label = ARENA_MODE_LABEL[mode]
		}
		if ui.igSelectable_Bool(
			fmt.ctprintf("%s  %s  (%s)###route%d", route.id, route.name, label, i),
			selected_start(ed) == i, ui.IM_SELECTABLE_NONE, {0, 0},
		) {
			ed.sel = {kind = .Start, idx = i}
		}
		for problem in arena_route_problems(route) {
			ui.im_text_colored(WARN_COL, fmt.ctprintf("  %s", problem))
		}
	}
	ui.im_text_colored(DIM_COL, "Add, remove and rename routes in the project manager.")

	draw_start_selection(ed)
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

// --- route starts ---------------------------------------------------------------

ARENA_START_COL := [Arena_Mode]gfx.Color {
	.Outbreak    = {120, 220, 90, 255},
	.Transporter = {90, 170, 255, 255},
}

// The selected route's start, or -1. Selects the route even when its start
// is not placed yet, so the inspector can offer to place it.
selected_start :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Start && ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.routes) {
		return ed.sel.idx
	}
	return -1
}

// One slot's centre in world space.
@(private = "file")
start_slot :: proc(start: Arena_Spot, slot: [2]f32) -> gfx.Vector3 {
	s, c := math.sin(start.yaw), math.cos(start.yaw)
	return start.pos + slot.x * gfx.Vector3{c, 0, -s} + slot.y * gfx.Vector3{s, 0, c}
}

// The ring of 8 cars, and an arrow along its heading.
@(private = "file")
draw_start_ring :: proc(start: Arena_Spot, mode_key: string, selected: bool) {
	mode, known := arena_mode_of(mode_key)
	if !known || !start.placed {
		return
	}
	col := selected ? gfx.Color{255, 140, 70, 255} : ARENA_START_COL[mode]
	for slot in ARENA_START_RING {
		at := start_slot(start, slot)
		draw_world_box(at - {1, 0.75, 1}, at + {1, 0.75, 1}, col)
	}
	tip := start_slot(start, {0, 8})
	gfx.DrawLine3D(start.pos, tip, col)
	gfx.DrawSphere(tip, 0.6, col)
	gfx.DrawSphere(start.pos, 1, col)
}

// A start is picked by its centre or any of its slots.
@(private = "file")
pick_start :: proc(doc: ^Venue_Doc, ray: gfx.Ray) -> (idx: int, dist: f32) {
	idx, dist = -1, max(f32)
	for route, i in doc.routes {
		start := route.party_start
		if !start.placed {
			continue
		}
		hit := gfx.GetRayCollisionSphere(ray, start.pos, 3)
		for slot in ARENA_START_RING {
			at := start_slot(start, slot)
			if h := gfx.GetRayCollisionBox(ray, at - {1, 0.75, 1}, at + {1, 0.75, 1}); h.hit && (!hit.hit || h.distance < hit.distance) {
				hit = h
			}
		}
		if hit.hit && hit.distance < dist {
			idx, dist = i, hit.distance
		}
	}
	return
}

// Move and turn a start. Yaw only: the turn is read back off the heading, and
// the ring drops onto the ground under its slots.
@(private = "file")
start_gizmo :: proc(ed: ^Editor, ri: int, cam: gfx.Camera3D) -> bool {
	start := &ed.doc.routes[ri].party_start
	if !start.placed {
		return false
	}
	op, space := gizmo_op_space(ed.gizmo_mode)
	rot := gfx.QuaternionFromAxisAngle({0, 1, 0}, start.yaw)
	pos, turned, used := ui.gizmo_manipulate_xform(start.pos, rot, cam, op, space)
	if used {
		forward := gfx.Vector3RotateByQuaternion({0, 0, 1}, turned)
		start.pos, start.yaw = pos, math.atan2(forward.x, forward.z)
		start_drop(ed, start)
		mark_edited(ed.doc)
	}
	return used
}

// Where the selected route's start would land under the cursor, while placing.
@(private = "file")
start_ghost_update :: proc(ed: ^Editor, ray: gfx.Ray) {
	ed.start_ghost = nil
	ri := selected_start(ed)
	if ri < 0 {
		ed.start_placing = false
	}
	if !ed.start_placing {
		return
	}
	at, hit := arena_pick_ground(ed, ray)
	if !hit {
		return
	}
	ghost := Arena_Spot{pos = at, yaw = ed.doc.routes[ri].party_start.yaw, placed = true}
	start_drop(ed, &ghost)
	ed.start_ghost = ghost
}

// Twin of prop_place_input (props.odin): the click that drops the start, and
// the keys that end the mode.
@(private = "file")
start_place_input :: proc(ed: ^Editor, nav, ui_mouse, ui_keys: bool) -> bool {
	if !ed.start_placing {
		return false
	}
	if (!ui_keys && gfx.IsKeyPressed(.ESCAPE)) || (!nav && !ui_mouse && gfx.IsMouseButtonPressed(.RIGHT)) {
		ed.start_placing = false
		return true
	}
	if nav || ui_mouse || !gfx.IsMouseButtonPressed(.LEFT) {
		return true
	}
	ghost, ok := ed.start_ghost.?
	if !ok {
		set_status(&ed.status, "point at the ground to put the start there", false)
		return true
	}
	ed.doc.routes[ed.sel.idx].party_start = ghost
	ed.start_placing = false
	mark_edited(ed.doc)
	set_status(&ed.status, "start placed", true)
	return true
}

// Stand the ring over the highest ground under any of its slots, at the stock
// lift. Left where it is when no slot is over ground.
@(private = "file")
start_drop :: proc(ed: ^Editor, start: ^Arena_Spot) {
	top, found := min(f32), false
	for slot in ARENA_START_RING {
		at := start_slot(start^, slot)
		if hit, ok := arena_pick_ground(ed, {position = at + {0, 200, 0}, direction = {0, -1, 0}}); ok {
			top, found = max(top, hit.y), true
		}
	}
	if found {
		start.pos.y = top + ARENA_START_LIFT
	}
}

// The selected route's start: where it is, and the ways to set it.
draw_start_selection :: proc(ed: ^Editor) {
	ri := selected_start(ed)
	if ri < 0 {
		return
	}
	route := &ed.doc.routes[ri]
	mode, known := arena_mode_of(route.mode)
	if !known {
		return
	}
	start := &route.party_start
	ui.igSeparatorText(fmt.ctprintf("%s start", ARENA_MODE_LABEL[mode]))
	if start.placed {
		ui.im_text(fmt.ctprintf("(%.1f, %.1f, %.1f)", start.pos.x, start.pos.y, start.pos.z))
		deg := math.to_degrees(start.yaw)
		if ui.igSliderFloat("heading", &deg, -180, 180, "%.0f deg", ui.IM_SLIDER_NONE) {
			start.yaw = math.to_radians(deg)
			mark_edited(ed.doc)
		}
		ui.im_text_colored(DIM_COL, "drag the gizmo to move it; it drops onto the ground")
	} else {
		ui.im_text_colored(WARN_COL, "no start placed")
	}
	if ui.im_button(ed.start_placing ? "Stop placing" : "Place start") {
		ed.start_placing = !ed.start_placing
		ed.prop_placing = nil
	}
	ui.im_same_line()
	if ui.im_button("Use stock start") {
		stock, msg, ok := arena_stock_start(ed.doc.arena.donor_dir, mode)
		if ok {
			start^ = stock
			mark_edited(ed.doc)
		}
		set_status(&ed.status, ok ? "start set to stock route_0's" : msg, ok)
	}
	if ed.start_placing {
		ui.im_text_colored(MINE_COL, "click the ground; Esc or right-click stops")
	}
}
