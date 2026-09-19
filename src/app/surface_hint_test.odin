package main

// Road surfaces: where a run of tarmac starts and where it stops.
//
// The property under test is the sparseness. A hint says "from here forward",
// so one edit covers a whole run and a limited section is two hints, the second
// naming what comes after. That is what makes a fork free — the hint reaches
// both branches without anyone walking them — and it is why most points store
// nothing at all.

import "core:testing"
import "../geo"
import "../gfx"

@(private = "file")
chain :: proc(sp: ^geo.Spline, count: int) {
	clear(&sp.points)
	clear(&sp.guards)
	for i in 0 ..< count {
		pos := gfx.Vector3{0, 0, f32(i) * 20}
		geo.spline_push(sp, geo.make_point(pos, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = i - 1))
	}
}

// The headline: one hint paves everything after it and nothing before it.
@(test)
a_hint_runs_forward_and_only_forward :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	chain(&sp, 6)
	sp.points[2].surface = .Paved

	got := geo.point_surfaces(sp, context.temp_allocator)
	want := [6]geo.Road_Surface{.Loose, .Loose, .Paved, .Paved, .Paved, .Paved}
	for expected, i in want {
		testing.expectf(t, got[i] == expected, "point %d reads %v, expected %v", i, got[i], expected)
	}
}

// And the user's case: two hints facing each other bound a section, with the
// second one naming what comes after rather than carrying a direction of its
// own.
@(test)
two_hints_bound_a_section :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	chain(&sp, 6)
	sp.points[1].surface = .Paved
	sp.points[4].surface = .Loose

	got := geo.point_surfaces(sp, context.temp_allocator)
	want := [6]geo.Road_Surface{.Loose, .Paved, .Paved, .Paved, .Loose, .Loose}
	for expected, i in want {
		testing.expectf(t, got[i] == expected, "point %d reads %v, expected %v", i, got[i], expected)
	}
}

// A fork costs nothing. The hint is upstream of the split, so both branches take
// it without the resolution walking anything.
@(test)
a_hint_reaches_every_branch_below_it :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	chain(&sp, 3)
	sp.points[0].surface = .Paved
	// Two children of point 1: the chain's own point 2, and a spur.
	geo.spline_push(&sp, geo.make_point({40, 0, 20}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = 1))
	geo.spline_push(&sp, geo.make_point({60, 0, 20}, gfx.Quaternion(1), geo.DEFAULT_WIDTH, parent = 3))

	got := geo.point_surfaces(sp, context.temp_allocator)
	for surface, i in got {
		testing.expectf(t, surface == .Paved, "point %d reads %v, the fork must inherit", i, surface)
	}
}

// The ribbon takes the surface of the node each slice leaves, never a blend
// across the span into it. A lerp would put the visual change in a different
// place from the collision change, which reads in game as a strip of road that
// looks paved and drives loose.
@(test)
the_ribbon_changes_surface_at_a_point :: proc(t: ^testing.T) {
	sp: geo.Spline
	defer geo.spline_free(&sp)
	chain(&sp, 4)
	sp.points[2].surface = .Paved
	ribbon := geo.build_ribbon(sp, allocator = context.temp_allocator)

	seen: [geo.Road_Surface]int
	for cs in ribbon {
		seen[cs.surface] += 1
		want: geo.Road_Surface = cs.e_from >= 2 ? .Paved : .Loose
		testing.expectf(t, cs.surface == want,
			"a slice leaving point %d reads %v, expected %v", cs.e_from, cs.surface, want)
	}
	testing.expect(t, seen[.Loose] > 0 && seen[.Paved] > 0, "both surfaces must appear")
	testing.expect_value(t, seen[.None], 0)
}

// Through the file and back. A surface is written by name, so a value inserted
// into the enum later cannot renumber what is already on disk.
@(test)
a_surface_survives_the_document :: proc(t: ^testing.T) {
	for surface in geo.Road_Surface {
		testing.expect_value(t, surface_of(SURFACE_KEY[surface]), surface)
	}
	// `.None` writes nothing, so an old file with no surface key at all reads
	// back as a road that states nothing — which is what it meant.
	testing.expect_value(t, SURFACE_KEY[.None], "")
	testing.expect_value(t, surface_of(""), geo.Road_Surface.None)
	testing.expect_value(t, surface_of("granite"), geo.Road_Surface.None)
}
