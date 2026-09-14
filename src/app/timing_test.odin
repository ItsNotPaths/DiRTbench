package main

import "core:testing"
import "../geo"

@(test)
timing_markers_apply_count_and_buffer :: proc(t:^testing.T) {
	ribbon:=[]geo.Cross_Section{{pos={0,0,0}},{pos={0,0,1000}}}
	markers:=timing_markers(ribbon,TIMING_DEFAULTS)
	testing.expect_value(t,len(markers),5)
	testing.expect_value(t,markers[0].kind,Timing_Marker_Kind.Start)
	testing.expect_value(t,markers[0].station,f32(50))
	testing.expect_value(t,markers[1].kind,Timing_Marker_Kind.Checkpoint)
	testing.expect_value(t,markers[3].kind,Timing_Marker_Kind.Checkpoint)
	testing.expect_value(t,markers[4].kind,Timing_Marker_Kind.Finish)
	testing.expect_value(t,markers[4].station,f32(950))
}

@(test)
timing_buffer_clamps_on_short_routes :: proc(t:^testing.T) {
	ribbon:=[]geo.Cross_Section{{pos={0,0,0}},{pos={0,0,100}}}
	markers:=timing_markers(ribbon,TIMING_DEFAULTS)
	testing.expect_value(t,markers[0].station,f32(25))
	testing.expect_value(t,markers[len(markers)-1].station,f32(75))
}
