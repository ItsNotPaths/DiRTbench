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
	seg: int,
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
			seg = ribbon[i].seg
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

// Every stage's lines. The selected one is drawn bright and the rest dim, so a
// new stage is placed against the ones already using this road.
draw_route_markers :: proc(ed: ^Editor) {
	for route, i in ed.doc.routes {
		lit := i == ed.route_sel
		start := gfx.Color{110, 255, 140, 255} if lit else {60, 120, 80, 255}
		finish := gfx.Color{255, 110, 110, 255} if lit else {120, 60, 60, 255}
		draw_marker(ed.doc.spline, route.start, start)
		draw_marker(ed.doc.spline, route.finish, finish)
	}
}

// A start or finish line, drawn across the road where it sits.
draw_marker :: proc(sp: geo.Spline, m: geo.Road_Marker, col: gfx.Color) {
	if !geo.marker_valid(sp, m) {
		return
	}
	cs := geo.sample_edge(sp, m.from, m.to, clamp(m.t, 0, 1))
	l, r := geo.xsec_ends(cs)
	gfx.DrawLine3D(l, r, col)
	gfx.DrawLine3D(l, l + cs.up * 4, col)
	gfx.DrawLine3D(r, r + cs.up * 4, col)
}

draw_handles :: proc(sp: geo.Spline, selected: int) {
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
		hcol := i == selected ? gfx.Color{255, 120, 60, 255} : gfx.Color{120, 200, 255, 255}
		gfx.DrawSphere(p.xform.translation, geo.handle_radius(p.width), hcol)
		// forward + up ticks so orientation is legible
		fwd_tip := p.xform.translation + geo.point_forward(p) * (p.width * 0.5)
		up_tip := p.xform.translation + geo.point_up(p) * (p.width * 0.4)
		gfx.DrawLine3D(p.xform.translation, fwd_tip, {120, 255, 150, 255})
		gfx.DrawLine3D(p.xform.translation, up_tip, {150, 180, 255, 255})
	}
}

// The viewport pass. Handles first: they share one fixed-size batch with the
// scenery, which grows with the stage, and what does not fit is dropped (see
// batch_has_room). Losing the far trees is a nuisance; losing the handles makes
// the editor unusable.
draw_scene :: proc(
	ed: ^Editor, cam3d: gfx.Camera3D, node_pos: []gfx.Vector3, node_active: []bool, sel_node: int,
) {
	gfx.ClearBackground({26, 28, 34, 255})
	gfx.BeginMode3D(cam3d)
	gfx.DrawGrid(GRID_SLICES, GRID_SPACING)
	geo.gpu_mesh_draw(ed.doc.terrain_mesh, ed.doc.material, ed.wireframe)
	geo.gpu_mesh_draw(ed.doc.road, ed.doc.material, ed.wireframe)
	draw_centreline(ed.doc.ribbon)
	draw_timing_markers(timing_markers(ed.doc.ribbon,ed.doc.timing))
	draw_handles(ed.doc.spline, selected_point(ed))
	geo.draw_terrain_nodes(&ed.doc.terrain, node_pos, node_active, ed.terrain_brush_mask[:], sel_node)
	geo.veg_draw(ed.doc.veg_cache)
	draw_route_markers(ed)
	if ed.previewing {
		gfx.DrawSphere(ed.preview_pos, 2.0, {255, 210, 80, 255})
	}
	gfx.EndMode3D()
}
