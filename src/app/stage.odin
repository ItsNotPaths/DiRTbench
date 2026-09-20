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
	// Both name a point by **id**, never by its position in `points`. The two
	// differ the moment a point is deleted, and an independent reader has only
	// the ids to go on. -1 for none.
	parent:      int,
	// Second edge out of this point, closing a loop.
	weld:        int,
	pos:         [3]f32,
	rot:         [4]f32, // x, y, z, w
	width:       f32,
	roughness:   f32, // per-node offset from the global road roughness
	// What the road is made of from here forward, or absent for "whatever
	// reaches me from upstream". A name rather than the enum's number, for the
	// same reason a guard kind is one: inserting a surface later must not
	// renumber what is already written. A new key rather than a version bump,
	// so a venue written before surfaces existed reads as all-loose, which is
	// what it meant.
	surface:     string,
}

// The file's names for geo.Road_Surface. `.None` writes nothing at all, so the
// common case costs no bytes and an old file reads back as it was.
SURFACE_KEY := [geo.Road_Surface]string {
	.None  = "",
	.Loose = "loose",
	.Paved = "paved",
}

surface_of :: proc(key: string) -> geo.Road_Surface {
	for name, surface in SURFACE_KEY {
		if name == key && surface != .None { return surface }
	}
	return .None
}

// One side guard. Cliffs, banks and gutters are one thing on disk because they
// are one thing in the editor — see geo.Guard.
Stage_Guard :: struct {
	id:    int,
	kind:  string, // "cliff", "bank" or "gutter"
	// 0 is the left edge in travel order, 1 the right.
	side:  int,
	// The anchor control point, by **id**, for the same reason parent and weld
	// are: a position means nothing outside the array it indexes.
	at:    int,
	size:  f32,
	span:  f32,
	taper: f32,
	width: f32,
	angle: f32,
	rough: f32,
}

// The file's names for geo.Guard_Kind. A name rather than the enum's number, so
// inserting a kind later cannot renumber what is already written.
GUARD_KIND_KEY := [geo.Guard_Kind]string {
	.Cliff  = "cliff",
	.Bank   = "bank",
	.Gutter = "gutter",
}

guard_kind_of :: proc(key: string) -> (geo.Guard_Kind, bool) {
	for name, kind in GUARD_KIND_KEY {
		if name == key { return kind, true }
	}
	return .Cliff, false
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
	warp_m:   f32, // a new key rather than a version bump: absent reads as 0
	controls: []Stage_Terrain_Control,
}

// A flat pad. Stored as its own outline rather than a run into a shared array:
// the file is a translation of geo's flat storage, not the storage.
Stage_Floor :: struct {
	y:         f32,
	falloff:   f32,
	points:    [][2]f32,
	no_trees:  bool,
	no_cover:  bool,
	// Standing water over the pad, and how far above its floor the surface
	// sits. New keys rather than a version bump: absent reads as no water.
	water:       bool `json:"water,omitempty"`,
	water_depth: f32  `json:"water_depth,omitempty"`,
	// What the first two used to be, when a pad cleared both or neither. Read
	// so a venue written before the split keeps its pads; never written, so it
	// leaves every new file as soon as that venue is saved again.
	clear_veg: bool `json:"clear_veg,omitempty"`,
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
	guards:  []Stage_Guard,
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
		// No venue at this path yet. It still has to be a venue document, so
		// it is given an identity here rather than reaching disk without one.
		p = Venue {
			format  = VENUE_FORMAT,
			version = VENUE_VERSION,
			id      = venue_uuid(context.temp_allocator),
			name    = sanitise_venue_name(
				strings.trim_suffix(filepath.base(path), STAGE_EXT),
				context.temp_allocator,
			),
		}
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
			// Ids, not the array positions the spline holds: the file is the
			// thing that travels, and a position means nothing outside the
			// array it indexes. Markers have always been written this way.
			parent      = geo.point_id(sp, p.parent),
			weld        = geo.point_id(sp, p.weld),
			pos         = {p.xform.translation.x, p.xform.translation.y, p.xform.translation.z},
			rot         = quat_to_array(p.xform.rotation),
			width       = p.width,
			roughness   = p.roughness,
			surface     = SURFACE_KEY[p.surface],
		}
	}
	road.points = pts
	{
		guards := make([]Stage_Guard, len(sp.guards), allocator)
		for g, i in sp.guards {
			guards[i] = {
				id    = g.id,
				kind  = GUARD_KIND_KEY[g.kind],
				side  = g.side,
				at    = geo.point_id(sp, g.at),
				size  = g.size,
				span  = g.span,
				taper = g.taper,
				width = g.width,
				angle = g.angle,
				rough = g.rough,
			}
		}
		road.guards = guards
	}
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
			warp_m   = terrain.warp_m,
			controls = controls,
		}
	}
	{
		floors := make([]Stage_Floor, len(terrain.floors), allocator)
		for f, i in terrain.floors {
			floors[i] = {
				y        = f.y,
				falloff  = f.falloff,
				points   = geo.floor_verts(terrain, f),
				no_trees    = f.no_trees,
				no_cover    = f.no_cover,
				water       = f.water,
				water_depth = f.water_depth,
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
	// `parent` and `weld` name points by id in the file and by array position in
	// memory, so nothing can be converted until every id is known. Ids first,
	// then the edges against the map they build.
	index_of := make(map[int]int, len(road.points), context.temp_allocator)
	for p, i in road.points {
		if p.id < 0 {
			return fmt.tprintf("road point %d has invalid id %d", i, p.id), false
		}
		// A repeated id would make point_index answer with the first of them, silently.
		if _, repeated := index_of[p.id]; repeated {
			return fmt.tprintf("road point %d repeats id %d", i, p.id), false
		}
		index_of[p.id] = i
	}

	parents := make([]int, len(road.points), context.temp_allocator)
	welds := make([]int, len(road.points), context.temp_allocator)
	for p, i in road.points {
		parents[i], welds[i] = -1, -1
		if p.parent != -1 {
			// A parent must sit earlier in the array: build_ribbon walks the
			// points in order and reads each parent's frame before its own.
			at, found := index_of[p.parent]
			if !found || at >= i {
				return fmt.tprintf("road point %d has invalid parent %d", i, p.parent), false
			}
			parents[i] = at
		}
		if p.weld != -1 {
			// A weld may point forward, unlike a parent. It may not point at
			// itself, which would sample an edge of zero length.
			at, found := index_of[p.weld]
			if !found || at == i {
				return fmt.tprintf("road point %d has invalid weld %d", i, p.weld), false
			}
			welds[i] = at
		}
	}

	clear(&sp.points)
	sp.next_id = 0
	for p, i in road.points {
		width := p.width if p.width > 0 else f32(geo.DEFAULT_WIDTH)
		append(
			&sp.points,
			geo.make_point(
				{p.pos[0], p.pos[1], p.pos[2]},
				quat_from_array(p.rot),
				width,
				p.roughness,
				parents[i],
			),
		)
		np := &sp.points[len(sp.points)-1]
		np.weld = welds[i]
		np.id = p.id
		np.surface = surface_of(p.surface)
		sp.next_id = max(sp.next_id, np.id + 1)
	}

	// Guards after the points, because an anchor is an id in the file and a
	// position in memory. A guard naming a point that is not there is dropped
	// rather than aimed somewhere else: a guard on the wrong road is worse than
	// no guard, and it would be silent.
	clear(&sp.guards)
	sp.next_guard_id = 0
	for g in road.guards {
		kind, known := guard_kind_of(g.kind)
		at, found := index_of[g.at]
		if !known || !found {
			continue
		}
		geo.guard_add(sp, geo.Guard {
			kind  = kind,
			side  = clamp(g.side, 0, 1),
			at    = at,
			size  = max(g.size, 0),
			span  = max(g.span, 0),
			taper = max(g.taper, 0),
			width = max(g.width, 0),
			angle = g.angle,
			rough = clamp(g.rough, 0, 1),
		})
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
		terrain.warp_m = clamp(t.warp_m, 0, geo.TERRAIN_REACH_MAX)
		geo.terrain_sculpt_load(terrain, saved)
	}
	{
		// Rebuilt from the file every time, so nothing of the last document's
		// pads or props survives into this one.
		clear(&terrain.floors)
		clear(&terrain.floor_pts)
		for f in road.floors {
			opts := geo.Floor_Opts {
				no_trees    = f.no_trees || f.clear_veg,
				no_cover    = f.no_cover || f.clear_veg,
				water       = f.water,
				water_depth = f.water_depth,
			}
			if i := geo.floor_add(terrain, f.points, f.y, opts); i >= 0 {
				terrain.floors[i].falloff = clamp(f.falloff, 0, geo.TERRAIN_REACH_MAX)
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
