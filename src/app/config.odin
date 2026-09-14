package main

// `dirtbench.conf`: the tool's machine-local settings, and the `key = value`
// grammar they are written in.
//
// One file, not one per export target. What it holds is where the game is, and
// anything else that differs per machine; a game install path often sits inside
// a Proton prefix, so none of it is ever committed.
//
// Rules, all of them:
//
//   - one entry per line, split on the **first** `=`
//   - `#` starts a comment line; blank lines are skipped
//   - key and value are trimmed of surrounding space
//   - a value runs to the end of the line, so it may contain spaces and further
//     `=` signs, and must not be quoted. Install paths need this: the game's own
//     directory is "DiRT 3 Complete Edition".
//
// Deliberately not JSON or TOML. These files are hand-edited, hold a handful of
// paths, and a parser you can hold in your head is worth more here than a format
// with an escaping story.

import "core:os"
import "core:path/filepath"
import "core:strings"

CONF_NAME :: "dirtbench.conf"

// A line with no `=` comes back as the whole line in `key` with an empty `val`.
// Callers reject that as a malformed entry rather than guessing at it.
Config_Iter :: struct {
	rest: string,
}

config_next :: proc(it: ^Config_Iter) -> (key, val: string, ok: bool) {
	for line in strings.split_lines_iterator(&it.rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {
			return trimmed, "", true
		}
		return strings.trim_space(trimmed[:eq]), strings.trim_space(trimmed[eq + 1:]), true
	}
	return "", "", false
}

// `dirtbench.conf` beside the executable, falling back to the current directory
// so a tool run out of a checkout still finds one.
conf_path :: proc(allocator := context.temp_allocator) -> string {
	beside, _ := filepath.join({exe_dir(), CONF_NAME}, allocator)
	if os.exists(beside) {
		return beside
	}
	return strings.clone(CONF_NAME, allocator)
}

// One key out of the config. Absent file and absent key are the same answer.
conf_get :: proc(key: string, allocator := context.temp_allocator) -> (val: string, ok: bool) {
	data, err := os.read_entire_file(conf_path(), context.temp_allocator)
	if err != nil {
		return
	}
	it := Config_Iter{string(data)}
	for k, v in config_next(&it) {
		if k == key {
			return strings.clone(v, allocator), true
		}
	}
	return
}
