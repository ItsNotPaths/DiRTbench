package d3

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"

D3_PROGRESS_GATE_STEP :: f32(70)
D3_PROGRESS_MIN_GATES :: 15
D3_PROGRESS_POINT_STEP :: f32(10.5)
D3_AI_GATE_STEP :: f32(17)
D3_AI_MIN_GATES :: 61 // smallest count in the stock route census
D3_PROGRESS_GATE_WIDTH :: f32(53)
D3_RACING_INSET :: f32(1.4)
// Both fewer and more checkpoints overrun assumptions in the route interpolator.
D3_TIME_SPLITS :: 3

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

d3_ai_xml :: proc(line: []Route_Station, allocator := context.allocator) -> (data: []u8, ok: bool) {
	length:=line[len(line)-1].distance
	distances:=d3_ai_gate_distances(length)
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
	sections:=make([dynamic]^Bxml_Node,context.temp_allocator)
	append(&sections,bxml_node("gates",[]Bxml_Attr{{"num_gates",d3_i(len(gates))}},gates[:]),bxml_node("links",[]Bxml_Attr{{"num_links",d3_i(len(links))}},links[:]))
	empty_sections:=[]string{"brake_lines","hold_lines","min_speed_lines","speed_lines","retire_lines","fork_sets"}
	for name in empty_sections { append(&sections,bxml_node(name,[]Bxml_Attr{{fmt.tprintf("num_%s",name),"0"}})) }
	root:=bxml_node("ai_track_data",[]Bxml_Attr{{"version_major","3"},{"version_minor","0"},{"version_revision","2"}},[]^Bxml_Node{bxml_node("track",[]Bxml_Attr{{"name","default"}},sections[:])})
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
	progress,pok:=d3_progress_xml(line,job.Markers); if !pok { return "could not encode progress_track.xml",false }
	ai,aok:=d3_ai_xml(line); if !aok { delete(progress); return "could not encode ai_track.xml",false }
	overrides,ook:=d3_route_overrides_build(line[len(line)-1].distance); if !ook { delete(progress); delete(ai); return "could not encode route_overrides.xml",false }
	defer delete(progress); defer delete(ai); defer delete(overrides)
	if write_msg,written:=d3_write_out(job,"progress_track.xml",progress); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"ai_track.xml",ai); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"route_overrides.xml",overrides); !written { return write_msg,false }
	return fmt.tprintf(
		"route data: %d progress gates, %d AI gates",
		len(d3_progress_gate_distances(line[len(line)-1].distance)),
		len(d3_ai_gate_distances(line[len(line)-1].distance)),
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
