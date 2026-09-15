package d3

// `database/database.bin` — the table that decides which venues exist.
//
// A venue is not a directory. The game reads `track_model` out of this file and
// `folder_string` / `file_string` / `route_string` select
// `<folder>/<venue>/<route>` on disk. A directory nobody registered is invisible
// and a registration with no directory is a broken menu entry, so the database
// is the authority and the filesystem is a second opinion. See install.odin,
// which reports where the two disagree.
//
// The layout is fixed and dull. A header, then one block per table **in schema
// order**, each tagged with its own index:
//
//     u32 magic, u32 version                      version must be 3934935529
//     for table_index, table in schema:
//         [table_index] 'L' 'B' 'T'               4-byte marker
//         u32 row_count
//         for each row:
//             'I' 'T' 'M' [table_index]           4-byte marker
//             one fixed-width value per field, in schema field order
//
// Every value is 4 bytes except a string, which is a NUL-padded fixed-width
// buffer (see `string_width`). Nothing is length-prefixed and nothing is
// optional, so the schema is not a hint: it *is* the file layout. Read it with
// the wrong schema and every offset after the first mismatch is garbage that
// still parses. `database_roundtrip_ok` is the guard, and it is not optional
// either — re-encode before writing and refuse if the bytes moved.
//
// The schema is Ego-Engine-Modding's `schemaDirt3.xml`, baked in rather than
// fetched, since nothing here reaches the network.

import "core:encoding/xml"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

D3_SCHEMA_XML :: #load("../../assets/d3/schemaDirt3.xml")

// The one database version this schema describes. A different number means the
// layout below does not apply, so refuse rather than write garbage.
D3_DATABASE_VERSION :: 3934935529

Field_Kind :: enum u8 {
	Int,
	Float,
	Bool,
	String,
}

Field :: struct {
	name: string,
	kind: Field_Kind,
	size: int, // declared max length, strings only
}

Value :: union {
	i32,
	f32,
	bool,
	string,
}

// One row is its table's fields, in order. Positional rather than a map: the
// order is the file layout, cloning a row is a slice copy, and a typo in a field
// name fails at the lookup instead of silently adding a key.
Row :: []Value

Table :: struct {
	name:   string,
	fields: []Field,
	rows:   [dynamic]Row,
}

Database :: struct {
	magic:   u32,
	version: u32,
	tables:  []Table,
}

// A string field occupies `size` bytes rounded up to a multiple of 4, plus at
// least one NUL. A length already 3 mod 4 therefore gains 5, not 1: rounding up
// would leave no room for the terminator.
string_width :: proc(size: int) -> int {
	if size % 4 == 3 {
		return size + 5
	}
	return size + (4 - size % 4)
}

// --- schema ------------------------------------------------------------------

Schema_Table :: struct {
	name:   string,
	fields: []Field,
}

// Parse `schemaDirt3.xml` into table-and-field order. Document order is the
// file's field order, so nothing here may sort.
schema_parse :: proc(
	source: []u8,
	allocator := context.allocator,
) -> (
	tables: []Schema_Table,
	msg: string,
	ok: bool,
) {
	doc, err := xml.parse_bytes(source, allocator = context.temp_allocator)
	if err != nil {
		return nil, fmt.tprintf("could not parse the database schema: %v", err), false
	}

	out := make([dynamic]Schema_Table, allocator)
	for element, id in doc.elements {
		if element.ident != "table" || element.kind != .Element {
			continue
		}
		name, has_name := xml.find_attribute_val_by_key(doc, xml.Element_ID(id), "name")
		if !has_name {
			return nil, "a schema table has no name", false
		}

		fields := make([dynamic]Field, allocator)
		for value in element.value {
			child_id, is_child := value.(xml.Element_ID)
			if !is_child {
				continue
			}
			child := doc.elements[child_id]
			if child.ident != "field" || child.kind != .Element {
				continue
			}
			field_name, has_field_name := xml.find_attribute_val_by_key(doc, child_id, "name")
			kind_text, has_kind := xml.find_attribute_val_by_key(doc, child_id, "type")
			if !has_field_name || !has_kind {
				return nil, fmt.tprintf("a field of %s has no name or type", name), false
			}
			kind: Field_Kind
			switch kind_text {
			case "float":
				kind = .Float
			case "bool":
				kind = .Bool
			case "string":
				kind = .String
			case:
				// The schema carries a handful of other integer-ish spellings.
				// They are all one 32-bit signed word, which is what `int` is.
				kind = .Int
			}
			size := 0
			if size_text, has_size := xml.find_attribute_val_by_key(doc, child_id, "size");
			   has_size {
				size, _ = strconv.parse_int(size_text)
			}
			append(
				&fields,
				Field {
					name = strings.clone(field_name, allocator),
					kind = kind,
					size = size,
				},
			)
		}
		append(
			&out,
			Schema_Table{name = strings.clone(name, allocator), fields = fields[:]},
		)
	}
	if len(out) == 0 {
		return nil, "the database schema declares no tables", false
	}
	return out[:], "", true
}

// The baked schema. Parsed on every call; callers hold the result.
schema_builtin :: proc(
	allocator := context.allocator,
) -> (
	tables: []Schema_Table,
	msg: string,
	ok: bool,
) {
	return schema_parse(D3_SCHEMA_XML, allocator)
}

// --- reading -----------------------------------------------------------------

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> (out: []u8, ok: bool) {
	if r.at + n > len(r.data) {
		return nil, false
	}
	out = r.data[r.at:r.at + n]
	r.at += n
	return out, true
}

@(private = "file")
take_u32 :: proc(r: ^Reader) -> (v: u32, ok: bool) {
	b := take(r, 4) or_return
	return binary_load_u32(b, 0), true
}

database_load :: proc(
	data: []u8,
	schema: []Schema_Table,
	allocator := context.allocator,
) -> (
	db: Database,
	msg: string,
	ok: bool,
) {
	r := Reader{data = data}
	magic, got_magic := take_u32(&r)
	version, got_version := take_u32(&r)
	if !got_magic || !got_version {
		return db, "database is too short to hold a header", false
	}
	if version != D3_DATABASE_VERSION {
		return db, fmt.tprintf(
			"database version %d, expected %d: the baked schema does not describe this file",
			version,
			D3_DATABASE_VERSION,
		), false
	}

	// Assigned before the loop so a refusal below releases whatever was read.
	// Unfilled entries are zero Tables, which delete cleanly.
	db.magic, db.version = magic, version
	db.tables = make([]Table, len(schema), allocator)
	defer if !ok {
		database_delete(&db, allocator)
	}

	for entry, table_index in schema {
		marker, got_marker := take(&r, 4)
		if !got_marker || !marker_is(marker, .Table, table_index) {
			return db, fmt.tprintf("bad table marker for %s (table %d)", entry.name, table_index), false
		}
		count, got_count := take_u32(&r)
		if !got_count {
			return db, fmt.tprintf("%s ends before its row count", entry.name), false
		}

		rows := make([dynamic]Row, 0, int(count), allocator)
		db.tables[table_index] = Table{name = entry.name, fields = entry.fields, rows = rows}
		for row_index in 0 ..< int(count) {
			row_marker, got_row_marker := take(&r, 4)
			if !got_row_marker || !marker_is(row_marker, .Row, table_index) {
				return db, fmt.tprintf("bad row marker for %s row %d", entry.name, row_index), false
			}
			// Tracked before it is filled, so a refusal part-way through the
			// row still releases it.
			row := make(Row, len(entry.fields), allocator)
			append(&rows, row)
			db.tables[table_index].rows = rows
			for field, field_index in entry.fields {
				value, read_msg, read_ok := read_value(&r, field, allocator)
				if !read_ok {
					return db, fmt.tprintf("%s.%s row %d: %s", entry.name, field.name, row_index, read_msg), false
				}
				row[field_index] = value
			}
		}
	}

	if r.at != len(data) {
		return db, fmt.tprintf("%d bytes remain after the last table", len(data) - r.at), false
	}
	return db, "", true
}

@(private = "file")
Marker_Kind :: enum {
	Table, // <index> L B T
	Row,   // I T M <index>
}

@(private = "file")
marker_is :: proc(marker: []u8, kind: Marker_Kind, table_index: int) -> bool {
	// The index is one byte, so a schema of more than 256 tables could not be
	// addressed. Dirt 3 has 212.
	if table_index > 255 {
		return false
	}
	switch kind {
	case .Table:
		return marker[0] == u8(table_index) && string(marker[1:]) == "LBT"
	case .Row:
		return string(marker[:3]) == "ITM" && marker[3] == u8(table_index)
	}
	return false
}

@(private = "file")
read_value :: proc(
	r: ^Reader,
	field: Field,
	allocator := context.allocator,
) -> (
	value: Value,
	msg: string,
	ok: bool,
) {
	switch field.kind {
	case .Float:
		b := take(r, 4) or_else nil
		if b == nil {
			return nil, "ran out of data", false
		}
		return transmute(f32)binary_load_u32(b, 0), "", true
	case .Int:
		b := take(r, 4) or_else nil
		if b == nil {
			return nil, "ran out of data", false
		}
		return transmute(i32)binary_load_u32(b, 0), "", true
	case .Bool:
		b := take(r, 4) or_else nil
		if b == nil {
			return nil, "ran out of data", false
		}
		// A bool is one byte in a 4-byte slot. Padding that is not zero means we
		// are reading at the wrong offset, which is worth catching here rather
		// than 600 KB later.
		if b[1] != 0 || b[2] != 0 || b[3] != 0 {
			return nil, "boolean padding is not zero", false
		}
		return b[0] != 0, "", true
	case .String:
		b := take(r, string_width(field.size)) or_else nil
		if b == nil {
			return nil, "ran out of data", false
		}
		end := 0
		for end < len(b) && b[end] != 0 {
			end += 1
		}
		return strings.clone(string(b[:end]), allocator), "", true
	}
	return nil, "unknown field kind", false
}

// --- writing -----------------------------------------------------------------

database_encode :: proc(
	db: Database,
	allocator := context.allocator,
) -> (
	data: []u8,
	msg: string,
	ok: bool,
) {
	out := make([dynamic]u8, allocator)
	defer if !ok {
		delete(out)
	}
	append_u32(&out, db.magic)
	append_u32(&out, db.version)

	for table, table_index in db.tables {
		if table_index > 255 {
			return nil, "a database cannot hold more than 256 tables", false
		}
		append(&out, u8(table_index), 'L', 'B', 'T')
		append_u32(&out, u32(len(table.rows)))
		for row, row_index in table.rows {
			append(&out, 'I', 'T', 'M', u8(table_index))
			if len(row) != len(table.fields) {
				return nil, fmt.tprintf(
					"%s row %d has %d values, expected %d",
					table.name,
					row_index,
					len(row),
					len(table.fields),
				), false
			}
			for field, field_index in table.fields {
				if write_msg, written := write_value(&out, field, row[field_index]); !written {
					return nil, fmt.tprintf("%s.%s row %d: %s", table.name, field.name, row_index, write_msg), false
				}
			}
		}
	}
	return out[:], "", true
}

@(private = "file")
append_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
write_value :: proc(out: ^[dynamic]u8, field: Field, value: Value) -> (msg: string, ok: bool) {
	switch field.kind {
	case .Float:
		f, is_float := value.(f32)
		if !is_float {
			return "expected a float", false
		}
		append_u32(out, transmute(u32)f)
	case .Int:
		i, is_int := value.(i32)
		if !is_int {
			return "expected an int", false
		}
		append_u32(out, transmute(u32)i)
	case .Bool:
		b, is_bool := value.(bool)
		if !is_bool {
			return "expected a bool", false
		}
		append(out, b ? 1 : 0, 0, 0, 0)
	case .String:
		s, is_string := value.(string)
		if !is_string {
			return "expected a string", false
		}
		width := string_width(field.size)
		// A value filling the buffer would leave no terminator, so the limit is
		// one below the width, not the declared size.
		if len(s) >= width {
			return fmt.tprintf("%q is %d bytes, the field holds %d", s, len(s), width - 1), false
		}
		append(out, s)
		for _ in len(s) ..< width {
			append(out, 0)
		}
	}
	return "", true
}

// The gate every writer sits behind. Load, re-encode, compare: if the bytes
// moved, the schema and the file disagree and nothing may be written back.
database_roundtrip_ok :: proc(data: []u8, db: Database) -> (msg: string, ok: bool) {
	encoded, encode_msg, encoded_ok := database_encode(db, context.temp_allocator)
	if !encoded_ok {
		return encode_msg, false
	}
	if len(encoded) != len(data) {
		return fmt.tprintf(
			"re-encoded database is %d bytes, the original is %d",
			len(encoded),
			len(data),
		), false
	}
	if mem.compare(encoded, data) != 0 {
		for i in 0 ..< len(data) {
			if encoded[i] != data[i] {
				return fmt.tprintf("re-encoded database first differs at byte %d", i), false
			}
		}
	}
	return "", true
}

// --- lookup ------------------------------------------------------------------

database_table :: proc(db: ^Database, name: string) -> (^Table, bool) {
	for &table in db.tables {
		if table.name == name {
			return &table, true
		}
	}
	return nil, false
}

table_field :: proc(t: ^Table, name: string) -> (int, bool) {
	for field, i in t.fields {
		if field.name == name {
			return i, true
		}
	}
	return 0, false
}

// Field accessors. A missing field or a wrong kind returns the zero value, which
// is wrong in a way that shows up immediately rather than a wrong *row*, which
// would not.
row_str :: proc(t: ^Table, row: Row, name: string) -> string {
	i, found := table_field(t, name)
	if !found {
		return ""
	}
	s, is_string := row[i].(string)
	return is_string ? s : ""
}

row_int :: proc(t: ^Table, row: Row, name: string) -> i32 {
	i, found := table_field(t, name)
	if !found {
		return 0
	}
	v, is_int := row[i].(i32)
	return is_int ? v : 0
}

row_bool :: proc(t: ^Table, row: Row, name: string) -> bool {
	i, found := table_field(t, name)
	if !found {
		return false
	}
	v, is_bool := row[i].(bool)
	return is_bool ? v : false
}

// Mutation helpers used by registration. Strings in a Database are owned, so
// cloning and replacement must clone/free them just like the reader does.
row_clone :: proc(t: ^Table, row: Row, allocator := context.allocator) -> Row {
	out := make(Row, len(row), allocator)
	for value, i in row {
		if text, is_string := value.(string); is_string {
			out[i] = strings.clone(text, allocator)
		} else {
			out[i] = value
		}
	}
	return out
}

row_set_int :: proc(t: ^Table, row: Row, name: string, value: i32) -> bool {
	i, found := table_field(t, name)
	if !found {
		return false
	}
	row[i] = value
	return true
}

row_set_bool :: proc(t: ^Table, row: Row, name: string, value: bool) -> bool {
	i, found := table_field(t, name)
	if !found {
		return false
	}
	row[i] = value
	return true
}

row_set_str :: proc(
	t: ^Table,
	row: Row,
	name, value: string,
	allocator := context.allocator,
) -> bool {
	i, found := table_field(t, name)
	if !found {
		return false
	}
	old, is_string := row[i].(string)
	if !is_string {
		return false
	}
	delete(old, allocator)
	row[i] = strings.clone(value, allocator)
	return true
}

table_next_id :: proc(t: ^Table) -> i32 {
	result: i32 = -1
	for row in t.rows {
		result = max(result, row_int(t, row, "id"))
	}
	return result + 1
}

table_max_int :: proc(t: ^Table, name: string) -> i32 {
	result: i32 = -1
	for row in t.rows {
		result = max(result, row_int(t, row, name))
	}
	return result
}

// --- lifetime ----------------------------------------------------------------
//
// Both allocate every string they hand back, so both have to be released
// explicitly. The schema outlives the database that was read with it: a Table
// borrows its `fields` slice from the Schema_Table, it does not own it.

schema_delete :: proc(tables: []Schema_Table, allocator := context.allocator) {
	for table in tables {
		for field in table.fields {
			delete(field.name, allocator)
		}
		delete(table.fields, allocator)
		delete(table.name, allocator)
	}
	delete(tables, allocator)
}

database_delete :: proc(db: ^Database, allocator := context.allocator) {
	for &table in db.tables {
		for row in table.rows {
			for value, i in row {
				if s, is_string := value.(string); is_string && table.fields[i].kind == .String {
					delete(s, allocator)
				}
			}
			delete(row, allocator)
		}
		delete(table.rows)
	}
	delete(db.tables, allocator)
	db^ = {}
}
