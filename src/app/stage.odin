package main

// The road block of a venue document, and the conversion between it and what
// the editor holds. venue.odin owns the file this block sits in.
//
// A road is the control points, each with its world position, road frame (as a
// quaternion) and width, plus vegetation, timing, terrain and props. Everything
// the viewport draws is derived from these (see geo/spline.odin), so this
// round-trips the whole document.
//
// This is deliberately *not* any export format. Export goes spline -> ribbon
// mesh -> a per-game target (see export.odin).

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../gfx"
import "../geo"

STAGE_EXT :: ".json"

// The on-disk shape. Kept flat and dumb: field names are the JSON keys, and a
// quaternion is four floats because core:encoding/json cannot marshal Odin's
// quaternion type.
Stage_Point :: struct {
	// Stable point identity. What a stage's start, finish and pins name.
	id:          int,
	parent:      int,
	// Second edge out of this point, closing a loop. -1 for none.
	weld:        int,
	pos:         [3]f32,
	rot:         [4]f32, // x, y, z, w
	width:       f32,
	cliff_l:     f32,
	cliff_r:     f32,
	span_l:      f32,
	span_r:      f32,
	cliff_taper: f32,
	cliff_angle: f32, // degrees off vertical; + leans away from the road
	roughness:   f32, // per-node offset from the global roughness
}

// No species here: they belong to the venue's base art, and are read off it
// every time the venue is opened (geo.veg_preset_for_base).
Stage_Veg :: struct {
	enabled:   bool,
	density:   f32,
	road_bias: f32,
	seed:      i32,
	// Distant card billboards. A new key rather than a version bump: a venue
	// written before it reads as false, which is what an old venue meant.
	billboards: bool,
}

Stage_Timing :: struct {
	buffer_m: f32,
}

// The sliders, plus the sculpt as a set of world-space offsets. See
// geo.terrain_sculpt for why only those three fields keep.
Stage_Terrain_Control :: struct {
	x, z:   f32,
	offset: f32,
}

Stage_Terrain :: struct {
	enabled:  bool,
	reach_m:  f32,
	blend_m:  f32,
	cell_m:   f32,
	row_m:    f32,
	controls: []Stage_Terrain_Control,
}

// A flat pad. Stored as its own outline rather than a run into a shared array:
// the file is a translation of geo's flat storage, not the storage.
Stage_Floor :: struct {
	y:         f32,
	falloff:   f32,
	points:    [][2]f32,
	clear_veg: bool,
}

// One hand-placed prop. The library is named rather than numbered: a venue's
// base art is what resolves it, and a prop the base does not ship must stay in
// the file rather than becoming a different prop by index.
Stage_Prop :: struct {
	name:  string,
	trees: bool, // from trees.pssg rather than objects.pssg
	scenery: bool, // drawn only, rather than drawn and collided
	pos:   [3]f32,
	rot:   [4]f32, // x, y, z, w
	scale: f32,
}

Venue_Road :: struct {
	points:  []Stage_Point,
	veg:     Stage_Veg,
	timing:  Stage_Timing,
	terrain: Stage_Terrain,
	floors:  []Stage_Floor,
	props:   []Stage_Prop,
}

// --- conversion -------------------------------------------------------------

quat_to_array :: proc(q: gfx.Quaternion) -> [4]f32 {
	return {q.x, q.y, q.z, q.w}
}

quat_from_array :: proc(a: [4]f32) -> gfx.Quaternion {
	q := quaternion(x = a[0], y = a[1], z = a[2], w = a[3])
	// Guard against a hand-edited or truncated file: a zero/denormal quaternion
	// would make every derived road frame NaN.
	if abs(q) < 1e-6 {
		return gfx.Quaternion(1)
	}
	return gfx.QuaternionNormalize(q)
}

// --- save / load ------------------------------------------------------------

// The document's road and stage list, written into the venue file at `path`.
//
// The file is re-read first, so identity the document does not hold — the base
// venue, the display names — survives a road save. That is also what keeps two
// windows on one venue from erasing each other's fields.
//
// road_block holds points, vegetation, timing, terrain, floors and props, and
// Venue_Doc holds the same, so this writes all of it. There is no per-block
// form: passing the blocks one at a time is how one gets silently dropped, and
// that has already cost every compiled stage its checkpoints once.
save_road :: proc(doc: ^Venue_Doc, path: string) -> (msg: string, ok: bool) {
	if len(doc.spline.points) < 2 {
		return "nothing to save: a stage needs at least 2 points", false
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			return fmt.tprintf("could not create %s: %v", dir, err), false
		}
	}
	p, _, loaded := venue_load_path(path, context.temp_allocator)
	if !loaded {
		p = Venue{format = VENUE_FORMAT, version = VENUE_VERSION}
	}
	return venue_doc_write(p, doc, path)
}

// The document's road, in the shape the file holds it.
road_block :: proc(doc: ^Venue_Doc, allocator := context.temp_allocator) -> (road: Venue_Road) {
	sp, veg, timing, terrain := doc.spline, doc.veg, doc.timing, &doc.terrain

	pts := make([]Stage_Point, len(sp.points), allocator)
	for p, i in sp.points {
		pts[i] = Stage_Point {
			id          = p.id,
			parent      = p.parent,
			weld        = p.weld,
			pos         = {p.xform.translation.x, p.xform.translation.y, p.xform.translation.z},
			rot         = quat_to_array(p.xform.rotation),
			width       = p.width,
			cliff_l     = p.cliff_l,
			cliff_r     = p.cliff_r,
			span_l      = p.span_l,
			span_r      = p.span_r,
			cliff_taper = p.cliff_taper,
			cliff_angle = p.cliff_angle,
			roughness   = p.roughness,
		}
	}
	road.points = pts
	road.veg = {
		enabled    = veg.enabled,
		density    = veg.density,
		road_bias  = veg.road_bias,
		seed       = i32(veg.seed),
		billboards = veg.billboards,
	}
	road.timing = {buffer_m = timing.buffer_m}
	{
		sculpt := geo.terrain_sculpt(terrain)
		controls := make([]Stage_Terrain_Control, len(sculpt), allocator)
		for c, i in sculpt {
			controls[i] = {x = c.x, z = c.z, offset = c.offset}
		}
		road.terrain = {
			enabled  = terrain.enabled,
			reach_m  = terrain.reach_m,
			blend_m  = terrain.blend_m,
			cell_m   = terrain.cell_m,
			row_m    = terrain.row_m,
			controls = controls,
		}
	}
	{
		floors := make([]Stage_Floor, len(terrain.floors), allocator)
		for f, i in terrain.floors {
			floors[i] = {
				y         = f.y,
				falloff   = f.falloff,
				points    = geo.floor_verts(terrain, f),
				clear_veg = f.clear_veg,
			}
		}
		road.floors = floors
	}
	{
		props := make([]Stage_Prop, len(doc.props), allocator)
		for inst, i in doc.props {
			props[i] = {
				name    = inst.ref.name,
				trees   = inst.ref.kind == .Trees_Pssg,
				scenery = inst.role == .Ornament,
				pos     = {inst.pos.x, inst.pos.y, inst.pos.z},
				rot     = quat_to_array(inst.rot),
				scale   = inst.scale,
			}
		}
		road.props = props
	}
	return
}

// The road of the venue file at a path the caller chose. See save_road.
load_road :: proc(doc: ^Venue_Doc, path: string) -> (msg: string, ok: bool) {
	p, load_msg, loaded := venue_load_path(path, context.temp_allocator)
	if !loaded {
		return load_msg, false
	}
	if msg, ok = doc_load_road(doc, p.road); !ok {
		return fmt.tprintf("%s: %s", filepath.base(path), msg), false
	}
	return fmt.tprintf("loaded %d points from %s", len(doc.spline.points), filepath.base(path)), true
}

// Put a road block into the document.
//
// Replaces the document's spline on success and leaves it untouched on any
// failure — a bad file must not destroy the road in the editor.
doc_load_road :: proc(doc: ^Venue_Doc, road: Venue_Road) -> (msg: string, ok: bool) {
	sp, veg, timing, terrain := &doc.spline, &doc.veg, &doc.timing, &doc.terrain
	if len(road.points) < 2 {
		return fmt.tprintf("road has %d points, needs at least 2", len(road.points)), false
	}
	for p, i in road.points {
		if p.parent < -1 || p.parent >= i {
			return fmt.tprintf("road point %d has invalid parent %d", i, p.parent), false
		}
		// A weld may point forward, unlike a parent. It may not point at itself,
		// which would sample an edge of zero length.
		if p.weld < -1 || p.weld >= len(road.points) || p.weld == i {
			return fmt.tprintf("road point %d has invalid weld %d", i, p.weld), false
		}
		// A repeated id would make point_index answer with the first of them, silently.
		if p.id < 0 {
			return fmt.tprintf("road point %d has invalid id %d", i, p.id), false
		}
		for q in road.points[i + 1:] {
			if q.id == p.id {
				return fmt.tprintf("road point %d repeats id %d", i, p.id), false
			}
		}
	}

	clear(&sp.points)
	sp.next_id = 0
	for p, i in road.points {
		width := p.width if p.width > 0 else f32(geo.DEFAULT_WIDTH)
		taper := p.cliff_taper if p.cliff_taper > 0 else f32(geo.DEFAULT_CLIFF_TAPER)
		append(
			&sp.points,
			geo.make_point(
				{p.pos[0], p.pos[1], p.pos[2]},
				quat_from_array(p.rot),
				width,
				p.cliff_l,
				p.cliff_r,
				p.span_l,
				p.span_r,
				taper,
				p.cliff_angle,
				p.roughness,
				p.parent,
			),
		)
		np := &sp.points[len(sp.points)-1]
		np.weld = p.weld
		np.id = p.id
		sp.next_id = max(sp.next_id, np.id + 1)
	}

	{
		// The species are the venue's, taken from its base art, so a load leaves
		// them exactly as the venue set them. The file has no say in it.
		preset := veg.preset
		veg^ = geo.Veg_Params {
			enabled    = road.veg.enabled,
			density    = road.veg.density,
			road_bias  = road.veg.road_bias,
			seed       = c.int(road.veg.seed),
			billboards = road.veg.billboards,
		}
		veg.preset = preset
	}
	timing^ = {buffer_m = clamp(road.timing.buffer_m, f32(0), f32(500))}
	{
		t := road.terrain
		saved := make([]geo.Terrain_Control, len(t.controls), context.temp_allocator)
		for c, i in t.controls {
			saved[i] = {x = c.x, z = c.z, offset = c.offset}
		}
		terrain.enabled = t.enabled
		terrain.reach_m = clamp(t.reach_m, 0, geo.TERRAIN_REACH_MAX)
		terrain.blend_m = max(t.blend_m, 0)
		terrain.cell_m = max(t.cell_m, 1)
		terrain.row_m = clamp(t.row_m, geo.TERRAIN_ROW_M_MIN, geo.TERRAIN_ROW_M_MAX)
		geo.terrain_sculpt_load(terrain, saved)
	}
	{
		// Rebuilt from the file every time, so nothing of the last document's
		// pads or props survives into this one.
		clear(&terrain.floors)
		clear(&terrain.floor_pts)
		for f in road.floors {
			if i := geo.floor_add(terrain, f.points, f.y); i >= 0 {
				terrain.floors[i].falloff = clamp(f.falloff, 0, geo.TERRAIN_REACH_MAX)
				terrain.floors[i].clear_veg = f.clear_veg
			}
		}
	}
	{
		props_free(doc)
		doc.props = make([dynamic]Prop_Instance)
		for pr in road.props {
			if pr.name == "" {
				continue
			}
			append(&doc.props, Prop_Instance{
				ref   = {kind = pr.trees ? .Trees_Pssg : .Objects_Pssg, name = strings.clone(pr.name)},
				role  = pr.scenery ? .Ornament : .Object,
				pos   = {pr.pos[0], pr.pos[1], pr.pos[2]},
				rot   = quat_from_array(pr.rot),
				scale = clamp(pr.scale, PROP_SCALE_MIN, PROP_SCALE_MAX),
			})
		}
	}
	return "", true
}
