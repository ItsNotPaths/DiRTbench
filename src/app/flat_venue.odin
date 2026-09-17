#+build ignore
package main

// Reference-only DiRT 3 probe. **Not compiled** — see the build directive
// above. Kept for the method, not for use; the CLI no longer exposes it.
// To run it again, drop the directive and restore its command in cli.odin.

// Build route and venue files directly from the complete road.json. Reading
// the whole road preserves the grid lead-in that compiled stages trim away.
// A broad tiled floor covers retained route-system terrain probes, while the
// placement fixtures exercise the ancillary files D3 expects.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import d3 "../d3"
import "../geo"

// finland_rally/route_0's own real qt.info bounding box (X, Z), read straight
// off its stock track.jpk: (-2258.24, -13.46, -1129.01) .. (2008.01, 29.14, 838.38).
// Padded outward to whole numbers.
FLAT_VENUE_FLOOR_LO :: [2]f32{-2260, -1130}
FLAT_VENUE_FLOOR_HI :: [2]f32{2010, 840}
FLAT_VENUE_FLOOR_CELLS_X :: 40
FLAT_VENUE_FLOOR_CELLS_Z :: 20

// A coarse flat floor tiled across `lo`..`hi` (X, Z) at a single `y`. Never
// the drivable stage itself -- .Terrain, not .Road. Tiled rather than one
// quad so the archive still partitions correctly at any real scale.
flat_venue_tiled_plane :: proc(
	lo, hi: [2]f32,
	y: f32,
	cells_x, cells_z: int,
	allocator := context.allocator,
) -> []d3.Collision_Triangle {
	out := make([dynamic]d3.Collision_Triangle, allocator)
	for zi in 0 ..< cells_z {
		z0 := lo[1] + (hi[1]-lo[1])*f32(zi)/f32(cells_z)
		z1 := lo[1] + (hi[1]-lo[1])*f32(zi+1)/f32(cells_z)
		for xi in 0 ..< cells_x {
			x0 := lo[0] + (hi[0]-lo[0])*f32(xi)/f32(cells_x)
			x1 := lo[0] + (hi[0]-lo[0])*f32(xi+1)/f32(cells_x)
			a := [3]f32{x0, y, z0}
			b := [3]f32{x1, y, z0}
			c := [3]f32{x1, y, z1}
			d := [3]f32{x0, y, z1}
			append(&out, d3.Collision_Triangle{Points = {a, c, b}, Material = .Terrain})
			append(&out, d3.Collision_Triangle{Points = {a, d, c}, Material = .Terrain})
		}
	}
	return out[:]
}

// "dougfir_tall_02_a" — reference_id 1 in finland_rally/route_0's own
// trees.bin, the donor every flatvenue-style project hardlinks its
// trees.bin from. Specific to that donor; re-check if the base venue changes.
FLAT_VENUE_TREE_REF :: 1
FLAT_VENUE_TREE_ENTITY :: "objecttypes.pssg#dougfir_tall_02_a.max"
FLAT_VENUE_HAYBALE_MESH :: "objecttypes.pssg#core_barr_haybale_e.max"
FLAT_VENUE_HOUSE_MESH :: "objecttypes.pssg#rural_house_yellow_a.max"

flat_venue_tree_square :: proc(allocator := context.allocator) -> []d3.D3_Placement_Instance {
	xs := []f32{20, 25, 30}
	zs := []f32{40, 45, 50}
	out := make([]d3.D3_Placement_Instance, len(xs)*len(zs), allocator)
	i := 0
	for x in xs {
		for z in zs {
			out[i] = {reference_id = FLAT_VENUE_TREE_REF, basis = d3.D3_BASIS_IDENTITY, position = {x, 0, z}}
			i += 1
		}
	}
	return out
}

// Every `[]T{...}` below is built with `make` rather than a bare compound
// literal: a slice literal is backed by this frame's stack, and every one of
// these ends up embedded in an `Ens_Node` that outlives it, through `nodes`
// back in flat_venue_headless.

ens_attrs :: proc(pairs: ..d3.Ens_Attr, allocator := context.allocator) -> []d3.Ens_Attr {
	out := make([]d3.Ens_Attr, len(pairs), allocator)
	copy(out, pairs)
	return out
}

ens_children :: proc(child: d3.Ens_Node, allocator := context.allocator) -> []d3.Ens_Node {
	out := make([]d3.Ens_Node, 1, allocator)
	out[0] = child
	return out
}

flat_venue_ens_ref :: proc(id, mesh: string, allocator := context.allocator) -> d3.Ens_Node {
	return {
		tag     = "TEMPLATEENTITYREFERENCE",
		attrs   = ens_attrs({"id", id}, {"uri", mesh}, {"allocAlt", "5"}, allocator = allocator),
		content = .Self_Close,
	}
}

flat_venue_ens_transform :: proc(pos: [3]f32) -> d3.Ens_Node {
	return {
		tag = "TEMPLATETRANSFORM",
		content = .Text,
		text = fmt.tprintf("1 0 0 0 0 1 0 0 0 0 1 0 %.6f %.6f %.6f 1 ", pos[0], pos[1], pos[2]),
	}
}

// A haybale stack, physics-relevant (`TEMPLATEENTITYINSTANCE`, so it carries
// an `instanceID`), off the -X side near the start.
flat_venue_haybale_stack :: proc(allocator := context.allocator) -> []d3.Ens_Node {
	out := make([dynamic]d3.Ens_Node, allocator)
	append(&out, flat_venue_ens_ref("flat_haybale", FLAT_VENUE_HAYBALE_MESH, allocator))
	for h, i in ([]f32{0, 1.6}) {
		append(&out, d3.Ens_Node{
			tag = "TEMPLATEENTITYINSTANCE",
			attrs = ens_attrs(
				{"id", fmt.tprintf("flat_haybale_%d", i)},
				{"instanceID", fmt.tprintf("%d", 500000+i)},
				{"uri", "#flat_haybale"},
				{"instance_tag", fmt.tprintf("%d", 500100+i)},
				allocator = allocator,
			),
			content  = .Children,
			children = ens_children(flat_venue_ens_transform({-20, h, 50}), allocator),
		})
	}
	return out[:]
}

// A house stack, pure scenery (`TEMPLATEBASICENTITYINSTANCE`, no instanceID
// at all — nothing for a VIS lookup to ever key on), off the -X side further
// along the route.
flat_venue_house_stack :: proc(allocator := context.allocator) -> []d3.Ens_Node {
	out := make([dynamic]d3.Ens_Node, allocator)
	append(&out, flat_venue_ens_ref("flat_house", FLAT_VENUE_HOUSE_MESH, allocator))
	for h, i in ([]f32{0, 8, 16}) {
		append(&out, d3.Ens_Node{
			tag = "TEMPLATEBASICENTITYINSTANCE",
			attrs = ens_attrs(
				{"id", fmt.tprintf("flat_house_%d", i)},
				{"uri", "#flat_house"},
				{"instance_tag", fmt.tprintf("%d", 500200+i)},
				allocator = allocator,
			),
			content  = .Children,
			children = ens_children(flat_venue_ens_transform({-20, h, 75}), allocator),
		})
	}
	return out[:]
}

// The same Route_Sample mapping export.odin's own export_dirt3 uses, off
// whatever ribbon is handed in rather than an editor's.
flat_venue_route_samples :: proc(ribbon: []geo.Cross_Section, allocator := context.allocator) -> []d3.Route_Sample {
	out := make([]d3.Route_Sample, len(ribbon), allocator)
	for section, i in ribbon {
		half := section.width / 2
		// D3 expects left->right to be route-forward rotated counter-clockwise.
		left := section.pos + section.right*half
		right := section.pos - section.right*half
		out[i] = {
			Centre = {section.pos.x, section.pos.y, section.pos.z},
			Left   = {left.x, left.y, left.z},
			Right  = {right.x, right.y, right.z},
		}
	}
	return out
}

flat_venue_route_length :: proc(route: []d3.Route_Sample) -> f32 {
	length: f32
	for i in 1..<len(route) {
		dx := route[i].Centre[0]-route[i-1].Centre[0]
		dy := route[i].Centre[1]-route[i-1].Centre[1]
		dz := route[i].Centre[2]-route[i-1].Centre[2]
		length += math.sqrt(dx*dx+dy*dy+dz*dz)
	}
	return length
}

// Spread five splits over the required 15-gate topology: 2/4/7/10/13.
flat_venue_markers :: proc(length: f32, allocator := context.allocator) -> []d3.Progress_Marker {
	out := make([]d3.Progress_Marker, 5, allocator)
	out[0] = {Kind = .Start, Distance = length*2/14}
	out[1] = {Kind = .Checkpoint, Distance = length*4/14}
	out[2] = {Kind = .Checkpoint, Distance = length*7/14}
	out[3] = {Kind = .Checkpoint, Distance = length*10/14}
	out[4] = {Kind = .Finish, Distance = length*13/14}
	return out
}

flat_venue_headless :: proc(venue_id, route_id: string) -> (msg: string, ok: bool) {
	scan: Install_Scan
	doc := Venue_Doc{install = &scan}
	install_scan_init(doc.install)
	defer install_scan_delete(doc.install)
	dir, deployed := venue_deploy_dir(&doc, venue_id, route_id)
	if !deployed {
		return fmt.tprintf("%s/%s is not deployed; run --venue-deploy --apply first", venue_id, route_id), false
	}
	venue_dir := filepath.dir(dir)

	// One straight, untruncated road for both the venue's tracksplit.pssg and
	// the route's own track.jpk/routesplit.pssg/grids.pssg -- see the header
	// comment for why the route can't come from a compiled stage here.
	local_collision, ribbon, profile, build_msg, built := venue_tracksplit_collision(doc.install, venue_id, true, context.temp_allocator)
	if !built { return fmt.tprintf("road: %s", build_msg), false }

	floor := flat_venue_tiled_plane(FLAT_VENUE_FLOOR_LO, FLAT_VENUE_FLOOR_HI, 0, FLAT_VENUE_FLOOR_CELLS_X, FLAT_VENUE_FLOOR_CELLS_Z, context.temp_allocator)
	collision := make([]d3.Collision_Triangle, len(local_collision)+len(floor), context.temp_allocator)
	copy(collision, local_collision)
	copy(collision[len(local_collision):], floor)

	tracksplit_msg, tracksplit_ok := d3.Export_Geometry(&d3.Export_Job{Out = venue_dir, Backup = true, Collision = collision, Profile = profile})
	if !tracksplit_ok { return fmt.tprintf("tracksplit.pssg: %s", tracksplit_msg), false }

	route := flat_venue_route_samples(ribbon, context.temp_allocator)
	route_msg, route_ok := d3.Export(&d3.Export_Job{
		Name = route_id, Out = dir, Backup = true,
		Route = route,
		Markers = flat_venue_markers(flat_venue_route_length(route), context.temp_allocator),
		Collision = collision, Profile = profile,
	})
	if !route_ok { return fmt.tprintf("route: %s", route_msg), false }

	trees_path, _ := filepath.join({dir, "trees.bin"}, context.temp_allocator)
	ornaments_path, _ := filepath.join({dir, "ornaments.bin"}, context.temp_allocator)
	ens_path, _ := filepath.join({dir, "objects.ens"}, context.temp_allocator)
	vis_path, _ := filepath.join({dir, "track.vis"}, context.temp_allocator)

	trees_data, trees_err := os.read_entire_file(trees_path, context.temp_allocator)
	if trees_err != nil { return fmt.tprintf("could not read %s: %v", trees_path, trees_err), false }
	tree_instances := flat_venue_tree_square(context.temp_allocator)
	new_trees, trees_msg, trees_ok := d3.d3_placement_relocate(trees_data, tree_instances, context.temp_allocator)
	if !trees_ok { return fmt.tprintf("trees.bin: %s", trees_msg), false }
	if write_msg, written := d3.Atomic_Write(trees_path, new_trees); !written { return write_msg, false }

	ornaments_data, ornaments_err := os.read_entire_file(ornaments_path, context.temp_allocator)
	if ornaments_err != nil { return fmt.tprintf("could not read %s: %v", ornaments_path, ornaments_err), false }
	new_ornaments, ornaments_msg, ornaments_ok := d3.d3_placement_relocate(ornaments_data, nil, context.temp_allocator)
	if !ornaments_ok { return fmt.tprintf("ornaments.bin: %s", ornaments_msg), false }
	if write_msg, written := d3.Atomic_Write(ornaments_path, new_ornaments); !written { return write_msg, false }

	nodes := make([dynamic]d3.Ens_Node, context.temp_allocator)
	tree_physics, tree_physics_msg, tree_physics_ok := d3.d3_ens_static_set_nodes({
		ens_reference_id       = "flat_tree",
		entity_uri             = FLAT_VENUE_TREE_ENTITY,
		instance_id_prefix     = "flat_tree",
		placement_reference_id = FLAT_VENUE_TREE_REF,
		instances              = tree_instances,
	}, context.temp_allocator)
	if !tree_physics_ok { return fmt.tprintf("objects.ens trees: %s", tree_physics_msg), false }
	append(&nodes, ..tree_physics)
	append(&nodes, ..flat_venue_haybale_stack(context.temp_allocator))
	append(&nodes, ..flat_venue_house_stack(context.temp_allocator))
	ens_data := d3.d3_ens_emit(nodes[:], context.temp_allocator)
	if write_msg, written := d3.Atomic_Write(ens_path, ens_data); !written { return write_msg, false }

	vis_data, vis_msg, vis_ok := d3.d3_stock_route_all_visible_vis(dir, venue_dir, "", .Skip, context.temp_allocator)
	if !vis_ok { return fmt.tprintf("track.vis: %s", vis_msg), false }
	if write_msg, written := d3.Atomic_Write(vis_path, vis_data); !written { return write_msg, false }

	return fmt.tprintf(
		"%s\ntracksplit.pssg: %s\nroute: %s\ntrees.bin: %s\nornaments.bin: %s\nobjects.ens: %d nodes (%s + haybale stack + house stack)\ntrack.vis: %s",
		dir, tracksplit_msg, route_msg, trees_msg, ornaments_msg, len(nodes), tree_physics_msg, vis_msg,
	), true
}
