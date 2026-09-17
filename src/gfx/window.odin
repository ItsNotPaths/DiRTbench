package gfx

// SDL owns native windows and their OpenGL contexts. Window state is stored on
// the window rather than in package globals so events can be routed by SDL's
// WindowID when the editor grows beyond one window.

import "core:c"
import sdl "vendor:sdl3"
import rlgl "vendor:raylib/rlgl"

foreign import imgui "../../vendor/imgui/libimgui.a"
@(default_calling_convention = "c")
foreign imgui {
	dirtImGuiProcessEvent :: proc(event: ^sdl.Event) ---
}

Window :: struct {
	handle:       ^sdl.Window,
	ctx:          sdl.GLContext,
	id:           sdl.WindowID,
	width:        i32,
	height:       i32,
	framebuffer_width:  i32,
	framebuffer_height: i32,
	owns_sdl:     bool,
	should_close: bool,
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

Key :: enum i32 { ONE, TWO, S, F, DELETE, LEFT_SHIFT, RIGHT_SHIFT, LEFT_CONTROL, RIGHT_CONTROL, LEFT_ALT, RIGHT_ALT }
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
	case .DELETE: return .DELETE
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
	if window == nil { return false }
	window^ = {width = width, height = height}
	if sdl_users == 0 && !sdl.Init(sdl.INIT_VIDEO) { return false }
	sdl_users += 1
	window.owns_sdl = true

	_ = sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	_ = sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	_ = sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1) // SDL_GL_CONTEXT_PROFILE_CORE
	_ = sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
	_ = sdl.GL_SetAttribute(.DEPTH_SIZE, 24)
	_ = sdl.GL_SetAttribute(.STENCIL_SIZE, 8)
	_ = sdl.GL_SetAttribute(.MULTISAMPLEBUFFERS, 1)
	_ = sdl.GL_SetAttribute(.MULTISAMPLESAMPLES, 4)
	window.handle = sdl.CreateWindow(title, c.int(width), c.int(height), {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window.handle == nil { DestroyWindow(window); return false }
	window.ctx = sdl.GL_CreateContext(window.handle)
	if window.ctx == nil { DestroyWindow(window); return false }
	window.id = sdl.GetWindowID(window.handle)
	_ = sdl.GL_MakeCurrent(window.handle, window.ctx)
	_ = sdl.GL_SetSwapInterval(1)
	rlgl.LoadExtensions(rawptr(sdl.GL_GetProcAddress))
	w, h, framebuffer_width, framebuffer_height: c.int
	_ = sdl.GetWindowSize(window.handle, &w, &h)
	_ = sdl.GetWindowSizeInPixels(window.handle, &framebuffer_width, &framebuffer_height)
	window.width, window.height = i32(w), i32(h)
	window.framebuffer_width, window.framebuffer_height = i32(framebuffer_width), i32(framebuffer_height)
	rlgl.Init(framebuffer_width, framebuffer_height)
	window.frame_start = sdl.GetPerformanceCounter()
	append(&windows, window)
	active_window = window
	return true
}

DestroyWindow :: proc(window: ^Window) {
	if window == nil { return }
	if window.ctx != nil {
		_ = sdl.GL_MakeCurrent(window.handle, window.ctx)
		rlgl.Close()
		_ = sdl.GL_DestroyContext(window.ctx)
		window.ctx = nil
	}
	if window.handle != nil { sdl.DestroyWindow(window.handle); window.handle = nil }
	for candidate, i in windows {
		if candidate == window { unordered_remove(&windows, i); break }
	}
	if active_window == window { active_window = nil }
	if window.owns_sdl {
		window.owns_sdl = false
		sdl_users -= 1
		if sdl_users == 0 { delete(windows); sdl.Quit() }
	}
}

window_by_id :: proc(id: sdl.WindowID) -> ^Window {
	for window in windows {
		if window.id == id { return window }
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
	case .WINDOW_CLOSE_REQUESTED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED: return event.window.windowID
	case .MOUSE_MOTION: return event.motion.windowID
	case .MOUSE_WHEEL: return event.wheel.windowID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP: return event.button.windowID
	case .KEY_DOWN, .KEY_UP: return event.key.windowID
	}
	return 0
}

apply_mouse_button_event :: proc(window: ^Window, event: ^sdl.Event) {
	i, known := mouse_button_index(event.button.button)
	if !known { return }
	pressed := event.type == .MOUSE_BUTTON_DOWN
	window.mouse_down[i] = pressed
	if pressed { window.mouse_pressed[i] = true }
}

apply_key_event :: proc(window: ^Window, event: ^sdl.Event) {
	i := int(event.key.scancode)
	if i < 0 || i >= len(window.keys_down) { return }
	pressed := event.type == .KEY_DOWN
	window.keys_down[i] = pressed
	if pressed && !event.key.repeat { window.keys_pressed[i] = true }
}

apply_window_event :: proc(window: ^Window, event: ^sdl.Event) {
	#partial switch event.type {
	case .WINDOW_CLOSE_REQUESTED: window.should_close = true
	case .WINDOW_RESIZED: window.width, window.height = event.window.data1, event.window.data2
	case .WINDOW_PIXEL_SIZE_CHANGED:
		window.framebuffer_width, window.framebuffer_height = event.window.data1, event.window.data2
	case .MOUSE_MOTION:
		window.mouse = {event.motion.x, event.motion.y}
		window.mouse_delta += {event.motion.xrel, event.motion.yrel}
	case .MOUSE_WHEEL: window.wheel += event.wheel.y
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP: apply_mouse_button_event(window, event)
	case .KEY_DOWN, .KEY_UP: apply_key_event(window, event)
	}
}

route_window_event :: proc(event: ^sdl.Event) {
	window := window_by_id(event_window_id(event))
	if window != nil { apply_window_event(window, event) }
}

PollWindowEvents :: proc() {
	for window in windows {
		window.mouse_delta, window.wheel = {}, 0
		window.mouse_pressed = {}
		window.keys_pressed = {}
	}
	event: sdl.Event
	for sdl.PollEvent(&event) {
		dirtImGuiProcessEvent(&event)
		if event.type == .QUIT {
			for window in windows { window.should_close = true }
			continue
		}
		route_window_event(&event)
	}
}

BeginWindowFrame :: proc(window: ^Window) {
	active_window = window
	_ = sdl.GL_MakeCurrent(window.handle, window.ctx)
	rlgl.SetFramebufferWidth(c.int(window.framebuffer_width))
	rlgl.SetFramebufferHeight(c.int(window.framebuffer_height))
	rlgl.Viewport(0, 0, c.int(window.framebuffer_width), c.int(window.framebuffer_height))
}

EndWindowFrame :: proc(window: ^Window) {
	rlgl.DrawRenderBatchActive()
	_ = sdl.GL_SwapWindow(window.handle)
	now := sdl.GetPerformanceCounter()
	freq := sdl.GetPerformanceFrequency()
	window.frame_time = f32(f64(now - window.frame_start) / f64(freq))
	window.frame_start = now
}

WindowShouldClose :: proc(window: ^Window) -> bool { return window.should_close }
NativeWindow :: proc(window: ^Window) -> rawptr { return rawptr(window.handle) }
NativeGLContext :: proc(window: ^Window) -> rawptr { return rawptr(window.ctx) }
GetScreenWidth :: proc() -> i32 { return active_window == nil ? 0 : active_window.width }
GetScreenHeight :: proc() -> i32 { return active_window == nil ? 0 : active_window.height }
GetFrameTime :: proc() -> f32 { return active_window == nil ? 0 : active_window.frame_time }
GetTime :: proc() -> f64 { return f64(sdl.GetTicksNS()) / 1_000_000_000.0 }
GetMousePosition :: proc() -> Vector2 { return active_window.mouse }
GetMouseDelta :: proc() -> Vector2 { return active_window.mouse_delta }
GetMouseWheelMove :: proc() -> f32 { return active_window.wheel }
IsMouseButtonPressed :: proc(button: MouseButton) -> bool { return active_window.mouse_pressed[int(button)] }
IsMouseButtonDown :: proc(button: MouseButton) -> bool { return active_window.mouse_down[int(button)] }
IsKeyPressed :: proc(key: Key) -> bool { return active_window.keys_pressed[int(key_scancode(key))] }
IsKeyDown :: proc(key: Key) -> bool { return active_window.keys_down[int(key_scancode(key))] }
