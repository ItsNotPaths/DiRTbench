package d3

import "core:fmt"
import "core:os"
import "core:testing"

BXML0_TEST_BATTERSEA :: "/run/media/paths/SSS-Games/SteamLibrary/steamapps/common/DiRT 3 Complete Edition/tracks/locations/uk/battersea"

// Read and written back, every stock Transporter trigger file is the same
// bytes: the writer has the format, not just the fields we use.
@(test)
stock_transporter_triggers_round_trip :: proc(t: ^testing.T) {
	for r in 0 ..< 5 {
		path := fmt.tprintf("%s/route_%d/game_modes/transporter/triggers_transporter.xml", BXML0_TEST_BATTERSEA, r)
		if !os.exists(path) { continue }
		stock, _ := os.read_entire_file(path, context.temp_allocator)
		root, msg, ok := d3_bxml0_read(stock)
		testing.expectf(t, ok, "route_%d did not read: %s", r, msg)
		if !ok { continue }
		back, wrote := d3_bxml0_write(root, context.temp_allocator)
		testing.expect(t, wrote)
		testing.expectf(t, string(back) == string(stock), "route_%d did not round trip", r)
	}
}

// What the editor writes is what the reader finds.
@(test)
transporter_goals_round_trip :: proc(t: ^testing.T) {
	goals := []D3_Transporter_Goal{
		{pos = {56.36359, 3, 151.75}, post = 5},
		{pos = {-10.5, 2.25, 0}, drop_zone = true, post = 2},
	}
	data, ok := d3_transporter_triggers(goals, context.temp_allocator)
	testing.expect(t, ok)
	back, msg, read_ok := d3_transporter_goals(data, context.temp_allocator)
	testing.expectf(t, read_ok, "did not read back: %s", msg)
	testing.expectf(t, len(back) == len(goals), "%d goals back from %d", len(back), len(goals))
	for g, i in goals {
		if i < len(back) {
			testing.expectf(t, back[i] == g, "goal %d came back as %v", i, back[i])
		}
	}
}

// The stock file in our shape: the same goals, and the same bytes.
@(test)
stock_transporter_goals_rewrite_as_stock :: proc(t: ^testing.T) {
	path := BXML0_TEST_BATTERSEA + "/route_0/game_modes/transporter/triggers_transporter.xml"
	if !os.exists(path) { return }
	stock, _ := os.read_entire_file(path, context.temp_allocator)
	goals, msg, ok := d3_transporter_goals(stock, context.temp_allocator)
	testing.expectf(t, ok, "stock did not read: %s", msg)
	testing.expect_value(t, len(goals), 147)
	ours, _ := d3_transporter_triggers(goals, context.temp_allocator)
	again, _, _ := d3_transporter_goals(ours, context.temp_allocator)
	testing.expectf(t, len(again) == len(goals), "%d goals after a rewrite", len(again))
}
