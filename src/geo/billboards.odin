package geo

// Distant tree billboards: flat cards the shader turns to face the camera.
//
//   Far   the wall. It stands in the void — where the terrain does not reach —
//         from BILLBOARD_RIM_IN inside the bare edge to BILLBOARD_WALL_M past
//         it, and nowhere else. Past the terrain there is only the venue LOD's
//         skirt, metres under the whole network, so the edge reads as a cliff;
//         the wall closes that view.
//
//   Near  single trees, on terrain where the scatter left room for one. Not a
//         band and not a function of road bias: a scatter thick enough to be a
//         forest takes this tier away by itself.
//
// Where the terrain ends is `su > reach` — distance from the *nearest* leg's
// verge seam (veg_field_su). A fixed offset from the casting verge instead puts
// wall cards inside another leg's terrain at every branch and hairpin.
//
// Nothing here knows about any one game: a card carries a size, a place and an
// index into the target's own card shapes. See src/d3/tree_cloud.odin.

import "core:math"
import "../gfx"

Billboard_Tier :: enum u8 {
	Near,
	Far,
}

// One card shape the target's art offers, in metres. The generator never invents
// a size: it picks among these, because a card's size is a property of the atlas
// rectangle it is cut from.
Billboard_Kind :: struct {
	w, h: f32,
}

// One generated card. `kind` indexes the kind list of its own tier.
Billboard_Card :: struct {
	pos:   gfx.Vector3, // the card's centre; its base stands on the ground
	tier:  Billboard_Tier,
	kind:  int,
	scale: f32, // what the kind's own size was multiplied by
	w, h:  f32, // that size, scaled
	arc:   f32, // where along the road it belongs, for grouping into clouds
}

// How far into the void the wall reaches, and how far inside the bare edge its
// innermost row may stand. A row exactly on the edge leaves the silhouette open
// at the rim; more than a few metres in and it stands on drawn ground.
BILLBOARD_WALL_M :: f32(50)
BILLBOARD_RIM_IN :: f32(3)
// Layers across that band, the first just inside the edge and the last at the far
// side of it. One row is a wall with no depth; the rest are parallax.
BILLBOARD_WALL_ROWS :: 3
// How much of its width the next card along a row covers, so a row has no gap.
BILLBOARD_OVERLAP :: f32(0.45)
// Wall cards sink this far under the ground they were measured on, so no seam
// opens between a card's bottom edge and the rim it hides.
BILLBOARD_SINK :: f32(4)
// How finely a ray is walked looking for the terrain's edge. The same as the rim
// allowance on purpose: the edge is reported as the last point with terrain under
// it, so the walk's own step is how far inside the true edge that can be.
BILLBOARD_EDGE_STEP :: BILLBOARD_RIM_IN
// How close to the road a tree card may stand. Off stock, which starts its own
// single-tree cards about this far out: closer than that a card is seen from the
// side, and a card seen from the side is a flat sheet.
BILLBOARD_NEAR_IN :: f32(25)
// Per-card size jitter, so a row does not read as one repeated sprite.
BILLBOARD_SCALE_MIN :: f32(0.85)
BILLBOARD_SCALE_MAX :: f32(1.25)
// A hard cap, the same reason VEG_MAX is one.
BILLBOARD_MAX :: 40000

// Drives the spacing. The pool is never empty — the caller refuses a tier without
// one.
billboard_median_w :: proc(kinds: []Billboard_Kind) -> f32 {
	total: f32
	for k in kinds {
		total += k.w
	}
	return max(total / f32(len(kinds)), 1)
}

billboard_max_w :: proc(kinds: []Billboard_Kind) -> (out: f32) {
	for k in kinds {
		out = max(out, k.w)
	}
	return
}

// A wall row's card spacing, overlapped so the row has no gap.
@(private = "file")
billboard_wall_spacing :: proc(kinds: []Billboard_Kind) -> f32 {
	return max(billboard_median_w(kinds) * (1 - BILLBOARD_OVERLAP), 4)
}

// --- where the model trees are ------------------------------------------------

// The scatter in plan view, so a card can ask whether a tree already stands here.
// The cell is the widest exclusion any pair can ask for, so the nine cells around
// a point hold every tree that could turn a card down. Bucket chaining: `head`
// holds a cell's first tree and `next` the rest, so nothing allocates per cell.
Billboard_Trees :: struct {
	cell:  f32,
	trees: []Veg_Instance,
	head:  map[[2]i32]int,
	next:  []int,
}

// The widest exclusion a tree and a card can ask for between them, which is the
// cell the index has to use for a nine-cell lookup to be complete.
billboard_tree_cell :: proc(trees: []Veg_Instance, kinds: []Billboard_Kind) -> (cell: f32) {
	for tree in trees {
		cell = max(cell, tree.r)
	}
	return cell + billboard_max_w(kinds) * 0.5
}

billboard_trees_index :: proc(
	trees: []Veg_Instance, cell: f32, allocator := context.temp_allocator,
) -> (out: Billboard_Trees) {
	out.cell = max(cell, 1)
	out.trees = trees
	out.head = make(map[[2]i32]int, 0, allocator)
	out.next = make([]int, len(trees), allocator)
	for tree, i in trees {
		key := billboard_cell(tree.pos.x, tree.pos.z, out.cell)
		out.next[i] = out.head[key] - 1 // absent reads as 0, so ids are stored one up
		out.head[key] = i + 1
	}
	return
}

billboard_trees_delete :: proc(index: ^Billboard_Trees, allocator := context.temp_allocator) {
	delete(index.head)
	delete(index.next, allocator)
	index^ = {}
}

@(private = "file")
billboard_cell :: proc(x, z, cell: f32) -> [2]i32 {
	return {i32(math.floor(x / cell)), i32(math.floor(z / cell))}
}

// Whether a card of half-width `half` at `p` would stand in a model tree. The
// tree's own canopy radius counts, so a card clears a big fir by more than a bush.
billboard_tree_here :: proc(index: ^Billboard_Trees, p: [2]f32, half: f32) -> bool {
	if len(index.trees) == 0 {
		return false
	}
	base := billboard_cell(p[0], p[1], index.cell)
	for gz in base[1] - 1 ..= base[1] + 1 {
		for gx in base[0] - 1 ..= base[0] + 1 {
			for i := index.head[{gx, gz}] - 1; i >= 0; i = index.next[i] {
				tree := index.trees[i]
				clear := tree.r + half
				dx, dz := tree.pos.x - p[0], tree.pos.z - p[1]
				if dx * dx + dz * dz < clear * clear {
					return true
				}
			}
		}
	}
	return false
}

// --- the outline of the terrain ----------------------------------------------

// One ray out of the road, and where along it the terrain gives out.
//
// `at` is where the ray starts and `u0` how far out from it the terrain's own
// measure begins, so a verge ray and a run-end ray are read the same way.
Billboard_Ray :: struct {
	at:  [2]f32,
	out: [2]f32, // unit
	u0:  f32,
	arc: f32,
}

// Rays out of both verges of every run, plus a half-disc sweep at each run's two
// ends. Without the sweeps a stage is open at the start line and the finish, which
// is where a driver is stopped and looking around.
billboard_rays :: proc(
	ribbon: []Cross_Section,
	arc, ds: []f32,
	reach, spacing, roughness: f32,
	allocator := context.temp_allocator,
) -> []Billboard_Ray {
	out := make([dynamic]Billboard_Ray, allocator)
	vrows := VERGE_ROWS
	for run in ribbon_runs(ribbon) {
		if run.hi <= run.lo {
			continue
		}
		lo, hi := arc[run.lo], arc[run.hi]
		for step in 0 ..= max(int((hi - lo) / spacing), 1) {
			i := veg_sample_at_arc(arc, run, clamp(lo + f32(step) * spacing, lo, hi))
			cs := ribbon[i]
			for side in 0 ..< 2 {
				seam := verge_seam(cs, side, vrows, i, roughness, ds[i])
				o := terrain_outward(cs, side)
				append(&out, Billboard_Ray {
					at  = {seam.x, seam.z},
					out = {o.x, o.z},
					arc = arc[i],
				})
			}
		}
		for i, end in ([2]int{run.lo, run.hi}) {
			cs := ribbon[i]
			half := cs.width * 0.5
			ahead := gfx.Vector3{cs.fwd.x, 0, cs.fwd.z}
			if gfx.Vector3Length(ahead) < 1e-4 {
				continue
			}
			ahead = gfx.Vector3Normalize(ahead)
			if end == 0 {
				ahead = -ahead
			}
			// Enough rays that the sweep is no coarser at its rim than a verge is.
			steps := max(int(math.PI * (half + reach + BILLBOARD_WALL_M) / spacing), 3)
			for s in 1 ..< steps {
				a := math.PI * (f32(s) / f32(steps) - 0.5)
				dir := [2]f32{
					ahead.x * math.cos(a) + cs.right.x * math.sin(a),
					ahead.z * math.cos(a) + cs.right.z * math.sin(a),
				}
				n := math.hypot(dir[0], dir[1])
				if n < 1e-4 {
					continue
				}
				append(&out, Billboard_Ray {
					at  = {cs.pos.x, cs.pos.z},
					out = dir / n,
					u0  = half,
					arc = arc[i],
				})
			}
		}
	}
	return out[:]
}

// Where the terrain gives out along one ray, and the ground height just inside it.
//
// The height is measured here and carried outward: out where a wall card stands
// there is no terrain to measure, and the venue LOD out there sits under the whole
// network, so a card on that sinks away from the edge it hides.
//
// Not found when the ray never had terrain under it: a ray that starts in the void
// is on nobody's outline.
billboard_edge :: proc(
	vf: ^Veg_Field, ray: Billboard_Ray, fallback: f32,
) -> (edge, y: f32, ok: bool) {
	y = fallback
	edge = -1
	for u := VEG_CLEAR; u <= vf.reach + BILLBOARD_WALL_M; u += BILLBOARD_EDGE_STEP {
		p := ray.at + ray.out * (ray.u0 + u)
		su, in_range := veg_field_su(vf, p)
		if !in_range || su > vf.reach {
			break
		}
		if su > VEG_CLEAR {
			// The last point with terrain under it, which is the edge as far as a
			// card is concerned: standing on it is standing on the bare rim.
			edge = u
			if ground, on_terrain := veg_field_y(vf, p); on_terrain && vf.heights {
				y = ground
			}
		}
	}
	return edge, y, edge >= 0
}

// --- placing cards ------------------------------------------------------------

// One card per cell of a grid sized to the card spacing, which is what bounds the
// density: the legs meeting at a junction cast over the same ground twice.
@(private = "file")
billboard_claim :: proc(taken: ^map[[2]i32]bool, p: [2]f32, cell: f32) -> bool {
	key := [2]i32{i32(math.floor(p[0] / cell)), i32(math.floor(p[1] / cell))}
	if key in taken {
		return false
	}
	taken[key] = true
	return true
}

// Drawn before the card is tested: the jitter adds up to a quarter to the kind's
// width, and it is the card's own half-width that has to clear a tree.
Billboard_Pick :: struct {
	kind:  int,
	scale: f32,
	w, h:  f32,
}

@(private = "file")
billboard_pick :: proc(kinds: []Billboard_Kind, rng: ^Rng) -> (pick: Billboard_Pick) {
	pick.kind = int(rng_next(rng) % u64(len(kinds)))
	pick.scale = rng_range(rng, BILLBOARD_SCALE_MIN, BILLBOARD_SCALE_MAX)
	pick.w = kinds[pick.kind].w * pick.scale
	pick.h = kinds[pick.kind].h * pick.scale
	return
}

@(private = "file")
billboard_place :: proc(
	out: ^[dynamic]Billboard_Card,
	pick: Billboard_Pick,
	tier: Billboard_Tier,
	p: [2]f32,
	base_y, arc: f32,
) {
	append(out, Billboard_Card {
		pos   = {p[0], base_y + pick.h * 0.5, p[1]},
		tier  = tier,
		kind  = pick.kind,
		scale = pick.scale,
		w     = pick.w,
		h     = pick.h,
		arc   = arc,
	})
}

// Clear of every leg of the road, past its ends as well as beside it. The
// terrain's own corridor test is not enough: straight off a dead end it reports the
// along-road overshoot as clearance, which is right for ground and wrong for a card
// two metres behind the finish gate.
billboard_clear_of_road :: proc(vf: ^Veg_Field, p: [2]f32) -> bool {
	if !vf.ok {
		return true
	}
	i, d := hash_nearest(vf.hash, vf.fs, p, vf.limit)
	if i < 0 {
		return true
	}
	return d > max(vf.fs[i].e[0], vf.fs[i].e[1]) + VEG_CLEAR
}

// The wall: rows across the void band, staggered along each ray so one row's gaps
// sit behind another row's cards. Every card is measured against the terrain once
// more before it is kept, because on a branch one leg's void band runs into
// another leg's ground.
billboard_wall_cards :: proc(
	out: ^[dynamic]Billboard_Card,
	rays: []Billboard_Ray,
	vf: ^Veg_Field,
	kinds: []Billboard_Kind,
	rng: ^Rng,
	taken: ^map[[2]i32]bool,
	fallback_y: f32,
) {
	spacing := billboard_wall_spacing(kinds)
	// Row 0 on the bare edge itself, the last at the far side of the band.
	step := BILLBOARD_WALL_M / f32(BILLBOARD_WALL_ROWS - 1)
	for ray in rays {
		edge, ground, found := billboard_edge(vf, ray, fallback_y)
		if !found {
			continue
		}
		tan := [2]f32{-ray.out[1], ray.out[0]}
		for row in 0 ..< BILLBOARD_WALL_ROWS {
			if len(out) >= BILLBOARD_MAX {
				return
			}
			u := edge + f32(row) * step
			along := (f32(row) * 0.5 + rng_range(rng, -0.25, 0.25)) * spacing
			p := ray.at + ray.out * (ray.u0 + u) + tan * along
			pick := billboard_pick(kinds, rng)
			if !billboard_in_void(vf, p) {
				continue
			}
			if !billboard_claim(taken, p, spacing) {
				continue
			}
			billboard_place(out, pick, .Far, p, ground - BILLBOARD_SINK, ray.arc)
		}
	}
}

// Whether a point is somewhere a wall card may stand: out past the terrain, or at
// most BILLBOARD_RIM_IN inside its bare edge, and no further out than the band.
// A point the field cannot place at all is deep void, which qualifies.
billboard_in_void :: proc(vf: ^Veg_Field, p: [2]f32) -> bool {
	su, in_range := veg_field_su(vf, p)
	if !in_range {
		return true
	}
	return su >= vf.reach - BILLBOARD_RIM_IN && su <= vf.reach + BILLBOARD_WALL_M
}

// Rows no finer than the ribbon's own step. A row station snaps to the nearest
// cross-section, so two rows closer together than that land on the same one and
// plant its columns twice over.
@(private = "file")
billboard_row_step :: proc(ds: []f32, spacing: f32) -> f32 {
	total, n := f32(0), 0
	for d in ds {
		if d > 0 {
			total += d
			n += 1
		}
	}
	if n == 0 {
		return spacing
	}
	return max(spacing, total / f32(n))
}

// The near tier: cards on the terrain, wherever the scatter left room for one.
// Candidates cover the whole plantable band and what keeps one is that no model
// tree stands where it would go, so the road bias never appears here — it moves the
// trees, and the cards follow.
billboard_near_cards :: proc(
	out: ^[dynamic]Billboard_Card,
	ribbon: []Cross_Section,
	arc, ds: []f32,
	vf: ^Veg_Field,
	near, roughness: f32,
	kinds: []Billboard_Kind,
	trees: ^Billboard_Trees,
	rng: ^Rng,
	taken: ^map[[2]i32]bool,
) {
	span := vf.reach - near
	width := billboard_median_w(kinds)
	// A card width apart, not the wall's overlapping spacing: this tier stands in
	// for trees you can see between, and cards half-covering each other read as
	// one green mass rather than as a forest.
	spacing := max(width, 4)
	if span < spacing {
		return
	}
	cols := max(int(span / spacing), 1)
	rows := billboard_row_step(ds, spacing)
	vrows := VERGE_ROWS
	for i in veg_rows(ribbon, arc, rows, rng) {
		if len(out) >= BILLBOARD_MAX {
			return
		}
		cs := ribbon[i]
		fwd := gfx.Vector3{cs.fwd.x, 0, cs.fwd.z}
		fwd = gfx.Vector3Length(fwd) > 1e-4 ? gfx.Vector3Normalize(fwd) : gfx.Vector3{0, 0, 1}
		for side in 0 ..< 2 {
			seam := verge_seam(cs, side, vrows, i, roughness, ds[i])
			o := terrain_outward(cs, side)
			for col in 0 ..< cols {
				if len(out) >= BILLBOARD_MAX {
					return
				}
				u := near + (f32(col) + rng_unit(rng)) * (span / f32(cols))
				jf := rng_range(rng, -0.5, 0.5) * rows
				p := [2]f32{
					seam.x + o.x * u + fwd.x * jf,
					seam.z + o.z * u + fwd.z * jf,
				}
				// On the terrain and nowhere else: the probe says no in a road
				// corridor, on a pad that clears its own foliage, and past the
				// reach, which is where the wall takes over.
				y, on_terrain := veg_field_y(vf, p)
				if !on_terrain {
					continue
				}
				if !vf.heights {
					y = seam.y
				}
				if !billboard_clear_of_road(vf, p) {
					continue
				}
				pick := billboard_pick(kinds, rng)
				if billboard_tree_here(trees, p, pick.w * 0.5) {
					continue
				}
				if !billboard_claim(taken, p, spacing) {
					continue
				}
				billboard_place(out, pick, .Near, p, y, arc[i])
			}
		}
	}
}

// Every card this stage places. Persistent-allocates the result (caller frees), or
// returns nil when there is nothing to place. Deterministic in `veg.seed`.
//
// `trees` is the scatter this stage already placed: the near tier's rule is "where
// those are not", and an empty list means every metre of terrain qualifies. A tier
// with no kinds is skipped — the art offers no card of that shape.
billboards_generate :: proc(
	ribbon: []Cross_Section,
	terrain: ^Terrain,
	veg: Veg_Params,
	roughness: f32,
	trees: []Veg_Instance,
	near_kinds, far_kinds: []Billboard_Kind,
	allocator := context.allocator,
) -> []Billboard_Card {
	if !veg.billboards || len(ribbon) < 2 {
		return nil
	}
	arc := ribbon_arc(ribbon)
	ds := sample_spacing(ribbon)
	if arc[len(arc) - 1] <= 0 {
		return nil
	}

	vf := veg_field_make(terrain, ribbon, arc, ds, roughness)
	if !vf.ok {
		return nil
	}
	rng := rng_init(veg.seed)
	// One grid per tier. The cell is the tier's own card spacing, and the tiers
	// differ by a factor of seven, so a shared map would key two different grids
	// into one namespace and drop cards for no reason.
	near_taken := make(map[[2]i32]bool, 0, context.temp_allocator)
	far_taken := make(map[[2]i32]bool, 0, context.temp_allocator)
	defer delete(near_taken)
	defer delete(far_taken)
	out := make([dynamic]Billboard_Card, allocator)

	if len(far_kinds) > 0 {
		rays := billboard_rays(
			ribbon, arc, ds, vf.reach, billboard_wall_spacing(far_kinds), roughness,
		)
		billboard_wall_cards(&out, rays, &vf, far_kinds, &rng, &far_taken, ribbon[0].pos.y)
	}
	if len(near_kinds) > 0 {
		index := billboard_trees_index(trees, billboard_tree_cell(trees, near_kinds))
		defer billboard_trees_delete(&index)
		billboard_near_cards(
			&out, ribbon, arc, ds, &vf, BILLBOARD_NEAR_IN, roughness, near_kinds, &index, &rng,
			&near_taken,
		)
	}

	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// --- the viewport preview ----------------------------------------------------

// Card colours in the editor. Not the art: a card is a texture in the game and a
// flat quad here, so the preview says where and how big, never what.
BILLBOARD_NEAR_COL :: gfx.Color{74, 104, 66, 210}
BILLBOARD_FAR_COL :: gfx.Color{88, 106, 96, 210}

// Nominal card shapes, for a preview taken before the venue's art has been read.
// The export always uses the art's own sizes, so a preview drawn on these is the
// right shape in the wrong size.
BILLBOARD_NOMINAL_NEAR := []Billboard_Kind{{8, 20}}
BILLBOARD_NOMINAL_FAR := []Billboard_Kind{{55, 28}}

// The cards as flat quads, each facing across the road it was cast from. In game
// the shader turns them to the camera; the preview leaves them still, which is
// what makes a wall read as a wall while the camera moves.
billboards_build_mesh :: proc(cards: []Billboard_Card, allocator := context.allocator) -> Tri_Mesh {
	m := tri_mesh_make(allocator)
	for card in cards {
		// Any horizontal direction will do for a still quad; the one across the
		// card's own radius from the origin keeps a wall facing its own stage.
		dir := gfx.Vector3{card.pos.z, 0, -card.pos.x}
		if gfx.Vector3Length(dir) < 1e-3 {
			dir = {1, 0, 0}
		}
		across := gfx.Vector3Normalize(dir) * (card.w * 0.5)
		up := gfx.Vector3{0, card.h * 0.5, 0}
		col := card.tier == .Far ? BILLBOARD_FAR_COL : BILLBOARD_NEAR_COL
		a := card.pos - across - up
		b := card.pos + across - up
		c := card.pos + across + up
		d := card.pos - across + up
		add_tri(&m, a, b, c, {}, {}, {}, col, .Terrain)
		add_tri(&m, a, c, d, {}, {}, {}, col, .Terrain)
	}
	return m
}
