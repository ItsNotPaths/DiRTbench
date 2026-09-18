package main

// The prop browsers: what the base venue ships, what one looks like, and the
// mode that drops it in the world.
//
// Two sections of the Inspector, beside Terrain and Vegetation. One browser per
// `Prop_Role`, because an object and an ornament are placed for different
// reasons and get picked from different ends of the catalogue. They share the
// one parse: both list out of `Prop_Catalog.refs`, and the Objects section is
// that list filtered down to the meshes the venue can collide.
//
// Picking a prop happens in the filtered list and nowhere else; the thumbnail
// beside it only shows what is picked.
//
// That thumbnail is projected and painted by hand into the dock's ImGui draw
// list rather than rendered into a texture: the prop is a few thousand
// triangles of flat colour, so painting it is cheaper than the render target it
// would otherwise need, and it costs the renderer nothing.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import d3 "../d3"
import "../gfx"
import "../ui"

// How tall the list and the thumbnail are, in pixels. Both are as wide as the
// dock, and the dock scrolls, so these only decide how much of it they take.
PROP_LIST_H :: 170

PROP_PREVIEW_H :: 170

PROP_PREVIEW_SENS :: 0.01 // radians per pixel of drag

// One of the two browsers: what it has picked out of the catalogue, the text
// narrowing its list, and the thumbnail it is spinning.
//
// `pick` indexes the catalogue's own ref list rather than naming a prop,
// because the catalogue owns those strings and a reload frees them.
Prop_Browser :: struct {
	pick:    int,
	filter:  [64]u8,
	preview: Prop_Preview,
	yaw:     f32,
	pitch:   f32,
}

prop_browser_defaults :: proc() -> Prop_Browser {
	return {pick = -1, yaw = 0.7, pitch = 0.35}
}

// The catalogue entry one browser has selected, if any. A pick is dropped when
// the mesh under it can no longer take the role — a base venue change can turn
// an object's mesh into one this venue has no rigid body for.
prop_picked :: proc(ed: ^Editor, role: Prop_Role) -> (ref: Prop_Ref, ok: bool) {
	cat := &ed.doc.props_lib
	pick := ed.prop_browse[role].pick
	if cat.state != .Ready || pick < 0 || pick >= len(cat.refs) {
		return
	}
	ref = cat.refs[pick]
	return ref, prop_role_allowed(cat, ref, role)
}

// Whether a mesh may be placed in this role. Every mesh can be an ornament;
// only the ones the venue declares an entity type for can be an object.
prop_role_allowed :: proc(cat: ^Prop_Catalog, ref: Prop_Ref, role: Prop_Role) -> bool {
	return role == .Ornament || prop_has_body(cat, ref)
}

// How many placements carry this role. The two sections each report their own.
prop_role_count :: proc(doc: ^Venue_Doc, role: Prop_Role) -> (n: int) {
	for inst in doc.props {
		if inst.role == role {
			n += 1
		}
	}
	return
}

// The selected placement, or -1. Validates the index: a delete or a load can
// shrink the list under the selection.
selected_prop :: proc(ed: ^Editor) -> int {
	if ed.sel.kind == .Prop && ed.sel.idx >= 0 && ed.sel.idx < len(ed.doc.props) {
		return ed.sel.idx
	}
	return -1
}

// --- the Inspector section ------------------------------------------------------

// Objects first: a prop is more often placed to be hit than to be looked at,
// and the Objects list is the shorter of the two.
draw_props_sections :: proc(ed: ^Editor) {
	if !draw_prop_catalog_gate(ed) {
		return
	}
	draw_prop_role_section(ed, .Object)
	draw_prop_role_section(ed, .Ornament)
}

// The one block both sections would otherwise repeat: no base venue, or a
// catalogue that has not been parsed yet. True when there is art to browse.
draw_prop_catalog_gate :: proc(ed: ^Editor) -> bool {
	cat := &ed.doc.props_lib
	if cat.state == .Ready {
		return true
	}
	if !ui.igCollapsingHeader_TreeNodeFlags("Props", ui.IM_TREE_NODE_DEFAULT_OPEN) {
		return false
	}
	if ed.doc.base == "" {
		ui.im_text_colored(DIM_COL, "a loose road has no base venue to take props from")
		return false
	}
	ui.im_text(fmt.ctprintf("art from %s", ed.doc.base))
	if cat.state == .Failed {
		ui.im_text_colored(WARN_COL, fmt.ctprint(cat.msg))
	}
	if ui.im_button("Load prop library") {
		msg, ok := prop_catalog_load(ed.doc)
		set_status(&ed.status, ok ? "prop library loaded" : msg, ok)
	}
	return false
}

// One browser. Objects and ornaments differ only in which meshes the list holds
// and what the placement is for, so one proc draws both.
draw_prop_role_section :: proc(ed: ^Editor, role: Prop_Role) {
	if !ui.igCollapsingHeader_TreeNodeFlags(
		fmt.ctprint(PROP_ROLE_NAMES[role]), ui.IM_TREE_NODE_DEFAULT_OPEN,
	) {
		return
	}
	cat := &ed.doc.props_lib
	browser := &ed.prop_browse[role]

	listed := 0
	for ref in cat.refs {
		if prop_role_allowed(cat, ref, role) {
			listed += 1
		}
	}
	if role == .Object {
		ui.im_text_colored(DIM_COL, fmt.ctprintf(
			"%d of %s's %d meshes carry a rigid body", listed, ed.doc.base, len(cat.refs),
		))
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%d meshes from %s, drawn only", listed, ed.doc.base))
	}

	ui.igSetNextItemWidth(-1)
	ui.igInputText(
		fmt.ctprintf("###prop_filter_%v", role), raw_data(browser.filter[:]), len(browser.filter),
		ui.IM_INPUT_TEXT_NONE, nil, nil,
	)
	ui.im_text_colored(DIM_COL, "filter by name")

	draw_prop_list(ed, role)
	draw_prop_preview(ed, role)

	ref, have := prop_picked(ed, role)
	placing := prop_placing_role(ed) == role
	ui.igBeginDisabled(!have)
	if ui.im_button(fmt.ctprintf("%s###prop_place_%v", placing ? "Stop placing" : "Place", role)) {
		prop_set_placing(ed, role, !placing)
	}
	ui.igEndDisabled()
	ui.im_same_line()
	ui.im_text(fmt.ctprintf("%d placed", prop_role_count(ed.doc, role)))
	if placing && have {
		ui.im_text_colored(MINE_COL, fmt.ctprintf("click the ground to drop %s", ref.name))
		ui.im_text_colored(DIM_COL, "Esc or right-click stops")
	} else {
		ui.im_text_colored(DIM_COL, "pick one, then Place. B toggles it too.")
	}
}

// The filtered name list. Every match is listed — the largest stock library is
// under 200 props, so the scroll bar is enough and nothing is ever hidden.
//
// The ids carry the role, so the two lists do not share ImGui state.
draw_prop_list :: proc(ed: ^Editor, role: Prop_Role) {
	cat := &ed.doc.props_lib
	browser := &ed.prop_browse[role]
	filter := strings.to_lower(buf_text(browser.filter[:]), context.temp_allocator)
	if !ui.igBeginChild_Str(
		fmt.ctprintf("prop_list_%v", role), {0, PROP_LIST_H},
		ui.IM_CHILD_BORDERS, ui.IM_WINDOW_NONE,
	) {
		ui.igEndChild()
		return
	}
	shown := 0
	for ref, i in cat.refs {
		if !prop_role_allowed(cat, ref, role) {
			continue
		}
		if filter != "" &&
		   !strings.contains(strings.to_lower(ref.name, context.temp_allocator), filter) {
			continue
		}
		shown += 1
		label := fmt.ctprintf(
			"%s%s###prop%v%d", ref.name, ref.kind == .Trees_Pssg ? "  (tree)" : "", role, i,
		)
		if ui.igSelectable_Bool(label, i == browser.pick, ui.IM_SELECTABLE_NONE, {0, 0}) {
			browser.pick = i
		}
	}
	if shown == 0 {
		ui.im_text_colored(DIM_COL, "nothing matches")
	}
	ui.igEndChild()
}

// --- the thumbnail --------------------------------------------------------------

// One prop's triangles, ready to be spun in a panel. Model space, recentred on
// the box so a rotation turns the prop rather than swinging it around the
// origin, and scaled so the largest dimension is 1.
Prop_Preview :: struct {
	ref:   Prop_Ref,
	tris:  [dynamic][3]gfx.Vector3,
	// What the source mesh measured, for the caption. Metres, before recentring.
	size:  gfx.Vector3,
	count: int, // triangles in the source, before any thinning
}

// A preview is redrawn every frame and sorted by depth, so a 20,000-triangle
// building has to be thinned to keep that honest. Shape survives it; this is a
// thumbnail, not the viewport.
PROP_PREVIEW_TRIS :: 3000

prop_preview_build :: proc(doc: ^Venue_Doc, ref: Prop_Ref, out: ^Prop_Preview) {
	if out.ref == ref && len(out.tris) > 0 {
		return
	}
	prop_preview_clear(out)
	cat := &doc.props_lib
	if cat.state != .Ready {
		return
	}
	mesh, ok := d3.prop_lib_mesh(&cat.libs[ref.kind], ref.name, context.temp_allocator)
	if !ok {
		return
	}
	// Owns the name: the catalogue's copy dies on a reload.
	out.ref = {kind = ref.kind, name = strings.clone(ref.name)}
	out.size = {mesh.hi[0] - mesh.lo[0], mesh.hi[1] - mesh.lo[1], mesh.hi[2] - mesh.lo[2]}
	out.count = len(mesh.tris) / 3
	lo, hi := prop_preview_frame(mesh.pos)
	centre := (lo + hi) * 0.5
	span := max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	scale := span > 1e-6 ? 1 / span : 1
	step := max(1, (out.count + PROP_PREVIEW_TRIS - 1) / PROP_PREVIEW_TRIS)
	out.tris = make([dynamic][3]gfx.Vector3)
	for t := 0; t < out.count; t += step {
		i := t * 3
		verts: [3]gfx.Vector3
		for k in 0 ..< 3 {
			p := gfx.Vector3(mesh.pos[mesh.tris[i + k]])
			verts[k] = (p - centre) * scale
		}
		append(&out.tris, verts)
	}
}

// What to frame the preview on. Not the real box: stock meshes carry stray
// vertices — four of core_barr_haybale_e's 456 sit nine metres below the bale —
// and framing on those shrinks the prop to a dot. A percentile off each end of
// each axis drops them. The caption still reports the real bounds.
PROP_PREVIEW_TRIM :: 0.01

prop_preview_frame :: proc(pos: [][3]f32) -> (lo, hi: gfx.Vector3) {
	drop := int(f32(len(pos)) * PROP_PREVIEW_TRIM)
	axis := make([]f32, len(pos), context.temp_allocator)
	for k in 0 ..< 3 {
		for p, i in pos {
			axis[i] = p[k]
		}
		slice.sort(axis)
		lo[k] = axis[drop]
		hi[k] = axis[len(axis) - 1 - drop]
	}
	return
}

prop_preview_clear :: proc(out: ^Prop_Preview) {
	delete(out.ref.name)
	delete(out.tris)
	out^ = {}
}

// One preview triangle, projected and ready to fill: the screen positions, the
// shade its normal earns, and the depth it sorts on.
Prop_Preview_Face :: struct {
	p:     [3][2]f32,
	shade: f32,
	depth: f32,
}

// Spin the preview, project it into `size` pixels, and sort back to front.
// Orthographic on purpose: a thumbnail wants no perspective to read scale from.
// Temp-allocated, so the caller draws it in the same frame.
prop_preview_faces :: proc(
	preview: ^Prop_Preview, yaw, pitch: f32, size: [2]f32,
) -> []Prop_Preview_Face {
	faces := make([dynamic]Prop_Preview_Face, 0, len(preview.tris), context.temp_allocator)
	cy, sy := math.cos(yaw), math.sin(yaw)
	cp, sp := math.cos(pitch), math.sin(pitch)
	// A whole prop at scale 1 spans one unit; leave a margin round it.
	zoom := min(size.x, size.y) * 0.8
	light := gfx.Vector3Normalize(PROP_LIGHT)
	for tri in preview.tris {
		face: Prop_Preview_Face
		view: [3]gfx.Vector3
		for k in 0 ..< 3 {
			v := tri[k]
			x := v.x * cy + v.z * sy
			z := v.z * cy - v.x * sy
			y := v.y * cp - z * sp
			view[k] = {x, y, z * cp + v.y * sp}
			// Screen Y grows downward, so up in the model is up on screen.
			face.p[k] = {size.x * 0.5 + x * zoom, size.y * 0.5 - y * zoom}
			face.depth += view[k].z
		}
		n := gfx.Vector3Normalize(gfx.Vector3CrossProduct(view[1] - view[0], view[2] - view[0]))
		face.shade = prop_face_shade(n, light)
		append(&faces, face)
	}
	slice.sort_by(faces[:], proc(a, b: Prop_Preview_Face) -> bool { return a.depth < b.depth })
	return faces[:]
}

// A thumbnail of whatever the list has picked, spun by dragging. It selects
// nothing — the list is the only place a prop is chosen. Painted straight into
// the dock: the faces come back sorted back to front, so filling them in order
// is the whole of the hidden-surface handling.
draw_prop_preview :: proc(ed: ^Editor, role: Prop_Role) {
	browser := &ed.prop_browse[role]
	ref, have := prop_picked(ed, role)
	if !have {
		ui.im_text_colored(DIM_COL, "no prop picked")
		return
	}
	prop_preview_build(ed.doc, ref, &browser.preview)

	avail := ui.igGetContentRegionAvail()
	size := ui.Im_Vec2{avail.x, PROP_PREVIEW_H}
	at := ui.igGetCursorScreenPos()
	ui.igInvisibleButton(fmt.ctprintf("prop_preview_%v", role), size, ui.IM_BUTTON_NONE)
	if ui.igIsItemActive() {
		drag := gfx.GetMouseDelta()
		browser.yaw += drag.x * PROP_PREVIEW_SENS
		browser.pitch = clamp(browser.pitch + drag.y * PROP_PREVIEW_SENS, -1.5, 1.5)
	}

	list := ui.igGetWindowDrawList()
	far := ui.Im_Vec2{at.x + size.x, at.y + size.y}
	ui.ImDrawList_PushClipRect(list, at, far, true)
	ui.ImDrawList_AddRectFilled(list, at, far, ui.im_col32(22, 24, 30, 255), 0, 0)
	base := PROP_BASE_COLOUR[ref.kind]
	for face in prop_preview_faces(&browser.preview, browser.yaw, browser.pitch, {size.x, size.y}) {
		rgb := prop_shade_colour(base, face.shade)
		col := ui.im_col32(rgb[0], rgb[1], rgb[2], 255)
		p :: proc(at: ui.Im_Vec2, v: [2]f32) -> ui.Im_Vec2 {
			return {at.x + v[0], at.y + v[1]}
		}
		ui.ImDrawList_AddTriangleFilled(list, p(at, face.p[0]), p(at, face.p[1]), p(at, face.p[2]), col)
	}
	ui.ImDrawList_PopClipRect(list)

	pv := &browser.preview
	if len(pv.tris) == 0 {
		ui.im_text_colored(WARN_COL, "this prop has no drawable geometry")
		return
	}
	ui.im_text(fmt.ctprintf("%.1f x %.1f x %.1f m", pv.size.x, pv.size.y, pv.size.z))
	ui.im_same_line()
	shown := len(pv.tris)
	if shown < pv.count {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%d tris (preview shows %d)", pv.count, shown))
	} else {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%d tris", pv.count))
	}
	ui.im_text_colored(DIM_COL, "drag to spin")
}

// --- the selection block ---------------------------------------------------------

// One placed prop: what it is for, where it stands, how big, and the way out.
// Its rotation is the gizmo's, so there are no angle fields here.
draw_prop_selection :: proc(ed: ^Editor) {
	pi := selected_prop(ed)
	if pi < 0 {
		return
	}
	inst := &ed.doc.props[pi]
	ui.igSeparatorText(fmt.ctprintf("%s %d of %d", PROP_ROLE_NAMES[inst.role], pi, len(ed.doc.props)))
	ui.im_text(fmt.ctprint(inst.ref.name))
	if _, drawn := prop_drawable(ed.doc, inst.ref); !drawn {
		ui.im_text_colored(WARN_COL, fmt.ctprintf("%s does not ship this prop", ed.doc.base))
	}
	draw_prop_role_switch(ed, inst)
	if ui.igDragFloat3("position", cast(^[3]f32)&inst.pos, 0.1, 0, 0, "%.2f m", ui.IM_SLIDER_NONE) {
		mark_edited(ed.doc)
	}
	if ui.igSliderFloat("scale", &inst.scale, PROP_SCALE_MIN, PROP_SCALE_MAX, "%.2fx", ui.IM_SLIDER_NONE) {
		mark_edited(ed.doc)
	}
	if ui.im_button("Stand upright") {
		inst.rot = gfx.Quaternion(1)
		mark_edited(ed.doc)
	}
	ui.im_same_line()
	if ui.im_button("Delete prop") {
		prop_remove(ed.doc, pi)
		ed.sel = {}
	}
}

// Turning one placement from scenery into an obstacle, or back. Disabled toward
// Object when the venue declares no entity type for the mesh: without one there
// is nothing for an `objects.ens` body to point at, and the prop would export as
// scenery while claiming to collide.
draw_prop_role_switch :: proc(ed: ^Editor, inst: ^Prop_Instance) {
	cat := &ed.doc.props_lib
	for role in Prop_Role {
		if role != .Ornament {
			ui.im_same_line()
		}
		allowed := cat.state != .Ready || prop_role_allowed(cat, inst.ref, role)
		ui.igBeginDisabled(!allowed)
		if ui.igRadioButton_Bool(fmt.ctprint(PROP_ROLE_NAMES[role]), inst.role == role) &&
		   inst.role != role {
			inst.role = role
			mark_edited(ed.doc)
		}
		ui.igEndDisabled()
	}
	if cat.state == .Ready && !prop_has_body(cat, inst.ref) {
		ui.im_text_colored(DIM_COL, fmt.ctprintf("%s has no rigid body for this mesh", ed.doc.base))
	}
}
