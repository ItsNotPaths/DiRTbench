package ui

// Odin bindings for ImGuizmo, via cimguizmo's flat C API, plus the raylib glue
// that feeds it. Vendored into vendor/imgui/libimgui.a alongside Dear ImGui
// itself — ImGuizmo draws through ImGui's draw list and reads ImGui's input, so
// the two are one dependency, not two. See imgui.odin.
//
// ImGuizmo is immediate-mode: a manipulate call both draws the gizmo and, when
// dragged, hands back the new transform. The gizmo holds a constant size on
// screen regardless of camera distance, which is ImGuizmo's native behaviour.

import "core:c"
import rl "../gfx"

// ImGuizmo lives in the same archive as ImGui. `foreign import` is file-scoped,
// so this restates the import from imgui.odin rather than sharing it.
foreign import imgui_lib {
	"../../vendor/imgui/libimgui.a",
}

// --- cimguizmo --------------------------------------------------------------

// Bitmask of the axes/handles a gizmo offers. Only the composite values we use
// are named; the per-axis bits are (1<<0)..(1<<9), see vendor/imgui/cimguizmo.h.
Gizmo_Operation :: enum c.int {
	Translate_Y = 0x2,   // TRANSLATE_Y alone — the terrain lattice's only freedom
	Translate   = 0x7,   // TRANSLATE_X | _Y | _Z
	Rotate      = 0x78,  // ROTATE_X | _Y | _Z | _SCREEN
	Scale       = 0x380, // SCALE_X | _Y | _Z
}

// Whether handles align to the object's own axes or to the world axes.
Gizmo_Space :: enum c.int {
	Local = 0,
	World = 1,
}

@(default_calling_convention = "c")
foreign imgui_lib {
	// Per-frame setup. Claims a full-screen, input-transparent ImGui window to
	// draw into, so it must be called inside the ImGui frame.
	@(link_name = "ImGuizmo_BeginFrame")
	gizmo_begin_frame :: proc() ---

	// The screen rect the gizmo projects into; must match the raylib viewport.
	@(link_name = "ImGuizmo_SetRect")
	gizmo_set_rect :: proc(x, y, width, height: f32) ---

	@(link_name = "ImGuizmo_SetOrthographic")
	gizmo_set_orthographic :: proc(is_orthographic: bool) ---

	// When disabled the gizmo still draws, greyed, but ignores the mouse.
	@(link_name = "ImGuizmo_Enable")
	gizmo_enable :: proc(enable: bool) ---

	// Draws the gizmo and, while dragged, writes the manipulated transform back
	// into `xform`. All matrices are column-major float[16], i.e. exactly what
	// rl.MatrixToFloatV produces. Returns true while the gizmo is being dragged.
	// The trailing four arguments (delta, snap, bounds, bounds snap) are
	// optional; pass nil.
	@(link_name = "ImGuizmo_Manipulate")
	gizmo_manipulate_raw :: proc(view, projection: [^]f32, operation: Gizmo_Operation, space: Gizmo_Space, xform: [^]f32, delta_matrix: [^]f32, snap: [^]f32, local_bounds: [^]f32, bounds_snap: [^]f32) -> bool ---

	// True while a handle is being dragged.
	@(link_name = "ImGuizmo_IsUsing")
	gizmo_is_using :: proc() -> bool ---

	// True when a handle is under the cursor, i.e. a click would grab the gizmo
	// rather than the scene.
	@(link_name = "ImGuizmo_IsOver_Nil")
	gizmo_is_over :: proc() -> bool ---
}

// --- raylib glue ------------------------------------------------------------

// A column-major float[16], the layout ImGuizmo reads and writes.
Gizmo_Matrix :: [16]f32

// Inverse of rl.MatrixToFloatV. rl.Matrix is #row_major, so a raw [16]f32 in
// ImGuizmo's column-major order transmutes into its transpose.
matrix_from_float_v :: proc(v: Gizmo_Matrix) -> rl.Matrix {
	m := transmute(rl.Matrix)v
	return rl.MatrixTranspose(m)
}

// The camera's view and projection matrices, matching what rl.BeginMode3D
// installs — the gizmo must project exactly as the scene does or its handles
// will not sit on the object.
//
// The clip planes are read back from rlgl rather than assumed, because main.odin
// overrides them (rlgl.SetClipPlanes); baking in rlgl's stock 0.01..1000 here
// would leave the gizmo projecting differently from the scene.
camera_matrices :: proc(cam: rl.Camera3D) -> (view, proj: Gizmo_Matrix) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	near := f32(rl.GetCullDistanceNear())
	far := f32(rl.GetCullDistanceFar())
	view = rl.MatrixToFloatV(rl.GetCameraMatrix(cam))
	proj = rl.MatrixToFloatV(rl.MatrixPerspective(cam.fovy * rl.DEG2RAD, w / h, near, far))
	return
}

// Draw a translate or rotate gizmo on a transform and, while it is dragged,
// return the manipulated transform. Caller-agnostic on purpose: this package
// knows matrices, not road points. See the editor's gizmo.odin for the wrapper
// that folds the result back into a spline control point.
gizmo_manipulate_xform :: proc(
	pos: rl.Vector3,
	rot: rl.Quaternion,
	cam: rl.Camera3D,
	op: Gizmo_Operation,
	space: Gizmo_Space,
) -> (
	out_pos: rl.Vector3,
	out_rot: rl.Quaternion,
	used: bool,
) {
	view, proj := camera_matrices(cam)
	m := rl.MatrixTranslate(pos.x, pos.y, pos.z) * rl.QuaternionToMatrix(rot)
	xform := rl.MatrixToFloatV(m)

	out_pos, out_rot = pos, rot
	used = gizmo_manipulate_raw(&view[0], &proj[0], op, space, &xform[0], nil, nil, nil, nil)
	if used {
		out := matrix_from_float_v(xform)
		out_pos = {out[0, 3], out[1, 3], out[2, 3]}
		// The rotation is read back off the 3x3 basis. Renormalise: the gizmo
		// composes deltas every frame of a drag, so error accumulates.
		out_rot = rl.QuaternionNormalize(rl.QuaternionFromMatrix(out))
	}
	return
}

// A single vertical handle at `pos`, for a terrain lattice node (terrain.odin).
// Only the new height is read back: a node has no rotation, and its XZ is
// derived from the ribbon, not stored. Nothing here holds a pointer into the
// lattice, so a resize between frames cannot dangle.
gizmo_manipulate_height :: proc(pos: rl.Vector3, cam: rl.Camera3D) -> (y: f32, used: bool) {
	view, proj := camera_matrices(cam)
	xform := rl.MatrixToFloatV(rl.MatrixTranslate(pos.x, pos.y, pos.z))
	used = gizmo_manipulate_raw(
		&view[0], &proj[0],
		.Translate_Y, .World,
		&xform[0], nil, nil, nil, nil,
	)
	y = pos.y
	if used {
		y = matrix_from_float_v(xform)[1, 3]
	}
	return
}
