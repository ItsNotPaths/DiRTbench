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

# Existence is not freshness. --check also fails on an archive older than its
# sources or built with flags the script no longer uses.
if ! deps="$(./download-deps.sh --check 2>&1)"; then
    echo "$deps" >&2
    exit 1
fi

./build-shaders.sh

CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin build src/app -o:speed -out:build/dirtbench \
    -extra-linker-flags:"-L$PWD/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
strip --strip-all build/dirtbench

echo "build/dirtbench"
