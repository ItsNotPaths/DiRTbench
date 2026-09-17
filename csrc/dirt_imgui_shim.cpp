// Hand-written glue compiled into vendor/imgui/libimgui.a by download-deps.sh.
//
// cimgui's flat C API exposes ImGuiIO only as a pointer (igGetIO_Nil), so
// reading a field off it from Odin would mean mirroring the whole ImGuiIO
// struct — ~60 fields whose layout shifts between Dear ImGui releases. These
// accessors are the only fields the editor needs, so we surface them as C
// functions instead and never describe the struct on the Odin side.
//
// Rendering goes through the SDL_GPU backend (Vulkan underneath). Unlike the
// old OpenGL path, ImGui no longer draws by itself: the caller drives the
// frame (dirtImGuiBegin), prepares the draw data into a command buffer
// (dirtImGuiPrepare, which must run outside any render pass), and then records
// it into its own swapchain render pass (dirtImGuiDraw).
//
// Unlike everything else under vendor/, this file is tracked in git.

#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_sdlgpu3.h"
#include <SDL3/SDL.h>

extern "C" {

bool dirtImGuiSetup(bool dark_theme, SDL_Window* window, SDL_GPUDevice* device, int color_format) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    if (dark_theme) ImGui::StyleColorsDark();
    if (!ImGui_ImplSDL3_InitForVulkan(window)) {
        ImGui::DestroyContext();
        return false;
    }
    ImGui_ImplSDLGPU3_InitInfo info = {};
    info.Device = device;
    info.ColorTargetFormat = (SDL_GPUTextureFormat)color_format;
    if (!ImGui_ImplSDLGPU3_Init(&info)) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return false;
    }
    return true;
}

void dirtImGuiBegin(void) {
    ImGui_ImplSDLGPU3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

void dirtImGuiPrepare(SDL_GPUCommandBuffer* command_buffer) {
    ImGui::Render();
    ImGui_ImplSDLGPU3_PrepareDrawData(ImGui::GetDrawData(), command_buffer);
}

void dirtImGuiDraw(SDL_GPUCommandBuffer* command_buffer, SDL_GPURenderPass* render_pass) {
    ImGui_ImplSDLGPU3_RenderDrawData(ImGui::GetDrawData(), command_buffer, render_pass);
}

void dirtImGuiShutdown(void) {
    ImGui_ImplSDLGPU3_Shutdown();
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
