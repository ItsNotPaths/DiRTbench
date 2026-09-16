package d3

import "core:testing"

@(test)
stage_collision_builds_an_archive_readable_by_our_decoder :: proc(t:^testing.T) {
	collision:=[]Collision_Triangle{
		{Points={{0,0,0},{10,0,0},{0,0,10}},Material=.Road},
		{Points={{20,0,0},{30,0,0},{20,5,10}},Material=.Cliff},
		{Points={{40,0,0},{50,0,0},{40,0,10}},Material=.Terrain},
		{Points={{60,0,0},{70,0,0},{60,0,10}},Material=.Road_Sand},
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
	gravel,rock,grass:=0,0,0
	for e in entries {
		if e.name=="qt.info" { continue }
		chunk,msg,decoded:=qt_read(e.data,context.allocator)
		testing.expect(t,decoded,msg)
		for triangle in chunk.tris {
			switch chunk.mats[triangle.mat] {
			case "GLD*": gravel+=1
			case "ROK*": rock+=1
			case "GRS*": grass+=1
			}
		}
		qt_chunk_delete(&chunk,context.allocator)
	}
	testing.expect(t,gravel>=2) // Road_Sand intentionally shares gravel physics.
	testing.expect(t,rock>=1)
	testing.expect(t,grass>=1)
}
