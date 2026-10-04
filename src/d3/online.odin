package d3

// Modded online play. Two things stand between a deployed venue and an online
// race: the checksum manager (network/csconfig.xml, network/csdata.xml) and the
// online playlist (network/server_file.xml). All three live in win_000.nfs; see
// package nefs. Proven by hand with opencodies/tools/_d3_csblank.py and
// _d3_netrace.py; map in opencodies/docs/checksums.md.

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../nefs"

NEFS_ARCHIVE :: "win_000.nfs"

// The copy of stock database.bin taken before the first deploy.
STOCK_DATABASE_SUFFIXES := [?]string{".dirtbench-stock", ".rallysculpt-stock"}

// Empty csconfig.xml's <file> list and csdata.xml's <section> strings, so no
// file is checksummed and every player reports the same (valid, 0).
online_checksums_blank :: proc(root: string) -> (msg: string, ok: bool) {
	path, _ := filepath.join({root, NEFS_ARCHIVE}, context.temp_allocator)
	a, open_msg, opened := open_archive(path)
	if !opened {
		return open_msg, false
	}
	defer nefs.close(&a)

	config, _ := nefs.read(&a, "csconfig.xml", context.temp_allocator)
	files, blanked := blank_config(config)
	if !blanked {
		return "csconfig.xml has no <csmanagerinfo> list", false
	}
	if msg, ok = nefs.write(&a, "csconfig.xml", config, xml_spares(config)); !ok {
		return
	}

	data, _ := nefs.read(&a, "csdata.xml", context.temp_allocator)
	spares, sections, parsed := blank_sections(data)
	if !parsed {
		return "csdata.xml is not the BinXML layout we know", false
	}
	if msg, ok = nefs.write(&a, "csdata.xml", data, spares); !ok {
		return
	}
	if msg, ok = save_archive(path, a.raw); !ok {
		return
	}
	return fmt.tprintf("checksums blanked: %d csconfig files, %d csdata sections", files, sections), true
}

// Mirror every deployed venue into server_file.xml: a copy of its base route's
// <track> under each race type that lists the base, with the venue's routes.
// Rebuilt from stock each time, so a revert drops what it added.
online_server_file_sync :: proc(root: string) -> (msg: string, ok: bool) {
	path, _ := filepath.join({root, NEFS_ARCHIVE}, context.temp_allocator)
	stock_path := d3_stock_path(root, NEFS_ARCHIVE)
	if stock_path == "" {
		return fmt.tprintf("no %s in %s", NEFS_ARCHIVE, root), false
	}
	stock, stock_msg, stock_ok := open_archive(stock_path)
	if !stock_ok {
		return stock_msg, false
	}
	defer nefs.close(&stock)
	stock_text, _ := nefs.read(&stock, "server_file.xml", context.temp_allocator)

	database_path, _ := filepath.join({root, "database/database.bin"}, context.temp_allocator)
	_, db, db_msg, db_ok := load_registration_database(database_path)
	if !db_ok {
		return db_msg, false
	}
	stages: []Online_Stage
	for suffix in STOCK_DATABASE_SUFFIXES {
		if backup := fmt.tprintf("%s%s", database_path, suffix); os.exists(backup) {
			_, stock_db, stock_db_msg, stock_db_ok := load_registration_database(backup)
			if !stock_db_ok {
				return stock_db_msg, false
			}
			stages = online_stages(&db, &stock_db)
			break
		}
	}
	if len(stages) == 0 && stock_path == path {
		return "", true
	}

	text, built := server_file_with(string(stock_text), stages)
	if !built {
		return "server_file.xml has too little whitespace for the deployed venues", false
	}
	a, open_msg, opened := open_archive(path)
	if !opened {
		return open_msg, false
	}
	defer nefs.close(&a)
	data := transmute([]u8)text
	if msg, ok = nefs.write(&a, "server_file.xml", data, xml_spares(data)); !ok {
		return
	}
	if msg, ok = save_archive(path, a.raw); !ok {
		return
	}
	return fmt.tprintf("server_file.xml: %d online stages", len(stages)), true
}

// --- archive io --------------------------------------------------------------

@(private = "file")
open_archive :: proc(path: string) -> (a: nefs.Archive, msg: string, ok: bool) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return a, fmt.tprintf("could not read %s: %v", path, err), false
	}
	a, msg, ok = nefs.open(raw)
	if ok {
		for name in ([]string{"csconfig.xml", "csdata.xml", "server_file.xml"}) {
			if _, found := nefs.read(&a, name, context.temp_allocator); !found {
				nefs.close(&a)
				return a, fmt.tprintf("%s has no %s", path, name), false
			}
		}
	}
	return
}

@(private = "file")
save_archive :: proc(path: string, raw: []u8) -> (msg: string, ok: bool) {
	if msg, ok = d3_backup_once(path); !ok {
		return
	}
	return atomic_write_file(path, raw)
}

// --- checksum files ----------------------------------------------------------

// Spaces over everything inside <csmanagerinfo>. Returns the <file> count.
@(private = "file")
blank_config :: proc(xml: []u8) -> (files: int, ok: bool) {
	text := string(xml)
	OPEN :: "<csmanagerinfo>"
	start := strings.index(text, OPEN)
	end := strings.index(text, "</csmanagerinfo>")
	if start < 0 || end < start {
		return
	}
	start += len(OPEN)
	files = strings.count(text[start:end], "<file ")
	for &b in xml[start:end] {
		b = ' '
	}
	return files, true
}

// NUL the first byte of every string used only as a <section> value; the game
// never reads `path` either. The rest of each blanked string is unread, so it
// is the spare room. Bit 7 flips, so a spare never becomes the NUL.
@(private = "file")
blank_sections :: proc(xml: []u8) -> (spares: []nefs.Spare, blanked: int, ok: bool) {
	t := bxml_tables(xml) or_return
	ids := section_only_strings(xml, t) or_return
	out := make([dynamic]nefs.Spare, context.temp_allocator)
	for i in ids {
		at := bxml_string_at(xml, t, i)
		if at >= len(xml) {
			return
		}
		xml[at] = 0
		for j := at + 1; j < len(xml) && xml[j] != 0; j += 1 {
			append(&out, nefs.Spare{j, xml[j] ~ 0x80})
		}
	}
	return out[:], len(ids), true
}

@(private = "file")
section_only_strings :: proc(xml: []u8, t: Bxml_Tables) -> (ids: []int, ok: bool) {
	targets := make(map[int]bool, context.temp_allocator)
	keep := make(map[int]bool, context.temp_allocator)
	for e in 0 ..< t.n_elements {
		el := t.elements + 24 * e
		name_id, value_id := u32_at(xml, el), u32_at(xml, el + 4)
		n, first := u32_at(xml, el + 8), u32_at(xml, el + 12)
		if max(name_id, value_id) >= t.n_strings || first + n > t.n_attrs {
			return
		}
		keep[name_id], keep[value_id] = true, true
		is_section := bxml_string(xml, t, name_id) == "section"
		for k in first ..< first + n {
			key_id, value := u32_at(xml, t.attrs + 8 * k), u32_at(xml, t.attrs + 8 * k + 4)
			if max(key_id, value) >= t.n_strings {
				return
			}
			keep[key_id] = true
			key := bxml_string(xml, t, key_id)
			if is_section && strings.has_prefix(key, "str") {
				targets[value] = true
			} else if key != "path" {
				keep[value] = true
			}
		}
	}
	out := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< t.n_strings {
		if targets[i] && !keep[i] {
			append(&out, i)
		}
	}
	return out[:], true
}

// Where a BinXML file's tables start, and their lengths.
@(private = "file")
Bxml_Tables :: struct {
	offsets, elements, attrs:       int,
	n_strings, n_elements, n_attrs: int,
}

@(private = "file")
BXML_STRINGS :: 24

@(private = "file")
bxml_tables :: proc(xml: []u8) -> (t: Bxml_Tables, ok: bool) {
	if len(xml) < BXML_STRINGS {
		return
	}
	t.offsets = BXML_STRINGS + u32_at(xml, 20) + 8
	t.n_strings = u32_at(xml, t.offsets - 4) / 4
	t.elements = t.offsets + 4 * t.n_strings + 8
	t.n_elements = u32_at(xml, t.elements - 4) / 24
	t.attrs = t.elements + 24 * t.n_elements + 8
	t.n_attrs = u32_at(xml, t.attrs - 4) / 8
	return t, t.attrs + 8 * t.n_attrs <= len(xml)
}

@(private = "file")
bxml_string_at :: proc(xml: []u8, t: Bxml_Tables, i: int) -> int {
	return BXML_STRINGS + u32_at(xml, t.offsets + 4 * i)
}

@(private = "file")
bxml_string :: proc(xml: []u8, t: Bxml_Tables, i: int) -> string {
	at := bxml_string_at(xml, t, i)
	end := at
	for end < len(xml) && xml[end] != 0 {
		end += 1
	}
	return string(xml[min(at, end):end])
}

// 0 past the end, so a short file reads as empty tables.
@(private = "file")
u32_at :: proc(d: []u8, at: int) -> int {
	return at >= 0 && at + 4 <= len(d) ? int(endian.unchecked_get_u32le(d[at:])) : 0
}

// Spaces and tabs between tags can trade places.
@(private = "file")
xml_spares :: proc(xml: []u8) -> []nefs.Spare {
	out := make([dynamic]nefs.Spare, context.temp_allocator)
	for gap in whitespace_gaps(string(xml)) {
		for i in gap[0] ..< gap[1] {
			switch xml[i] {
			case ' ':
				append(&out, nefs.Spare{i, '\t'})
			case '\t':
				append(&out, nefs.Spare{i, ' '})
			}
		}
	}
	return out[:]
}

// [start, end) of every run of pure whitespace from a '>' to a '<'.
@(private = "file")
whitespace_gaps :: proc(xml: string) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	for i := 0; i < len(xml); i += 1 {
		if xml[i] != '>' {
			continue
		}
		end := i + 1
		for end < len(xml) && strings.is_space(rune(xml[end])) {
			end += 1
		}
		if end > i + 1 && end < len(xml) && xml[end] == '<' {
			append(&out, [2]int{i + 1, end})
		}
		i = end - 1
	}
	return out[:]
}

// Cut up to `excess` bytes of whitespace between tags, last gap first.
// Returns what is left to cut.
@(private = "file")
cut_gaps :: proc(xml: string, excess: int) -> (out: string, left: int) {
	gaps := whitespace_gaps(xml)
	cut := make([]int, len(gaps), context.temp_allocator)
	left = excess
	for i := len(gaps) - 1; i >= 0 && left > 0; i -= 1 {
		cut[i] = min(left, gaps[i][1] - gaps[i][0])
		left -= cut[i]
	}
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for gap, i in gaps {
		strings.write_string(&b, xml[at:gap[1] - cut[i]])
		at = gap[1]
	}
	strings.write_string(&b, xml[at:])
	return strings.to_string(b), left
}

// --- server_file.xml ---------------------------------------------------------

// One deployed stage, and the stock route it was cloned from.
@(private)
Online_Stage :: struct {
	key, base_key:     string, // track name_string_id
	route, base_route: string, // the N in route_N
}

// Our stages are the models stock does not have. Each was cloned from a stock
// model and kept its track_spline_id.
@(private = "file")
online_stages :: proc(db, stock: ^Database) -> []Online_Stage {
	tracks, has_tracks := database_table(db, "track")
	models, has_models := database_table(db, "track_model")
	stock_models, has_stock := database_table(stock, "track_model")
	if !has_tracks || !has_models || !has_stock {
		return nil
	}
	key_of := make(map[i32]string, context.temp_allocator)
	for row in tracks.rows {
		key_of[row_int(tracks, row, "id")] = row_str(tracks, row, "name_string_id")
	}
	is_stock := make(map[i32]bool, context.temp_allocator)
	for row in stock_models.rows {
		is_stock[row_int(stock_models, row, "id")] = true
	}

	out := make([dynamic]Online_Stage, context.temp_allocator)
	for model in models.rows {
		if is_stock[row_int(models, model, "id")] {
			continue
		}
		spline := row_str(models, model, "track_spline_id")
		for base in models.rows {
			if is_stock[row_int(models, base, "id")] && row_str(models, base, "track_spline_id") == spline {
				append(&out, Online_Stage{
					key_of[row_int(models, model, "track_id")],
					key_of[row_int(models, base, "track_id")],
					strings.trim_prefix(row_str(models, model, "route_string"), "route_"),
					strings.trim_prefix(row_str(models, base, "route_string"), "route_"),
				})
				break
			}
		}
	}
	return out[:]
}

// The stock file with a clone of each listed base <track> after it, then cut
// back to its stock size out of the whitespace between tags.
@(private)
server_file_with :: proc(stock: string, stages: []Online_Stage) -> (text: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for {
		start := strings.index(stock[at:], `<track value="`)
		if start < 0 {
			break
		}
		start += at
		close := strings.index(stock[start:], "</track>")
		if close < 0 {
			return
		}
		end := start + close + len("</track>")
		strings.write_string(&b, stock[at:end])
		track_clones(&b, stock[start:end], stages)
		at = end
	}
	strings.write_string(&b, stock[at:])
	grown := strings.to_string(b)
	left: int
	text, left = cut_gaps(grown, len(grown) - len(stock))
	return text, left == 0
}

// One clone per new track key that is based on this element's key.
@(private = "file")
track_clones :: proc(b: ^strings.Builder, element: string, stages: []Online_Stage) {
	key := attr_value(element)
	for s, i in stages {
		if s.base_key != key || first_of_key(stages, i) != i {
			continue
		}
		routes := strings.builder_make(context.temp_allocator)
		for r in stages {
			if r.key == s.key && r.base_key == key {
				if route, found := route_element(element, r.base_route); found {
					strings.write_string(&routes, swap_first(route, r.base_route, r.route))
				}
			}
		}
		if strings.builder_len(routes) == 0 {
			continue
		}
		bare := strip_routes(element)
		bare = swap_first(bare, key, s.key)
		bare, _ = strings.replace(bare, "</track>", fmt.tprintf("%s</track>", strings.to_string(routes)), 1, context.temp_allocator)
		tight, _ := cut_gaps(bare, len(bare))
		strings.write_string(b, tight)
	}
}

@(private = "file")
first_of_key :: proc(stages: []Online_Stage, i: int) -> int {
	for s, j in stages {
		if s.key == stages[i].key && s.base_key == stages[i].base_key {
			return j
		}
	}
	return i
}

// The first `"old"` becomes `"new"`.
@(private = "file")
swap_first :: proc(text, old, new: string) -> string {
	out, _ := strings.replace(text, fmt.tprintf(`"%s"`, old), fmt.tprintf(`"%s"`, new), 1, context.temp_allocator)
	return out
}

// The first value="..." of an element.
@(private = "file")
attr_value :: proc(element: string) -> string {
	start := strings.index(element, `value="`) + len(`value="`)
	end := strings.index_byte(element[start:], '"')
	return element[start:start + end]
}

// `<route value="n" .../>` or `<route value="n" ...>...</route>`.
@(private = "file")
route_element :: proc(text: string, n: string) -> (route: string, ok: bool) {
	start := strings.index(text, fmt.tprintf(`<route value="%s"`, n))
	if start < 0 {
		return
	}
	return text[start:start + route_length(text[start:])], true
}

@(private = "file")
route_length :: proc(route: string) -> int {
	tag_end := strings.index_byte(route, '>')
	if route[tag_end - 1] == '/' {
		return tag_end + 1
	}
	return strings.index(route, "</route>") + len("</route>")
}

@(private = "file")
strip_routes :: proc(element: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := element
	for {
		start := strings.index(rest, "<route ")
		if start < 0 {
			break
		}
		strings.write_string(&b, rest[:start])
		rest = rest[start + route_length(rest[start:]):]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}
