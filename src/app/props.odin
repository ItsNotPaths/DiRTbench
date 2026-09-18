package main

// Placed props: the ornaments, barriers and set dressing a venue puts beside
// its road, taken from the base venue's own art.
//
// A venue derives its art from a stock base (venue.odin), so the props it may
// place are exactly the ones that base ships: `objects.pssg` for ornaments and
// physics props, `trees.pssg` for the tree meshes. Both are read through
// d3.prop_lib, which hands back LOD0 positions and triangles and nothing else —
// no textures, no materials. The viewport shades each face flat off its own
// normal, which is enough to judge where a thing sits and how big it is.
//
// The catalogue lives on the document, so two windows onto one venue share one
// parse and one set of uploaded meshes. The placements live there too, and are
// saved in road.json. The browser's thumbnail is props_ui.odin's. Nothing here writes a game file: emitting these into
// `ornaments.bin` and `objects.ens` is the export's job and comes later.

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../geo"
import "../gfx"

// Which of the base venue's two libraries a prop comes from. The name alone is
// not a key: the two files are separate namespaces.
Prop_Lib_Kind :: enum u8 {
	Objects,
	Trees,
}

PROP_LIB_FILES := [Prop_Lib_Kind]string {
	.Objects = "objects.pssg",
	.Trees   = "trees.pssg",
}

// One prop of the base venue's art, named the way a placement file names it.
Prop_Ref :: struct {
	kind: Prop_Lib_Kind,
	name: string,
}

// One placed prop. The transform is the instance's alone — every prop mesh is
// straight model space, with no transform of its own to compose.
Prop_Instance :: struct {
	ref:   Prop_Ref,
	pos:   gfx.Vector3,
	rot:   gfx.Quaternion,
	scale: f32,
}

Prop_Catalog_State :: enum u8 {
	Unloaded,
	Ready,
	Failed,
}

// One prop's geometry as the viewport needs it: uploaded once, plus the model
// space box that picking and framing read.
//
// A prop the library does not hold is cached too, as `found = false`. Without
// that, a road.json naming a prop its base does not ship would re-walk the
// library once per prop per frame, for ever.
Prop_Drawable :: struct {
	mesh:  geo.Gpu_Mesh,
	lo:    gfx.Vector3,
	hi:    gfx.Vector3,
	found: bool,
}

// The base venue's libraries, parsed once per document.
//
// `meshes` is filled on demand and never evicted: a venue places a handful of
// distinct props out of a library of two hundred, and uploading the ones it
// uses costs a few hundred KB. The parse itself is the expensive half (tens of
// milliseconds for the largest library), which is why it happens on the first
// ask rather than when the venue opens.
Prop_Catalog :: struct {
	base:   string, // the "<location>/<venue>" it was read for
	state:  Prop_Catalog_State,
	msg:    string,
	libs:   [Prop_Lib_Kind]d3.Prop_Library,
	refs:   [dynamic]Prop_Ref, // objects then trees, each sorted by name
	meshes: map[Prop_Ref]Prop_Drawable,
}

// --- the catalogue -----------------------------------------------------------

// Where the base venue's art lives. A venue derives from a stock base, and the
// three library files sit at that base, one level above `route_n`.
prop_base_dir :: proc(doc: ^Venue_Doc) -> (dir: string, ok: bool) {
	slash := strings.index_byte(doc.base, '/')
	if slash < 0 || doc.install == nil || !doc.install.found {
		return "", false
	}
	venue, found := d3.install_venue(&doc.install.install, doc.base[:slash], doc.base[slash + 1:])
	if !found {
		return "", false
	}
	return venue.dir, true
}

// Parse both libraries. Idempotent: already loaded for this base is a no-op, and
// a base that changed under the document reloads.
prop_catalog_load :: proc(doc: ^Venue_Doc) -> (msg: string, ok: bool) {
	cat := &doc.props_lib
	if cat.state == .Ready && cat.base == doc.base {
		return "", true
	}
	prop_catalog_free(doc)
	dir, have_dir := prop_base_dir(doc)
	if !have_dir {
		cat.state = .Failed
		cat.msg = strings.clone("the base venue is not in the installed game")
		return cat.msg, false
	}
	for file, kind in PROP_LIB_FILES {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		lib, lib_msg, lib_ok := d3.prop_lib_open(path)
		if !lib_ok {
			prop_catalog_free(doc)
			cat.state = .Failed
			cat.msg = strings.clone(lib_msg)
			return cat.msg, false
		}
		cat.libs[kind] = lib
	}
	cat.refs = make([dynamic]Prop_Ref)
	for kind in Prop_Lib_Kind {
		for entry in cat.libs[kind].props {
			append(&cat.refs, Prop_Ref{kind = kind, name = entry.name})
		}
	}
	cat.base = strings.clone(doc.base)
	cat.state = .Ready
	return "", true
}

prop_catalog_free :: proc(doc: ^Venue_Doc) {
	cat := &doc.props_lib
	for ref, &drawable in cat.meshes {
		geo.gpu_mesh_unload(&drawable.mesh)
		delete(ref.name)
	}
	delete(cat.meshes)
	delete(cat.refs)
	for kind in Prop_Lib_Kind {
		d3.prop_lib_delete(&cat.libs[kind])
	}
	delete(cat.base)
	delete(cat.msg)
	cat^ = {}
}

// The uploaded geometry for one prop, read from the cache or built into it.
// Not ok when the catalogue is not loaded, or the library has no such prop.
prop_drawable :: proc(doc: ^Venue_Doc, ref: Prop_Ref) -> (drawable: Prop_Drawable, ok: bool) {
	cat := &doc.props_lib
	if cat.state != .Ready {
		return
	}
	if cached, seen := cat.meshes[ref]; seen {
		return cached, cached.found
	}
	if mesh, built := d3.prop_lib_mesh(&cat.libs[ref.kind], ref.name, context.temp_allocator); built {
		tri := prop_tri_mesh(mesh, PROP_BASE_COLOUR[ref.kind], context.temp_allocator)
		drawable = {
			mesh  = geo.gpu_mesh_upload(tri),
			lo    = {mesh.lo[0], mesh.lo[1], mesh.lo[2]},
			hi    = {mesh.hi[0], mesh.hi[1], mesh.hi[2]},
			found = true,
		}
	}
	// The key is the placement's own string, which is freed when the placement
	// is; the cache outlives it, so it keeps its own copy.
	cat.meshes[Prop_Ref{kind = ref.kind, name = strings.clone(ref.name)}] = drawable
	return drawable, drawable.found
}

// The two libraries are tinted apart because a tree placed by hand and a tree
// from the scatter should not look like the same thing.
PROP_BASE_COLOUR := [Prop_Lib_Kind][3]f32{
	.Objects = {0.72, 0.70, 0.66},
	.Trees   = {0.42, 0.62, 0.38},
}

// One fixed overhead-ish light, so untextured shape reads. Two-sided: a prop's
// sheet geometry (fences, foliage cards) is wound for the game's own culling,
// and a face lit from behind would read as a hole.
PROP_LIGHT :: gfx.Vector3{0.35, 0.86, 0.36}

prop_face_shade :: proc(n, light: gfx.Vector3) -> f32 {
	return 0.35 + 0.65 * abs(gfx.Vector3DotProduct(n, light))
}

prop_shade_colour :: proc(base: [3]f32, shade: f32) -> [3]u8 {
	return {
		u8(clamp(base[0] * shade, 0, 1) * 255),
		u8(clamp(base[1] * shade, 0, 1) * 255),
		u8(clamp(base[2] * shade, 0, 1) * 255),
	}
}

// Flat-shade the triangles into a viewport mesh. The colour is baked per face:
// the scene shader carries no lighting, so the only place shading can happen is
// here.
prop_tri_mesh :: proc(
	src: d3.Prop_Mesh, base: [3]f32, allocator := context.allocator,
) -> geo.Tri_Mesh {
	m := geo.tri_mesh_make(allocator)
	light := gfx.Vector3Normalize(PROP_LIGHT)
	for i := 0; i + 2 < len(src.tris); i += 3 {
		a := gfx.Vector3(src.pos[src.tris[i]])
		b := gfx.Vector3(src.pos[src.tris[i + 1]])
		c := gfx.Vector3(src.pos[src.tris[i + 2]])
		n := gfx.Vector3Normalize(gfx.Vector3CrossProduct(b - a, c - a))
		rgb := prop_shade_colour(base, prop_face_shade(n, light))
		col := gfx.Color{rgb[0], rgb[1], rgb[2], 255}
		append(&m.pos, a, b, c)
		append(&m.nrm, n, n, n)
		append(&m.uv, [2]f32{}, [2]f32{}, [2]f32{})
		append(&m.col, col, col, col)
		append(&m.mat, geo.Mat_Id.Terrain)
	}
	return m
}

// --- placements ---------------------------------------------------------------

PROP_SCALE_MIN :: 0.1

PROP_SCALE_MAX :: 8.0

prop_instance_xform :: proc(inst: Prop_Instance) -> gfx.Matrix {
	translate := gfx.MatrixTranslate(inst.pos.x, inst.pos.y, inst.pos.z)
	rotate := gfx.QuaternionToMatrix(inst.rot)
	scale := gfx.Matrix(1)
	scale[0, 0], scale[1, 1], scale[2, 2] = inst.scale, inst.scale, inst.scale
	return translate * rotate * scale
}

// The instance's model box in world space: all eight corners transformed, then
// re-bounded. A rotated prop's box is wider than its model box, which is what
// picking has to test against.
prop_world_bounds :: proc(doc: ^Venue_Doc, inst: Prop_Instance) -> (lo, hi: gfx.Vector3, ok: bool) {
	drawable, have := prop_drawable(doc, inst.ref)
	if !have {
		return
	}
	xform := prop_instance_xform(inst)
	for corner in 0 ..< 8 {
		local := gfx.Vector3{
			corner & 1 != 0 ? drawable.hi.x : drawable.lo.x,
			corner & 2 != 0 ? drawable.hi.y : drawable.lo.y,
			corner & 4 != 0 ? drawable.hi.z : drawable.lo.z,
		}
		p := xform * [4]f32{local.x, local.y, local.z, 1}
		world := gfx.Vector3{p.x, p.y, p.z}
		if corner == 0 {
			lo, hi = world, world
			continue
		}
		for k in 0 ..< 3 {
			lo[k] = min(lo[k], world[k])
			hi[k] = max(hi[k], world[k])
		}
	}
	return lo, hi, true
}

// Drop a prop on the ground, standing upright and unrotated. Yaw is the one
// thing worth varying per instance and the gizmo is where that is done, so a
// fresh placement is deliberately plain.
prop_place :: proc(doc: ^Venue_Doc, ref: Prop_Ref, at: gfx.Vector3) -> int {
	append(&doc.props, Prop_Instance{
		ref   = {kind = ref.kind, name = strings.clone(ref.name)},
		pos   = at,
		rot   = gfx.Quaternion(1),
		scale = 1,
	})
	mark_edited(doc)
	return len(doc.props) - 1
}

prop_remove :: proc(doc: ^Venue_Doc, idx: int) {
	if idx < 0 || idx >= len(doc.props) {
		return
	}
	delete(doc.props[idx].ref.name)
	ordered_remove(&doc.props, idx)
	mark_edited(doc)
}

props_free :: proc(doc: ^Venue_Doc) {
	for inst in doc.props {
		delete(inst.ref.name)
	}
	delete(doc.props)
	doc.props = nil
}

// --- picking and drawing --------------------------------------------------------

// Nearest placed prop the ray strikes, by world box, or -1. A box rather than
// the triangles: a prop is picked to be moved, and hitting the space it
// occupies is what a cursor means by "that one".
pick_prop :: proc(doc: ^Venue_Doc, ray: gfx.Ray) -> (idx: int, dist: f32) {
	idx, dist = -1, max(f32)
	for inst, i in doc.props {
		lo, hi, ok := prop_world_bounds(doc, inst)
		if !ok {
			continue
		}
		hit := gfx.GetRayCollisionBox(ray, lo, hi)
		if hit.hit && hit.distance < dist {
			idx, dist = i, hit.distance
		}
	}
	return
}

// Every placed prop. A prop with no geometry — the base venue does not ship it —
// is skipped silently here; the inspector is where that is reported.
//
// The library is parsed on the way in when there is anything to draw, so a
// venue with props opens showing them rather than waiting to be asked. A failed
// parse stays failed and is not retried every frame.
draw_props :: proc(doc: ^Venue_Doc, wireframe: bool) {
	if len(doc.props) > 0 && doc.props_lib.state == .Unloaded {
		prop_catalog_load(doc)
	}
	for inst in doc.props {
		drawable, have := prop_drawable(doc, inst.ref)
		if !have {
			continue
		}
		prop_draw_one(doc, drawable, prop_instance_xform(inst), wireframe)
	}
}

// One prop mesh at one transform. Culling is off for the same reason the road
// turns it off: prop sheets are wound for the game, and the editor camera goes
// behind them.
prop_draw_one :: proc(doc: ^Venue_Doc, drawable: Prop_Drawable, xform: gfx.Matrix, wireframe: bool) {
	if drawable.mesh.mesh.buffer == nil {
		return
	}
	gfx.DisableBackfaceCulling()
	defer gfx.EnableBackfaceCulling()
	if wireframe {
		gfx.EnableWireMode()
	}
	gfx.DrawMesh(drawable.mesh.mesh, doc.material, xform)
	if wireframe {
		gfx.DisableWireMode()
	}
}

// The box round a placed prop, so the selected one is visible against the
// scenery it is standing in.
draw_prop_box :: proc(doc: ^Venue_Doc, inst: Prop_Instance, col: gfx.Color) {
	lo, hi, ok := prop_world_bounds(doc, inst)
	if !ok {
		return
	}
	corner :: proc(lo, hi: gfx.Vector3, i: int) -> gfx.Vector3 {
		return {i & 1 != 0 ? hi.x : lo.x, i & 2 != 0 ? hi.y : lo.y, i & 4 != 0 ? hi.z : lo.z}
	}
	// Every pair of corners differing in one bit is an edge of the box.
	for a in 0 ..< 8 {
		for bit in 0 ..< 3 {
			b := a | (1 << u32(bit))
			if b != a {
				gfx.DrawLine3D(corner(lo, hi, a), corner(lo, hi, b), col)
			}
		}
	}
}

// --- placing one ------------------------------------------------------------------

// Where the prop being placed would land, refreshed once a frame while the mode
// is on. Held on the window rather than recomputed at each reader, because the
// ground pick walks every terrain triangle — affordable once per frame in a
// mode you turned on, and not affordable twice.
prop_ghost_update :: proc(ed: ^Editor, ray: gfx.Ray) {
	ed.prop_ghost_ok = false
	if !ed.prop_placing {
		return
	}
	if _, have := prop_picked(ed); !have {
		ed.prop_placing = false
		return
	}
	ed.prop_ghost, ed.prop_ghost_ok = pick_ground(ed, ray)
}

// The prop under the cursor, before it is placed: the real mesh where it would
// land, with a box round it so it reads as not yet placed.
draw_prop_ghost :: proc(ed: ^Editor) {
	ref, have := prop_picked(ed)
	if !ed.prop_placing || !ed.prop_ghost_ok || !have {
		return
	}
	drawable, drawn := prop_drawable(ed.doc, ref)
	if !drawn {
		return
	}
	at := ed.prop_ghost
	prop_draw_one(ed.doc, drawable, gfx.MatrixTranslate(at.x, at.y, at.z), ed.wireframe)
	draw_prop_box(ed.doc, {ref = ref, pos = at, rot = gfx.Quaternion(1), scale = 1}, {120, 255, 180, 255})
}

// The click that drops a prop, and the keys that end the mode. Returns true
// while placing owns the input, which is what holds the road's own click verbs
// off — the same bargain floor drawing makes.
prop_place_input :: proc(ed: ^Editor, nav, ui_mouse, ui_keys: bool) -> bool {
	if !ed.prop_placing {
		return false
	}
	if !ui_keys && gfx.IsKeyPressed(.ESCAPE) {
		ed.prop_placing = false
		return true
	}
	if nav || ui_mouse {
		return true
	}
	if gfx.IsMouseButtonPressed(.RIGHT) {
		ed.prop_placing = false
		return true
	}
	if gfx.IsMouseButtonPressed(.LEFT) {
		ref, have := prop_picked(ed)
		if !ed.prop_ghost_ok || !have {
			set_status(&ed.status, "point at the ground to put a prop there", false)
			return true
		}
		// Selected as it lands, so the gizmo is already on it: a prop is almost
		// always turned or nudged straight after being dropped.
		ed.sel = {kind = .Prop, idx = prop_place(ed.doc, ref, ed.prop_ghost)}
		set_status(&ed.status, fmt.tprintf("%s placed", ref.name), true)
	}
	return true
}
