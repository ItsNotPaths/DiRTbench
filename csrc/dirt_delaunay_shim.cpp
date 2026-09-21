// Hand-written glue compiled into vendor/delaunay/libdelaunay.a by
// download-deps.sh.
//
// delaunator-cpp is a C++ header with std::vector in its interface, and Odin
// cannot call C++. This flattens it to a C API over plain arrays.
//
// It also swallows exceptions. delaunator throws std::runtime_error on inputs it
// cannot triangulate — all-collinear points, or fewer than three distinct ones —
// and Odin has no way to catch that. Callers get a return code instead. Note this
// translation unit is therefore built *with* exceptions, unlike libimgui.a.
//
// Unlike everything else under vendor/, this file is tracked in git.

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <vector>

// delaunator.hpp leans on libstdc++ pulling these in through other headers:
// it uses std::tie with no <tuple>, and std::runtime_error with <exception>
// rather than <stdexcept>. MSVC obliges with neither.
#include <stdexcept>
#include <tuple>

#include "delaunator.hpp"

extern "C" {

// `coords` is 2*npoints doubles, x and y interleaved.
//
// On success writes a malloc'd array of 3*(*out_ntris) vertex indices, which the
// caller must hand back to rsDelaunayFree.
//
//   0  ok
//  -1  fewer than three points
//  -2  nothing to triangulate (collinear, coincident, or delaunator threw)
//  -3  out of memory
int rsDelaunay(const double *coords, size_t npoints, uint32_t **out_tris, size_t *out_ntris) {
    *out_tris = nullptr;
    *out_ntris = 0;
    if (npoints < 3) {
        return -1;
    }
    try {
        std::vector<double> in(coords, coords + npoints * 2);
        delaunator::Delaunator d(in);

        const size_t ntris = d.triangles.size() / 3;
        if (ntris == 0) {
            return -2;
        }
        uint32_t *out = static_cast<uint32_t *>(std::malloc(ntris * 3 * sizeof(uint32_t)));
        if (out == nullptr) {
            return -3;
        }
        for (size_t i = 0; i < ntris * 3; i++) {
            out[i] = static_cast<uint32_t>(d.triangles[i]);
        }
        *out_tris = out;
        *out_ntris = ntris;
        return 0;
    } catch (...) {
        return -2;
    }
}

void rsDelaunayFree(uint32_t *tris) { std::free(tris); }

} // extern "C"
