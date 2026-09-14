package geo

// Road spline model + geometry.
//
// A spline is an ordered chain of *oriented control points* (parent -> child ==
// array order). Each control point carries a full raylib Transform: its
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

import "core:math"
import rl "vendor:raylib"

DEFAULT_WIDTH :: 8.0    // metres — plausible rally road width
SAMPLES_PER_SEG :: 14   // curve subdivisions between two control points
HERMITE_TENSION :: 1.0  // tangent scale; higher == wider swoops

DEFAULT_CLIFF_SPAN :: 48.0  // metres of road a cliff covers, end to end
DEFAULT_CLIFF_TAPER :: 16.0 // metres of that span spent rising and falling
DEFAULT_CLIFF_ANGLE :: 6.0  // degrees off vertical, leaning away from the road

Point :: struct {
	xform:       rl.Transform, // translation = centre, rotation = road frame
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

// A sampled slice across the road: everything needed to lay a ribbon rung and
// to pick against it. `seg` is the index of the control point the sample grew
// from (the parent of the segment it lies on).
Cross_Section :: struct {
	pos:     rl.Vector3,
	right:   rl.Vector3, // across the road, unit
	up:      rl.Vector3, // surface normal, unit
	fwd:     rl.Vector3, // travel direction, unit
	width:   f32,
	seg:     int,
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

point_forward :: proc(p: Point) -> rl.Vector3 {
	return rl.Vector3Normalize(rl.Vector3RotateByQuaternion({0, 0, 1}, p.xform.rotation))
}
point_right :: proc(p: Point) -> rl.Vector3 {
	return rl.Vector3Normalize(rl.Vector3RotateByQuaternion({1, 0, 0}, p.xform.rotation))
}
point_up :: proc(p: Point) -> rl.Vector3 {
	return rl.Vector3Normalize(rl.Vector3RotateByQuaternion({0, 1, 0}, p.xform.rotation))
}

// the two rung endpoints of a control point (left, right), honouring bank
point_ends :: proc(p: Point) -> (left: rl.Vector3, right: rl.Vector3) {
	r := point_right(p)
	half := r * (p.width * 0.5)
	return p.xform.translation + half, p.xform.translation - half
}

// a quaternion whose local +Z == fwd and +Y == up (orthonormalised)
quat_from_frame :: proc(fwd, up: rl.Vector3) -> rl.Quaternion {
	f := rl.Vector3Normalize(fwd)
	r := rl.Vector3Normalize(rl.Vector3CrossProduct(up, f))
	u := rl.Vector3CrossProduct(f, r)
	// column-major basis (right, up, forward) as a rotation matrix
	m := rl.Matrix{
		r.x, u.x, f.x, 0,
		r.y, u.y, f.y, 0,
		r.z, u.z, f.z, 0,
		0,   0,   0,   1,
	}
	return rl.QuaternionFromMatrix(m)
}

// level heading (yaw about +Y) pointing from `from` toward `to`
heading_quat :: proc(from, to: rl.Vector3) -> rl.Quaternion {
	d := to - from
	yaw := math.atan2(d.x, d.z)
	return rl.QuaternionFromAxisAngle({0, 1, 0}, yaw)
}

make_point :: proc(
	pos: rl.Vector3,
	rot: rl.Quaternion,
	width: f32,
	cliff_l: f32 = 0,
	cliff_r: f32 = 0,
	span_l: f32 = DEFAULT_CLIFF_SPAN,
	span_r: f32 = DEFAULT_CLIFF_SPAN,
	cliff_taper: f32 = DEFAULT_CLIFF_TAPER,
	cliff_angle: f32 = DEFAULT_CLIFF_ANGLE,
	roughness:   f32 = 0,
) -> Point {
	return Point {
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
hermite_pos :: proc(p0, p1: Point, t: f32) -> rl.Vector3 {
	P0 := p0.xform.translation
	P1 := p1.xform.translation
	L := rl.Vector3Length(P1 - P0) * HERMITE_TENSION
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
hermite_tangent :: proc(p0, p1: Point, t: f32) -> rl.Vector3 {
	P0 := p0.xform.translation
	P1 := p1.xform.translation
	L := rl.Vector3Length(P1 - P0) * HERMITE_TENSION
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
	fwd := rl.Vector3Normalize(tangent)
	if rl.Vector3Length(tangent) < 1e-5 {
		fwd = point_forward(p0)
	}
	// interpolate the surface normal (banking / slope) via the control rotations
	q := rl.QuaternionSlerp(p0.xform.rotation, p1.xform.rotation, t)
	up_ref := rl.Vector3Normalize(rl.Vector3RotateByQuaternion({0, 1, 0}, q))
	right := rl.Vector3Normalize(rl.Vector3CrossProduct(up_ref, fwd))
	up := rl.Vector3Normalize(rl.Vector3CrossProduct(fwd, right))
	width := p0.width + (p1.width - p0.width) * t
	angle := p0.cliff_angle + (p1.cliff_angle - p0.cliff_angle) * t
	rough := p0.roughness + (p1.roughness - p0.roughness) * t
	return Cross_Section {
		pos = pos, right = right, up = up, fwd = fwd,
		width = width, seg = seg, cliff_angle = angle, roughness = rough,
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
	for seg in 0 ..< nseg {
		// each segment contributes t in [0, 1); the final endpoint is added once
		for s in 0 ..< spp {
			t := f32(s) / f32(spp)
			append(&out, sample_at(sp, seg, t))
		}
	}
	append(&out, sample_at(sp, nseg - 1, 1.0))
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
		arc[i] = arc[i - 1] + rl.Vector3Distance(ribbon[i - 1].pos, ribbon[i].pos)
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
		k[i] = rl.Vector3DotProduct(dfwd, ribbon[i].right) / ds
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
xsec_ends :: proc(cs: Cross_Section) -> (left: rl.Vector3, right: rl.Vector3) {
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
insert_point :: proc(sp: ^Spline, seg: int, at: rl.Vector3, frame: Cross_Section) -> int {
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
	)
	inject_at(&sp.points, seg + 1, np)
	return seg + 1
}

// Extrude the point at `idx`: duplicate it and return the index of the copy, which
// the caller drags away. The copy always goes on the *outward* side so the spline
// grows at its ends rather than gaining a point mid-chain:
//   - head (idx 0)  -> copy becomes the new head, extending backwards
//   - otherwise     -> copy becomes idx's child, so extruding the tail appends
extrude_point :: proc(sp: ^Spline, idx: int) -> int {
	if idx == 0 && len(sp.points) > 1 {
		inject_at(&sp.points, 0, sp.points[0])
		return 0
	}
	inject_at(&sp.points, idx + 1, sp.points[idx])
	return idx + 1
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
	for &p in sp.points {
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
append_point :: proc(sp: ^Spline, at: rl.Vector3) -> int {
	rot := rl.Quaternion(1)
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
	append(&sp.points, make_point(at, rot, width, cliff_l, cliff_r, span_l, span_r, taper, angle, rough))
	return len(sp.points) - 1
}
