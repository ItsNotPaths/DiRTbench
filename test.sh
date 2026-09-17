#!/usr/bin/env bash
# Every suite. The d3 package needs no deps; src/app links ImGui.
set -euo pipefail
cd "$(dirname "$0")"
# Compiled shaders must exist before src/gfx builds; see release.sh.
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
odin test src/d3
odin test src/gfx
CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin test src/app -extra-linker-flags:"-L$PWD/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
