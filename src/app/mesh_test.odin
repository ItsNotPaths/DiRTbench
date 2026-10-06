package main

// `--mesh`: a game server builds a level from a venue file alone. It needs the
// whole network's triangles, a surface on every primitive, the same bytes every
// time (it caches by hash), and a refusal of any document it cannot read. The
// scene extras carry each route's centreline and the editor's tree scatter.

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:testing"
import d3 "../d3"
import "../geo"

@(private = "file")
Glb_Json :: struct {
	meshes:    []struct {
		primitives: []struct {
			attributes: struct {
				POSITION: int,
			},
			material:   int,
		},
	},
	materials: []struct {
		extras: struct {
			surface: string,
		},
	},
	accessors: []struct {
		count: int,
	},
	scenes:    []struct {
		extras: Glb_Extras,
	},
}

@(private = "file")
Glb_Extras :: struct {
	routes: []struct {
		id:     string,
		points: [][4]f32,
	},
	trees:  []struct {
		pos:   [3]f32,
		shape: string,
	},
}

@(private = "file")
read_glb :: proc(t: ^testing.T, path: string) -> (doc: Glb_Json, ok: bool) {
	glb, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(glb) < 20 {
		testing.expectf(t, false, "could not read %s", path)
		return
	}
	json_len := int(le_u32(glb, 12))
	err := json.unmarshal(glb[20:20 + json_len], &doc, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil)
	return doc, err == nil
}

@(private = "file")
le_u32 :: proc(b: []byte, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

@(private = "file")
TEST_START :: geo.Road_Marker{from = 0, to = 1, t = 0.2}

// The seed road with ground and a cliff, so road, terrain and guard all land,
// one stage over it, and trees when `veg` says so.
@(private = "file")
write_test_venue :: proc(t: ^testing.T, path: string, veg := true) -> bool {
	doc := doc_defaults()
	defer doc_delete(&doc)
	seed_spline(&doc.spline)
	doc.terrain.enabled = true
	doc.veg.enabled = veg
	geo.guard_add(&doc.spline, geo.guard_make(.Cliff, 1, 2))
	routes_add(&doc.routes, &doc.next_route)
	doc.routes[0].start = TEST_START
	doc.routes[0].finish = {from = 2, to = 3, t = 0.8}
	msg, ok := save_road(&doc, path)
	testing.expect(t, ok, msg)
	return ok
}

@(test)
a_venue_meshes_into_a_glb_of_every_built_triangle :: proc(t: ^testing.T) {
	venue := "/tmp/claude-1000/dirtbench-mesh-venue.json"
	out := "/tmp/claude-1000/dirtbench-mesh.glb"
	defer os.remove(venue)
	defer os.remove(out)
	if !write_test_venue(t, venue) {
		return
	}

	msg, ok := mesh_headless(venue, out)
	testing.expect(t, ok, msg)
	if !ok {
		return
	}
	glb, rerr := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect_value(t, le_u32(glb, 0), u32(GLB_MAGIC))
	testing.expect_value(t, int(le_u32(glb, 8)), len(glb))
	doc, _ := read_glb(t, out)

	built := doc_defaults()
	defer doc_delete(&built)
	load_msg, loaded := load_road(&built, venue)
	testing.expect(t, loaded, load_msg)
	g, gmsg, gok := build_geometry(&built, built.spline)
	defer export_geometry_delete(&g)
	testing.expect(t, gok, gmsg)
	testing.expect(t, g.counts[.Terrain] > 0 && g.counts[.Cliff] > 0, "the test venue lost its ground or its cliff")

	tris := 0
	for p in doc.meshes[0].primitives {
		tris += doc.accessors[p.attributes.POSITION].count / 3
		surface := doc.materials[p.material].extras.surface
		known := false
		for s in d3.Collision_Surface {
			known ||= surface == fmt.tprintf("%v", s)
		}
		testing.expectf(t, known, "a primitive drives as %q", surface)
	}
	testing.expect_value(t, tris, len(g.order))
}

@(test)
the_same_venue_meshes_to_the_same_bytes :: proc(t: ^testing.T) {
	venue := "/tmp/claude-1000/dirtbench-mesh-twice.json"
	a := "/tmp/claude-1000/dirtbench-mesh-a.glb"
	b := "/tmp/claude-1000/dirtbench-mesh-b.glb"
	defer os.remove(venue)
	defer os.remove(a)
	defer os.remove(b)
	if !write_test_venue(t, venue) {
		return
	}
	msg, ok := mesh_headless(venue, a)
	testing.expect(t, ok, msg)
	msg, ok = mesh_headless(venue, b)
	testing.expect(t, ok, msg)
	first, _ := os.read_entire_file(a, context.temp_allocator)
	second, _ := os.read_entire_file(b, context.temp_allocator)
	testing.expect(t, len(first) > 0 && string(first) == string(second), "two meshes of one venue differ")
}

@(test)
a_document_of_another_format_or_version_is_refused :: proc(t: ^testing.T) {
	venue := "/tmp/claude-1000/dirtbench-mesh-bad.json"
	out := "/tmp/claude-1000/dirtbench-mesh-bad.glb"
	defer os.remove(venue)
	defer os.remove(out)
	bad := []string {
		fmt.tprint(`{"format":"dirtbench.stage","version":`, VENUE_VERSION, "}", sep = ""),
		fmt.tprint(`{"format":"`, VENUE_FORMAT, `","version":`, VENUE_VERSION + 1, "}", sep = ""),
	}
	for body in bad {
		testing.expect(t, os.write_entire_file(venue, transmute([]u8)body) == nil)
		msg, ok := mesh_headless(venue, out)
		testing.expectf(t, !ok, "%s was meshed", body)
		testing.expect(t, msg != "", "a refused venue gave no reason")
		testing.expect(t, !os.exists(out), "a refused venue still wrote a mesh")
	}
}

@(test)
every_route_ships_its_centreline_from_the_start_line :: proc(t: ^testing.T) {
	venue := "/tmp/claude-1000/dirtbench-mesh-routes.json"
	out := "/tmp/claude-1000/dirtbench-mesh-routes.glb"
	defer os.remove(venue)
	defer os.remove(out)
	if !write_test_venue(t, venue) {
		return
	}
	msg, ok := mesh_headless(venue, out)
	testing.expect(t, ok, msg)
	doc, read := read_glb(t, out)
	if !ok || !read {
		return
	}
	routes := doc.scenes[0].extras.routes
	testing.expect_value(t, len(routes), 1)
	if len(routes) != 1 {
		return
	}
	testing.expect(t, len(routes[0].points) >= 2, "a route has no centreline")

	built := doc_defaults()
	defer doc_delete(&built)
	load_road(&built, venue)
	at, on_road := geo.marker_resolve(built.spline, TEST_START)
	testing.expect(t, on_road)
	start := geo.marker_point(built.spline, at).xform.translation
	first := routes[0].points[0]
	gap := linalg.distance(start, [3]f32{first.x, first.y, first.z})
	testing.expectf(t, gap < 0.01, "the centreline starts %.3f m off the start line", gap)
	testing.expect(t, first.w > 0, "a route point has no road width")
}

@(test)
trees_scatter_the_same_twice_and_not_at_all_when_off :: proc(t: ^testing.T) {
	venue := "/tmp/claude-1000/dirtbench-mesh-trees.json"
	a := "/tmp/claude-1000/dirtbench-mesh-trees-a.glb"
	b := "/tmp/claude-1000/dirtbench-mesh-trees-b.glb"
	defer os.remove(venue)
	defer os.remove(a)
	defer os.remove(b)
	if !write_test_venue(t, venue) {
		return
	}
	mesh_headless(venue, a)
	mesh_headless(venue, b)
	first, a_ok := read_glb(t, a)
	second, b_ok := read_glb(t, b)
	if !a_ok || !b_ok {
		return
	}
	ta, tb := first.scenes[0].extras.trees, second.scenes[0].extras.trees
	testing.expect(t, len(ta) > 0, "the test venue scattered no trees")
	testing.expect_value(t, len(tb), len(ta))
	for i in 0 ..< min(len(ta), len(tb)) {
		testing.expect(t, ta[i] == tb[i], "two scatters of one venue differ")
	}

	if !write_test_venue(t, venue, veg = false) {
		return
	}
	msg, ok := mesh_headless(venue, a)
	testing.expect(t, ok, msg)
	off, _ := read_glb(t, a)
	testing.expect_value(t, len(off.scenes[0].extras.trees), 0)
}
