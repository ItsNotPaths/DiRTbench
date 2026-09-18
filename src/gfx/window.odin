package gfx

// SDL owns native windows. Each window claims into the shared GPU device from
// render.odin; its swapchain texture is current-frame only, while the depth
// buffer persists across frames and is resized to the swapchain on demand.
// Window state lives on the window so events route by SDL WindowID.

import "core:c"
import sdl "vendor:sdl3"

foreign import imgui "../../vendor/imgui/libimgui.a"
@(default_calling_convention = "c")
foreign imgui {
	dirtImGuiProcessEvent :: proc(event: ^sdl.Event) ---
	dirtImGuiSetCurrent :: proc(ctx: rawptr) ---
}

Window :: struct {
	handle:       ^sdl.Window,
	id:           sdl.WindowID,
	// This window's ImGui context (ui.imgui_backend_setup). Made current with
	// the window, so "the active window" is one idea rather than two.
	imgui:        rawptr,
	width:        i32,
	height:       i32,
	swapchain:    ^sdl.GPUTexture,
	swapchain_w:  i32,
	swapchain_h:  i32,
	depth:        ^sdl.GPUTexture,
	depth_w:      i32,
	depth_h:      i32,
	cmd:          ^sdl.GPUCommandBuffer,
	clear:        sdl.FColor,
	scene_drawn:  bool,
	owns_sdl:     bool,
	should_close: bool,
	focused:      bool,
	frame_start:  u64,
	frame_time:   f32,
	mouse:        Vector2,
	mouse_delta:  Vector2,
	wheel:        f32,
	mouse_down:   [3]bool,
	mouse_pressed:[3]bool,
	keys_down:    [512]bool,
	keys_pressed: [512]bool,
}

Key :: enum i32 { ONE, TWO, S, F, P, DELETE, ESCAPE, ENTER, KP_ENTER, LEFT_SHIFT, RIGHT_SHIFT, LEFT_CONTROL, RIGHT_CONTROL, LEFT_ALT, RIGHT_ALT }
MouseButton :: enum i32 { LEFT, RIGHT, MIDDLE }

active_window: ^Window
sdl_users: int
windows: [dynamic]^Window

key_scancode :: proc(key: Key) -> sdl.Scancode {
	switch key {
	case .ONE: return ._1
	case .TWO: return ._2
	case .S: return .S
	case .F: return .F
	case .P: return .P
	case .DELETE: return .DELETE
	case .ESCAPE: return .ESCAPE
	case .ENTER: return .RETURN
	case .KP_ENTER: return .KP_ENTER
	case .LEFT_SHIFT: return .LSHIFT
	case .RIGHT_SHIFT: return .RSHIFT
	case .LEFT_CONTROL: return .LCTRL
	case .RIGHT_CONTROL: return .RCTRL
	case .LEFT_ALT: return .LALT
	case .RIGHT_ALT: return .RALT
	}
	return .UNKNOWN
}

CreateWindow :: proc(window: ^Window, width, height: i32, title: cstring) -> bool {
	if window == nil {
		return false
	}
	window^ = {width = width, height = height}
	if sdl_users == 0 && !sdl.Init(sdl.INIT_VIDEO) {
		return false
	}
	sdl_users += 1
	window.owns_sdl = true

	window.handle = sdl.CreateWindow(title, c.int(width), c.int(height), {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window.handle == nil {
		DestroyWindow(window)
		return false
	}
	if !ensure_gpu() {
		DestroyWindow(window)
		return false
	}
	if !sdl.ClaimWindowForGPUDevice(gpu_device, window.handle) {
		DestroyWindow(window)
		return false
	}
	if !ensure_pipelines(sdl.GetGPUSwapchainTextureFormat(gpu_device, window.handle)) {
		DestroyWindow(window)
		return false
	}
	window.id = sdl.GetWindowID(window.handle)
	w, h: c.int
	_ = sdl.GetWindowSize(window.handle, &w, &h)
	window.width, window.height = i32(w), i32(h)
	window.frame_start = sdl.GetPerformanceCounter()
	window.focused = true
	append(&windows, window)
	active_window = window
	return true
}

DestroyWindow :: proc(window: ^Window) {
	if window == nil {
		return
	}
	if window.depth != nil && gpu_device != nil {
		sdl.ReleaseGPUTexture(gpu_device, window.depth)
		window.depth = nil
	}
	if window.handle != nil {
		if gpu_device != nil {
			sdl.ReleaseWindowFromGPUDevice(gpu_device, window.handle)
		}
		sdl.DestroyWindow(window.handle)
		window.handle = nil
	}
	window.cmd, window.swapchain = nil, nil
	for candidate, i in windows {
		if candidate == window {
			unordered_remove(&windows, i)
			break
		}
	}
	if active_window == window {
		SetActiveWindow(nil)
	}
	if window.owns_sdl {
		window.owns_sdl = false
		sdl_users -= 1
		if sdl_users == 0 {
			drop_gpu()
			delete(windows)
			sdl.Quit()
		}
	}
}

window_by_id :: proc(id: sdl.WindowID) -> ^Window {
	for window in windows {
		if window.id == id {
			return window
		}
	}
	return nil
}

mouse_button_index :: proc(button: u8) -> (int, bool) {
	switch button {
	case sdl.BUTTON_LEFT: return 0, true
	case sdl.BUTTON_RIGHT: return 1, true
	case sdl.BUTTON_MIDDLE: return 2, true
	}
	return 0, false
}

event_window_id :: proc(event: ^sdl.Event) -> sdl.WindowID {
	#partial switch event.type {
	case .WINDOW_CLOSE_REQUESTED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED,
	     .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST: return event.window.windowID
	case .MOUSE_MOTION: return event.motion.windowID
	case .MOUSE_WHEEL: return event.wheel.windowID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP: return event.button.windowID
	case .KEY_DOWN, .KEY_UP: return event.key.windowID
	// Typed characters arrive as their own event, not on the key press. An
	// unrouted one is dropped here, and then no text field takes anything.
	case .TEXT_INPUT: return event.text.windowID
	case .TEXT_EDITING: return event.edit.windowID
	}
	return 0
}

apply_mouse_button_event :: proc(window: ^Window, event: ^sdl.Event) {
	i, known := mouse_button_index(event.button.button)
	if !known {
		return
	}
	pressed := event.type == .MOUSE_BUTTON_DOWN
	window.mouse_down[i] = pressed
	if pressed {
		window.mouse_pressed[i] = true
	}
}

apply_key_event :: proc(window: ^Window, event: ^sdl.Event) {
	i := int(event.key.scancode)
	if i < 0 || i >= len(window.keys_down) {
		return
	}
	pressed := event.type == .KEY_DOWN
	window.keys_down[i] = pressed
	if pressed && !event.key.repeat {
		window.keys_pressed[i] = true
	}
}

apply_window_event :: proc(window: ^Window, event: ^sdl.Event) {
	#partial switch event.type {
	case .WINDOW_CLOSE_REQUESTED: window.should_close = true
	case .WINDOW_FOCUS_GAINED: window.focused = true
	case .WINDOW_FOCUS_LOST: window.focused = false
	case .WINDOW_RESIZED: window.width, window.height = event.window.data1, event.window.data2
	case .WINDOW_PIXEL_SIZE_CHANGED:
		window.swapchain_w, window.swapchain_h = 0, 0
	case .MOUSE_MOTION:
		window.mouse = {event.motion.x, event.motion.y}
		window.mouse_delta += {event.motion.xrel, event.motion.yrel}
	case .MOUSE_WHEEL: window.wheel += event.wheel.y
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP: apply_mouse_button_event(window, event)
	case .KEY_DOWN, .KEY_UP: apply_key_event(window, event)
	}
}

// The active window and its ImGui context move together. Every input query in
// this file and every ImGui call in ui/ reads one of the two, so letting them
// drift apart would feed one window's keystrokes to another window's panels.
SetActiveWindow :: proc(window: ^Window) {
	active_window = window
	dirtImGuiSetCurrent(window == nil ? nil : window.imgui)
}

// The ImGui context this window draws its panels with. Set once, after
// ui.imgui_backend_setup has built it for this window.
SetWindowImGui :: proc(window: ^Window, ctx: rawptr) {
	window.imgui = ctx
}

PollWindowEvents :: proc() {
	for window in windows {
		window.mouse_delta, window.wheel = {}, 0
		window.mouse_pressed = {}
		window.keys_pressed = {}
	}
	event: sdl.Event
	for sdl.PollEvent(&event) {
		if event.type == .QUIT {
			for window in windows {
				window.should_close = true
			}
			continue
		}
		// Key and mouse-motion events carry no viewport the backend can check,
		// so the context has to be chosen here or they land in the wrong window.
		if target := window_by_id(event_window_id(&event)); target != nil {
			SetActiveWindow(target)
			dirtImGuiProcessEvent(&event)
			apply_window_event(target, &event)
		}
	}
}

ensure_depth :: proc(window: ^Window) {
	if window.depth != nil && window.depth_w == window.swapchain_w && window.depth_h == window.swapchain_h {
		return
	}
	if window.depth != nil {
		sdl.ReleaseGPUTexture(gpu_device, window.depth)
		window.depth = nil
	}
	window.depth_w, window.depth_h = window.swapchain_w, window.swapchain_h
	window.depth = sdl.CreateGPUTexture(
		gpu_device,
		{type = .D2, format = .D32_FLOAT, usage = {.DEPTH_STENCIL_TARGET}, width = u32(window.swapchain_w), height = u32(window.swapchain_h), layer_count_or_depth = 1, num_levels = 1, sample_count = ._1},
	)
}

// Acquires a command buffer and the swapchain texture. A nil command buffer or
// a missing swapchain texture (minimized window) makes every later draw of
// this frame a no-op; EndWindowFrame still submits.
BeginWindowFrame :: proc(window: ^Window) {
	SetActiveWindow(window)
	window.cmd, window.swapchain, window.scene_drawn = nil, nil, false
	window.swapchain_w, window.swapchain_h = window.width, window.height
	if gpu_device == nil {
		return
	}
	cmd := sdl.AcquireGPUCommandBuffer(gpu_device)
	if cmd == nil {
		return
	}
	window.cmd = cmd
	tex: ^sdl.GPUTexture
	w, h: u32
	if sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window.handle, &tex, &w, &h) && tex != nil {
		window.swapchain, window.swapchain_w, window.swapchain_h = tex, i32(w), i32(h)
		ensure_depth(window)
	}
}

// The ImGui pass runs after the scene pass (or, with no scene, clears first).
// ui/ records into it through the returned pointer; a nil return draws nothing.
BeginImGuiPass :: proc() -> rawptr {
	w := active_window
	if w == nil || w.cmd == nil || w.swapchain == nil || w.depth == nil {
		return nil
	}
	load := sdl.GPULoadOp.CLEAR
	if w.scene_drawn {
		load = .LOAD
	}
	color_info := sdl.GPUColorTargetInfo{texture = w.swapchain, clear_color = w.clear, load_op = load, store_op = .STORE}
	pass := sdl.BeginGPURenderPass(w.cmd, &color_info, 1, nil)
	sdl.SetGPUViewport(pass, {w = f32(w.swapchain_w), h = f32(w.swapchain_h), min_depth = 0, max_depth = 1})
	return pass
}

EndImGuiPass :: proc(pass: rawptr) {
	if pass != nil {
		sdl.EndGPURenderPass((^sdl.GPURenderPass)(pass))
	}
}

ImGuiCommandBuffer :: proc() -> rawptr {
	return active_window == nil ? nil : active_window.cmd
}

EndWindowFrame :: proc(window: ^Window) {
	if window.cmd != nil {
		_ = sdl.SubmitGPUCommandBuffer(window.cmd)
		window.cmd, window.swapchain = nil, nil
	}
	now := sdl.GetPerformanceCounter()
	freq := sdl.GetPerformanceFrequency()
	window.frame_time = f32(f64(now - window.frame_start) / f64(freq))
	window.frame_start = now
}

// Bring a window to the front. Opening something that is already open should
// show it, not make a second one.
RaiseWindow :: proc(window: ^Window) {
	if window.handle != nil {
		sdl.RaiseWindow(window.handle)
	}
}

// Whether this window has keyboard focus. ImGuizmo keeps one file-static drag
// state for the whole process, so only the focused window may run a gizmo:
// a second window manipulating in the same frame would clobber the first
// window's drag half way through it.
WindowFocused :: proc(window: ^Window) -> bool {
	return window.focused
}

WindowShouldClose :: proc(window: ^Window) -> bool {
	return window.should_close
}

// The shared GPU device and a window's swapchain format, for the ImGui
// backend setup. The format matches the pipelines from CreateWindow.
GpuDevice :: proc() -> rawptr {
	return rawptr(gpu_device)
}
WindowSwapchainFormat :: proc(window: ^Window) -> c.int {
	if gpu_device == nil || window.handle == nil {
		return 0
	}
	return c.int(sdl.GetGPUSwapchainTextureFormat(gpu_device, window.handle))
}
NativeWindow :: proc(window: ^Window) -> rawptr {
	return rawptr(window.handle)
}
GetScreenWidth :: proc() -> i32 {
	return active_window == nil ? 0 : active_window.width
}
GetScreenHeight :: proc() -> i32 {
	return active_window == nil ? 0 : active_window.height
}
GetFrameTime :: proc() -> f32 {
	return active_window == nil ? 0 : active_window.frame_time
}
GetTime :: proc() -> f64 {
	return f64(sdl.GetTicksNS()) / 1_000_000_000.0
}
GetMousePosition :: proc() -> Vector2 {
	return active_window.mouse
}
GetMouseDelta :: proc() -> Vector2 {
	return active_window.mouse_delta
}
GetMouseWheelMove :: proc() -> f32 {
	return active_window.wheel
}
IsMouseButtonPressed :: proc(button: MouseButton) -> bool {
	return active_window.mouse_pressed[int(button)]
}
IsMouseButtonDown :: proc(button: MouseButton) -> bool {
	return active_window.mouse_down[int(button)]
}
IsKeyPressed :: proc(key: Key) -> bool {
	return active_window.keys_pressed[int(key_scancode(key))]
}
IsKeyDown :: proc(key: Key) -> bool {
	return active_window.keys_down[int(key_scancode(key))]
}
