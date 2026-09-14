package d3

import "core:bytes"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
atomic_write_replaces_a_hardlink_without_touching_its_source :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "dirtbench-atomic-*", context.temp_allocator)
	testing.expectf(t, err == nil, "could not create test directory: %v", err)
	defer os.remove_all(dir)

	source, _ := filepath.join({dir, "source"}, context.temp_allocator)
	target, _ := filepath.join({dir, "target"}, context.temp_allocator)
	original := [5]u8{'s', 't', 'o', 'c', 'k'}
	replacement := [6]u8{'c', 'u', 's', 't', 'o', 'm'}
	testing.expectf(
		t,
		os.write_entire_file(source, original[:]) == nil,
		"could not write source fixture",
	)
	testing.expectf(t, os.link(source, target) == nil, "could not create hardlink fixture")

	msg, ok := atomic_write_file(target, replacement[:])
	testing.expectf(t, ok, "atomic write failed: %s", msg)
	source_data, source_err := os.read_entire_file(source, context.temp_allocator)
	target_data, target_err := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, source_err == nil && target_err == nil)
	testing.expect(t, bytes.equal(source_data, original[:]))
	testing.expect(t, bytes.equal(target_data, replacement[:]))

	source_info, source_stat_err := os.stat(source, context.temp_allocator)
	target_info, target_stat_err := os.stat(target, context.temp_allocator)
	testing.expect(t, source_stat_err == nil && target_stat_err == nil)
	testing.expect(t, !os.same_file(source_info, target_info))
}
