package main

// The ground fading into the road.
//
// A DiRT 3 ground shader holds two textures, so two materials can never blend
// into each other — there is no vertex belonging to both. Only a third material
// holding both can, ramped across the join. The property under test is that its
// two ends are *exactly* its neighbours: anything else swaps one hard edge for
// two fainter ones.

import "core:testing"
import d3 "../d3"
import "../geo"
import "../gfx"

@(private = "file")
straight :: proc(sp: ^geo.Spline, count: int) {
	clear(&sp.points)
	clear(&sp.guards)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * 20}
		geo.spline_push(sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
}

// Build the ground beside a road, and report the roadside weight of every
// vertex that carries one.
@(private = "file")
ground :: proc(sp: ^geo.Spline, guards: bool) -> (mesh: geo.Tri_Mesh, ok: bool) {
	if guards {
		for side in 0 ..< 2 {
			geo.guard_add(sp, {kind = .Cliff, side = side, at = 0, size = 6, span = 400, taper = 10, width = 2})
		}
	}
	ribbon := geo.build_ribbon(sp^, allocator = context.temp_allocator)
	terrain := geo.TERRAIN_DEFAULTS
	terrain.enabled = true
	defer geo.terrain_delete(&terrain)
	geo.terrain_ensure(&terrain, ribbon, 0)
	field: geo.Terrain_Field
	defer geo.terrain_field_delete(&field)
	arc := geo.ribbon_arc(ribbon)
	ds := geo.sample_spacing(ribbon)
	geo.terrain_field_ensure(&field, &terrain, ribbon, arc, ds, 0, 1)
	if len(field.tris) == 0 { return }
	mesh = geo.tri_mesh_make(context.temp_allocator)
	geo.build_terrain_mesh(&mesh, &terrain, &field, ribbon, 0)
	return mesh, true
}

// The headline. The ground keeps all of the road's texture where it meets the
// road, none of it by the time it is clear, and takes real values in between —
// a step at either end would be a hard edge moved, not removed.
@(test)
the_ground_fades_into_a_bare_road_edge :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 8)
	mesh, ok := ground(&sp, guards = false)
	testing.expect(t, ok, "the terrain must build"); if !ok { return }

	// The road runs up +z at x = 0, so |x| is distance from the centreline —
	// but only alongside it. Past either end the ground wraps around, and a
	// point there sits at a small |x| while being nowhere near a road edge, so
	// the middle of the run is the only part where |x| means what it looks like.
	//
	// Bucketed rather than compared pairwise: the lattice is unstructured, and
	// what has to hold is the trend, not any one neighbouring pair.
	BUCKET :: 2.0
	MIDDLE_LO, MIDDLE_HI :: 40.0, 100.0 // 8 points, 20 m apart
	sum := make(map[int]f32, context.temp_allocator)
	count := make(map[int]int, context.temp_allocator)
	lo, hi := max(f32), f32(0)
	roadside := 0
	for mat, tri in mesh.mat {
		if mat != .Roadside { continue }
		roadside += 1
		for corner in 0 ..< 3 {
			w := mesh.blend[tri*3 + corner]
			lo = min(lo, w); hi = max(hi, w)
			p := mesh.pos[tri*3 + corner]
			if p.z < MIDDLE_LO || p.z > MIDDLE_HI { continue }
			b := int(abs(p.x) / BUCKET)
			sum[b] += w
			count[b] += 1
		}
	}
	testing.expect(t, roadside > 0, "a bare road edge must emit roadside ground")
	testing.expectf(t, hi > 0.99, "the seam must keep the road's texture whole, got %v", hi)
	testing.expectf(t, lo < 0.01, "the fade must reach plain ground, got %v", lo)

	// Falls away from the road and never climbs back. A sign error or a leg read
	// off the wrong seam shows up here and nowhere else — both ends can be right
	// while the middle runs backwards.
	last, started := f32(1.01), false
	for b := 0; b < 40; b += 1 {
		if count[b] == 0 { continue }
		mean := sum[b] / f32(count[b])
		testing.expectf(t, mean <= last + 0.01,
			"ground %.0f m out keeps more road (%v) than the ground inside it (%v)",
			f32(b)*BUCKET, mean, last)
		last = mean
		started = true
	}
	testing.expect(t, started, "the buckets must hold something")
}

// A cliff or a bank stands between the ground and the road, so what the ground
// meets there is rock, not road. Fading in the road's texture at the crest would
// paint gravel on top of a cliff.
@(test)
a_guard_keeps_the_road_out_of_the_ground :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 8)
	// The same road twice, once walled on both sides. Comparing the two is what
	// says the guard suppressed the fade rather than the test finding an empty
	// mesh, and it needs no opinion about which side is which.
	bare_sp: geo.Spline
	defer geo.spline_free(&bare_sp)
	straight(&bare_sp, 8)
	bare_mesh, bare_ok := ground(&bare_sp, guards = false)
	testing.expect(t, bare_ok, "the bare terrain must build"); if !bare_ok { return }

	walled, ok := ground(&sp, guards = true)
	testing.expect(t, ok, "the walled terrain must build"); if !ok { return }

	testing.expect(t, roadside_tris(bare_mesh) > 0, "a bare road edge must fade")
	testing.expect_value(t, roadside_tris(walled), 0)
}

@(private = "file")
roadside_tris :: proc(m: geo.Tri_Mesh) -> (n: int) {
	for mat in m.mat { if mat == .Roadside { n += 1 } }
	return
}

// Drawn as roadside, driven as ground. This is the first material where the two
// axes part company, and it is the whole reason they are two.
@(test)
roadside_ground_still_drives_as_ground :: proc(t: ^testing.T) {
	export := MAT_EXPORT[.Roadside]
	testing.expect_value(t, export.draw, d3.Draw_Material.Roadside)
	testing.expect_value(t, export.surface, d3.Collision_Surface.Terrain)
	testing.expect_value(t, export.surface, MAT_EXPORT[.Terrain].surface)
	testing.expect(t, export.draw != MAT_EXPORT[.Terrain].draw)
}

// --- the road changing surface -----------------------------------------------

// One drawn material over two codes: the paint crosses the change gradually and
// the grip flips at the control point. Stock's own boundary on Tupasentie has
// its paint and its physics about 30 m apart, so they are not required to agree
// — but each has to be right on its own side.
//
// Run over a **branching** road on purpose. A straight chain samples through
// `is_linear`, which emits no run boundaries at all, and every real venue has a
// branch somewhere. The first version of this ran straight and passed while the
// export drew no changeover whatsoever: a surface changes at a control point,
// which is exactly where one graph edge ends and the next begins, and the change
// detector was skipping those slices.
@(test)
the_road_fades_between_its_two_surfaces :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 10)
	sp.points[5].surface = .Paved
	// A spur off point 2, which is what takes the ribbon down the graph sampler.
	geo.spline_push(&sp, geo.make_point({30, 0, 40}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = 2))
	testing.expect(t, !geo.is_linear(sp), "the ribbon must run through the graph sampler")
	ribbon := geo.build_ribbon(sp, allocator = context.temp_allocator)
	mesh := geo.build_tri_mesh(ribbon, 0, geo.DEFAULT_LOOK, context.temp_allocator)

	lo, hi := max(f32), f32(0)
	between, changing := 0, 0
	seen: [geo.Mat_Id]int
	for mat, tri in mesh.mat {
		seen[mat] += 1
		if mat != .Road_Change_Loose && mat != .Road_Change_Paved { continue }
		changing += 1
		for corner in 0 ..< 3 {
			w := mesh.blend[tri*3 + corner]
			lo = min(lo, w); hi = max(hi, w)
			if w > 0.05 && w < 0.95 { between += 1 }
		}
	}
	testing.expect(t, changing > 0, "a surface change must emit changeover road")
	testing.expect(t, between > 0, "the fade must have a middle")
	testing.expectf(t, lo < 0.2, "the loose end must reach the loose road, got %v", lo)
	testing.expectf(t, hi > 0.8, "the paved end must reach the paved road, got %v", hi)

	// Both codes appear, because the fade straddles the point where grip flips.
	testing.expect(t, seen[.Road_Change_Loose] > 0 && seen[.Road_Change_Paved] > 0,
		"the changeover must carry both surfaces, not one")
	// And the road either side of the fade is ordinary again.
	testing.expect(t, seen[.Road] > 0 && seen[.Road_Paved] > 0)
}

// Both halves draw with one material and drive as two. This is the pair the
// split of Draw_Material from Collision_Surface exists for.
@(test)
the_changeover_is_one_material_over_two_codes :: proc(t: ^testing.T) {
	loose := MAT_EXPORT[.Road_Change_Loose]
	paved := MAT_EXPORT[.Road_Change_Paved]
	testing.expect_value(t, loose.draw, paved.draw)
	testing.expect(t, loose.surface != paved.surface)
	testing.expect_value(t, loose.surface, MAT_EXPORT[.Road].surface)
	testing.expect_value(t, paved.surface, MAT_EXPORT[.Road_Paved].surface)
}

// A road that never changes surface never emits a changeover, so the fade
// cannot cost anything on the venues that have one surface.
@(test)
a_road_of_one_surface_has_nothing_to_fade :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	straight(&sp, 10)
	ribbon := geo.build_ribbon(sp, allocator = context.temp_allocator)
	mesh := geo.build_tri_mesh(ribbon, 0, geo.DEFAULT_LOOK, context.temp_allocator)
	for mat in mesh.mat {
		testing.expect(t, mat != .Road_Change_Loose && mat != .Road_Change_Paved)
	}
}
