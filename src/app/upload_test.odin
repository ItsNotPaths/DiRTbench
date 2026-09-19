package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../geo"
import "../gfx"
import "../net"

// --- the form ------------------------------------------------------------------

@(private = "file")
field_of :: proc(fields: []net.Form_Field, name: string) -> (net.Form_Field, bool) {
	for f in fields {
		if f.name == name {
			return f, true
		}
	}
	return {}, false
}

// An upload with no slug is a new listing. Sending an empty one instead makes
// the endpoint look for a listing called "", which answers 404.
@(test)
a_first_upload_sends_no_slug :: proc(t: ^testing.T) {
	job := Upload_Job{
		username   = "paths",
		title      = "Pine Ridge",
		level_path = "maps/pine.json",
	}
	fields := upload_fields(job, context.allocator)
	defer delete(fields)

	_, has_slug := field_of(fields, "slug")
	testing.expect(t, !has_slug, "an empty slug was sent")
	level, has_level := field_of(fields, "level")
	testing.expect(t, has_level, "the document itself was not attached")
	testing.expect_value(t, level.filename, "pine.json")
	testing.expect_value(t, level.mime, "application/json")
	testing.expect_value(t, level.value, "")
}

// A venue that has been published before posts a new version of its listing,
// which is what the remembered slug is for.
@(test)
a_later_upload_names_its_listing :: proc(t: ^testing.T) {
	job := Upload_Job{slug = "pine-ridge-ab12cd", level_path = "maps/pine.json"}
	fields := upload_fields(job, context.allocator)
	defer delete(fields)

	slug, has_slug := field_of(fields, "slug")
	testing.expect(t, has_slug, "the listing was not named")
	testing.expect_value(t, slug.value, "pine-ridge-ab12cd")
}

// No image part at all when there is no image: an empty one would be an upload
// error, not an absent thumbnail.
@(test)
an_upload_without_a_picture_sends_no_image_part :: proc(t: ^testing.T) {
	fields := upload_fields(Upload_Job{level_path = "maps/pine.json"}, context.allocator)
	defer delete(fields)
	_, has_image := field_of(fields, "image")
	testing.expect(t, !has_image)
}

@(test)
an_override_image_is_typed_by_its_extension :: proc(t: ^testing.T) {
	fields := upload_fields(
		Upload_Job{level_path = "maps/pine.json", image_path = "/home/paths/Shot.PNG"},
		context.allocator,
	)
	defer delete(fields)
	image, has_image := field_of(fields, "image")
	testing.expect(t, has_image)
	testing.expect_value(t, image.mime, "image/png")
	testing.expect_value(t, image.path, "/home/paths/Shot.PNG")
}

// --- the shot travels with the document ------------------------------------------

// The thumbnail camera is saved with the venue and nothing else about the
// picture is. A round trip is the whole contract: the site renders nothing, so
// a shot that does not survive the file is a shot that never existed.
@(test)
a_venue_round_trips_its_shot_and_its_source :: proc(t: ^testing.T) {
	path, _ := filepath.join({".", "dirtbench-shot-test.json"}, context.allocator)
	defer delete(path)
	defer os.remove(path)

	p := Venue {
		format  = VENUE_FORMAT,
		version = VENUE_VERSION,
		id      = "pine",
		names   = {venue = "PINE RIDGE"},
		shot    = {set = true, pos = {12, 34, 56}, yaw = 0.75, pitch = -0.25},
		source  = {site = "dirtbench.paths.place", slug = "pine-ridge-ab12cd"},
		road    = {},
	}
	msg, ok := venue_write(p, path)
	testing.expectf(t, ok, "could not write the venue: %s", msg)

	back, load_msg, loaded := venue_load_path(path, context.allocator)
	defer venue_free(back, context.allocator)
	testing.expectf(t, loaded, "could not read the venue back: %s", load_msg)

	testing.expect(t, back.shot.set, "the saved view came back unset")
	testing.expect_value(t, back.shot.pos, [3]f32{12, 34, 56})
	testing.expect_value(t, back.shot.yaw, f32(0.75))
	testing.expect_value(t, back.shot.pitch, f32(-0.25))
	testing.expect_value(t, back.source.slug, "pine-ridge-ab12cd")
	testing.expect_value(t, back.source.site, "dirtbench.paths.place")
}

// A venue nobody framed carries an unset shot, not a camera at the origin: the
// renderer falls back to framing the whole road, and it has to be able to tell.
@(test)
an_unframed_venue_stays_unframed_across_a_write :: proc(t: ^testing.T) {
	path, _ := filepath.join({".", "dirtbench-unframed-test.json"}, context.allocator)
	defer delete(path)
	defer os.remove(path)

	p := Venue{format = VENUE_FORMAT, version = VENUE_VERSION, id = "pine"}
	msg, ok := venue_write(p, path)
	testing.expectf(t, ok, "could not write the venue: %s", msg)

	back, _, loaded := venue_load_path(path, context.allocator)
	defer venue_free(back, context.allocator)
	testing.expect(t, loaded)
	testing.expect(t, !back.shot.set, "an unframed venue came back framed")
	testing.expect_value(t, back.source.slug, "")
}

// --- the picture has to have the venue in it ------------------------------------

@(private = "file")
straight_road_doc :: proc(doc: ^Venue_Doc) {
	// 200 m of road along +X at the origin, which is all the framing test reads.
	doc.ribbon = make([]geo.Cross_Section, 21, context.allocator)
	for i in 0 ..< len(doc.ribbon) {
		doc.ribbon[i] = geo.Cross_Section{pos = {f32(i) * 10, 0, 0}}
	}
}

// A camera looking at the road sees it; the same camera turned around sees
// nothing. Without this, a saved view pointed at the sky publishes the sky.
@(test)
the_framing_test_tells_the_road_from_the_void :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer delete(doc.ribbon)
	straight_road_doc(&doc)

	at_it := gfx.Camera3D{
		position = {100, 60, 140}, target = {100, 0, 0}, up = {0, 1, 0},
		fovy = 55, projection = .PERSPECTIVE,
	}
	testing.expect(
		t,
		thumbnail_framed(&doc, at_it) > THUMB_MIN_FRAMED,
		"a camera pointed at the road did not find it",
	)

	// Same place, turned to face away from the road.
	away := at_it
	away.target = {100, 0, 280}
	testing.expect_value(t, thumbnail_framed(&doc, away), f32(0))

	// In the right direction, but so far off that the road is past the far plane.
	far_off := gfx.Camera3D{
		position = {100, 0, CAM_FAR * 2}, target = {100, 0, 0}, up = {0, 1, 0},
		fovy = 55, projection = .PERSPECTIVE,
	}
	testing.expect_value(t, thumbnail_framed(&doc, far_off), f32(0))
}

// A venue with no road at all frames nothing, whatever the camera does. The
// render falls back rather than looping: there is nothing to fall back to.
@(test)
a_venue_with_no_road_frames_nothing :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	cam := gfx.Camera3D{position = {0, 10, 10}, target = {}, up = {0, 1, 0}, fovy = 55}
	testing.expect_value(t, thumbnail_framed(&doc, cam), f32(0))
}

// The fitted framing is the fallback, so it has to be the one that cannot miss.
@(test)
the_fitted_framing_always_has_the_road_in_it :: proc(t: ^testing.T) {
	doc := Venue_Doc{}
	defer delete(doc.ribbon)
	straight_road_doc(&doc)
	framed := thumbnail_framed(&doc, thumbnail_fitted_camera(&doc))
	testing.expectf(t, framed > 0.9, "the fitted camera only framed %.2f of the road", framed)
}

// One flat colour is a picture of nothing, whatever that colour turned out to
// be. A single pixel of anything else means the venue was drawn.
@(test)
a_picture_of_one_colour_is_a_picture_of_nothing :: proc(t: ^testing.T) {
	bare := make([]u8, 300, context.allocator)
	defer delete(bare)
	for i in 0 ..< 100 {
		bare[i * 3 + 0] = THUMB_BG[0]
		bare[i * 3 + 1] = THUMB_BG[1]
		bare[i * 3 + 2] = THUMB_BG[2]
	}
	testing.expect(t, thumbnail_is_blank(bare), "a flat frame did not read as empty")

	bare[297] = THUMB_BG[0] + 40
	testing.expect(t, !thumbnail_is_blank(bare), "a drawn pixel did not count")
}
