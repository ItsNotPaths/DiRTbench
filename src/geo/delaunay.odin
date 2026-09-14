package geo

// Odin bindings for delaunator-cpp, via csrc/dirt_delaunay_shim.cpp.
//
// 2D Delaunay triangulation of a point set. The terrain (terrain.odin) uses it
// to triangulate the ground *region* beside the road: a Delaunay triangulation
// maximises the minimum angle, which is exactly the property a swept loft cannot
// offer, and it does not care whether the region is convex, concave, pinched or
// multiply-connected.
//
// Vendored into vendor/delaunay/libdelaunay.a by download-deps.sh, in its own
// archive rather than libimgui.a's: delaunator throws, so the shim is compiled
// with exceptions while the ImGui stack is compiled without them.

import "core:c"

foreign import delaunay_lib {
	"../../vendor/delaunay/libdelaunay.a",
	"system:stdc++",
}

@(default_calling_convention = "c")
foreign delaunay_lib {
	@(link_name = "rsDelaunay")
	dirt_delaunay :: proc(coords: [^]f64, npoints: c.size_t, out_tris: ^[^]u32, out_ntris: ^c.size_t) -> c.int ---

	@(link_name = "rsDelaunayFree")
	dirt_delaunay_free :: proc(tris: [^]u32) ---
}

// Triangulate `coords`, which is x/y interleaved. The returned slice aliases
// malloc'd C memory and must be released with `delaunay_delete`.
//
// Fails on fewer than three points, and on point sets with no triangulation at
// all — all-collinear, or all-coincident. Duplicate points are the caller's
// problem: delaunator will either drop them or refuse the whole set, so dedupe
// first (terrain.odin does).
delaunay_triangulate :: proc(coords: []f64) -> (tris: [][3]u32, ok: bool) {
	if len(coords) < 6 || len(coords) % 2 != 0 {
		return nil, false
	}
	raw: [^]u32
	count: c.size_t
	if dirt_delaunay(raw_data(coords), c.size_t(len(coords) / 2), &raw, &count) != 0 {
		return nil, false
	}
	return ([^][3]u32)(raw)[:count], true
}

delaunay_delete :: proc(tris: [][3]u32) {
	if len(tris) > 0 {
		dirt_delaunay_free(([^]u32)(raw_data(tris)))
	}
}
