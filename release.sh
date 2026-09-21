#!/usr/bin/env bash
# Build a release binary, or ask GitHub to build and publish one.
#
#   ./release.sh --local
#   ./release.sh --public --version 0.1.0 --notes "notes here"
#
# Both produce the same artifact the same way: inside docker/Dockerfile, on
# glibc 2.28, because a build on this machine only starts on this machine. The
# shaders are built out here first — glslc needs glibc 2.38 and will not run in
# the image — and mounted in.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=dirtbench-build
WORKFLOW=release.yml
# Built in the image, never shared with a host build.
VENDOR_ALMA="$PWD/vendor-alma8"

usage() {
    cat >&2 <<'EOF'
usage: ./release.sh --local
       ./release.sh --public --version <x.y.z> --notes <text>
EOF
}

die() { echo "$*" >&2; exit 1; }

# --- what the source says the version is -------------------------------------

# One home for the version, src/app/notice.odin. --public states it too, and
# the two must agree: a tag that does not match what `dirtbench --version`
# prints is worse than no tag.
source_version() {
    sed -n 's/^VERSION :: "\(.*\)"$/\1/p' src/app/notice.odin
}

# --- the build ---------------------------------------------------------------

build_image() {
    docker build -q -t "$IMAGE" docker >/dev/null
}

# The image holds the toolchain; the tree and its vendor directory are mounted,
# so an incremental release does not recompile SDL. Running as the caller keeps
# root out of the working tree.
build_in_container() {
    mkdir -p build "$VENDOR_ALMA"
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "$PWD":/src \
        -v "$VENDOR_ALMA":/src/vendor \
        -e HOME=/tmp \
        "$IMAGE" -c '
set -euo pipefail
cd /src
./download-deps.sh
CXX_RUNTIME="$(c++ -print-file-name=libstdc++.a)"
GCC_RUNTIME="$(cc -print-libgcc-file-name)"
GCC_EH_RUNTIME="$(cc -print-file-name=libgcc_eh.a)"
odin build src/app -o:speed -out:build/dirtbench \
    -extra-linker-flags:"-L/src/vendor/sdl3 $CXX_RUNTIME $GCC_RUNTIME $GCC_EH_RUNTIME"
strip --strip-all build/dirtbench
'
}

# A binary that asks for a symbol version this image cannot have means the link
# happened somewhere else. Fail loudly rather than ship it.
check_floor() {
    local floor
    floor="$(objdump -T build/dirtbench | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
    case "$floor" in
        GLIBC_2.[0-9]|GLIBC_2.[12][0-9]) ;;
        *) die "glibc floor is $floor; the link did not happen in the image" ;;
    esac
    echo "glibc floor: $floor"
}

do_build() {
    ./build-shaders.sh
    build_image
    build_in_container
    check_floor
    echo "build/dirtbench"
}

# --- arguments ---------------------------------------------------------------

[ "$#" -ge 1 ] || { usage; exit 2; }
mode="$1"; shift

case "$mode" in
    --local)
        [ "$#" -eq 0 ] || { usage; exit 2; }
        do_build
        ;;
    --public)
        version=""
        notes=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --version) [ "$#" -ge 2 ] || die "--version needs a number"; version="$2"; shift 2 ;;
                --notes)   [ "$#" -ge 2 ] || die "--notes needs text";      notes="$2";   shift 2 ;;
                *) usage; exit 2 ;;
            esac
        done
        [ -n "$version" ] || { usage; exit 2; }
        [ -n "$notes" ]   || { usage; exit 2; }

        command -v gh >/dev/null || die "gh is not installed"
        gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"

        want="$(source_version)"
        [ "$version" = "$want" ] || die "--version $version, but src/app/notice.odin says $want"

        [ -z "$(git status --porcelain)" ] || die "the working tree is dirty; commit first"
        git rev-parse "v$version" >/dev/null 2>&1 && die "tag v$version already exists"

        head="$(git rev-parse HEAD)"
        git fetch -q origin
        git merge-base --is-ancestor "$head" origin/main \
            || die "HEAD is not pushed; the workflow builds what is on origin"

        echo "releasing v$version from ${head:0:8}"
        gh workflow run "$WORKFLOW" -f version="$version" -f notes="$notes"
        echo "watch it: gh run watch"
        ;;
    *)
        usage; exit 2 ;;
esac
