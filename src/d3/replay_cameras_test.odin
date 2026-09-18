package d3

import "core:math"
import "core:strings"
import "core:testing"

@(private = "file")
test_line :: proc(n: int, allocator := context.temp_allocator) -> []Route_Station {
	out := make([]Route_Station, n, allocator)
	for i in 0 ..< n {
		z := f32(i)*10
		out[i] = {
			distance = z,
			centre   = {0, 3, z},
			left     = {-4, 3, z},
			right    = {4, 3, z},
		}
	}
	return out
}

// Camera forward is +Z, so the orientation must rotate +Z onto the aim.
@(test)
camera_orientation_aims_plus_z_at_the_target :: proc(t: ^testing.T) {
	for forward in ([][3]f32{{0,0,1}, {1,0,0}, {-1,0,0}, {0,0,-1}, {3,-1,7}, {-2,4,-5}}) {
		q := d3_camera_orientation(forward)
		// Rotate +Z by q, written out rather than reusing the helpers under test.
		x, y, z, w := q[0], q[1], q[2], q[3]
		got := [3]f32{2*(x*z + w*y), 2*(y*z - w*x), 1 - 2*(x*x + y*y)}
		n := math.sqrt(forward[0]*forward[0]+forward[1]*forward[1]+forward[2]*forward[2])
		want := [3]f32{forward[0]/n, forward[1]/n, forward[2]/n}
		for k in 0 ..< 3 {
			testing.expectf(t, abs(got[k]-want[k]) < 1e-4,
				"forward %v: axis %d aimed %f, wanted %f", forward, k, got[k], want[k])
		}
	}
}

// The cutscenes and the global sequences name these by rule, so they must
// exist whatever the montage count.
@(test)
camera_shots_always_emit_the_externally_named_idents :: proc(t: ^testing.T) {
	shots, msg, ok := d3_camera_shots(test_line(40), 3, 0)
	testing.expect(t, ok, msg); if !ok { return }
	have := make(map[string]bool, context.temp_allocator)
	for shot in shots { have[shot.ident] = true }
	for want in ([]string{
		"start_camera_r3", "splitfin_camera_r3", "initial_camera_r0",
		"finishlineCam_r3", "multifin_camera_r3", "establish_camera_r3",
		// The `_r0` aliases the base route's hardlinked cutscenes still name.
		"start_camera_r0", "splitfin_camera_r0", "initial_camera_r3",
	}) {
		testing.expectf(t, have[want], "missing camera %q", want)
	}
}

@(test)
camera_shots_place_every_montage_shot_on_the_road :: proc(t: ^testing.T) {
	line := test_line(40)
	total := line[len(line)-1].distance
	shots, msg, ok := d3_camera_shots(line, 0, 6)
	testing.expect(t, ok, msg); if !ok { return }
	montage := 0
	for shot in shots {
		if len(shot.ident) < 5 || shot.ident[:5] != "mont_" { continue }
		montage += 1
		// The aim rides the centre line, so it stays on the route's own span.
		testing.expectf(t, shot.aim[2] >= -1 && shot.aim[2] <= total+1,
			"%s aims off the route at z %f", shot.ident, shot.aim[2])
		// And the dolly actually travels.
		testing.expect(t, d3_dist(shot.eye, shot.eye_end) > 1, "a dolly that does not move")
		testing.expect(t, shot.eye[1] > shot.aim[1], "a montage camera below what it looks at")
	}
	testing.expect_value(t, montage, 6)
}

// Same road in, same cameras out: an export must not reshuffle the intro.
@(test)
camera_shots_are_deterministic :: proc(t: ^testing.T) {
	a, _, ok_a := d3_camera_shots(test_line(40), 0, 5, context.temp_allocator)
	b, _, ok_b := d3_camera_shots(test_line(40), 0, 5, context.temp_allocator)
	testing.expect(t, ok_a && ok_b); if !(ok_a && ok_b) { return }
	testing.expect_value(t, len(a), len(b))
	for shot, i in a {
		testing.expect_value(t, shot.ident, b[i].ident)
		testing.expect_value(t, shot.eye, b[i].eye)
	}
}

// More montage shots must mean a bigger file, and a route too short to place
// anything on must refuse rather than emit a degenerate config.
@(test)
replay_config_encodes_every_shot :: proc(t: ^testing.T) {
	few, msg, ok := d3_replay_camera_config(test_line(40), 0, 2, context.temp_allocator)
	testing.expect(t, ok, msg); if !ok { return }
	many, many_msg, many_ok := d3_replay_camera_config(test_line(40), 0, 8, context.temp_allocator)
	testing.expect(t, many_ok, many_msg); if !many_ok { return }
	testing.expect(t, len(many) > len(few), "six more cameras did not grow the file")

	_, _, built := d3_replay_camera_config(test_line(1), 0, 4, context.temp_allocator)
	testing.expect(t, !built, "a one-station route must refuse")
}

// Every copied element is stock's, whole. The counts are stock's, exactly, and
// a camera naming a spline the table leaves out would draw nothing.
@(test)
stock_elements_are_copied_whole :: proc(t: ^testing.T) {
	want := []struct{ident: string, children: int}{
		{"dynamic_camera_rig",      42},
		{"camera_dyn_-1",           50},
		{"camera_dyn_+1",           50},
		{"relative_service_camera", 50}, // 49 Parameter plus a DynamicRoll
		{"finish_camera",           49},
		{"one2watch_camera",        41},
		{"one2watch_camera_RAM",    41},
	}
	copied := d3_stock_elements(context.temp_allocator)
	paths := make(map[string]bool, context.temp_allocator)
	for node in copied {
		if node.name != "Path" { continue }
		for attr in node.attrs { if attr.name == "ident" { paths[attr.value] = true } }
	}
	seen := 0
	for node in copied {
		if node.name != "Camera" { continue }
		ident, source := "", ""
		for attr in node.attrs {
			switch attr.name {
			case "ident":      ident = attr.value
			case "sourcePath": source = attr.value
			}
		}
		// The rig cameras carry an empty one: they are placed by the rig and
		// by `linePointOffset`, not by a spline.
		testing.expectf(t, source == "" || paths[source],
			"%s rides %q, which is not copied", ident, source)
		children, is_stock := 0, false
		for candidate in want {
			if candidate.ident == ident { children, is_stock = candidate.children, true }
		}
		testing.expectf(t, is_stock, "unexpected camera %q", ident)
		if !is_stock { continue }
		seen += 1
		testing.expectf(t, len(node.children) == children,
			"%s has %d children, stock has %d", ident, len(node.children), children)
	}
	testing.expect_value(t, seen, len(want))
	testing.expect_value(t, seen, D3_STOCK_CAMERAS)
}

// `pathRelativeToTarget` tells the game these four sit metres from a subject.
// Without it the service-area shot is read as world space and lands at the
// venue origin.
@(test)
stock_relative_cameras_declare_themselves_relative :: proc(t: ^testing.T) {
	relative := []string{
		"relative_service_camera", "finish_camera",
		"one2watch_camera", "one2watch_camera_RAM",
	}
	copied := d3_stock_elements(context.temp_allocator)
	for want in relative {
		found := false
		for node in copied {
			if node.name != "Camera" { continue }
			is_wanted := false
			for attr in node.attrs { if attr.name == "ident" && attr.value == want { is_wanted = true } }
			if !is_wanted { continue }
			for child in node.children {
				for attr in child.attrs {
					// stock spells it `pathRelativeTotarget` on the one2watch pair
					if attr.name == "name" && strings.equal_fold(attr.value, "pathRelativeToTarget") {
						found = true
					}
				}
			}
		}
		testing.expectf(t, found, "%s is missing pathRelativeToTarget", want)
	}
}

// The terminal-damage flow fires `SwitchToDynamicCameraRig`. That finds the
// camera flagged `assignedToDynamicCameraRig`, and the rig element beside it is
// what places the camera, so one without the other is no crash camera at all.
@(test)
stock_crash_camera_ships_with_its_rig :: proc(t: ^testing.T) {
	rigs, assigned, placeholders, transitions := 0, 0, 0, 0
	for node in d3_stock_elements(context.temp_allocator) {
		if node.name == "DynamicCameraRig" {
			rigs += 1
			for child in node.children {
				switch child.name {
				case "PlaceHolder": placeholders += 1
				case "Transition":  transitions += 1
				}
			}
		}
		for attr in node.attrs {
			if attr.name == "assignedToDynamicCameraRig" && attr.value == "true" { assigned += 1 }
		}
	}
	testing.expect_value(t, rigs, 1)
	testing.expect_value(t, assigned, 1)
	testing.expect_value(t, placeholders, 10)
	testing.expect_value(t, transitions, 10)
}
