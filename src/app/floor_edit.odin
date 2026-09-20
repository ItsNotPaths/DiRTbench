package main

// Drawing, picking and moving a floor (geo/floor.odin).
//
// A floor is authored in world XZ, so none of this goes near the spline. It is
// a venue-window tool: the stage windows show the ground but do not shape it.
//
// Drawing is a state on the window rather than a global tool mode, so the road's
// own right-click verbs are untouched — they are simply held off for as long as
// an outline is open.

import "core:fmt"
import "../geo"
import "../ui"
import "../gfx"

// Handle size for an outline vertex, and the slack a click on the outline gets.
FLOOR_HANDLE_R :: 1.6

// How much wider the first corner's handle is while the outline is open. The
// outline closes by clicking it, so it has to be the easier of two corners to
// hit when they sit on top of each other — the last corner placed is often
// right beside it.
FLOOR_SHUT_R :: FLOOR_HANDLE_R * 2

// --- selection ----------------------------------------------------------------

// The selected pad, or -1. Validated: a delete or a load can leave the selection
// past the end of the list.
selected_floor :: proc(ed: ^Editor) -> int {
	#partial switch ed.sel.kind {
	case .Floor, .Floor_Vert:
		if geo.floor_valid(&ed.doc.terrain, ed.sel.idx) {
			return ed.sel.idx
		}
	}
	return -1
}

// The selected outline vertex as (pad, vertex), or (-1, -1).
selected_floor_vert :: proc(ed: ^Editor) -> (int, int) {
	fi := selected_floor(ed)
	if ed.sel.kind != .Floor_Vert || fi < 0 {
		return -1, -1
	}
	if ed.sel.sub < 0 || ed.sel.sub >= ed.doc.terrain.floors[fi].count {
		return -1, -1
	}
	return fi, ed.sel.sub
}

floor_vert_pos :: proc(t: ^geo.Terrain, fi, v: int) -> gfx.Vector3 {
	f := t.floors[fi]
	p := geo.floor_verts(t, f)[v]
	return {p[0], f.y, p[1]}
}

// --- drawing a new one --------------------------------------------------------

floor_draw_begin :: proc(ed: ^Editor) {
	clear(&ed.floor_draw)
	ed.floor_drawing = true
	ed.sel = {}
}

floor_draw_cancel :: proc(ed: ^Editor) {
	clear(&ed.floor_draw)
	ed.floor_drawing = false
	ed.floor_shut = false
}

// Whether the ray is on the first corner with enough corners behind it to make
// a pad. This is the close: there is no button, and a shape shuts where it was
// started, the way it reads on screen.
floor_draw_shuts :: proc(ed: ^Editor, ray: gfx.Ray) -> bool {
	if len(ed.floor_draw) < geo.FLOOR_MIN_VERTS {
		return false
	}
	return gfx.GetRayCollisionSphere(ray, ed.floor_draw[0], FLOOR_SHUT_R).hit
}

// Close the outline into a pad. Its height is the mean of the ground it was
// drawn over, so a fresh pad cuts the high half and leaves the low half alone —
// which is the shape of the thing being asked for, and a sane place to drag from.
floor_draw_close :: proc(ed: ^Editor) {
	defer floor_draw_cancel(ed)
	if len(ed.floor_draw) < geo.FLOOR_MIN_VERTS {
		set_status(&ed.status, "a floor needs at least 3 corners", false)
		return
	}
	verts := make([][2]f32, len(ed.floor_draw), context.temp_allocator)
	y: f32
	for p, i in ed.floor_draw {
		verts[i] = {p.x, p.z}
		y += p.y
	}
	y /= f32(len(ed.floor_draw))

	i := geo.floor_add(&ed.doc.terrain, verts, y, ed.floor_opts)
	if i < 0 {
		return
	}
	ed.sel = {kind = .Floor, idx = i}
	mark_terrain_dirty(ed.doc)
	set_status(&ed.status, fmt.tprintf("floor %d placed, %d corners", i, len(verts)), true)
}

// The click that puts a corner down, and the keys that end the outline. Returns
// true while the outline owns the input, which is what holds the road's own
// right-click verbs off.
floor_draw_input :: proc(ed: ^Editor, ray: gfx.Ray, nav, ui_mouse, ui_keys: bool) -> bool {
	if !ed.floor_drawing {
		return false
	}
	ed.floor_shut = !nav && !ui_mouse && floor_draw_shuts(ed, ray)
	if !ui_keys {
		if gfx.IsKeyPressed(.ESCAPE) {
			floor_draw_cancel(ed)
			return true
		}
		if gfx.IsKeyPressed(.ENTER) || gfx.IsKeyPressed(.KP_ENTER) {
			floor_draw_close(ed)
			return true
		}
	}
	if nav || ui_mouse {
		return true
	}
	if gfx.IsMouseButtonPressed(.LEFT) {
		if ed.floor_shut {
			floor_draw_close(ed)
			return true
		}
		if len(ed.floor_draw) >= geo.FLOOR_MAX_VERTS {
			set_status(&ed.status, fmt.tprintf("a floor holds %d corners", geo.FLOOR_MAX_VERTS), false)
			return true
		}
		if at, ok := pick_ground(ed, ray); ok {
			append(&ed.floor_draw, at)
		} else {
			set_status(&ed.status, "point at the ground to put a corner there", false)
		}
	}
	return true
}

// --- picking ------------------------------------------------------------------

// Nearest outline vertex the ray strikes, over every pad.
pick_floor_vert :: proc(t: ^geo.Terrain, ray: gfx.Ray) -> (fi, v: int, dist: f32) {
	fi, v, dist = -1, -1, max(f32)
	for f, i in t.floors {
		if f.count < geo.FLOOR_MIN_VERTS {
			continue
		}
		for _, k in geo.floor_verts(t, f) {
			hit := gfx.GetRayCollisionSphere(ray, floor_vert_pos(t, i, k), FLOOR_HANDLE_R)
			if hit.hit && hit.distance < dist {
				fi, v, dist = i, k, hit.distance
			}
		}
	}
	return
}

// The pad whose surface the ray lands on, by intersecting its own plane. Nearest
// first, so a pad stacked over another picks the one in front.
pick_floor :: proc(t: ^geo.Terrain, ray: gfx.Ray) -> (fi: int, dist: f32) {
	fi, dist = -1, max(f32)
	if abs(ray.direction.y) < 1e-6 {
		return
	}
	for f, i in t.floors {
		if f.count < geo.FLOOR_MIN_VERTS {
			continue
		}
		d := (f.y - ray.position.y) / ray.direction.y
		if d < 0 || d >= dist {
			continue
		}
		at := ray.position + ray.direction * d
		if geo.poly_signed_dist(geo.floor_verts(t, f), {at.x, at.z}) <= 0 {
			fi, dist = i, d
		}
	}
	return
}

// --- the gizmo ----------------------------------------------------------------

// Whole pad or one corner, on the same translate gizmo. A corner takes XZ only:
// a pad has one height, and that is the pad's own handle.
floor_gizmo :: proc(ed: ^Editor, cam3d: gfx.Camera3D) -> bool {
	t := &ed.doc.terrain
	fi := selected_floor(ed)
	if fi < 0 {
		return false
	}
	_, vert := selected_floor_vert(ed)

	at: gfx.Vector3
	if vert >= 0 {
		at = floor_vert_pos(t, fi, vert)
	} else {
		c := geo.floor_centre(t, fi)
		at = {c[0], t.floors[fi].y, c[1]}
	}

	to, _, used := ui.gizmo_manipulate_xform(at, gfx.Quaternion(1), cam3d, .Translate, .World)
	if !used {
		return false
	}
	d := [2]f32{to.x - at.x, to.z - at.z}
	if vert >= 0 {
		geo.floor_verts(t, t.floors[fi])[vert] += d
	} else {
		geo.floor_move(t, fi, d)
		t.floors[fi].y = to.y
	}
	mark_terrain_dirty(ed.doc)
	return true
}

// --- edits --------------------------------------------------------------------

// Right-click on an outline puts a corner in the edge nearest the cursor, which
// mirrors what right-clicking the ribbon does to the road.
floor_insert_vert :: proc(ed: ^Editor, ray: gfx.Ray) -> bool {
	t := &ed.doc.terrain
	fi := selected_floor(ed)
	if fi < 0 {
		return false
	}
	at, ok := pick_ground(ed, ray)
	if !ok {
		return false
	}
	e, d2 := geo.floor_nearest_edge(t, fi, {at.x, at.z})
	if e < 0 || d2 > FLOOR_HANDLE_R * FLOOR_HANDLE_R * 4 {
		return false
	}
	v := geo.floor_vert_insert(t, fi, e, {at.x, at.z})
	if v < 0 {
		return false
	}
	ed.sel = {kind = .Floor_Vert, idx = fi, sub = v}
	mark_terrain_dirty(ed.doc)
	return true
}

// Delete takes the corner when one is selected and the whole pad otherwise.
floor_delete :: proc(ed: ^Editor) -> bool {
	t := &ed.doc.terrain
	fi, v := selected_floor_vert(ed)
	if fi >= 0 {
		if !geo.floor_vert_remove(t, fi, v) {
			set_status(&ed.status, fmt.tprintf("a floor needs %d corners", geo.FLOOR_MIN_VERTS), false)
			return true
		}
		ed.sel = {kind = .Floor, idx = fi}
		mark_terrain_dirty(ed.doc)
		return true
	}
	if fi = selected_floor(ed); fi < 0 {
		return false
	}
	geo.floor_remove(t, fi)
	ed.sel = {}
	mark_terrain_dirty(ed.doc)
	return true
}

// --- drawing ------------------------------------------------------------------

FLOOR_COL :: gfx.Color{120, 170, 255, 255}
FLOOR_SEL_COL :: gfx.Color{255, 200, 90, 255}
FLOOR_VERT_COL :: gfx.Color{255, 120, 60, 255}

draw_floors :: proc(ed: ^Editor) {
	t := &ed.doc.terrain
	sel := selected_floor(ed)
	_, sel_vert := selected_floor_vert(ed)
	for f, i in t.floors {
		if f.count < geo.FLOOR_MIN_VERTS {
			continue
		}
		verts := geo.floor_verts(t, f)
		col := i == sel ? FLOOR_SEL_COL : FLOOR_COL
		for k in 0 ..< len(verts) {
			a := verts[k]
			b := verts[(k + 1) % len(verts)]
			gfx.DrawLine3D({a[0], f.y, a[1]}, {b[0], f.y, b[1]}, col)
		}
		for _, k in verts {
			hcol := i == sel && k == sel_vert ? FLOOR_VERT_COL : col
			gfx.DrawSphereEx(floor_vert_pos(t, i, k), FLOOR_HANDLE_R, 3, 4, hcol)
		}
	}

	// The outline being drawn: open, and at the heights it was picked at. The
	// first corner wears the closing edge as soon as the cursor is on it, so
	// the shape you would get is on screen before the click that takes it.
	for k in 0 ..< len(ed.floor_draw) {
		gfx.DrawSphereEx(ed.floor_draw[k], FLOOR_HANDLE_R, 3, 4, FLOOR_SEL_COL)
		if k > 0 {
			gfx.DrawLine3D(ed.floor_draw[k - 1], ed.floor_draw[k], FLOOR_SEL_COL)
		}
	}
	if ed.floor_shut {
		first, last := ed.floor_draw[0], ed.floor_draw[len(ed.floor_draw) - 1]
		gfx.DrawSphereEx(first, FLOOR_SHUT_R, 3, 4, FLOOR_VERT_COL)
		gfx.DrawLine3D(last, first, FLOOR_VERT_COL)
	}
}
