#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
mkdir -p build dist

./download-deps.sh
CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin build src/app -o:speed -out:build/dirtbench \
    -extra-linker-flags:"-L$PWD/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
strip --strip-all build/dirtbench
tar -czf "dist/dirtbench-${ARCH}-linux.tar.gz" -C build dirtbench

echo "dist/dirtbench-${ARCH}-linux.tar.gz"
