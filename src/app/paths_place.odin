#+build ignore
package main

// Reference-only DiRT 3 probe. **Not compiled** — see the build directive
// above. Kept for the method, not for use; the CLI no longer exposes it.
// To run it again, drop the directive and restore its command in cli.odin.

// `--dirt3-paths-place <venue_id> [<route_id>]`: the full custom-level debug
// emit: route core, ground, decorations, venue tracksplit, all-visible VIS,
// manifest stubs, and route_overrides.xml.
//
// The road is already the debug strip (lead-in, 100 m timed, run-out), so no
// windowing. The road must already curve: an exact straight trips the
// route-selector degeneracy, and this emit fails closed on one rather than
// bowing collision it cannot rebuild.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import d3 "../d3"
import "../geo"

// Refuse a ribbon this close to its own chord.
PATHS_PLACE_MIN_BOW_M :: f32(1)
PATHS_PLACE_HOUSE_COUNT :: u32(3)
PATHS_PLACE_HAY_COUNT :: u32(5)
PATHS_PLACE_TAG_2_CAPACITY :: PATHS_PLACE_HOUSE_COUNT+PATHS_PLACE_HAY_COUNT

paths_place_curve_deviation :: proc(ribbon: []geo.Cross_Section) -> f32 {
	if len(ribbon) < 3 { return 0 }
	a := ribbon[0].pos
	b := ribbon[len(ribbon)-1].pos
	dx, dz := b.x-a.x, b.z-a.z
	length := math.sqrt(dx*dx+dz*dz)
	if length < 1e-6 { return 0 }
	worst: f32
	for s in ribbon[1:len(ribbon)-1] {
		off := math.abs((s.pos.z-a.z)*dx-(s.pos.x-a.x)*dz)/length
		worst = max(worst, off)
	}
	return worst
}

PATHS_PLACE_TREE_REFERENCE :: d3.D3_Placement_Reference{
	reference_id=0, filename="dougfir_tall_02_a",
	bounds_min={-4.722625,-0.5921014,-5.154214}, bounds_max={5.3381443,25.46084,5.050685},
}
PATHS_PLACE_HOUSE_REFERENCE :: d3.D3_Placement_Reference{
	reference_id=0, filename="rural_house_yellow_a", instance_capacity=PATHS_PLACE_HOUSE_COUNT,
	bounds_min={-4.314604,-0.9315009,-4.149647}, bounds_max={3.78497219,6.766279,4.35014439},
}
PATHS_PLACE_HAY_REFERENCE :: d3.D3_Placement_Reference{
	reference_id=1, filename="core_barr_haybale_e", instance_capacity=PATHS_PLACE_HAY_COUNT,
	bounds_min={-0.576802135,-8.768219,-0.398107052}, bounds_max={0.5781785,0.51696384,0.333437383},
}

// Plus sign of five trees, left of the road just past the start line.
paths_place_tree_plus :: proc(allocator := context.allocator) -> []d3.D3_Placement_Instance {
	spots := [5][3]f32{{-16, 0, 12}, {-21, 0, 12}, {-11, 0, 12}, {-16, 0, 7}, {-16, 0, 17}}
	out := make([]d3.D3_Placement_Instance, len(spots), allocator)
	for spot, i in spots {
		out[i] = {reference_id=0, instance_id=u32(i), instance_tag=u32(i+1), basis=d3.D3_BASIS_IDENTITY, position={spot[0],spot[1],spot[2]}, shadow_factor=1}
	}
	return out
}

// `instanceID` continues after cooked ornaments in tag 2's drawable space.
// TEMPLATEBASICENTITYINSTANCE physics mirrors consume no drawable id.
paths_place_haybales :: proc(first_instance_id: u32, allocator := context.allocator) -> []d3.Ens_Node {
	out := make([dynamic]d3.Ens_Node, allocator)
	append(&out, flat_venue_ens_ref("pp_haybale", FLAT_VENUE_HAYBALE_MESH, allocator))
	for h, i in ([]f32{0, 1.35, 2.7, 4.05, 5.4}) {
		append(&out, d3.Ens_Node{
			tag = "TEMPLATEENTITYINSTANCE",
			attrs = ens_attrs(
				{"id", fmt.tprintf("pp_haybale_%d", i)},
				{"instanceID", fmt.tprintf("%d", first_instance_id+u32(i))},
				{"uri", "#pp_haybale"},
				{"instance_tag", fmt.tprintf("%d", 500100+i)},
				allocator = allocator,
			),
			content  = .Children,
				children = ens_children(flat_venue_ens_transform({18, h, 110}), allocator),
		})
	}
	return out[:]
}

// Ornament tower, right of the road further down the track. These exact
// authored ids also key tag 2 of the synthesized VIS.
paths_place_houses :: proc(allocator := context.allocator) -> []d3.D3_Placement_Instance {
	out := make([]d3.D3_Placement_Instance, int(PATHS_PLACE_HOUSE_COUNT), allocator)
	for h, i in ([]f32{0, 8, 16}) {
		out[i] = {reference_id=0, instance_id=u32(i), instance_tag=u32(i+1), basis=d3.D3_BASIS_IDENTITY, position={25,h,110}}
	}
	return out
}

paths_place_write :: proc(path: string, data: []u8) -> (msg: string, ok: bool) {
	if backup_msg, backed_up := d3.d3_backup_once(path); !backed_up { return backup_msg, false }
	return d3.Atomic_Write(path, data)
}

paths_place_emit_placement_pair :: proc(
	dir, stem: string,
	format: d3.D3_Placement_Format,
	references: []d3.D3_Placement_Reference,
	instances: []d3.D3_Placement_Instance,
) -> (msg: string, ok: bool) {
	bin, bin_msg, bin_ok := d3.d3_placement_build(format, references, instances, context.temp_allocator)
	if !bin_ok { return fmt.tprintf("%s.bin: %s", stem, bin_msg), false }
	bin_path, _ := filepath.join({dir, fmt.tprintf("%s.bin", stem)}, context.temp_allocator)
	if write_msg, written := paths_place_write(bin_path, bin); !written { return write_msg, false }

	xml, xml_msg, xml_ok := d3.d3_placement_xml_build(format, references, instances, context.temp_allocator)
	if !xml_ok { return fmt.tprintf("%s.xml: %s", stem, xml_msg), false }
	xml_path, _ := filepath.join({dir, fmt.tprintf("%s.xml", stem)}, context.temp_allocator)
	if write_msg, written := paths_place_write(xml_path, xml); !written { return write_msg, false }
	return fmt.tprintf("%s / %s", bin_msg, xml_msg), true
}

paths_place_stubs :: proc(dir: string, ribbon: []geo.Cross_Section) -> (msg: string, ok: bool) {
	lo := [3]f32{ribbon[0].pos.x, ribbon[0].pos.y, ribbon[0].pos.z}
	hi := lo
	for s in ribbon {
		lo[0] = min(lo[0], s.pos.x-60); lo[1] = min(lo[1], s.pos.y-60); lo[2] = min(lo[2], s.pos.z-60)
		hi[0] = max(hi[0], s.pos.x+60); hi[1] = max(hi[1], s.pos.y+60); hi[2] = max(hi[2], s.pos.z+60)
	}
	text := [?]struct{name, body: string}{
		{"light_placement.xml", d3.D3_STUB_LIGHT_PLACEMENT},
		{"iwater.xml", d3.D3_STUB_INTERACTIVE_WATER},
		{"niwater.xml", d3.D3_STUB_INTERACTIVE_WATER},
		{"organism_track_dataset.xml", d3.D3_STUB_ORGANISM_TRACK_DATASET},
	}
	for stub in text {
		path, _ := filepath.join({dir, stub.name}, context.temp_allocator)
		data := d3.d3_stub_text(stub.body, context.temp_allocator)
		if write_msg, written := paths_place_write(path, data); !written {
			return write_msg, false
		}
	}
	binaries := [?]struct{name: string, data: []u8}{
		{"clothFile.bin", d3.d3_stub_zero(4, context.temp_allocator)},
		{"reducedmechanics.jpk", d3.d3_stub_reducedmechanics(context.temp_allocator)},
		{"cameralines.cqtc", d3.d3_stub_cqtc("RESD", lo, hi, context.temp_allocator)},
		{"barrierlines.cqtc", d3.d3_stub_cqtc("BARR", lo, hi, context.temp_allocator)},
	}
	for stub in binaries {
		path, _ := filepath.join({dir, stub.name}, context.temp_allocator)
		if write_msg, written := paths_place_write(path, stub.data); !written {
			return write_msg, false
		}
	}
	return "8 stubs", true
}

Paths_Place_Target :: enum {
	Installed,
	Debug_Out,
}

paths_place_headless :: proc(venue_id, route_id: string, target: Paths_Place_Target) -> (msg: string, ok: bool) {
	scan: Install_Scan
	doc := Venue_Doc{install = &scan}
	install_scan_init(doc.install)
	defer install_scan_delete(doc.install)
	if !doc.install.found {
		return install_scan_status_text(doc.install), false
	}
	if target == .Installed {
		dir, deployed := venue_deploy_dir(&doc, venue_id, route_id)
		if !deployed {
			return fmt.tprintf("%s/%s is not deployed; run --venue-deploy --apply first", venue_id, route_id), false
		}
		return paths_place_emit_into(&doc, venue_id, route_id, dir, filepath.dir(dir), filepath.dir(dir))
	}
	return paths_place_debug_out(&doc, venue_id, route_id)
}

paths_place_emit_placements :: proc(dir: string) -> (msg: string, ok: bool) {
	ens_path, _ := filepath.join({dir, "objects.ens"}, context.temp_allocator)

	tree_instances := paths_place_tree_plus(context.temp_allocator)
	trees_msg, trees_ok := paths_place_emit_placement_pair(dir, "trees", .Trees, {PATHS_PLACE_TREE_REFERENCE}, tree_instances)
	if !trees_ok { return trees_msg, false }

	house_instances := paths_place_houses(context.temp_allocator)
	ornament_refs := []d3.D3_Placement_Reference{PATHS_PLACE_HOUSE_REFERENCE, PATHS_PLACE_HAY_REFERENCE}
	ornaments_msg, ornaments_ok := paths_place_emit_placement_pair(dir, "ornaments", .Ornaments, ornament_refs, house_instances)
	if !ornaments_ok { return ornaments_msg, false }

	nodes := make([dynamic]d3.Ens_Node, context.temp_allocator)
	tree_physics, tree_physics_msg, tree_physics_ok := d3.d3_ens_static_set_nodes({
		ens_reference_id       = "pp_tree",
		entity_uri             = FLAT_VENUE_TREE_ENTITY,
		instance_id_prefix     = "pp_tree",
		placement_reference_id = 0,
		instances              = tree_instances,
	}, context.temp_allocator)
	if !tree_physics_ok { return fmt.tprintf("objects.ens trees: %s", tree_physics_msg), false }
	append(&nodes, ..tree_physics)
	append(&nodes, ..paths_place_haybales(PATHS_PLACE_HOUSE_COUNT, context.temp_allocator))
	house_physics, house_physics_msg, house_physics_ok := d3.d3_ens_static_set_nodes({
		ens_reference_id="pp_house", entity_uri=FLAT_VENUE_HOUSE_MESH, instance_id_prefix="pp_house",
		placement_reference_id=0, instances=house_instances,
	}, context.temp_allocator)
	if !house_physics_ok { return fmt.tprintf("objects.ens houses: %s", house_physics_msg), false }
	append(&nodes, ..house_physics)
	ens_data := d3.d3_ens_emit(nodes[:], context.temp_allocator)
	if write_msg, written := paths_place_write(ens_path, ens_data); !written { return write_msg, false }

	return fmt.tprintf(
		"trees.bin/xml: %s\nornaments.bin/xml: %s\nobjects.ens: %d nodes (%s + %d haybales + %s)",
		trees_msg, ornaments_msg, len(nodes), tree_physics_msg, PATHS_PLACE_HAY_COUNT, house_physics_msg,
	), true
}

// Seed a writable copy of the base route under out/ and emit into it. Reads
// the game, writes nothing into it: the detour while the install is
// read-only, and an inspection shelf afterwards.
paths_place_seed_route :: proc(src, dst: string) -> (msg: string, ok: bool) {
	infos, read_err := os.read_all_directory_by_path(src, context.temp_allocator)
	if read_err != nil { return fmt.tprintf("could not read %s: %v", src, read_err), false }
	for info in infos {
		if info.type == .Directory { continue }
		from, _ := filepath.join({src, info.name}, context.temp_allocator)
		to, _ := filepath.join({dst, info.name}, context.temp_allocator)
		if os.exists(to) { continue }
		data, file_err := os.read_entire_file(from, context.temp_allocator)
		if file_err != nil { return fmt.tprintf("could not read %s: %v", from, file_err), false }
		if write_err := os.write_entire_file(to, data); write_err != nil {
			return fmt.tprintf("could not write %s: %v", to, write_err), false
		}
	}
	return "", true
}

paths_place_debug_out :: proc(doc: ^Venue_Doc, venue_id, route_id: string) -> (msg: string, ok: bool) {
	p, load_msg, loaded := venue_load(venue_id)
	if !loaded { return load_msg, false }
	defer venue_free(p)
	src, _ := filepath.join({doc.install.install.root, "tracks", "locations", p.base, p.base_route}, context.temp_allocator)
	dst, _ := filepath.join({out_dir(), venue_id, route_id}, context.temp_allocator)
	if err := os.make_directory_all(dst); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dst, err), false
	}
	if seed_msg, seeded := paths_place_seed_route(src, dst); !seeded { return seed_msg, false }
	// Keep the generated venue-scope tracksplit beside this scratch route. VIS
	// must census that file, not the base venue's donor tracksplit.
	return paths_place_emit_into(doc, venue_id, route_id, dst, filepath.dir(dst), filepath.dir(src))
}

paths_place_read_tracksplit_template :: proc(venue_dir, donor_venue_dir: string) -> ([]u8, string, bool) {
	path, _ := filepath.join({donor_venue_dir, "tracksplit.pssg"}, context.temp_allocator)
	if donor_venue_dir == venue_dir {
		original := fmt.tprintf("%s.orig", path)
		if os.exists(original) { path = original }
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return nil, fmt.tprintf("could not read base template %s: %v", path, read_err), false
	}
	return data, "", true
}

// Everything below writes only into `dir`, which the caller made: the
// deployed route in the game, or a scratch copy of the base route for
// validation while the game disk stays read-only.
paths_place_emit_into :: proc(doc: ^Venue_Doc, venue_id, route_id, dir, venue_dir, donor_venue_dir: string) -> (msg: string, ok: bool) {
	local_collision, ribbon, profile, build_msg, built := venue_tracksplit_collision(doc.install, venue_id, true, context.temp_allocator)
	if !built { return fmt.tprintf("road: %s", build_msg), false }
	if len(ribbon) < 2 { return "road: ribbon has fewer than two sections", false }
	if deviation := paths_place_curve_deviation(ribbon); deviation < PATHS_PLACE_MIN_BOW_M {
		return fmt.tprintf("road: near-straight (%.2f m off chord); author a curve", deviation), false
	}

	floor := flat_venue_tiled_plane(FLAT_VENUE_FLOOR_LO, FLAT_VENUE_FLOOR_HI, 0, FLAT_VENUE_FLOOR_CELLS_X, FLAT_VENUE_FLOOR_CELLS_Z, context.temp_allocator)
	collision := make([]d3.Collision_Triangle, len(local_collision)+len(floor), context.temp_allocator)
	copy(collision, local_collision)
	copy(collision[len(local_collision):], floor)

	route := flat_venue_route_samples(ribbon, context.temp_allocator)
	route_msg, route_ok := d3.Export(&d3.Export_Job{
		Name = route_id, Out = dir, Backup = true,
		Route = route,
		Markers = flat_venue_markers(flat_venue_route_length(route), context.temp_allocator),
		Collision = collision, Profile = profile,
	})
	if !route_ok { return fmt.tprintf("route: %s", route_msg), false }
	tracksplit_template, template_msg, template_ok := paths_place_read_tracksplit_template(venue_dir, donor_venue_dir)
	if !template_ok { return fmt.tprintf("tracksplit.pssg: %s", template_msg), false }

	// VIS enumerates venue tiles before route tiles, so build it after both PSSGs.
	tracksplit_msg, tracksplit_ok := d3.Export_Venue_Geometry(&d3.Export_Job{
		Name = venue_id, Out = venue_dir, Backup = true,
		Collision = collision, Profile = profile,
	}, tracksplit_template)
	if !tracksplit_ok { return fmt.tprintf("tracksplit.pssg: %s", tracksplit_msg), false }

	vis_path, _ := filepath.join({dir, "track.vis"}, context.temp_allocator)

	placements_msg, placements_ok := paths_place_emit_placements(dir)
	if !placements_ok { return placements_msg, false }

	// Dynamic ENS ids consume tag-2 capacity, but only cooked ornaments and
	// `staticVis=1` entities receive VIS boxes.
	vis_floor: [16]u32
	vis_floor[2] = PATHS_PLACE_TAG_2_CAPACITY
	vis_data, vis_msg, vis_ok := d3.d3_stock_route_all_visible_vis(
		dir, venue_dir, "", .Synthesized, context.temp_allocator,
		header_floor=vis_floor,
	)
	if !vis_ok { return fmt.tprintf("track.vis: %s", vis_msg), false }
	if write_msg, written := paths_place_write(vis_path, vis_data); !written { return write_msg, false }

	stub_msg, stub_ok := paths_place_stubs(dir, ribbon)
	if !stub_ok { return fmt.tprintf("stubs: %s", stub_msg), false }

	return fmt.tprintf(
		"%s\nroute: %s\ntracksplit.pssg: %s\n%s\ntrack.vis: %s\nstubs: %s",
		dir, route_msg, tracksplit_msg, placements_msg, vis_msg, stub_msg,
	), true
}
