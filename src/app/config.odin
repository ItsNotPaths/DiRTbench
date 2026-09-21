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

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CONF_NAME :: "dirtbench.conf"

// The file first run emits. Baked into the binary so a release is one file, and
// commented rather than empty so the grammar is beside the keys.
CONF_TEMPLATE :: #load("../../assets/dirtbench.conf.default")

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

// `dirtbench.conf` in the platform's config directory, falling back to the
// current directory so a tool run out of a checkout still finds one.
conf_path :: proc(allocator := context.temp_allocator) -> string {
	settled, _ := filepath.join({config_root(context.temp_allocator), CONF_NAME}, allocator)
	if os.exists(settled) {
		return settled
	}
	return strings.clone(CONF_NAME, allocator)
}

// First run: the template in the config directory, so the file every message
// names exists. Nothing of ours is there yet, so the directory comes first. An
// existing config is left exactly as it is.
conf_ensure :: proc(allocator := context.temp_allocator) -> (path: string, made: bool) {
	path = conf_write_path(allocator)
	if os.exists(path) {
		return path, false
	}
	dir := filepath.dir(path)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return path, false
	}
	return path, os.write_entire_file(path, CONF_TEMPLATE) == nil
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

// Where a write goes: the file `conf_get` reads when there is one, and the
// config directory when there is not. Never the bare fallback name, which would
// drop a second config into whatever directory the tool was started from.
@(private = "file")
conf_write_path :: proc(allocator := context.temp_allocator) -> string {
	existing := conf_path(context.temp_allocator)
	if os.exists(existing) {
		return strings.clone(existing, allocator)
	}
	joined, _ := filepath.join({config_root(context.temp_allocator), CONF_NAME}, allocator)
	return joined
}

// Write one key, leaving every other line exactly as it was.
//
// Read, replace, write: a config is hand-edited and full of comments, and a
// rewrite from parsed keys alone would throw all of that away the first time
// the tool remembered a username. A key that is not there yet is appended.
conf_set :: proc(key, val: string) -> (msg: string, ok: bool) {
	path := conf_write_path()
	data, _ := os.read_entire_file(path, context.temp_allocator)
	out := conf_apply(string(data), key, val, context.temp_allocator)
	if err := os.write_entire_file(path, transmute([]u8)out); err != nil {
		return fmt.tprintf("could not write %s: %v", path, err), false
	}
	return "", true
}

// Forget one key. The line goes and nothing else moves; a key that was not
// there is not an error.
conf_unset :: proc(key: string) -> (msg: string, ok: bool) {
	path := conf_write_path()
	data, _ := os.read_entire_file(path, context.temp_allocator)
	out := conf_apply(string(data), key, "", context.temp_allocator, remove = true)
	if err := os.write_entire_file(path, transmute([]u8)out); err != nil {
		return fmt.tprintf("could not write %s: %v", path, err), false
	}
	return "", true
}

// `text` with `key` set to `val`, or with `key` gone when `remove` is set: the
// line replaced where it stands, appended when there is none, and every other
// line — comments, blanks, order — left exactly as it was found. A file that
// holds the same key twice comes back holding it once.
conf_apply :: proc(
	text, key, val: string, allocator := context.temp_allocator, remove := false,
) -> string {
	b := strings.builder_make(allocator)
	written := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		eq := strings.index_byte(trimmed, '=')
		is_key := eq > 0 && !strings.has_prefix(trimmed, "#") &&
			strings.trim_space(trimmed[:eq]) == key
		if is_key {
			if !written && !remove {
				fmt.sbprintf(&b, "%s = %s\n", key, val)
				written = true
			}
			continue
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if !written && !remove {
		fmt.sbprintf(&b, "%s = %s\n", key, val)
	}
	return strings.to_string(b)
}
