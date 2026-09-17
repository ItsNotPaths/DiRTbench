package d3

// Reference only — see refs/README.md. Not part of any package that builds.
//
// These commands record the destructive experiments and format surgery used to
// establish the production codecs. They are kept for the method, not for use:
// nothing in the shipping tool may depend on them.
//
// To run one again: move this file to src/d3/, add its alias back to
// src/d3/api.odin, and restore its command in src/app/cli.odin.

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// --- Collision synthesis and stock-archive surgery ---------------------------
//
// Synthetic ramps, strips, and flat sheets proved the collision encoder and
// archive partition rules. The stock variants rewrite or replace chunks to
// isolate game behavior; Rewrite is the byte-level round-trip oracle.

// A wide, unmistakable 200 m strip. Position and across-road normal come from
// Finland route 0's first AI gate. `ground_y` is supplied separately because
// the gate floats about one metre above the actual collision surface.
d3_ramp_tris :: proc(ground_y: f32, allocator := context.allocator) -> []D3_Write_Tri {
	tris := make([dynamic]D3_Write_Tri, context.temp_allocator)
	segments := 50
	// Centre of the first progress gate. The next gate's centre establishes the
	// direction of travel; unlike AI gate 0, this lies on the driven benchmark.
	start := [3]f32{-2107.845, ground_y, -656.33}
	forward := [3]f32{0.061786, 0, -0.998090}
	across := [3]f32{0.998090, 0, 0.061786}
	for i in 0..<segments {
		d0, d1 := f32(i) * 4, f32(i + 1) * 4
		y0, y1 := f32(i) / f32(segments) * 8, f32(i + 1) / f32(segments) * 8
		center0, center1 := start + forward*d0, start + forward*d1
		center0[1] += y0; center1[1] += y1
		a := center0 - across*5; b := center0 + across*5; c := center1 + across*5; d := center1 - across*5
		append(&tris, D3_Write_Tri{p = {a, c, b}, mat = "GLD*"}, D3_Write_Tri{p = {a, d, c}, mat = "GLD*"})
	}
	return slice.clone(tris[:], allocator)
}

// An invisible-collision driving oracle: dead straight in XZ so the benchmark
// driver cannot miss it, but gently wavy in Y so contact with our surface is
// obvious. Dense tessellation deliberately forces several archive partitions.
d3_partition_strip_tris :: proc(ground_y: f32, allocator := context.allocator) -> []D3_Write_Tri {
	tris := make([dynamic]D3_Write_Tri, context.temp_allocator)
	segments := 300
	step := f32(1)
	// Centre of the near edge of the first visible wooden bridge. Unlike the
	// old AI-gate coordinate, this is a surface the benchmark car demonstrably
	// reaches. The bridge centreline runs toward decreasing X, increasing Z.
	start := [3]f32{-2139.02,ground_y,-505.84}
	forward := [3]f32{-0.3425,0,0.9395}
	across := [3]f32{0.9395,0,0.3425}
	for i in 0..<segments {
		d0,d1:=f32(i)*step,f32(i+1)*step
		centers: [2][3]f32
		distances := [2]f32{d0,d1}
		for d,j in distances {
			// 24 m smooth rise to a 2 m-high strip. Fade the 0.22 m wave
			// in over the same distance so neither component makes an impact lip.
			u:=math.clamp(d/24, f32(0), f32(1))
			envelope:=(1-math.cos(math.PI*u))/2
			y:=ground_y+2*envelope+0.22*envelope*math.sin(2*math.PI*d/28)
			centers[j]=start+forward*d; centers[j][1]=y
		}
		a:=centers[0]-across*7; b:=centers[0]+across*7
		c:=centers[1]+across*7; d:=centers[1]-across*7
		append(&tris,D3_Write_Tri{p={a,c,b},mat="GLD*"},D3_Write_Tri{p={a,d,c},mat="GLD*"})
	}
	return slice.clone(tris[:],allocator)
}

// Fresh-archive oracle with enough collision under the real start gate for the
// race car to settle before it reaches the ribbon. It then climbs conspicuously
// above the stock scenery and stays dead straight for an unguided car.
d3_sky_strip_tris :: proc(allocator := context.allocator) -> []D3_Write_Tri {
	tris:=make([dynamic]D3_Write_Tri,context.temp_allocator)
	// Measured directly from the first visible wooden bridge collision. This
	// test deliberately has no dependency on AI/progress gate semantics.
	spawn:=[3]f32{-2139.02,2.02,-505.84}
	forward:=[3]f32{-0.3425,0,0.9395}
	across:=[3]f32{0.9395,0,0.3425}
	// Catch area without a second sheet beneath the centre lane: one rear pad
	// and two forward wings meet the 30 m ribbon along shared edges.
	pads:=[3][4]f32{{-50,0,-50,50},{0,60,-50,-15},{0,60,15,50}}
	for pad in pads {
		a:=spawn+forward*pad[0]+across*pad[2]; b:=spawn+forward*pad[0]+across*pad[3]
		c:=spawn+forward*pad[1]+across*pad[3]; d:=spawn+forward*pad[1]+across*pad[2]
		append(&tris,D3_Write_Tri{p={a,c,b},mat="GLD*"},D3_Write_Tri{p={a,d,c},mat="GLD*"})
	}
	segments:=800; step:=f32(1)
	for i in 0..<segments {
		centers:[2][3]f32; distances:=[2]f32{f32(i)*step,f32(i+1)*step}
		for d,j in distances {
			// Give the car 20 m to settle, then rise 10 m over 60 m.
			u:=math.clamp((d-20)/60,f32(0),f32(1)); rise:=(1-math.cos(math.PI*u))/2
			y:=spawn[1]+10*rise+0.35*rise*math.sin(2*math.PI*d/32)
			centers[j]=spawn+forward*d; centers[j][1]=y
		}
		a:=centers[0]-across*15; b:=centers[0]+across*15; c:=centers[1]+across*15; d:=centers[1]-across*15
		append(&tris,D3_Write_Tri{p={a,c,b},mat="GLD*"},D3_Write_Tri{p={a,d,c},mat="GLD*"})
	}
	return slice.clone(tris[:],allocator)
}

// A fresh, level collision sheet. 32x32 cells produce 1089 unique vertices,
// deliberately exceeding the root chunk's 1024-vertex split threshold. A
// broad stage therefore gets four spatial leaves instead of the one-root
// archive that the game failed to look up, while each leaf stays small.
d3_flat_tris :: proc(min_x, max_x, min_z, max_z, y: f32, allocator := context.allocator) -> []D3_Write_Tri {
	CELLS :: 32
	tris:=make([dynamic]D3_Write_Tri,context.temp_allocator)
	for z in 0..<CELLS {
		z0:=min_z+(max_z-min_z)*f32(z)/CELLS
		z1:=min_z+(max_z-min_z)*f32(z+1)/CELLS
		for x in 0..<CELLS {
			x0:=min_x+(max_x-min_x)*f32(x)/CELLS
			x1:=min_x+(max_x-min_x)*f32(x+1)/CELLS
			a:=[3]f32{x0,y,z0}; b:=[3]f32{x1,y,z0}
			c:=[3]f32{x1,y,z1}; d:=[3]f32{x0,y,z1}
			append(&tris,D3_Write_Tri{p={a,c,b},mat="GLD*"},D3_Write_Tri{p={a,d,c},mat="GLD*"})
		}
	}
	return slice.clone(tris[:],allocator)
}

dirt3_flat_headless :: proc(min_x, max_x, min_z, max_z, y: f32, out_path: string) -> (msg: string, ok: bool) {
	if !(min_x < max_x) { return "flat collision needs min-x < max-x",false }
	if !(min_z < max_z) { return "flat collision needs min-z < max-z",false }
	if y != y { return "flat collision height must be finite",false }
	tris:=d3_flat_tris(min_x,max_x,min_z,max_z,y,context.allocator); defer delete(tris)
	jpak,pmsg,pok:=d3_track_write(tris,context.allocator); if !pok { return pmsg,false }; defer delete(jpak)

	// Exercise both readers before putting the file on disk. This catches JPAK
	// layout errors as well as malformed packed chunks without needing the game.
	entries,jok:=jpak_read(jpak,context.temp_allocator); if !jok { return "flat writer produced an unreadable JPAK",false }
	chunks,decoded_tris:=0,0
	seam_x,seam_z:=[dynamic]bool{},[dynamic]bool{}
	for e in entries {
		if e.name=="qt.info" { continue }
		chunk,cmsg,cok:=qt_read(e.data,context.allocator); if !cok { return fmt.tprintf("%s: %s",e.name,cmsg),false }
		if vmsg,vok:=qt_validate(&chunk); !vok { qt_chunk_delete(&chunk); return fmt.tprintf("%s: %s",e.name,vmsg),false }
		touches_x,touches_z:=false,false
		mid_x,mid_z:=(min_x+max_x)/2,(min_z+max_z)/2
		eps_x,eps_z:=(max_x-min_x)*0.00001,(max_z-min_z)*0.00001
		for v in chunk.verts {
			if math.abs(v[1]-y)>0.001 { qt_chunk_delete(&chunk); return "flat writer self-check found a non-level vertex",false }
			if math.abs(v[0]-mid_x)<=eps_x { touches_x=true }
			if math.abs(v[2]-mid_z)<=eps_z { touches_z=true }
		}
		append(&seam_x,touches_x); append(&seam_z,touches_z)
		decoded_tris+=len(chunk.tris); chunks+=1; qt_chunk_delete(&chunk)
	}
	if chunks<2 { return "flat collision did not produce multiple spatial chunks",false }
	if decoded_tris<len(tris) { return "flat writer self-check lost collision triangles",false }
	for hit,i in seam_x { if !hit || !seam_z[i] { return fmt.tprintf("flat collision chunk %d does not meet both partition seams",i),false } }
	if err:=os.write_entire_file(out_path,jpak); err!=nil { return fmt.tprintf("could not write %s: %v",out_path,err),false }
	return fmt.tprintf("%s: flat %.1f x %.1f m collision at Y %.3f; %s",out_path,max_x-min_x,max_z-min_z,y,pmsg),true
}

dirt3_partition_strip_headless :: proc(out_path: string) -> (msg: string, ok: bool) {
	tris:=d3_sky_strip_tris(context.allocator); defer delete(tris)
	jpak,pmsg,pok:=d3_track_write(tris,context.allocator); if !pok { return pmsg,false }; defer delete(jpak)
	entries,jok:=jpak_read(jpak,context.temp_allocator); if !jok { return "partition writer produced an unreadable JPAK",false }
	chunks,decoded_tris:=0,0
	for e in entries {
		if e.name=="qt.info" { continue }
		c,cmsg,cok:=qt_read(e.data,context.allocator); if !cok { return fmt.tprintf("%s: %s",e.name,cmsg),false }
		if vmsg,vok:=qt_validate(&c); !vok { qt_chunk_delete(&c); return fmt.tprintf("%s: %s",e.name,vmsg),false }
		decoded_tris+=len(c.tris); chunks+=1; qt_chunk_delete(&c)
	}
	if chunks<2 { return "partition oracle did not produce multiple collision chunks",false }
	if decoded_tris<len(tris) { return "partition oracle lost source triangles",false }
	if err:=os.write_entire_file(out_path,jpak); err!=nil { return fmt.tprintf("could not write %s: %v",out_path,err),false }
	return fmt.tprintf("%s: start platform plus straight 800 m sky ribbon; %s, %d stored triangles",out_path,pmsg,decoded_tris),true
}

// Preserve the stock route so every showcase/spawn position remains supported,
// then place the straight oracle into the stock archive cells. The bridge deck
// beneath its entrance is replaced, not doubled: overlapping sheet collision
// already proved capable of forming an undriveable wedge.
dirt3_partition_strip_on_stock_headless :: proc(path,out_path:string) -> (msg:string,ok:bool) {
	raw,err:=os.read_entire_file(path,context.allocator); if err!=nil { return fmt.tprintf("could not read %s: %v",path,err),false }; defer delete(raw)
	entries,jok:=jpak_read(raw,context.allocator); if !jok { return fmt.tprintf("%s is not a readable JPAK",path),false }; defer delete(entries)
	strip:=d3_partition_strip_tris(2.02,context.allocator); defer delete(strip)
	covered:=make([]bool,len(strip),context.allocator); defer delete(covered)
	sources:=make([dynamic]D3_Jpak_Source,context.allocator); owned:=make([dynamic][]u8,context.allocator)
	defer { for b in owned { delete(b) }; delete(owned); delete(sources) }
	route_min,route_max:=[3]f32{},[3]f32{}
	for e in entries { if e.name=="qt.info" && len(e.data)>=24 { for axis in 0..<3 { route_min[axis]=d3_get_f32(e.data,axis*4); route_max[axis]=d3_get_f32(e.data,12+axis*4) }; break } }
	replaced,stored:=0,0
	for e in entries {
		if e.name=="qt.info" { append(&sources,D3_Jpak_Source{e.name,e.data}); continue }
		if len(e.name)<6 || e.name[len(e.name)-6:]!=".vcqtc" { continue }
		chunk,rmsg,rok:=qt_read(e.data,context.allocator); if !rok { return fmt.tprintf("%s: %s",e.name,rmsg),false }
		lo,hi,bok:=d3_named_cell_bounds(e.name,route_min,route_max); if !bok { qt_chunk_delete(&chunk); return fmt.tprintf("cannot decode spatial chunk name %q",e.name),false }
		extra:=make([dynamic]int,context.allocator)
		for t,i in strip { if d3_tri_hits_cell(t,lo,hi) { append(&extra,i); covered[i]=true; stored+=1 } }
		keep:=0
		for t in chunk.tris {
			p:=[3][3]f32{chunk.verts[t.v[0]],chunk.verts[t.v[1]],chunk.verts[t.v[2]]}; center:=(p[0]+p[1]+p[2])/3; mat:=chunk.mats[t.mat]
			is_bridge:=len(mat)>=3&&mat[:3]=="WDS"&&center[0]>=-2160&&center[0]<=-2125&&center[2]>=-510&&center[2]<=-475
			if is_bridge { replaced+=1 } else { keep+=1 }
		}
		input:=make([]D3_Write_Tri,keep+len(extra),context.allocator); at:=0
		for t in chunk.tris {
			p:=[3][3]f32{chunk.verts[t.v[0]],chunk.verts[t.v[1]],chunk.verts[t.v[2]]}; center:=(p[0]+p[1]+p[2])/3; mat:=chunk.mats[t.mat]
			if len(mat)>=3&&mat[:3]=="WDS"&&center[0]>=-2160&&center[0]<=-2125&&center[2]>=-510&&center[2]<=-475 { continue }
			input[at]={p=p,mat=mat}; at+=1
		}
		for id in extra { input[at]=strip[id]; at+=1 }
		delete(extra)
		rebuilt,wmsg,wok:=d3_vcqtc_write(input,context.allocator); delete(input); qt_chunk_delete(&chunk)
		if !wok { return fmt.tprintf("%s: %s",e.name,wmsg),false }
		append(&owned,rebuilt); append(&sources,D3_Jpak_Source{e.name,rebuilt})
	}
	for hit,i in covered { if !hit { return fmt.tprintf("strip triangle %d was outside the stock collision grid",i),false } }
	jpak:=d3_jpak_write(sources[:],context.allocator); defer delete(jpak)
	if werr:=os.write_entire_file(out_path,jpak); werr!=nil { return fmt.tprintf("could not write %s: %v",out_path,werr),false }
	return fmt.tprintf("%s: retained stock collision, replaced %d bridge faces, added %d strip triangle instances",out_path,replaced,stored),true
}

@(private = "file")
d3_named_cell_bounds :: proc(name: string, route_min, route_max: [3]f32) -> (lo, hi: [2]f32, ok: bool) {
	if len(name) < 8 || name[:2] != "qt" { return lo, hi, false }
	fx, fz, width := f32(0), f32(0), f32(1)
	for at := 2; at + 2 < len(name) && name[at] == '_'; at += 3 {
		width *= 0.5
		if name[at+1] == '1' { fx += width } else if name[at+1] != '0' { return lo, hi, false }
		if name[at+2] == '1' { fz += width } else if name[at+2] != '0' { return lo, hi, false }
	}
	sx, sz := route_max[0]-route_min[0], route_max[2]-route_min[2]
	lo = {route_min[0]+fx*sx, route_min[2]+fz*sz}
	hi = {lo[0]+width*sx, lo[1]+width*sz}
	return lo, hi, true
}

dirt3_ramp_headless :: proc(out_path: string) -> (msg: string, ok: bool) {
	tris := d3_ramp_tris(5.16, context.temp_allocator)
	chunk, cmsg, cok := d3_vcqtc_write(tris[:], context.temp_allocator)
	if !cok { return cmsg, false }
	info := make([]u8, 24, context.temp_allocator)
	for axis in 0..<3 { d3_put_f32(info, axis*4, d3_get_f32(chunk, axis*4)); d3_put_f32(info, 12+axis*4, d3_get_f32(chunk, 12+axis*4)) }
	jpak := d3_jpak_write({{"qt.vcqtc", chunk}, {"qt.info", info}}, context.temp_allocator)
	if err := os.write_entire_file(out_path, jpak); err != nil { return fmt.tprintf("could not write %s: %v", out_path, err), false }
	entries, read_ok := jpak_read(jpak, context.temp_allocator)
	if !read_ok || len(entries) != 2 { return "writer produced an unreadable JPAK", false }
	decoded, dmsg, dok := qt_read(entries[0].data, context.temp_allocator)
	if !dok { return fmt.tprintf("writer self-check: %s", dmsg), false }
	defer qt_chunk_delete(&decoded, context.temp_allocator)
	if vmsg, vok := qt_validate(&decoded); !vok { return fmt.tprintf("writer self-check: %s", vmsg), false }
	return fmt.tprintf("%s: straight ramp, %d verts, %d tris, Y %.1f..%.1f m", out_path, len(decoded.verts), len(decoded.tris), decoded.bounds_min[1], decoded.bounds_max[1]), true
}

// Keep the stock archive partition and collision, adding each ramp triangle to
// the existing spatial chunk that contains its centroid. This makes the first
// custom-geometry test independent of gates, reset lines, and empty grid cells.
dirt3_ramp_on_stock_headless :: proc(path, out_path: string) -> (msg: string, ok: bool) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil { return fmt.tprintf("could not read %s: %v", path, err), false }
	defer delete(raw)
	entries, jok := jpak_read(raw, context.allocator)
	if !jok { return fmt.tprintf("%s is not a readable JPAK", path), false }
	defer delete(entries)
	ramp := d3_ramp_tris(5.16, context.allocator); defer delete(ramp)
	assigned := make([]bool, len(ramp), context.allocator); defer delete(assigned)
	sources := make([dynamic]D3_Jpak_Source, context.allocator)
	owned := make([dynamic][]u8, context.allocator)
	defer { for bytes in owned { delete(bytes) }; delete(owned); delete(sources) }
	added := 0
	route_min, route_max := [3]f32{}, [3]f32{}
	for entry in entries {
		if entry.name == "qt.info" && len(entry.data) >= 24 {
			for axis in 0..<3 { route_min[axis]=d3_get_f32(entry.data,axis*4); route_max[axis]=d3_get_f32(entry.data,12+axis*4) }
			break
		}
	}

	for entry in entries {
		if entry.name == "qt.info" { append(&sources, D3_Jpak_Source{entry.name, entry.data}); continue }
		if len(entry.name) < 6 || entry.name[len(entry.name)-6:] != ".vcqtc" { continue }
		chunk, rmsg, rok := qt_read(entry.data, context.allocator)
		if !rok { return fmt.tprintf("%s: %s", entry.name, rmsg), false }
		cell_lo, cell_hi, cell_ok := d3_named_cell_bounds(entry.name, route_min, route_max)
		if !cell_ok { qt_chunk_delete(&chunk); return fmt.tprintf("cannot decode spatial chunk name %q", entry.name), false }
		extra := make([dynamic]int, context.temp_allocator)
		for rt, ri in ramp {
			if assigned[ri] { continue }
			center := (rt.p[0] + rt.p[1] + rt.p[2]) / 3
			if center[0] >= cell_lo[0] && center[0] <= cell_hi[0] &&
			   center[2] >= cell_lo[1] && center[2] <= cell_hi[1] {
				append(&extra, ri); assigned[ri] = true; added += 1
			}
		}
		input := make([]D3_Write_Tri, len(chunk.tris) + len(extra), context.allocator)
		for t, i in chunk.tris { input[i] = {p={chunk.verts[t.v[0]],chunk.verts[t.v[1]],chunk.verts[t.v[2]]},mat=chunk.mats[t.mat]} }
		for ri, i in extra { input[len(chunk.tris)+i] = ramp[ri] }
		rebuilt, wmsg, wok := d3_vcqtc_write(input, context.allocator)
		delete(input); qt_chunk_delete(&chunk)
		if !wok { return fmt.tprintf("%s: %s", entry.name, wmsg), false }
		append(&owned, rebuilt); append(&sources, D3_Jpak_Source{entry.name, rebuilt})
	}
	if added != len(ramp) { return fmt.tprintf("only placed %d of %d ramp triangles into stock chunks", added, len(ramp)), false }
	jpak := d3_jpak_write(sources[:], context.allocator); defer delete(jpak)
	if werr := os.write_entire_file(out_path, jpak); werr != nil { return fmt.tprintf("could not write %s: %v", out_path, werr), false }
	return fmt.tprintf("%s: stock collision plus %d custom ramp triangles in the original spatial grid", out_path, added), true
}

// Turn the first visible wooden bridge into a smooth 3 m arch. The new faces
// are derived from the bridge's own WDS collision and remain in the exact same
// archive chunks, making this the least ambiguous custom-geometry probe.
dirt3_bridge_bump_headless :: proc(path, out_path: string) -> (msg: string, ok: bool) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil { return fmt.tprintf("could not read %s: %v", path, err), false }
	defer delete(raw)
	entries, jok := jpak_read(raw, context.allocator)
	if !jok { return fmt.tprintf("%s is not a readable JPAK", path), false }
	defer delete(entries)
	sources := make([dynamic]D3_Jpak_Source, context.allocator)
	owned := make([dynamic][]u8, context.allocator)
	defer { for bytes in owned { delete(bytes) }; delete(owned); delete(sources) }
	added := 0

	for entry in entries {
		if entry.name == "qt.info" { append(&sources, D3_Jpak_Source{entry.name, entry.data}); continue }
		if len(entry.name) < 6 || entry.name[len(entry.name)-6:] != ".vcqtc" { continue }
		chunk, rmsg, rok := qt_read(entry.data, context.allocator)
		if !rok { return fmt.tprintf("%s: %s", entry.name, rmsg), false }
		input := make([]D3_Write_Tri, len(chunk.tris), context.allocator)
		for t, i in chunk.tris {
			p := [3][3]f32{chunk.verts[t.v[0]],chunk.verts[t.v[1]],chunk.verts[t.v[2]]}
			mat := chunk.mats[t.mat]
			center := (p[0]+p[1]+p[2])/3
			is_bridge := len(mat)>=3 && mat[:3]=="WDS" && center[0]>=-2160 && center[0]<=-2125 && center[2]>=-510 && center[2]<=-475
			if is_bridge {
				for &v in p {
					u := math.clamp((v[2] - (-505.84)) / 25.32, f32(0), f32(1))
					// Raised cosine: height and slope both meet the stock deck
					// continuously, avoiding an impact lip at either end.
					v[1] += (1-math.cos(2*u*math.PI))*1.5
				}
				added += 1
			}
			input[i]={p=p,mat=mat}
		}
		rebuilt, wmsg, wok := d3_vcqtc_write(input, context.allocator)
		delete(input); qt_chunk_delete(&chunk)
		if !wok { return fmt.tprintf("%s: %s", entry.name, wmsg), false }
		append(&owned, rebuilt); append(&sources, D3_Jpak_Source{entry.name, rebuilt})
	}
	if added == 0 { return "could not find the start bridge's WDS collision", false }
	jpak := d3_jpak_write(sources[:], context.allocator); defer delete(jpak)
	if werr := os.write_entire_file(out_path, jpak); werr != nil { return fmt.tprintf("could not write %s: %v", out_path, werr), false }
	return fmt.tprintf("%s: replaced %d faces of the first wooden bridge with a smooth 3 m arch", out_path, added), true
}

// Decode every stock chunk to triangles, then rebuild it through our packed
// writer while retaining the archive's spatial names. This is the game oracle:
// if it drives, the byte writer is sound and any later failure belongs to
// stage partitioning/placement rather than the packed format.
dirt3_rewrite_headless :: proc(path, out_path: string) -> (msg: string, ok: bool) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil { return fmt.tprintf("could not read %s: %v", path, err), false }
	defer delete(raw)
	entries, jok := jpak_read(raw, context.allocator)
	if !jok { return fmt.tprintf("%s is not a readable JPAK", path), false }
	defer delete(entries)

	sources := make([dynamic]D3_Jpak_Source, context.allocator)
	owned := make([dynamic][]u8, context.allocator)
	defer {
		for bytes in owned { delete(bytes) }
		delete(owned); delete(sources)
	}
	for entry in entries {
		if entry.name == "qt.info" {
			append(&sources, D3_Jpak_Source{entry.name, entry.data})
			continue
		}
		if len(entry.name) < 6 || entry.name[len(entry.name)-6:] != ".vcqtc" { continue }
		chunk, rmsg, rok := qt_read(entry.data, context.allocator)
		if !rok { return fmt.tprintf("%s: %s", entry.name, rmsg), false }
		input := make([]D3_Write_Tri, len(chunk.tris), context.allocator)
		for t, i in chunk.tris {
			input[i] = {p = {chunk.verts[t.v[0]], chunk.verts[t.v[1]], chunk.verts[t.v[2]]}, mat = chunk.mats[t.mat]}
		}
		rebuilt, wmsg, wok := d3_vcqtc_write(input, context.allocator)
		delete(input)
		qt_chunk_delete(&chunk)
		if !wok { return fmt.tprintf("%s: %s", entry.name, wmsg), false }
		append(&owned, rebuilt)
		append(&sources, D3_Jpak_Source{entry.name, rebuilt})
	}
	if len(owned) == 0 { return "archive holds no collision chunks", false }
	jpak := d3_jpak_write(sources[:], context.allocator); defer delete(jpak)
	if werr := os.write_entire_file(out_path, jpak); werr != nil { return fmt.tprintf("could not write %s: %v", out_path, werr), false }
	return fmt.tprintf("%s: rewrote %d stock chunks through our encoder", out_path, len(owned)), true
}


// --- Collision inspection and mutation ---------------------------------------
//
// Dump converts collision to OBJ for inspection. Raise rewrites an archive
// after translating its vertices, a deliberately surgical format probe.

qt_write_obj :: proc(chunks: []Qt_Chunk, path: string) -> (msg: string, ok: bool) {
	stem := strings.trim_suffix(path, filepath.ext(path))
	mtl_path := fmt.tprintf("%s.mtl", stem)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "mtllib %s", filepath.base(mtl_path))

	// Positions first, one flat list; faces then index into it per chunk.
	bases := make([]int, len(chunks), context.temp_allocator)
	total := 1 // OBJ indices are 1-based
	for c, i in chunks {
		bases[i] = total
		for v in c.verts {
			fmt.sbprintfln(&b, "v %f %f %f", v[0], v[1], v[2])
		}
		total += len(c.verts)
	}

	// Group faces by code so each surface is one object. Sorted, so two runs of
	// the same input give the same file.
	codes := make([dynamic]string, context.temp_allocator)
	for c in chunks {
		for t in c.tris {
			code := c.mats[t.mat]
			if !slice.contains(codes[:], code) {
				append(&codes, code)
			}
		}
	}
	slice.sort(codes[:])

	faces := 0
	for code in codes {
		fmt.sbprintfln(&b, "o %s", code)
		fmt.sbprintfln(&b, "usemtl %s", code)
		for c, ci in chunks {
			base := bases[ci]
			for t in c.tris {
				if c.mats[t.mat] != code {
					continue
				}
				fmt.sbprintfln(&b, "f %d %d %d", base + t.v[0], base + t.v[1], base + t.v[2])
				faces += 1
			}
		}
	}

	m := strings.builder_make(context.temp_allocator)
	for code in codes {
		fmt.sbprintfln(&m, "newmtl %s", code)
		fmt.sbprintfln(&m, "Kd %s", qt_colour(code))
		fmt.sbprintln(&m, "Ka 0 0 0")
	}

	if werr := os.write_entire_file(path, b.buf[:]); werr != nil {
		return fmt.tprintf("could not write %s: %v", path, werr), false
	}
	if werr := os.write_entire_file(mtl_path, m.buf[:]); werr != nil {
		return fmt.tprintf("could not write %s: %v", mtl_path, werr), false
	}
	return fmt.tprintf("%s: %d verts, %d faces, %d surfaces", path, total - 1, faces, len(codes)), true
}

// --- headless ----------------------------------------------------------------

// `--dirt3-dump <track.jpk|x.vcqtc> [-o out.obj]`: parse a stock collision file
// and write it out as an OBJ. This is milestone 0 — it checks the format notes
// against the game's own files before anything tries to write one.
// A `.vcqtc` on its own is one chunk; a `track.jpk` is an archive of them plus
// a `qt.info` holding the route's bounding box. Chunk material codes slice the
// archive, so `raw` is kept alive alongside them.
D3_Collision_File :: struct {
	raw:     []u8,
	chunks:  [dynamic]Qt_Chunk,
	skipped: int,
}

d3_collision_delete :: proc(file: ^D3_Collision_File, allocator := context.allocator) {
	for &chunk in file.chunks { qt_chunk_delete(&chunk, allocator) }
	delete(file.chunks)
	delete(file.raw, allocator)
	file^ = {}
}

d3_collision_read :: proc(path: string, allocator := context.allocator) -> (file: D3_Collision_File, msg: string, ok: bool) {
	raw, rerr := os.read_entire_file(path, allocator)
	if rerr != nil { return file, fmt.tprintf("could not read %s: %v", path, rerr), false }
	file.raw = raw
	file.chunks = make([dynamic]Qt_Chunk, allocator)

	members: []Jpak_Entry
	if len(raw) >= 4 && string(raw[:4]) == "JPAK" {
		entries, jok := jpak_read(raw, context.temp_allocator)
		if !jok { d3_collision_delete(&file, allocator); return file, fmt.tprintf("%s is not a readable JPAK", path), false }
		members = entries
	} else {
		members = slice.clone([]Jpak_Entry{{name = filepath.base(path), data = raw}}, context.temp_allocator)
	}

	for m in members {
		if !strings.has_suffix(m.name, ".vcqtc") { file.skipped += 1; continue }
		chunk, cmsg, cok := qt_read(m.data, allocator)
		if !cok { d3_collision_delete(&file, allocator); return file, fmt.tprintf("%s: %s", m.name, cmsg), false }
		if vmsg, vok := qt_validate(&chunk); !vok {
			qt_chunk_delete(&chunk, allocator); d3_collision_delete(&file, allocator)
			return file, fmt.tprintf("%s: %s", m.name, vmsg), false
		}
		append(&file.chunks, chunk)
	}
	if len(file.chunks) == 0 {
		first := "(none)"
		if len(members) > 0 { first = members[0].name }
		count := len(members)
		d3_collision_delete(&file, allocator)
		return file, fmt.tprintf("%s holds no .vcqtc chunks (%d entries; first name %q)", path, count, first), false
	}
	return file, "", true
}

dirt3_dump_headless :: proc(path: string, out: string) -> (msg: string, ok: bool) {
	file, read_msg, read_ok := d3_collision_read(path, context.allocator)
	if !read_ok { return read_msg, false }
	defer d3_collision_delete(&file)

	tris, verts := 0, 0
	for chunk in file.chunks { tris += len(chunk.tris); verts += len(chunk.verts) }
	fmt.printfln(
		"%s: %d chunks, %d verts, %d tris, %d non-chunk entries",
		filepath.base(path), len(file.chunks), verts, tris, file.skipped,
	)
	return qt_write_obj(file.chunks[:], out)
}

// --- surgery -----------------------------------------------------------------

@(private = "file")
le_put_f32 :: proc(b: []u8, at: int, v: f32) {
	binary_store_f32(b, at, v)
}

// Shift every collision surface up by `dy` metres, in place, touching 8 bytes per
// chunk and re-encoding nothing.
//
// A position is quantized against the chunk's own bounding box:
//
//	pos = quantized * (max - min) * QT_SCALE + min
//
// Add `dy` to `min.y` and `max.y` together and the span is unchanged, so every
// packed vertex byte stays exactly as it was and only those two floats move. The
// quadtree is indexed on X and Z, so it does not notice.
//
// This is the end-to-end test that does not need the writer: the game either
// loads the file and drives that far above its own scenery, or it refuses it.
qt_raise :: proc(raw: []u8, dy: f32) -> (chunks: int, ok: bool) {
	entries := jpak_read(raw, context.temp_allocator) or_return
	for e in entries {
		// qt.info is the route's bounding box, 6 floats, same layout as a chunk
		// header's first 24 bytes. Both move or the route stops containing itself.
		is_chunk := strings.has_suffix(e.name, ".vcqtc")
		if !is_chunk && e.name != "qt.info" {
			continue
		}
		if len(e.data) < 24 {
			return chunks, false
		}
		le_put_f32(e.data, 4, le_f32(e.data, 4) + dy)
		le_put_f32(e.data, 16, le_f32(e.data, 16) + dy)
		if is_chunk {
			chunks += 1
		}
	}
	return chunks, chunks > 0
}

// `--dirt3-raise <track.jpk> <metres> [-o out.jpk]`: write a copy of a collision
// archive with every surface lifted. The input is never modified.
dirt3_raise_headless :: proc(path: string, dy: f32, out: string) -> (msg: string, ok: bool) {
	raw, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return fmt.tprintf("could not read %s: %v", path, rerr), false
	}
	defer delete(raw)

	chunks := qt_raise(raw, dy) or_else 0
	if chunks == 0 {
		return fmt.tprintf("%s is not a readable JPAK of .vcqtc chunks", path), false
	}
	if werr := os.write_entire_file(out, raw); werr != nil {
		return fmt.tprintf("could not write %s: %v", out, werr), false
	}
	return fmt.tprintf("%s: %d chunks raised %.2f m -> %s", filepath.base(path), chunks, dy, out), true
}


// --- Route-split conversion --------------------------------------------------
//
// Converts decoded collision back into render geometry with fixture shaders.
// This is a diagnostic bridge, not the normal venue export path.

// The profile maps a material to a collision code; going back the other way
// gives a stock or exported track.jpk the visual surface that matches it.
d3_material_of :: proc(profile: ^D3_Venue_Profile, code: string) -> Collision_Material {
	for material in Collision_Material {
		if profile.collision[material] == code { return material }
	}
	return .Terrain
}

// A debug converter: a stock track.jpk in, a routesplit out. It runs with no
// venue open, so it draws with the fixture shaders rather than a venue's own.
dirt3_routesplit_headless :: proc(path, out_path: string) -> (msg: string, ok: bool) {
	profile, profile_msg, profile_ok := d3_profile_fixture()
	if !profile_ok { return profile_msg, false }
	collision, read_msg, read_ok := d3_collision_read(path, context.allocator)
	if !read_ok { return read_msg, false }
	defer d3_collision_delete(&collision)

	total := 0
	for chunk in collision.chunks { total += len(chunk.tris) }
	tris := make([]Collision_Triangle, total, context.allocator)
	defer delete(tris)
	at := 0
	for chunk in collision.chunks {
		for tri in chunk.tris {
			code := chunk.mats[tri.mat] if tri.mat >= 0 && tri.mat < len(chunk.mats) else ""
			tris[at] = {
				Points = {chunk.verts[tri.v[0]], chunk.verts[tri.v[1]], chunk.verts[tri.v[2]]},
				Material = d3_material_of(&profile, code),
			}
			at += 1
		}
	}

	data, build_msg, built := d3_routesplit_build(tris, &profile, context.allocator)
	if !built { return build_msg, false }
	defer delete(data)
	if err := os.write_entire_file(out_path, data); err != nil {
		return fmt.tprintf("could not write %s: %v", out_path, err), false
	}
	return fmt.tprintf("%s: %d chunks, %s", out_path, len(collision.chunks), build_msg), true
}


// --- All-visible VIS experiment ----------------------------------------------
//
// Rebuilds a route VIS from placement, ENS, and PSSG evidence. Donor and random
// ornament modes document the experiments that established which ids are safe;
// synthesized mode is retained here as the successful reference implementation.
// A stock PSSG can nest several "NODE" elements before the one that actually
// groups the tiles — Michigan's tracksplit.pssg has an empty decoy NODE
// directly under ROOTNODE, ahead of the real one — so the surface node must
// be found by its own `id` attribute, not by first match on element type.
@(private = "file")
d3_pssg_find_node_by_id :: proc(file: ^Pssg_File, node: ^Pssg_Node, type_name, id: string) -> ^Pssg_Node {
	if node == nil { return nil }
	if node.name == type_name && pssg_attr_string(file, node, "id") == id { return node }
	for child in node.children {
		if found := d3_pssg_find_node_by_id(file, child, type_name, id); found != nil { return found }
	}
	return nil
}

// Every tile box on a `tracksplit.pssg`/`routesplit.pssg` surface node, read
// straight off the file's own BOUNDINGBOX children (big-endian, like every
// PSSG float payload) rather than recomputed from our own tiling. In file
// order; the caller applies whatever registration order the engine expects.
d3_pssg_surface_tile_boxes :: proc(file: ^Pssg_File, allocator := context.allocator) -> (boxes: []D3_Tile_Box, ok: bool) {
	surface := d3_pssg_find_node_by_id(file, file.root, "NODE", "surface")
	if surface == nil || len(surface.children) <= 2 { return nil, false }

	out := make([dynamic]D3_Tile_Box, allocator)
	for tile in surface.children[2:] {
		if len(tile.children) <= 2 { continue }
		lo, hi: [3]f32
		seen := false
		for render in tile.children[2:] {
			box := pssg_walk_first(render, "BOUNDINGBOX")
			if box == nil || len(box.data) != 24 { continue }
			for k in 0 ..< 3 {
				low_bits, _ := pssg_be_u32(box.data, k*4)
				high_bits, _ := pssg_be_u32(box.data, 12+k*4)
				low, high := transmute(f32)low_bits, transmute(f32)high_bits
				if !seen { lo[k] = low; hi[k] = high } else { lo[k] = min(lo[k], low); hi[k] = max(hi[k], high) }
			}
			seen = true
		}
		if seen { append(&out, D3_Tile_Box{lo, hi}) }
	}
	return out[:], true
}

@(private = "file")
d3_read_or_fail :: proc(path: string, allocator := context.allocator) -> (data: []u8, msg: string, ok: bool) {
	read, err := os.read_entire_file(path, allocator)
	if err != nil { return nil, fmt.tprintf("could not read %s: %v", path, err), false }
	return read, "", true
}

@(private = "file")
d3_read_pssg_tile_boxes :: proc(path: string, allocator := context.allocator) -> (boxes: []D3_Tile_Box, msg: string, ok: bool) {
	data, read_msg, read_ok := d3_read_or_fail(path, context.temp_allocator)
	if !read_ok { return nil, read_msg, false }
	file, pssg_msg, pssg_ok := pssg_read(data, context.temp_allocator)
	if !pssg_ok { return nil, fmt.tprintf("%s: %s", path, pssg_msg), false }
	defer pssg_delete(&file, context.temp_allocator)
	tiles, tiles_ok := d3_pssg_surface_tile_boxes(&file, allocator)
	if !tiles_ok { return nil, fmt.tprintf("%s: no tiled surface node", path), false }
	return tiles, "", true
}

// Every instance of one placement file (`trees.bin` or `ornaments.bin`),
// appended as VIS objects of `tag`, indexed by its cooked instance id.
@(private = "file")
d3_append_placement_objects :: proc(
	out: ^[dynamic]D3_Vis_Object,
	path: string,
	tag: u32,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, fmt.tprintf("%s: not a recognised placement file", path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, fmt.tprintf("%s: %s", path, read_msg), false }

	for inst, i in instances {
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, fmt.tprintf("%s: instance %d names an unknown reference %d", path, i, inst.reference_id), false
		}
		append(out, D3_Vis_Object{tag = tag, index = inst.instance_id, lo = lo, hi = hi})
		added += 1
	}
	return added, "", true
}

// `ornaments.bin`'s own instances, tag 2, with their real id read straight
// from `ornaments.xml` (see d3_ornaments_xml_instance_ids). Only instances
// whose id is actually present in `donor_vis_path`'s own tag-2 section are
// included — a route's `ornaments.xml` holds every authored placement, but a
// given route's `track.vis` only registers the subset relevant to it (162 vs
// 291's worth spread across sources on Michigan route_3; 157 of 162 present,
// 5 legitimately absent). No box-distance guessing: the id is exact, so
// inclusion is exact set membership, not a nearest match — see
// [[dirt3-ornaments-vis-crash]] for why a wrong id here is dangerous and
// leaving an object out of tag 2 entirely is the confirmed-safe fallback.
@(private = "file")
d3_append_ornaments_with_donor_ids :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ornaments_path, ornaments_xml_path, donor_vis_path: string,
) -> (
	added, skipped: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ornaments_path, context.temp_allocator)
	if !data_ok { return 0, 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, 0, fmt.tprintf("%s: not a recognised placement file", ornaments_path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, 0, fmt.tprintf("%s: %s", ornaments_path, read_msg), false }

	xml_data, xml_read_msg, xml_read_ok := d3_read_or_fail(ornaments_xml_path, context.temp_allocator)
	if !xml_read_ok { return 0, 0, xml_read_msg, false }
	xml_ids, xml_ok := d3_ornaments_xml_instance_ids(xml_data, context.temp_allocator)
	if !xml_ok { return 0, 0, fmt.tprintf("%s: could not read every instance_id", ornaments_xml_path), false }
	if len(xml_ids) != len(instances) {
		return 0, 0, fmt.tprintf("%s has %d instances but %s has %d", ornaments_path, len(instances), ornaments_xml_path, len(xml_ids)), false
	}

	donor_data, donor_read_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
	if !donor_read_ok { return 0, 0, donor_read_msg, false }
	donor_boxes, donor_ok := d3_vis_read_tag_boxes(donor_data, 2, context.temp_allocator)
	if !donor_ok { return 0, 0, fmt.tprintf("%s: too short to hold a Dirt 3 VIS section 3", donor_vis_path), false }

	for inst, i in instances {
		id := xml_ids[i]
		if _, present := donor_boxes[id]; !present {
			skipped += 1
			continue
		}
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, skipped, fmt.tprintf("%s: instance %d names an unknown reference %d", ornaments_path, i, inst.reference_id), false
		}
		append(out, D3_Vis_Object{tag = 2, index = id, lo = lo, hi = hi})
		added += 1
	}
	return added, skipped, "", true
}

// Picked well clear of both the made-up sequential range that's confirmed to
// crash (0..161 on Michigan route_3) and every real id observed on any route
// sampled (max ~2011, see [[dirt3-ornaments-vis-crash]]) — the point is to
// test whether an arbitrary, merely-unclaimed id is safe, not to dodge a
// specific collision.
D3_ORNAMENT_RANDOM_ID_BASE :: u32(10_000)
D3_ORNAMENT_RANDOM_ID_SPAN :: u32(60_000)

// `ornaments.bin`'s own instances, tag 2, with ids picked at random rather
// than recovered from anywhere real — an experiment, not a fix: donor-borrowed
// and objects.ens ids are the only ones confirmed safe so far (see
// [[dirt3-ornaments-vis-crash]]). `avoid` is every id already claimed
// elsewhere in this build (so this never collides with objects.ens's real
// entries); each instance still gets its own real box.
@(private = "file")
d3_append_ornaments_with_random_ids :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ornaments_path: string,
	avoid: map[u32]bool,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ornaments_path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	layout, layout_ok := d3_placement_layout(data)
	if !layout_ok { return 0, fmt.tprintf("%s: not a recognised placement file", ornaments_path), false }
	instances, read_msg, read_ok := d3_placement_read(data, context.temp_allocator)
	if !read_ok { return 0, fmt.tprintf("%s: %s", ornaments_path, read_msg), false }

	used := make(map[u32]bool, context.temp_allocator)
	for id in avoid { used[id] = true }

	for inst, i in instances {
		lo, hi, box_ok := d3_placement_instance_box(data, layout, inst)
		if !box_ok {
			return added, fmt.tprintf("%s: instance %d names an unknown reference %d", ornaments_path, i, inst.reference_id), false
		}
		id: u32
		for {
			id = D3_ORNAMENT_RANDOM_ID_BASE + u32(rand.int31_max(i32(D3_ORNAMENT_RANDOM_ID_SPAN)))
			if !used[id] { break }
		}
		used[id] = true
		append(out, D3_Vis_Object{tag = 2, index = id, lo = lo, hi = hi})
		added += 1
	}
	return added, "", true
}

// The route's `objects.ens` static-vis entities: real per-tag ids straight
// from the file's own `instanceID` attribute (see d3_ens_static_vis_ids),
// paired with a real box borrowed from `donor_vis_path`'s own tag-2 section.
// The id is confirmed exact game-wide; nothing shipped gives an independent
// box for it, so this is skipped entirely with no donor.
@(private = "file")
d3_append_ens_static_vis_objects :: proc(
	out: ^[dynamic]D3_Vis_Object,
	ens_path, donor_vis_path: string,
) -> (
	added: int,
	msg: string,
	ok: bool,
) {
	data, data_msg, data_ok := d3_read_or_fail(ens_path, context.temp_allocator)
	if !data_ok { return 0, data_msg, false }
	nodes, parse_ok := d3_ens_parse(data, context.temp_allocator)
	if !parse_ok { return 0, fmt.tprintf("%s: not a recognised objects.ens file", ens_path), false }
	ids, ids_ok := d3_ens_static_vis_ids(nodes, context.temp_allocator)
	if !ids_ok { return 0, fmt.tprintf("%s: a staticVis entity is missing its instanceID", ens_path), false }
	if len(ids) == 0 { return 0, "", true }

	donor_data, donor_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
	if !donor_read_ok { return 0, donor_msg, false }
	donor_boxes, donor_ok := d3_vis_read_tag_boxes(donor_data, 2, context.temp_allocator)
	if !donor_ok { return 0, fmt.tprintf("%s: too short to hold a Dirt 3 VIS section 3", donor_vis_path), false }

	for id in ids {
		box, found := donor_boxes[id]
		if !found { return added, fmt.tprintf("%s: instanceID %d has no tag-2 box in donor %s", ens_path, id, donor_vis_path), false }
		append(out, D3_Vis_Object{tag = 2, index = id, lo = box.lo, hi = box.hi})
		added += 1
	}
	return added, "", true
}

// How `ornaments.bin`'s own instances get their tag-2 id.
// `Skip`: leave them out of tag 2 entirely (confirmed safe).
// `Donor`: nearest-box match against `donor_vis_path` (confirmed safe; the
// donor must already carry the real answer, so this only works for existing,
// unmodified content).
// `Random`: an unclaimed id picked with no real source at all — an
// experiment to see whether *any* unclaimed id is safe, or whether it has to
// trace back to something real. See [[dirt3-ornaments-vis-crash]].
D3_Ornaments_Id_Mode :: enum { Skip, Donor, Random, Synthesized }

// `ornaments.bin`'s own instances for one `D3_Ornaments_Id_Mode`. `out` must
// already hold every `objects.ens` object, so `Random` can avoid colliding
// with those real ids.
@(private = "file")
d3_ornaments_step :: proc(
	out: ^[dynamic]D3_Vis_Object,
	mode: D3_Ornaments_Id_Mode,
	route_dir, donor_vis_path: string,
) -> (
	added, skipped: int,
	desc: string,
	ok: bool,
) {
	switch mode {
	case .Skip:
		return 0, 0, "skipped", true
	case .Donor:
		if donor_vis_path == "" {
			return 0, 0, "ornaments.bin needs a donor to recover its real tag-2 ids from (see d3_append_ornaments_with_donor_ids)", false
		}
		ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)
		ornaments_xml_path, _ := filepath.join({route_dir, "ornaments.xml"}, context.temp_allocator)
		donor_added, donor_skipped, add_msg, add_ok := d3_append_ornaments_with_donor_ids(out, ornaments_path, ornaments_xml_path, donor_vis_path)
		if !add_ok { return 0, 0, add_msg, false }
		return added, skipped, fmt.tprintf("%d real ids, %d not in donor's tag-2 set", added, skipped), true
	case .Random:
		avoid := make(map[u32]bool, context.temp_allocator)
		for obj in out^ { if obj.tag == 2 { avoid[obj.index] = true } }
		ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)
		random_added, add_msg, add_ok := d3_append_ornaments_with_random_ids(out, ornaments_path, avoid)
		if !add_ok { return 0, 0, add_msg, false }
		return random_added, 0, fmt.tprintf("%d, random unclaimed ids", random_added), true
	case .Synthesized:
		ornaments_path, _ := filepath.join({route_dir, "ornaments.bin"}, context.temp_allocator)
		authored_added, add_msg, add_ok := d3_append_placement_objects(out, ornaments_path, 2)
		if !add_ok { return 0, 0, add_msg, false }
		return authored_added, 0, fmt.tprintf("%d authored ids", authored_added), true
	}
	return 0, 0, "", true
}

// Every object this codebase can currently derive a safe header count for:
// tag-0 tile boxes (venue tracksplit then route routesplit, engine reverse
// order) and every tree. `venue_dir` is the location
// directory tracksplit.pssg lives in; `route_dir` is the route inside it.
// `ornaments_mode` controls `ornaments.bin`'s own instances (`Donor` requires
// `donor_vis_path`). `donor_vis_path`, when non-empty, also pulls in every
// `objects.ens` static-vis entity with its real id (see
// d3_append_ens_static_vis_objects) — gathered first so `Random` can avoid
// colliding with those real ids.
d3_stock_route_all_visible_objects :: proc(
	route_dir, venue_dir, donor_vis_path: string,
	ornaments_mode: D3_Ornaments_Id_Mode,
	allocator := context.allocator,
) -> (
	objects: []D3_Vis_Object,
	msg: string,
	ok: bool,
) {
	out := make([dynamic]D3_Vis_Object, allocator)
	defer if !ok { delete(out) }

	// The venue's tracksplit tiles hold the low indices, the route's own
	// routesplit tiles the high ones (Moosylvania: 0..28 then 38..69, the
	// "lead" a route's own retile must offset by) — two ascending blocks, not
	// one list reversed as a unit. Reversing the whole concatenation instead
	// of each source on its own scrambles which real drawable an index names,
	// which is exactly what emptied the terrain on the first drive of this.
	tracksplit_path, _ := filepath.join({venue_dir, "tracksplit.pssg"}, context.temp_allocator)
	routesplit_path, _ := filepath.join({route_dir, "routesplit.pssg"}, context.temp_allocator)
	tile_total := 0
	next_index := u32(0)
	for path in ([]string{tracksplit_path, routesplit_path}) {
		tiles, tile_msg, tile_ok := d3_read_pssg_tile_boxes(path, context.temp_allocator)
		if !tile_ok { return nil, tile_msg, false }
		tile_total += len(tiles)
		// Within one source, the engine enumerates tile nodes in reverse
		// traversal order.
		for i in 0 ..< len(tiles) {
			box := tiles[len(tiles)-1-i]
			append(&out, D3_Vis_Object{tag = 0, index = next_index, lo = box.lo, hi = box.hi})
			next_index += 1
		}
	}

	trees_path, _ := filepath.join({route_dir, "trees.bin"}, context.temp_allocator)
	trees_added, trees_msg, trees_ok := d3_append_placement_objects(&out, trees_path, 3)
	if !trees_ok { return nil, trees_msg, false }

	// Gathered before ornaments.bin so D3_Ornaments_Id_Mode.Random can avoid
	// colliding with these real ids.
	ens_added := 0
	if donor_vis_path != "" {
		ens_path, _ := filepath.join({route_dir, "objects.ens"}, context.temp_allocator)
		added, ens_msg, ens_ok := d3_append_ens_static_vis_objects(&out, ens_path, donor_vis_path)
		if !ens_ok { return nil, ens_msg, false }
		ens_added = added
	}

	_, _, ornaments_mode_msg, ornaments_ok := d3_ornaments_step(&out, ornaments_mode, route_dir, donor_vis_path)
	if !ornaments_ok { return nil, ornaments_mode_msg, false }

	if len(out) == 0 { return nil, "found no objects to make visible", false }
	return out[:], fmt.tprintf(
		"tag 0 (surface): %d tiles; tag 2 (ornaments.bin): %s; tag 2 (objects.ens static-vis): %d; tag 3 (trees): %d",
		tile_total, ornaments_mode_msg, ens_added, trees_added,
	), true
}

// `donor_vis_path`, when non-empty, floors every tag's header count at the
// donor file's own count for that tag — see d3_vis_build_single_cell. Pass
// the route's own stock backup to keep a tag whose derived count is known to
// undersell the real one (ornaments) from sizing the game's allocation too
// small.
d3_stock_route_all_visible_vis :: proc(
	route_dir, venue_dir, donor_vis_path: string,
	ornaments_mode: D3_Ornaments_Id_Mode,
	allocator := context.allocator,
	header_floor := [16]u32{},
) -> (
	out: []u8,
	msg: string,
	ok: bool,
) {
	objects, objects_msg, objects_ok := d3_stock_route_all_visible_objects(route_dir, venue_dir, donor_vis_path, ornaments_mode, context.temp_allocator)
	if !objects_ok { return nil, objects_msg, false }

	effective_floor := header_floor
	donor_msg := "no donor"
	if donor_vis_path != "" {
		donor_data, donor_read_msg, donor_read_ok := d3_read_or_fail(donor_vis_path, context.temp_allocator)
		if !donor_read_ok { return nil, donor_read_msg, false }
		floor_ok: bool
		donor_floor: [16]u32
		donor_floor, floor_ok = d3_vis_read_header_tag_counts(donor_data)
		if !floor_ok { return nil, fmt.tprintf("%s: too short to hold a Dirt 3 VIS header", donor_vis_path), false }
		for count, tag in donor_floor { effective_floor[tag] = max(effective_floor[tag], count) }
		donor_msg = fmt.tprintf("header floors from %s", donor_vis_path)
	}

	built, build_msg, built_ok := d3_vis_build_single_cell(objects, effective_floor, allocator)
	if !built_ok { return nil, build_msg, false }
	return built, fmt.tprintf("%s -- %s -- %s", objects_msg, donor_msg, build_msg), true
}

// `--dirt3-vis-allvisible <route_dir> <venue_dir> [--donor track.vis] [--ornaments skip|donor|random] [-o out.vis]`:
// build an all-visible track.vis for an existing stock route from its own
// files. Never touches the route directly; installing the result is a manual
// step.
dirt3_vis_allvisible_headless :: proc(route_dir, venue_dir, donor_vis_path, out_path: string, ornaments_mode: D3_Ornaments_Id_Mode) -> (msg: string, ok: bool) {
	data, build_msg, built := d3_stock_route_all_visible_vis(route_dir, venue_dir, donor_vis_path, ornaments_mode, context.allocator)
	if !built { return build_msg, false }
	defer delete(data)
	if write_err := os.write_entire_file(out_path, data); write_err != nil {
		return fmt.tprintf("could not write %s: %v", out_path, write_err), false
	}
	return fmt.tprintf("%s -> %s (%d bytes)\n%s", route_dir, out_path, len(data), build_msg), true
}
