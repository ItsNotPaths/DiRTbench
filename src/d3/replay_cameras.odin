package d3

// `replay_camera_config.xml` and two of the six `cutscene_*.xml`, written
// from a route's own centre line. See `docs/dirt3-cutscenes.md` for the formats.
//
// Both sides are ours, which is the point: a cutscene names a camera by
// `ident` and nothing more, and the donor's idents carry route-set suffixes
// like `mont_0_camera_r0124` that no rule derives. Writing the timelines too
// means every name here is one we chose, so the pair cannot disagree and a
// venue does not inherit its base's camera naming.
//
// The names the *global* `<install>/cutscene/` files reach back for are not
// free: they substitute `[route]` into `start_camera_r[route]` and
// `splitfin_camera_r[route]`, and `startsequence.xml` names
// `initial_camera_r0` literally. Those are emitted at exactly those names.

import "core:fmt"
import "core:math"
import "core:mem"

// Camera forward is +Z. Measured exact: the orientation quaternion rotates +Z
// onto (first target point - position) with 0.0 degrees of error on every
// stock camera that carries a target path.
D3_CAMERA_FORWARD :: [3]f32{0, 0, 1}

// A montage shot dollies this far along the road over its hold, slowly enough
// to read as a crane rather than a fly-by.
D3_CAMERA_DOLLY_M :: f32(18)
// How long one montage camera holds before the cut. `updateTime` on the event,
// not the spline duration — stock disagrees on 382 of 430 montage references,
// so the spline runs longer and the cut lands part-way through.
D3_CAMERA_HOLD_S :: f32(5)
D3_CAMERA_SPLINE_S :: f32(6.66667)

D3_Camera_Shot :: struct {
	ident:     string,
	// Where it sits, and the first point of what it looks at.
	eye, aim:  [3]f32,
	// The dolly, and the road it tracks. Four points each: a spline is cubic
	// Bezier segments of four controls, and one segment is the whole shot.
	eye_end:   [3]f32,
	aim_end:   [3]f32,
	duration:  f32,
}

// --- vectors -----------------------------------------------------------------

@(private = "file")
d3_cam_sub :: proc(a, b: [3]f32) -> [3]f32 { return {a[0]-b[0], a[1]-b[1], a[2]-b[2]} }

@(private = "file")
d3_cam_add :: proc(a, b: [3]f32) -> [3]f32 { return {a[0]+b[0], a[1]+b[1], a[2]+b[2]} }

@(private = "file")
d3_cam_scale :: proc(a: [3]f32, s: f32) -> [3]f32 { return {a[0]*s, a[1]*s, a[2]*s} }

@(private = "file")
d3_cam_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]}
}

@(private = "file")
d3_cam_norm :: proc(a: [3]f32) -> [3]f32 {
	n := math.sqrt(a[0]*a[0]+a[1]*a[1]+a[2]*a[2])
	if n < 1e-6 { return D3_CAMERA_FORWARD }
	return {a[0]/n, a[1]/n, a[2]/n}
}

// The quaternion taking local +Z onto `forward`, roll levelled against world
// up. Verified against 24 stock cameras: reproduces their own orientation's
// aim to 0.0000 degrees.
d3_camera_orientation :: proc(forward: [3]f32) -> [4]f32 {
	f := d3_cam_norm(forward)
	up := [3]f32{0, 1, 0}
	if abs(f[1]) > 0.999 { up = {0, 0, 1} }
	r := d3_cam_norm(d3_cam_cross(up, f))
	u := d3_cam_cross(f, r)
	// Columns are the images of local x, y and z.
	m := [3][3]f32{{r[0], u[0], f[0]}, {r[1], u[1], f[1]}, {r[2], u[2], f[2]}}
	trace := m[0][0] + m[1][1] + m[2][2]
	if trace > 0 {
		s := math.sqrt(trace+1) * 2
		return {(m[2][1]-m[1][2])/s, (m[0][2]-m[2][0])/s, (m[1][0]-m[0][1])/s, 0.25*s}
	}
	if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
		s := math.sqrt(1+m[0][0]-m[1][1]-m[2][2]) * 2
		return {0.25*s, (m[0][1]+m[1][0])/s, (m[0][2]+m[2][0])/s, (m[2][1]-m[1][2])/s}
	}
	if m[1][1] > m[2][2] {
		s := math.sqrt(1+m[1][1]-m[0][0]-m[2][2]) * 2
		return {(m[0][1]+m[1][0])/s, 0.25*s, (m[1][2]+m[2][1])/s, (m[0][2]-m[2][0])/s}
	}
	s := math.sqrt(1+m[2][2]-m[0][0]-m[1][1]) * 2
	return {(m[0][2]+m[2][0])/s, (m[1][2]+m[2][1])/s, 0.25*s, (m[1][0]-m[0][1])/s}
}

// --- shot placement ----------------------------------------------------------

// The road's own across-vector at a station, and the direction of travel.
@(private = "file")
d3_cam_frame :: proc(line: []Route_Station, distance: f32) -> (at, side, ahead: [3]f32) {
	station := d3_station_at(line, distance)
	next := d3_station_at(line, min(distance+1, line[len(line)-1].distance))
	ahead = d3_cam_norm(d3_cam_sub(next.centre, station.centre))
	side = d3_cam_norm(d3_cam_cross({0, 1, 0}, ahead))
	return station.centre, side, ahead
}

// Deterministic, so the same road exports the same shots. A road edit moves
// them, which is correct: they are placed along it.
@(private = "file")
d3_cam_hash :: proc(seed: u32) -> f32 {
	h := seed*2654435761 + 1013904223
	h ~= h >> 15
	h *= 2246822519
	h ~= h >> 13
	return f32(h & 0xffff) / 65535
}

// One dolly: sit off the road, walk forward with it, and look at the stretch
// the car will take. `spread` is 0..1 along the route.
@(private = "file")
d3_cam_dolly :: proc(
	line: []Route_Station,
	ident: string,
	spread: f32,
	index: u32,
	lateral, height, ahead_m: f32,
) -> D3_Camera_Shot {
	total := line[len(line)-1].distance
	d := spread * total
	at, side, ahead := d3_cam_frame(line, d)
	// Left or right of the road, by the hash, so a montage does not shoot every
	// corner from the same shoulder.
	if d3_cam_hash(index*7+1) < 0.5 { side = d3_cam_scale(side, -1) }
	eye := d3_cam_add(d3_cam_add(at, d3_cam_scale(side, lateral)), {0, height, 0})
	aim_d := min(d+ahead_m, total)
	return {
		ident    = ident,
		eye      = eye,
		eye_end  = d3_cam_add(eye, d3_cam_scale(ahead, D3_CAMERA_DOLLY_M)),
		aim      = d3_station_at(line, min(d+10, total)).centre,
		aim_end  = d3_station_at(line, aim_d).centre,
		duration = D3_CAMERA_SPLINE_S,
	}
}

// Appends `shot` as `base_r<route>`, plus a `base_r0` alias when the route is
// not 0: deployment hardlinks the base route's cutscenes into every route of
// a venue, so route 3 inherits timelines that still say `_r0`. Emitting both
// names satisfies both readers; a camera costs a spline and 43 parameters.
@(private = "file")
d3_cam_push :: proc(
	out: ^[dynamic]D3_Camera_Shot,
	shot: D3_Camera_Shot,
	base: string,
	route: int,
	allocator: mem.Allocator,
) {
	named := shot
	named.ident = fmt.aprintf("%s_r%d", base, route, allocator = allocator)
	append(out, named)
	if route != 0 {
		alias := shot
		alias.ident = fmt.aprintf("%s_r0", base, allocator = allocator)
		append(out, alias)
	}
}

// Every shot a route needs: the fixed set the cutscenes and the global
// sequences name, plus `montage` dollies spread along the road.
//
// `montage` of 0 still emits the fixed set, because `start_camera_r#` and
// `initial_camera_r0` are named from outside this file and must exist.
d3_camera_shots :: proc(
	line: []Route_Station,
	route: int,
	montage: int,
	allocator := context.temp_allocator,
) -> (
	shots: []D3_Camera_Shot,
	msg: string,
	ok: bool,
) {
	if len(line) < 2 {
		return nil, "replay cameras need a route with at least two stations", false
	}
	total := line[len(line)-1].distance
	if total < 1 {
		return nil, "replay cameras need a route longer than a metre", false
	}
	out := make([dynamic]D3_Camera_Shot, allocator)

	// The grid shot. Off the shoulder at the start, looking back down the line
	// the field sits on. It doubles as the initial camera the global
	// `startsequence.xml` names.
	start_at, start_side, start_ahead := d3_cam_frame(line, 0)
	start_eye := d3_cam_add(d3_cam_add(start_at, d3_cam_scale(start_side, 14)), {0, 5, 0})
	grid := D3_Camera_Shot{
		eye      = start_eye,
		eye_end  = d3_cam_add(start_eye, d3_cam_scale(start_ahead, 10)),
		aim      = d3_station_at(line, 12).centre,
		aim_end  = d3_station_at(line, min(70, total)).centre,
		duration = 7,
	}
	d3_cam_push(&out, grid, "start_camera", route, allocator)
	d3_cam_push(&out, grid, "initial_camera", route, allocator)

	// The opening card, high and wide over the first third.
	establish := d3_cam_dolly(line, "", 0.3, 101, 70, 40, 120)
	establish.duration = 13.33333
	d3_cam_push(&out, establish, "establish_camera", route, allocator)

	// The finish, and the two multiplayer finishes, all looking back up the road.
	finish_at, finish_side, _ := d3_cam_frame(line, total)
	finish_eye := d3_cam_add(d3_cam_add(finish_at, d3_cam_scale(finish_side, 15)), {0, 9, 0})
	for base in ([]string{"finishlineCam", "multifin_camera", "splitfin_camera"}) {
		d3_cam_push(&out, D3_Camera_Shot{
			eye      = finish_eye,
			// Still. A source spline of four identical points is stock: 220
			// of the game's own `zoom` cameras ride one.
			eye_end  = finish_eye,
			aim      = d3_station_at(line, max(total-12, 0)).centre,
			aim_end  = d3_station_at(line, max(total-90, 0)).centre,
			duration = 7,
		}, base, route, allocator)
	}

	// The montage. Spread over the middle of the route, so the establishing
	// shot and the grid are not repeated.
	for i in 0 ..< montage {
		spread := 0.15 + 0.7*f32(i)/f32(max(montage-1, 1))
		wobble := (d3_cam_hash(u32(i)*13+5) - 0.5) * 0.08
		lateral := 20 + d3_cam_hash(u32(i)*29+9)*26
		height := 7 + d3_cam_hash(u32(i)*37+3)*14
		shot := d3_cam_dolly(
			line, "", clamp(spread+wobble, 0.02, 0.96), u32(i), lateral, height, 90,
		)
		shot.ident = fmt.aprintf("mont_%d_camera_r%d", i, route, allocator = allocator)
		append(&out, shot)
	}
	return out[:], fmt.tprintf("%d placed, %d montage shots", len(out), montage), true
}

// --- the config --------------------------------------------------------------

@(private = "file")
D3_Cam_Param :: struct { name, kind, value: string }

// Every parameter a `zoom` camera carries beyond its own placement, copied
// from `finland_rally/route_0`'s `start_camera_r0`.
//
// The list is read by name and is not fixed — `zoom` alone uses 147 distinct
// lists across the stock routes — so one real camera's list is copied whole
// rather than invented. Only `Position` and `orientation` vary per shot; these
// 41 are tuning.
@(private = "file")
D3_CAMERA_PARAMS := []D3_Cam_Param{
	{"verticalAdjustment", "scalar", "0.500000"},
	{"horizontalAdjustment", "scalar", "0.500000"},
	{"dynamicAdjustment", "bool", "true"},
	{"lookahead", "scalar", "0.025000"},
	{"lookaheadMaxAdjustment", "scalar", "0.330000"},
	{"waitTime", "scalar", "0.000000"},
	{"waitDistance", "scalar", "0.000000"},
	{"overZoomPercent", "scalar", "0.000000"},
	{"overZoomTime", "scalar", "0.000000"},
	{"targetRadiusCrashZoom", "scalar", "0.000000"},
	{"zoomInDamping", "scalar", "1.000000"},
	{"zoomOutDamping", "scalar", "1.000000"},
	{"useWaitTime", "bool", "false"},
	{"useWaitDistance", "bool", "false"},
	{"crashZoomEnabled", "bool", "false"},
	{"handyCamEnabled", "bool", "false"},
	{"minNoiseFOV", "scalar", "45.000000"},
	{"maxNoiseFOV", "scalar", "45.000000"},
	{"minNoise", "scalar", "0.416000"},
	{"maxNoise", "scalar", "0.416000"},
	{"roughness", "scalar", "0.277000"},
	{"frequency", "scalar", "0.637000"},
	{"xyTorque", "scalar", "41.618000"},
	{"zTorque", "scalar", "39.306000"},
	{"handyCamFractal", "bool", "true"},
	{"handyCamHarmonic", "bool", "false"},
	{"roll", "scalar", "0.000000"},
	{"defaultFov", "scalar", "43.000000"},
	{"minimumFov", "scalar", "43.000000"},
	{"maximumFov", "scalar", "43.000000"},
	{"turnAcceleration", "scalar", "0.800000"},
	{"turnDamping", "scalar", "5.000000"},
	{"maxTurnSpeed", "scalar", "1.500000"},
	{"shakeAngle", "scalar", "0.000000"},
	{"shakeRadius", "scalar", "5.000000"},
	{"shakeDamping", "scalar", "5.000000"},
	{"minimumShakeSpeed", "scalar", "0.000000"},
	{"maximumShakeSpeed", "scalar", "0.000000"},
	{"shakeScaleX", "scalar", "1.000000"},
	{"shakeScaleY", "scalar", "1.000000"},
	{"shakeRotationSpeed", "scalar", "1.000000"},
}

@(private = "file")
d3_cam_f :: proc(v: f32) -> string { return fmt.tprintf("%.6f", v) }

@(private = "file")
d3_cam_vector3 :: proc(name: string, v: [3]f32, allocator := context.temp_allocator) -> ^Bxml_Node {
	return bxml_node("Parameter", bxml_attrs(
		{"name", name}, {"type", "vector3"},
		{"x", d3_cam_f(v[0])}, {"y", d3_cam_f(v[1])}, {"z", d3_cam_f(v[2])},
		allocator = allocator,
	), nil, allocator)
}

// Four controls, the inner two on the straight thirds. One segment is one shot.
@(private = "file")
d3_cam_spline :: proc(
	ident: string,
	from, to: [3]f32,
	duration: f32,
	curve: string,
	allocator := context.temp_allocator,
) -> ^Bxml_Node {
	span := d3_cam_sub(to, from)
	points := make([]^Bxml_Node, 4, allocator)
	for i in 0 ..< 4 {
		p := d3_cam_add(from, d3_cam_scale(span, f32(i)/3))
		points[i] = bxml_node("Point", bxml_attrs(
			{"x", d3_cam_f(p[0])}, {"y", d3_cam_f(p[1])}, {"z", d3_cam_f(p[2])},
			allocator = allocator,
		), nil, allocator)
	}
	return bxml_node("Path", bxml_attrs(
		// Every one of the 1424 stock splines measured carries local="true",
		// including the world-space ones, so it is not a space flag.
		{"ident", ident}, {"type", "spline"}, {"local", "true"},
		{"duration", fmt.tprintf("%g", duration)}, {"loop", "false"},
		{"percentageCurve", curve},
		allocator = allocator,
	), points, allocator)
}

@(private = "file")
d3_cam_linear :: proc(ident: string, allocator := context.temp_allocator) -> ^Bxml_Node {
	values := make([]^Bxml_Node, 2, allocator)
	values[0] = bxml_node("Value", bxml_attrs({"time", "0.000000"}, {"value", "0.000000"}, allocator = allocator), nil, allocator)
	values[1] = bxml_node("Value", bxml_attrs({"time", "1.000000"}, {"value", "1.000000"}, allocator = allocator), nil, allocator)
	return bxml_node("Path", bxml_attrs({"ident", ident}, {"type", "linearPercentage"}, allocator = allocator), values, allocator)
}

// `replay_camera_config.xml` for one route.
//
// No `ActivationZone`: those are the in-race replay director, and no cutscene
// reaches them. Omitting them costs in-race replay angles and nothing else.
d3_replay_camera_config :: proc(
	line: []Route_Station,
	route: int,
	montage: int,
	allocator := context.allocator,
) -> (
	data: []u8,
	msg: string,
	ok: bool,
) {
	shots, shots_msg, shots_ok := d3_camera_shots(line, route, montage, context.temp_allocator)
	if !shots_ok {
		return nil, shots_msg, false
	}

	children := make([dynamic]^Bxml_Node, context.temp_allocator)
	for shot in shots {
		source := fmt.tprintf("spline_%s", shot.ident)
		target := fmt.tprintf("spline_%s.Target", shot.ident)
		curve := fmt.tprintf("%s_linearControllerPath", shot.ident)
		target_curve := fmt.tprintf("%s.Target_linearControllerPath", shot.ident)

		params := make([dynamic]^Bxml_Node, context.temp_allocator)
		// Position is the first point of the source spline, exactly. Stock's
		// exceptions are shared splines and sub-millimetre drift; ours has
		// neither.
		append(&params, d3_cam_vector3("Position", shot.eye))
		orientation := d3_camera_orientation(d3_cam_sub(shot.aim, shot.eye))
		append(&params, bxml_node("Parameter", bxml_attrs(
			{"name", "orientation"}, {"type", "Quaternion"},
			{"x", d3_cam_f(orientation[0])}, {"y", d3_cam_f(orientation[1])},
			{"z", d3_cam_f(orientation[2])}, {"w", d3_cam_f(orientation[3])},
		)))
		for param in D3_CAMERA_PARAMS {
			append(&params, bxml_node("Parameter", bxml_attrs(
				{"name", param.name}, {"type", param.kind}, {"value", param.value},
			)))
		}

		attrs := make([dynamic]Bxml_Attr, context.temp_allocator)
		append(&attrs, Bxml_Attr{"type", "zoom"}, Bxml_Attr{"ident", shot.ident})
		append(&attrs, Bxml_Attr{"sourcePath", source}, Bxml_Attr{"targetPath", target})
		append(&attrs, Bxml_Attr{"postProcess", "PreRaceDOF"})
		append(&children, bxml_node("Camera", attrs[:], params[:], context.temp_allocator))

		append(&children, d3_cam_spline(source, shot.eye, shot.eye_end, shot.duration, curve))
		append(&children, d3_cam_linear(curve))
		append(&children, d3_cam_spline(target, shot.aim, shot.aim_end, shot.duration, target_curve))
		append(&children, d3_cam_linear(target_curve))
	}

	// The cameras no route derives, copied whole rather than placed: the crash
	// camera with its rig, and the four whose coordinates are metres from a
	// subject instead of from the venue origin.
	append(&children, ..d3_stock_elements(context.temp_allocator))
	shots_msg = fmt.tprintf("%s, %d copied whole", shots_msg, D3_STOCK_CAMERAS)

	root := bxml_node("ReplayCameraConfiguration", bxml_attrs(
		{"route", fmt.tprintf("%d", route)},
		{"initialCamera", "initial_camera_r0"},
		{"terminalDamageActivationDelay", "0.000000"},
	), children[:], context.temp_allocator)

	built, built_ok := bxml_build(root, allocator)
	if !built_ok {
		return nil, "could not encode replay_camera_config.xml", false
	}
	return built, shots_msg, true
}

// --- the two cutscenes that name our own cameras ------------------------------
//
// Only `establish` and `montage` are written. The other four — `title`,
// `event_start`, `post_race`, `multi_post_race` — stay the donor's, because
// every camera they name follows a rule we emit (`start_camera_r#`,
// `finishlineCam_r#`, `multifin_camera_r#`, `relative_service_camera`) and
// `post_race` alone is 37 elements of slow motion, SFX and OSD with no camera
// geometry in it.
//
// A timeline holds no geometry at all: it names a camera by `ident` and says
// how long to hold before cutting to `nextCamera`.

// `updateTime` is the hold, not the spline duration; see D3_CAMERA_HOLD_S.
@(private = "file")
d3_cut_event :: proc(camera, next: string, hold: f32, allocator := context.temp_allocator) -> ^Bxml_Node {
	attrs := make([dynamic]Bxml_Attr, allocator)
	append(&attrs,
		Bxml_Attr{"type", "ReplayCamera"},
		Bxml_Attr{"resetToTerminal", "false"},
		Bxml_Attr{"targetPlayer", "false"},
		Bxml_Attr{"camera", camera},
	)
	if next != "" { append(&attrs, Bxml_Attr{"nextCamera", next}) }
	append(&attrs,
		Bxml_Attr{"reset", "false"},
		Bxml_Attr{"updateTime", d3_cam_f(hold)},
		Bxml_Attr{"crossFade", "true"},
	)
	return bxml_node("Event", attrs[:], nil, allocator)
}

// `Attempts` is how a restart gets a different intro: one keyframe for the
// first run, one for even retries, one for odd.
@(private = "file")
D3_Cut_Attempt :: enum { First, Even, Odd }

@(private = "file")
d3_cut_condition :: proc(attempt: D3_Cut_Attempt, allocator := context.temp_allocator) -> ^Bxml_Node {
	exact, alternate, even := "false", "true", "false"
	switch attempt {
	case .First: exact, alternate, even = "true", "false", "false"
	case .Even:  even = "true"
	case .Odd:
	}
	return bxml_node("Condition", bxml_attrs(
		{"type", "Attempts"}, {"attempts", "0"},
		{"fireOnAlternate", alternate}, {"fireOnExact", exact}, {"fireOnEven", even},
		allocator = allocator,
	), nil, allocator)
}

@(private = "file")
d3_cut_keyframe :: proc(
	name: string,
	relative_to: string,
	children: []^Bxml_Node, // a Condition then its Event, siblings as in stock
	allocator := context.temp_allocator,
) -> ^Bxml_Node {
	attrs := make([dynamic]Bxml_Attr, allocator)
	append(&attrs, Bxml_Attr{"name", name}, Bxml_Attr{"time", "0.000000"})
	if relative_to == "" {
		append(&attrs, Bxml_Attr{"timeType", "absolute"})
	} else {
		append(&attrs, Bxml_Attr{"timeType", "relative"}, Bxml_Attr{"relativeTo", relative_to})
	}
	return bxml_node("Keyframe", attrs[:], children, allocator)
}

@(private = "file")
d3_cutscene :: proc(keyframes: []^Bxml_Node, allocator: mem.Allocator) -> (data: []u8, ok: bool) {
	timeline := bxml_node("Timeline", nil, keyframes, context.temp_allocator)
	root := bxml_node("Cutscene", nil, {timeline}, context.temp_allocator)
	return bxml_build(root, allocator)
}

// The location card, cutting into the first montage shot.
d3_cutscene_establish :: proc(route: int, allocator := context.allocator) -> (data: []u8, msg: string, ok: bool) {
	establish := fmt.tprintf("establish_camera_r%d", route)
	first := fmt.tprintf("mont_0_camera_r%d", route)
	frames := make([dynamic]^Bxml_Node, context.temp_allocator)
	for attempt, i in ([]D3_Cut_Attempt{.First, .Even, .Odd}) {
		events := make([]^Bxml_Node, 2, context.temp_allocator)
		events[0] = d3_cut_condition(attempt)
		events[1] = d3_cut_event(establish, first, D3_CAMERA_HOLD_S)
		append(&frames, d3_cut_keyframe(fmt.tprintf("KF_EstablishCamera_%d", i), "", events))
	}
	built, built_ok := d3_cutscene(frames[:], allocator)
	if !built_ok { return nil, "could not encode cutscene_establish.xml", false }
	return built, fmt.tprintf("%s into %s", establish, first), true
}

// The montage: each shot holds, then cuts to the next, and the last hands over
// to the service-area camera the title cutscene expects.
d3_cutscene_montage :: proc(route, montage: int, allocator := context.allocator) -> (data: []u8, msg: string, ok: bool) {
	if montage < 1 {
		return nil, "a montage needs at least one camera", false
	}
	frames := make([dynamic]^Bxml_Node, context.temp_allocator)
	for i in 0 ..< montage {
		camera := fmt.tprintf("mont_%d_camera_r%d", i, route)
		next := "relative_service_camera"
		if i+1 < montage { next = fmt.tprintf("mont_%d_camera_r%d", i+1, route) }
		// The first is absolute; the rest chain off the one before, so the
		// montage runs as long as the shots do.
		previous := i == 0 ? "" : fmt.tprintf("KF_MontageCamera%d", i-1)
		events := make([]^Bxml_Node, 2, context.temp_allocator)
		events[0] = d3_cut_condition(.First)
		events[1] = d3_cut_event(camera, next, D3_CAMERA_HOLD_S)
		append(&frames, d3_cut_keyframe(fmt.tprintf("KF_MontageCamera%d", i), previous, events))
	}
	// A retry skips the chain and takes one shot straight to the service area.
	for attempt, i in ([]D3_Cut_Attempt{.Even, .Odd}) {
		events := make([]^Bxml_Node, 2, context.temp_allocator)
		events[0] = d3_cut_condition(attempt)
		events[1] = d3_cut_event(
			fmt.tprintf("mont_%d_camera_r%d", i % montage, route),
			"relative_service_camera", D3_CAMERA_HOLD_S,
		)
		append(&frames, d3_cut_keyframe(fmt.tprintf("KF_MontageRetry%d", i), "", events))
	}
	built, built_ok := d3_cutscene(frames[:], allocator)
	if !built_ok { return nil, "could not encode cutscene_montage.xml", false }
	return built, fmt.tprintf("%d shots", montage), true
}

// --- export ------------------------------------------------------------------

// Shots per route. Three reads as a montage without repeating the same stretch
// of road, and each holds D3_CAMERA_HOLD_S.
D3_MONTAGE_SHOTS :: 3

// `replay_camera_config.xml` and the two cutscenes that name our own cameras.
d3_write_replay_cameras :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	if len(job.Route) < 2 {
		return "replay cameras need a route", false
	}
	line := d3_route_stations(job.Route, context.temp_allocator)

	config, config_msg, config_ok := d3_replay_camera_config(
		line, job.Route_Index, D3_MONTAGE_SHOTS, context.temp_allocator,
	)
	if !config_ok {
		return fmt.tprintf("replay_camera_config.xml: %s", config_msg), false
	}
	establish, establish_msg, establish_ok := d3_cutscene_establish(job.Route_Index, context.temp_allocator)
	if !establish_ok {
		return fmt.tprintf("cutscene_establish.xml: %s", establish_msg), false
	}
	montage, montage_msg, montage_ok := d3_cutscene_montage(
		job.Route_Index, D3_MONTAGE_SHOTS, context.temp_allocator,
	)
	if !montage_ok {
		return fmt.tprintf("cutscene_montage.xml: %s", montage_msg), false
	}

	for file in ([]struct{name: string, data: []u8}{
		{"replay_camera_config.xml", config},
		{"cutscene_establish.xml", establish},
		{"cutscene_montage.xml", montage},
	}) {
		if write_msg, written := d3_write_out(job, file.name, file.data); !written {
			return write_msg, false
		}
	}
	return fmt.tprintf("%s; %s; montage %s", config_msg, establish_msg, montage_msg), true
}

// --- what the kickoff and finish shots must see ------------------------------
//
// Two of the shots frame the car rather than the scenery: the kickoff off the
// grid, and the finish. A tree standing between either camera and its stretch
// of road hides the car outright, so the export culls one out of the other
// (src/app/export.odin). The panning shots are scenery and keep their trees.

// How far outside the wedge a trunk still has to stand.
D3_CAMERA_CLEAR_M :: f32(2)

// The two shots, taken from the picker itself so they cannot drift from what
// gets written. Route index is irrelevant here: it names a shot, never places
// one.
d3_camera_start_finish :: proc(
	route: []Route_Sample,
	allocator := context.temp_allocator,
) -> []D3_Camera_Shot {
	if len(route) < 2 {
		return nil
	}
	line := d3_route_stations(route, context.temp_allocator)
	shots, _, ok := d3_camera_shots(line, 0, 0, context.temp_allocator)
	if !ok {
		return nil
	}
	out := make([dynamic]D3_Camera_Shot, 0, 2, allocator)
	for shot in shots {
		if shot.ident == "start_camera_r0" || shot.ident == "finishlineCam_r0" {
			append(&out, shot)
		}
	}
	return out[:]
}

@(private = "file")
d3_cam_flat :: proc(v: [3]f32) -> [2]f32 { return {v[0], v[2]} }

// Distance from `p` to segment `a`-`b`.
@(private = "file")
d3_cam_seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	ab := [2]f32{b[0]-a[0], b[1]-a[1]}
	ap := [2]f32{p[0]-a[0], p[1]-a[1]}
	square := ab[0]*ab[0] + ab[1]*ab[1]
	t := square <= 0 ? f32(0) : clamp((ap[0]*ab[0] + ap[1]*ab[1])/square, 0, 1)
	dx, dy := ap[0] - ab[0]*t, ap[1] - ab[1]*t
	return math.sqrt(dx*dx + dy*dy)
}

@(private = "file")
d3_cam_turn :: proc(a, b, p: [2]f32) -> f32 {
	return (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0])
}

// Zero inside the triangle, else the distance to its nearest edge.
@(private = "file")
d3_cam_tri_dist :: proc(p, a, b, c: [2]f32) -> f32 {
	ab, bc, ca := d3_cam_turn(a, b, p), d3_cam_turn(b, c, p), d3_cam_turn(c, a, p)
	if (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0) {
		return 0
	}
	return min(d3_cam_seg_dist(p, a, b), d3_cam_seg_dist(p, b, c), d3_cam_seg_dist(p, c, a))
}

// True when a trunk of `radius` at `pos` stands in the ground one of `shots`
// frames: the quad from the camera's own dolly out to the stretch of road it
// looks at, as two triangles. Flat, so a tree of any height counts — the
// cameras sit 5 to 9 metres up and every species we place is taller than that.
d3_camera_blocks :: proc(shots: []D3_Camera_Shot, pos: [3]f32, radius: f32) -> bool {
	p := d3_cam_flat(pos)
	for shot in shots {
		eye, eye_end := d3_cam_flat(shot.eye), d3_cam_flat(shot.eye_end)
		aim, aim_end := d3_cam_flat(shot.aim), d3_cam_flat(shot.aim_end)
		clear := radius + D3_CAMERA_CLEAR_M
		if d3_cam_tri_dist(p, eye, eye_end, aim_end) <= clear { return true }
		if d3_cam_tri_dist(p, eye, aim_end, aim) <= clear { return true }
	}
	return false
}
