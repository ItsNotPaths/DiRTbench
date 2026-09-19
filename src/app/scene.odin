package main

// What a window draws into its viewport, and what it picks out of it.
//
// Picking and drawing share the ribbon and the spline, and neither mutates
// anything: a pick returns an index, a draw emits geometry.

import "../geo"
import "../gfx"

// Ground grid, sized to the new view distance: slices * spacing metres across.
GRID_SLICES :: 256

GRID_SPACING :: 32

color_mix :: proc(a, b: gfx.Color, t: f32) -> (out: gfx.Color) {
	for i in 0 ..< 4 {
		out[i] = u8(f32(a[i]) + (f32(b[i]) - f32(a[i])) * clamp(t, 0, 1))
	}
	return
}

// --- Picking ----------------------------------------------------------------

ray_ground :: proc(ray: gfx.Ray) -> (hit: gfx.Vector3, ok: bool) {
	if abs(ray.direction.y) < 1e-6 {
		return {}, false
	}
	t := (GROUND_Y - ray.position.y) / ray.direction.y
	if t < 0 {
		return {}, false
	}
	return ray.position + ray.direction * t, true
}

// Where the cursor lands on the ground: the terrain surface as it was last
// built, or the world plane when there is no terrain to hit. Brute force over
// the field's triangles: affordable on a click, and at worst once per frame
// while a prop ghost tracks the cursor.
pick_ground :: proc(ed: ^Editor, ray: gfx.Ray) -> (gfx.Vector3, bool) {
	f := &ed.doc.terrain_field
	at: gfx.Vector3
	best := max(f32)
	if len(f.ys) == len(f.pts) {
		vert :: proc(f: ^geo.Terrain_Field, i: u32) -> gfx.Vector3 {
			return {f.pts[i].x, f.ys[i], f.pts[i].z}
		}
		for tri in f.tris {
			c := gfx.GetRayCollisionTriangle(ray, vert(f, tri[0]), vert(f, tri[1]), vert(f, tri[2]))
			if c.hit && c.distance < best {
				at, best = c.point, c.distance
			}
		}
	}
	if best < max(f32) {
		return at, true
	}
	// With terrain on, a miss means the cursor is off the ground — or that the
	// field is in the rebuild worker's hands this frame. Either way there is no
	// answer, and the world plane is the wrong one: it is at y = 0 and the
	// ground need not be anywhere near it.
	if ed.doc.terrain.enabled {
		return {}, false
	}
	return ray_ground(ray)
}

// nearest control point the ray strikes, or -1. The distance comes back too, so
// a click can be arbitrated against a terrain node hit (see pick_terrain_node).
pick_point :: proc(sp: geo.Spline, ray: gfx.Ray) -> (idx: int, dist: f32) {
	idx = -1
	dist = max(f32)
	for p, i in sp.points {
		c := gfx.GetRayCollisionSphere(ray, p.xform.translation, geo.handle_radius(p.width))
		if c.hit && c.distance < dist {
			dist = c.distance
			idx = i
		}
	}
	return
}

// first ribbon quad the ray hits. Returns the parent segment, the hit point,
// and the road frame there (for orienting an inserted point). ok=false on miss.
pick_ribbon :: proc(
	ribbon: []geo.Cross_Section,
	ray: gfx.Ray,
) -> (
	at: gfx.Vector3,
	frame: geo.Cross_Section,
	ok: bool,
) {
	best_dist := max(f32)
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		la, ra := geo.xsec_ends(ribbon[i])
		lb, rb := geo.xsec_ends(ribbon[i + 1])
		c := gfx.GetRayCollisionQuad(ray, la, ra, rb, lb)
		if c.hit && c.distance < best_dist {
			best_dist = c.distance
			at = c.point
			frame = ribbon[i]
			ok = true
		}
	}
	return
}

// --- Rendering --------------------------------------------------------------

draw_centreline :: proc(ribbon: []geo.Cross_Section) {
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		gfx.DrawLine3D(ribbon[i].pos, ribbon[i + 1].pos, {235, 200, 60, 255})
	}
}

// A start or finish line, drawn across the road where it sits.
draw_marker :: proc(sp: geo.Spline, m: geo.Road_Marker, col: gfx.Color) {
	at, on_road := geo.marker_resolve(sp, m)
	if !on_road {
		return
	}
	cs := geo.sample_edge(sp, at.from, at.to, clamp(at.t, 0, 1))
	l, r := geo.xsec_ends(cs)
	gfx.DrawLine3D(l, r, col)
	gfx.DrawLine3D(l, l + cs.up * 4, col)
	gfx.DrawLine3D(r, r + cs.up * 4, col)
}

// `weights` is the live road brush's hold on each point, or empty. A point it
// has caught is tinted toward the brush colour by how much of a move it takes,
// so the falloff is visible before the drag that uses it.
draw_handles :: proc(sp: geo.Spline, selected: int, weights: []f32 = nil) {
	for p, i in sp.points {
		// A weld is an edge with no ribbon handle of its own, so draw the join
		// itself or there is no way to see that a loop is closed.
		if p.weld >= 0 && p.weld < len(sp.points) {
			gfx.DrawLine3D(
				p.xform.translation,
				sp.points[p.weld].xform.translation,
				{255, 200, 90, 255},
			)
		}
		l, r := geo.point_ends(p)
		gfx.DrawLine3D(l, r, {200, 210, 225, 255}) // rung
		hcol := gfx.Color{120, 200, 255, 255}
		if i < len(weights) && weights[i] > 0 {
			hcol = color_mix(hcol, {255, 190, 80, 255}, weights[i])
		}
		if i == selected {
			hcol = {255, 120, 60, 255}
		}
		gfx.DrawSphere(p.xform.translation, geo.handle_radius(p.width), hcol)
		// forward + up ticks so orientation is legible
		fwd_tip := p.xform.translation + geo.point_forward(p) * (p.width * 0.5)
		up_tip := p.xform.translation + geo.point_up(p) * (p.width * 0.4)
		gfx.DrawLine3D(p.xform.translation, fwd_tip, {120, 255, 150, 255})
		gfx.DrawLine3D(p.xform.translation, up_tip, {150, 180, 255, 255})
	}
}

// Both edges of a ribbon, lifted clear of the surface it lies on. This is how
// one stage is drawn over the road it was cut from.
draw_ribbon_edges :: proc(ribbon: []geo.Cross_Section, col: gfx.Color) {
	lift := gfx.Vector3{0, 0.15, 0}
	for i in 0 ..< len(ribbon) - 1 {
		if ribbon[i + 1].break_before { continue }
		la, ra := geo.xsec_ends(ribbon[i])
		lb, rb := geo.xsec_ends(ribbon[i + 1])
		gfx.DrawLine3D(la + lift, lb + lift, col)
		gfx.DrawLine3D(ra + lift, rb + lift, col)
	}
}

// The venue itself, from the shared cache: what both window kinds draw first,
// and all the thumbnail draws. Takes the document rather than the window,
// because the thumbnail is rendered with no window in front of it.
draw_world :: proc(doc: ^Venue_Doc, wireframe: bool) {
	geo.gpu_mesh_draw(doc.terrain_mesh, doc.material, wireframe)
	geo.gpu_mesh_draw(doc.road, doc.material, wireframe)
	draw_centreline(doc.ribbon)
	geo.gpu_mesh_draw(doc.veg_mesh, doc.material, wireframe)
	geo.gpu_mesh_draw(doc.card_mesh, doc.material, wireframe)
	draw_props(doc, wireframe)
}

// The venue window's pass. What is left in the fixed-size overlay batch (see
// batch_has_room) is the grid, the centreline and the handles — the scenery went
// to its own meshes exactly because a dense stage overran it and took the handles
// down with it.
draw_venue_scene :: proc(
	ed: ^Editor, cam3d: gfx.Camera3D, node_pos: []gfx.Vector3, node_active: []bool, sel_node: int,
) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	draw_world(ed.doc, ed.wireframe)
	draw_handles(ed.doc.spline, selected_point(ed), ed.road_brush_weight[:])
	geo.draw_terrain_nodes(&ed.doc.terrain, node_pos, node_active, ed.terrain_brush_mask[:], sel_node)
	draw_floors(ed)
	if pi := selected_prop(ed); pi >= 0 {
		draw_prop_box(ed.doc, ed.doc.props[pi], {255, 140, 70, 255})
	}
	draw_prop_ghost(ed)
	gfx.EndMode3D()
}

// A stage window's pass: the venue road with this stage lit up on it. Only this
// stage's lines are drawn — the others belong to their own windows. The timing
// gates come off the compiled ribbon, which is the road the game will actually
// time, rather than off the whole graph.
draw_stage_scene :: proc(ed: ^Editor, cam3d: gfx.Camera3D) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	draw_world(ed.doc, ed.wireframe)
	if route := selected_route(ed); route != nil {
		draw_marker(ed.doc.spline, route.start, {110, 255, 140, 255})
		draw_marker(ed.doc.spline, route.finish, {255, 110, 110, 255})
		for pin in route.pins {
			draw_marker(ed.doc.spline, pin, {120, 190, 255, 255})
		}
	}
	if ed.stage.state == .Ready {
		draw_ribbon_edges(ed.stage.ribbon, {255, 235, 120, 255})
		draw_timing_markers(timing_markers(ed.stage.ribbon, ed.doc.timing))
	}
	if ed.previewing {
		gfx.DrawSphere(ed.preview_pos, 2.0, {255, 210, 80, 255})
	}
	gfx.EndMode3D()
}
