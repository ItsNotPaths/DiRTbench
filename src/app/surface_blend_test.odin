package main

// The road's texture mix.
//
// A DiRT 3 ground shader carries two diffuse layers and blends them per vertex,
// which is how stock paints worn wheel tracks against a coarser verge out of one
// material. The property under test is that the mix is a function of the road
// column alone: the middle sits at one texture, both edges at the other, and
// nothing else in the mesh is painted at all.

import "core:math"
import "core:testing"
import "../geo"
import "../gfx"

@(private = "file")
straight :: proc(sp: ^geo.Spline, count: int, spacing: f32) {
	clear(&sp.points)
	clear(&sp.guards)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * spacing}
		geo.spline_push(sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
}

@(test)
the_road_mix_is_a_function_of_the_column :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 6, 20)
	ribbon := geo.build_ribbon(sp, allocator = context.temp_allocator)
	m := geo.build_tri_mesh(ribbon, 0, geo.DEFAULT_LOOK, context.temp_allocator)

	testing.expect_value(t, len(m.blend), len(m.pos))

	TOLERANCE :: 1e-5
	lo, hi := max(f32), f32(0)
	painted := 0
	for mat, tri in m.mat {
		for corner in 0 ..< 3 {
			i := tri*3 + corner
			got := m.blend[i]
			if mat != .Road && mat != .Road_Paved {
				testing.expectf(t, got == 0, "%v vertex carries mix %v, only the road is painted", mat, got)
				continue
			}
			// `v` runs 0 at one road edge to -1 at the other, so -v is the column
			// fraction the mix is built from.
			want := abs(2*-m.uv[i][1] - 1)
			testing.expectf(t, abs(got-want) < TOLERANCE,
				"road vertex at v %v got mix %v, the column gives %v", m.uv[i][1], got, want)
			lo = min(lo, got); hi = max(hi, got)
			painted += 1
		}
	}
	testing.expect(t, painted > 0, "the road must emit painted vertices")
	testing.expectf(t, lo < TOLERANCE, "the middle of the road must reach the first texture, got %v", lo)
	testing.expectf(t, hi > 1-TOLERANCE, "the road edge must reach the second texture, got %v", hi)
}

// The mix is carried per vertex, so it has to survive the sort the export runs
// before a target sees the soup. A sort that moved `mat` and left `blend` behind
// would paint the wrong triangles and still pass every count.
@(test)
sorting_by_material_keeps_each_vertex_its_mix :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 6, 20)
	ribbon := geo.build_ribbon(sp, allocator = context.temp_allocator)
	m := geo.build_tri_mesh(ribbon, 0, geo.DEFAULT_LOOK, context.temp_allocator)
	order, _ := sort_faces_by_material(m)
	collision := collision_from_mesh(m, order, context.temp_allocator)

	testing.expect_value(t, len(collision), len(order))
	for tri, i in collision {
		for corner in 0 ..< 3 {
			want := m.blend[order[i]*3 + corner]
			testing.expectf(t, tri.Blend[corner] == want,
				"triangle %d corner %d got mix %v, the mesh says %v", i, corner, tri.Blend[corner], want)
			p := m.pos[order[i]*3 + corner]
			testing.expectf(t, math.abs(tri.Points[corner][0]-p.x) < 1e-6,
				"triangle %d corner %d lost its position", i, corner)
		}
	}
}
