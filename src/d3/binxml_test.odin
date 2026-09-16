package d3

import "core:testing"

test_le_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at])|u32(data[at+1])<<8|u32(data[at+2])<<16|u32(data[at+3])<<24
}

test_bxml_string :: proc(data:[]u8,at,end:int) -> string {
	for i in at..<end { if data[i]==0 { return string(data[at:i]) } }
	return ""
}

test_bxml_attr :: proc(data:[]u8,element_name,attr_name:string) -> string {
	strings_at:=24
	strings_end:=strings_at+int(test_le_u32(data,20))
	offsets_at:=strings_end+8
	string_count:=int(test_le_u32(data,strings_end+4))/4
	strings:=make([]string,string_count,context.temp_allocator)
	for i in 0..<string_count {
		at:=strings_at+int(test_le_u32(data,offsets_at+i*4))
		strings[i]=test_bxml_string(data,at,strings_end)
	}
	elements_header:=offsets_at+string_count*4
	elements_at:=elements_header+8
	element_count:=int(test_le_u32(data,elements_header+4))/24
	attrs_header:=elements_at+element_count*24
	attrs_at:=attrs_header+8
	for i in 0..<element_count {
		record:=elements_at+i*24
		if strings[test_le_u32(data,record)]!=element_name { continue }
		count:=int(test_le_u32(data,record+8)); first:=int(test_le_u32(data,record+12))
		for j in 0..<count {
			pair:=attrs_at+(first+j)*8
			if strings[test_le_u32(data,pair)]==attr_name { return strings[test_le_u32(data,pair+4)] }
		}
	}
	return ""
}

@(test)
binxml_nodes_own_slice_literal_storage :: proc(t:^testing.T) {
	attrs:=[]Bxml_Attr{{"id","first"}}
	children:=[]^Bxml_Node{bxml_node("first_child")}
	n:=bxml_node("node",attrs,children)
	attrs[0]={"id","changed"}
	children[0]=bxml_node("changed_child")
	testing.expect_value(t,n.attrs[0].value,"first")
	testing.expect_value(t,n.children[0].name,"first_child")
}

@(test)
binxml_writes_section_sizes_and_sibling_first_layout :: proc(t:^testing.T) {
	root:=bxml_node("root",[]Bxml_Attr{{"version","1"}},[]^Bxml_Node{
		bxml_node("first",nil,[]^Bxml_Node{bxml_text("value","hello")}),
		bxml_node("second"),
	})
	data,ok:=bxml_build(root,context.temp_allocator)
	testing.expect(t,ok)
	testing.expect_value(t,test_le_u32(data,0),BXML_FILE)
	testing.expect_value(t,int(test_le_u32(data,4)),len(data)-8)
	testing.expect_value(t,test_le_u32(data,8),BXML_TABLE)
	testing.expect_value(t,test_le_u32(data,16),BXML_STRINGS)

	strings_end:=24+int(test_le_u32(data,20))
	testing.expect_value(t,test_le_u32(data,strings_end),BXML_OFFSETS)
	offsets_end:=strings_end+8+int(test_le_u32(data,strings_end+4))
	testing.expect_value(t,test_le_u32(data,offsets_end),BXML_ELEMENTS)
	records:=offsets_end+8
	// Root reserves both direct children before laying out first's descendant.
	testing.expect_value(t,test_le_u32(data,records+16),u32(2))
	testing.expect_value(t,test_le_u32(data,records+20),u32(1))
	testing.expect_value(t,test_le_u32(data,records+24+20),u32(3))
	attributes:=records+int(test_le_u32(data,offsets_end+4))
	testing.expect_value(t,test_le_u32(data,attributes),BXML_ATTRIBUTES)
}

@(test)
binxml_rejects_mixed_text_and_children :: proc(t:^testing.T) {
	n:=bxml_text("bad","text")
	n.children=[]^Bxml_Node{bxml_node("child")}
	data,ok:=bxml_build(n,context.temp_allocator)
	testing.expect(t,!ok)
	testing.expect_value(t,len(data),0)
}

@(test)
dirt3_track_generators_accept_a_real_polyline :: proc(t:^testing.T) {
	route:=[]Route_Sample{
		{Centre={0,2,0},Left={-4,2,0},Right={4,2,0}},
		{Centre={0,2,200},Left={-4,2,200},Right={4,2,200}},
		{Centre={100,4,400},Left={96,4,400},Right={104,4,400}},
	}
	line:=d3_route_stations(route)
	markers:=[]Progress_Marker{{.Start,50},{.Checkpoint,160},{.Checkpoint,270},{.Finish,370}}
	progress,pok:=d3_progress_xml(line,markers,context.temp_allocator)
	ai,aok:=d3_ai_xml(line,context.temp_allocator)
	testing.expect(t,pok); testing.expect(t,aok)
	testing.expect_value(t,test_le_u32(progress,0),BXML_FILE)
	testing.expect_value(t,test_le_u32(ai,0),BXML_FILE)
	testing.expect_value(t,test_bxml_attr(progress,"gates","num_gates"),"15")
	testing.expect_value(t,test_bxml_attr(progress,"line","num_points"),"41")
	// The engine's route interpolator assumes the stock minimum density even
	// for short stages; fewer gates throws "invalid vector<T> subscript".
	testing.expect_value(t,test_bxml_attr(ai,"gates","num_gates"),"61")
	testing.expect_value(t,test_bxml_attr(ai,"links","num_links"),"60")
	testing.expect_value(t,test_bxml_attr(ai,"brake_lines","num_brake_lines"),"0")
	// Resampling includes both endpoints exactly.
	testing.expect_value(t,d3_station_at(line,0).centre,route[0].Centre)
	testing.expect_value(t,d3_station_at(line,line[len(line)-1].distance).centre,route[len(route)-1].Centre)
}

@(test)
dirt3_route_overrides_cover_the_route :: proc(t:^testing.T) {
	data,ok:=d3_route_overrides_build(261,context.temp_allocator)
	testing.expect(t,ok)
	testing.expect_value(t,test_le_u32(data,0),BXML_FILE)
	testing.expect_value(t,test_bxml_attr(data,"block0","start"),"-4.5")
	testing.expect_value(t,test_bxml_attr(data,"block0","end"),"261")
	testing.expect_value(t,test_bxml_attr(data,"Systems","tree_settings"),"medium")
	_,bad:=d3_route_overrides_build(0,context.temp_allocator)
	testing.expect(t,!bad)
}

@(test)
dirt3_progress_requires_exactly_three_time_splits :: proc(t:^testing.T) {
	two:=[]Progress_Marker{{.Start,50},{.Checkpoint,150},{.Checkpoint,250},{.Finish,330}}
	three:=[]Progress_Marker{{.Start,50},{.Checkpoint,120},{.Checkpoint,190},{.Checkpoint,260},{.Finish,330}}
	four:=[]Progress_Marker{{.Start,50},{.Checkpoint,110},{.Checkpoint,170},{.Checkpoint,230},{.Checkpoint,290},{.Finish,350}}
	// The route interpolator requires exactly three intermediate splits.
	msg2,bad2:=d3_validate_markers(two,400); testing.expect(t,!bad2); testing.expect(t,len(msg2)>0)
	_,ok:=d3_validate_markers(three,400); testing.expect(t,ok)
	msg4,bad4:=d3_validate_markers(four,400); testing.expect(t,!bad4); testing.expect(t,len(msg4)>0)
}

@(test)
dirt3_progress_rejects_splits_that_share_a_gate :: proc(t: ^testing.T) {
	route := []Route_Sample{
		{Centre={0,0,0}, Left={4,0,0}, Right={-4,0,0}},
		{Centre={0,0,400}, Left={4,0,400}, Right={-4,0,400}},
	}
	line := d3_route_stations(route)
	markers := []Progress_Marker{
		{.Start,50}, {.Checkpoint,51}, {.Checkpoint,200}, {.Checkpoint,300}, {.Finish,350},
	}
	data, ok := d3_progress_xml(line, markers, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, len(data), 0)
}

@(test)
dirt3_progress_requires_start_and_finish_buffers :: proc(t: ^testing.T) {
	start_at_origin := []Progress_Marker{{.Start,0},{.Finish,90}}
	finish_at_end := []Progress_Marker{{.Start,10},{.Finish,100}}
	_, start_ok := d3_validate_markers(start_at_origin, 100)
	_, finish_ok := d3_validate_markers(finish_at_end, 100)
	testing.expect(t, !start_ok)
	testing.expect(t, !finish_ok)
}

@(test)
dirt3_route_rejects_vertical_ai_cross_section :: proc(t: ^testing.T) {
	route := []Route_Sample{
		{Centre={0,0,0}, Left={0,-1,0}, Right={0,1,0}},
		{Centre={0,0,10}, Left={0,-1,10}, Right={0,1,10}},
	}
	msg, ok := d3_validate_route(route)
	testing.expect(t, !ok)
	testing.expect(t, len(msg) > 0)
}
