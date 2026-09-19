package d3

import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
seed_row :: proc(t: ^Table) -> Row {
	row := make(Row, len(t.fields))
	for field, i in t.fields {
		switch field.kind {
		case .Int:
			row[i] = i32(0)
		case .Float:
			row[i] = f32(0)
		case .Bool:
			row[i] = false
		case .String:
			row[i] = strings.clone("")
		}
	}
	append(&t.rows, row)
	return row
}

@(private = "file")
DONOR_MODEL :: i32(7)

// One donor chain and nothing else: location, track, track_model, and one row
// in each table a model owns. Built against the real baked schema, because
// registration names real fields.
@(private = "file")
seed_database :: proc(t: ^testing.T) -> (schema: []Schema_Table, db: Database) {
	msg: string
	ok: bool
	schema, msg, ok = schema_builtin()
	testing.expectf(t, ok, "the baked schema did not parse: %s", msg)

	db.magic = 0xDEADBEEF
	db.version = D3_DATABASE_VERSION
	db.tables = make([]Table, len(schema))
	for entry, i in schema {
		db.tables[i] = Table {
			name   = entry.name,
			fields = entry.fields,
			rows   = make([dynamic]Row),
		}
	}

	locations, _ := database_table(&db, "location")
	location := seed_row(locations)
	_ = row_set_int(locations, location, "id", 3)
	_ = row_set_str(locations, location, "name_string_id", "finland")

	tracks, _ := database_table(&db, "track")
	track := seed_row(tracks)
	_ = row_set_int(tracks, track, "id", 5)
	_ = row_set_int(tracks, track, "location_id", 3)

	models, _ := database_table(&db, "track_model")
	model := seed_row(models)
	_ = row_set_int(models, model, "id", DONOR_MODEL)
	_ = row_set_int(models, model, "track_id", 5)
	_ = row_set_str(models, model, "folder_string", "finland")
	_ = row_set_str(models, model, "file_string", "finland_rally")
	_ = row_set_str(models, model, "route_string", "route_0")

	for name in ([]string{"track_model_conditions", "track_model_surface"}) {
		table, _ := database_table(&db, name)
		row := seed_row(table)
		_ = row_set_int(table, row, "id", 1)
		_ = row_set_int(table, row, "track_model_id", DONOR_MODEL)
	}
	return
}

@(private = "file")
row_count :: proc(db: ^Database, name: string) -> int {
	table, found := database_table(db, name)
	return found ? len(table.rows) : -1
}

@(private = "file")
venue_model_ids :: proc(db: ^Database, location, venue: string) -> []i32 {
	models, _ := database_table(db, "track_model")
	out := make([dynamic]i32, context.temp_allocator)
	for row in models.rows {
		if row_str(models, row, "folder_string") == location &&
		   row_str(models, row, "file_string") == venue {
			append(&out, row_int(models, row, "id"))
		}
	}
	return out[:]
}

@(private = "file")
register :: proc(t: ^testing.T, db: ^Database, venue: string, routes: []string) {
	keys := make([]string, len(routes), context.temp_allocator)
	for route, i in routes {
		keys[i] = strings.concatenate({venue, "_", route}, context.temp_allocator)
	}
	ids, msg, ok := register_location(db, DONOR_MODEL, venue, venue, routes, keys)
	defer delete(ids.models)
	testing.expectf(t, ok, "%s did not register: %s", venue, msg)
}

// The property the whole subtractive revert exists for: deployments are not a
// stack. An older venue comes out while a newer one stays, untouched and with
// its row ids unmoved.
@(test)
revert_of_an_older_venue_leaves_a_newer_one_intact :: proc(t: ^testing.T) {
	schema, db := seed_database(t)
	defer schema_delete(schema)
	defer database_delete(&db)

	register(t, &db, "alpha", {"route_0"})
	register(t, &db, "beta", {"route_0", "route_1"})
	beta_before := venue_model_ids(&db, "beta", "beta")
	testing.expect_value(t, len(beta_before), 2)

	ids, msg, ok := unregister_location(&db, "alpha", "alpha")
	defer delete(ids.models)
	testing.expectf(t, ok, "alpha did not unregister: %s", msg)
	testing.expect_value(t, len(ids.models), 1)

	testing.expect_value(t, len(venue_model_ids(&db, "alpha", "alpha")), 0)
	beta_after := venue_model_ids(&db, "beta", "beta")
	testing.expect_value(t, len(beta_after), 2)
	for id, i in beta_after {
		testing.expectf(t, id == beta_before[i], "beta model %d moved to %d", beta_before[i], id)
	}
	testing.expect_value(t, len(venue_model_ids(&db, "finland", "finland_rally")), 1)

	// beta owns two models, so both of its cloned child rows must survive and
	// both of alpha's must be gone: donor 1 + beta 2 per table.
	testing.expect_value(t, row_count(&db, "track_model_conditions"), 3)
	testing.expect_value(t, row_count(&db, "track_model_surface"), 3)
	testing.expect_value(t, row_count(&db, "location"), 2)
	testing.expect_value(t, row_count(&db, "track"), 2)
}

// Removing every venue in either order lands back on the donor, exactly.
@(test)
revert_of_both_venues_returns_the_seed :: proc(t: ^testing.T) {
	schema, db := seed_database(t)
	defer schema_delete(schema)
	defer database_delete(&db)
	seed, _, encoded := database_encode(db)
	defer delete(seed)
	testing.expect(t, encoded, "the seed did not encode")

	register(t, &db, "alpha", {"route_0"})
	register(t, &db, "beta", {"route_0", "route_1"})
	for venue in ([]string{"alpha", "beta"}) {
		ids, msg, ok := unregister_location(&db, venue, venue)
		defer delete(ids.models)
		testing.expectf(t, ok, "%s did not unregister: %s", venue, msg)
	}

	testing.expect_value(t, row_count(&db, "location"), 1)
	testing.expect_value(t, row_count(&db, "track"), 1)
	testing.expect_value(t, row_count(&db, "track_model"), 1)
	testing.expect_value(t, row_count(&db, "track_model_conditions"), 1)
	testing.expect_value(t, row_count(&db, "track_model_surface"), 1)

	again, _, re_encoded := database_encode(db)
	defer delete(again)
	testing.expect(t, re_encoded, "the stripped database did not encode")
	testing.expect(t, slice.equal(again, seed), "stripped database is not the seed, byte for byte")
}

@(test)
unregister_refuses_a_venue_that_is_not_registered :: proc(t: ^testing.T) {
	schema, db := seed_database(t)
	defer schema_delete(schema)
	defer database_delete(&db)
	_, msg, ok := unregister_location(&db, "alpha", "alpha")
	testing.expect(t, !ok, "an unregistered venue must not be removable")
	testing.expectf(t, len(msg) > 0, "a refusal must say why")
}

// A revert must not take a location another venue is still standing on. Two
// venues under one location is not what deployment builds, but it is what the
// orphan check is for, and the check is cheaper than the bug.
@(test)
unregister_keeps_a_location_another_track_still_uses :: proc(t: ^testing.T) {
	schema, db := seed_database(t)
	defer schema_delete(schema)
	defer database_delete(&db)
	register(t, &db, "alpha", {"route_0"})

	// A second track hung off alpha's location, as a shipped multi-track
	// location has.
	locations, _ := database_table(&db, "location")
	alpha_location := row_int(locations, locations.rows[len(locations.rows) - 1], "id")
	tracks, _ := database_table(&db, "track")
	extra := seed_row(tracks)
	_ = row_set_int(tracks, extra, "id", table_next_id(tracks))
	_ = row_set_int(tracks, extra, "location_id", alpha_location)

	ids, msg, ok := unregister_location(&db, "alpha", "alpha")
	defer delete(ids.models)
	testing.expectf(t, ok, "alpha did not unregister: %s", msg)
	testing.expect_value(t, ids.location, i32(-1))
	testing.expect_value(t, row_count(&db, "location"), 2)
	testing.expect_value(t, row_count(&db, "track"), 2)
}
