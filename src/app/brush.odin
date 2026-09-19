package main

// The selection brush, and the gesture it runs on.
//
// LMB grabs a gizmo, RMB joins it to size a brush around what the gizmo holds,
// and releasing RMB turns the same drag into a move of everything the brush
// caught. `brush_step` is that gesture, kept apart from what any one brush
// selects and what a move does to it, so a second brush over a different kind
// of handle is a second caller rather than a second copy.

import "core:fmt"
import "../geo"
import "../ui"
import "../gfx"

Brush_Phase :: enum {
	None,
	Size,
	Move,
}

// The gesture's own state. `radius_start` and `mouse_y`
// are where a drag began, so sizing and moving are both absolute against the
// press rather than accumulated per frame.
Brush :: struct {
	phase:        Brush_Phase,
	radius:       f32,
	radius_start: f32,
	mouse_y:      f32,
}

// What the caller owes the brush this frame. Each is one thing to do, so a
// caller is a switch with no state of its own.
Brush_Act :: enum {
	None,   // no brush: the caller's ordinary gizmo has the frame
	Enter,  // the brush just took it: hold the anchor still, then select
	Select, // the radius moved: select again
	Snap,   // sizing is over: take the snapshot the move measures from
	Move,   // shift everything selected by `dy`, weighted
	Clear,  // released
}

// One frame of the gesture. `size_per_px` and `move_per_px` are world metres
// per pixel of mouse travel, so a drag feels the same close in or pulled back.
brush_step :: proc(
	b: ^Brush, mouse_y, size_per_px, move_per_px, max_radius: f32,
) -> (act: Brush_Act, dy: f32) {
	left := gfx.IsMouseButtonDown(.LEFT)
	right := gfx.IsMouseButtonDown(.RIGHT)

	// RMB joining the drag starts sizing, and may join again mid-move to
	// re-size without dropping what is held. Movement before the first join is
	// intentional single-handle editing; a later join keeps it and re-anchors.
	if b.phase != .Size && left && right {
		b.phase = .Size
		b.mouse_y = mouse_y
		b.radius_start = b.radius
		return .Enter, 0
	}
	switch b.phase {
	case .Size:
		if !left {
			b.phase = .None
			return .Clear, 0
		}
		if right {
			b.radius = clamp(
				b.radius_start + (b.mouse_y - mouse_y) * size_per_px, 0, max_radius,
			)
			return .Select, 0
		}
		b.phase = .Move
		b.mouse_y = mouse_y
		return .Snap, 0
	case .Move:
		if !left {
			b.phase = .None
			return .Clear, 0
		}
		return .Move, (b.mouse_y - mouse_y) * move_per_px
	case .None:
	}
	return .None, 0
}

// Whether the brush is sizing. These are the frames whose gizmo output is
// thrown away: sizing changes what is held and never a height, and ImGuizmo
// has to go on receiving the drag either way or it resumes later with the
// whole accumulated delta and snaps the anchor.
brush_sizing :: proc(act: Brush_Act) -> bool {
	return act == .Enter || act == .Select || act == .Snap
}

// The live brush's reach and what it has hold of, over the viewport.
brush_overlay :: proc(ed: ^Editor) {
	if ed.terrain_brush.phase == .None {
		return
	}
	n := 0
	for on in ed.terrain_brush_mask {
		if on {
			n += 1
		}
	}
	txt := fmt.ctprintf("terrain brush: %d controls  %.0f m", n, ed.terrain_brush.radius)
	ui.draw_overlay_text_centered(txt, 40, 72, f32(gfx.GetScreenWidth()), 0xff50beff)
}

terrain_brush_clear :: proc(ed: ^Editor) {
	ed.terrain_brush.phase = .None
	clear(&ed.terrain_brush_mask)
	clear(&ed.terrain_brush_offsets)
}

terrain_brush_select :: proc(ed: ^Editor, node_pos: []gfx.Vector3, selected: int) {
	resize(&ed.terrain_brush_mask, len(node_pos))
	for &affected in ed.terrain_brush_mask {
		affected = false
	}
	if selected < 0 || selected >= len(node_pos) {
		return
	}
	centre := node_pos[selected]
	r2 := ed.terrain_brush.radius * ed.terrain_brush.radius
	for p, i in node_pos {
		dx, dz := p.x - centre.x, p.z - centre.z
		ed.terrain_brush_mask[i] = i == selected || dx * dx + dz * dz <= r2
	}
}

terrain_brush_snapshot :: proc(ed: ^Editor) {
	resize(&ed.terrain_brush_offsets, len(ed.doc.terrain.controls))
	for c, i in ed.doc.terrain.controls {
		ed.terrain_brush_offsets[i] = c.offset
	}
}

// Every masked control back to its snapshot height, plus dy. The bounds hold
// against a rebuild that resized the controls under a live brush.
terrain_brush_apply :: proc(ed: ^Editor, dy: f32) {
	for &c, i in ed.doc.terrain.controls {
		if i < len(ed.terrain_brush_mask) && i < len(ed.terrain_brush_offsets) &&
		   ed.terrain_brush_mask[i] {
			c.offset = ed.terrain_brush_offsets[i] + dy
		}
	}
	mark_terrain_dirty(ed.doc)
}

// The terrain-node gizmo and the brush that grows out of it. Returns whether it
// owns the mouse this frame.
terrain_brush_gizmo :: proc(
	ed: ^Editor, node_pos: []gfx.Vector3, sel_node: int, cam3d: gfx.Camera3D,
) -> (used: bool) {
	act, dy := brush_step(
		&ed.terrain_brush,
		gfx.GetMousePosition().y,
		clamp(world_per_pixel(ed, cam3d) * 2, 0.1, 2),
		clamp(world_per_pixel(ed, cam3d), 0.01, 1),
		ed.doc.terrain.reach_m * 4,
	)
	live := ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.terrain.controls)
	if act == .Enter && live {
		ed.terrain_brush_anchor = ed.doc.terrain.controls[ed.sel.idx].offset
	}
	gizmo_y, gizmo_dragging := ui.gizmo_manipulate_height(node_pos[sel_node], cam3d)
	if brush_sizing(act) && live {
		ed.doc.terrain.controls[ed.sel.idx].offset = ed.terrain_brush_anchor
	}

	used = act != .None
	switch act {
	case .Enter, .Select:
		terrain_brush_select(ed, node_pos, sel_node)
	case .Snap:
		terrain_brush_snapshot(ed)
	case .Move:
		terrain_brush_apply(ed, dy)
	case .Clear:
		terrain_brush_clear(ed)
	case .None:
		// Height only, so an ordinary LMB drag keeps the single-control gizmo.
		if gizmo_dragging {
			geo.terrain_set_node(&ed.doc.terrain, ed.sel.idx, gizmo_y)
			mark_terrain_dirty(ed.doc)
		}
		used = gizmo_dragging
	}
	return
}
