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
// and always the one it grew from.
@(test)
brush_mask_covers_the_radius :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0, 0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush_radius = 15}
	defer { delete(ed.terrain_brush_mask); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	testing.expect_value(t, len(ed.terrain_brush_mask), 4)
	testing.expect(t, ed.terrain_brush_mask[0], "the anchor is always in")
	testing.expect(t, ed.terrain_brush_mask[1], "10 m is inside a 15 m radius")
	testing.expect(t, !ed.terrain_brush_mask[2], "20 m is outside it")
	testing.expect(t, !ed.terrain_brush_mask[3], "30 m is outside it")

	// A zero radius is a single-control brush, not an empty one.
	ed.terrain_brush_radius = 0
	terrain_brush_select(&ed, pos, 2)
	testing.expect(t, ed.terrain_brush_mask[2], "the anchor survives a zero radius")
	testing.expect(t, !ed.terrain_brush_mask[1], "nothing else does")
}

// Sizing the brush re-anchors on the offsets already moved, so a move follows a
// snapshot rather than a raw height. Masked controls take snapshot + dy; the
// rest hold.
@(test)
brush_move_is_relative_to_the_snapshot :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({5, -2, 9, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush_radius = 15}
	defer { delete(ed.terrain_brush_mask); delete(ed.terrain_brush_offsets) }

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

// A rebuild can shrink the controls under a live brush. The stale mask and
// snapshot must not be read past their end, and the surviving controls still
// move.
@(test)
brush_survives_controls_shrinking_under_it :: proc(t: ^testing.T) {
	doc, pos := brush_fixture({0, 0, 0, 0})
	defer { geo.terrain_delete(&doc.terrain); delete(pos) }
	ed := Editor{doc = &doc, terrain_brush_radius = 100}
	defer { delete(ed.terrain_brush_mask); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	resize(&doc.terrain.controls, 2)
	terrain_brush_apply(&ed, 4)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(4))
	testing.expect_value(t, doc.terrain.controls[1].offset, f32(4))

	// Growing back under it is not the same control, but the mask and the
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
	ed := Editor{doc = &doc, terrain_brush_radius = 100, terrain_brush_phase = .Move}
	defer { delete(ed.terrain_brush_mask); delete(ed.terrain_brush_offsets) }

	terrain_brush_select(&ed, pos, 0)
	terrain_brush_snapshot(&ed)
	terrain_brush_clear(&ed)
	testing.expect_value(t, ed.terrain_brush_phase, Terrain_Brush_Phase.None)
	testing.expect_value(t, len(ed.terrain_brush_mask), 0)
	testing.expect_value(t, len(ed.terrain_brush_offsets), 0)

	// Applying with nothing selected moves nothing.
	terrain_brush_apply(&ed, 5)
	testing.expect_value(t, doc.terrain.controls[0].offset, f32(0))
}
