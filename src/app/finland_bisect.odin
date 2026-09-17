package main

// `--dirt3-bisect-1 <venue_id> [<route_id>]`: stage 1 of the AI-finalise-hang
// bisection. Resets `route_id` back to the donor's own real files everywhere
// except track.jpk/routesplit.pssg. Isolates "does our writer break AI
// finalise" from "does our synthetic route shape/content break it".
//
// `--dirt3-bisect-1-flat <venue_id> [<route_id>]`: same reset, but
// track.jpk/routesplit.pssg become a flat tiled plane spanning the *same
// real bounding box* instead of a faithful rebuild of the real shape.
// Isolates route *shape* (winding real terrain vs. a flat plane) from route
// *span* -- progress/ai xml, grids, and real placements still describe the
// real, much larger route. track.vis is rebuilt after routesplit.pssg so its
// surface indices describe the replacement tiles rather than the donor tiles.
//
// Confirmed 2026-09-15: stage 1 (real shape, our writer) drives clean --
// two winedbg snapshots of the main thread a moment apart both landed in
// ordinary d3d11/dxgi render-loop code, never the VehicleManagerPlugin wait.
// That took two real bugs in the writer out first: d3_track_write freed
// buffers through the ambient context.allocator instead of the allocator it
// was actually given (invisible until fed anything but the default), and
// Binary_Writer's binary_reserve called `resize` -- which sets capacity to
// exactly the requested length every time, no geometric growth -- once per
// write, which was fine at every synthetic scale this codebase had used
// before but is O(n^2) against a real ~20 MB PSSG file's node count. Both
// are fixed in dirt3_writer.odin/binary.odin, not just this bisection.
//
// This targets `venue_id`'s own deployed route -- never the donor's real
// directory -- so it never touches stock content.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import d3 "../d3"

// Route-scoped files restored verbatim; venue-scoped tracksplit.pssg is
// restored separately since it lives one level up.
FINLAND_BISECT_RESTORE_FILES :: []string{
	"progress_track.xml", "ai_track.xml", "grids.pssg",
	"trees.bin", "ornaments.bin", "objects.ens",
}

finland_bisect_restore_file :: proc(donor_dir, deployed_dir, name: string) -> (msg: string, ok: bool) {
	src, _ := filepath.join({donor_dir, name}, context.temp_allocator)
	dst, _ := filepath.join({deployed_dir, name}, context.temp_allocator)
	data, err := os.read_entire_file(src, context.temp_allocator)
	if err != nil { return fmt.tprintf("could not read donor %s: %v", src, err), false }
	return d3.Atomic_Write(dst, data)
}

// Everything both bisection stages share: reset the route to the donor's own
// real files except track.jpk/routesplit.pssg, then decode the donor's real
// track.jpk into a flat triangle soup ready for either writer path.
Finland_Bisect_Base :: struct {
	deployed_dir:       string,
	deployed_venue_dir: string,
	donor_vis_path:     string,
	profile:            ^d3.Venue_Profile,
	tris:               []d3.Collision_Triangle,
	restored:           []string,
}

finland_bisect_prepare :: proc(
	ed: ^Editor,
	venue_id, route_id: string,
	allocator := context.temp_allocator,
) -> (
	base: Finland_Bisect_Base,
	msg:  string,
	ok:   bool,
) {
	deployed_dir, deployed := venue_deploy_dir(ed, venue_id, route_id)
	if !deployed {
		return base, fmt.tprintf("%s/%s is not deployed", venue_id, route_id), false
	}
	base.deployed_dir = deployed_dir
	base.deployed_venue_dir = filepath.dir(deployed_dir)

	p, load_msg, loaded := venue_load(venue_id, context.temp_allocator)
	if !loaded { return base, load_msg, false }
	donor_venue, donor_route, found := venue_source(ed.install, p)
	if !found { return base, fmt.tprintf("could not resolve %s's base venue in the live install", venue_id), false }
	base.donor_vis_path, _ = filepath.join({donor_route.dir, "track.vis"}, allocator)

	restored := make([dynamic]string, allocator)
	for name in FINLAND_BISECT_RESTORE_FILES {
		if restore_msg, restored_ok := finland_bisect_restore_file(donor_route.dir, base.deployed_dir, name); !restored_ok {
			return base, fmt.tprintf("%s: %s", name, restore_msg), false
		}
		append(&restored, name)
	}
	if restore_msg, restored_ok := finland_bisect_restore_file(donor_venue.dir, base.deployed_venue_dir, "tracksplit.pssg"); !restored_ok {
		return base, fmt.tprintf("tracksplit.pssg: %s", restore_msg), false
	}
	base.restored = restored[:]

	donor_jpk, _ := filepath.join({donor_route.dir, "track.jpk"}, context.temp_allocator)
	collision, read_msg, read_ok := d3.d3_collision_read(donor_jpk, context.allocator)
	if !read_ok { return base, fmt.tprintf("track.jpk: %s", read_msg), false }
	defer d3.d3_collision_delete(&collision, context.allocator)

	profile, profile_msg, profile_ok := export_profile(ed.install, venue_id, allocator)
	if !profile_ok { return base, fmt.tprintf("profile: %s", profile_msg), false }
	base.profile = profile

	total := 0
	for chunk in collision.chunks { total += len(chunk.tris) }
	tris := make([]d3.Collision_Triangle, total, allocator)
	at := 0
	for chunk in collision.chunks {
		for tri in chunk.tris {
			code := chunk.mats[tri.mat] if tri.mat >= 0 && tri.mat < len(chunk.mats) else ""
			tris[at] = {
				Points   = {chunk.verts[tri.v[0]], chunk.verts[tri.v[1]], chunk.verts[tri.v[2]]},
				Material = d3.d3_material_of(profile, code),
			}
			at += 1
		}
	}
	base.tris = tris
	return base, "", true
}

finland_bisect_write_route_files :: proc(base: Finland_Bisect_Base, tris: []d3.Collision_Triangle, profile: ^d3.Venue_Profile) -> (msg: string, ok: bool) {
	jpk_data, jpk_msg, jpk_ok := d3.d3_collision_build(tris, profile, context.temp_allocator)
	if !jpk_ok { return fmt.tprintf("track.jpk rebuild: %s", jpk_msg), false }
	jpk_path, _ := filepath.join({base.deployed_dir, "track.jpk"}, context.temp_allocator)
	if write_msg, written := d3.Atomic_Write(jpk_path, jpk_data); !written { return write_msg, false }

	routesplit_data, routesplit_msg, routesplit_ok := d3.d3_routesplit_build(tris, profile, context.temp_allocator)
	if !routesplit_ok { return fmt.tprintf("routesplit.pssg rebuild: %s", routesplit_msg), false }
	routesplit_path, _ := filepath.join({base.deployed_dir, "routesplit.pssg"}, context.temp_allocator)
	if write_msg, written := d3.Atomic_Write(routesplit_path, routesplit_data); !written { return write_msg, false }

	vis_data, vis_msg, vis_ok := d3.d3_stock_route_all_visible_vis(
		base.deployed_dir,
		base.deployed_venue_dir,
		base.donor_vis_path,
		.Donor,
		context.temp_allocator,
	)
	if !vis_ok { return fmt.tprintf("track.vis rebuild: %s", vis_msg), false }
	vis_path, _ := filepath.join({base.deployed_dir, "track.vis"}, context.temp_allocator)
	if write_msg, written := d3.Atomic_Write(vis_path, vis_data); !written { return write_msg, false }

	return fmt.tprintf(
		"track.jpk (%d tris, %s), routesplit.pssg (%s), track.vis (%s)",
		len(tris), jpk_msg, routesplit_msg, vis_msg,
	), true
}

// Finland's stock routes use this grid. Keep both stage-1 variants on the
// same partition so the flat test changes geometry, not render-object count.
finland_bisect_render_profile :: proc(profile: ^d3.Venue_Profile) -> d3.Venue_Profile {
	out := profile^
	out.tiles_x = 10
	out.tiles_z = 10
	return out
}

finland_bisect_stage1_headless :: proc(venue_id, route_id: string) -> (msg: string, ok: bool) {
	scan: Install_Scan
	ed := Editor{install = &scan}
	install_scan_init(ed.install)
	defer install_scan_delete(ed.install)
	base, prep_msg, prepped := finland_bisect_prepare(&ed, venue_id, route_id, context.allocator)
	if !prepped { return prep_msg, false }
	defer delete(base.tris)

	// Finland's stock routes use a 10x10 spatial grid; route_0 occupies 34 of
	// those cells. The profile's old <=32-cell restriction belongs to the
	// retired donor-slot VIS scheme, not to the PSSG format. Match the donor's
	// native partition here so the real-scale rebuild neither overloads the
	// old coarse profile's per-node payloads nor explodes into hundreds of
	// live render tiles. This copied profile deliberately bypasses the stale
	// d3_profile_complete validation until that general limit is replaced.
	wide_profile := finland_bisect_render_profile(base.profile)

	write_msg, written := finland_bisect_write_route_files(base, base.tris, &wide_profile)
	if !written { return write_msg, false }

	return fmt.tprintf(
		"%s\nrestored from donor: %v, tracksplit.pssg\nrebuilt through our writer, same real shape: %s",
		base.deployed_dir, base.restored, write_msg,
	), true
}

// Finland rally route_0's stock standing grid. This command is deliberately a
// Finland diagnostic; anchoring the plane to the donor surface beneath its
// unchanged grid keeps the one changed variable the route's relief.
FINLAND_BISECT_GRID_XZ :: [2]f32{-2128.7896, -520.8919}

finland_bisect_surface_y :: proc(tris: []d3.Collision_Triangle, at: [2]f32) -> (y: f32, ok: bool) {
	for tri in tris {
		a, b, c := tri.Points[0], tri.Points[1], tri.Points[2]
		denom := (b[2]-c[2])*(a[0]-c[0]) + (c[0]-b[0])*(a[2]-c[2])
		if abs(denom) < 1e-6 { continue }
		u := ((b[2]-c[2])*(at[0]-c[0]) + (c[0]-b[0])*(at[1]-c[2])) / denom
		v := ((c[2]-a[2])*(at[0]-c[0]) + (a[0]-c[0])*(at[1]-c[2])) / denom
		w := 1-u-v
		if u >= -1e-4 && v >= -1e-4 && w >= -1e-4 {
			return u*a[1] + v*b[1] + w*c[1], true
		}
	}
	return 0, false
}

// The donor's own real triangle soup's bounding box (X, Z). The flat plane
// keeps the real footprint but uses the donor surface height at the start grid.
finland_bisect_plane_bounds :: proc(tris: []d3.Collision_Triangle) -> (lo, hi: [2]f32, y: f32) {
	lo = {tris[0].Points[0][0], tris[0].Points[0][2]}
	hi = lo
	for tri in tris {
		for p in tri.Points {
			lo[0] = min(lo[0], p[0]); hi[0] = max(hi[0], p[0])
			lo[1] = min(lo[1], p[2]); hi[1] = max(hi[1], p[2])
		}
	}
	found: bool
	y, found = finland_bisect_surface_y(tris, FINLAND_BISECT_GRID_XZ)
	if !found { y = tris[0].Points[0][1] }
	return lo, hi, y
}

FINLAND_BISECT_FLAT_CELLS_X :: 60
FINLAND_BISECT_FLAT_CELLS_Z :: 60

finland_bisect_stage1_flat_headless :: proc(venue_id, route_id: string) -> (msg: string, ok: bool) {
	scan: Install_Scan
	ed := Editor{install = &scan}
	install_scan_init(ed.install)
	defer install_scan_delete(ed.install)
	base, prep_msg, prepped := finland_bisect_prepare(&ed, venue_id, route_id, context.allocator)
	if !prepped { return prep_msg, false }
	defer delete(base.tris)

	lo, hi, y := finland_bisect_plane_bounds(base.tris)
	plane := flat_venue_tiled_plane(lo, hi, y, FINLAND_BISECT_FLAT_CELLS_X, FINLAND_BISECT_FLAT_CELLS_Z, context.temp_allocator)

	wide_profile := finland_bisect_render_profile(base.profile)
	write_msg, written := finland_bisect_write_route_files(base, plane, &wide_profile)
	if !written { return write_msg, false }

	return fmt.tprintf(
		"%s\nrestored from donor: %v, tracksplit.pssg\nflat plane spanning the real route's own bounds (X %.1f..%.1f, Z %.1f..%.1f, Y %.2f): %s",
		base.deployed_dir, base.restored, lo[0], hi[0], lo[1], hi[1], y, write_msg,
	), true
}

FINLAND_BISECT_SHORT_RUNWAY :: f32(90)
FINLAND_BISECT_SHORT_STAGE :: f32(100)
FINLAND_BISECT_SHORT_WIDTH :: f32(12)
FINLAND_BISECT_GRID_FORWARD :: [3]f32{-0.56085795, 0, 0.82791203}
FINLAND_BISECT_GRID_LATERAL :: [3]f32{0.82791203, 0, 0.56085795}

finland_bisect_short_route :: proc(y: f32, allocator := context.allocator) -> []d3.Route_Sample {
	total := FINLAND_BISECT_SHORT_RUNWAY + FINLAND_BISECT_SHORT_STAGE
	step := f32(5)
	count := int(total/step)+1
	out := make([]d3.Route_Sample, count, allocator)
	// d3_grids_build places its grid one route width before the start marker:
	// distance 78 on this 12 m road. Anchor that point at Finland's real grid.
	origin := [3]f32{FINLAND_BISECT_GRID_XZ[0], y, FINLAND_BISECT_GRID_XZ[1]} -
		FINLAND_BISECT_GRID_FORWARD*(FINLAND_BISECT_SHORT_RUNWAY-FINLAND_BISECT_SHORT_WIDTH)
	half := FINLAND_BISECT_SHORT_WIDTH/2
	for &sample, i in out {
		centre := origin + FINLAND_BISECT_GRID_FORWARD*(f32(i)*step)
		sample = {
			Centre = centre,
			Left = centre-FINLAND_BISECT_GRID_LATERAL*half,
			Right = centre+FINLAND_BISECT_GRID_LATERAL*half,
		}
	}
	return out
}

finland_bisect_short_collision :: proc(route: []d3.Route_Sample, allocator := context.allocator) -> []d3.Collision_Triangle {
	out := make([]d3.Collision_Triangle, (len(route)-1)*2, allocator)
	for i in 0..<len(route)-1 {
		a, b := route[i].Left, route[i].Right
		c, d := route[i+1].Right, route[i+1].Left
		out[i*2] = {Points={a,c,b}, Material=.Road}
		out[i*2+1] = {Points={a,d,c}, Material=.Road}
	}
	return out
}

finland_bisect_short_headless :: proc(venue_id, route_id: string) -> (msg: string, ok: bool) {
	scan: Install_Scan
	ed := Editor{install = &scan}
	install_scan_init(ed.install)
	defer install_scan_delete(ed.install)
	base, prep_msg, prepped := finland_bisect_prepare(&ed, venue_id, route_id, context.allocator)
	if !prepped { return prep_msg, false }
	defer delete(base.tris)

	y, found := finland_bisect_surface_y(base.tris, FINLAND_BISECT_GRID_XZ)
	if !found { return "could not find Finland's collision beneath its start grid", false }
	route := finland_bisect_short_route(y, context.temp_allocator)
	collision := finland_bisect_short_collision(route, context.temp_allocator)
	markers := []d3.Progress_Marker{
		{Kind=.Start, Distance=FINLAND_BISECT_SHORT_RUNWAY},
		{Kind=.Checkpoint, Distance=FINLAND_BISECT_SHORT_RUNWAY+FINLAND_BISECT_SHORT_STAGE/4},
		{Kind=.Checkpoint, Distance=FINLAND_BISECT_SHORT_RUNWAY+FINLAND_BISECT_SHORT_STAGE/2},
		{Kind=.Checkpoint, Distance=FINLAND_BISECT_SHORT_RUNWAY+FINLAND_BISECT_SHORT_STAGE*3/4},
		// Stay inside the f32 polyline length after accumulating 38 segments.
		{Kind=.Finish, Distance=FINLAND_BISECT_SHORT_RUNWAY+FINLAND_BISECT_SHORT_STAGE-0.01},
	}
	profile := finland_bisect_render_profile(base.profile)
	export_msg, exported := d3.Export(&d3.Export_Job{
		Name=route_id, Out=base.deployed_dir, Backup=true,
		Route=route, Markers=markers, Collision=collision, Profile=&profile,
	})
	if !exported { return export_msg, false }

	vis_data, vis_msg, vis_ok := d3.d3_stock_route_all_visible_vis(
		base.deployed_dir, base.deployed_venue_dir, base.donor_vis_path,
		.Donor, context.temp_allocator,
	)
	if !vis_ok { return fmt.tprintf("track.vis: %s", vis_msg), false }
	vis_path, _ := filepath.join({base.deployed_dir, "track.vis"}, context.temp_allocator)
	if write_msg, written := d3.Atomic_Write(vis_path, vis_data); !written { return write_msg, false }

	return fmt.tprintf(
		"%s\n100 m timed straight at Finland's start, Y %.2f\nroute: %s\ncombined track.vis: %s",
		base.deployed_dir, y, export_msg, vis_msg,
	), true
}
