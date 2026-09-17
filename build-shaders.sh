#!/usr/bin/env bash
# The GPU shaders are source (src/gfx/shaders/); their SPIR-V builds land in
# build/shaders/ and are loaded by the binary at compile time. Rebuilt when
# stale. src/gfx does not build without them.
set -euo pipefail
cd "$(dirname "$0")"

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
