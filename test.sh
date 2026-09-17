#!/usr/bin/env bash
# Every suite. The d3 package needs no deps; src/app links ImGui.
set -euo pipefail
cd "$(dirname "$0")"
odin test src/d3
odin test src/gfx
CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin test src/app -extra-linker-flags:"-L$PWD/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
