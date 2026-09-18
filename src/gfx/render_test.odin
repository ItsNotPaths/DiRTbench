package gfx

import "core:math"
import "core:testing"
import sdl "vendor:sdl3"

// The Vulkan backend refuses device creation unless the properties carry the
// SPIR-V shader flag. Locks the bring-up contract without needing a display.
@(test)
device_props_select_vulkan_with_spirv :: proc(t: ^testing.T) {
	props := gpu_device_props()
	defer sdl.DestroyProperties(props)
	testing.expect_value(
		t,
		sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_CREATE_NAME_STRING, ""),
		cstring("vulkan"),
	)
	testing.expect(
		t,
		sdl.GetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, false),
	)
}

// The MVP applies model, then view, then projection. Reversing the order
// projects world coordinates as if the camera sat at the origin, so all but
// a sliver of fragments clip away.
@(test)
scene_mvp_applies_projection_last :: proc(t: ^testing.T) {
	active_camera = Camera3D {
		position = {0, 0, 5},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fovy = math.PI / 2,
		projection = .PERSPECTIVE,
	}
	active_projection = MatrixPerspective(math.PI / 2, 640.0 / 480.0, 0.1, 100)
	c := scene_mvp(Matrix(1)) * [4]f32{0, 0, 0, 1}
	testing.expect(t, c[3] > 0)
	ndc := Vector3{c[0] / c[3], c[1] / c[3], c[2] / c[3]}
	testing.expect(t, abs(ndc.x) < 1e-5 && abs(ndc.y) < 1e-5)
	testing.expect(t, ndc.z > 0 && ndc.z < 1)
}

// The shader reads the pushed floats as column-major, so the translation of
// a matrix must land in the fourth pushed column.
@(test)
mvp_upload_is_column_major :: proc(t: ^testing.T) {
	v := MatrixToFloatV(Matrix{1, 0, 0, 5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1})
	testing.expect(t, v[3] == 0 && v[12] == 5 && v[15] == 1)
}

// Every event the UI needs has to name its window, or PollWindowEvents drops it
// before ImGui ever sees it. Text input is the one that bites: keys still route,
// so the field takes backspace and no characters.
@(test)
event_window_id_routes_typed_text :: proc(t: ^testing.T) {
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.windowID = 7
	testing.expect_value(t, event_window_id(&ev), sdl.WindowID(7))

	ev = {}
	ev.type = .TEXT_EDITING
	ev.edit.windowID = 9
	testing.expect_value(t, event_window_id(&ev), sdl.WindowID(9))
}
