package d3

import "core:mem"
import "core:testing"

// A schema small enough to reason about, carrying one field of every kind. The
// string sizes are the two that matter: 3 is the `% 4 == 3` case that gains 5
// bytes, 4 is the plain case that gains 4.
@(private = "file")
TINY_SCHEMA :: `<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<schema>
    <table name="first">
        <field name="id" type="int" key="primary" />
        <field name="ratio" type="float" />
        <field name="enabled" type="bool" />
        <field name="tag" type="string" size="3" />
        <field name="name" type="string" size="4" />
    </table>
    <table name="second">
        <field name="id" type="int" key="primary" />
    </table>
</schema>`

@(private = "file")
tiny_schema :: proc(t: ^testing.T) -> []Schema_Table {
	tables, msg, ok := schema_parse(transmute([]u8)string(TINY_SCHEMA), context.allocator)
	testing.expectf(t, ok, "schema did not parse: %s", msg)
	return tables
}

// header + table 0 marker + count + one row + table 1 marker + count
@(private = "file")
tiny_bytes :: proc() -> []u8 {
	out := make([dynamic]u8)
	le32 :: proc(out: ^[dynamic]u8, v: u32) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	le32(&out, 0xDEADBEEF)          // magic
	le32(&out, D3_DATABASE_VERSION) // version

	append(&out, 0, 'L', 'B', 'T')
	le32(&out, 1)                   // one row
	append(&out, 'I', 'T', 'M', 0)
	le32(&out, transmute(u32)i32(-7))  // id
	le32(&out, transmute(u32)f32(0.5)) // ratio
	append(&out, 1, 0, 0, 0)           // enabled
	append(&out, 'a', 'b', 'c', 0, 0, 0, 0, 0) // tag: size 3 -> width 8
	append(&out, 'w', 'x', 'y', 0, 0, 0, 0, 0) // name: size 4 -> width 8

	append(&out, 1, 'L', 'B', 'T')
	le32(&out, 0)                   // second table, no rows
	return out[:]
}

@(test)
string_width_leaves_room_for_the_terminator :: proc(t: ^testing.T) {
	// A size already 3 mod 4 must gain 5, not 1: rounding up to the next
	// multiple of 4 would leave no byte for the NUL.
	testing.expect_value(t, string_width(3), 8)
	testing.expect_value(t, string_width(7), 12)
	testing.expect_value(t, string_width(4), 8)
	testing.expect_value(t, string_width(5), 8)
	testing.expect_value(t, string_width(0), 4)
	for size in 0 ..< 200 {
		testing.expectf(t, string_width(size) > size, "size %d has no terminator", size)
		testing.expectf(t, string_width(size) % 4 == 0, "size %d is not word-aligned", size)
	}
}

@(test)
database_round_trips_byte_for_byte :: proc(t: ^testing.T) {
	schema := tiny_schema(t)
	defer schema_delete(schema)
	data := tiny_bytes()
	defer delete(data)
	db, msg, ok := database_load(data, schema)
	defer database_delete(&db)
	testing.expectf(t, ok, "load failed: %s", msg)

	first := &db.tables[0]
	testing.expect_value(t, len(first.rows), 1)
	testing.expect_value(t, row_int(first, first.rows[0], "id"), i32(-7))
	testing.expect_value(t, row_str(first, first.rows[0], "tag"), "abc")
	testing.expect_value(t, row_str(first, first.rows[0], "name"), "wxy")
	testing.expect_value(t, len(db.tables[1].rows), 0)

	rt_msg, rt_ok := database_roundtrip_ok(data, db)
	testing.expectf(t, rt_ok, "round trip failed: %s", rt_msg)
}

@(test)
database_refuses_a_wrong_version :: proc(t: ^testing.T) {
	data := tiny_bytes()
	defer delete(data)
	schema := tiny_schema(t)
	defer schema_delete(schema)
	data[4] = 0 // corrupt the version word
	_, _, ok := database_load(data, schema)
	testing.expect(t, !ok, "a database of an unknown version must not load")
}

// The schema is the file layout, so reading at the wrong offset is the failure
// that matters. Non-zero boolean padding is the cheapest place it shows up.
@(test)
database_refuses_nonzero_boolean_padding :: proc(t: ^testing.T) {
	data := tiny_bytes()
	defer delete(data)
	schema := tiny_schema(t)
	defer schema_delete(schema)
	// header 8 + table marker 4 + count 4 + row marker 4 + id 4 + ratio 4 = 28
	data[28 + 1] = 0xFF
	_, msg, ok := database_load(data, schema)
	testing.expect(t, !ok, "misaligned boolean padding must not load")
	testing.expectf(t, len(msg) > 0, "a refusal must say why")
}

@(test)
database_refuses_trailing_bytes :: proc(t: ^testing.T) {
	data := tiny_bytes()
	defer delete(data)
	schema := tiny_schema(t)
	defer schema_delete(schema)
	longer := make([]u8, len(data) + 1)
	defer delete(longer)
	mem.copy(raw_data(longer), raw_data(data), len(data))
	_, _, ok := database_load(longer, schema)
	testing.expect(t, !ok, "bytes after the last table mean the schema is wrong")
}

@(test)
database_refuses_a_bad_table_marker :: proc(t: ^testing.T) {
	data := tiny_bytes()
	defer delete(data)
	schema := tiny_schema(t)
	defer schema_delete(schema)
	data[8] = 9 // table 0's marker now claims to be table 9
	_, _, ok := database_load(data, schema)
	testing.expect(t, !ok, "a table marker naming another table must not load")
}

@(test)
database_refuses_an_overlong_string :: proc(t: ^testing.T) {
	schema := tiny_schema(t)
	defer schema_delete(schema)
	data := tiny_bytes()
	defer delete(data)
	db, _, ok := database_load(data, schema)
	defer database_delete(&db)
	testing.expect(t, ok)

	first := &db.tables[0]
	i, found := table_field(first, "tag")
	testing.expect(t, found)
	// width 8, so 8 bytes has no room for the terminator even though the
	// declared size is only 3. The loaded value owns its storage, so hand it
	// back before overwriting the slot.
	delete(first.rows[0][i].(string))
	first.rows[0][i] = "abcdefgh"
	_, msg, encoded := database_encode(db)
	testing.expect(t, !encoded, "a string that fills its buffer must not encode")
	testing.expectf(t, len(msg) > 0, "a refusal must say why")
}

@(test)
baked_schema_describes_the_dirt3_database :: proc(t: ^testing.T) {
	tables, msg, ok := schema_builtin()
	defer schema_delete(tables)
	testing.expectf(t, ok, "the baked schema did not parse: %s", msg)
	testing.expect_value(t, len(tables), 212)

	model := -1
	for table, i in tables {
		if table.name == "track_model" {
			model = i
		}
	}
	testing.expect(t, model >= 0, "the baked schema has no track_model table")

	// The three fields that decide which directory a registration points at.
	// Nothing else in this package works if these move.
	want := [3]string{"folder_string", "file_string", "route_string"}
	for name in want {
		found := false
		for field in tables[model].fields {
			if field.name == name {
				found = true
				testing.expectf(t, field.kind == .String, "track_model.%s is not a string", name)
			}
		}
		testing.expectf(t, found, "track_model has no %s", name)
	}
}
