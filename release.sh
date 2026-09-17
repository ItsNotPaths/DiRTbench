#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
    echo "usage: ./release.sh --local" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

case "$1" in
    --local) ;;
    --public)
        echo "public releases are not implemented yet" >&2
        exit 2
        ;;
    *)
        usage
        exit 2
        ;;
esac

mkdir -p build

if [ ! -f vendor/sdl3/libSDL3.a ] ||
   [ ! -f vendor/imgui/libimgui.a ] ||
   [ ! -f vendor/delaunay/libdelaunay.a ]; then
    echo "dependencies are missing; run ./download-deps.sh first" >&2
    exit 1
fi

# The GPU shaders are source (src/gfx/shaders/); their SPIR-V builds land in
# build/ and are loaded by the binary at compile time. Rebuilt when stale.
if ! command -v glslc >/dev/null 2>&1; then
    echo "glslc is missing; install shaderc to build the shaders" >&2
    exit 1
fi
mkdir -p build/shaders
for s in src/gfx/shaders/mesh.vert src/gfx/shaders/mesh.frag; do
    o="build/shaders/$(basename "$s").spv"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
        glslc "$s" -o "$o"
    fi
done

CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin build src/app -o:speed -out:build/dirtbench \
    -extra-linker-flags:"-L$PWD/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
strip --strip-all build/dirtbench

echo "build/dirtbench"
