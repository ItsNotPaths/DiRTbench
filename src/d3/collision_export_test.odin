package d3

import "core:testing"

@(test)
stage_collision_builds_an_archive_readable_by_our_decoder :: proc(t:^testing.T) {
	collision:=[]Collision_Triangle{
		{Points={{0,0,0},{10,0,0},{0,0,10}},Draw=.Road,Surface=.Road},
		{Points={{20,0,0},{30,0,0},{20,5,10}},Draw=.Cliff,Surface=.Cliff},
		{Points={{40,0,0},{50,0,0},{40,0,10}},Draw=.Terrain,Surface=.Terrain},
		{Points={{60,0,0},{70,0,0},{60,0,10}},Draw=.Road_Paved,Surface=.Road_Paved},
	}
	raw,_,written:=d3_collision_build(collision,d3_test_profile(),context.allocator)
	defer delete(raw)
	testing.expect(t,written)
	entries,opened:=jpak_read(raw,context.allocator)
	defer delete(entries)
	testing.expect(t,opened)
	// The archive root always splits at least once (a whole route collapsed to
	// one entry loads fine but the game never finds it, see d3_track_write), so
	// four well-separated triangles land in more than one .vcqtc chunk plus
	// qt.info.
	testing.expect(t,len(entries)>2)

	// A triangle straddling a partition seam is duplicated into every chunk it
	// touches, so tally materials across every chunk rather than assuming one
	// holds everything.
	gravel,rock,grass,tarmac:=0,0,0,0
	for e in entries {
		if e.name=="qt.info" { continue }
		chunk,msg,decoded:=qt_read(e.data,context.allocator)
		testing.expect(t,decoded,msg)
		for triangle in chunk.tris {
			switch chunk.mats[triangle.mat] {
			case "GLD*": gravel+=1
			case "ROK*": rock+=1
			case "GRS*": grass+=1
			case "TSD*": tarmac+=1
			}
		}
		qt_chunk_delete(&chunk,context.allocator)
	}
	testing.expect(t,gravel>=1)
	testing.expect(t,rock>=1)
	testing.expect(t,grass>=1)
	// The paved road carries its own code, which is the whole point of the
	// surface: same ribbon, different grip, dust and tyre note.
	testing.expect(t,tarmac>=1)
}

// The two axes really are two. One drawn material over two surface codes is
// what a run of road fading from gravel into tarmac needs: the paint crosses the
// boundary gradually and the grip cannot, so they part company there.
//
// Before the split this could not be said at all — one enum picked the shader
// and the code together.
@(test)
one_material_can_cover_two_surfaces :: proc(t: ^testing.T) {
	collision := []Collision_Triangle{
		{Points={{0,0,0},{10,0,0},{0,0,10}},   Draw=.Road, Surface=.Road},
		{Points={{40,0,0},{50,0,0},{40,0,10}}, Draw=.Road, Surface=.Road_Paved},
	}
	profile := d3_test_profile()
	testing.expect(t, profile.collision[.Road] != profile.collision[.Road_Paved],
		"the fixture must give the two surfaces different codes")

	raw, jpk_msg, written := d3_collision_build(collision, profile, context.allocator)
	testing.expect(t, written, jpk_msg); if !written { return }
	defer delete(raw)
	entries, opened := jpak_read(raw, context.allocator)
	defer delete(entries)
	testing.expect(t, opened)

	codes := make(map[string]bool, context.temp_allocator)
	for e in entries {
		if e.name == "qt.info" { continue }
		chunk, msg, decoded := qt_read(e.data, context.allocator)
		testing.expect(t, decoded, msg)
		for triangle in chunk.tris { codes[chunk.mats[triangle.mat]] = true }
		qt_chunk_delete(&chunk, context.allocator)
	}
	testing.expect(t, codes[profile.collision[.Road]], "the loose half kept its own code")
	testing.expect(t, codes[profile.collision[.Road_Paved]], "the paved half kept its own code")

	// And the drawn side sees one material, not two, because both triangles name
	// the same one. A scene that split them here would break the run into two
	// draw calls and put a seam where the whole point is not to have one.
	scene, scene_msg, built := d3_routesplit_build(collision, profile, context.allocator)
	testing.expect(t, built, scene_msg); if !built { return }
	defer delete(scene)
	file, read_msg, parsed := pssg_read(scene, context.allocator)
	testing.expect(t, parsed, read_msg); if !parsed { return }
	defer pssg_delete(&file)

	nodes := make([dynamic]^Pssg_Node, context.temp_allocator)
	d3_test_walk(file.root, &nodes)
	surface_shaders := make(map[string]bool, context.temp_allocator)
	for node in nodes {
		if node.name != "RENDERSTREAMINSTANCE" { continue }
		shader := d3_unref(pssg_attr_string(&file, node, "shader"))
		if shader == profile.lod || shader == profile.batch { continue }
		surface_shaders[shader] = true
	}
	testing.expect_value(t, len(surface_shaders), 1)
	testing.expect(t, surface_shaders[profile.visual[.Road]])
}

// An arena keeps a stock track.jpk minus the collision of the props it
// removed. A dropped triangle must be gone, and every other one must keep its
// surface code and its sheet bits, which our own collision never sets.
@(test)
jpk_without_drops_only_what_it_names :: proc(t:^testing.T) {
	input:=[]D3_Write_Tri{
		{p={{0,0,0},{10,0,0},{0,0,10}},mat="MET*",sheet=3},
		{p={{40,0,0},{50,0,0},{40,5,10}},mat="WDB+",sheet=1},
		{p={{80,0,0},{90,0,0},{80,0,10}},mat="GLD*",sheet=0},
	}
	stock,_,written:=d3_track_write(input,context.temp_allocator)
	testing.expect(t,written); if !written { return }

	// Index every stored copy, and drop each copy of the wooden one.
	entries,_:=jpak_read(stock,context.temp_allocator)
	drop:=make([dynamic]bool,context.temp_allocator)
	for e in entries {
		if e.name=="qt.info" { continue }
		chunk,_,_:=qt_read(e.data,context.temp_allocator)
		for tri in chunk.tris { append(&drop,chunk.mats[tri.mat]=="WDB+") }
	}

	out,msg,ok:=d3_jpk_without(stock,drop[:],context.temp_allocator)
	testing.expect(t,ok,msg); if !ok { return }
	after,_:=jpak_read(out,context.temp_allocator)
	found:=make(map[string]u8,context.temp_allocator)
	for e in after {
		if e.name=="qt.info" { continue }
		chunk,_,_:=qt_read(e.data,context.temp_allocator)
		for tri in chunk.tris { found[chunk.mats[tri.mat]]=u8(tri.sheet) }
	}
	testing.expect_value(t,len(found),2)
	_,wood:=found["WDB+"]
	testing.expect(t,!wood,"a dropped triangle came back")
	testing.expect_value(t,found["MET*"],u8(3))
	testing.expect_value(t,found["GLD*"],u8(0))
}
