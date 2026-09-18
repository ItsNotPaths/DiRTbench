package main

// The editor's own gizmo wrappers. The ImGuizmo binding in ui/ speaks matrices;
// these two procedures are the only place that knows a handle is attached to a
// road control point.

import "../geo"
import "../ui"
import "../gfx"

// Translation is world-aligned (drag along world X/Y/Z), rotation is
// object-aligned so the rings match the thing being turned: on a road point
// yaw steers, pitch slopes, roll banks. Scale is never offered.
gizmo_op_space :: proc(mode: Gizmo_Mode) -> (op: ui.Gizmo_Operation, space: ui.Gizmo_Space) {
	if mode == .Move {
		return .Translate, .World
	}
	return .Rotate, .Local
}

// Draw the gizmo on `p` and, while it is dragged, fold the result back into the
// point's transform. Returns true while dragging.
gizmo_manipulate :: proc(p: ^geo.Point, cam: gfx.Camera3D, mode: Gizmo_Mode) -> bool {
	op, space := gizmo_op_space(mode)
	pos, rot, used := ui.gizmo_manipulate_xform(
		p.xform.translation,
		p.xform.rotation,
		cam,
		op,
		space,
	)
	if used {
		p.xform.translation = pos
		p.xform.rotation = rot
	}
	return used
}

// The same, on a placed prop.
prop_gizmo :: proc(ed: ^Editor, idx: int, cam: gfx.Camera3D) -> bool {
	inst := &ed.doc.props[idx]
	op, space := gizmo_op_space(ed.gizmo_mode)
	pos, rot, used := ui.gizmo_manipulate_xform(inst.pos, inst.rot, cam, op, space)
	if used {
		inst.pos = pos
		inst.rot = rot
		mark_edited(ed.doc)
	}
	return used
}
