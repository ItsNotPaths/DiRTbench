package main

// An arena window. It shares the camera, the menubar and the docks with the
// venue and stage windows, and nothing that assumes a road: there is no
// rebuild, no gizmo on road points, and no stage cache.

import "core:fmt"
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
	camera_step(ed, ui_mouse, nav)
	cam3d := to_camera3d(ed.cam)
	draw_arena_scene(ed, cam3d)

	ui.imgui_backend_begin()
	draw_menubar(ed)
	draw_arena_inspector(ed)
	if ed.show_demo {
		ui.igShowDemoWindow(&ed.show_demo)
	}
	render_imgui(&ed.window)

	gfx.EndWindowFrame(&ed.window)
	free_all(context.temp_allocator)
}

// Twin of draw_venue_scene (scene.odin).
draw_arena_scene :: proc(ed: ^Editor, cam3d: gfx.Camera3D) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	geo.gpu_mesh_draw(ed.doc.arena_ground.mesh, ed.doc.material, ed.wireframe)
	draw_arena_props(ed.doc, ed.wireframe)
	gfx.EndMode3D()
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
		ui.im_text(fmt.ctprintf("%s  %s", route.id, route.name))
		ui.im_same_line()
		ui.im_text_colored(DIM_COL, fmt.ctprint(label))
	}
	ui.im_text_colored(DIM_COL, "Add, remove and rename routes in the project manager.")
}

// --- the ground ----------------------------------------------------------------

// An arena's ground, as the window draws and picks it: the collision the
// export writes, which is the drawn ground plus the baked walls of every prop
// the baseline keeps. What the car drives on is what a prop is dropped on.
Arena_Ground :: struct {
	tris:  [][3]gfx.Vector3,
	mesh:  geo.Gpu_Mesh,
	lo:    gfx.Vector3,
	hi:    gfx.Vector3,
	props: []Arena_Prop, // the baseline, drawn from the venue art
}

Arena_Prop :: struct {
	ref:   Prop_Ref,
	xform: gfx.Matrix,
}

arena_ground_free :: proc(g: ^Arena_Ground) {
	delete(g.tris)
	for prop in g.props {
		delete(prop.ref.name)
	}
	delete(g.props)
	geo.gpu_mesh_unload(&g.mesh)
	g^ = {}
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

// Read the arena's collision off the stock route and upload it.
arena_ground_load :: proc(doc: ^Venue_Doc, p: Venue) -> (msg: string, ok: bool) {
	arena_ground_free(&doc.arena_ground)
	_, donor, found := venue_source(doc.install, p)
	if !found {
		return fmt.tprintf("%s/%s is not in the game", p.base, p.base_route), false
	}
	stock, read_err := os.read_entire_file(d3.Stock_Path(donor.dir, "track.jpk"), context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read the stock track.jpk: %v", read_err), false
	}
	places, drop, baseline_msg, baseline_ok := arena_baseline()
	if !baseline_ok {
		return baseline_msg, false
	}
	tris, tris_msg, tris_ok := d3.Jpk_Triangles(stock, drop, context.temp_allocator)
	if !tris_ok {
		return tris_msg, false
	}

	mesh := arena_ground_build(&doc.arena_ground, tris)
	doc.arena_ground.mesh = geo.gpu_mesh_upload(mesh)
	doc.arena_ground.props = make([]Arena_Prop, len(places))
	for place, i in places {
		doc.arena_ground.props[i] = {
			ref   = {kind = place.ref.kind, name = strings.clone(place.ref.name)},
			xform = arena_place_xform(place),
		}
	}
	return fmt.tprintf("%d ground and wall triangles", len(tris)), true
}

// The CPU half of arena_ground_load: positions for picking, and a coloured mesh
// to upload.
arena_ground_build :: proc(g: ^Arena_Ground, tris: []d3.Write_Tri) -> (mesh: geo.Tri_Mesh) {
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
draw_arena_props :: proc(doc: ^Venue_Doc, wireframe: bool) {
	if len(doc.arena_ground.props) > 0 && doc.venue_art.state == .Unloaded {
		venue_art_load(doc)
	}
	for prop in doc.arena_ground.props {
		if drawable, have := prop_drawable(doc, prop.ref); have {
			prop_draw_one(doc, drawable, prop.xform, wireframe)
		}
	}
}

// Twin of pick_ground (scene.odin), over the arena's collision.
arena_pick_ground :: proc(ed: ^Editor, ray: gfx.Ray) -> (at: gfx.Vector3, hit: bool) {
	best := max(f32)
	for tri in ed.doc.arena_ground.tris {
		c := gfx.GetRayCollisionTriangle(ray, tri[0], tri[1], tri[2])
		if c.hit && c.distance < best {
			at, best = c.point, c.distance
		}
	}
	return at, best < max(f32)
}

// Frame the whole ground from above, the first time the window opens.
arena_camera_frame :: proc(ed: ^Editor) {
	g := ed.doc.arena_ground
	if g.mesh.tris == 0 {
		return
	}
	ed.cam.target = (g.lo + g.hi) / 2
	ed.cam.distance = linalg.length(g.hi - g.lo) * 0.6
	ed.cam.pitch = 0.9
}
