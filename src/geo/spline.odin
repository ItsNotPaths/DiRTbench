package geo

// Road spline model + geometry.
//
// A spline is an ordered chain of *oriented control points* (parent -> child ==
// array order). Each control point carries a full graphics Transform: its
// translation is the road centre (Y is free, so roads can climb/dip), and its
// rotation is the road frame at that point — local +Z is travel direction,
// +X is "right" across the road, +Y is the road-surface normal. Rotating a
// control point therefore steers the road (yaw), tilts it (pitch, for slopes)
// and banks it (roll, for swoops).
//
// The visible road is a smooth cubic-Hermite curve threaded through the points:
// it leaves and enters each point along that point's forward direction, so the
// per-point rotation shapes the curve directly. The curve is sampled into a
// ribbon of cross-sections for rendering and picking.

import "core:fmt"
import "core:math"
import "core:slice"
import "../gfx"

DEFAULT_WIDTH :: 8.0    // metres — plausible rally road width
SAMPLES_PER_SEG :: 14   // curve subdivisions between two control points
HERMITE_TENSION :: 1.0  // tangent scale; higher == wider swoops

DEFAULT_CLIFF_SPAN :: 48.0  // metres of road a cliff covers, end to end
DEFAULT_CLIFF_TAPER :: 16.0 // metres of that span spent rising and falling
DEFAULT_CLIFF_ANGLE :: 6.0  // degrees off vertical, leaning away from the road

Point :: struct {
	// Parent in the venue road graph. -1 is a root. Nodes are topologically
	// ordered, so every non-root parent is lower than its child. A second child
	// is a branch; no separate edge or junction object is needed.
	parent:      int,
	// A second edge out of this point, closing a loop. -1 for none.
	//
	// The parent tree above stays a tree: acyclic, every parent lower than its
	// child. A weld is emitted by build_ribbon and **never traversed onward**,
	// so nothing ever walks from one weld to another. That is what lets the
	// road close a loop while every walk over the graph still terminates, with
	// no cycle detection anywhere. Unlike a parent, a weld may point forward.
	weld:        int,
	xform:       gfx.Transform, // translation = centre, rotation = road frame
	width:       f32,          // road width, metres

	// Cliffs rise from the road's edges, centred on this control point.
	//
	//   height  |    ______________              <- cliff_l / cliff_r
	//           |   /              \
	//           |  /                \
	//           |_/__________________\____  road
	//            <-> <------------> <->
	//           taper    plateau   taper
	//            <-------- span -------->
	//
	// `span` is the *total* length of road the cliff covers, tapers included,
	// so the plateau is span - 2*taper. A zero height or a zero span means no
	// cliff on that side. The taper and the angle are shared by both sides.
	cliff_l:     f32, // height, metres
	cliff_r:     f32,
	span_l:      f32, // total length along the road, metres
	span_r:      f32,
	cliff_taper: f32,
	// Degrees off vertical. Positive leans the face away from the road;
	// negative leans it back over the road, overhanging it.
	cliff_angle: f32,

	// Per-node roughness offset, added to the global roughness slider and then
	// clamped to [0,1] along the road (lerped between control points, like
	// `cliff_angle`). Lets one stretch read rougher or smoother than the stage
	// baseline. The absolute displacement it can produce is still hard-capped —
	// see ROUGH_MAX_M in mesh.odin — because the tightest target is the Trackmania
	// Stadium car. Signed: negative smooths a stretch below the global baseline.
	roughness:   f32,
}

Spline :: struct {
	points: [dynamic]Point,
}

first_child :: proc(sp: Spline, idx: int) -> int {
	for p, i in sp.points { if p.parent == idx { return i } }
	return -1
}

is_branch :: proc(sp: Spline, idx: int) -> bool {
	if idx < 0 || idx >= len(sp.points) { return false }
	parent := sp.points[idx].parent
	return parent >= 0 && first_child(sp, parent) != idx
}

is_linear :: proc(sp: Spline) -> bool {
	// A weld is an edge the linear sampler cannot express, so any weld makes the
	// graph sampler the only correct one.
	for p, i in sp.points { if p.parent != i - 1 || p.weld >= 0 { return false } }
	return true
}

has_weld :: proc(sp: Spline, idx: int) -> bool {
	return idx >= 0 && idx < len(sp.points) && sp.points[idx].weld >= 0
}

// Close a loop: a second edge out of `from` into `to`. Refused when the two are
// already joined, so a weld never duplicates a parent edge.
weld_points :: proc(sp: ^Spline, from, to: int) -> bool {
	n := len(sp.points)
	if from < 0 || from >= n || to < 0 || to >= n || from == to { return false }
	if sp.points[from].parent == to || sp.points[to].parent == from { return false }
	if sp.points[to].weld == from { return false }
	sp.points[from].weld = to
	return true
}

unweld_point :: proc(sp: ^Spline, idx: int) {
	if idx >= 0 && idx < len(sp.points) { sp.points[idx].weld = -1 }
}

// Every index the graph stores moves when the array does. One place, so an edit
// cannot shift parents and quietly forget welds.
shift_links :: proc(sp: ^Spline, at, skip: int) {
	for &p, i in sp.points {
		if i == skip { continue }
		if p.parent >= at { p.parent += 1 }
		if p.weld >= at { p.weld += 1 }
	}
}

// A sampled slice across the road: everything needed to lay a ribbon rung and
// to pick against it. `seg` is the index of the control point the sample grew
// from (the parent of the segment it lies on).
Cross_Section :: struct {
	// True when this starts another graph edge rather than continuing from the
	// previous sampled section. Consumers must not bridge across this boundary.
	break_before: bool,
	pos:     gfx.Vector3,
	right:   gfx.Vector3, // across the road, unit
	up:      gfx.Vector3, // surface normal, unit
	fwd:     gfx.Vector3, // travel direction, unit
	width:   f32,
	seg:     int,
	// The graph edge this sample lies on, and where along it. `seg` alone
	// cannot say: a weld edge and the parent edge into the same node share a
	// child index. Filled by build_ribbon, which is the only place that knows
	// which edge it is walking.
	e_from:  int,
	e_to:    int,
	t:       f32,
	// Cliff height at this slice, resolved from every nearby control point's
	// tapered contribution. Filled by build_ribbon, not by sample_at.
	cliff_l: f32,
	cliff_r: f32,
	// Cliff face angle, degrees off vertical. Unlike the heights this simply
	// interpolates along the segment, the way width does.
	cliff_angle: f32,
	// Per-node roughness offset at this slice, lerped between the two control
	// points (like `cliff_angle`). Combined with the global slider and clamped
	// where the road surface is displaced (build_road_surface).
	roughness:   f32,
}

// --- frame helpers ----------------------------------------------------------

point_forward :: proc(p: Point) -> gfx.Vector3 {
	return gfx.Vector3Normalize(gfx.Vector3RotateByQuaternion({0, 0, 1}, p.xform.rotation))
}
point_right :: proc(p: Point) -> gfx.Vector3 {
	return gfx.Vector3Normalize(gfx.Vector3RotateByQuaternion({1, 0, 0}, p.xform.rotation))
}
point_up :: proc(p: Point) -> gfx.Vector3 {
	return gfx.Vector3Normalize(gfx.Vector3RotateByQuaternion({0, 1, 0}, p.xform.rotation))
}

// the two rung endpoints of a control point (left, right), honouring bank
point_ends :: proc(p: Point) -> (left: gfx.Vector3, right: gfx.Vector3) {
	r := point_right(p)
	half := r * (p.width * 0.5)
	return p.xform.translation + half, p.xform.translation - half
}

// a quaternion whose local +Z == fwd and +Y == up (orthonormalised)
quat_from_frame :: proc(fwd, up: gfx.Vector3) -> gfx.Quaternion {
	f := gfx.Vector3Normalize(fwd)
	r := gfx.Vector3Normalize(gfx.Vector3CrossProduct(up, f))
	u := gfx.Vector3CrossProduct(f, r)
	// column-major basis (right, up, forward) as a rotation matrix
	m := gfx.Matrix{
		r.x, u.x, f.x, 0,
		r.y, u.y, f.y, 0,
		r.z, u.z, f.z, 0,
		0,   0,   0,   1,
	}
	return gfx.QuaternionFromMatrix(m)
}

// level heading (yaw about +Y) pointing from `from` toward `to`
heading_quat :: proc(from, to: gfx.Vector3) -> gfx.Quaternion {
	d := to - from
	yaw := math.atan2(d.x, d.z)
	return gfx.QuaternionFromAxisAngle({0, 1, 0}, yaw)
}

make_point :: proc(
	pos: gfx.Vector3,
	rot: gfx.Quaternion,
	width: f32,
	cliff_l: f32 = 0,
	cliff_r: f32 = 0,
	span_l: f32 = DEFAULT_CLIFF_SPAN,
	span_r: f32 = DEFAULT_CLIFF_SPAN,
	cliff_taper: f32 = DEFAULT_CLIFF_TAPER,
	cliff_angle: f32 = DEFAULT_CLIFF_ANGLE,
	roughness:   f32 = 0,
	parent:      int = -1,
) -> Point {
	return Point {
		parent      = parent,
		weld        = -1,
		xform       = {translation = pos, rotation = rot, scale = {1, 1, 1}},
		width       = width,
		cliff_l     = cliff_l,
		cliff_r     = cliff_r,
		span_l      = span_l,
		span_r      = span_r,
		cliff_taper = cliff_taper,
		cliff_angle = cliff_angle,
		roughness   = roughness,
	}
}

// --- cubic Hermite ----------------------------------------------------------

// position on the Hermite segment p0->p1 at t in [0,1]
hermite_pos :: proc(p0, p1: Point, t: f32) -> gfx.Vector3 {
	P0 := p0.xform.translation
	P1 := p1.xform.translation
	L := gfx.Vector3Length(P1 - P0) * HERMITE_TENSION
	T0 := point_forward(p0) * L
	T1 := point_forward(p1) * L
	t2 := t * t
	t3 := t2 * t
	h00 := 2 * t3 - 3 * t2 + 1
	h10 := t3 - 2 * t2 + t
	h01 := -2 * t3 + 3 * t2
	h11 := t3 - t2
	return P0 * h00 + T0 * h10 + P1 * h01 + T1 * h11
}

// tangent (unnormalised travel direction) on the segment at t
hermite_tangent :: proc(p0, p1: Point, t: f32) -> gfx.Vector3 {
	P0 := p0.xform.translation
	P1 := p1.xform.translation
	L := gfx.Vector3Length(P1 - P0) * HERMITE_TENSION
	T0 := point_forward(p0) * L
	T1 := point_forward(p1) * L
	t2 := t * t
	d00 := 6 * t2 - 6 * t
	d10 := 3 * t2 - 4 * t + 1
	d01 := -6 * t2 + 6 * t
	d11 := 3 * t2 - 2 * t
	return P0 * d00 + T0 * d10 + P1 * d01 + T1 * d11
}

// frame at parameter t on segment (seg, seg+1): tangent-following, banking and
// width interpolated from the two control points.
sample_at :: proc(sp: Spline, seg: int, t: f32) -> Cross_Section {
	p0 := sp.points[seg]
	p1 := sp.points[seg + 1]
	pos := hermite_pos(p0, p1, t)
	// Test the raw tangent, not the normalised one: a near-zero tangent
	// normalises to a unit vector pointing anywhere.
	tangent := hermite_tangent(p0, p1, t)
	fwd := gfx.Vector3Normalize(tangent)
	if gfx.Vector3Length(tangent) < 1e-5 {
		fwd = point_forward(p0)
	}
	// interpolate the surface normal (banking / slope) via the control rotations
	q := gfx.QuaternionSlerp(p0.xform.rotation, p1.xform.rotation, t)
	up_ref := gfx.Vector3Normalize(gfx.Vector3RotateByQuaternion({0, 1, 0}, q))
	right := gfx.Vector3Normalize(gfx.Vector3CrossProduct(up_ref, fwd))
	up := gfx.Vector3Normalize(gfx.Vector3CrossProduct(fwd, right))
	width := p0.width + (p1.width - p0.width) * t
	angle := p0.cliff_angle + (p1.cliff_angle - p0.cliff_angle) * t
	rough := p0.roughness + (p1.roughness - p0.roughness) * t
	return Cross_Section {
		pos = pos, right = right, up = up, fwd = fwd,
		width = width, seg = seg, cliff_angle = angle, roughness = rough,
	}
}

sample_edge :: proc(sp: Spline, parent, child: int, t: f32) -> Cross_Section {
	p0, p1 := sp.points[parent], sp.points[child]
	pos := hermite_pos(p0, p1, t)
	tangent := hermite_tangent(p0, p1, t)
	fwd := gfx.Vector3Normalize(tangent)
	if gfx.Vector3Length(tangent) < 1e-5 { fwd = point_forward(p0) }
	q := gfx.QuaternionSlerp(p0.xform.rotation, p1.xform.rotation, t)
	up_ref := gfx.Vector3Normalize(gfx.Vector3RotateByQuaternion({0, 1, 0}, q))
	right := gfx.Vector3Normalize(gfx.Vector3CrossProduct(up_ref, fwd))
	up := gfx.Vector3Normalize(gfx.Vector3CrossProduct(fwd, right))
	return Cross_Section {
		pos = pos, right = right, up = up, fwd = fwd,
		width = p0.width + (p1.width-p0.width)*t,
		// `seg` identifies the child for graph-aware insertion.
		seg = child,
		cliff_l = p0.cliff_l+(p1.cliff_l-p0.cliff_l)*t,
		cliff_r = p0.cliff_r+(p1.cliff_r-p0.cliff_r)*t,
		cliff_angle = p0.cliff_angle+(p1.cliff_angle-p0.cliff_angle)*t,
		roughness = p0.roughness+(p1.roughness-p0.roughness)*t,
	}
}

// Sample the whole spline into a contiguous ribbon of cross-sections.
// `samples_per_seg` is the global topo resolution. Returns a freshly-allocated
// slice (caller deletes) or nil when there is nothing to draw.
build_ribbon :: proc(
	sp: Spline,
	samples_per_seg := SAMPLES_PER_SEG,
	allocator := context.temp_allocator,
) -> []Cross_Section {
	nseg := len(sp.points) - 1
	if nseg < 1 {
		return nil
	}
	spp := max(samples_per_seg, 1)
	out := make([dynamic]Cross_Section, allocator)
	if !is_linear(sp) {
		for child in 0 ..< len(sp.points) {
			parent := sp.points[child].parent
			if parent < 0 { continue }
			for s in 0 ..= spp {
				t := f32(s)/f32(spp)
				cs := sample_edge(sp, parent, child, t)
				cs.break_before = s == 0
				cs.e_from, cs.e_to, cs.t = parent, child, t
				append(&out, cs)
			}
		}
		// Weld edges last, sampled exactly like a parent edge. They are emitted
		// here and nowhere else; no traversal follows one, so a closed loop
		// costs no cycle detection.
		for p, i in sp.points {
			if p.weld < 0 || p.weld >= len(sp.points) || p.weld == i { continue }
			for s in 0 ..= spp {
				t := f32(s)/f32(spp)
				cs := sample_edge(sp, i, p.weld, t)
				cs.break_before = s == 0
				cs.e_from, cs.e_to, cs.t = i, p.weld, t
				append(&out, cs)
			}
		}
		// NOTE: no resolve_cliffs here. The graph sampler lerps cliff heights
		// between the two endpoints, where the linear one leaves them at zero
		// and resolve_cliffs fills the tapered envelope. Two cliff models, and
		// resolve_cliffs maps control point i to sample i*spp, which the graph
		// layout does not satisfy. Unifying them is its own job.
		return out[:]
	}
	for seg in 0 ..< nseg {
		// each segment contributes t in [0, 1); the final endpoint is added once
		for s in 0 ..< spp {
			t := f32(s) / f32(spp)
			cs := sample_at(sp, seg, t)
			cs.e_from, cs.e_to, cs.t = seg, seg + 1, t
			append(&out, cs)
		}
	}
	last := sample_at(sp, nseg - 1, 1.0)
	last.e_from, last.e_to, last.t = nseg - 1, nseg, 1
	append(&out, last)
	resolve_cliffs(sp, out[:], spp)
	return out[:]
}

// --- ribbon measures --------------------------------------------------------

// Arc length along the sampled centreline, sample by sample, starting at 0.
//
// Everything that measures road in metres reads this: cliff spans, and the
// terrain lattice's along-road stations. Spline parameter would do neither, as
// it stretches with segment length.
ribbon_arc :: proc(ribbon: []Cross_Section, allocator := context.temp_allocator) -> []f32 {
	arc := make([]f32, len(ribbon), allocator)
	for i in 1 ..< len(ribbon) {
		arc[i] = arc[i - 1] + gfx.Vector3Distance(ribbon[i - 1].pos, ribbon[i].pos)
	}
	return arc
}

// **Signed** curvature at each sample, in 1/metres: how fast the travel
// direction turns per metre of road. Central-differenced, and the two end
// samples copy their neighbour rather than one-siding it.
//
// The sign says which way: positive turns toward `right`, i.e. toward side 0.
// That matters because 1/|k| is the local radius of curvature, and a skirt swept
// outward crosses its own columns only on the **inside** of the turn — so the
// clamp applies to one side and not the other. Magnitude alone cannot say which.
//
// `arc` must be the table ribbon_arc returned for the same ribbon.
ribbon_curvature :: proc(
	ribbon: []Cross_Section,
	arc: []f32,
	allocator := context.temp_allocator,
) -> []f32 {
	n := len(ribbon)
	k := make([]f32, n, allocator)
	if n < 3 {
		return k
	}
	for i in 1 ..< n - 1 {
		ds := arc[i + 1] - arc[i - 1]
		if ds < 1e-6 {
			continue
		}
		dfwd := ribbon[i + 1].fwd - ribbon[i - 1].fwd
		k[i] = gfx.Vector3DotProduct(dfwd, ribbon[i].right) / ds
	}
	k[0] = k[1]
	k[n - 1] = k[n - 2]
	return k
}

// The cliff profile along the road: 1 across the plateau, smoothly down to 0
// at the ends of `span`. `d` is metres of road from the control point.
//
// The taper is clamped to half the span, so a span narrower than two tapers
// degenerates into a plateau-less bump rather than inverting.
cliff_envelope :: proc(d, span, taper: f32) -> f32 {
	if span <= 0 {
		return 0
	}
	half := span * 0.5
	t := min(taper, half)
	a := abs(d)
	if a >= half {
		return 0
	}
	plateau := half - t
	if a <= plateau || t <= 0 {
		return 1
	}
	return math.smoothstep(f32(0), f32(1), 1 - (a - plateau) / t)
}

// Resolve each slice's cliff height from every control point whose span reaches
// it.
//
// A slice's height is *not* a lerp between its two neighbouring points: a span
// can cover many slices and several spans can overlap one. Overlaps take the
// maximum, which unions adjacent cliffs into one ridge instead of stacking them
// into a spike.
//
// Cost is O(points * span-in-samples), not O(points * samples): each point only
// writes the window its own span covers.
resolve_cliffs :: proc(sp: Spline, ribbon: []Cross_Section, spp: int) {
	n := len(ribbon)
	if n < 2 {
		return
	}
	arc := ribbon_arc(ribbon)

	apply :: proc(cs: ^Cross_Section, p: Point, d: f32) {
		cs.cliff_l = max(cs.cliff_l, p.cliff_l * cliff_envelope(d, p.span_l, p.cliff_taper))
		cs.cliff_r = max(cs.cliff_r, p.cliff_r * cliff_envelope(d, p.span_r, p.cliff_taper))
	}

	for p, i in sp.points {
		if (p.cliff_l <= 0 || p.span_l <= 0) && (p.cliff_r <= 0 || p.span_r <= 0) {
			continue
		}
		// Control point i lands on sample i*spp; the last point is the endpoint
		// appended after the sampling loop.
		idx := i == len(sp.points) - 1 ? n - 1 : i * spp
		// The wider of the two sides bounds the window we have to touch.
		reach := max(p.span_l, p.span_r) * 0.5
		s0 := arc[idx]

		for j := idx; j < n && arc[j] - s0 <= reach; j += 1 {
			apply(&ribbon[j], p, arc[j] - s0)
		}
		for j := idx - 1; j >= 0 && s0 - arc[j] <= reach; j -= 1 {
			apply(&ribbon[j], p, arc[j] - s0)
		}
	}
}

// rung endpoints of a cross-section (left, right)
xsec_ends :: proc(cs: Cross_Section) -> (left: gfx.Vector3, right: gfx.Vector3) {
	half := cs.right * (cs.width * 0.5)
	return cs.pos + half, cs.pos - half
}

// picking radius of a control-point handle, scaled to road width
handle_radius :: proc(width: f32) -> f32 {
	return max(1.0, width * 0.15)
}

// --- edits ------------------------------------------------------------------

// insert a control point on segment (seg, seg+1) at world point `at`, framed by
// the interpolated road frame there. Returns the new point's index.
insert_point :: proc(sp: ^Spline, seg: int, at: gfx.Vector3, frame: Cross_Section) -> int {
	if !is_linear(sp^) {
		child := seg
		if child <= 0 || child >= len(sp.points) { return -1 }
		parent := sp.points[child].parent
		src := sp.points[parent]
		np := make_point(
			at, quat_from_frame(frame.fwd, frame.up), frame.width,
			frame.cliff_l, frame.cliff_r, src.span_l, src.span_r,
			src.cliff_taper, frame.cliff_angle, frame.roughness, parent,
		)
		inject_at(&sp.points, child, np)
		shift_links(sp, child, child)
		sp.points[child + 1].parent = child
		return child
	}
	rot := quat_from_frame(frame.fwd, frame.up)
	// Adopt the cliff height already resolved at this slice, so inserting a
	// point into a cliffed stretch does not punch a notch out of the cliff.
	src := sp.points[seg]
	np := make_point(
		at, rot, frame.width,
		frame.cliff_l, frame.cliff_r,
		src.span_l, src.span_r, src.cliff_taper, frame.cliff_angle,
		// Inserting into a rough stretch keeps its roughness; the frame already
		// carries the lerped value at this slice.
		frame.roughness,
		seg,
	)
	inject_at(&sp.points, seg + 1, np)
	// The old child now follows the inserted node. Shift every index affected
	// by the insertion before repairing that one edge.
	shift_links(sp, seg + 1, seg + 1)
	if seg + 2 < len(sp.points) && sp.points[seg + 2].parent == seg {
		sp.points[seg + 2].parent = seg + 1
	}
	return seg + 1
}

// Extrude the point at `idx`: duplicate it and return the index of the copy, which
// the caller drags away. The copy always goes on the *outward* side so the spline
// grows at its ends rather than gaining a point mid-chain:
//   - head (idx 0)  -> copy becomes the new head, extending backwards
//   - otherwise     -> copy becomes idx's child, so extruding the tail appends
extrude_point :: proc(sp: ^Spline, idx: int) -> int {
	// Like Writ's graph editor, appending another child to a node that already
	// has one creates a branch. Append it to preserve topological order.
	for p in sp.points {
		if p.parent == idx {
			copy := sp.points[idx]
			copy.parent = idx
			// A fresh node does not inherit someone else's loop closure.
			copy.weld = -1
			append(&sp.points, copy)
			return len(sp.points) - 1
		}
	}
	if idx == 0 && len(sp.points) > 1 {
		inject_at(&sp.points, 0, sp.points[0])
		for &p, i in sp.points {
			if i > 1 {
				if p.parent >= 0 { p.parent += 1 }
				if p.weld >= 0 { p.weld += 1 }
			}
		}
		sp.points[0].parent = -1
		sp.points[0].weld = -1
		sp.points[1].parent = 0
		if sp.points[1].weld >= 0 { sp.points[1].weld += 1 }
		return 0
	}
	inject_at(&sp.points, idx + 1, sp.points[idx])
	shift_links(sp, idx + 1, idx + 1)
	sp.points[idx + 1].parent = idx
	sp.points[idx + 1].weld = -1
	if idx + 2 < len(sp.points) && sp.points[idx + 2].parent == idx {
		sp.points[idx + 2].parent = idx + 1
	}
	return idx + 1
}

// Remove a node while keeping its children connected to its parent, then fix
// indices after compaction. This is the graph equivalent of ordered_remove.
remove_point :: proc(sp: ^Spline, idx: int) {
	if idx < 0 || idx >= len(sp.points) || len(sp.points) <= 1 { return }
	parent := sp.points[idx].parent
	for &p in sp.points {
		if p.parent == idx { p.parent = parent }
		// A weld into the removed node has no parent to fall back on: the loop
		// it closed is gone, so drop the edge rather than aim it somewhere else.
		if p.weld == idx { p.weld = -1 }
	}
	ordered_remove(&sp.points, idx)
	for &p in sp.points {
		if p.parent > idx { p.parent -= 1 }
		if p.weld > idx { p.weld -= 1 }
	}
}

// Reverse the driving direction: the last control point becomes the first. The
// physical road is unchanged — only which way it is travelled — so each frame's
// forward is negated while its surface normal (up) is kept, and the per-side
// cliffs swap (the old left is the new right). Everything downstream keys off
// travel direction: the ribbon, the pace notes and their left/right, and the
// preview camera all flip together. Use it on a stage authored end-first.
reverse_spline :: proc(sp: ^Spline) {
	n := len(sp.points)
	for i in 0 ..< n / 2 {
		sp.points[i], sp.points[n - 1 - i] = sp.points[n - 1 - i], sp.points[i]
	}
	for &p, i in sp.points {
		// reverse_spline is only defined for a chain. Array order is its new
		// travel order, so rebuild the graph edges to match that order.
		p.parent = i - 1
		p.weld = -1
		f := point_forward(p)
		u := point_up(p)
		// Flip the frame to face the new travel direction, normal unchanged.
		p.xform.rotation = quat_from_frame(-f, u)
		// The physical sides swap when you turn around.
		p.cliff_l, p.cliff_r = p.cliff_r, p.cliff_l
		p.span_l, p.span_r = p.span_r, p.span_l
	}
}

// append a control point at world point `at`, level, aimed there from the last
append_point :: proc(sp: ^Spline, at: gfx.Vector3) -> int {
	rot := gfx.Quaternion(1)
	width := f32(DEFAULT_WIDTH)
	cliff_l, cliff_r: f32
	span_l := f32(DEFAULT_CLIFF_SPAN)
	span_r := f32(DEFAULT_CLIFF_SPAN)
	taper := f32(DEFAULT_CLIFF_TAPER)
	angle := f32(DEFAULT_CLIFF_ANGLE)
	rough: f32
	if n := len(sp.points); n > 0 {
		last := sp.points[n - 1]
		rot = heading_quat(last.xform.translation, at)
		width = last.width
		// Carry the cliffs forward: extending a cliffed road should keep its cliffs.
		cliff_l, cliff_r = last.cliff_l, last.cliff_r
		span_l, span_r, taper = last.span_l, last.span_r, last.cliff_taper
		angle = last.cliff_angle
		rough = last.roughness
	}
	parent := len(sp.points) - 1
	append(&sp.points, make_point(at, rot, width, cliff_l, cliff_r, span_l, span_r, taper, angle, rough, parent))
	return len(sp.points) - 1
}

// --- stages -----------------------------------------------------------------

// Where a start or finish line sits: a point along one graph edge. Naming the
// edge by both ends rather than by its child is what lets a marker sit on a
// weld, which is how a loop stage finishes where it began.
Road_Marker :: struct {
	from: int,
	to:   int,
	t:    f32,
}

// Keeps a marker clear of the node at either end of its edge. Landing exactly
// on one would put two control points in the same place, and a zero-length
// segment has no tangent to follow.
MARKER_MARGIN :: 0.02

marker_valid :: proc(sp: Spline, m: Road_Marker) -> bool {
	n := len(sp.points)
	if m.from < 0 || m.from >= n || m.to < 0 || m.to >= n || m.from == m.to {
		return false
	}
	return sp.points[m.to].parent == m.from || sp.points[m.from].weld == m.to
}

// The control point a marker stands for, framed by the road it sits on.
marker_point :: proc(sp: Spline, m: Road_Marker) -> Point {
	t := clamp(m.t, MARKER_MARGIN, 1 - MARKER_MARGIN)
	cs := sample_edge(sp, m.from, m.to, t)
	src := sp.points[m.from]
	return make_point(
		cs.pos, quat_from_frame(cs.fwd, cs.up), cs.width,
		cs.cliff_l, cs.cliff_r, src.span_l, src.span_r,
		src.cliff_taper, cs.cliff_angle, cs.roughness, -1,
	)
}

// The road between two markers, as a plain chain the exporter can take.
//
// The nodes in between come from the parent chain, walked upward from the node
// the finish edge leaves to the node the start edge enters. That walk is over
// the tree only, so it terminates even when the road loops: a weld can be the
// finish edge but never a step in the walk.
compile_stage :: proc(
	sp: Spline,
	start, finish: Road_Marker,
	allocator := context.allocator,
) -> (
	out: Spline,
	msg: string,
	ok: bool,
) {
	if !marker_valid(sp, start) { return out, "the start line is not on a road", false }
	if !marker_valid(sp, finish) { return out, "the finish line is not on a road", false }

	between := make([dynamic]int, context.temp_allocator)
	if start.from == finish.from && start.to == finish.to {
		if start.t >= finish.t {
			return out, "the finish comes before the start on the same stretch of road", false
		}
	} else {
		node := finish.from
		for node >= 0 && node != start.to {
			append(&between, node)
			node = sp.points[node].parent
		}
		if node != start.to {
			return out, "no road runs from the start line to the finish line", false
		}
		append(&between, start.to)
		slice.reverse(between[:])
	}

	out.points = make([dynamic]Point, allocator)
	append(&out.points, marker_point(sp, start))
	for idx in between { append(&out.points, sp.points[idx]) }
	append(&out.points, marker_point(sp, finish))
	// A compiled stage is a chain, never a graph. Nothing downstream of here
	// branches, and the exporter reads array order as travel order.
	for &p, i in out.points {
		p.parent = i - 1
		p.weld = -1
	}
	return out, fmt.tprintf("%d control points", len(out.points)), true
}
