package d3

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"

D3_PROGRESS_GATE_STEP :: f32(70)
D3_PROGRESS_POINT_STEP :: f32(10.5)
D3_AI_GATE_STEP :: f32(17)
D3_PROGRESS_GATE_WIDTH :: f32(53)
D3_RACING_INSET :: f32(1.4)
// Stock routes never ship more than 4 timed sections, and steerAssistData.xml
// holds exactly split_0..split_3.  A 5th section overruns that array.
D3_MAX_TIME_SPLITS :: 3

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

d3_f3 :: proc(v: [3]f32) -> string { return fmt.tprintf("%.2f %.2f %.2f", v[0],v[1],v[2]) }
d3_f5 :: proc(v: f32) -> string { return fmt.tprintf("%.5g", v) }
d3_i :: proc(v: int) -> string { return fmt.tprintf("%d",v) }

d3_across :: proc(s: Route_Station, offset: f32) -> [3]f32 {
	dx, dz := s.right[0]-s.left[0], s.right[2]-s.left[2]
	length := math.sqrt(dx*dx+dz*dz)
	if length < 1e-6 { return s.centre }
	return {s.centre[0]+dx/length*offset, s.centre[1], s.centre[2]+dz/length*offset}
}

d3_progress_gate_distances :: proc(length:f32,markers:[]Progress_Marker) -> []f32 {
	regular := d3_even_distances(length,D3_PROGRESS_GATE_STEP)
	gate_list:=make([dynamic]f32,context.temp_allocator)
	append(&gate_list,..regular)
	for marker in markers { append(&gate_list,marker.Distance) }
	slice.sort_by(gate_list[:],proc(a,b:f32)->bool{return a<b})
	out:=make([dynamic]f32,context.temp_allocator)
	for distance in gate_list { if len(out)==0 || math.abs(distance-out[len(out)-1])>0.001 { append(&out,distance) } }
	return out[:]
}

d3_progress_xml :: proc(line: []Route_Station, markers:[]Progress_Marker, allocator := context.allocator) -> (data: []u8, ok: bool) {
	length := line[len(line)-1].distance
	gate_d:=d3_progress_gate_distances(length,markers)
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
	for marker,i in markers {
		gate:=0
		for distance,j in gate_d { if math.abs(distance-marker.Distance)<0.001 { gate=j; break } }
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
	length:=line[len(line)-1].distance; distances:=d3_even_distances(length,D3_AI_GATE_STEP)
	gates:=make([dynamic]^Bxml_Node,context.temp_allocator)
	for distance,i in distances {
		s:=d3_station_at(line,distance); width:=d3_dist(s.left,s.right); inset:=min(D3_RACING_INSET,width/4)
		dx,dz:=s.right[0]-s.left[0],s.right[2]-s.left[2]; n:=math.sqrt(dx*dx+dz*dz)
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
			bxml_text("normal",fmt.tprintf("%.6f 0.0 %.6f",dx/n,dz/n),[]Bxml_Attr{{"format","float3"}}),
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
	previous:f32=-1
	for marker,i in markers {
		if marker.Distance<0 || marker.Distance>length || marker.Distance<=previous { return fmt.tprintf("Dirt 3 progress marker %d is out of order",i),false }
		if i>0 && i<len(markers)-1 && marker.Kind!=.Checkpoint { return fmt.tprintf("Dirt 3 progress marker %d is not a checkpoint",i),false }
		previous=marker.Distance
	}
	if checkpoints:=len(markers)-2; checkpoints>D3_MAX_TIME_SPLITS {
		return fmt.tprintf("Dirt 3 holds at most %d checkpoints, which is %d timed sections; this stage has %d",D3_MAX_TIME_SPLITS,D3_MAX_TIME_SPLITS+1,checkpoints),false
	}
	return "",true
}

d3_write_track_data :: proc(job:^Export_Job) -> (msg:string,ok:bool) {
	if validation,valid:=d3_validate_route(job.Route); !valid { return validation,false }
	line:=d3_route_stations(job.Route)
	if line[len(line)-1].distance<1 { return "Dirt 3 export route is shorter than one metre",false }
	if validation,valid:=d3_validate_markers(job.Markers,line[len(line)-1].distance); !valid { return validation,false }
	if _,dir_msg,dir_ok:=d3_out_dir(job); !dir_ok { return dir_msg,false }
	progress,pok:=d3_progress_xml(line,job.Markers); if !pok { return "could not encode progress_track.xml",false }
	ai,aok:=d3_ai_xml(line); if !aok { delete(progress); return "could not encode ai_track.xml",false }
	defer delete(progress); defer delete(ai)
	if write_msg,written:=d3_write_out(job,"progress_track.xml",progress); !written { return write_msg,false }
	if write_msg,written:=d3_write_out(job,"ai_track.xml",ai); !written { return write_msg,false }
	return fmt.tprintf("route data: %d progress gates, %d AI gates",len(d3_progress_gate_distances(line[len(line)-1].distance,job.Markers)),len(d3_even_distances(line[len(line)-1].distance,D3_AI_GATE_STEP))),true
}
