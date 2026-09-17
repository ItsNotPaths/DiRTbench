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
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_opengl3.h"
#include <SDL3/SDL.h>

extern "C" {

bool dirtImGuiSetup(bool dark_theme, SDL_Window* window, SDL_GLContext context) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    if (dark_theme) ImGui::StyleColorsDark();
    if (!ImGui_ImplSDL3_InitForOpenGL(window, context)) {
        ImGui::DestroyContext();
        return false;
    }
    if (!ImGui_ImplOpenGL3_Init("#version 330")) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return false;
    }
    return true;
}

void dirtImGuiBegin(void) {
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

void dirtImGuiEnd(void) {
    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

void dirtImGuiShutdown(void) {
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
}

void dirtImGuiProcessEvent(const SDL_Event* event) {
    if (ImGui::GetCurrentContext()) ImGui_ImplSDL3_ProcessEvent(event);
}

// True when ImGui (a window, a popup, a drag in progress) owns the mouse this
// frame, i.e. the viewport must not act on clicks, drags or the wheel.
bool dirtImGuiWantCaptureMouse(void) { return ImGui::GetIO().WantCaptureMouse; }

// True when ImGui owns the keyboard, e.g. a text field has focus.
bool dirtImGuiWantCaptureKeyboard(void) { return ImGui::GetIO().WantCaptureKeyboard; }

} // extern "C"
