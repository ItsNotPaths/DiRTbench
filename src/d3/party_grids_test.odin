package d3

import "core:math"
import "core:os"
import "core:testing"

PARTY_GRID :: "/run/media/paths/SSS-Games/SteamLibrary/steamapps/common/DiRT 3 Complete Edition/tracks/locations/uk/battersea/route_0/game_modes/outbreak/grids.pssg"

// A start set is a start read back, and nothing else in the file moves: the
// service and compound groups are stock's.
@(test)
a_party_start_moves_only_the_start_ring :: proc(t: ^testing.T) {
	if !os.exists(PARTY_GRID) { return }
	stock, err := os.read_entire_file(PARTY_GRID, context.temp_allocator)
	testing.expect(t, err == nil)
	parent :: "grid_start_outbreak_0"
	pos, yaw, msg, ok := d3_party_start(stock, parent)
	testing.expectf(t, ok, "no stock start: %s", msg)

	want := pos + {40, -2, -25}
	moved, set_msg, set_ok := d3_party_start_set(stock, parent, want, yaw + 1, context.temp_allocator)
	testing.expectf(t, set_ok, "the start did not set: %s", set_msg)
	got, got_yaw, _, _ := d3_party_start(moved, parent)
	for k in 0 ..< 3 {
		testing.expectf(t, abs(got[k] - want[k]) < 1e-3, "the ring centre moved to %v, not %v", got, want)
	}
	testing.expectf(t, abs(math.angle_diff(got_yaw, yaw + 1)) < 1e-4, "the heading read back as %f", got_yaw)

	a, _, _ := pssg_read(stock, context.temp_allocator)
	b, _, _ := pssg_read(moved, context.temp_allocator)
	changed := 0
	walk :: proc(x, y: ^Pssg_Node, changed: ^int) {
		if string(x.data) != string(y.data) {
			changed^ += 1
		}
		for child, i in x.children {
			walk(child, y.children[i], changed)
		}
	}
	walk(a.root, b.root, &changed)
	testing.expectf(t, changed == 1, "%d payloads changed; only the start parent's transform should", changed)
}
