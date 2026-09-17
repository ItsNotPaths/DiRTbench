package main

import "core:testing"

// One window per venue. Two views of the same road with two caches behind them
// would disagree the moment either one edited, so a second open raises the
// first window instead of making another.
@(test)
venue_editor_open_matches_venue_identity :: proc(t: ^testing.T) {
	app := App{}
	defer delete(app.editors)
	forest_doc := Venue_Doc{open_venue = "forest"}
	finland_doc := Venue_Doc{open_venue = "finland"}
	forest := Editor{doc = &forest_doc}
	finland := Editor{doc = &finland_doc}
	append(&app.editors, &forest, &finland)

	testing.expect(t, venue_editor_open(&app, "forest") == &forest)
	testing.expect(t, venue_editor_open(&app, "finland") == &finland)
	testing.expect(t, venue_editor_open(&app, "michigan") == nil)
}

// A document outlives every window but the last. Closing one of two windows on
// a venue must keep its geometry alive for the other, and the window being
// closed must leave the list before the survivors are counted — otherwise the
// scan reads the entry it is about to free.
@(test)
a_document_is_freed_only_with_its_last_window :: proc(t: ^testing.T) {
	app := App{}
	defer delete(app.editors)
	defer delete(app.docs)
	shared, alone := Venue_Doc{open_venue = "shared"}, Venue_Doc{open_venue = "alone"}
	a, b, c := Editor{doc = &shared}, Editor{doc = &shared}, Editor{doc = &alone}
	append(&app.editors, &a, &b, &c)
	append(&app.docs, &shared, &alone)

	testing.expect(t, editors_detach(&app, &a) == nil, "the shared document went with its first window")
	testing.expect_value(t, len(app.editors), 2)
	testing.expect_value(t, len(app.docs), 2)

	testing.expect(t, editors_detach(&app, &c) == &alone, "an only window did not release its document")
	testing.expect_value(t, len(app.docs), 1)

	testing.expect(t, editors_detach(&app, &b) == &shared, "the last window did not release the shared document")
	testing.expect_value(t, len(app.editors), 0)
	testing.expect_value(t, len(app.docs), 0)
}
