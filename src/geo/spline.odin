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
import "../gfx"

DEFAULT_WIDTH :: 8.0    // metres — plausible rally road width
SAMPLES_PER_SEG :: 14   // curve subdivisions between two control points
HERMITE_TENSION :: 1.0  // tangent scale; higher == wider swoops

DEFAULT_CLIFF_SPAN :: 48.0  // metres of road a cliff covers, end to end
DEFAULT_CLIFF_TAPER :: 16.0 // metres of that span spent rising and falling
DEFAULT_CLIFF_ANGLE :: 6.0  // degrees off vertical, leaning away from the road

Point :: struct {
	// Stable identity, handed out by spline_push/spline_inject and never
	// reused. Array position moves under every insert, remove and extrude;
	// this does not, which is what lets a marker held outside the spline go on
	// naming the same stretch of road. See Road_Marker.
	id:          int,
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
	points:  [dynamic]Point,
	// Hands out point ids. Only ever grows, never on a remove: an id is never
	// reused, so a marker naming a point that is gone stays unresolvable
	// rather than quietly landing on some later point.
	next_id: int,
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

// The two ways a point enters the array, and the only two. Both stamp a fresh
// id, so no edit can add a point without one — the same reason shift_links is
// a single proc. The loader is the one exception: it restores the ids its file
// carries and sets next_id itself.
spline_push :: proc(sp: ^Spline, p: Point) -> int {
	append(&sp.points, stamped(sp, p))
	return len(sp.points) - 1
}

spline_inject :: proc(sp: ^Spline, at: int, p: Point) -> int {
	inject_at(&sp.points, at, stamped(sp, p))
	return at
}

@(private = "file")
stamped :: proc(sp: ^Spline, p: Point) -> Point {
	out := p
	out.id = sp.next_id
	sp.next_id += 1
	return out
}

// Where the point with this id sits right now, or -1. Linear: a road is a few
// hundred control points, and this runs a handful of times per compile, which
// is itself cached.
point_index :: proc(sp: Spline, id: int) -> int {
	for p, i in sp.points {
		if p.id == id {
			return i
		}
	}
	return -1
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
// to pick against it.
Cross_Section :: struct {
	// True when this starts another graph edge rather than continuing from the
	// previous sampled section. Consumers must not bridge across this boundary.
	break_before: bool,
	pos:     gfx.Vector3,
	right:   gfx.Vector3, // across the road, unit
	up:      gfx.Vector3, // surface normal, unit
	fwd:     gfx.Vector3, // travel direction, unit
	width:   f32,
	// The graph edge this sample lies on, and where along it. A child index
	// alone cannot say: a weld edge and the parent edge into the same node
	// share one. Everything that puts a point on the road goes by this.
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
		width = width, cliff_angle = angle, roughness = rough,
		e_from = seg, e_to = seg + 1, t = t,
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
		e_from = parent, e_to = child, t = t,
		cliff_angle = p0.cliff_angle+(p1.cliff_angle-p0.cliff_angle)*t,
		roughness = p0.roughness+(p1.roughness-p0.roughness)*t,
	}
}

// Sample the whole spline into a contiguous ribbon of cross-sections.
// `samples_per_seg` defaults to SAMPLES_PER_SEG; only tests pass anything else.
// Returns a freshly-allocated
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
				append(&out, cs)
			}
		}
		resolve_cliffs(sp, out[:])
		return out[:]
	}
	for seg in 0 ..< nseg {
		// each segment contributes t in [0, 1); the final endpoint is added once
		for s in 0 ..< spp {
			t := f32(s) / f32(spp)
			append(&out, sample_at(sp, seg, t))
		}
	}
	append(&out, sample_at(sp, nseg - 1, 1.0))
	resolve_cliffs(sp, out[:])
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
// it, measured along the road rather than along the array.
//
// Distance is the road walk the stage search uses, so a span runs past a fork
// into both of its branches and over a weld into the road it closes. Nothing
// here reads sample order, which is why one procedure serves both a chain and a
// branched venue: on a branched one the ribbon is a run per edge, and arc
// length across those runs means nothing.
//
// A slice's height is *not* a lerp between its two neighbouring points: a span
// can cover many slices and several spans can overlap one. Overlaps take the
// maximum, which unions adjacent cliffs into one ridge instead of stacking them
// into a spike.
//
// Only points that carry a cliff are walked, and a walk settles only what its
// own span reaches, so a venue pays for the cliffs it has rather than for its
// length.
resolve_cliffs :: proc(sp: Spline, ribbon: []Cross_Section) {
	for p, i in sp.points {
		if (p.cliff_l <= 0 || p.span_l <= 0) && (p.cliff_r <= 0 || p.span_r <= 0) {
			continue
		}
		// The wider of the two sides bounds the road this point can touch.
		reach := max(p.span_l, p.span_r) * 0.5
		dist := graph_reach(sp, i, reach)
		// One length per edge, not per sample: a ribbon runs an edge at a time.
		last_from, last_to := -1, -1
		edge_len: f32
		for &cs in ribbon {
			da, db := dist[cs.e_from], dist[cs.e_to]
			if da >= reach && db >= reach {
				continue // the whole edge is out of reach, and so is this slice
			}
			if cs.e_from != last_from || cs.e_to != last_to {
				last_from, last_to = cs.e_from, cs.e_to
				edge_len = edge_length(sp, last_from, last_to)
			}
			// `t` stands in for arc fraction across the edge. Control points sit
			// metres apart, so the two differ by well under the taper.
			d := min(da + cs.t * edge_len, db + (1 - cs.t) * edge_len)
			cs.cliff_l = max(cs.cliff_l, p.cliff_l * cliff_envelope(d, p.span_l, p.cliff_taper))
			cs.cliff_r = max(cs.cliff_r, p.cliff_r * cliff_envelope(d, p.span_r, p.cliff_taper))
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

// Insert a control point where the road was clicked. `frame` names the edge it
// was clicked on and where along it; nothing else can say, because a weld edge
// and the parent edge into the same node share a child index.
//
// On a parent edge the new point takes the child's place in the array and the
// child moves along, which keeps every parent below its child. A weld edge has
// no child to get in front of: the point goes on the end and takes the weld
// over, so `from` -> new is a parent edge and new -> `to` is the weld that
// still closes the loop.
insert_point :: proc(
	sp: ^Spline, at: gfx.Vector3, frame: Cross_Section,
) -> (
	idx: int, split: Edge_Split,
) {
	split.mid = -1
	from, to := frame.e_from, frame.e_to
	n := len(sp.points)
	if from < 0 || from >= n || to < 0 || to >= n || from == to {
		return -1, split
	}
	// Fill around `mid`, never over it: a whole-struct literal here would put
	// the "nothing was cut" -1 back to 0, which is a live point id.
	split.a, split.b, split.t = sp.points[from].id, sp.points[to].id, frame.t
	src := sp.points[from]
	np := make_point(
		at, quat_from_frame(frame.fwd, frame.up), frame.width,
		// Adopt the cliff already resolved at this slice, so inserting into a
		// cliffed stretch does not punch a notch out of the cliff. The frame
		// carries the lerped roughness for the same reason.
		frame.cliff_l, frame.cliff_r,
		src.span_l, src.span_r, src.cliff_taper, frame.cliff_angle,
		frame.roughness, from,
	)
	if sp.points[to].parent != from {
		at_idx := spline_push(sp, np)
		sp.points[at_idx].weld = to
		sp.points[from].weld = -1
		split.mid = sp.points[at_idx].id
		return at_idx, split
	}
	spline_inject(sp, to, np)
	// Every index the insertion moved, then the one edge it broke: the old
	// child now hangs off the new point.
	shift_links(sp, to, to)
	sp.points[to + 1].parent = to
	split.mid = sp.points[to].id
	return to, split
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
			return spline_push(sp, copy)
		}
	}
	if idx == 0 && len(sp.points) > 1 {
		spline_inject(sp, 0, sp.points[0])
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
	spline_inject(sp, idx + 1, sp.points[idx])
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
	// Parents and welds are array positions and shift; ids stay (see next_id).
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
		p = point_flipped(p)
		// reverse_spline is only defined for a chain. Array order is its new
		// travel order, so rebuild the graph edges to match that order.
		p.parent = i - 1
		p.weld = -1
	}
}

// The same control point faced the other way: forward negated, the surface
// normal kept, and the physical sides swapped, because the old left is the new
// right. A whole chain of these is reverse_spline; one of them is a stage
// crossing an edge against the way the road was drawn.
point_flipped :: proc(p: Point) -> Point {
	out := p
	out.xform.rotation = quat_from_frame(-point_forward(p), point_up(p))
	out.cliff_l, out.cliff_r = p.cliff_r, p.cliff_l
	out.span_l, out.span_r = p.span_r, p.span_l
	return out
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
	return spline_push(sp, make_point(at, rot, width, cliff_l, cliff_r, span_l, span_r, taper, angle, rough, parent))
}

// --- markers -----------------------------------------------------------------

// Where a start or finish line sits: a point along one graph edge.
//
// The edge is named by the **ids** of the points at its two ends, not by their
// array positions. A marker lives outside the spline — in venue.json, on a
// stage — so nothing can renumber it the way shift_links renumbers parents and
// welds, and an insert two hundred points away would otherwise slide it onto a
// different road. Naming both ends rather than the child is what lets it sit on
// a weld, which is how a loop stage finishes where it began.
//
// -1 in either end is "not placed yet".
Road_Marker :: struct {
	from: int,
	to:   int,
	t:    f32,
}

// A marker resolved against the spline it names: the same edge, by array index.
//
// **Ids at rest, indices in flight.** Everything that walks the graph works in
// indices; marker_resolve and marker_of are the only two crossings. Its own
// type rather than a reused Road_Marker, because the two are the same three
// fields meaning different things, and the compiler is the only reliable place
// to keep those apart.
Edge_At :: struct {
	from: int,
	to:   int,
	t:    f32,
}

// An edge picked off the ribbon, named so it will keep. Cross_Section carries
// e_from/e_to/t, which is an Edge_At in all but name.
marker_of :: proc(sp: Spline, e: Edge_At) -> Road_Marker {
	n := len(sp.points)
	if e.from < 0 || e.from >= n || e.to < 0 || e.to >= n {
		return {from = -1, to = -1}
	}
	return {from = sp.points[e.from].id, to = sp.points[e.to].id, t = e.t}
}

// One edge cut in two by an insert: `a` -> `mid` -> `b`, by point id, with `t`
// saying where along the old edge the cut fell. `mid` is -1 when nothing was
// cut. Anything holding a marker into the graph has to be told this, because
// the edge the marker named has stopped existing.
Edge_Split :: struct {
	a, mid, b: int,
	t:         f32,
}

// Carry a marker across a split: it moves onto whichever half now holds it,
// with `t` rescaled to that half. A marker on any other edge is left alone.
//
// The road between `a` and `b` genuinely moves when a point goes in, so no
// rescale is exact. This one is in curve parameter; `a_split_barely_moves_a_marker`
// measures what that costs.
marker_follow :: proc(m: ^Road_Marker, s: Edge_Split) {
	if s.mid < 0 || s.t <= 0 || s.t >= 1 {
		return
	}
	if m.from != s.a || m.to != s.b {
		return
	}
	if m.t < s.t {
		m.to = s.mid
		m.t = m.t / s.t
	} else {
		m.from = s.mid
		m.t = (m.t - s.t) / (1 - s.t)
	}
}

// The same spot on the road after reverse_spline. Every edge is drawn the other
// way round now, so a marker's ends swap and `t` runs from the other one. Exact,
// because the ids travel with their points through the reversal.
marker_reversed :: proc(m: Road_Marker) -> Road_Marker {
	if m.from < 0 || m.to < 0 {
		return m
	}
	return {from = m.to, to = m.from, t = 1 - m.t}
}

// The marker's edge as it stands now, or ok=false when that edge is gone —
// either end removed, or the stretch split by an insert. False is the honest
// answer and the caller says so; the alternative is a confident wrong road.
marker_resolve :: proc(sp: Spline, m: Road_Marker) -> (e: Edge_At, ok: bool) {
	from, to := point_index(sp, m.from), point_index(sp, m.to)
	if from < 0 || to < 0 || from == to {
		return {}, false
	}
	// Drawn order only, because `t` runs from `from` to `to`. A marker is
	// always built from a ribbon sample, and build_ribbon emits every edge the
	// way it was drawn.
	if sp.points[to].parent != from && sp.points[from].weld != to {
		return {}, false
	}
	return Edge_At{from = from, to = to, t = m.t}, true
}

// Keeps a marker clear of the node at either end of its edge. Landing exactly
// on one would put two control points in the same place, and a zero-length
// segment has no tangent to follow.
MARKER_MARGIN :: 0.02

marker_valid :: proc(sp: Spline, m: Road_Marker) -> bool {
	_, ok := marker_resolve(sp, m)
	return ok
}

// The control point a marker stands for, framed by the road it sits on.
marker_point :: proc(sp: Spline, e: Edge_At) -> Point {
	t := clamp(e.t, MARKER_MARGIN, 1 - MARKER_MARGIN)
	// Through the resolver, because a start line inside a cliffed stretch has
	// to come out of a compile standing at the height the road already stands
	// at. The point itself holds no cliff until this fills it.
	one := []Cross_Section{sample_edge(sp, e.from, e.to, t)}
	resolve_cliffs(sp, one)
	cs := one[0]
	src := sp.points[e.from]
	return make_point(
		cs.pos, quat_from_frame(cs.fwd, cs.up), cs.width,
		cs.cliff_l, cs.cliff_r, src.span_l, src.span_r,
		src.cliff_taper, cs.cliff_angle, cs.roughness, -1,
	)
}

// --- the road graph ----------------------------------------------------------

// Which way a stage crosses one edge. An edge is *drawn* parent -> child (or
// from -> weld), but a stage may cross it either way: coming out of one branch
// of a fork and going down another is only possible against the drawn
// direction, and a reverse stage is the same road driven the other way.
Edge_Dir :: enum {
	Drawn,
	Against,
}

// How `a` and `b` are joined, if they are at all. At most one edge joins two
// control points: weld_points refuses a weld where a parent edge already runs.
edge_between :: proc(sp: Spline, a, b: int) -> (dir: Edge_Dir, ok: bool) {
	n := len(sp.points)
	if a < 0 || a >= n || b < 0 || b >= n || a == b {
		return .Drawn, false
	}
	if sp.points[b].parent == a || sp.points[a].weld == b {
		return .Drawn, true
	}
	if sp.points[a].parent == b || sp.points[b].weld == a {
		return .Against, true
	}
	return .Drawn, false
}

EDGE_LENGTH_STEPS :: 8

// How long a compiled chain is, edge by edge. The ribbon is the accurate
// measure; this one needs no sampling buffer, so a caller that only wants to
// compare two roads can have it cheaply.
spline_length :: proc(sp: Spline) -> (total: f32) {
	for i in 1 ..< len(sp.points) {
		total += edge_length(sp, i - 1, i)
	}
	return
}

// How long one edge is, for choosing between two roads to the same place.
// Sampled, because a Hermite segment is longer than the line across its ends.
edge_length :: proc(sp: Spline, a, b: int) -> f32 {
	dir, ok := edge_between(sp, a, b)
	if !ok {
		return 0
	}
	p0, p1 := sp.points[a], sp.points[b]
	if dir == .Against {
		p0, p1 = p1, p0
	}
	total: f32
	prev := hermite_pos(p0, p1, 0)
	for s in 1 ..= EDGE_LENGTH_STEPS {
		at := hermite_pos(p0, p1, f32(s) / EDGE_LENGTH_STEPS)
		total += gfx.Vector3Distance(prev, at)
		prev = at
	}
	return total
}

@(private = "file")
edge_is :: proc(e: Edge_At, a, b: int) -> bool {
	return (e.from == a && e.to == b) || (e.from == b && e.to == a)
}

@(private = "file")
edge_blocked :: proc(blocked: []Edge_At, a, b: int) -> bool {
	for e in blocked {
		if edge_is(e, a, b) {
			return true
		}
	}
	return false
}

// Farther than any road, and what an unreached control point is left at.
ROAD_INF :: max(f32)

// Every control point joined to every other it shares an edge with, both kinds
// in one array. Undirected, because a road is drivable either way whatever the
// parent pointers spell out. Built in one pass: rescanning the point array at
// every step of a walk would be the same work over and over.
road_links :: proc(sp: Spline, allocator := context.temp_allocator) -> [][dynamic]int {
	n := len(sp.points)
	links := make([][dynamic]int, n, allocator)
	for i in 0 ..< n {
		links[i] = make([dynamic]int, allocator)
	}
	join :: proc(links: [][dynamic]int, a, b: int) {
		append(&links[a], b)
		append(&links[b], a)
	}
	for p, i in sp.points {
		if p.parent >= 0 && p.parent < n && p.parent != i {
			join(links, p.parent, i)
		}
		if p.weld >= 0 && p.weld < n && p.weld != i {
			join(links, i, p.weld)
		}
	}
	return links
}

// The one walk over the road graph: metres from `from` to every control point,
// and the point each was reached through. ROAD_INF where no road runs.
//
// `blocked` names edges the walk may not cross (only `from` and `to` are read).
// `limit` stops it once the nearest point still open is further than that, so a
// walk that only cares about its own neighbourhood does not settle the whole
// venue; points past the limit are left at whatever bound they had reached, and
// are only ever an over-estimate. `stop` ends it early on one point, or -1 for
// all of them.
//
// O(V^2) and no heap: a road is control points, not map tiles.
@(private = "file")
road_walk :: proc(
	sp: Spline,
	from: int,
	blocked: []Edge_At,
	limit: f32,
	stop: int,
	allocator := context.temp_allocator,
) -> (
	dist: []f32,
	prev: []int,
) {
	n := len(sp.points)
	dist = make([]f32, n, allocator)
	prev = make([]int, n, allocator)
	for i in 0 ..< n {
		dist[i], prev[i] = ROAD_INF, -1
	}
	if from < 0 || from >= n {
		return
	}
	links := road_links(sp)
	done := make([]bool, n, context.temp_allocator)
	dist[from] = 0
	for _ in 0 ..< n {
		at := -1
		for i in 0 ..< n {
			if !done[i] && dist[i] < ROAD_INF && (at < 0 || dist[i] < dist[at]) {
				at = i
			}
		}
		if at < 0 || at == stop || dist[at] > limit {
			break
		}
		done[at] = true
		for nbr in links[at] {
			if done[nbr] || edge_blocked(blocked, at, nbr) {
				continue
			}
			if step := dist[at] + edge_length(sp, at, nbr); step < dist[nbr] {
				dist[nbr], prev[nbr] = step, at
			}
		}
	}
	return
}

// The shortest road between two control points, as the points it runs through,
// both ends included. Undirected: parent edges and welds are crossable either
// way, so what comes back is the road a driver can see rather than the one the
// parent pointers happen to spell out. `blocked` names edges the road may not
// cross (only `from` and `to` are read), which is how a leg is stopped from
// doubling back along the edge it just left. nil when no road joins them.
//
// Shortest by metres, not by control points: two roads to the same place are
// rarely cut up the same way.
graph_path :: proc(
	sp: Spline,
	from, to: int,
	blocked: []Edge_At = nil,
	allocator := context.temp_allocator,
) -> []int {
	n := len(sp.points)
	if from < 0 || from >= n || to < 0 || to >= n {
		return nil
	}
	if from == to {
		out := make([]int, 1, allocator)
		out[0] = from
		return out
	}
	dist, prev := road_walk(sp, from, blocked, ROAD_INF, to)
	if dist[to] >= ROAD_INF {
		return nil
	}

	hops := 1
	for node := to; node != from; node = prev[node] {
		hops += 1
	}
	out := make([]int, hops, allocator)
	node := to
	for i := hops - 1; i >= 0; i -= 1 {
		out[i] = node
		node = prev[node]
	}
	return out
}

// How far every control point is from `src` by road, up to `reach`. Past that
// the answer is only an upper bound, which is all a caller that stops at
// `reach` ever reads.
graph_reach :: proc(
	sp: Spline,
	src: int,
	reach: f32,
	allocator := context.temp_allocator,
) -> []f32 {
	dist, _ := road_walk(sp, src, nil, reach, -1, allocator)
	return dist
}

// --- stages ------------------------------------------------------------------

// The control point a marker stands for, faced the way the stage crosses it.
marker_point_dir :: proc(sp: Spline, m: Edge_At, dir: Edge_Dir) -> Point {
	p := marker_point(sp, m)
	return dir == .Drawn ? p : point_flipped(p)
}

@(private = "file")
mark_name :: proc(i, count: int) -> string {
	switch i {
	case 0:
		return "the start line"
	case count - 1:
		return "the finish line"
	}
	return fmt.tprintf("pin %d", i)
}

// Which control point the stage leaves a waypoint through, and which one it
// arrives at. Crossing an edge drawn means leaving at `to`; crossing it against
// means leaving at `from`.
@(private = "file")
mark_exit :: proc(m: Edge_At, dir: Edge_Dir) -> int {
	return dir == .Drawn ? m.to : m.from
}

@(private = "file")
mark_entry :: proc(m: Edge_At, dir: Edge_Dir) -> int {
	return dir == .Drawn ? m.from : m.to
}

// One leg: the road from waypoint `a`, crossed `da`, to waypoint `b`, crossed
// `db`. `nodes` are the control points between them, ends included, and is
// empty when both markers sit on one edge and the stage simply carries on along
// it. `cost` counts the part of each marker's own edge the stage drives, so
// picking a direction at a marker near one end of its edge is not free.
@(private = "file")
leg_road :: proc(
	sp: Spline,
	a: Edge_At, da: Edge_Dir,
	b: Edge_At, db: Edge_Dir,
	allocator := context.temp_allocator,
) -> (
	nodes: []int,
	cost: f32,
	ok: bool,
) {
	len_a := edge_length(sp, a.from, a.to)
	if a.from == b.from && a.to == b.to && da == db {
		if da == .Drawn && a.t < b.t {
			return nil, (b.t - a.t) * len_a, true
		}
		if da == .Against && a.t > b.t {
			return nil, (a.t - b.t) * len_a, true
		}
	}
	// The edge a leg starts on and the one it ends on are both off limits: a
	// stage that doubles back along the road it is already on is a U-turn, not
	// a route. Blocking them is also what sends a start-and-finish pair on one
	// edge the long way round a loop instead of straight back down it.
	blocked := [2]Edge_At{{from = a.from, to = a.to}, {from = b.from, to = b.to}}
	nodes = graph_path(sp, mark_exit(a, da), mark_entry(b, db), blocked[:], allocator)
	if nodes == nil {
		return nil, 0, false
	}
	cost = (da == .Drawn ? 1 - a.t : a.t) * len_a
	cost += (db == .Drawn ? b.t : 1 - b.t) * edge_length(sp, b.from, b.to)
	for i in 1 ..< len(nodes) {
		cost += edge_length(sp, nodes[i - 1], nodes[i])
	}
	return nodes, cost, true
}

// The road a stage runs over, as a plain chain the exporter can take: the start
// line, the finish line, and every pin between them in the order they were
// placed.
//
// The search is undirected and shortest-first, so a stage takes the quickest
// road from the start to the finish by default. A pin is a road the stage is
// made to cross on the way, which is how a longer way round is asked for when
// the venue has a shorter one. Pins are crossed in order and none of them
// becomes a control point: a pin says which road, not where a point goes.
//
// A stage may cross an edge against the direction the road was drawn in — it
// has to, to come out of one branch of a fork and go down another — so every
// control point is turned to face the way the stage crosses it as it is copied.
// What comes out is one consistent travel direction from end to end, which is
// what the ribbon, the pace notes and the preview all read.
compile_stage :: proc(
	sp: Spline,
	start, finish: Road_Marker,
	pins: []Road_Marker,
	allocator := context.allocator,
) -> (
	out: Spline,
	msg: string,
	ok: bool,
) {
	// The waypoints in travel order, each turned from the ids it keeps into the
	// indices the graph walk needs. This is the only place a stage's markers
	// are resolved, so a line whose road has been edited away is caught once,
	// here, and named.
	lines := make([dynamic]Road_Marker, 0, len(pins) + 2, context.temp_allocator)
	append(&lines, start)
	append(&lines, ..pins)
	append(&lines, finish)
	last := len(lines) - 1
	marks := make([]Edge_At, len(lines), context.temp_allocator)
	for m, i in lines {
		at, on_road := marker_resolve(sp, m)
		if !on_road {
			return out, fmt.tprintf("%s is not on a road", mark_name(i, len(lines))), false
		}
		marks[i] = at
	}
	for i in 0 ..< last {
		a, b := marks[i], marks[i + 1]
		if a.from == b.from && a.to == b.to && abs(a.t - b.t) < MARKER_MARGIN {
			return out, fmt.tprintf(
				"%s and %s are on the same spot",
				mark_name(i, len(marks)), mark_name(i + 1, len(marks)),
			), false
		}
	}

	// Each waypoint is crossed one way or the other, and that choice is not
	// free of the next one: crossing a pin drawn means leaving it at `to`,
	// which is where the following leg has to start. So the legs are solved
	// together and the cheapest whole road wins.
	INF :: max(f32)
	best := make([][Edge_Dir]f32, len(marks), context.temp_allocator)
	back := make([][Edge_Dir]Edge_Dir, len(marks), context.temp_allocator)
	for &b in best {
		b = {.Drawn = INF, .Against = INF}
	}
	best[0] = {.Drawn = 0, .Against = 0}
	for i in 0 ..< last {
		reached := false
		for da in Edge_Dir {
			if best[i][da] >= INF {
				continue
			}
			for db in Edge_Dir {
				_, cost, leg_ok := leg_road(sp, marks[i], da, marks[i + 1], db)
				if !leg_ok {
					continue
				}
				reached = true
				if total := best[i][da] + cost; total < best[i + 1][db] {
					best[i + 1][db] = total
					back[i + 1][db] = da
				}
			}
		}
		if !reached {
			return out, fmt.tprintf(
				"no road runs from %s to %s",
				mark_name(i, len(marks)), mark_name(i + 1, len(marks)),
			), false
		}
	}

	dirs := make([]Edge_Dir, len(marks), context.temp_allocator)
	dirs[last] = best[last][.Drawn] <= best[last][.Against] ? .Drawn : .Against
	for i := last; i > 0; i -= 1 {
		dirs[i - 1] = back[i][dirs[i]]
	}

	// The control points the stage runs through, in travel order. A leg ends at
	// one end of the next waypoint's edge and the leg after it starts at the
	// other, so the legs join up with nothing to trim.
	walk := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< last {
		nodes, _, leg_ok := leg_road(sp, marks[i], dirs[i], marks[i + 1], dirs[i + 1])
		if !leg_ok {
			return out, "no road runs the whole way", false
		}
		append(&walk, ..nodes)
	}

	first_p := marker_point_dir(sp, marks[0], dirs[0])
	last_p := marker_point_dir(sp, marks[last], dirs[last])
	// A compiled chain is a new document, so its points take ids from its own
	// counter rather than inheriting the venue's.
	out.points = make([dynamic]Point, allocator)
	spline_push(&out, first_p)
	for nd, i in walk {
		in_dir := dirs[0]
		if i > 0 {
			in_dir, _ = edge_between(sp, walk[i - 1], nd)
		}
		out_dir := dirs[last]
		if i < len(walk) - 1 {
			out_dir, _ = edge_between(sp, nd, walk[i + 1])
		}
		p := sp.points[nd]
		if out_dir == .Against {
			p = point_flipped(p)
		}
		if in_dir != out_dir {
			// A point the stage turns at — the apex of a fork it comes up one
			// branch of and leaves down another — has no tangent either edge
			// can lend it. It takes the heading through it instead.
			before := i == 0 ? first_p.xform.translation : sp.points[walk[i - 1]].xform.translation
			after := i == len(walk) - 1 ? last_p.xform.translation : sp.points[walk[i + 1]].xform.translation
			p.xform.rotation = heading_quat(before, after)
		}
		spline_push(&out, p)
	}
	spline_push(&out, last_p)

	// A compiled stage is a chain, never a graph. Nothing downstream of here
	// branches, and the exporter reads array order as travel order.
	for &p, i in out.points {
		p.parent = i - 1
		p.weld = -1
	}
	if len(pins) > 0 {
		return out, fmt.tprintf("%d control points, %d pins", len(out.points), len(pins)), true
	}
	return out, fmt.tprintf("%d control points", len(out.points)), true
}
