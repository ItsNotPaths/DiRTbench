package d3

// Dirt 3 collision writer, ported from EgoEngineModding/Ego-Engine-Modding
// (MIT).  This first slice deliberately writes one vcqtc leaf: it is the
// complete packed writer needed by the straight-ramp game test.  Spatial
// splitting for full stages comes next; keeping it out of this test makes a
// bad packed field distinguishable from a bad partitioner.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

D3_Write_Tri :: struct {
	p:   [3][3]f32,
	mat: string,
}

D3_Packed_Tri :: struct {
	v:   [3]int,
	mat: int,
}

@(private = "file")
d3_put_u32 :: proc(b: []u8, at: int, v: u32) {
	binary_store_u32(b, at, v)
}

@(private = "file")
d3_put_i32 :: proc(b: []u8, at: int, v: int) { d3_put_u32(b, at, u32(i32(v))) }

@(private = "file")
d3_put_f32 :: proc(b: []u8, at: int, v: f32) { d3_put_u32(b, at, transmute(u32)v) }

@(private = "file")
d3_get_f32 :: proc(b: []u8, at: int) -> f32 {
	return binary_load_f32(b, at)
}

@(private = "file")
d3_align16 :: proc(n: int) -> int { aligned, _ := binary_align_up(n, 16); return aligned }

@(private = "file")
d3_same_pos :: proc(a, b: [3]f32) -> bool {
	return math.abs(a[0] - b[0]) < 0.0001 && math.abs(a[1] - b[1]) < 0.0001 && math.abs(a[2] - b[2]) < 0.0001
}

@(private = "file")
d3_lowest_first :: proc(t: ^D3_Packed_Tri) {
	a, b, c := t.v[0], t.v[1], t.v[2]
	if b < a && b < c {
		t.v = {b, c, a}
	} else if c < a {
		t.v = {c, a, b}
	}
}

// This is QuadTreeMeshData.PatchUp. Vertex zero has ten bits and the other
// indices are unsigned byte offsets from it, so move a far vertex toward the
// triangle's minimum and repair every affected index. Restart after each move,
// because repairing one triangle can disturb an earlier one.
@(private = "file")
d3_patch_indices :: proc(verts: ^[dynamic][3]f32, tris: ^[dynamic]D3_Packed_Tri) -> bool {
	if len(tris) == 0 { return true }
	limit, moves, ti := len(tris) * 3, 0, 0
	for ti < len(tris) {
		t := tris[ti]
		lo := min(t.v[0], min(t.v[1], t.v[2]))
		far := -1
		for vi in t.v {
			if vi - lo > 255 { far = vi; break }
		}
		if far < 0 { ti += 1; continue }

		insert := lo + 204 // upstream: 255 - 255/5
		if insert >= far { return false }
		moved := verts[far]
		for i := far; i > insert; i -= 1 { verts[i] = verts[i - 1] }
		verts[insert] = moved
		for &other in tris {
			for &index in other.v {
				if index == far { index = insert } else if index >= insert && index < far { index += 1 }
			}
		}
		moves += 1
		if moves >= limit { return false }
		ti = 0
	}
	for &t in tris { d3_lowest_first(&t) }
	return true
}

// Create one Dirt 3 .vcqtc chunk. The root is a leaf containing every
// triangle. That is a valid quadtree and intentionally sufficient for the
// small ramp oracle; the full-stage splitter can later wrap this exact encoder.
d3_vcqtc_write :: proc(input: []D3_Write_Tri, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	if len(input) == 0 || len(input) > 65535 { return nil, "a collision chunk needs 1..65535 triangles", false }
	verts := make([dynamic][3]f32, allocator); defer delete(verts)
	tris := make([dynamic]D3_Packed_Tri, allocator); defer delete(tris)
	mats := make([dynamic]string, allocator); defer delete(mats)
	bmin := [3]f32{3.4028234e38, 3.4028234e38, 3.4028234e38}
	bmax := [3]f32{-3.4028234e38, -3.4028234e38, -3.4028234e38}

	for source in input {
		if len(source.mat) != 4 { return nil, fmt.tprintf("surface code %q is not 4 characters", source.mat), false }
		mi := -1
		for m, i in mats { if m == source.mat { mi = i; break } }
		if mi < 0 { mi = len(mats); append(&mats, source.mat) }
		if len(mats) > 16 { return nil, "a Dirt 3 chunk cannot contain more than 16 materials", false }
		t := D3_Packed_Tri{mat = mi}
		for p, corner in source.p {
			vi := -1
			for v, i in verts { if d3_same_pos(v, p) { vi = i; break } }
			if vi < 0 { vi = len(verts); append(&verts, p) }
			t.v[corner] = vi
			for axis in 0..<3 { bmin[axis] = min(bmin[axis], p[axis]); bmax[axis] = max(bmax[axis], p[axis]) }
		}
		d3_lowest_first(&t)
		append(&tris, t)
	}
	if len(verts) > 1279 { return nil, fmt.tprintf("chunk has %d vertices; split it below 1280", len(verts)), false }
	if !d3_patch_indices(&verts, &tris) { return nil, "could not make triangle indices encodable", false }
	for t in tris { if t.v[0] > 1023 || t.v[1] - t.v[0] > 255 || t.v[2] - t.v[0] > 255 { return nil, "patched triangle is outside packed-index limits", false } }

	// The upstream writer pads every axis by 0.1 m, avoiding zero spans and
	// ensuring vertices never quantize outside their chunk bounds.
	for axis in 0..<3 { bmin[axis] -= 0.1; bmax[axis] += 0.1 }
	refs_size := 3 // first u16 + terminator
	for i in 1..<len(tris) { gap := i - (i - 1); refs_size += gap / 254 + 1 }
	header := 52 + 16 * 4
	verts_at := header
	nodes_at := verts_at + len(verts) * 8
	tris_at := nodes_at + 2
	refs_at := tris_at + len(tris) * 4
	out = make([]u8, refs_at + refs_size, allocator)
	for axis in 0..<3 { d3_put_f32(out, axis * 4, bmin[axis]); d3_put_f32(out, 12 + axis * 4, bmax[axis]) }
	d3_put_i32(out, 24, -len(tris)); d3_put_i32(out, 28, -len(verts)); d3_put_i32(out, 32, 16)
	d3_put_i32(out, 36, verts_at); d3_put_i32(out, 40, nodes_at); d3_put_i32(out, 44, tris_at); d3_put_i32(out, 48, refs_at)
	fill := mats[len(mats) - 1]
	for i in 0..<16 { m := fill; if i < len(mats) { m = mats[i] }; copy(out[52 + i * 4:][:4], transmute([]u8)m) }

	for v, i in verts {
		q: [3]u32
		q[0] = u32(math.clamp((v[0] - bmin[0]) / (bmax[0] - bmin[0]) * f32(1 << 24) + 0.5, 0, f32((1 << 24) - 1)))
		q[1] = u32(math.clamp((v[1] - bmin[1]) / (bmax[1] - bmin[1]) * f32(1 << 16) + 0.5, 0, f32((1 << 16) - 1)))
		q[2] = u32(math.clamp((v[2] - bmin[2]) / (bmax[2] - bmin[2]) * f32(1 << 24) + 0.5, 0, f32((1 << 24) - 1)))
		at := verts_at + i * 8
		out[at] = u8(q[0] >> 16); out[at+1] = u8(q[0] >> 8); out[at+2] = u8(q[0])
		out[at+3] = u8(q[1] >> 8); out[at+4] = u8(q[1])
		out[at+5] = u8(q[2] >> 16); out[at+6] = u8(q[2] >> 8); out[at+7] = u8(q[2])
	}
	// Single root leaf, triangle-list offset zero.
	out[nodes_at] = 0x80; out[nodes_at + 1] = 0
	for t, i in tris {
		at := tris_at + i * 4; v0 := t.v[0]
		out[at] = u8(v0 >> 4); out[at + 1] = u8(v0 << 4) | u8(t.mat)
		out[at + 2] = u8(t.v[1] - v0); out[at + 3] = u8(t.v[2] - v0)
	}
	out[refs_at] = 0; out[refs_at + 1] = 0
	for i in 1..<len(tris) { out[refs_at + 1 + i] = 1 }
	out[len(out) - 1] = 0xFF
	return out, "", true
}

D3_Jpak_Source :: struct { name: string, data: []u8 }

D3_Partition_Cell :: struct {
	lo, hi: [2]f32,
	level:  int,
	name:   string,
	tris:   []int,
}

d3_jpak_write :: proc(entries: []D3_Jpak_Source, allocator := context.allocator) -> []u8 {
	names_end := 32 + len(entries) * 32 + 1
	for e in entries { names_end += len(e.name) + 1 }
	data_at := d3_align16(names_end)
	total := data_at
	for e in entries { total += d3_align16(len(e.data)) }
	out := make([]u8, total, allocator)
	copy(out[:4], []u8{'J','P','A','K'}); d3_put_i32(out, 8, len(entries)); d3_put_i32(out, 12, 16); d3_put_i32(out, 20, 32 + len(entries) * 32)
	name_at := 32 + len(entries) * 32 + 1
	file_at := data_at
	for e, i in entries {
		at := 32 + i * 32
		d3_put_i32(out, at, name_at); d3_put_i32(out, at + 4, len(e.data)); d3_put_i32(out, at + 8, file_at); d3_put_i32(out, at + 12, len(e.data))
		copy(out[name_at:], e.name); name_at += len(e.name) + 1
		copy(out[file_at:], e.data); file_at += d3_align16(len(e.data))
	}
	return out
}

@(private = "file")
d3_tri_hits_cell :: proc(t: D3_Write_Tri, lo, hi: [2]f32) -> bool {
	// SAT in XZ: the rectangle axes, followed by the three triangle-edge
	// normals. Touching a boundary counts, deliberately duplicating seam faces.
	for axis in 0..<5 {
		n := [2]f32{}
		if axis == 0 { n = {1, 0} } else if axis == 1 { n = {0, 1} } else {
			a, b := t.p[axis-2], t.p[(axis-1)%3]
			e := [2]f32{b[0]-a[0], b[2]-a[2]}; n = {-e[1], e[0]}
		}
		corners := [4][2]f32{{lo[0],lo[1]},{hi[0],lo[1]},{hi[0],hi[1]},{lo[0],hi[1]}}
		rmin, rmax := corners[0][0]*n[0]+corners[0][1]*n[1], corners[0][0]*n[0]+corners[0][1]*n[1]
		for i in 1..<4 { p:=corners[i][0]*n[0]+corners[i][1]*n[1]; rmin=min(rmin,p); rmax=max(rmax,p) }
		tmin, tmax := t.p[0][0]*n[0]+t.p[0][2]*n[1], t.p[0][0]*n[0]+t.p[0][2]*n[1]
		for i in 1..<3 { p:=t.p[i][0]*n[0]+t.p[i][2]*n[1]; tmin=min(tmin,p); tmax=max(tmax,p) }
		if rmax < tmin || tmax < rmin { return false }
	}
	return true
}

// Quantized to the same 0.0001 epsilon `d3_same_pos` used before this was a
// map key: two positions within that distance hash identically. A linear
// scan per vertex against every vertex seen so far was O(k^2) in a cell's own
// triangle count -- fine at the small, synthetic scale every caller used
// until a real stock route's full ~456k triangles were fed through in one
// flat soup, where it made partitioning too slow to be usable.
@(private = "file")
d3_quantize_pos :: proc(p: [3]f32) -> [3]i32 {
	return {i32(math.round(p[0]*10000)), i32(math.round(p[1]*10000)), i32(math.round(p[2]*10000))}
}

// docs/dirt3-target.md records the real per-chunk budget every stock DiRT 3
// .vcqtc was built to: 1565 triangles, 929 vertices (materials already
// capped at 16 below). Vertex 0 of a packed triangle has only 10 bits, so
// 1024 unique vertices is the hard ceiling regardless -- but nothing shipped
// ever gets within 95 of it. d3_vcqtc_write's own PatchUp pass only reorders
// existing vertices to satisfy the 255-offset constraint between a
// triangle's corners; it never adds one, so this is the only place that
// controls how many a chunk ends up with. Matching the real margin here,
// not just the hard limit, is what a load-time crash unrelated to anything
// in this file (a null read deep in unrelated render-task setup) pointed
// back to: something sized for the stock budget elsewhere in the engine,
// overrun by chunks bigger than any real one ever was.
D3_CHUNK_TRI_BUDGET :: 1565
D3_CHUNK_VERT_BUDGET :: 929

@(private = "file")
d3_partition_should_split :: proc(input: []D3_Write_Tri, ids: []int) -> bool {
	if len(ids) > D3_CHUNK_TRI_BUDGET { return true }
	verts := make(map[[3]i32]bool, context.temp_allocator)
	defer delete(verts)
	mats := make(map[string]bool, context.temp_allocator)
	defer delete(mats)
	for id in ids {
		t := input[id]
		if !mats[t.mat] {
			mats[t.mat] = true
			if len(mats) > 16 { return true }
		}
		for p in t.p {
			key := d3_quantize_pos(p)
			if !verts[key] {
				verts[key] = true
				if len(verts) > D3_CHUNK_VERT_BUDGET { return true }
			}
		}
	}
	return false
}

// Build Dirt 3's required archive-level spatial quadtree. Triangle/cell SAT
// assignment matches the reference writer; the packed chunk itself remains a
// single leaf, which the stock rewrite proved the game accepts.
d3_track_write :: proc(input: []D3_Write_Tri, allocator := context.allocator) -> (out: []u8, msg: string, ok: bool) {
	if len(input)==0 { return nil,"collision needs at least one triangle",false }
	bmin := [3]f32{3.4028234e38,3.4028234e38,3.4028234e38}; bmax := -bmin
	for t in input { for p in t.p { for axis in 0..<3 { bmin[axis]=min(bmin[axis],p[axis]); bmax[axis]=max(bmax[axis],p[axis]) } } }
	bmin-=0.1; bmax+=0.1
	root_ids:=make([]int,len(input),allocator); for _,i in root_ids { root_ids[i]=i }
	// `c.tris` and `root_ids` are plain slices, not `[dynamic]`, so unlike
	// `queue`/`leaves`/`owned`/`sources` below they carry no allocator of
	// their own -- deleting them bare would free through whatever
	// `context.allocator` happens to be at the call site, not through
	// `allocator`, and silently corrupt or crash the moment a caller passes
	// anything other than the default (found by feeding a full real-route
	// collision archive through with `context.temp_allocator`).
	queue:=make([dynamic]D3_Partition_Cell,allocator); defer { for c in queue { delete(c.tris, allocator) }; delete(queue) }
	append(&queue,D3_Partition_Cell{lo={bmin[0],bmin[2]},hi={bmax[0],bmax[2]},name="qt",tris=root_ids})
	leaves:=make([dynamic]int,allocator); defer delete(leaves)
	for qi:=0; qi<len(queue); qi+=1 {
		c:=queue[qi]
		// The root must always split at least once: Dirt 3 selects collision
		// through the archive's entry-name grid, and a whole route collapsed
		// to one root .vcqtc entry loads and validates fine but the game never
		// finds it — the car falls through everything. Below-threshold input
		// (a small custom stage, unlike any stock route) used to hit exactly
		// that shape silently. See docs/dirt3-target.md, "archive topology
		// matters".
		if c.level>0 && !d3_partition_should_split(input,c.tris) { append(&leaves,qi); continue }
		if c.level>=16 { return nil,fmt.tprintf("%s still exceeds a chunk limit at level 16",c.name),false }
		mid:=(c.lo+c.hi)/2
		for child in 0..<4 {
			lo,hi:=c.lo,c.hi
			xbit:=child&1; zbit:=(child>>1)&1
			if xbit==0 { hi[0]=mid[0] } else { lo[0]=mid[0] }
			if zbit==0 { hi[1]=mid[1] } else { lo[1]=mid[1] }
			ids:=make([dynamic]int,allocator)
			for id in c.tris { if d3_tri_hits_cell(input[id],lo,hi) { append(&ids,id) } }
			if len(ids)>0 { append(&queue,D3_Partition_Cell{lo=lo,hi=hi,level=c.level+1,name=fmt.tprintf("%s_%d%d",c.name,xbit,zbit),tris=ids[:]}) } else { delete(ids) }
		}
	}
	sources:=make([dynamic]D3_Jpak_Source,allocator); owned:=make([dynamic][]u8,allocator)
	defer { for b in owned { delete(b, allocator) }; delete(owned); delete(sources) }
	// TrackGround.Save writes cells in spatial depth-first order, and its loader
	// verifies archive order against that traversal. Construction above is
	// breadth-first, so sort the leaf paths before assembling the JPAK.
	ordered:=make([]D3_Partition_Cell,len(leaves),context.temp_allocator)
	for li,i in leaves { ordered[i]=queue[li] }
	slice.sort_by(ordered,proc(a,b:D3_Partition_Cell)->bool{return a.name<b.name})
	for c in ordered {
		tris:=make([]D3_Write_Tri,len(c.tris),context.temp_allocator)
		for id,i in c.tris { tris[i]=input[id] }
		chunk,cmsg,cok:=d3_vcqtc_write(tris,allocator); if !cok { return nil,fmt.tprintf("%s: %s",c.name,cmsg),false }
		append(&owned,chunk); append(&sources,D3_Jpak_Source{fmt.tprintf("%s.vcqtc",c.name),chunk})
	}
	info:=make([]u8,24,allocator); append(&owned,info)
	for axis in 0..<3 { d3_put_f32(info,axis*4,bmin[axis]); d3_put_f32(info,12+axis*4,bmax[axis]) }
	append(&sources,D3_Jpak_Source{"qt.info",info})
	return d3_jpak_write(sources[:],allocator),fmt.tprintf("%d triangles partitioned into %d chunks",len(input),len(leaves)),true
}

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
