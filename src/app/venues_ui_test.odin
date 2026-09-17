package main

import "core:testing"

@(test)
venue_editor_running_matches_venue_identity :: proc(t: ^testing.T) {
	ps := Venues_Screen{}
	append(
		&ps.editors,
		Venue_Editor_Process{venue_id = "forest"},
		Venue_Editor_Process{venue_id = "finland"},
	)
	defer delete(ps.editors)

	testing.expect(t, venue_editor_running(&ps, "forest"))
	testing.expect(t, venue_editor_running(&ps, "finland"))
	testing.expect(t, !venue_editor_running(&ps, "michigan"))
}
