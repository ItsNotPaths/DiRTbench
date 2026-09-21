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
// **One context per window.** Dear ImGui keeps its state in a global current
// context, and each platform backend binds one SDL window. The SDL3 backend
// gates only enter, leave and focus events by window id; key and mouse-motion
// events go straight into whichever context is current. So every window owns a
// context, and the caller makes one current before it feeds events or draws.
// Each context builds its own font atlas: sharing one across contexts makes two
// renderer backends fight over the same texture id.
//
// Unlike everything else under vendor/, this file is tracked in git.

#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_sdlgpu3.h"
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>

// MSVC spells it _strdup; plain strdup is a deprecated alias that only resolves
// through OLDNAMES.lib.
#ifdef _MSC_VER
#define dirt_strdup _strdup
#else
#define dirt_strdup strdup
#endif

extern "C" {

// Returns the new context, or null. It is left current.
void* dirtImGuiSetup(bool dark_theme, SDL_Window* window, SDL_GPUDevice* device, int color_format) {
    IMGUI_CHECKVERSION();
    ImGuiContext* ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(ctx);
    if (dark_theme) ImGui::StyleColorsDark();
    if (!ImGui_ImplSDL3_InitForVulkan(window)) {
        ImGui::DestroyContext(ctx);
        return nullptr;
    }
    ImGui_ImplSDLGPU3_InitInfo info = {};
    info.Device = device;
    info.ColorTargetFormat = (SDL_GPUTextureFormat)color_format;
    if (!ImGui_ImplSDLGPU3_Init(&info)) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext(ctx);
        return nullptr;
    }
    return ctx;
}

void dirtImGuiSetCurrent(void* ctx) {
    ImGui::SetCurrentContext((ImGuiContext*)ctx);
}

// ImGui stores the pointer rather than the string, so a name we set has to
// outlive the call. It cannot simply be freed either: io.IniFilename starts out
// pointing at ImGui's own "imgui.ini" literal, and freeing that aborts the
// process. So the copies we allocate are tracked here, and only those are freed.
enum { DIRT_MAX_CONTEXTS = 16 };
static struct { ImGuiContext* ctx; char* ini; } g_ini[DIRT_MAX_CONTEXTS];

static char** dirt_ini_slot(ImGuiContext* ctx) {
    for (int i = 0; i < DIRT_MAX_CONTEXTS; i++) if (g_ini[i].ctx == ctx) return &g_ini[i].ini;
    for (int i = 0; i < DIRT_MAX_CONTEXTS; i++) if (g_ini[i].ctx == nullptr) {
        g_ini[i].ctx = ctx;
        return &g_ini[i].ini;
    }
    return nullptr;
}

static void dirt_ini_release(ImGuiContext* ctx) {
    for (int i = 0; i < DIRT_MAX_CONTEXTS; i++) if (g_ini[i].ctx == ctx) {
        free(g_ini[i].ini);
        g_ini[i] = {};
        return;
    }
}

// A null name turns the .ini off for this window, which is what every window
// but the first one wants: they would otherwise write their layouts over each
// other.
void dirtImGuiSetIniFilename(void* c, const char* name) {
    ImGuiContext* ctx = (ImGuiContext*)c;
    char** slot = dirt_ini_slot(ctx);
    if (slot == nullptr) return;
    free(*slot);
    *slot = name ? dirt_strdup(name) : nullptr;

    ImGuiContext* prev = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(ctx);
    ImGui::GetIO().IniFilename = *slot;
    ImGui::SetCurrentContext(prev);
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

void dirtImGuiShutdown(void* ctx) {
    ImGui::SetCurrentContext((ImGuiContext*)ctx);
    ImGui_ImplSDLGPU3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext((ImGuiContext*)ctx);
    ImGui::SetCurrentContext(nullptr);
    dirt_ini_release((ImGuiContext*)ctx);
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
