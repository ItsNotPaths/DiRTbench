// Hand-written glue compiled into vendor/imgui/libimgui.a by download-deps.sh.
//
// cimgui's flat C API exposes ImGuiIO only as a pointer (igGetIO_Nil), so
// reading a field off it from Odin would mean mirroring the whole ImGuiIO
// struct — ~60 fields whose layout shifts between Dear ImGui releases. These
// two accessors are the only fields the editor needs, so we surface them as C
// functions instead and never describe the struct on the Odin side.
//
// Unlike everything else under vendor/, this file is tracked in git.

#include "imgui.h"

extern "C" {

// True when ImGui (a window, a popup, a drag in progress) owns the mouse this
// frame, i.e. the viewport must not act on clicks, drags or the wheel.
bool dirtImGuiWantCaptureMouse(void) { return ImGui::GetIO().WantCaptureMouse; }

// True when ImGui owns the keyboard, e.g. a text field has focus.
bool dirtImGuiWantCaptureKeyboard(void) { return ImGui::GetIO().WantCaptureKeyboard; }

} // extern "C"
