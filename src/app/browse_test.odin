package main

import "core:strings"
import "core:testing"

// --- the query -----------------------------------------------------------------

// Whatever is typed into the search box is one query-string value and can never
// become another parameter. `&sort=` here would otherwise silently re-sort the
// listing, and a `#` would truncate the URL.
@(test)
a_search_cannot_reshape_its_own_url :: proc(t: ^testing.T) {
	url := browse_url("rally* &sort=rating", .New, 1, context.allocator)
	defer delete(url)

	testing.expect(t, strings.contains(url, "sort=new"), url)
	testing.expect(t, !strings.contains(url, "sort=rating"), url)
	testing.expect(t, strings.contains(url, "q=rally%2A%20%26sort%3Drating"), url)
}

// Page 1 is the default, so it is not sent; a later page is.
@(test)
only_a_later_page_is_asked_for_by_number :: proc(t: ^testing.T) {
	first := browse_url("", .Downloads, 1, context.allocator)
	defer delete(first)
	later := browse_url("", .Downloads, 3, context.allocator)
	defer delete(later)

	testing.expect(t, !strings.contains(first, "page="), first)
	testing.expect(t, strings.contains(later, "page=3"), later)
	testing.expect(t, strings.contains(later, "sort=downloads"), later)
}

// An empty box asks for everything, rather than asking for the empty string.
@(test)
an_empty_search_sends_no_query :: proc(t: ^testing.T) {
	url := browse_url("   ", .New, 1, context.allocator)
	defer delete(url)
	testing.expect(t, !strings.contains(url, "q="), url)
}

// --- what comes back -------------------------------------------------------------

@(private = "file")
SAMPLE :: `{"ok":true,"total":2,"page":1,"pages":1,"limit":25,"venues":[
 {"slug":"pine-ridge-ab12cd","venue_id":"pine_ridge","title":"Pine Ridge","author":"paths",
  "stages":3,"length_m":12400,"bytes":88213,"downloads":41,"version":2,
  "rating":{"average":4.5,"count":7},"created":"2026-09-01T10:00:00+00:00",
  "thumb_url":"https://dirtbench.paths.place/t/ab/cd","page_url":"https://dirtbench.paths.place/venue/pine-ridge-ab12cd",
  "download_url":"https://dirtbench.paths.place/d/pine-ridge-ab12cd"},
 {"slug":"fog-line-99","venue_id":"fog_line","title":"Fog Line","author":"someone",
  "stages":null,"length_m":null,"bytes":4011,"downloads":0,"version":1,
  "rating":{"average":null,"count":0},"page_url":"https://dirtbench.paths.place/venue/fog-line-99"}]}`

@(private = "file")
sample_browser :: proc(body: string) -> Browser {
	br := Browser{}
	br.job = Browse_Job{kind = .Search, body = strings.clone(body)}
	return br
}

// The listing the panel draws, out of the bytes the site sends. Keys it does
// not know are ignored on purpose: the site adds fields without warning.
@(test)
a_listing_page_reads_back_whole :: proc(t: ^testing.T) {
	br := sample_browser(SAMPLE)
	defer browser_delete(&br)

	msg, ok := browse_keep(&br)
	testing.expectf(t, ok, "the sample listing did not parse: %s", msg)
	testing.expect_value(t, br.results.total, 2)
	testing.expect_value(t, len(br.results.venues), 2)

	first := br.results.venues[0]
	testing.expect_value(t, first.slug, "pine-ridge-ab12cd")
	testing.expect_value(t, first.venue_id, "pine_ridge")
	testing.expect_value(t, first.author, "paths")
	testing.expect_value(t, first.stages, 3)
	testing.expect_value(t, first.length_m, 12400)
	testing.expect_value(t, first.downloads, 41)
	testing.expect_value(t, first.rating.count, 7)
}

// The site sends null for a figure it could not measure. Null is not a number,
// and the row says so rather than claiming a venue with no stages.
@(test)
an_unmeasured_venue_reads_as_unmeasured :: proc(t: ^testing.T) {
	br := sample_browser(SAMPLE)
	defer browser_delete(&br)
	_, ok := browse_keep(&br)
	testing.expect(t, ok)

	second := br.results.venues[1]
	testing.expect_value(t, second.stages, 0)
	testing.expect_value(t, second.length_m, 0)
	testing.expect_value(t, second.rating.average, f32(0))

	text := browse_row_text(second, context.allocator)
	defer delete(text)
	testing.expect(t, strings.contains(text, "stages not measured"), text)
	testing.expect(t, !strings.contains(text, "km"), text)
	testing.expect(t, !strings.contains(text, "rated"), text)
}

// A body that is not a listing leaves the panel with the page it already had,
// rather than half of one.
@(test)
an_answer_that_is_not_a_listing_is_refused :: proc(t: ^testing.T) {
	br := sample_browser("<html>502 Bad Gateway</html>")
	defer browser_delete(&br)

	_, ok := browse_keep(&br)
	testing.expect(t, !ok, "html parsed as a venue listing")
	testing.expect_value(t, len(br.results.venues), 0)
}

// --- the bytes -------------------------------------------------------------------

// The download is checked against the hash the site publishes, so the hash has
// to be the one everybody else means by SHA-256.
@(test)
the_download_hash_is_the_one_the_site_means :: proc(t: ^testing.T) {
	got := sha256_hex(transmute([]u8)string("abc"), context.allocator)
	defer delete(got)
	testing.expect_value(
		t, got, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	)
}

// Bytes off the network are a venue only because this parses them. Anything
// else must never reach maps/.
@(test)
a_download_that_is_not_a_venue_never_becomes_one :: proc(t: ^testing.T) {
	for body in ([]string{"", "{}", `{"format":"dirtbench.venue","version":1}`, "not json"}) {
		_, msg, ok := venue_parse(transmute([]u8)body, "the download", context.allocator)
		testing.expectf(t, !ok, "%q was read as a venue", body)
		testing.expect(t, msg != "", "a refusal with no reason")
	}
}

// --- update or collision ---------------------------------------------------------

// A download overwrites a venue only when that venue is this listing's own
// copy. Anything else sharing the id is somebody's work, and the id is what the
// game installs under, so the two cannot both be there.
@(test)
only_a_venue_s_own_listing_may_overwrite_it :: proc(t: ^testing.T) {
	mine := Venue{id = "00112233445566aa", name = "pine", source = {site = UPLOAD_SITE, slug = "pine-ridge-ab12cd"}}
	testing.expect(t, venue_is_copy_of(mine, "pine-ridge-ab12cd"), "an update was read as a collision")
	testing.expect(t, !venue_is_copy_of(mine, "pine-ridge-ff99"), "another listing could overwrite it")

	// Made here, never published. Nothing downloaded may land on it.
	testing.expect(t, !venue_is_copy_of(Venue{id = "00112233445566aa", name = "pine"}, "pine-ridge-ab12cd"))
	// Published from here, which is not the same as downloaded from there: the
	// slug an upload remembers lives in the config, not in the document.
	own_upload := Venue{id = "00112233445566aa", name = "pine", source = {slug = "pine-ridge-ab12cd"}}
	testing.expect(t, !venue_is_copy_of(own_upload, "pine-ridge-ab12cd"))
}
