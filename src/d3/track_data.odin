package d3

import "core:fmt"
import "core:math"

D3_PROGRESS_GATE_STEP :: f32(70)
D3_PROGRESS_MIN_GATES :: 15
D3_PROGRESS_POINT_STEP :: f32(10.5)
D3_AI_GATE_STEP :: f32(17)
D3_AI_MIN_GATES :: 61 // smallest count in the stock route census
D3_PROGRESS_GATE_WIDTH :: f32(53)
D3_RACING_INSET :: f32(1.4)
// Both fewer and more checkpoints overrun assumptions in the route interpolator.
D3_TIME_SPLITS :: 3

// One brake line per corner, sized off the corner radius. Stock fits
// `max_speed = grip * sqrt(radius)` with a ceiling, measured over all 95 stock
// routes; everything else in a brake_data record is a constant there.
D3_BRAKE_GRIP :: f32(4.7)
D3_BRAKE_SPEED_CAP :: f32(80)
D3_BRAKE_RADIUS_CUT :: f32(250)
D3_BRAKE_MERGE :: f32(60)
D3_BRAKE_STEP :: f32(8)
D3_BRAKE_SPAN :: f32(17)
D3_BRAKE_MIN_SPEED_DROP :: f32(0.6)
// ai_vehicle_track.xml puts drift_speed this far under max_speed.
D3_BRAKE_DRIFT_DROP :: f32(5)

Route_Station :: struct {
	distance: f32,
	centre, left, right: [3]f32,
}

d3_dist :: proc(a, b: [3]f32) -> f32 {
	dx, dy, dz := b[0]-a[0], b[1]-a[1], b[2]-a[2]
	return math.sqrt(dx*dx+dy*dy+dz*dz)
}

d3_route_stations :: proc(route: []Route_Sample, allocator := context.temp_allocator) -> []Route_Station {
	out := make([]Route_Station, len(route), allocator)
	for sample, i in route {
		out[i] = {centre=sample.Centre, left=sample.Left, right=sample.Right}
		if i > 0 { out[i].distance = out[i-1].distance+d3_dist(route[i-1].Centre, sample.Centre) }
	}
	return out
}

d3_lerp3 :: proc(a, b: [3]f32, t: f32) -> [3]f32 {
	return {a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t, a[2]+(b[2]-a[2])*t}
}

d3_station_at :: proc(line: []Route_Station, distance: f32) -> Route_Station {
	if distance <= 0 { return line[0] }
	if distance >= line[len(line)-1].distance { return line[len(line)-1] }
	for i in 1..<len(line) {
		if distance <= line[i].distance {
			a, b := line[i-1], line[i]
			span := b.distance-a.distance
			t := span > 0 ? (distance-a.distance)/span : 0
			return {distance=distance, centre=d3_lerp3(a.centre,b.centre,t), left=d3_lerp3(a.left,b.left,t), right=d3_lerp3(a.right,b.right,t)}
		}
	}
	return line[len(line)-1]
}

d3_even_distances :: proc(length, step: f32, allocator := context.temp_allocator) -> []f32 {
	count := max(2, int(math.round(length/step))+1)
	out := make([]f32, count, allocator)
	for i in 0..<count { out[i] = length*f32(i)/f32(count-1) }
	return out
}

// The engine's route interpolator assumes at least the smallest gate count
// seen in stock data, even when the physical route is much shorter than the
// usual 17 m sampling interval.
d3_ai_gate_distances :: proc(length: f32, allocator := context.temp_allocator) -> []f32 {
	step := min(D3_AI_GATE_STEP, length/f32(D3_AI_MIN_GATES-1))
	return d3_even_distances(length, step, allocator)
}

d3_f3 :: proc(v: [3]f32) -> string { return fmt.tprintf("%.2f %.2f %.2f", v[0],v[1],v[2]) }
d3_f5 :: proc(v: f32) -> string { return fmt.tprintf("%.5g", v) }
d3_i :: proc(v: int) -> string { return fmt.tprintf("%d",v) }

d3_across :: proc(s: Route_Station, offset: f32) -> [3]f32 {
	dx, dz := s.right[0]-s.left[0], s.right[2]-s.left[2]
	length := math.sqrt(dx*dx+dz*dz)
	if length < 1e-6 { return s.centre }
	return {s.centre[0]+dx/length*offset, s.centre[1], s.centre[2]+dz/length*offset}
}

d3_progress_gate_distances :: proc(length:f32) -> []f32 {
	// Split markers map onto this uniform sampling; they are not extra gates.
	step := min(D3_PROGRESS_GATE_STEP, length/f32(D3_PROGRESS_MIN_GATES-1))
	return d3_even_distances(length,step)
}

d3_nearest_gate :: proc(gates: []f32, distance: f32) -> int {
	nearest := 0
	best := math.abs(gates[0]-distance)
	for gate, i in gates[1:] {
		if delta := math.abs(gate-distance); delta < best {
			nearest = i+1
			best = delta
		}
	}
	return nearest
}

Brake_Point :: struct {
	gate:  int,
	speed: f32,
}

d3_dist_flat :: proc(a, b: [3]f32) -> f32 {
	dx, dz := b[0]-a[0], b[2]-a[2]
	return math.sqrt(dx*dx+dz*dz)
}

// Radius of the circle through three centre-line points `span` apart. Our
// racing line is the centre line, so this is the radius the AI drives.
d3_corner_radius :: proc(line: []Route_Station, distance, span: f32) -> f32 {
	a := d3_station_at(line, distance-span).centre
	b := d3_station_at(line, distance).centre
	c := d3_station_at(line, distance+span).centre
	area2 := math.abs((b[0]-a[0])*(c[2]-a[2])-(b[2]-a[2])*(c[0]-a[0]))
	ab, bc, ac := d3_dist_flat(a,b), d3_dist_flat(b,c), d3_dist_flat(a,c)
	if area2 < 1e-6 || ab < 1e-6 || bc < 1e-6 { return max(f32) }
	return ab*bc*ac/(2*area2)
}

d3_brake_speed :: proc(radius: f32) -> f32 {
	return min(D3_BRAKE_SPEED_CAP, D3_BRAKE_GRIP*math.sqrt(radius))
}

// One brake point per corner: local minima of the radius, thinned so no two sit
// closer than the merge distance, then snapped onto the AI gates. The last gate
// is skipped because every brake line needs a hold line on the gate after it.
d3_brake_points :: proc(line: []Route_Station, gates: []f32, allocator := context.temp_allocator) -> []Brake_Point {
	length := line[len(line)-1].distance
	if length <= 2*D3_BRAKE_SPAN { return nil }
	count := int((length-2*D3_BRAKE_SPAN)/D3_BRAKE_STEP)+1
	radii := make([]f32, count, context.temp_allocator)
	for i in 0..<count { radii[i] = d3_corner_radius(line, D3_BRAKE_SPAN+f32(i)*D3_BRAKE_STEP, D3_BRAKE_SPAN) }
	minima := make([dynamic]int, context.temp_allocator)
	for i in 1..<count-1 {
		// Not strict on either side, so a constant-radius sweeper still counts
		// as a corner instead of falling through as a plateau.
		if radii[i] >= D3_BRAKE_RADIUS_CUT || radii[i] > radii[i-1] || radii[i] > radii[i+1] { continue }
		if n := len(minima); n > 0 && f32(i-minima[n-1])*D3_BRAKE_STEP < D3_BRAKE_MERGE {
			if radii[i] < radii[minima[n-1]] { minima[n-1] = i }
			continue
		}
		append(&minima, i)
	}
	out := make([dynamic]Brake_Point, allocator)
	for at in minima {
		gate := d3_nearest_gate(gates, D3_BRAKE_SPAN+f32(at)*D3_BRAKE_STEP)
		if gate >= len(gates)-1 { continue }
		if n := len(out); n > 0 && out[n-1].gate >= gate { continue }
		append(&out, Brake_Point{gate=gate, speed=d3_brake_speed(radii[at])})
	}
	return out[:]
}

d3_progress_xml :: proc(line: []Route_Station, markers:[]Progress_Marker, allocator := context.allocator) -> (data: []u8, ok: bool) {
	length := line[len(line)-1].distance
	gate_d:=d3_progress_gate_distances(length)
	point_d := d3_even_distances(length,D3_PROGRESS_POINT_STEP)
	if len(gate_d)<4 { return nil,false }
	gates := make([dynamic]^Bxml_Node,context.temp_allocator)
	for distance,i in gate_d {
		s:=d3_station_at(line,distance); half:=D3_PROGRESS_GATE_WIDTH/2
		append(&gates,bxml_node("gate",[]Bxml_Attr{{"id",d3_i(i)},{"distance",d3_f5(distance)}},[]^Bxml_Node{
			bxml_text("left",d3_f3(d3_across(s,-half)),[]Bxml_Attr{{"format","float3"}}),
			bxml_text("right",d3_f3(d3_across(s,half)),[]Bxml_Attr{{"format","float3"}}),
		}))
	}
	points:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for distance,i in point_d { s:=d3_station_at(line,distance); append(&points,bxml_node("point",[]Bxml_Attr{{"id",d3_i(i)},{"distance",d3_f5(distance)}},[]^Bxml_Node{bxml_text("position",d3_f3(s.centre),[]Bxml_Attr{{"format","float3"}})})) }
	splits:=make([dynamic]^Bxml_Node,context.temp_allocator)
	previous_gate := -1
	for marker,i in markers {
		gate := d3_nearest_gate(gate_d, marker.Distance)
		if gate <= previous_gate { return nil, false }
		previous_gate = gate
		kind:="time"
		if marker.Kind==.Start { kind="start" } else if marker.Kind==.Finish { kind="finish_absolute" }
		append(&splits,bxml_node("split",[]Bxml_Attr{{"id",d3_i(i)},{"type",kind},{"gate",d3_i(gate)}}))
	}
	root:=bxml_node("progress_track_data",[]Bxml_Attr{{"exporter_version","3.0.0"}},[]^Bxml_Node{
		bxml_node("track",[]Bxml_Attr{{"type","point_to_point"},{"total_distance",d3_f5(length)}}),
		bxml_node("routes",[]Bxml_Attr{{"num_routes","1"}},[]^Bxml_Node{bxml_node("route",[]Bxml_Attr{{"id","0"},{"direction","forwards"},{"num_splits",d3_i(len(splits))}},splits[:])}),
		bxml_node("gates",[]Bxml_Attr{{"num_gates",d3_i(len(gates))}},gates[:]),
		bxml_node("points",[]Bxml_Attr{{"num_lines","1"}},[]^Bxml_Node{bxml_node("line",[]Bxml_Attr{{"name","progress_centre_line_0"},{"type","progress"},{"num_points",d3_i(len(points))}},points[:])}),
	})
	return bxml_build(root,allocator)
}

d3_ai_xml :: proc(line: []Route_Station, distances: []f32, brakes: []Brake_Point, allocator := context.allocator) -> (data: []u8, ok: bool) {
	gates:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for distance,i in distances {
		s:=d3_station_at(line,distance)
		dx,dz:=s.right[0]-s.left[0],s.right[2]-s.left[2]
		width:=math.sqrt(dx*dx+dz*dz)
		inset:=min(D3_RACING_INSET,width/4)
		waypoints:=[]^Bxml_Node{
			bxml_node("waypoint",[]Bxml_Attr{{"id","0"},{"type","left_track_limit"},{"length","0.00"}}),
			bxml_node("waypoint",[]Bxml_Attr{{"id","1"},{"type","left_racing_limit"},{"length",fmt.tprintf("%.2f",inset)}}),
			bxml_node("waypoint",[]Bxml_Attr{{"id","2"},{"type","racing_line"},{"length",fmt.tprintf("%.2f",width/2)}},[]^Bxml_Node{bxml_node("racing_line",[]Bxml_Attr{{"type","optimal"}})}),
			bxml_node("waypoint",[]Bxml_Attr{{"id","3"},{"type","right_racing_limit"},{"length",fmt.tprintf("%.2f",width-inset)}}),
			bxml_node("waypoint",[]Bxml_Attr{{"id","4"},{"type","right_track_limit"},{"length",fmt.tprintf("%.2f",width)}}),
			bxml_node("waypoint",[]Bxml_Attr{{"id","5"},{"type","racing_line"},{"length",fmt.tprintf("%.2f",width/2)}},[]^Bxml_Node{bxml_node("racing_line",[]Bxml_Attr{{"type","visual"}})}),
		}
		append(&gates,bxml_node("gate",[]Bxml_Attr{{"id",d3_i(i)}},[]^Bxml_Node{
			bxml_text("position",d3_f3(s.left),[]Bxml_Attr{{"format","float3"}}),
			bxml_text("normal",fmt.tprintf("%.6f 0.0 %.6f",dx/width,dz/width),[]Bxml_Attr{{"format","float3"}}),
			bxml_node("waypoints",[]Bxml_Attr{{"num_waypoints","6"}},waypoints),
		}))
	}
	links:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for i in 0..<len(gates)-1 { append(&links,bxml_node("link",[]Bxml_Attr{{"id",d3_i(i)},{"from_gate",d3_i(i)},{"to_gate",d3_i(i+1)}})) }
	brake_lines:=make([dynamic]^Bxml_Node,context.temp_allocator)
	hold_lines:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for brake,i in brakes {
		speed:=fmt.tprintf("%.2f",brake.speed)
		append(&brake_lines,bxml_node("brake_line",[]Bxml_Attr{{"id",d3_i(i*10)},{"gate_id",d3_i(brake.gate)}},[]^Bxml_Node{
			bxml_node("brake_data",[]Bxml_Attr{
				{"type","normal"},
				{"min_speed",fmt.tprintf("%.2f",brake.speed*D3_BRAKE_MIN_SPEED_DROP)},
				{"min_speed_drop",fmt.tprintf("%.2f",D3_BRAKE_MIN_SPEED_DROP)},
				{"max_speed",speed},{"max_speed_left",speed},{"max_speed_right",speed},
				{"hold_line_id",d3_i(i)},
				{"hold_distance_modifier","0.00"},
				{"distance_modifier","1.00"},
				{"brake_cruise_ratio","1.10"},
				{"curve_modifier","1.00"},{"curve_modifier_left","1.00"},{"curve_modifier_right","1.00"},
			}),
		}))
		append(&hold_lines,bxml_node("hold_line",[]Bxml_Attr{{"id",d3_i(i)},{"gate_id",d3_i(brake.gate+1)},{"brakeline_id",d3_i(i*10)}}))
	}
	sections:=make([dynamic]^Bxml_Node,context.temp_allocator)
	append(&sections,
		bxml_node("gates",[]Bxml_Attr{{"num_gates",d3_i(len(gates))}},gates[:]),
		bxml_node("links",[]Bxml_Attr{{"num_links",d3_i(len(links))}},links[:]),
		bxml_node("brake_lines",[]Bxml_Attr{{"num_brake_lines",d3_i(len(brake_lines))}},brake_lines[:]),
		bxml_node("hold_lines",[]Bxml_Attr{{"num_hold_lines",d3_i(len(hold_lines))}},hold_lines[:]),
	)
	empty_sections:=[]string{"min_speed_lines","speed_lines","retire_lines","fork_sets"}
	for name in empty_sections { append(&sections,bxml_node(name,[]Bxml_Attr{{fmt.tprintf("num_%s",name),"0"}})) }
	root:=bxml_node("ai_track_data",[]Bxml_Attr{{"version_major","3"},{"version_minor","0"},{"version_revision","2"}},[]^Bxml_Node{bxml_node("track",[]Bxml_Attr{{"name","default"}},sections[:])})
	return bxml_build(root,allocator)
}

// Per-class AI tuning, which stock pairs with ai_track.xml by brake-line id.
// The numbers are the same corner speeds; the per-class hand tuning stock puts
// in curve_modifier we leave at 1.
d3_ai_vehicle_xml :: proc(brakes: []Brake_Point, allocator := context.allocator) -> (data: []u8, ok: bool) {
	names:=[]string{
		"default","landrush_buggie","landrush_trucks","raid_t1",
		"rally_60s","rally_70s","rally_80s","rally_90s","rally_cross",
		"rally_groupb","rally_open","rally_s2000","rally_wrc",
		"trailblazer","trailblazer_cla",
	}
	types:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for name in names {
		lines:=make([dynamic]^Bxml_Node,context.temp_allocator)
		for brake,i in brakes {
			speed:=fmt.tprintf("%.2f",brake.speed)
			append(&lines,bxml_node("brake_line",[]Bxml_Attr{{"id",d3_i(i*10)}},[]^Bxml_Node{
				bxml_node("brake_data",[]Bxml_Attr{
					{"type","curve"},
					{"min_speed",fmt.tprintf("%.2f",brake.speed*D3_BRAKE_MIN_SPEED_DROP)},
					{"min_speed_drop",fmt.tprintf("%.2f",D3_BRAKE_MIN_SPEED_DROP)},
					{"max_speed",speed},{"max_speed_left",speed},{"max_speed_right",speed},
					{"drift_speed",fmt.tprintf("%.2f",max(0,brake.speed-D3_BRAKE_DRIFT_DROP))},
					{"distance_modifier","1.00"},
					{"brake_cruise_ratio","1.10"},
					{"hold_time","0.00"},
					{"curve_modifier","1.00"},{"curve_modifier_left","1.00"},{"curve_modifier_right","1.00"},
				}),
			}))
		}
		append(&types,bxml_node("vehicle_type",[]Bxml_Attr{{"name",name}},[]^Bxml_Node{
			bxml_node("brake_lines",[]Bxml_Attr{{"num_brake_lines",d3_i(len(lines))}},lines[:]),
		}))
	}
	root:=bxml_node("vehicle_type_track_data",[]Bxml_Attr{{"version_major","3"},{"version_minor","0"},{"version_revision","0"}},[]^Bxml_Node{
		bxml_node("vehicle_track",[]Bxml_Attr{{"name","default"}},[]^Bxml_Node{bxml_node("vehicle_types",nil,types[:])}),
	})
	return bxml_build(root,allocator)
}

d3_validate_route :: proc(route:[]Route_Sample) -> (msg:string,ok:bool) {
	if len(route)<2 { return "Dirt 3 export needs at least two route samples",false }
	for sample,i in route {
		if d3_dist(sample.Left,sample.Right)<0.1 { return fmt.tprintf("Dirt 3 route sample %d has no width",i),false }
		dx, dz := sample.Right[0]-sample.Left[0], sample.Right[2]-sample.Left[2]
		if dx*dx+dz*dz < 0.01 {
			return fmt.tprintf("Dirt 3 route sample %d has no horizontal width",i),false
		}
		points := [3][3]f32{sample.Centre,sample.Left,sample.Right}
		for point in points {
			for value in point { if value!=value || math.abs(value)>3.4028234e38 { return fmt.tprintf("Dirt 3 route sample %d is not finite",i),false } }
		}
	}
	return "",true
}

d3_validate_markers :: proc(markers:[]Progress_Marker,length:f32) -> (msg:string,ok:bool) {
	if len(markers)<2 || markers[0].Kind!=.Start || markers[len(markers)-1].Kind!=.Finish {
		return "Dirt 3 progress markers need one start and one finish",false
	}
	if markers[0].Distance <= 0 || markers[len(markers)-1].Distance >= length {
		return "Dirt 3 progress markers need road before the start and after the finish",false
	}
	previous:f32=-1
	for marker,i in markers {
		if marker.Distance<0 || marker.Distance>length || marker.Distance<=previous { return fmt.tprintf("Dirt 3 progress marker %d is out of order",i),false }
		if i>0 && i<len(markers)-1 && marker.Kind!=.Checkpoint { return fmt.tprintf("Dirt 3 progress marker %d is not a checkpoint",i),false }
		previous=marker.Distance
	}
	if checkpoints:=len(markers)-2; checkpoints!=D3_TIME_SPLITS {
		return fmt.tprintf("Dirt 3 needs exactly %d checkpoints; this stage has %d",D3_TIME_SPLITS,checkpoints),false
	}
	return "",true
}

d3_write_track_data :: proc(job:^Export_Job) -> (msg:string,ok:bool) {
	if validation,valid:=d3_validate_route(job.Route); !valid { return validation,false }
	line:=d3_route_stations(job.Route)
	if line[len(line)-1].distance<1 { return "Dirt 3 export route is shorter than one metre",false }
	if validation,valid:=d3_validate_markers(job.Markers,line[len(line)-1].distance); !valid { return validation,false }
	if _,dir_msg,dir_ok:=d3_out_dir(job); !dir_ok { return dir_msg,false }
	// A progress track needs at least four gates, so a stage shorter than a few
	// gate steps cannot make one. Say that, rather than "could not encode".
	length:=line[len(line)-1].distance
	if gates:=d3_progress_gate_distances(length); len(gates)<4 {
		return fmt.tprintf("the stage is %.0f m long and yields %d progress gates; Dirt 3 needs at least 4",length,len(gates)),false
	}
	ai_gates:=d3_ai_gate_distances(length)
	brakes:=d3_brake_points(line,ai_gates)
	progress,pok:=d3_progress_xml(line,job.Markers); if !pok { return "could not encode progress_track.xml",false }
	defer delete(progress)
	ai,aok:=d3_ai_xml(line,ai_gates,brakes); if !aok { return "could not encode ai_track.xml",false }
	defer delete(ai)
	vehicle,vok:=d3_ai_vehicle_xml(brakes); if !vok { return "could not encode ai_vehicle_track.xml",false }
	defer delete(vehicle)
	overrides,ook:=d3_route_overrides_build(length); if !ook { return "could not encode route_overrides.xml",false }
	defer delete(overrides)
	if write_msg,written:=d3_write_out(job,"progress_track.xml",progress); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"ai_track.xml",ai); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"ai_vehicle_track.xml",vehicle); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"route_overrides.xml",overrides); !written { return write_msg,false }
	return fmt.tprintf(
		"route data: %d progress gates, %d AI gates, %d brake lines",
		len(d3_progress_gate_distances(length)),
		len(ai_gates),
		len(brakes),
	),true
}

// Distance bands over this route, in the shape stock route_overrides.xml
// uses: one block per range plus a Systems row. A short debug route gets a
// single block; the cull values copy stock block0, the one whose range our
// whole route fits inside.
d3_route_overrides_build :: proc(length: f32, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if length < 1 { return nil, false }
	block := bxml_node("block0", []Bxml_Attr{
		{"start", "-4.5"}, {"end", d3_f5(length)},
		{"world_cull_dist", "1000.0"}, {"track_cull_dist", "530.0"},
		{"track_lod_dist", "160.0"}, {"shadow_dist", "80.0"},
		{"envmap_cull_dist", "50"}, {"main_obj_size", "0.01"},
		{"shadow_obj_size", "0.05"}, {"refmap_obj_size", "0.3"},
		{"fade", "20.0"},
	})
	systems := bxml_node("Systems", []Bxml_Attr{
		{"tree_settings", "medium"}, {"ornament_settings", "low"},
	})
	root := bxml_node("route", nil, []^Bxml_Node{block, systems})
	return bxml_build(root, allocator)
}
