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
	raw,_,written:=d3_collision_build(collision,context.allocator)
	defer delete(raw)
	testing.expect(t,written)
	entries,opened:=jpak_read(raw,context.allocator)
	defer delete(entries)
	testing.expect(t,opened)
	testing.expect_value(t,len(entries),2)

	chunk,msg,decoded:=qt_read(entries[0].data,context.allocator)
	defer qt_chunk_delete(&chunk,context.allocator)
	testing.expect(t,decoded,msg)
	testing.expect_value(t,len(chunk.tris),len(collision))
	gravel,rock,grass:=0,0,0
	for triangle in chunk.tris {
		code:=chunk.mats[triangle.mat]
		switch code {
		case "GLD*": gravel+=1
		case "ROK*": rock+=1
		case "GRS*": grass+=1
		}
	}
	testing.expect_value(t,gravel,2) // Road_Sand intentionally shares gravel physics.
	testing.expect_value(t,rock,1)
	testing.expect_value(t,grass,1)
}
