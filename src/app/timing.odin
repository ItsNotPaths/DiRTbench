package main

import "../gfx"
import "../geo"

// Dirt 3 allows 4 sections per stage, so start, 3 checkpoints, finish. A fifth
// section kills Start Race, and there is no reason to want fewer.
TIMING_CHECKPOINTS :: 3

Timing_Params :: struct {
	buffer_m: f32,
}

TIMING_DEFAULTS :: Timing_Params {
	buffer_m = 50,
}

Timing_Marker_Kind :: enum u8 {
	Start,
	Checkpoint,
	Finish,
}

Timing_Marker :: struct {
	kind:    Timing_Marker_Kind,
	station: f32,
	pos:     gfx.Vector3,
}

timing_pos_at :: proc(ribbon:[]geo.Cross_Section,arc:[]f32,station:f32) -> gfx.Vector3 {
	if station<=0 { return ribbon[0].pos }
	for i in 1..<len(ribbon) {
		if arc[i]>=station {
			span:=max(arc[i]-arc[i-1],1e-6)
			return ribbon[i-1].pos+(ribbon[i].pos-ribbon[i-1].pos)*(station-arc[i-1])/span
		}
	}
	return ribbon[len(ribbon)-1].pos
}

timing_markers :: proc(ribbon:[]geo.Cross_Section,p:Timing_Params,allocator:=context.temp_allocator) -> []Timing_Marker {
	if len(ribbon)<2 { return nil }
	arc:=geo.ribbon_arc(ribbon,allocator)
	length:=arc[len(arc)-1]
	buffer:=min(max(p.buffer_m,0),length*0.25)
	count:=TIMING_CHECKPOINTS+2
	out:=make([]Timing_Marker,count,allocator)
	for i in 0..<count {
		station:=buffer+(length-2*buffer)*f32(i)/f32(count-1)
		kind:=Timing_Marker_Kind.Checkpoint
		if i==0 { kind=.Start } else if i==count-1 { kind=.Finish }
		out[i]={kind=kind,station=station,pos=timing_pos_at(ribbon,arc,station)}
	}
	return out
}

draw_timing_markers :: proc(markers:[]Timing_Marker) {
	for marker in markers {
		colour:=gfx.Color{245,205,55,255}
		switch marker.kind {
		case .Start:  colour={70,220,95,255}
		case .Finish: colour={235,65,65,255}
		case .Checkpoint:
		}
		gfx.DrawSphere(marker.pos+gfx.Vector3{0,1.5,0},1.5,colour)
	}
}
