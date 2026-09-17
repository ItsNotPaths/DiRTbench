package main

import "core:testing"

// One window per venue. Two views of the same road with two caches behind them
// would disagree the moment either one edited, so a second open raises the
// first window instead of making another.
@(test)
venue_editor_open_matches_venue_identity :: proc(t: ^testing.T) {
	app := App{}
	defer delete(app.editors)
	forest := Editor{open_venue = "forest"}
	finland := Editor{open_venue = "finland"}
	append(&app.editors, &forest, &finland)

	testing.expect(t, venue_editor_open(&app, "forest") == &forest)
	testing.expect(t, venue_editor_open(&app, "finland") == &finland)
	testing.expect(t, venue_editor_open(&app, "michigan") == nil)
}
