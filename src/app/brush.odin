package main

// The two selection brushes, and the one gesture they share.
//
// LMB grabs a gizmo, RMB joins it to size a brush around what the gizmo holds,
// and releasing RMB turns the same drag into a move of everything the brush
// caught. `brush_step` is that gesture; what each brush selects and what a move
// does to it is the brush's own business, and the two never touch the same
// thing: a Selection is a terrain node or a road point, never both.
//
// Terrain takes whatever is inside a radius on the ground, all of it equally.
// The road measures along the road instead — a hairpin folds back on itself, so
// a radius would catch the far side of it — and falls off across that distance,
// which is what turns a pull upward into a ramp rather than a step.

import "core:fmt"
import "../geo"
import "../ui"
import "../gfx"

// How far a road brush can reach along the road, either way from its anchor.
ROAD_BRUSH_MAX_M :: 2000.0

Brush_Phase :: enum {
	None,
	Size,
	Move,
}

// The gesture's own state, shared by both brushes. `radius_start` and `mouse_y`
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

// The live brush's reach and what it has hold of, over the viewport. Only one
// can be live, so there is only ever one line.
brush_overlay :: proc(ed: ^Editor) {
	txt: cstring
	switch {
	case ed.terrain_brush.phase != .None:
		n := 0
		for on in ed.terrain_brush_mask {
			if on {
				n += 1
			}
		}
		txt = fmt.ctprintf("terrain brush: %d controls  %.0f m", n, ed.terrain_brush.radius)
	case len(ed.road_brush_weight) > 0:
		n := 0
		for w in ed.road_brush_weight {
			if w > 0 {
				n += 1
			}
		}
		txt = fmt.ctprintf("road brush: %d points  %.0f m of road", n, ed.road_brush.radius)
	case:
		return
	}
	ui.draw_overlay_text_centered(txt, 40, 72, f32(gfx.GetScreenWidth()), 0xff50beff)
}

// --- terrain ------------------------------------------------------------------

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

// --- road ---------------------------------------------------------------------

// The road brush is a *selection*, not a gesture that ends in a move. Sizing it
// leaves it standing, and the ordinary gizmo then drags the whole of it: grab an
// arrow and the selection slides, grab a ring and it turns, each point taking
// the weighted share of the anchor's own edit. Clicking away drops it, the same
// click that drops the selected point.

// One control point as the drag found it. Every frame of that drag is measured
// from here rather than from wherever the last frame left the point, so a drag
// back the way it came takes the road back where it was. `fwd` is the slope the
// road ran through this point at, and what a re-aim turns away from.
Road_Brush_Snap :: struct {
	pos: gfx.Vector3,
	rot: gfx.Quaternion,
	fwd: gfx.Vector3,
}

road_brush_clear :: proc(ed: ^Editor) {
	ed.road_brush.phase = .None
	ed.road_brush_anchor_id = -1
	clear(&ed.road_brush_weight)
	clear(&ed.road_brush_snap)
}

// Drop a selection that has stopped meaning anything. The weights name array
// positions and hang off one anchor, so the moment the selection moves off that
// anchor, or an edit renumbers the array under them, they name the wrong road.
// The same job resolve_node_selection does for a terrain node.
road_brush_resolve :: proc(ed: ^Editor) {
	if len(ed.road_brush_weight) == 0 {
		return
	}
	pi := selected_point(ed)
	if pi < 0 || len(ed.road_brush_weight) != len(ed.doc.spline.points) ||
	   geo.point_id(ed.doc.spline, pi) != ed.road_brush_anchor_id {
		road_brush_clear(ed)
	}
}

// How much of the anchor's edit each control point takes: all of it at the
// anchor, tapering to none at the far end of the brush's reach.
//
// Distance is metres *along the road*, from the same graph walk the cliffs and
// the stage search use, so the brush runs past a fork into both branches and
// over a weld into the road it closes, and never catches the far side of a
// hairpin the way a radius would. The falloff is the cliff envelope: a plateau
// with smoothstepped shoulders, so `taper` at 1 is a pure ramp and at 0 is the
// hard-edged cylinder the terrain brush cuts.
road_brush_select :: proc(ed: ^Editor, anchor: int) {
	sp := &ed.doc.spline
	resize(&ed.road_brush_weight, len(sp.points))
	for &w in ed.road_brush_weight {
		w = 0
	}
	if anchor < 0 || anchor >= len(sp.points) {
		return
	}
	ed.road_brush_anchor_id = geo.point_id(sp^, anchor)
	r := ed.road_brush.radius
	dist := geo.graph_reach(sp^, anchor, r)
	taper := r * clamp(ed.road_brush_taper, 0, 1)
	for d, i in dist {
		ed.road_brush_weight[i] = geo.cliff_envelope(d, r * 2, taper)
	}
	ed.road_brush_weight[anchor] = 1 // a zero reach is a single-point brush, not an empty one
}

// The road's direction through a control point: parent to child, or the one
// edge it has at an end. Zero-length when it has neither.
road_point_tangent :: proc(sp: geo.Spline, i: int) -> gfx.Vector3 {
	here := sp.points[i].xform.translation
	before, after := here, here
	if p := sp.points[i].parent; p >= 0 && p < len(sp.points) {
		before = sp.points[p].xform.translation
	}
	if c := geo.first_child(sp, i); c >= 0 {
		after = sp.points[c].xform.translation
	}
	return after - before
}

road_brush_snapshot :: proc(ed: ^Editor) {
	sp := ed.doc.spline
	resize(&ed.road_brush_snap, len(sp.points))
	for p, i in sp.points {
		ed.road_brush_snap[i] = {
			pos = p.xform.translation,
			rot = p.xform.rotation,
			fwd = road_point_tangent(sp, i),
		}
	}
}

// Carry the anchor's edit across the selection, each point taking its weighted
// share of it, and then turn every point onto the slope the edit left it on.
//
// The turn is expressed in the anchor's own frame before it is shared out, so a
// roll of the anchor is a roll of every point about its own heading rather than
// about the anchor's: banking a stretch stays banking all the way round a bend.
//
// The re-aim is not optional decoration. A Hermite segment leaves each point
// along that point's *rotation*, so shifting a run of points without turning
// them leaves a road that flattens at every one of them and pulses the gradient
// in between. The shortest arc from a point's old slope to its new one, on the
// left of everything else, adds exactly the turn the edit earned and leaves the
// bank and any hand-dialled slope alone. A pure gizmo rotation moves nothing, so
// it re-aims by nothing; a pure translation asks for no turn, so all it gets is
// the re-aim.
//
// Positions all land before any tangent is read: a tangent is its neighbours'
// positions, and half-moved neighbours would aim it at nothing.
road_brush_move :: proc(ed: ^Editor, anchor: int, to: gfx.Transform) {
	sp := &ed.doc.spline
	n := min(len(sp.points), len(ed.road_brush_weight), len(ed.road_brush_snap))
	if anchor < 0 || anchor >= n {
		return
	}
	base := ed.road_brush_snap[anchor]
	shift := to.translation - base.pos
	turn := conj(base.rot) * to.rotation // the anchor's turn, in the anchor's frame

	for i in 0 ..< n {
		sp.points[i].xform.translation = ed.road_brush_snap[i].pos +
			shift * ed.road_brush_weight[i]
	}
	for i in 0 ..< n {
		was := ed.road_brush_snap[i]
		rot := was.rot * gfx.QuaternionSlerp(1, turn, ed.road_brush_weight[i])
		// A point with no edge either side has no slope to be turned onto.
		if now := road_point_tangent(sp^, i);
		   gfx.Vector3Length(was.fwd) > 1e-5 && gfx.Vector3Length(now) > 1e-5 {
			rot = gfx.QuaternionFromVector3ToVector3(was.fwd, now) * rot
		}
		sp.points[i].xform.rotation = rot
	}
	mark_dirty(ed.doc)
}

// The road-point gizmo, and the brush that sizes a selection under it.
//
// The anchor is held still for the whole of the sizing gesture, right through
// to the release of LMB. ImGuizmo recomputes its drag from where the drag
// began rather than from the transform it is handed, so letting go of it early
// would land every pixel travelled during sizing in one frame. Held to the end,
// the drag that sized the selection edits nothing, and the next one moves all
// of it.
road_brush_gizmo :: proc(ed: ^Editor, pi: int, cam3d: gfx.Camera3D) -> (used: bool) {
	act, _ := brush_step(
		&ed.road_brush,
		gfx.GetMousePosition().y,
		// Reach is measured in road metres and runs to kilometres, so sizing
		// moves further per pixel than the terrain brush does.
		clamp(world_per_pixel(ed, cam3d) * 8, 0.5, 20),
		0, // the gizmo does the moving; brush_step's own move delta is unused
		ROAD_BRUSH_MAX_M,
	)
	if act == .Enter {
		ed.road_brush_anchor = ed.doc.spline.points[pi].xform
	}
	before := ed.doc.spline.points[pi].xform
	dragging := gizmo_manipulate(&ed.doc.spline.points[pi], cam3d, ed.gizmo_mode)
	after := ed.doc.spline.points[pi].xform
	if act != .None {
		ed.doc.spline.points[pi].xform = ed.road_brush_anchor
		ed.road_gizmo_drag = false
	}

	used = act != .None
	switch act {
	case .Enter, .Select:
		road_brush_select(ed, pi)
	case .Snap, .Move, .Clear:
		// Sizing is over and the selection stands. Nothing to do but go on
		// holding the anchor until the drag that sized it is let go of.
	case .None:
		used = dragging
		if !dragging {
			ed.road_gizmo_drag = false
			return
		}
		if len(ed.road_brush_weight) == 0 {
			mark_dirty(ed.doc) // one point, moved by the gizmo alone
			return
		}
		// The snapshot has to predate the drag, and this is the first frame
		// that can know the drag has begun — so put the anchor back, snapshot,
		// and let the gizmo's edit land through the selection instead.
		if !ed.road_gizmo_drag {
			ed.road_gizmo_drag = true
			ed.doc.spline.points[pi].xform = before
			road_brush_snapshot(ed)
		}
		road_brush_move(ed, pi, after)
	}
	return
}
