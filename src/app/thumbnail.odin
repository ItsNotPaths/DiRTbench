package main

// The venue's picture, rendered on demand.
//
// Nothing stores an image. The document carries the camera it was framed with
// (Venue_Shot) and the picture is made from that at the moment it is wanted, so
// a thumbnail can never disagree with the road it is a thumbnail of.
//
// It is drawn with no window in front of it: gfx.Capture puts the scene into a
// texture of a fixed size, which is both how the pixels can be read back at all
// (a swapchain is write-only) and how the shot stops depending on how large the
// user happens to have dragged a window.
//
// Square, because the site shows it square: the venue page's hero is 256x256
// and crops anything else. Rendered at twice that and averaged down, because a
// single sample per pixel makes a fence line crawl.

import "core:bytes"
import "core:image"
import "core:image/bmp"
import "core:math"
import "../gfx"

THUMB_PX :: 256

// Supersampling factor. The render is THUMB_PX * this on a side.
THUMB_SS :: 2

// How far back the fitted framing stands off the road it is framing.
THUMB_FIT :: 2.4

// The background a thumbnail is cleared to. Shared with the coverage test
// below, which is the whole reason it is a constant: what counts as an empty
// picture is "the colour nothing was drawn over".
THUMB_BG :: gfx.Color{26, 28, 34, 255}

// The least of the road a saved view may have in front of it and still be used.
// One point in twenty is a road leaving the frame, not a camera pointed away
// from it; nothing at all is a picture of the sky.
THUMB_MIN_FRAMED :: 0.05

// How many road points the framing test looks at. Enough to be representative
// of a long stage, few enough to cost nothing.
THUMB_SAMPLES :: 256

// The view a thumbnail is taken from. A saved shot is position and angle, so
// the target is put one metre down the view direction: distance is the orbit
// rig's business and says nothing about what the camera sees.
thumbnail_camera :: proc(shot: Venue_Shot, doc: ^Venue_Doc) -> gfx.Camera3D {
	if !shot.set {
		return thumbnail_fitted_camera(doc)
	}
	cp := math.cos(shot.pitch)
	offset := gfx.Vector3{
		math.sin(shot.yaw) * cp,
		math.sin(shot.pitch),
		math.cos(shot.yaw) * cp,
	}
	return gfx.Camera3D{
		position   = shot.pos,
		target     = shot.pos - offset,
		up         = {0, 1, 0},
		fovy       = 55,
		projection = .PERSPECTIVE,
	}
}

// The framing that cannot miss: stand off the whole road at the angle a new
// window opens at. What an unframed venue gets, and what a saved view that
// turned out to be pointed at nothing falls back to.
thumbnail_fitted_camera :: proc(doc: ^Venue_Doc) -> gfx.Camera3D {
	centre, radius := road_bounds(doc)
	return to_camera3d(
		Orbit_Camera{
			target   = centre,
			distance = clamp(radius * THUMB_FIT, CAM_DIST_MIN, CAM_DIST_MAX),
			yaw      = 0.6,
			pitch    = 0.6,
		},
	)
}

// How much of the road this camera has in front of it, as a fraction of the
// points looked at. Zero is a camera facing away from the venue, or standing so
// far off that the road is past the far plane.
//
// The thumbnail is square, so the aspect is 1 and this answers for the picture
// that will actually be taken rather than for the window the camera came from.
thumbnail_framed :: proc(doc: ^Venue_Doc, cam: gfx.Camera3D) -> f32 {
	total, inside := 0, 0
	vp := gfx.MatrixPerspective(cam.fovy * gfx.DEG2RAD, 1, CAM_NEAR, CAM_FAR) *
		gfx.GetCameraMatrix(cam)
	seen :: proc(vp: gfx.Matrix, p: gfx.Vector3) -> bool {
		clip := vp * [4]f32{p.x, p.y, p.z, 1}
		// w is -z in this projection, so a point behind the camera has w <= 0
		// and no amount of dividing makes it visible.
		if clip.w <= 0 {
			return false
		}
		ndc := [3]f32{clip.x, clip.y, clip.z} / clip.w
		return abs(ndc.x) <= 1 && abs(ndc.y) <= 1 && ndc.z >= 0 && ndc.z <= 1
	}
	for p in road_sample_points(doc) {
		total += 1
		if seen(vp, p) {
			inside += 1
		}
	}
	if total == 0 {
		return 0
	}
	return f32(inside) / f32(total)
}

// Up to THUMB_SAMPLES points spread along the road: the ribbon that is drawn,
// or the control points when no ribbon has been built.
@(private = "file")
road_sample_points :: proc(doc: ^Venue_Doc, allocator := context.temp_allocator) -> []gfx.Vector3 {
	count := len(doc.ribbon) > 0 ? len(doc.ribbon) : len(doc.spline.points)
	if count == 0 {
		return nil
	}
	step := max(1, count / THUMB_SAMPLES)
	out := make([dynamic]gfx.Vector3, 0, count / step + 1, allocator)
	for i := 0; i < count; i += step {
		if len(doc.ribbon) > 0 {
			append(&out, doc.ribbon[i].pos)
		} else {
			append(&out, doc.spline.points[i].xform.translation)
		}
	}
	return out[:]
}

// Whether nothing at all was drawn: every pixel the same colour, which is the
// clear and only the clear. A road hidden behind a ridge, or past the far
// plane, passes the framing test above and still comes back like this, so the
// rendered pixels get the last word.
//
// Against the picture's own first pixel rather than against THUMB_BG, so a
// swapchain that stores its colours in sRGB does not read as a full frame.
thumbnail_is_blank :: proc(rgb: []u8) -> bool {
	n := len(rgb) / 3
	if n == 0 {
		return true
	}
	bg := [3]u8{rgb[0], rgb[1], rgb[2]}
	for i in 1 ..< n {
		if rgb[i * 3 + 0] != bg[0] || rgb[i * 3 + 1] != bg[1] || rgb[i * 3 + 2] != bg[2] {
			return false
		}
	}
	return true
}

// The road's middle and the radius of the sphere around it. Off the ribbon,
// which is what is actually drawn; off the control points when there is no
// ribbon yet, which is a venue nobody has built a road in.
@(private = "file")
road_bounds :: proc(doc: ^Venue_Doc) -> (centre: gfx.Vector3, radius: f32) {
	lo := gfx.Vector3{max(f32), max(f32), max(f32)}
	hi := gfx.Vector3{min(f32), min(f32), min(f32)}
	seen := 0
	grow :: proc(lo, hi: ^gfx.Vector3, p: gfx.Vector3) {
		lo^ = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
		hi^ = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
	}
	for cs in doc.ribbon {
		grow(&lo, &hi, cs.pos)
		seen += 1
	}
	if seen == 0 {
		for p in doc.spline.points {
			grow(&lo, &hi, p.xform.translation)
			seen += 1
		}
	}
	if seen == 0 {
		return {0, 0, 0}, CAM_DIST_MIN
	}
	centre = (lo + hi) * 0.5
	radius = max(gfx.Vector3Length(hi - lo) * 0.5, 1)
	return
}

// The venue alone: no grid, no handles, no gizmo, nothing that belongs to
// editing rather than to the venue. Drawn into a capture surface, so there is
// no window and no Editor to ask.
draw_thumbnail_scene :: proc(doc: ^Venue_Doc, cam3d: gfx.Camera3D) {
	gfx.ClearBackground(THUMB_BG)
	gfx.BeginMode3D(cam3d)
	draw_world(doc, false)
	gfx.EndMode3D()
}

// Render `p`'s thumbnail and write it to `path` as a BMP.
//
// BMP because it needs no compressor: the file is a scratch upload the server
// re-encodes to WebP the moment it arrives, so the only thing that matters is
// that it is written without a dependency and read without a guess.
thumbnail_render :: proc(app: ^App, p: ^Venue, path: string) -> (fitted: bool, msg: string, ok: bool) {
	doc, doc_msg, doc_ok := venue_doc_open(app, p)
	if !doc_ok {
		return false, doc_msg, false
	}
	// A no-op while a window holds this document, and the whole cleanup when
	// this call is what loaded it.
	defer venue_doc_release(app, doc)
	// Land whatever is in flight, dispatch what is still stale, wait that out
	// too. Through the worker rather than rebuild_geometry: the synchronous
	// path builds no vegetation, and the thumbnail needs the trees.
	rebuild_join(doc)
	if rebuild_tick(doc, false, false) {
		// Same rule as docs_rebuild: no open window's node index survives a
		// renumbering, and this dispatch can cause one.
		clear_node_selections(app, doc)
	}
	rebuild_join(doc)

	side := i32(THUMB_PX * THUMB_SS)
	cap: gfx.Capture
	if !gfx.CaptureOpen(&cap, side, side) {
		return false, "could not make a surface to render the thumbnail into", false
	}
	defer gfx.CaptureClose(&cap)

	// A saved view is only used if the venue is in it. Two tests, because they
	// catch different failures: the first asks whether the road is in front of
	// the camera at all, and the second asks whether anything actually came out.
	cam := thumbnail_camera(doc.shot, doc)
	fitted = !doc.shot.set
	if !fitted && thumbnail_framed(doc, cam) < THUMB_MIN_FRAMED {
		cam, fitted = thumbnail_fitted_camera(doc), true
	}
	rgb, render_msg, rendered := thumbnail_pixels(&cap, doc, cam, side)
	if !rendered {
		return fitted, render_msg, false
	}
	if !fitted && thumbnail_is_blank(rgb) {
		fitted = true
		rgb, render_msg, rendered = thumbnail_pixels(&cap, doc, thumbnail_fitted_camera(doc), side)
		if !rendered {
			return fitted, render_msg, false
		}
	}
	write_msg, wrote := thumbnail_write(path, box_downscale(rgb, int(side), int(side), THUMB_SS))
	return fitted, write_msg, wrote
}

// One render into `cap`, as three bytes per pixel. Temp-allocated: a second
// call replaces the first, which is exactly what the fallback wants.
@(private = "file")
thumbnail_pixels :: proc(
	cap: ^gfx.Capture, doc: ^Venue_Doc, cam: gfx.Camera3D, side: i32,
) -> (
	rgb: []u8, msg: string, ok: bool,
) {
	if !gfx.CaptureBegin(cap) {
		return nil, "could not start the thumbnail render", false
	}
	draw_thumbnail_scene(doc, cam)
	raw := make([]u8, int(side) * int(side) * 4, context.temp_allocator)
	if !gfx.CaptureEnd(cap, raw) {
		return nil, "the thumbnail render did not come back", false
	}
	rgb = make([]u8, int(side) * int(side) * 3, context.temp_allocator)
	gfx.CaptureToRGB(cap, raw, rgb)
	return rgb, "", true
}

// Average each SSxSS block down to one pixel. Three channels, no gamma: the
// scene is written to an unorm target and read straight back, so the numbers
// here are the numbers that were drawn.
@(private = "file")
box_downscale :: proc(src: []u8, w, h, factor: int, allocator := context.temp_allocator) -> [dynamic]u8 {
	ow, oh := w / factor, h / factor
	out := make([dynamic]u8, ow * oh * 3, allocator)
	n := factor * factor
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			sums: [3]int
			for sy in 0 ..< factor {
				row := (y * factor + sy) * w
				for sx in 0 ..< factor {
					at := (row + x * factor + sx) * 3
					sums[0] += int(src[at + 0])
					sums[1] += int(src[at + 1])
					sums[2] += int(src[at + 2])
				}
			}
			at := (y * ow + x) * 3
			out[at + 0] = u8(sums[0] / n)
			out[at + 1] = u8(sums[1] / n)
			out[at + 2] = u8(sums[2] / n)
		}
	}
	return out
}

@(private = "file")
thumbnail_write :: proc(path: string, pixels: [dynamic]u8) -> (msg: string, ok: bool) {
	img := image.Image{
		width    = THUMB_PX,
		height   = THUMB_PX,
		channels = 3,
		depth    = 8,
		pixels   = bytes.Buffer{buf = pixels},
	}
	if err := bmp.save_to_file(path, &img); err != nil {
		return "could not write the thumbnail", false
	}
	return "", true
}
