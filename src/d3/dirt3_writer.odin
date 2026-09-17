package d3

// Dirt 3 collision writer, ported from EgoEngineModding/Ego-Engine-Modding
// (MIT).  This first slice deliberately writes one vcqtc leaf: it is the
// complete packed writer needed by the straight-ramp game test.  Spatial
// splitting for full stages comes next; keeping it out of this test makes a
// bad packed field distinguishable from a bad partitioner.

import "core:fmt"
import "core:math"
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

d3_put_f32 :: proc(b: []u8, at: int, v: f32) { d3_put_u32(b, at, transmute(u32)v) }

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
