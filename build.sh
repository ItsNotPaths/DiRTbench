#!/usr/bin/env bash
# Build the editor. `./download-deps.sh` once first.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${MODE:-release}"
FLAGS=(-o:speed)
[ "$MODE" = debug ] && FLAGS=(-o:none -debug)

mkdir -p build
odin build src/app -out:build/dirtbench "${FLAGS[@]}"
echo "build/dirtbench"
