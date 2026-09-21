#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"

# Windows compiles the same sources with MSVC instead of gcc, and names the
# archives the way `foreign import` asks for them there. Everything else —
# what is fetched, the pins, the staleness tests — is shared.
#
# On Windows this script wants an MSVC environment already set up (vcvars64),
# because `cl` and `lib` are not on PATH without one.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) WINDOWS=true ;;
    *)                    WINDOWS=false ;;
esac

# One object from one source. Same arguments either way; the flags differ.
compile_obj() {
    local out="$1" src="$2"; shift 2
    if $WINDOWS; then
        cl //nologo //std:c++14 //O2 //EHsc- //GR- //c //Fo:"$out" "$@" "$src"
    else
        c++ -std=c++11 -O2 -fPIC -fno-exceptions -fno-rtti -c -o "$out" "$@" "$src"
    fi
}

# One static library from a pile of objects. Replaces whatever was there.
archive() {
    local out="$1"; shift
    rm -f "$out"
    if $WINDOWS; then
        lib //nologo //OUT:"$out" "$@"
    else
        ar rcs "$out" "$@"
    fi
}

# What the archives are called, which is what src/ `foreign import`s.
if $WINDOWS; then
    IMGUI_LIB_NAME=imgui.lib
    DELAUNAY_LIB_NAME=delaunay.lib
    OBJ_EXT=obj
else
    IMGUI_LIB_NAME=libimgui.a
    DELAUNAY_LIB_NAME=libdelaunay.a
    OBJ_EXT=o
fi

# --check reports what is missing or stale and builds nothing. release.sh uses
# it as its dependency guard.
CHECK_ONLY=false
case "${1:-}" in
    --check) CHECK_ONLY=true ;;
    "")      ;;
    *)       echo "usage: ./download-deps.sh [--check]" >&2; exit 2 ;;
esac
STALE=false

# Every dep owns a staleness test and a build. Existence is not freshness: a
# newer source or a changed build flag must rebuild the archive.
dep() {
    local name="$1" stale="$2" build="$3"
    if ! "$stale"; then
        echo "  already present: $name"
    elif $CHECK_ONLY; then
        echo "  missing or stale: $name"
        STALE=true
    else
        "$build"
    fi
}

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
#
# SDL is linked into dirtbench, not installed.  Keeping the archive beside the
# rest of the vendored code also prevents a system libSDL3.so from winning the
# link on development machines.
SDL_VERSION="3.4.16"
SDL_SRC="$VENDOR/sdl3-src"
SDL_DEST="$VENDOR/sdl3"
# What cmake produces, and what we install it as. Odin's `vendor:sdl3` does
# `foreign import lib { "SDL3.lib" }` on Windows — a bare name the linker
# resolves off /LIBPATH — so the static library has to land under that name.
if $WINDOWS; then
    SDL_BUILT_NAME=SDL3-static.lib
    SDL_LIB_NAME=SDL3.lib
else
    SDL_BUILT_NAME=libSDL3.a
    SDL_LIB_NAME=libSDL3.a
fi
SDL_A="$SDL_DEST/$SDL_LIB_NAME"
SDL_STAMP="$SDL_DEST/config.stamp"

# A failed feature probe leaves a misleading cache behind, so configuration is
# intentionally fresh.  SDL_GPU stays enabled; SDL_Render is unrelated.
SDL_CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DSDL_SHARED=OFF -DSDL_STATIC=ON
    -DSDL_GPU=ON -DSDL_VULKAN=ON -DSDL_AUDIO=ON
    -DSDL_RENDER=OFF -DSDL_CAMERA=OFF -DSDL_JOYSTICK=OFF
    -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF
    -DSDL_POWER=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF
    -DSDL_X11_XTEST=OFF -DSDL_TEST_LIBRARY=OFF
)

# MSVC picks its runtime per configuration, and every object in the final link
# has to agree. Odin's Windows target is the non-debug dynamic CRT.
if $WINDOWS; then
    SDL_CMAKE_FLAGS+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL)
fi

sdl_config() { echo "$SDL_VERSION ${SDL_CMAKE_FLAGS[*]}"; }

# The version pin and the flags are the archive's real inputs, and neither
# leaves a mark in the tree, so the build writes them down beside it.
sdl3_stale() {
    [ ! -f "$SDL_A" ] || [ "$(cat "$SDL_STAMP" 2>/dev/null)" != "$(sdl_config)" ]
}

fetch_sdl() {
    if [ ! -d "$SDL_SRC" ] || [ -z "$(ls -A "$SDL_SRC" 2>/dev/null)" ]; then
        echo "  downloading SDL $SDL_VERSION..."
        mkdir -p "$SDL_SRC"
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C "$SDL_SRC" \
            || { rm -rf "$SDL_SRC"; exit 1; }
    fi

    echo "  compiling static SDL3..."
    rm -rf "$SDL_SRC/build"
    cmake -S "$SDL_SRC" -B "$SDL_SRC/build" "${SDL_CMAKE_FLAGS[@]}" >/dev/null
    cmake --build "$SDL_SRC/build" --config Release --parallel >/dev/null
    mkdir -p "$SDL_DEST"
    # A multi-config generator (which is what cmake picks on Windows) puts the
    # library under its configuration rather than beside the cache.
    local built
    built="$(find "$SDL_SRC/build" -name "$SDL_BUILT_NAME" -print -quit)"
    [ -n "$built" ] || { echo "  $SDL_BUILT_NAME was not produced" >&2; exit 1; }
    cp "$built" "$SDL_A"
    sdl_config > "$SDL_STAMP"
    echo "  done."
}

dep sdl3 sdl3_stale fetch_sdl

# --- Dear ImGui + ImGuizmo (+ C APIs + SDL3/SDL_GPU backend) -----------------
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

# A newer backend source or shim must retrigger the build.
imgui_stale() {
    local a="$IMGUI_DEST/$IMGUI_LIB_NAME"
    if [ ! -f "$a" ] || [ ! -f "$IMGUI_DEST/backends/imgui_impl_sdlgpu3.cpp" ]; then
        return 0
    fi
    for s in "$ROOT/csrc/dirt_imgui_shim.cpp" \
             "$IMGUI_DEST/backends/imgui_impl_sdl3.cpp" \
             "$IMGUI_DEST/backends/imgui_impl_sdlgpu3.cpp" \
             "$IMGUI_DEST/backends/imgui_impl_sdlgpu3.h" \
             "$IMGUI_DEST/backends/imgui_impl_sdlgpu3_shaders.h"; do
        if [ "$s" -nt "$a" ]; then
            return 0
        fi
    done
    return 1
}

# The layout below is dictated by the generated sources' own #includes:
# cimgui.cpp does #include "./imgui/imgui.h", and cimguizmo.cpp does
# #include "./ImGuizmo/src/ImGuizmo.h". Keep the tree shaped that way.
fetch_imgui() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$IMGUI_DEST/imgui" "$IMGUI_DEST/backends" "$IMGUI_DEST/ImGuizmo/src"

    echo "  downloading Dear ImGui $IMGUI_TAG..."
    curl -fsSL "https://github.com/ocornut/imgui/archive/refs/tags/${IMGUI_TAG}.tar.gz" | tar xz -C "$tmp"
    cp "$tmp"/imgui-*/{imgui.cpp,imgui_draw.cpp,imgui_tables.cpp,imgui_widgets.cpp,imgui_demo.cpp} "$IMGUI_DEST/imgui/"
    cp "$tmp"/imgui-*/{imgui.h,imgui_internal.h,imconfig.h,imstb_textedit.h,imstb_rectpack.h,imstb_truetype.h} "$IMGUI_DEST/imgui/"
    cp "$tmp"/imgui-*/backends/{imgui_impl_sdl3.cpp,imgui_impl_sdl3.h,imgui_impl_sdlgpu3.cpp,imgui_impl_sdlgpu3.h,imgui_impl_sdlgpu3_shaders.h} "$IMGUI_DEST/backends/"

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

    echo "  compiling $IMGUI_LIB_NAME..."
    local inc=(-I"$IMGUI_DEST" -I"$IMGUI_DEST/imgui" -I"$SDL_SRC/include")
    local srcs=(imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp
                imgui/imgui_widgets.cpp imgui/imgui_demo.cpp
                cimgui.cpp ImGuizmo/src/ImGuizmo.cpp cimguizmo.cpp
                backends/imgui_impl_sdl3.cpp backends/imgui_impl_sdlgpu3.cpp)
    local objs=()
    for s in "${srcs[@]}"; do
        local o="$IMGUI_DEST/${s//\//_}.$OBJ_EXT"
        compile_obj "$o" "$IMGUI_DEST/$s" "${inc[@]}"
        objs+=("$o")
    done
    # Our own glue (tracked in csrc/, not vendored) rides in the same archive.
    compile_obj "$IMGUI_DEST/dirt_imgui_shim.$OBJ_EXT" "$ROOT/csrc/dirt_imgui_shim.cpp" "${inc[@]}"
    objs+=("$IMGUI_DEST/dirt_imgui_shim.$OBJ_EXT")

    archive "$IMGUI_DEST/$IMGUI_LIB_NAME" "${objs[@]}"
    echo "  done."
}

dep imgui imgui_stale fetch_imgui

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

# Our shim is the archive's only source, so editing it must rebuild.
delaunay_stale() {
    local a="$DELAUNAY_DEST/$DELAUNAY_LIB_NAME"
    if [ ! -f "$a" ]; then
        return 0
    fi
    for s in "$ROOT/csrc/dirt_delaunay_shim.cpp" "$DELAUNAY_DEST/delaunator.hpp"; do
        if [ "$s" -nt "$a" ]; then
            return 0
        fi
    done
    return 1
}

fetch_delaunay() {
    local tmp
    mkdir -p "$DELAUNAY_DEST"

    if [ ! -f "$DELAUNAY_DEST/delaunator.hpp" ]; then
        tmp="$(mktemp -d)"
        echo "  downloading delaunator-cpp @ ${DELAUNATOR_SHA:0:8}..."
        curl -fsSL "https://github.com/delfrrr/delaunator-cpp/archive/${DELAUNATOR_SHA}.tar.gz" | tar xz -C "$tmp"
        cp "$tmp"/delaunator-cpp-*/include/delaunator.hpp "$DELAUNAY_DEST/"
        cp "$tmp"/delaunator-cpp-*/LICENSE "$DELAUNAY_DEST/LICENSE.delaunator"
        rm -rf "$tmp"
    fi

    # Built *with* exceptions: delaunator throws on degenerate input, and
    # libimgui is built without them, so the two must not share an archive.
    echo "  compiling $DELAUNAY_LIB_NAME..."
    local obj="$DELAUNAY_DEST/dirt_delaunay_shim.$OBJ_EXT"
    if $WINDOWS; then
        cl //nologo //std:c++14 //O2 //EHsc //GR- //c //Fo:"$obj" \
            -I"$DELAUNAY_DEST" "$ROOT/csrc/dirt_delaunay_shim.cpp"
    else
        c++ -std=c++11 -O2 -fPIC -fno-rtti -I"$DELAUNAY_DEST" -c -o "$obj" \
            "$ROOT/csrc/dirt_delaunay_shim.cpp"
    fi
    archive "$DELAUNAY_DEST/$DELAUNAY_LIB_NAME" "$obj"
    echo "  done."
}

dep delaunay delaunay_stale fetch_delaunay

if $STALE; then
    echo "run ./download-deps.sh" >&2
    exit 1
fi

echo ""
echo "All deps ready."
