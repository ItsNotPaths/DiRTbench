package d3

// Dirt 3 collision: the JPAK archive, and the `.vcqtc` quadtree chunks in it.
//
// This is the read half. It earns its place twice: it proves the format notes
// before the write half is ported, and then it is the oracle for that port —
// read a stock `track.jpk`, rebuild it, compare bytes.
//
// Only the Dirt 3 variant. The same container covers Race Driver: Grid through
// Dirt Rally, but the differences (material count, sheet support, sign of the
// material count) are not ours to carry.
//
// Layout is in docs/dirt3-target.md. Derived from EgoEngineLibrary, MIT,
// github.com/EgoEngineModding/Ego-Engine-Modding.
//
// The archive is little-endian. Inside a chunk the packed vertex, node and
// triangle fields are big-endian, which is why they are spelled out by byte.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// --- byte access -------------------------------------------------------------
// Out of range reads 0. Every offset is checked before use, so this only has to
// stop a malformed file from panicking, not diagnose it.

@(private = "file")
le_u32 :: proc(b: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) {
		return 0
	}
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

@(private = "file")
le_i32 :: proc(b: []u8, at: int) -> int {
	return int(i32(le_u32(b, at)))
}

@(private = "file")
le_f32 :: proc(b: []u8, at: int) -> f32 {
	return transmute(f32)le_u32(b, at)
}

@(private = "file")
le_vec3 :: proc(b: []u8, at: int) -> [3]f32 {
	return {le_f32(b, at), le_f32(b, at + 4), le_f32(b, at + 8)}
}

// The name tables store plain NUL-terminated strings back to back.
@(private = "file")
str_at :: proc(b: []u8, at: int) -> string {
	if at < 0 || at >= len(b) {
		return ""
	}
	for i in at ..< len(b) {
		if b[i] == 0 {
			return string(b[at:i])
		}
	}
	return string(b[at:])
}

// --- JPAK --------------------------------------------------------------------

@(private = "file")
JPAK_HEADER :: 32
@(private = "file")
JPAK_ENTRY :: 32

// One archive member. `data` slices the archive, so it lives as long as the
// bytes passed to `jpak_read` and must not be freed on its own.
Jpak_Entry :: struct {
	name: string,
	data: []u8,
}

// `route_N/track.jpk` holds one `.vcqtc` per quadtree leaf, plus a `qt.info`
// carrying the bounding box of the whole route.
jpak_read :: proc(
	raw: []u8,
	allocator := context.allocator,
) -> (
	entries: []Jpak_Entry,
	ok: bool,
) {
	if len(raw) < JPAK_HEADER || string(raw[:4]) != "JPAK" {
		return nil, false
	}
	count := le_i32(raw, 8)
	if count < 0 || JPAK_HEADER + count * JPAK_ENTRY > len(raw) {
		return nil, false
	}

	out := make([]Jpak_Entry, count, allocator)
	for i in 0 ..< count {
		at := JPAK_HEADER + i * JPAK_ENTRY
		name_at := le_i32(raw, at)
		size := le_i32(raw, at + 4)
		data_at := le_i32(raw, at + 8)
		if size < 0 || data_at < 0 || data_at + size > len(raw) {
			delete(out, allocator)
			return nil, false
		}
		out[i] = {name = str_at(raw, name_at), data = raw[data_at:][:size]}
	}
	return out, true
}

// --- .vcqtc ------------------------------------------------------------------

@(private = "file")
QT_HEADER :: 52
@(private = "file")
QT_VERTEX :: 8
@(private = "file")
QT_TRI :: 4
// X and Z quantize over 24 bits, Y over 16.
@(private = "file")
QT_SCALE :: [3]f32{1.0 / f32(1 << 24), 1.0 / f32(1 << 16), 1.0 / f32(1 << 24)}

Qt_Tri :: struct {
	v:     [3]int, // into `Qt_Chunk.verts`
	mat:   int,    // into `Qt_Chunk.mats`
	sheet: int,    // 2 bits; Dirt 3 keeps the `*`/`+` in the code itself
}

// One decoded chunk. `mats` slices the chunk bytes; `verts` and `tris` are
// allocated. Positions are world space, metres, Y up — the same frame the
// editor works in, so nothing needs converting.
Qt_Chunk :: struct {
	bounds_min: [3]f32,
	bounds_max: [3]f32,
	mats:       []string, // 4 characters each, a surface code
	verts:      [][3]f32,
	tris:       []Qt_Tri,
	nodes:      []u16, // the quadtree itself, kept for validation
	refs:       []u8,  // delta-coded per-leaf triangle lists
}

qt_chunk_delete :: proc(c: ^Qt_Chunk, allocator := context.allocator) {
	delete(c.mats, allocator)
	delete(c.verts, allocator)
	delete(c.tris, allocator)
	delete(c.nodes, allocator)
}

// The triangle and vertex counts are stored negated, and the material count is
// not. `VcQuadTreeFile.Identify` leans on that: a negative material count means
// Dirt 2 or Race Driver: Grid, and 16 means Dirt 3.
qt_read :: proc(
	b: []u8,
	allocator := context.allocator,
) -> (
	c: Qt_Chunk,
	msg: string,
	ok: bool,
) {
	if len(b) < QT_HEADER {
		return c, "chunk is shorter than its header", false
	}
	num_tris := -le_i32(b, 24)
	num_verts := -le_i32(b, 28)
	num_mats := le_i32(b, 32)
	verts_at := le_i32(b, 36)
	nodes_at := le_i32(b, 40)
	tris_at := le_i32(b, 44)
	refs_at := le_i32(b, 48)

	if num_mats != 16 {
		return c, fmt.tprintf("not a Dirt 3 chunk: material count is %d, want 16", num_mats), false
	}
	if num_tris < 0 || num_verts < 0 {
		return c, "negative triangle or vertex count", false
	}
	// Sections are laid out in this order and pack tight, so each offset is the
	// end of the one before it.
	if QT_HEADER + num_mats * 4 != verts_at ||
	   verts_at + num_verts * QT_VERTEX != nodes_at ||
	   tris_at + num_tris * QT_TRI != refs_at ||
	   refs_at > len(b) ||
	   nodes_at > tris_at {
		return c, "section offsets disagree with the counts", false
	}

	c.bounds_min = le_vec3(b, 0)
	c.bounds_max = le_vec3(b, 12)

	c.mats = make([]string, num_mats, allocator)
	for i in 0 ..< num_mats {
		c.mats[i] = string(b[QT_HEADER + i * 4:][:4])
	}

	// Positions are quantized over the chunk's own bounding box, so every chunk
	// decodes against its own scale.
	scale := (c.bounds_max - c.bounds_min) * QT_SCALE
	c.verts = make([][3]f32, num_verts, allocator)
	for i in 0 ..< num_verts {
		v := b[verts_at + i * QT_VERTEX:]
		q := [3]f32 {
			f32(int(v[0]) << 16 | int(v[1]) << 8 | int(v[2])),
			f32(int(v[3]) << 8 | int(v[4])),
			f32(int(v[5]) << 16 | int(v[6]) << 8 | int(v[7])),
		}
		c.verts[i] = q * scale + c.bounds_min
	}

	// Vertex 0 is 10 bits; the other two are byte offsets from it. That cap is
	// what the writer's PatchUp pass exists to satisfy.
	c.tris = make([]Qt_Tri, num_tris, allocator)
	for i in 0 ..< num_tris {
		t := b[tris_at + i * QT_TRI:]
		v0 := int(t[0] & 0x3F) << 4 | int(t[1] >> 4)
		c.tris[i] = {
			v     = {v0, v0 + int(t[2]), v0 + int(t[3])},
			mat   = int(t[1] & 0x0F),
			sheet = int(t[0] >> 6),
		}
		for v in c.tris[i].v {
			if v >= num_verts {
				qt_chunk_delete(&c, allocator)
				return c, fmt.tprintf("triangle %d indexes vertex %d of %d", i, v, num_verts), false
			}
		}
	}

	num_nodes := (tris_at - nodes_at) / 2
	c.nodes = make([]u16, num_nodes, allocator)
	for i in 0 ..< num_nodes {
		n := b[nodes_at + i * 2:]
		c.nodes[i] = u16(n[0]) << 8 | u16(n[1])
	}
	c.refs = b[refs_at:]
	return c, "", true
}

// --- the quadtree ------------------------------------------------------------

qt_node_is_leaf :: proc(n: u16) -> bool {
	return n & 0x8000 != 0
}

qt_node_has_tris :: proc(n: u16) -> bool {
	return qt_node_is_leaf(n) && n != 0xFFFF
}

// A leaf's triangle list: two big-endian bytes for the first index, then one
// byte per step. 254 continues a gap without emitting, 255 ends the list.
qt_leaf_tris :: proc(refs: []u8, at: int, out: ^[dynamic]int) -> bool {
	clear(out)
	if at < 0 || at + 3 > len(refs) {
		return false
	}
	cur := int(refs[at]) << 8 | int(refs[at + 1])
	append(out, cur)
	for i := at + 2; i < len(refs); i += 1 {
		switch refs[i] {
		case 0xFF:
			return true
		case 0xFE:
			cur += 0xFE
		case:
			cur += int(refs[i])
			append(out, cur)
		}
	}
	return false // ran off the end without a terminator
}

// Walks every leaf and makes sure the tree agrees with the triangle array:
// every referenced index is in range, and every triangle is reachable. A
// triangle can sit in several leaves, because a leaf takes any triangle that
// overlaps its rectangle.
qt_validate :: proc(c: ^Qt_Chunk) -> (msg: string, ok: bool) {
	seen := make([]bool, len(c.tris), context.temp_allocator)
	list := make([dynamic]int, context.temp_allocator)
	leaves := 0

	for n, i in c.nodes {
		if !qt_node_has_tris(n) {
			continue
		}
		leaves += 1
		if !qt_leaf_tris(c.refs, int(n & 0x7FFF), &list) {
			return fmt.tprintf("node %d has an unterminated triangle list", i), false
		}
		for t in list {
			if t < 0 || t >= len(c.tris) {
				return fmt.tprintf("node %d references triangle %d of %d", i, t, len(c.tris)), false
			}
			seen[t] = true
		}
	}

	for s, i in seen {
		if !s {
			return fmt.tprintf("triangle %d is in no leaf", i), false
		}
	}
	if leaves == 0 && len(c.tris) > 0 {
		return "chunk has triangles but no leaf holds them", false
	}
	return "", true
}

// --- OBJ ---------------------------------------------------------------------

// Colours for the surface codes, straight off `surface_materials.xml`. Only the
// ones Finland uses; anything else falls back to grey, which reads as "a code
// this table has not met yet" rather than as a wrong colour.
@(private = "file")
QT_COLOURS := [][2]string {
	{"GLD", "0.616 0.565 0.369"}, // gravel, light and dry — the road
	{"GBK", "0.843 0.820 0.733"}, // gravel bank
	{"GRS", "0.000 1.000 0.000"}, // grass
	{"GSL", "0.000 1.000 0.000"}, // grass and leaves
	{"ROK", "0.843 0.820 0.733"}, // rock
	{"TSD", "0.502 0.502 0.502"}, // tarmac, smooth and dry
	{"WDS", "0.502 0.251 0.000"}, // wooden slat
}

@(private = "file")
qt_colour :: proc(code: string) -> string {
	for c in QT_COLOURS {
		if len(code) >= 3 && code[:3] == c[0] {
			return c[1]
		}
	}
	return "0.400 0.400 0.400"
}

// One OBJ plus its MTL, grouped by surface code so a parse can be judged by
// looking at it. Materials are what make it readable: the road has to come out
// as one continuous ribbon of `GLD`, or the parse is wrong.
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
