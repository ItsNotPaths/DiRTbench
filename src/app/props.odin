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
// A placement is an ornament or an object, which is ours rather than the
// game's: an ornament is drawn, an object is drawn and collided. Only the
// meshes the venue's `objecttypes.pssg` declares an entity type for can be
// objects, and the catalogue reads that file to know which.
//
// The catalogue lives on the document, so two windows onto one venue share one
// parse and one set of uploaded meshes. The placements live there too, and are
// saved in road.json. The browsers are props_ui.odin's. Nothing here writes a
// game file: emitting these into `ornaments.bin` and `objects.ens` is the
// export's job.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../geo"
import "../gfx"
import "../ui"

// Which of the base venue's two libraries a prop comes from. The name alone is
// not a key: the two files are separate namespaces. Spelled after the files so
// that nothing here reads as the placement role below, which is a different
// question entirely.
Prop_Lib_Kind :: enum u8 {
	Objects_Pssg,
	Trees_Pssg,
}

PROP_LIB_FILES := [Prop_Lib_Kind]string {
	.Objects_Pssg = "objects.pssg",
	.Trees_Pssg   = "trees.pssg",
}

// One prop of the base venue's art, named the way a placement file names it.
Prop_Ref :: struct {
	kind: Prop_Lib_Kind,
	name: string,
}

// What a placement is for. Ours, not the game's: the game has no word for a
// drawable that deliberately refuses the rigid body its art offers.
//
// An ornament is drawn and nothing else. An object is drawn and collided, which
// costs it an `objects.ens` body and so limits it to meshes the venue's
// `objecttypes.pssg` declares an entity type for.
Prop_Role :: enum u8 {
	Ornament,
	Object,
}

PROP_ROLE_NAMES := [Prop_Role]string {
	.Ornament = "Ornaments",
	.Object   = "Objects",
}

PROP_ROLE_COLS := [Prop_Role]ui.Im_Vec4 {
	.Ornament = ORNAMENT_COL,
	.Object   = OBJECT_COL,
}

// One placed prop. The transform is the instance's alone — every prop mesh is
// straight model space, with no transform of its own to compose.
Prop_Instance :: struct {
	ref:   Prop_Ref,
	role:  Prop_Role,
	pos:   gfx.Vector3,
	rot:   gfx.Quaternion,
	scale: f32,
}

Venue_Art_State :: enum u8 {
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

// Everything the editor reads off the base venue's art, parsed once per document:
// which props exist, which of them can collide, the meshes it has uploaded, and
// the billboard card shapes.
//
// `meshes` is filled on demand and never evicted: a venue places a handful of
// distinct props out of a library of two hundred, and uploading the ones it
// uses costs a few hundred KB. The parse itself is the expensive half (tens of
// milliseconds for the largest library), which is why it happens on the first
// ask rather than when the venue opens.
// `bodies` is the venue's `objecttypes.pssg`, which decides what may be placed
// as an object at all. Small beside the libraries (760 KB at the worst venue in
// the game against 30 MB of geometry), so it is read in the same pass.
Venue_Art :: struct {
	base:   string, // the "<location>/<venue>" it was read for
	state:  Venue_Art_State,
	msg:    string,
	libs:   [Prop_Lib_Kind]d3.Prop_Library,
	refs:   [dynamic]Prop_Ref, // objects then trees, each sorted by name
	bodies: map[string]string, // mesh -> the entity id an objects.ens body points at
	meshes: map[Prop_Ref]Prop_Drawable,
	// The card shapes the venue's treesheet art offers, per tier. Read off
	// trees.pssg in the same pass because decoding walks every card of every
	// cloud, which is too much for a rebuild to redo.
	card_kinds: [geo.Billboard_Tier][]geo.Billboard_Kind,
}

// Those shapes, or the nominal pair when the art has not been read yet: the
// preview is then the right shape in the wrong size, which beats no preview.
//
// The export does not come through here. It reads the deployed venue's own
// trees.pssg, which is the one the content pack put there
// (export_dirt3_billboards.odin).
venue_art_card_kinds :: proc(doc: ^Venue_Doc) -> (out: [geo.Billboard_Tier][]geo.Billboard_Kind) {
	out[.Near], out[.Far] = geo.BILLBOARD_NOMINAL_NEAR, geo.BILLBOARD_NOMINAL_FAR
	cat := &doc.venue_art
	if cat.state != .Ready {
		return
	}
	for tier in geo.Billboard_Tier {
		if len(cat.card_kinds[tier]) > 0 {
			out[tier] = cat.card_kinds[tier]
		}
	}
	return
}

// The two tiers' card shapes, off whichever clouds the venue's art offers. A
// venue with no card cloud at all leaves both empty, and both the preview and the
// export then fall back or write nothing.
@(private = "file")
venue_art_read_card_kinds :: proc(lib: ^d3.Prop_Library) -> (out: [geo.Billboard_Tier][]geo.Billboard_Kind) {
	templates := d3.billboard_templates(lib, context.temp_allocator)
	defer d3.billboard_templates_delete(templates, context.temp_allocator)
	for tier in geo.Billboard_Tier {
		template, found := d3.billboard_template_pick(templates, tier == .Far)
		if !found {
			continue
		}
		sizes := d3.billboard_template_sizes(template, context.temp_allocator)
		kinds := make([]geo.Billboard_Kind, len(sizes))
		for size, i in sizes {
			kinds[i] = {size[0], size[1]}
		}
		out[tier] = kinds
	}
	return
}

// Whether the base venue can collide this mesh. Both browsers list off one
// `refs` array, so the Objects list is this test rather than a second array.
prop_has_body :: proc(cat: ^Venue_Art, ref: Prop_Ref) -> bool {
	return ref.name in cat.bodies
}

// Every mesh the venue's `objecttypes.pssg` declares a rigid body for, keyed by
// mesh name. That file is not PSSG at all: it is the same CSSGXml text as
// `objects.ens`, so one parser reads both, and its entity ids are `<mesh>.max`.
//
// Best effort. A venue whose file will not parse gets an empty map, which reads
// as "nothing here can be an object" rather than as an error.
prop_venue_bodies :: proc(
	dir: string, allocator := context.allocator,
) -> (bodies: map[string]string) {
	bodies = make(map[string]string, allocator)
	if dir == "" {
		return
	}
	path, _ := filepath.join({dir, "objecttypes.pssg"}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	nodes, parsed := d3.Ens_Parse(data, context.temp_allocator)
	if !parsed {
		return
	}
	for node in nodes {
		if node.tag != "TEMPLATEENTITY" {
			continue
		}
		id, has_id := d3.ens_attr(node, "id")
		if !has_id {
			continue
		}
		mesh := strings.trim_suffix(id, ".max")
		if mesh == id {
			continue
		}
		// The file bytes are temp; the catalogue outlives them.
		if _, known := bodies[mesh]; !known {
			owned := strings.clone(mesh, allocator)
			bodies[owned] = owned
		}
	}
	return
}

// --- the catalogue -----------------------------------------------------------

// Where the prop art lives: the stock venue under the document's content pack.
// The three library files sit there, one level above `route_n`.
venue_art_dir :: proc(doc: ^Venue_Doc) -> (dir: string, ok: bool) {
	if doc.install == nil {
		return "", false
	}
	dir = base_venue_dir(doc.install, pack_manifest(doc.base).base)
	return dir, dir != ""
}

// Parse both libraries. Idempotent: already loaded for this base is a no-op, and
// a base that changed under the document reloads.
venue_art_load :: proc(doc: ^Venue_Doc) -> (msg: string, ok: bool) {
	cat := &doc.venue_art
	if cat.state == .Ready && cat.base == doc.base {
		return "", true
	}
	venue_art_free(doc)
	dir, have_dir := venue_art_dir(doc)
	if !have_dir {
		cat.state = .Failed
		cat.msg = strings.clone("the base venue is not in the installed game")
		return cat.msg, false
	}
	for file, kind in PROP_LIB_FILES {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		lib, lib_msg, lib_ok := d3.prop_lib_open(path)
		if !lib_ok {
			venue_art_free(doc)
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
	cat.bodies = prop_venue_bodies(dir)
	cat.card_kinds = venue_art_read_card_kinds(&cat.libs[.Trees_Pssg])
	cat.base = strings.clone(doc.base)
	cat.state = .Ready
	return "", true
}

venue_art_free :: proc(doc: ^Venue_Doc) {
	cat := &doc.venue_art
	for ref, &drawable in cat.meshes {
		geo.gpu_mesh_unload(&drawable.mesh)
		delete(ref.name)
	}
	delete(cat.meshes)
	delete(cat.refs)
	for mesh in cat.bodies {
		delete(mesh)
	}
	delete(cat.bodies)
	for kind in Prop_Lib_Kind {
		d3.prop_lib_delete(&cat.libs[kind])
	}
	for tier in geo.Billboard_Tier {
		delete(cat.card_kinds[tier])
	}
	delete(cat.base)
	delete(cat.msg)
	cat^ = {}
}

// The uploaded geometry for one prop, read from the cache or built into it.
// Not ok when the catalogue is not loaded, or the library has no such prop.
prop_drawable :: proc(doc: ^Venue_Doc, ref: Prop_Ref) -> (drawable: Prop_Drawable, ok: bool) {
	cat := &doc.venue_art
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
	.Objects_Pssg = {0.72, 0.70, 0.66},
	.Trees_Pssg   = {0.42, 0.62, 0.38},
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
prop_place :: proc(doc: ^Venue_Doc, ref: Prop_Ref, role: Prop_Role, at: gfx.Vector3) -> int {
	append(&doc.props, Prop_Instance{
		ref   = {kind = ref.kind, name = strings.clone(ref.name)},
		role  = role,
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
	if len(doc.props) > 0 && doc.venue_art.state == .Unloaded {
		venue_art_load(doc)
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

// Which browser owns the next viewport click, if any.
prop_placing_role :: proc(ed: ^Editor) -> Maybe(Prop_Role) {
	return ed.prop_placing
}

// Turn one browser's placing mode on or off. Only ever one at a time: two
// ghosts under one cursor is not a thing the viewport can mean.
prop_set_placing :: proc(ed: ^Editor, role: Prop_Role, on: bool) {
	ed.prop_placing = on ? role : nil
	ed.prop_last = role
}

// Where the prop being placed would land, refreshed once a frame while the mode
// is on. Held on the window rather than recomputed at each reader, because the
// ground pick walks every terrain triangle — affordable once per frame in a
// mode you turned on, and not affordable twice.
prop_ghost_update :: proc(ed: ^Editor, ray: gfx.Ray) {
	ed.prop_ghost_ok = false
	role, placing := ed.prop_placing.?
	if !placing {
		return
	}
	if _, have := prop_picked(ed, role); !have {
		ed.prop_placing = nil
		return
	}
	ed.prop_ghost, ed.prop_ghost_ok = pick_ground(ed, ray)
}

// The prop under the cursor, before it is placed: the real mesh where it would
// land, with a box round it so it reads as not yet placed. The box is the
// browser's colour, so an object and an ornament do not look alike in flight.
draw_prop_ghost :: proc(ed: ^Editor) {
	role, placing := ed.prop_placing.?
	if !placing || !ed.prop_ghost_ok {
		return
	}
	ref, have := prop_picked(ed, role)
	if !have {
		return
	}
	drawable, drawn := prop_drawable(ed.doc, ref)
	if !drawn {
		return
	}
	at := ed.prop_ghost
	prop_draw_one(ed.doc, drawable, gfx.MatrixTranslate(at.x, at.y, at.z), ed.wireframe)
	draw_prop_box(
		ed.doc, {ref = ref, role = role, pos = at, rot = gfx.Quaternion(1), scale = 1},
		PROP_GHOST_COLOUR[role],
	)
}

PROP_GHOST_COLOUR := [Prop_Role]gfx.Color {
	.Ornament = {120, 255, 180, 255},
	.Object   = {255, 190, 90, 255},
}

// The click that drops a prop, and the keys that end the mode. Returns true
// while placing owns the input, which is what holds the road's own click verbs
// off — the same bargain floor drawing makes.
prop_place_input :: proc(ed: ^Editor, nav, ui_mouse, ui_keys: bool) -> bool {
	role, placing := ed.prop_placing.?
	if !placing {
		return false
	}
	if !ui_keys && gfx.IsKeyPressed(.ESCAPE) {
		ed.prop_placing = nil
		return true
	}
	if nav || ui_mouse {
		return true
	}
	if gfx.IsMouseButtonPressed(.RIGHT) {
		ed.prop_placing = nil
		return true
	}
	if gfx.IsMouseButtonPressed(.LEFT) {
		ref, have := prop_picked(ed, role)
		if !ed.prop_ghost_ok || !have {
			set_status(&ed.status, "point at the ground to put a prop there", false)
			return true
		}
		// Selected as it lands, so the gizmo is already on it: a prop is almost
		// always turned or nudged straight after being dropped.
		ed.sel = {kind = .Prop, idx = prop_place(ed.doc, ref, role, ed.prop_ghost)}
		set_status(&ed.status, fmt.tprintf("%s placed as %s", ref.name, PROP_ROLE_NAMES[role]), true)
	}
	return true
}
