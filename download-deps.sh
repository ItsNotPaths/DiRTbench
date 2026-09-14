#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"

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

# --- Dear ImGui + ImGuizmo (+ C APIs + raylib backend) -----------------------
# All five sources are C++ and all compile into one static lib, vendor/imgui/
# libimgui.a, which src/imgui.odin and src/imguizmo.odin link against.
#
#   imgui      Dear ImGui itself                              (MIT)
#   cimgui     generated flat C API for imgui                 (MIT)
#   ImGuizmo   the 3D transform gizmo                         (MIT)
#   cimguizmo  generated flat C API for ImGuizmo              (MIT)
#   rlImGui    raylib backend; renders imgui through rlgl     (zlib)
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
#   - RAYLIB_TAG must match ODINROOT vendor/raylib (libraylib.so.550).
#   - rlImGui's Raylib_5_5 tag is the raylib-5.5-compatible cut.
IMGUI_TAG="v1.92.8"
CIMGUI_SHA="d298666861ebf00dcfeb2407409931c04e47e33c"
GUIZMO_SHA="a712ea83e937cc6f11e22c3b2c82920857ae13df"
CIMGUIZMO_SHA="c351c2da1de08d7db94a51ca12c3b03697aee80b"
RLIMGUI_TAG="Raylib_5_5"
RAYLIB_TAG="5.5"
IMGUI_DEST="$VENDOR/imgui"

# The layout below is dictated by the generated sources' own #includes:
# cimgui.cpp does #include "./imgui/imgui.h", and cimguizmo.cpp does
# #include "./ImGuizmo/src/ImGuizmo.h". Keep the tree shaped that way.
fetch_imgui() {
    if [ -f "$IMGUI_DEST/libimgui.a" ]; then
        echo "  already present: imgui"
        return
    fi
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$IMGUI_DEST/imgui" "$IMGUI_DEST/ImGuizmo/src"

    echo "  downloading Dear ImGui $IMGUI_TAG..."
    curl -fsSL "https://github.com/ocornut/imgui/archive/refs/tags/${IMGUI_TAG}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/imgui-*/{imgui.cpp,imgui_draw.cpp,imgui_tables.cpp,imgui_widgets.cpp,imgui_demo.cpp} "$IMGUI_DEST/imgui/"
    cp "$tmp"/imgui-*/{imgui.h,imgui_internal.h,imconfig.h,imstb_textedit.h,imstb_rectpack.h,imstb_truetype.h} "$IMGUI_DEST/imgui/"

    echo "  downloading cimgui @ ${CIMGUI_SHA:0:8}..."
    curl -fsSL "https://github.com/cimgui/cimgui/archive/${CIMGUI_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/cimgui-*/{cimgui.cpp,cimgui.h,cimconfig.h} "$IMGUI_DEST/"

    echo "  downloading ImGuizmo @ ${GUIZMO_SHA:0:8}..."
    curl -fsSL "https://github.com/CedricGuillemet/ImGuizmo/archive/${GUIZMO_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/ImGuizmo-*/src/{ImGuizmo.cpp,ImGuizmo.h} "$IMGUI_DEST/ImGuizmo/src/"

    echo "  downloading cimguizmo @ ${CIMGUIZMO_SHA:0:8}..."
    curl -fsSL "https://github.com/cimgui/cimguizmo/archive/${CIMGUIZMO_SHA}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/cimguizmo-*/{cimguizmo.cpp,cimguizmo.h} "$IMGUI_DEST/"

    echo "  downloading rlImGui $RLIMGUI_TAG..."
    curl -fsSL "https://github.com/raylib-extras/rlImGui/archive/refs/tags/${RLIMGUI_TAG}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/rlImGui-*/{rlImGui.cpp,rlImGui.h,imgui_impl_raylib.h,rlImGuiColors.h} "$IMGUI_DEST/"

    # rlImGui.cpp is the only thing that needs raylib's C headers; rlImGui
    # renders through rlgl, so imgui's own GL/GLFW backends are never built.
    echo "  downloading raylib $RAYLIB_TAG headers..."
    local rlbase="https://raw.githubusercontent.com/raysan5/raylib/${RAYLIB_TAG}/src"
    for h in raylib.h raymath.h rlgl.h; do
        curl -fsSL -o "$IMGUI_DEST/$h" "$rlbase/$h"
    done
    rm -rf "$tmp"

    # NO_FONT_AWESOME drops rlImGui's embedded icon font (an extra ~200KB and a
    # third licence) which the editor does not use.
    echo "  compiling libimgui.a..."
    local flags=(-std=c++11 -O2 -fPIC -fno-exceptions -fno-rtti -DNO_FONT_AWESOME
                 -I"$IMGUI_DEST" -I"$IMGUI_DEST/imgui")
    local srcs=(imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp
                imgui/imgui_widgets.cpp imgui/imgui_demo.cpp
                cimgui.cpp ImGuizmo/src/ImGuizmo.cpp cimguizmo.cpp rlImGui.cpp)
    local objs=()
    for s in "${srcs[@]}"; do
        local o="$IMGUI_DEST/${s//\//_}.o"
        c++ "${flags[@]}" -c -o "$o" "$IMGUI_DEST/$s"
        objs+=("$o")
    done
    # Our own glue (tracked in csrc/, not vendored) rides in the same archive.
    c++ "${flags[@]}" -c -o "$IMGUI_DEST/dirt_imgui_shim.o" "$ROOT/csrc/dirt_imgui_shim.cpp"
    objs+=("$IMGUI_DEST/dirt_imgui_shim.o")

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
