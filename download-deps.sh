#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"

# SDL is linked into dirtbench, not installed.  Keeping the archive beside the
# rest of the vendored code also prevents a system libSDL3.so from winning the
# link on development machines.
SDL_VERSION="3.4.16"
SDL_SRC="$VENDOR/sdl3-src"
SDL_DEST="$VENDOR/sdl3"
SDL_A="$SDL_DEST/libSDL3.a"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

# --- SDL3 (window, input, audio and GPU abstraction) ------------------------
# X11, Wayland, libdecor, ALSA/Pulse/PipeWire and Vulkan are loaded at runtime.
# Their development files are build inputs only and add no ELF dependencies.
fetch_sdl() {
    if [ -f "$SDL_A" ]; then
        echo "  already present: sdl3"
        return
    fi
    if [ ! -d "$SDL_SRC" ] || [ -z "$(ls -A "$SDL_SRC" 2>/dev/null)" ]; then
        echo "  downloading SDL $SDL_VERSION..."
        mkdir -p "$SDL_SRC"
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C "$SDL_SRC" \
            || { rm -rf "$SDL_SRC"; exit 1; }
    fi

    echo "  compiling static SDL3..."
    # A failed feature probe leaves a misleading cache behind, so configuration
    # is intentionally fresh.  SDL_GPU stays enabled; SDL_Render is unrelated.
    rm -rf "$SDL_SRC/build"
    cmake -S "$SDL_SRC" -B "$SDL_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DSDL_GPU=ON -DSDL_VULKAN=ON -DSDL_AUDIO=ON \
        -DSDL_RENDER=OFF -DSDL_CAMERA=OFF -DSDL_JOYSTICK=OFF \
        -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF \
        -DSDL_POWER=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF \
        -DSDL_X11_XTEST=OFF -DSDL_TEST_LIBRARY=OFF >/dev/null
    cmake --build "$SDL_SRC/build" --parallel >/dev/null
    mkdir -p "$SDL_DEST"
    cp "$SDL_SRC/build/libSDL3.a" "$SDL_A"
    echo "  done."
}

fetch_sdl

# --- Dear ImGui + ImGuizmo (+ C APIs + SDL3/OpenGL backend) ------------------
# All five sources are C++ and all compile into one static lib, vendor/imgui/
# libimgui.a, which src/imgui.odin and src/imguizmo.odin link against.
#
#   imgui      Dear ImGui itself                              (MIT)
#   cimgui     generated flat C API for imgui                 (MIT)
#   ImGuizmo   the 3D transform gizmo                         (MIT)
#   cimguizmo  generated flat C API for ImGuizmo              (MIT)
#   backends   official SDL3 platform + OpenGL3 renderer       (MIT)
#
# Odin cannot call C++, so everything crosses the boundary through the two
# generated C APIs plus csrc/dirt_imgui_shim.cpp. Nothing here needs cimgui's Lua
# generator: cimgui.cpp/.h and cimguizmo.cpp/.h are checked into their repos
# pre-generated, and we take them as-is.
#
# The pins are a matched set, do not bump one alone:
#   - cimgui.cpp is generated against an exact imgui version (its own imgui
#     submodule), and cimguizmo.cpp against an exact ImGuizmo (likewise).
#   - IMGUI_TAG must equal what CIMGUI_SHA's submodule points at (v1.92.8).
#   - GUIZMO_SHA must equal what CIMGUIZMO_SHA's submodule points at.
IMGUI_TAG="v1.92.8"
CIMGUI_SHA="d298666861ebf00dcfeb2407409931c04e47e33c"
GUIZMO_SHA="a712ea83e937cc6f11e22c3b2c82920857ae13df"
CIMGUIZMO_SHA="c351c2da1de08d7db94a51ca12c3b03697aee80b"
IMGUI_DEST="$VENDOR/imgui"

# The layout below is dictated by the generated sources' own #includes:
# cimgui.cpp does #include "./imgui/imgui.h", and cimguizmo.cpp does
# #include "./ImGuizmo/src/ImGuizmo.h". Keep the tree shaped that way.
fetch_imgui() {
    if [ -f "$IMGUI_DEST/libimgui.a" ] && [ -f "$IMGUI_DEST/backends/imgui_impl_sdl3.cpp" ]; then
        echo "  already present: imgui"
        return
    fi
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$IMGUI_DEST/imgui" "$IMGUI_DEST/backends" "$IMGUI_DEST/ImGuizmo/src"

    echo "  downloading Dear ImGui $IMGUI_TAG..."
    curl -fsSL "https://github.com/ocornut/imgui/archive/refs/tags/${IMGUI_TAG}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/imgui-*/{imgui.cpp,imgui_draw.cpp,imgui_tables.cpp,imgui_widgets.cpp,imgui_demo.cpp} "$IMGUI_DEST/imgui/"
    cp "$tmp"/imgui-*/{imgui.h,imgui_internal.h,imconfig.h,imstb_textedit.h,imstb_rectpack.h,imstb_truetype.h} "$IMGUI_DEST/imgui/"
    cp "$tmp"/imgui-*/backends/{imgui_impl_sdl3.cpp,imgui_impl_sdl3.h,imgui_impl_opengl3.cpp,imgui_impl_opengl3.h,imgui_impl_opengl3_loader.h} "$IMGUI_DEST/backends/"

    echo "  downloading cimgui @ ${CIMGUI_SHA:0:8}..."
    curl -fsSL "https://github.com/cimgui/cimgui/archive/${CIMGUI_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/cimgui-*/{cimgui.cpp,cimgui.h,cimconfig.h} "$IMGUI_DEST/"

    echo "  downloading ImGuizmo @ ${GUIZMO_SHA:0:8}..."
    curl -fsSL "https://github.com/CedricGuillemet/ImGuizmo/archive/${GUIZMO_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/ImGuizmo-*/src/{ImGuizmo.cpp,ImGuizmo.h} "$IMGUI_DEST/ImGuizmo/src/"

    echo "  downloading cimguizmo @ ${CIMGUIZMO_SHA:0:8}..."
    curl -fsSL "https://github.com/cimgui/cimguizmo/archive/${CIMGUIZMO_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/cimguizmo-*/{cimguizmo.cpp,cimguizmo.h} "$IMGUI_DEST/"

    rm -rf "$tmp"

    echo "  compiling libimgui.a..."
    local flags=(-std=c++11 -O2 -fPIC -fno-exceptions -fno-rtti
                 -I"$IMGUI_DEST" -I"$IMGUI_DEST/imgui" -I"$SDL_SRC/include")
    local srcs=(imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp
                imgui/imgui_widgets.cpp imgui/imgui_demo.cpp
                cimgui.cpp ImGuizmo/src/ImGuizmo.cpp cimguizmo.cpp
                backends/imgui_impl_sdl3.cpp backends/imgui_impl_opengl3.cpp)
    local objs=()
    for s in "${srcs[@]}"; do
        local o="$IMGUI_DEST/${s//\//_}.o"
        c++ "${flags[@]}" -c -o "$o" "$IMGUI_DEST/$s"
        objs+=("$o")
    done
    # Our own glue (tracked in csrc/, not vendored) rides in the same archive.
    c++ "${flags[@]}" -c -o "$IMGUI_DEST/dirt_imgui_shim.o" "$ROOT/csrc/dirt_imgui_shim.cpp"
    objs+=("$IMGUI_DEST/dirt_imgui_shim.o")

    rm -f "$IMGUI_DEST/libimgui.a"
    ar rcs "$IMGUI_DEST/libimgui.a" "${objs[@]}"
    echo "  done."
}

fetch_imgui

# --- delaunator-cpp (2D Delaunay triangulation) ------------------------------
# One MIT header. The terrain (src/geo/terrain.odin) is a triangulation of the
# ground *region* beside the road, not a loft between two rails — a loft can
# only make a topological rectangle, and the inside of a tight corner, the belly
# of a hairpin and a road that nearly touches itself are none of them.
#
# C++ with std::vector in its interface, so it crosses into Odin through
# csrc/dirt_delaunay_shim.cpp, exactly as the ImGui stack does. That shim is built
# *with* exceptions, because delaunator throws on degenerate input; libimgui.a
# above is built with -fno-exceptions and the two must not share a translation
# unit. Hence a separate archive rather than one more object in libimgui.a.
DELAUNATOR_SHA="c1521f6e879881232dcddabd6c2ddb6187e8714b"
DELAUNAY_DEST="$VENDOR/delaunay"

fetch_delaunay() {
    if [ -f "$DELAUNAY_DEST/libdelaunay.a" ]; then
        echo "  already present: delaunay"
        return
    fi
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$DELAUNAY_DEST"

    echo "  downloading delaunator-cpp @ ${DELAUNATOR_SHA:0:8}..."
    curl -fsSL "https://github.com/delfrrr/delaunator-cpp/archive/${DELAUNATOR_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/delaunator-cpp-*/include/delaunator.hpp "$DELAUNAY_DEST/"
    cp "$tmp"/delaunator-cpp-*/LICENSE "$DELAUNAY_DEST/LICENSE.delaunator"
    rm -rf "$tmp"

    echo "  compiling libdelaunay.a..."
    c++ -std=c++11 -O2 -fPIC -fno-rtti -I"$DELAUNAY_DEST" \
        -c -o "$DELAUNAY_DEST/dirt_delaunay_shim.o" "$ROOT/csrc/dirt_delaunay_shim.cpp"
    ar rcs "$DELAUNAY_DEST/libdelaunay.a" "$DELAUNAY_DEST/dirt_delaunay_shim.o"
    echo "  done."
}

fetch_delaunay

echo ""
echo "All deps ready."
