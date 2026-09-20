package main

import "core:testing"
import "../geo"
import "../gfx"

// Four controls in a row, 10 m apart, at the offsets given.
brush_fixture :: proc(offsets: []f32) -> (doc: Venue_Doc, pos: []gfx.Vector3) {
	for o, i in offsets {
		append(&doc.terrain.controls, geo.Terrain_Control{x = f32(i) * 10, z = 0, offset = o, radius = 10})
	}
	pos = make([]gfx.Vector3, len(offsets))
	for c, i in doc.terrain.controls {
		pos[i] = {c.x, c.offset, c.z}
	}
	return
}

// The brush takes every control inside its radius, measured on the ground plane,
// and always the one it grew from. At a falloff of 0 it is a hard-edged
// cylinder: everything in reach takes the whole move.
@(test)
brush_covers_the_radius :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0, 0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush = {radius = 15}, brush_taper = 0}
	defer { delete(ed.terrain_brush_weight); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	testing.expect_value(t, len(ed.terrain_brush_weight), 4)
	testing.expect_value(t, ed.terrain_brush_weight[0], f32(1)) // the anchor
	testing.expect_value(t, ed.terrain_brush_weight[1], f32(1)) // 10 m, inside 15
	testing.expect_value(t, ed.terrain_brush_weight[2], f32(0)) // 20 m, outside it
	testing.expect_value(t, ed.terrain_brush_weight[3], f32(0)) // 30 m

	// A zero radius is a single-control brush, not an empty one.
	ed.terrain_brush.radius = 0
	terrain_brush_select(&ed, pos, 2)
	testing.expect_value(t, ed.terrain_brush_weight[2], f32(1))
	testing.expect_value(t, ed.terrain_brush_weight[1], f32(0))
}

// With a falloff the brush is a dome: the anchor takes the whole move and a
// control further out takes less the further out it is.
@(test)
brush_falls_off_across_the_ground :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0, 0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush = {radius = 30}, brush_taper = 1}
	defer { delete(ed.terrain_brush_weight); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	terrain_brush_apply(&ed, 10)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(10))
	testing.expect(t, ed.terrain_brush_weight[1] < 1, "10 m out should take less than the anchor")
	testing.expect(
		t,
		ed.terrain_brush_weight[2] < ed.terrain_brush_weight[1],
		"the falloff should keep falling",
	)
	testing.expect_value(t, ed.terrain_brush_weight[3], f32(0)) // 30 m: the edge of the reach
	testing.expect_value(t, doc.terrain.controls[3].offset, f32(0))

	// Shift is the way back to a block move: everything held takes the lot.
	ed.terrain_brush.rigid = true
	terrain_brush_apply(&ed, 10)
	testing.expect_value(t, doc.terrain.controls[1].offset, f32(10))
	testing.expect_value(t, doc.terrain.controls[2].offset, f32(10))
	testing.expect_value(t, doc.terrain.controls[3].offset, f32(0))
}

// Sizing the brush re-anchors on the offsets already moved, so a move follows a
// snapshot rather than a raw height. Masked controls take snapshot + dy; the
// rest hold.
@(test)
brush_move_is_relative_to_the_snapshot :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({5, -2, 9, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush = {radius = 15}, brush_taper = 0}
	defer { delete(ed.terrain_brush_weight); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	terrain_brush_apply(&ed, 3)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(8))
	testing.expect_value(t, doc.terrain.controls[1].offset, f32(1))
	testing.expect_value(t, doc.terrain.controls[2].offset, f32(9))

	// A second drag of the same brush is absolute against the snapshot, so it
	// replaces the first rather than stacking on it.
	terrain_brush_apply(&ed, -1)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(4))
	testing.expect_value(t, doc.terrain.controls[1].offset, f32(-3))
}

// A rebuild can shrink the controls under a live brush. The stale weights and
// snapshot must not be read past their end, and the surviving controls still
// move.
@(test)
brush_survives_controls_shrinking_under_it :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0, 0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush = {radius = 100}, brush_taper = 0}
	defer { delete(ed.terrain_brush_weight); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	resize(&doc.terrain.controls, 2)
	terrain_brush_apply(&ed, 4)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(4))
	testing.expect_value(t, doc.terrain.controls[1].offset, f32(4))

	// Growing back under it is not the same control, but the weights and the
	// snapshot are addressed by index, so the new one at index 2 is swept along
	// until the next select. The bounds only stop the read running off the end.
	append(&doc.terrain.controls, geo.Terrain_Control{x = 20, radius = 10, offset = 7})
	terrain_brush_apply(&ed, 1)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(1))
	testing.expect_value(t, doc.terrain.controls[2].offset, f32(1))
}

// Clearing drops the phase and both buffers, so a window that loses focus
// mid-brush leaves nothing behind for the next one.
@(test)
brush_clear_drops_the_phase_and_buffers :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush = {radius = 100, phase = .Move}, brush_taper = 0}
	defer { delete(ed.terrain_brush_weight); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	terrain_brush_clear(&ed)
	testing.expect_value(t, ed.terrain_brush.phase, Brush_Phase.None)
	testing.expect_value(t, len(ed.terrain_brush_weight), 0)
	testing.expect_value(t, len(ed.terrain_brush_offsets), 0)

	// Applying with nothing selected moves nothing.
	terrain_brush_apply(&ed, 5)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(0))
}
