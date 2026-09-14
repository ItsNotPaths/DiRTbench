package d3

// Build the database and localization half of a derived venue deployment.
// This file does not write to the install. The caller receives a complete,
// verified set of replacement bytes and may either print the plan or apply it
// as part of a filesystem transaction.

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Registration_Ids :: struct {
	location: i32,
	track:    i32,
	models:   []i32,
}

Registration_Output :: struct {
	database: []u8,
	eng:      []u8,
	use:      []u8,
	summary:  string,
}

@(private = "file")
Registration_Source :: struct {
	locations:      ^Table,
	tracks:         ^Table,
	models:         ^Table,
	location_row:   Row,
	track_row:      Row,
	model_row:      Row,
}

registration_ids_delete :: proc(ids: ^Registration_Ids, allocator := context.allocator) {
	delete(ids.models, allocator)
	ids^ = {}
}

registration_output_delete :: proc(
	out: ^Registration_Output,
	allocator := context.allocator,
) {
	delete(out.database, allocator)
	delete(out.eng, allocator)
	delete(out.use, allocator)
	delete(out.summary, allocator)
	out^ = {}
}

@(private = "file")
find_row_by_id :: proc(table: ^Table, id: i32) -> (Row, bool) {
	for row in table.rows {
		if row_int(table, row, "id") == id {
			return row, true
		}
	}
	return nil, false
}

@(private = "file")
registration_source :: proc(
	db: ^Database,
	model_id: i32,
) -> (
	source: Registration_Source,
	msg: string,
	ok: bool,
) {
	source.locations, ok = database_table(db, "location")
	if !ok {
		return source, "database has no location table", false
	}
	source.tracks, ok = database_table(db, "track")
	if !ok {
		return source, "database has no track table", false
	}
	source.models, ok = database_table(db, "track_model")
	if !ok {
		return source, "database has no track_model table", false
	}
	source.model_row, ok = find_row_by_id(source.models, model_id)
	if !ok {
		return source, fmt.tprintf("no track_model with id %d", model_id), false
	}
	track_id := row_int(source.models, source.model_row, "track_id")
	source.track_row, ok = find_row_by_id(source.tracks, track_id)
	if !ok {
		return source, "source model has no track", false
	}
	location_id := row_int(source.tracks, source.track_row, "location_id")
	source.location_row, ok = find_row_by_id(source.locations, location_id)
	if !ok {
		return source, "source track has no location", false
	}
	return source, "", true
}

@(private = "file")
location_name_available :: proc(locations: ^Table, name: string) -> bool {
	for row in locations.rows {
		if row_str(locations, row, "name_string_id") == name {
			return false
		}
	}
	return true
}

@(private = "file")
database_has_venue :: proc(db: ^Database, location, venue: string) -> bool {
	models, found := database_table(db, "track_model")
	if !found {
		return false
	}
	for row in models.rows {
		if row_str(models, row, "folder_string") == location &&
		   row_str(models, row, "file_string") == venue {
			return true
		}
	}
	return false
}

@(private = "file")
clone_related_rows :: proc(
	db: ^Database,
	table_name, foreign_key: string,
	source_id, target_id: i32,
	allocator := context.allocator,
) -> (
	count: int,
	msg: string,
	ok: bool,
) {
	table, found := database_table(db, table_name)
	if !found {
		return 0, fmt.tprintf("database has no %s table", table_name), false
	}

	additions := make([dynamic]Row, allocator)
	defer delete(additions)
	next_id := table_next_id(table)
	for row in table.rows {
		if row_int(table, row, foreign_key) != source_id {
			continue
		}
		cloned := row_clone(table, row, allocator)
		_ = row_set_int(table, cloned, "id", next_id)
		_ = row_set_int(table, cloned, foreign_key, target_id)
		append(&additions, cloned)
		next_id += 1
	}

	count = len(additions)
	append(&table.rows, ..additions[:])
	return count, "", true
}

@(private = "file")
clone_location_row :: proc(
	locations: ^Table,
	source: Row,
	name: string,
	allocator := context.allocator,
) -> (row: Row, id: i32) {
	id = table_next_id(locations)
	row = row_clone(locations, source, allocator)
	_ = row_set_int(locations, row, "id", id)
	_ = row_set_str(locations, row, "name_string_id", name, allocator)
	_ = row_set_int(
		locations,
		row,
		"order_index",
		table_max_int(locations, "order_index") + 1,
	)
	_ = row_set_bool(locations, row, "count_for_achievement", false)
	_ = row_set_int(locations, row, "xlast_context_id", 0)
	return
}

@(private = "file")
clone_track_row :: proc(
	tracks: ^Table,
	source: Row,
	location_id: i32,
	name: string,
	allocator := context.allocator,
) -> (row: Row, id: i32) {
	id = table_next_id(tracks)
	row = row_clone(tracks, source, allocator)
	_ = row_set_int(tracks, row, "id", id)
	_ = row_set_int(tracks, row, "location_id", location_id)
	_ = row_set_str(tracks, row, "name_string_id", name, allocator)
	return
}

@(private = "file")
clone_model_row :: proc(
	models: ^Table,
	source: Row,
	track_id: i32,
	location, venue, route, name_key: string,
	allocator := context.allocator,
) -> (row: Row, id: i32) {
	id = table_next_id(models)
	row = row_clone(models, source, allocator)
	_ = row_set_int(models, row, "id", id)
	_ = row_set_int(models, row, "track_id", track_id)
	_ = row_set_str(models, row, "folder_string", location, allocator)
	_ = row_set_str(models, row, "file_string", venue, allocator)
	_ = row_set_str(models, row, "route_string", route, allocator)
	_ = row_set_str(models, row, "name_string_id", name_key, allocator)
	_ = row_set_int(
		models,
		row,
		"order_index",
		table_max_int(models, "order_index") + 1,
	)
	_ = row_set_int(models, row, "ui_track_model_id", 0)
	_ = row_set_bool(models, row, "every_track_achievement", false)
	return
}

// Clone a source location/track/model chain, then one model per requested
// route. The source route's internal AI and spline identifiers are retained:
// deployment begins with a byte-for-byte hardlinked copy of that route.
register_location :: proc(
	db: ^Database,
	source_model_id: i32,
	location, venue: string,
	routes, stage_keys: []string,
	allocator := context.allocator,
) -> (
	ids: Registration_Ids,
	msg: string,
	ok: bool,
) {
	if len(routes) == 0 || len(routes) != len(stage_keys) {
		return ids, "registration needs one localization key per route", false
	}

	source, source_msg, source_ok := registration_source(db, source_model_id)
	if !source_ok {
		return ids, source_msg, false
	}
	if database_has_venue(db, location, venue) {
		return ids, fmt.tprintf("%s/%s is already registered", location, venue), false
	}
	if !location_name_available(source.locations, location) {
		return ids, fmt.tprintf("location %q already exists", location), false
	}

	location_row: Row
	location_row, ids.location = clone_location_row(
		source.locations,
		source.location_row,
		location,
		allocator,
	)
	append(&source.locations.rows, location_row)

	track_row: Row
	track_row, ids.track = clone_track_row(
		source.tracks,
		source.track_row,
		ids.location,
		venue,
		allocator,
	)
	append(&source.tracks.rows, track_row)

	ids.models = make([]i32, len(routes), allocator)
	for route, i in routes {
		model, model_id := clone_model_row(
			source.models,
			source.model_row,
			ids.track,
			location,
			venue,
			route,
			stage_keys[i],
			allocator,
		)
		ids.models[i] = model_id
		append(&source.models.rows, model)

		_, msg, ok = clone_related_rows(
			db,
			"track_model_conditions",
			"track_model_id",
			source_model_id,
			model_id,
			allocator,
		)
		if !ok {
			return
		}
		_, msg, ok = clone_related_rows(
			db,
			"track_model_surface",
			"track_model_id",
			source_model_id,
			model_id,
			allocator,
		)
		if !ok {
			return
		}
	}
	return ids, "", true
}

@(private = "file")
sha256_text :: proc(data: []u8, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])

	builder := strings.builder_make(allocator)
	for byte in digest {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

@(private = "file")
add_localized_strings :: proc(
	raw: []u8,
	location_key, location_name, venue_key, venue_name: string,
	stage_keys, stage_names: []string,
	allocator := context.allocator,
) -> (
	data: []u8,
	msg: string,
	ok: bool,
) {
	data = make([]u8, len(raw), allocator)
	copy(data, raw)

	keys := [2]string{location_key, venue_key}
	values := [2]string{location_name, venue_name}
	for value, i in values {
		key := fmt.tprintf("db_%s", keys[i])
		next, set_msg, set_ok := verified_lng_bytes(data, key, value, allocator)
		delete(data, allocator)
		if !set_ok {
			return nil, set_msg, false
		}
		data = next
	}
	for value, i in stage_names {
		key := fmt.tprintf("db_%s", stage_keys[i])
		next, set_msg, set_ok := verified_lng_bytes(data, key, value, allocator)
		delete(data, allocator)
		if !set_ok {
			return nil, set_msg, false
		}
		data = next
	}
	return data, "", true
}

@(private = "file")
load_registration_database :: proc(
	path: string,
) -> (
	raw: []u8,
	database: Database,
	msg: string,
	ok: bool,
) {
	read_err: os.Error
	raw, read_err = os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return nil, database, fmt.tprintf("could not read %s: %v", path, read_err), false
	}
	schema, schema_msg, schema_ok := schema_builtin(context.temp_allocator)
	if !schema_ok {
		return nil, database, schema_msg, false
	}
	database, msg, ok = database_load(raw, schema, context.temp_allocator)
	if !ok {
		return
	}
	if msg, ok = database_roundtrip_ok(raw, database); !ok {
		return
	}
	return raw, database, "", true
}

@(private = "file")
read_registration_file :: proc(path: string) -> ([]u8, string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, fmt.tprintf("could not read %s: %v", path, err), false
	}
	return data, "", true
}

prepare_registration :: proc(
	root: string,
	source_model_id: i32,
	location, venue, location_name, venue_name: string,
	routes, stage_names: []string,
	allocator := context.allocator,
) -> (
	out: Registration_Output,
	msg: string,
	ok: bool,
) {
	defer if !ok {
		registration_output_delete(&out, allocator)
	}
	if len(routes) != len(stage_names) {
		return out, "stage routes and names disagree", false
	}

	database_path, _ := filepath.join({root, DATABASE_SUBPATH}, context.temp_allocator)
	eng_path, _ := filepath.join(
		{root, "language/language_extensions_eng.lng"},
		context.temp_allocator,
	)
	use_path, _ := filepath.join(
		{root, "language/language_extensions_use.lng"},
		context.temp_allocator,
	)

	database_raw: []u8
	database: Database
	database_raw, database, msg, ok = load_registration_database(database_path)
	if !ok { return }

	stage_keys := make([]string, len(routes), context.temp_allocator)
	for route, i in routes {
		stage_keys[i] = fmt.tprintf("%s_%s", venue, route)
	}
	ids, register_msg, registered := register_location(
		&database,
		source_model_id,
		location,
		venue,
		routes,
		stage_keys,
		context.temp_allocator,
	)
	if !registered {
		return out, register_msg, false
	}
	out.database, msg, ok = database_encode(database, allocator)
	if !ok {
		return
	}

	eng_raw: []u8
	eng_raw, msg, ok = read_registration_file(eng_path)
	if !ok { return }
	use_raw: []u8
	use_raw, msg, ok = read_registration_file(use_path)
	if !ok { return }
	out.eng, msg, ok = add_localized_strings(
		eng_raw,
		location,
		location_name,
		venue,
		venue_name,
		stage_keys,
		stage_names,
		allocator,
	)
	if !ok {
		return
	}
	out.use, msg, ok = add_localized_strings(
		use_raw,
		location,
		location_name,
		venue,
		venue_name,
		stage_keys,
		stage_names,
		allocator,
	)
	if !ok {
		return
	}

	out.summary = fmt.aprintf(
		"source model: %d\n" +
		"location: clone as %d (%s)\n" +
		"track: clone as %d (%s)\n" +
		"models: %v\n" +
		"localization: db_%s, db_%s, and %d stage keys in eng and use\n" +
		"database sha256: %s\n" +
		"language_extensions_eng.lng sha256: %s\n" +
		"language_extensions_use.lng sha256: %s",
		source_model_id,
		ids.location,
		location,
		ids.track,
		venue,
		ids.models,
		location,
		venue,
		len(routes),
		sha256_text(database_raw, context.temp_allocator),
		sha256_text(eng_raw, context.temp_allocator),
		sha256_text(use_raw, context.temp_allocator),
		allocator = allocator,
	)
	return out, "", true
}

database_bytes_have_venue :: proc(raw: []u8, location, venue: string) -> bool {
	schema, _, schema_ok := schema_builtin(context.temp_allocator)
	if !schema_ok {
		return false
	}
	database, _, database_ok := database_load(raw, schema, context.temp_allocator)
	if !database_ok {
		return false
	}
	return database_has_venue(&database, location, venue)
}
