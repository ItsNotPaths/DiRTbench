package d3

// Reading an installed Dirt 3 tree: which venues the game knows about, and the
// routes inside each. Read-only.
//
// **The database decides, not the directory listing.** The game reads
// `track_model` out of `database/database.bin`, and `folder_string` /
// `file_string` / `route_string` select
//
//     <root>/tracks/locations/<folder>/<venue>/<route>/
//
// A directory nobody registered is invisible to the game; a registration with no
// directory is a broken menu entry. On a stock install the two disagree in both
// directions — three registered venues have no files, and dev leftovers sit on
// disk unregistered — so this reads both and reports where they differ rather
// than picking one and looking confident. See docs/venue-projects.md.
//
// A location groups venues that share terrain (`finland` holds `finland_rally`
// and `finland_trail`); a venue owns `tracksplit.pssg`, `track.vis`, the object
// and tree placements, and everything a route sits inside.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

LOCATIONS_SUBDIR :: "tracks/locations"
DATABASE_SUBPATH :: "database/database.bin"

Route :: struct {
	id:         string, // "route_0"
	dir:        string, // absolute; still set when the directory is absent
	registered: bool,   // the game has a track_model row for it
	on_disk:    bool,
	model_id:   i32, // track_model.id, when registered
}

Venue :: struct {
	id:       string, // file_string, e.g. "finland_rally"
	location: string, // folder_string, e.g. "finland"
	dir:      string,
	routes:   []Route,
}

Install :: struct {
	root:   string, // the game directory, the one holding tracks/
	venues: []Venue,
	// Held open: registering a new venue clones rows out of this, and the schema
	// owns the field slices every Table borrows.
	db:     Database,
	schema: []Schema_Table,
}

// A route the game can actually load needs both halves.
route_playable :: proc(r: Route) -> bool {
	return r.registered && r.on_disk
}

// Neither half is enough on its own, and a venue with no playable route is an
// orphan however it got that way.
venue_playable :: proc(v: Venue) -> bool {
	for route in v.routes {
		if route_playable(route) {
			return true
		}
	}
	return false
}

// Enumerate what the install holds. Fails when the database cannot be read or
// does not round-trip, because everything downstream would then be guessing.
install_open :: proc(
	root: string,
	allocator := context.allocator,
) -> (
	inst: Install,
	msg: string,
	ok: bool,
) {
	defer if !ok {
		install_delete(&inst, allocator)
	}

	inst.root = strings.clone(root, allocator)
	inst.schema, msg, ok = schema_builtin(allocator)
	if !ok {
		return
	}

	db_path, _ := filepath.join({root, DATABASE_SUBPATH}, context.temp_allocator)
	raw, read_err := os.read_entire_file(db_path, context.temp_allocator)
	if read_err != nil {
		return inst, fmt.tprintf("could not read %s: %v", db_path, read_err), false
	}
	inst.db, msg, ok = database_load(raw, inst.schema, allocator)
	if !ok {
		return
	}
	// The schema is the file layout, so a load that "worked" proves nothing on
	// its own. Refuse an install we could not write back safely.
	if msg, ok = database_roundtrip_ok(raw, inst.db); !ok {
		return
	}

	inst.venues = merge_venues(&inst, allocator)
	return inst, "", true
}

install_delete :: proc(inst: ^Install, allocator := context.allocator) {
	for venue in inst.venues {
		for route in venue.routes {
			delete(route.id, allocator)
			delete(route.dir, allocator)
		}
		delete(venue.routes, allocator)
		delete(venue.id, allocator)
		delete(venue.location, allocator)
		delete(venue.dir, allocator)
	}
	delete(inst.venues, allocator)
	database_delete(&inst.db, allocator)
	schema_delete(inst.schema, allocator)
	delete(inst.root, allocator)
	inst^ = {}
}

Install_Counts :: struct {
	venues, routes:                   int, // playable: registered and present
	orphan_venues, orphan_routes:     int, // one half only, either way
}

install_counts :: proc(inst: Install) -> (c: Install_Counts) {
	for venue in inst.venues {
		if venue_playable(venue) {
			c.venues += 1
		} else {
			c.orphan_venues += 1
		}
		for route in venue.routes {
			if route_playable(route) {
				c.routes += 1
			} else {
				c.orphan_routes += 1
			}
		}
	}
	return
}

install_venue :: proc(inst: ^Install, location, id: string) -> (^Venue, bool) {
	for &venue in inst.venues {
		if venue.location == location && venue.id == id {
			return &venue, true
		}
	}
	return nil, false
}

// --- the two halves ----------------------------------------------------------

@(private = "file")
Key :: struct {
	location, id: string,
}

@(private = "file")
Seen :: struct {
	registered: bool,
	on_disk:    bool,
	model_id:   i32,
}

// Union of what the database registers and what the filesystem holds, sorted by
// location then venue then route number.
@(private = "file")
merge_venues :: proc(inst: ^Install, allocator := context.allocator) -> []Venue {
	found := make(map[Key]map[string]Seen, context.temp_allocator)

	mark :: proc(found: ^map[Key]map[string]Seen, key: Key, route: string, seen: Seen) {
		if key not_in found^ {
			found^[key] = make(map[string]Seen, context.temp_allocator)
		}
		routes := &found^[key]
		was := routes^[route]
		routes^[route] = Seen {
			registered = was.registered || seen.registered,
			on_disk    = was.on_disk || seen.on_disk,
			model_id   = seen.registered ? seen.model_id : was.model_id,
		}
	}

	if models, has_models := database_table(&inst.db, "track_model"); has_models {
		for row in models.rows {
			key := Key {
				location = row_str(models, row, "folder_string"),
				id       = row_str(models, row, "file_string"),
			}
			route := row_str(models, row, "route_string")
			if key.location == "" || key.id == "" || route == "" {
				continue
			}
			mark(&found, key, route, {registered = true, model_id = row_int(models, row, "id")})
		}
	}

	locations, _ := filepath.join({inst.root, LOCATIONS_SUBDIR}, context.temp_allocator)
	for location in read_dirs(locations, context.temp_allocator) {
		location_dir, _ := filepath.join({locations, location}, context.temp_allocator)
		for id in read_dirs(location_dir, context.temp_allocator) {
			venue_dir, _ := filepath.join({location_dir, id}, context.temp_allocator)
			for route in read_dirs(venue_dir, context.temp_allocator) {
				if !strings.has_prefix(route, "route_") {
					continue
				}
				mark(&found, {location, id}, route, {on_disk = true})
			}
		}
	}

	keys := make([dynamic]Key, 0, len(found), context.temp_allocator)
	for key in found {
		append(&keys, key)
	}
	slice.sort_by(keys[:], proc(a, b: Key) -> bool {
		return a.location != b.location ? a.location < b.location : a.id < b.id
	})

	venues := make([]Venue, len(keys), allocator)
	for key, i in keys {
		venue_dir, _ := filepath.join({locations, key.location, key.id}, allocator)
		venues[i] = Venue {
			id       = strings.clone(key.id, allocator),
			location = strings.clone(key.location, allocator),
			dir      = venue_dir,
			routes   = build_routes(found[key], venue_dir, allocator),
		}
	}
	return venues
}

@(private = "file")
build_routes :: proc(
	seen: map[string]Seen,
	venue_dir: string,
	allocator := context.allocator,
) -> []Route {
	names := make([dynamic]string, 0, len(seen), context.temp_allocator)
	for name in seen {
		append(&names, name)
	}
	// `route_10` must sort after `route_9`, so order by the trailing number.
	// A name that carries none sorts last, by name.
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		ai, bi := route_index(a), route_index(b)
		return ai != bi ? ai < bi : a < b
	})

	routes := make([]Route, len(names), allocator)
	for name, i in names {
		dir, _ := filepath.join({venue_dir, name}, allocator)
		routes[i] = Route {
			id         = strings.clone(name, allocator),
			dir        = dir,
			registered = seen[name].registered,
			on_disk    = seen[name].on_disk,
			model_id   = seen[name].model_id,
		}
	}
	return routes
}

// Subdirectory names, sorted. Filesystem order is not stable between machines,
// and a venue list that reshuffles per machine is worse than a slightly wrong
// one.
@(private = "file")
read_dirs :: proc(dir: string, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	handle, err := os.open(dir)
	if err != nil {
		return names[:]
	}
	defer os.close(handle)

	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, handle)
	defer os.read_directory_iterator_destroy(&it)
	for info in os.read_directory_iterator(&it) {
		if info.type == .Directory {
			append(&names, strings.clone(info.name, allocator))
		}
	}
	slice.sort(names[:])
	return names[:]
}

// The `n` of `route_n`. Anything else sorts last, which is where `skipfe` — a
// registered route whose name is not `route_N` at all — belongs.
route_index :: proc(id: string) -> int {
	digits := strings.trim_prefix(id, "route_")
	if digits == id || digits == "" {
		return max(int)
	}
	n := 0
	for ch in digits {
		if ch < '0' || ch > '9' {
			return max(int)
		}
		n = n * 10 + int(ch - '0')
	}
	return n
}
