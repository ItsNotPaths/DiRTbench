package d3

// The graphics template a venue draws with, read out of the base venue's
// `tracksplit.pssg`. One pack per base venue, under `content-packs/`, shared by
// every venue of ours that derives from it.
//
// It holds shader metadata and texture names, never a payload. A SHADERINPUT
// names its texture as `tracksplit.pssg#<name>.tga`, and that resolves against
// the base venue's own file. A synthesized venue tracksplit retains those
// texture payloads, so the pack and its art remain from the same venue.
//
// Read from `tracksplit.pssg`, not from a route's `routesplit.pssg`: kenya and
// norway_trail ship no routesplit at all, and every venue has a tracksplit.
//
// Only `terrain_infield.fx` matches the vertex buffer routesplit.odin writes,
// which is position, colour, half2 ST and half4 normal. Every stock
// `terrain_road.fx` draw call adds a second ST set, a tangent and a binormal,
// so a road shader taken from that group reads streams we never fill.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

D3_PACK_SURFACE_GROUP :: "terrain_infield.fx"
D3_PACK_LOD_GROUP :: "terrain_lod.fx"
D3_PACK_BATCH_GROUP :: "batched_track.fx"

// A pack is metadata. Anything near this size means a payload came with it.
D3_PACK_MAX :: 256*1024

// The five libraries a stock `routesplit.pssg` holds, in its order. A
// tracksplit can carry more, and carrying those through would give us an output
// file that no stock route resembles.
d3_pack_libraries := [?]string{
	"SHADERINSTANCE",
	"SHADERGROUP",
	"SEGMENTSET",
	"RENDERINTERFACEBOUND",
	"NODE",
}

d3_unref :: proc(id: string) -> string {
	return strings.has_prefix(id, "#") ? id[1:] : id
}

// `grass_01!2` is `grass_01` again, in another tile.
d3_shader_base :: proc(id: string) -> string {
	at := strings.last_index_byte(id, '!')
	if at < 0 || at == len(id)-1 { return id }
	for c in id[at+1:] { if c < '0' || c > '9' { return id } }
	return id[:at]
}

// --- the cliff material ------------------------------------------------------
//
// No venue ships a surface material for a rock face. Stock rock lives in
// `terrain_rockbank.fx`, and that group reads a tangent and a binormal our
// vertex buffer never fills. So the cliff material is made rather than found:
// the venue's own infield shader, with both its diffuse layers repointed at the
// venue's rock art.
//
// It is made twice, once into the pack and once into the installed venue
// tracksplit. A route's draw calls name it, and a name no instance answers to
// draws nothing and says nothing.

D3_CLIFF_MATERIAL :: "dirtbench_cliff"
D3_PAVED_MATERIAL :: "dirtbench_paved"

// What a base venue's own art cannot say for itself, and so comes from the
// content pack's palette instead.
//
// A tarmac texture cannot be found by name. Codemasters number their road
// textures rather than describing them, so `fin_tra_bas_13_d` (tarmac) reads
// exactly like `fin_tra_bas_01_d` (gravel), and searching shader instance names
// for "tarmac" finds nothing in finland_rally, norway, michigan or moosylvania —
// Finland keeps its tarmac materials in a *route* file, not in the tracksplit
// this reads. Rock got away with a name rule; paving does not.
//
// An empty texture is not a failure. The paved road then draws with the loose
// road's material and differs only in its collision code, which is still a real
// tarmac surface to drive on.
D3_Pack_Art :: struct {
	paved_texture: string,
}

// The two diffuse layers of `terrain_infield.fx`. A parameter id belongs to the
// shader group, not to the venue, so these hold everywhere — measured over all
// nine base-eligible tracksplits. Both layers take the same texture, which
// leaves the blend map between them nothing to decide.
d3_infield_diffuse := [?]u32{0x0c, 0x15}

// Rock art, by Codemasters' own texture naming: `rck` is rock, `fea` is a
// terrain feature, `_d` is the diffuse of the set. Every stock venue holds one,
// and Kenya's own infield materials draw with them, so the shader takes one.
d3_rock_words := [?]string{"_rck_", "_fea_", "rock"}

d3_texture_ids :: proc(file: ^Pssg_File, node: ^Pssg_Node, out: ^[dynamic]string) {
	if node.name == "TEXTURE" {
		if id := pssg_attr_string(file, node, "id"); id != "" { append(out, id) }
	}
	for child in node.children { d3_texture_ids(file, child, out) }
}

// The first naming that matches, and the lowest name under it, so one venue
// always yields the same cliff.
d3_rock_texture :: proc(file: ^Pssg_File, allocator: mem.Allocator) -> string {
	ids := make([dynamic]string, allocator)
	d3_texture_ids(file, file.root, &ids)
	for word in d3_rock_words {
		best := ""
		for id in ids {
			lower := strings.to_lower(id, allocator)
			if !strings.has_suffix(lower, "_d.tga") || !strings.contains(lower, word) { continue }
			if best == "" || id < best { best = id }
		}
		if best != "" { return best }
	}
	return ""
}

// Clone `donor_id` under `name`, repoint both its diffuse layers at `texture`,
// and hang it in the shader instance library beside the material it came from.
// Returns the name for the profile, or "" when the clone could not be made.
//
// DiRT 3 ships no shader we can bind that draws rock or tarmac, so both are made
// this way rather than found. Both layers take the same texture, which leaves the
// blend map between them nothing to decide — see docs/dirt3-pssg.md for what the
// two layers are and what mixes them.
d3_surface_material :: proc(
	file: ^Pssg_File,
	instances: ^Pssg_Node,
	donor_id, name, texture: string,
	allocator: mem.Allocator,
) -> string {
	donor := pssg_walk_first_by_id(file, instances, "SHADERINSTANCE", donor_id)
	if donor == nil || texture == "" { return "" }

	clone := pssg_clone_node(donor, allocator)
	if !pssg_set_attr_string(file, clone, "id", name, allocator) { return "" }
	// Local form, as a tracksplit names its own textures. The pack requalifies
	// every reference it keeps, this one with the rest.
	local := strings.concatenate({"#", texture}, allocator)
	painted := 0
	for input in clone.children {
		id, known := pssg_attr_u32(file, input, "parameterID")
		if !known || !slice.contains(d3_infield_diffuse[:], id) { continue }
		if pssg_set_attr_string(file, input, "texture", local, allocator) { painted += 1 }
	}
	if painted != len(d3_infield_diffuse) { return "" }
	append(&instances.children, clone)
	return name
}

d3_cliff_material :: proc(
	file: ^Pssg_File,
	instances: ^Pssg_Node,
	donor_id: string,
	allocator: mem.Allocator,
) -> string {
	rock := d3_rock_texture(file, allocator)
	return d3_surface_material(file, instances, donor_id, D3_CLIFF_MATERIAL, rock, allocator)
}

d3_pack_source_sizes :: proc(file: ^Pssg_File, node: ^Pssg_Node, out: ^map[string]u64) {
	if node.name == "RENDERDATASOURCE" {
		id := pssg_attr_string(file, node, "id")
		for child in node.children {
			if child.name != "RENDERINDEXSOURCE" { continue }
			if count, known := pssg_attr_u32(file, child, "count"); known { out[id] += u64(count) }
		}
	}
	for child in node.children { d3_pack_source_sizes(file, child, out) }
}

d3_pack_shader_use :: proc(file: ^Pssg_File, node: ^Pssg_Node, sources, out: ^map[string]u64) {
	if node.name == "RENDERSTREAMINSTANCE" {
		shader := d3_unref(pssg_attr_string(file, node, "shader"))
		out[shader] += sources[d3_unref(pssg_attr_string(file, node, "indices"))]
	}
	for child in node.children { d3_pack_shader_use(file, child, sources, out) }
}

D3_Pack_Pick :: struct {
	id:   string,
	uses: u64,
}

// Instances of one shader group, most-drawn first. How much ground a material
// covers is the only ranking the file offers. Ties break on id, so one venue
// always yields the same pack.
d3_pack_rank :: proc(
	file: ^Pssg_File,
	instances: ^Pssg_Node,
	group: string,
	uses: ^map[string]u64,
	allocator: mem.Allocator,
) -> []D3_Pack_Pick {
	out := make([dynamic]D3_Pack_Pick, allocator)
	for child in instances.children {
		if child.name != "SHADERINSTANCE" { continue }
		if d3_unref(pssg_attr_string(file, child, "shaderGroup")) != group { continue }
		id := pssg_attr_string(file, child, "id")
		if id == "" { continue }
		append(&out, D3_Pack_Pick{id, uses[id]})
	}
	slice.sort_by(out[:], proc(a, b: D3_Pack_Pick) -> bool {
		return a.uses != b.uses ? a.uses > b.uses : a.id < b.id
	})
	return out[:]
}

// True when this subtree names a node type the pack has not kept yet. A TEXTURE
// never counts: it is megabytes of art and the pack carries names, not payload.
d3_pack_adds :: proc(node: ^Pssg_Node, have: ^map[string]bool) -> bool {
	if node.name == "TEXTURE" { return false }
	if node.name not_in have { return true }
	for child in node.children { if d3_pack_adds(child, have) { return true } }
	return false
}

// The pack exists to donate type ids, and `pssg_types` reads those off real
// nodes rather than off the schema. So keep the smallest set of subtrees that
// still names every node type, and drop everything else.
//
// Keeping the first child of each name is not enough. Finland's first scene
// node holds nothing but a transform and a box, and that rule follows it and
// loses every RENDERNODE in the venue.
d3_pack_thin :: proc(node: ^Pssg_Node, have: ^map[string]bool, allocator: mem.Allocator) {
	have[node.name] = true
	kept := make([dynamic]^Pssg_Node, allocator)
	for child in node.children {
		if !d3_pack_adds(child, have) { continue }
		d3_pack_thin(child, have, allocator)
		append(&kept, child)
	}
	clear(&node.children)
	append(&node.children, ..kept[:])
	switch node.name {
	case "DATABLOCKDATA", "INDEXSOURCEDATA", "TEXTUREIMAGEBLOCKDATA":
		node.data = nil
		node.data_owned = false
	}
}

// A tracksplit names its own textures locally, as `#name.tga`. A routesplit
// names them across files, and every stock one does: all 1531 references in
// Finland route_1 read `tracksplit.pssg#name.tga`. Carrying the local form into
// our routesplit leaves every texture reference pointing at nothing, which
// draws nothing and says nothing.
d3_pack_requalify :: proc(file: ^Pssg_File, node: ^Pssg_Node, allocator: mem.Allocator) {
	if node.name == "SHADERINPUT" {
		texture := pssg_attr_string(file, node, "texture")
		if strings.has_prefix(texture, "#") {
			qualified := strings.concatenate({"tracksplit.pssg", texture}, allocator)
			_ = pssg_set_attr_string(file, node, "texture", qualified, allocator)
		}
	}
	for child in node.children { d3_pack_requalify(file, child, allocator) }
}

// One road triangle and one terrain triangle, with no degenerate axis. Building
// a route out of this is the pack's acceptance test.
d3_pack_probe_mesh :: proc(allocator := context.temp_allocator) -> []Collision_Triangle {
	out := make([]Collision_Triangle, 2, allocator)
	out[0] = {Points = {{0, 0, 0}, {10, 0, 0}, {0, 1, 10}}, Material = .Road}
	out[1] = {Points = {{10, 0, 0}, {10, 1, 10}, {0, 1, 10}}, Material = .Terrain}
	return out
}

// Extract the pack and the profile that names its materials. `base_id` becomes
// the profile's `default` key, so the file says which base venue it came out of.
d3_pack_build :: proc(
	tracksplit: []u8,
	base_id: string,
	art: D3_Pack_Art,
	allocator := context.allocator,
) -> (
	pack: []u8,
	profile_text: string,
	msg: string,
	ok: bool,
) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return nil, "", "could not reserve memory for the Dirt 3 material pack", false
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	file, read_msg, read_ok := pssg_read(tracksplit, scratch)
	if !read_ok { return nil, "", read_msg, false }

	libraries := make(map[string]^Pssg_Node, scratch)
	for child in file.root.children {
		if child.name != "LIBRARY" { continue }
		kind := pssg_attr_string(&file, child, "type")
		if kind not_in libraries { libraries[kind] = child }
	}
	for kind in d3_pack_libraries {
		if kind not_in libraries {
			return nil, "", fmt.tprintf("the base venue's tracksplit.pssg has no %s library", kind), false
		}
	}

	sources := make(map[string]u64, scratch)
	d3_pack_source_sizes(&file, file.root, &sources)
	uses := make(map[string]u64, scratch)
	d3_pack_shader_use(&file, file.root, &sources, &uses)

	instances := libraries["SHADERINSTANCE"]
	surface := d3_pack_rank(&file, instances, D3_PACK_SURFACE_GROUP, &uses, scratch)
	lod := d3_pack_rank(&file, instances, D3_PACK_LOD_GROUP, &uses, scratch)
	batch := d3_pack_rank(&file, instances, D3_PACK_BATCH_GROUP, &uses, scratch)
	if len(surface) == 0 || len(lod) == 0 || len(batch) == 0 {
		return nil, "", fmt.tprintf(
			"the base venue holds %d %s, %d %s and %d %s materials, and it needs one of each",
			len(surface), D3_PACK_SURFACE_GROUP,
			len(lod), D3_PACK_LOD_GROUP,
			len(batch), D3_PACK_BATCH_GROUP,
		), false
	}

	// Colours, collision codes and the tile grid are ours. The base venue
	// decides only which shaders name its art.
	profile := d3_profile_defaults()
	profile.id = base_id
	profile.lod = lod[0].id
	profile.batch = batch[0].id
	// The largest surface material drives the road, and the largest one with a
	// different name drives the terrain. Most venues offer one or two, so this
	// degrades to every material sharing a shader rather than to a failure.
	road := surface[0].id
	ground := road
	for pick in surface {
		if d3_shader_base(pick.id) != d3_shader_base(road) { ground = pick.id; break }
	}
	// The cliff draws with rock the venue already owns. Failing that, any third
	// surface material still beats cutting the cliff out of the road's gravel,
	// and a venue offering two materials has no choice but the road.
	cliff := d3_cliff_material(&file, instances, road, scratch)
	if cliff == "" {
		cliff = road
		for pick in surface {
			base := d3_shader_base(pick.id)
			if base != d3_shader_base(road) && base != d3_shader_base(ground) { cliff = pick.id; break }
		}
	}
	// The paved road is made from the palette's texture. With none, it falls
	// back to the loose road's material: right grip, wrong paint, still useful.
	paved := d3_surface_material(&file, instances, road, D3_PAVED_MATERIAL, art.paved_texture, scratch)
	if paved == "" { paved = road }

	for material in Collision_Material { profile.visual[material] = road }
	profile.visual[.Terrain] = ground
	profile.visual[.Cliff] = cliff
	profile.visual[.Road_Paved] = paved
	profile.paved_texture = art.paved_texture

	wanted := make(map[string]bool, scratch)
	for material in Collision_Material { wanted[profile.visual[material]] = true }
	wanted[profile.lod] = true
	wanted[profile.batch] = true

	kept_instances := make([dynamic]^Pssg_Node, scratch)
	groups := make(map[string]bool, scratch)
	for child in instances.children {
		if child.name != "SHADERINSTANCE" { continue }
		if !wanted[pssg_attr_string(&file, child, "id")] { continue }
		d3_pack_requalify(&file, child, scratch)
		append(&kept_instances, child)
		groups[d3_unref(pssg_attr_string(&file, child, "shaderGroup"))] = true
	}
	kept_groups := make([dynamic]^Pssg_Node, scratch)
	for child in libraries["SHADERGROUP"].children {
		if child.name != "SHADERGROUP" { continue }
		if groups[pssg_attr_string(&file, child, "id")] { append(&kept_groups, child) }
	}

	ordered := make([dynamic]^Pssg_Node, scratch)
	kept_types := make(map[string]bool, scratch)
	for kind in d3_pack_libraries {
		library := libraries[kind]
		switch kind {
		case "SHADERINSTANCE":
			clear(&library.children)
			append(&library.children, ..kept_instances[:])
		case "SHADERGROUP":
			clear(&library.children)
			append(&library.children, ..kept_groups[:])
		case:
			d3_pack_thin(library, &kept_types, scratch)
		}
		append(&ordered, library)
	}
	clear(&file.root.children)
	append(&file.root.children, ..ordered[:])

	encoded, written := pssg_write(&file, allocator)
	if !written { return nil, "", "could not encode the Dirt 3 material pack", false }
	if len(encoded) > D3_PACK_MAX {
		delete(encoded, allocator)
		return nil, "", fmt.tprintf(
			"the Dirt 3 material pack came out at %d bytes, so a payload survived the trim",
			len(encoded),
		), false
	}

	// Building a route out of the pack is the whole acceptance test. It fails
	// unless every node type and every attribute id the exporter needs survived.
	profile.template = encoded
	probe, probe_msg, probe_ok := d3_routesplit_build(
		d3_pack_probe_mesh(),
		&profile,
		context.temp_allocator,
	)
	if !probe_ok {
		delete(encoded, allocator)
		return nil, "", fmt.tprintf("the Dirt 3 material pack is incomplete: %s", probe_msg), false
	}
	delete(probe, context.temp_allocator)

	return encoded, strings.clone(d3_profile_text(profile, context.temp_allocator), allocator), "", true
}

// --- the pack on disk ---------------------------------------------------------

d3_profile_save :: proc(dir: string, pack: []u8, profile_text: string) -> (msg: string, ok: bool) {
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return fmt.tprintf("could not create %s: %v", dir, err), false
	}
	materials, _ := filepath.join({dir, D3_MATERIALS_FILE}, context.temp_allocator)
	if write_msg, written := atomic_write_file(materials, pack); !written { return write_msg, false }
	profile, _ := filepath.join({dir, D3_PROFILE_FILE}, context.temp_allocator)
	return atomic_write_file(profile, transmute([]u8)profile_text)
}

d3_profile_load :: proc(
	dir: string,
	allocator := context.temp_allocator,
) -> (
	profile: D3_Venue_Profile,
	msg: string,
	ok: bool,
) {
	materials, _ := filepath.join({dir, D3_MATERIALS_FILE}, context.temp_allocator)
	pack, pack_err := os.read_entire_file(materials, allocator)
	if pack_err != nil {
		return profile, fmt.tprintf("could not read %s: %v", materials, pack_err), false
	}
	path, _ := filepath.join({dir, D3_PROFILE_FILE}, context.temp_allocator)
	text, text_err := os.read_entire_file(path, context.temp_allocator)
	if text_err != nil {
		return profile, fmt.tprintf("could not read %s: %v", path, text_err), false
	}
	return d3_profile_parse(string(text), pack, allocator)
}

d3_tracksplit_path :: proc(base_dir: string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({base_dir, "tracksplit.pssg"}, allocator)
	return joined
}

// Extract straight to a profile, writing nothing. This is how a stage exported
// over a stock route draws with that venue's own shaders.
d3_pack_profile :: proc(
	base_dir, base_id: string,
	art: D3_Pack_Art,
	allocator := context.temp_allocator,
) -> (
	profile: D3_Venue_Profile,
	msg: string,
	ok: bool,
) {
	source := d3_tracksplit_path(base_dir)
	tracksplit, read_err := os.read_entire_file(source, context.temp_allocator)
	if read_err != nil {
		return profile, fmt.tprintf("could not read %s: %v", source, read_err), false
	}
	pack, text, build_msg, built := d3_pack_build(tracksplit, base_id, art, allocator)
	if !built { return profile, build_msg, false }
	return d3_profile_parse(text, pack, allocator)
}

// One call to build a content pack: read the base venue's tracksplit, extract
// the pack, and write both files into `dir`.
d3_pack_install :: proc(base_dir, dir, base_id: string, art: D3_Pack_Art) -> (msg: string, ok: bool) {
	source := d3_tracksplit_path(base_dir)
	tracksplit, read_err := os.read_entire_file(source, context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read %s: %v", source, read_err), false
	}
	pack, profile_text, build_msg, built := d3_pack_build(tracksplit, base_id, art, context.temp_allocator)
	if !built { return build_msg, false }
	if save_msg, saved := d3_profile_save(dir, pack, profile_text); !saved { return save_msg, false }
	return fmt.tprintf("%d byte material pack from %s", len(pack), source), true
}
