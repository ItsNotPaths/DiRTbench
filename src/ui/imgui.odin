package ui

// Odin bindings for Dear ImGui, via cimgui's flat C API, plus the official
// SDL3 platform and SDL_GPU renderer backends. Vendored and compiled into vendor/imgui/libimgui.a by
// download-deps.sh — see that script for the pinned versions and why they must
// move as a set.
//
// Odin cannot call C++, so nothing here talks to ImGui:: directly. Everything
// goes through cimgui's generated `ig*` functions, our backend shim,
// entry points, or csrc/dirt_imgui_shim.cpp for the two ImGuiIO fields that have
// no flat-C accessor.
//
// This binds only the subset the editor uses. cimgui exposes the entire ImGui
// API under the same `ig` prefix; to use a new widget, look its signature up in
// vendor/imgui/cimgui.h and add it to the foreign block below.

import "core:c"

// The build scripts place the static C++ runtime after this archive.
foreign import imgui {
	"../../vendor/imgui/libimgui.a",
}

// --- types ------------------------------------------------------------------

Im_Vec2 :: struct {
	x, y: f32,
}

Im_Vec4 :: struct {
	x, y, z, w: f32,
}

Im_Cond :: enum c.int {
	None         = 0,
	Always       = 1 << 0,
	Once         = 1 << 1,
	FirstUseEver = 1 << 2,
	Appearing    = 1 << 3,
}

Im_Window_Flags :: distinct c.int
IM_WINDOW_NONE :: Im_Window_Flags(0)
IM_WINDOW_NO_TITLE_BAR :: Im_Window_Flags(1 << 0)
IM_WINDOW_NO_RESIZE :: Im_Window_Flags(1 << 1)
IM_WINDOW_NO_MOVE :: Im_Window_Flags(1 << 2)
IM_WINDOW_NO_COLLAPSE :: Im_Window_Flags(1 << 5)
IM_WINDOW_ALWAYS_AUTO_RESIZE :: Im_Window_Flags(1 << 6)
IM_WINDOW_NO_SAVED_SETTINGS :: Im_Window_Flags(1 << 8)
IM_WINDOW_NO_BRING_TO_FRONT :: Im_Window_Flags(1 << 13)

Im_Slider_Flags :: distinct c.int
IM_SLIDER_NONE :: Im_Slider_Flags(0)

Im_Input_Text_Flags :: distinct c.int
IM_INPUT_TEXT_NONE :: Im_Input_Text_Flags(0)
IM_INPUT_TEXT_CHARS_NO_BLANK :: Im_Input_Text_Flags(1 << 4)

Im_Tree_Node_Flags :: distinct c.int
IM_TREE_NODE_NONE :: Im_Tree_Node_Flags(0)
IM_TREE_NODE_DEFAULT_OPEN :: Im_Tree_Node_Flags(1 << 5)

// ImGuiDir_, for the arrow a button draws.
Im_Dir :: enum c.int {
	Left  = 0,
	Right = 1,
	Up    = 2,
	Down  = 3,
}

// Style slots, from the head of ImGuiCol_ in cimgui.h. Only what we restyle.
Im_Col :: enum c.int {
	Text = 0,
}

// --- SDL3/SDL_GPU backend lifecycle -----------------------------------------

@(default_calling_convention = "c")
foreign imgui {
	// Creates an ImGui context on an SDL window; rendering goes through the
	// SDL_GPU backend. `device` is the gfx GPU device, `color_format` the
	// window's swapchain texture format as an integer. Returns the context, or
	// nil, and leaves it current. One per window — see the shim for why.
	@(link_name = "dirtImGuiSetup")
	imgui_backend_setup :: proc(dark_theme: bool, window, device: rawptr, color_format: c.int) -> rawptr ---
	// Which context the ImGui and ImGuizmo calls below act on. gfx switches this
	// with the active window, so nothing else should need to call it.
	@(link_name = "dirtImGuiSetCurrent")
	imgui_backend_set_current :: proc(ctx: rawptr) ---
	// Where this context saves its window layout. nil turns saving off, which is
	// what every window but the first wants: they would write over each other.
	@(link_name = "dirtImGuiSetIniFilename")
	imgui_backend_set_ini :: proc(ctx: rawptr, name: cstring) ---
	// Begins the ImGui frame (feeds input, calls NewFrame). All ImGui and
	// ImGuizmo calls for the frame go between Begin and Prepare.
	@(link_name = "dirtImGuiBegin")
	imgui_backend_begin :: proc() ---
	// Ends the frame and uploads the draw data into `cmd`. Must run outside
	// any render pass.
	@(link_name = "dirtImGuiPrepare")
	imgui_backend_prepare :: proc(cmd: rawptr) ---
	// Records the prepared draw data into the caller's swapchain pass.
	@(link_name = "dirtImGuiDraw")
	imgui_backend_draw :: proc(cmd, pass: rawptr) ---
	// Destroys one context before its SDL window disappears.
	@(link_name = "dirtImGuiShutdown")
	imgui_backend_shutdown :: proc(ctx: rawptr) ---
}

// --- dirt_imgui_shim: ImGuiIO fields with no flat-C accessor -------------------

@(default_calling_convention = "c")
foreign imgui {
	// True when ImGui owns the mouse this frame (cursor over a window, or a
	// drag in progress). The viewport must ignore clicks, drags and the wheel.
	@(link_name = "dirtImGuiWantCaptureMouse")
	imgui_want_capture_mouse :: proc() -> bool ---
	// True when ImGui owns the keyboard, e.g. a text field has focus.
	@(link_name = "dirtImGuiWantCaptureKeyboard")
	imgui_want_capture_keyboard :: proc() -> bool ---

	igGetForegroundDrawList_Nil :: proc() -> rawptr ---
	igGetFont :: proc() -> rawptr ---
	ImFont_CalcTextSizeA :: proc(font: rawptr, size, max_width, wrap_width: f32, text_begin, text_end: cstring, remaining: ^cstring) -> Im_Vec2 ---
	ImDrawList_AddText_FontPtr :: proc(draw_list, font: rawptr, font_size: f32, pos: Im_Vec2, color: u32, text_begin, text_end: cstring, wrap_width: f32, clip_rect: ^Im_Vec4) ---
}

draw_overlay_text_centered :: proc(text: cstring, size, y, width: f32, color: u32) {
	font := igGetFont()
	extent := ImFont_CalcTextSizeA(font, size, 3.402823e38, 0, text, nil, nil)
	ImDrawList_AddText_FontPtr(igGetForegroundDrawList_Nil(), font, size, {(width - extent.x) / 2, y}, color, text, nil, 0, nil)
}

// --- cimgui: the ImGui subset we use ----------------------------------------

@(default_calling_convention = "c")
foreign imgui {
	igBegin :: proc(name: cstring, p_open: ^bool, flags: Im_Window_Flags) -> bool ---
	igEnd :: proc() ---

	igSetNextWindowPos :: proc(pos: Im_Vec2, cond: Im_Cond, pivot: Im_Vec2) ---
	igSetNextWindowSize :: proc(size: Im_Vec2, cond: Im_Cond) ---
	// One line of widget: the font plus the frame padding. Also the height of
	// the main menu bar, which is what a panel pinned below it needs.
	igGetFrameHeight :: proc() -> f32 ---

	igBeginMainMenuBar :: proc() -> bool ---
	igEndMainMenuBar :: proc() ---
	igBeginMenu :: proc(label: cstring, enabled: bool) -> bool ---
	igEndMenu :: proc() ---
	igMenuItem_Bool :: proc(label, shortcut: cstring, selected, enabled: bool) -> bool ---

	// text_end = nil means "NUL-terminated", which is what an Odin cstring is.
	igTextUnformatted :: proc(text: cstring, text_end: cstring) ---
	igSeparatorText :: proc(label: cstring) ---
	igSeparator :: proc() ---
	igSpacing :: proc() ---
	igSameLine :: proc(offset_from_start_x: f32, spacing: f32) ---

	// Greys out and inert-ifies everything drawn between the two.
	igBeginDisabled :: proc(disabled: bool) ---
	igEndDisabled :: proc() ---

	igPushStyleColor_Vec4 :: proc(idx: Im_Col, col: Im_Vec4) ---
	igPopStyleColor :: proc(count: c.int) ---

	// Where text wraps, in window-local x. 0 wraps at the content edge, which is
	// what a fixed-width panel holding file paths wants.
	igPushTextWrapPos :: proc(wrap_local_pos_x: f32) ---
	igPopTextWrapPos :: proc() ---

	igButton :: proc(label: cstring, size: Im_Vec2) -> bool ---
	// A square button holding nothing but an arrow. `str_id` is the id, not a
	// label, so nothing is drawn beside it.
	igArrowButton :: proc(str_id: cstring, dir: Im_Dir) -> bool ---
	igRadioButton_Bool :: proc(label: cstring, active: bool) -> bool ---
	igCheckbox :: proc(label: cstring, v: ^bool) -> bool ---
	// `v` is C `float[3]`; gfx.Vector3 is a distinct [3]f32, so cast into it.
	igDragFloat3 :: proc(label: cstring, v: ^[3]f32, v_speed, v_min, v_max: f32, format: cstring, flags: Im_Slider_Flags) -> bool ---
	igSliderFloat :: proc(label: cstring, v: ^f32, v_min, v_max: f32, format: cstring, flags: Im_Slider_Flags) -> bool ---
	// A slider with no ends: drag to change by `v_speed` per pixel. v_min >= v_max
	// means unbounded, which is what a world height wants.
	igDragFloat :: proc(label: cstring, v: ^f32, v_speed, v_min, v_max: f32, format: cstring, flags: Im_Slider_Flags) -> bool ---
	igSliderInt :: proc(label: cstring, v: ^c.int, v_min, v_max: c.int, format: cstring, flags: Im_Slider_Flags) -> bool ---
	// step / step_fast drive the -/+ buttons and ctrl-click stepping.
	igInputInt :: proc(label: cstring, v: ^c.int, step, step_fast: c.int, flags: Im_Input_Text_Flags) -> bool ---

	// True when the header is expanded; draw its contents then.
	igCollapsingHeader_TreeNodeFlags :: proc(label: cstring, flags: Im_Tree_Node_Flags) -> bool ---
	// Width of the next widget in pixels. Without it an unlabelled field takes
	// 65% of the window and pushes whatever shares its line off the edge.
	igSetNextItemWidth :: proc(item_width: f32) ---
	// True on the frame a field that was edited loses focus, which Enter also
	// does. This is the commit signal: a text field reports every keystroke.
	igIsItemDeactivatedAfterEdit :: proc() -> bool ---
	// `buf` is an in/out NUL-terminated C string of capacity `buf_size`; ImGui
	// edits it in place. Pass nil for the callback we do not use.
	igInputText :: proc(label: cstring, buf: [^]u8, buf_size: uint, flags: Im_Input_Text_Flags, callback: rawptr, user_data: rawptr) -> bool ---

	igShowDemoWindow :: proc(p_open: ^bool) ---
}

// Defaults that keep call sites readable: cimgui has no default arguments.
im_text :: proc(text: cstring) {
	igTextUnformatted(text, nil)
}
im_same_line :: proc() {
	igSameLine(0, -1) // 0 = pack against previous item, -1 = default spacing
}
im_button :: proc(label: cstring) -> bool {
	return igButton(label, {0, 0}) // {0,0} = size to fit the label
}

// Coloured text. Deliberately not cimgui's igTextColored, which is variadic and
// would treat the text itself as a printf format — a stage named "100%" would
// then read past the end of the argument list.
im_text_colored :: proc(col: Im_Vec4, text: cstring) {
	igPushStyleColor_Vec4(.Text, col)
	igTextUnformatted(text, nil)
	igPopStyleColor(1)
}
