package main

// The editor's own gizmo wrappers. The ImGuizmo binding in ui/ speaks matrices;
// these two procedures are the only place that knows a handle is attached to a
// road control point.

import "../geo"
import "../ui"
import rl "vendor:raylib"

// Draw the gizmo on `p` and, while it is dragged, fold the result back into the
// point's transform. Returns true while dragging.
//
// Translation is world-aligned (drag along world X/Y/Z), rotation is
// object-aligned so the rings match the road frame: yaw steers, pitch slopes,
// roll banks. Scale is never offered — road width is a separate scalar.
gizmo_manipulate :: proc(p: ^geo.Point, cam: rl.Camera3D, mode: Gizmo_Mode) -> bool {
	op: ui.Gizmo_Operation = mode == .Move ? .Translate : .Rotate
	space: ui.Gizmo_Space = mode == .Move ? .World : .Local

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
