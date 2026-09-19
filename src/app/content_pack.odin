package main

// A content pack: the art a venue builds on, and where each piece of it comes
// from.
//
//     build/content-packs/<id>/
//       pack.json          the manifest below
//       materials.pssg     shaders extracted from the base venue's tracksplit
//       profile.txt        which of those materials each surface draws with
//       local/             files the pack provides itself
//
// Every pack today is **derived**: its id is a stock venue, it owns nothing but
// the extracted shaders, and a deploy hardlinks the stock venue's art. The
// manifest exists so that stops being the only kind. A pack that ships its own
// textures, trees or objects lists them in `local`, and a deploy takes those
// from `local/` and the rest from the base venue.
//
// So the manifest answers one question, for one entry at a time: **does this
// come out of the installed game, or out of the pack?** Nothing else here
// decides that, and nothing else should.
//
// The pack is derived data, never a document. It rebuilds out of whatever
// install the reader has, which is why a venue can be handed to someone else
// with no game file attached. Erasing `content-packs/` costs nothing.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import d3 "../d3"

PACK_FORMAT :: "dirtbench.pack"
PACK_VERSION :: 1
PACK_FILE :: "pack.json"
PACK_LOCAL_DIR :: "local"

// The on-disk shape. Flat and dumb: field names are the JSON keys.
Content_Pack :: struct {
	format:  string,
	version: int,
	id:      string,
	// The stock venue the pack borrows from, as "<location>/<venue>". Empty
	// when the pack stands on its own, which nothing builds yet.
	base:    string,
	// Venue-root entries the pack provides itself. A name here is linked out of
	// `local/` at deploy time and the base venue's copy of it is ignored.
	local:   []string,
}

content_pack_dir :: proc(id: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({content_packs_dir(context.temp_allocator), id}, allocator)
	return joined
}

pack_local_dir :: proc(id: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({content_pack_dir(id, context.temp_allocator), PACK_LOCAL_DIR}, allocator)
	return joined
}

// The manifest, or the derived default for a pack that has none.
//
// A missing manifest is the normal case for a pack this build made before the
// manifest existed, and for one being built right now. It reads as a pack
// derived straight from the stock venue of the same name, which is what every
// pack is today.
pack_manifest :: proc(id: string, allocator := context.temp_allocator) -> Content_Pack {
	path, _ := filepath.join({content_pack_dir(id, context.temp_allocator), PACK_FILE}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return pack_derived(id, allocator)
	}
	pack: Content_Pack
	if uerr := json.unmarshal(data, &pack, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
		return pack_derived(id, allocator)
	}
	if pack.format != PACK_FORMAT || pack.version != PACK_VERSION || pack.id != id {
		pack_free(pack, allocator)
		return pack_derived(id, allocator)
	}
	return pack
}

// A pack with nothing of its own: everything comes from the stock venue its id
// names.
pack_derived :: proc(id: string, allocator := context.temp_allocator) -> Content_Pack {
	return Content_Pack {
		format  = strings.clone(PACK_FORMAT, allocator),
		version = PACK_VERSION,
		id      = strings.clone(id, allocator),
		base    = strings.clone(id, allocator),
		local   = make([]string, 0, allocator),
	}
}

pack_free :: proc(pack: Content_Pack, allocator := context.temp_allocator) {
	delete(pack.format, allocator)
	delete(pack.id, allocator)
	delete(pack.base, allocator)
	for name in pack.local {
		delete(name, allocator)
	}
	delete(pack.local, allocator)
}

pack_write :: proc(pack: Content_Pack) -> (msg: string, ok: bool) {
	dir := content_pack_dir(pack.id)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dir, err), false
	}
	out := pack
	out.format, out.version = PACK_FORMAT, PACK_VERSION
	data, merr := json.marshal(out, {pretty = true, use_spaces = true}, context.temp_allocator)
	if merr != nil {
		return fmt.tprintf("could not encode the content pack: %v", merr), false
	}
	path, _ := filepath.join({dir, PACK_FILE}, context.temp_allocator)
	if werr := os.write_entire_file(path, data); werr != nil {
		return fmt.tprintf("could not write %s: %v", path, werr), false
	}
	return "", true
}

// Whether the pack provides this venue-root entry itself. The one place that
// question is answered: deployment asks it per entry, and a future pack that
// ships art changes only the list, never the caller.
pack_provides :: proc(pack: Content_Pack, name: string) -> bool {
	return slice.contains(pack.local, name)
}

// One line naming the pack a venue builds on, and the stock venue under it when
// those differ. A derived pack names the same thing twice, so it says it once.
pack_text :: proc(id, route: string, allocator := context.temp_allocator) -> string {
	pack := pack_manifest(id)
	if pack.base == id {
		return fmt.tprintf("art from %s/%s", id, route)
	}
	return fmt.tprintf("art from pack %s, on %s/%s", id, pack.base, route)
}

// --- the material pack -------------------------------------------------------

// The pack's shader profile, built out of the install when it is missing or was
// written by an older build of this tool.
//
// The pack is derived, so rebuilding is always safe and is the only answer to a
// pack that does not load. Never repair one in place.
content_pack_profile :: proc(
	vs: ^Install_Scan,
	id: string,
	allocator := context.temp_allocator,
) -> (
	profile: d3.Venue_Profile,
	msg: string,
	ok: bool,
) {
	dir := content_pack_dir(id, context.temp_allocator)
	pack := pack_manifest(id)
	palette := palette_for(pack.base, id, context.temp_allocator)

	// Two things make a pack on disk stale. The stamp covers a change to this
	// tool. The paving texture covers a change to the palette, because that one
	// is cloned into a material inside materials.pssg rather than named in a row
	// — so laying the palette over the profile could not fix it.
	if profile, _, ok = d3.Profile_Load(dir, allocator); ok &&
	   profile.pack == d3.Pack_Stamp && profile.paved_texture == palette.paved_texture {
		palette_over_profile(palette, &profile)
		return profile, "", true
	}
	base_dir := base_venue_dir(vs, pack.base)
	if base_dir == "" {
		return profile, fmt.tprintf(
			"the base venue of %s is not installed, so its shaders cannot be read", id,
		), false
	}
	_, base_id, _ := base_split(pack.base)
	if detail, installed := d3.Pack_Install(base_dir, dir, base_id, palette_art(palette)); !installed {
		return profile, fmt.tprintf("could not read the shaders of %s: %s", pack.base, detail), false
	}
	// The manifest goes down with the shaders, so a pack on disk always says
	// where its art comes from rather than leaving the next reader to assume.
	if write_msg, written := pack_write(pack); !written {
		return profile, write_msg, false
	}
	profile, msg, ok = d3.Profile_Load(dir, allocator)
	if ok { palette_over_profile(palette, &profile) }
	return profile, msg, ok
}
