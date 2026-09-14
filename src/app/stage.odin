package main

// Stage save/load — the editor's own working format, not an export.
//
// A stage is the spline and nothing else: the control points, each with its
// world position, road frame (as a quaternion) and width. Everything the
// viewport draws is derived from these (see geo/spline.odin), so this round-trips
// the whole document.
//
// This is deliberately *not* any export format. Export goes spline -> ribbon
// mesh -> a per-game target (see export.odin) and lands in `out/`. Stages live
// in `maps/`, next to the executable.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../geo"

STAGE_FORMAT :: "dirtbench.stage"
// The names this format carried in stagesculpt / tm-rallysculpt. Still accepted
// on load, so a stage saved by either of those keeps opening here.
STAGE_FORMAT_LEGACY :: "stagesculpt.stage"
STAGE_FORMAT_LEGACY_2 :: "tm-rallysculpt.stage"
// v2 added per-point cliffs; v3 added the per-point roughness offset; v4 added the
// stage-global vegetation block; v5 added timing markers. Older files still load: a missing field unmarshals
// to zero, which is the correct default (no cliff / no roughness offset / veg off).
// v6 added the parent index and v7 the weld. Both are read behind a version
// check, because zero is a valid point index and would silently mean "point 0".
STAGE_VERSION :: 7
STAGE_EXT :: ".json"

// The on-disk shape. Kept flat and dumb: field names are the JSON keys, and a
// quaternion is four floats because core:encoding/json cannot marshal Odin's
// quaternion type.
Stage_Point :: struct {
	parent:      int,
	// Second edge out of this point, closing a loop (v7). -1 for none.
	weld:        int,
	pos:         [3]f32,
	rot:         [4]f32, // x, y, z, w
	width:       f32,
	// Cliffs (v2). Absent in a v1 file, where they unmarshal to zero — which
	// means "no cliff", so old stages load unchanged.
	cliff_l:     f32,
	cliff_r:     f32,
	span_l:      f32,
	span_r:      f32,
	cliff_taper: f32,
	cliff_angle: f32, // degrees off vertical; + leans away from the road
	// Roughness offset (v3). Absent in v1/v2 files, where it unmarshals to zero —
	// i.e. no per-node offset, so the stage rides at the global roughness.
	roughness:   f32,
}

// The stage-global vegetation block (v4). Absent in older files, where every field
// unmarshals to zero — enabled=false, so an old stage simply carries no vegetation
// until the user turns it on, at which point the defaults below fill in.
Stage_Veg :: struct {
	enabled:   bool,
	preset:    i32, // Veg_Preset ordinal
	density:   f32,
	road_bias: f32,
	seed:      i32,
}

Stage_Timing :: struct {
	checkpoint_count: i32,
	buffer_m: f32,
}

Stage_File :: struct {
	format:  string,
	version: int,
	name:    string,
	points:  []Stage_Point,
	veg:     Stage_Veg,
	timing:  Stage_Timing,
}

// --- paths ------------------------------------------------------------------

// `maps/` sits next to the executable, so a release build and a dev build each
// see their own stages. release.sh seeds the release copy with the demo stage.
maps_dir :: proc(allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join({exe_dir(), "maps"}, allocator)
	return joined
}

// Create maps/ if it is not there yet. An already-existing directory is the
// expected case, not an error.
ensure_maps_dir :: proc() -> (dir: string, ok: bool) {
	dir = maps_dir()
	if os.exists(dir) {
		return dir, true
	}
	if err := os.make_directory(dir); err != nil && err != os.General_Error.Exist {
		return dir, false
	}
	return dir, true
}

stage_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	file := strings.concatenate({name, STAGE_EXT}, context.temp_allocator)
	joined, _ := filepath.join({maps_dir(), file}, allocator)
	return joined
}

// Stage names become filenames, so keep them to something a filesystem and a
// menu can both hold. Empty -> "untitled"; separators and spaces -> '-'.
sanitise_stage_name :: proc(raw: string, allocator := context.temp_allocator) -> string {
	trimmed := strings.trim_space(raw)
	if trimmed == "" {
		return strings.clone("untitled", allocator)
	}
	b := strings.builder_make(allocator)
	for r in trimmed {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', ' ':
			strings.write_rune(&b, '-')
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// --- conversion -------------------------------------------------------------

quat_to_array :: proc(q: rl.Quaternion) -> [4]f32 {
	return {q.x, q.y, q.z, q.w}
}

quat_from_array :: proc(a: [4]f32) -> rl.Quaternion {
	q := quaternion(x = a[0], y = a[1], z = a[2], w = a[3])
	// Guard against a hand-edited or truncated file: a zero/denormal quaternion
	// would make every derived road frame NaN.
	if abs(q) < 1e-6 {
		return rl.Quaternion(1)
	}
	return rl.QuaternionNormalize(q)
}

// --- save / load ------------------------------------------------------------

// Writes maps/<name>.json. Returns a message fit for the status line.
save_stage :: proc(sp: geo.Spline, name: string, veg := geo.VEG_DEFAULTS, timing:=TIMING_DEFAULTS) -> (msg: string, ok: bool) {
	if _, dir_ok := ensure_maps_dir(); !dir_ok {
		return fmt.tprintf("could not create %s", maps_dir()), false
	}
	if msg, ok = save_stage_to(sp, stage_path(name), veg, timing); !ok {
		return
	}
	return fmt.tprintf("saved %d points to maps/%s%s", len(sp.points), name, STAGE_EXT), true
}

// The same document, at a path the caller chose. A venue's stages live under
// `venues/<id>/stages/`, not in `maps/`.
save_stage_to :: proc(sp: geo.Spline, path: string, veg := geo.VEG_DEFAULTS, timing:=TIMING_DEFAULTS) -> (msg: string, ok: bool) {
	if len(sp.points) < 2 {
		return "nothing to save: a stage needs at least 2 points", false
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
			return fmt.tprintf("could not create %s: %v", dir, err), false
		}
	}

	pts := make([]Stage_Point, len(sp.points), context.temp_allocator)
	for p, i in sp.points {
		pts[i] = Stage_Point {
			parent      = p.parent,
			weld        = p.weld,
			pos         = {p.xform.translation.x, p.xform.translation.y, p.xform.translation.z},
			rot         = quat_to_array(p.xform.rotation),
			width       = p.width,
			cliff_l     = p.cliff_l,
			cliff_r     = p.cliff_r,
			span_l      = p.span_l,
			span_r      = p.span_r,
			cliff_taper = p.cliff_taper,
			cliff_angle = p.cliff_angle,
			roughness   = p.roughness,
		}
	}

	stage := Stage_File {
		format  = STAGE_FORMAT,
		version = STAGE_VERSION,
		name    = filepath.short_stem(filepath.base(path)),
		points  = pts,
		veg     = {
			enabled   = veg.enabled,
			preset    = i32(veg.preset),
			density   = veg.density,
			road_bias = veg.road_bias,
			seed      = i32(veg.seed),
		},
		timing = {checkpoint_count=i32(timing.checkpoint_count),buffer_m=timing.buffer_m},
	}
	data, merr := json.marshal(stage, {pretty = true, use_spaces = true}, context.temp_allocator)
	if merr != nil {
		return fmt.tprintf("could not encode stage: %v", merr), false
	}

	if werr := os.write_entire_file(path, data); werr != nil {
		return fmt.tprintf("could not write %s: %v", path, werr), false
	}
	return "", true
}

// Replaces `sp`'s points with the file's on success, and leaves them untouched
// on any failure — a bad file must not destroy the spline in the editor. When
// `veg` is non-nil it receives the stage's vegetation block, or VEG_DEFAULTS for a
// pre-v4 file that predates it.
load_stage :: proc(sp: ^geo.Spline, name: string, veg: ^geo.Veg_Params = nil, timing:^Timing_Params=nil) -> (msg: string, ok: bool) {
	return load_stage_from(sp, stage_path(name), veg, timing)
}

// The same document, from a path the caller chose. See save_stage_to.
load_stage_from :: proc(sp: ^geo.Spline, path: string, veg: ^geo.Veg_Params = nil, timing:^Timing_Params=nil) -> (msg: string, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return fmt.tprintf("could not read %s: %v", path, rerr), false
	}

	stage: Stage_File
	if uerr := json.unmarshal(data, &stage, json.DEFAULT_SPECIFICATION, context.temp_allocator);
	   uerr != nil {
		return fmt.tprintf("could not parse %s: %v", path, uerr), false
	}
	switch stage.format {
	case STAGE_FORMAT, STAGE_FORMAT_LEGACY, STAGE_FORMAT_LEGACY_2:
	case:
		return fmt.tprintf("not a stage file (format %q)", stage.format), false
	}
	if stage.version > STAGE_VERSION {
		return fmt.tprintf("stage version %d is newer than this build (%d)", stage.version, STAGE_VERSION), false
	}
	if len(stage.points) < 2 {
		return fmt.tprintf("stage has %d points, needs at least 2", len(stage.points)), false
	}
	if stage.version >= 6 {
		for p, i in stage.points {
			if p.parent < -1 || p.parent >= i {
				return fmt.tprintf("road point %d has invalid parent %d", i, p.parent), false
			}
		}
	}
	if stage.version >= 7 {
		// A weld may point forward, unlike a parent. It may not point at itself,
		// which would sample an edge of zero length.
		for p, i in stage.points {
			if p.weld < -1 || p.weld >= len(stage.points) || p.weld == i {
				return fmt.tprintf("road point %d has invalid weld %d", i, p.weld), false
			}
		}
	}

	// A v1 file carries no cliff fields, so they unmarshal to zero. Zero height
	// is what we want (no cliffs), but a zero span/taper would leave the point's
	// cliff sliders inert until the user also found the span slider. Give v1
	// points the defaults instead. In a v2 file a zero span is a deliberate
	// "no cliff on this side" and must be preserved.
	legacy := stage.version < 2

	clear(&sp.points)
	for p, i in stage.points {
		width := p.width if p.width > 0 else f32(geo.DEFAULT_WIDTH)
		span_l := f32(geo.DEFAULT_CLIFF_SPAN) if legacy else p.span_l
		span_r := f32(geo.DEFAULT_CLIFF_SPAN) if legacy else p.span_r
		taper := p.cliff_taper if p.cliff_taper > 0 else f32(geo.DEFAULT_CLIFF_TAPER)
		angle := f32(geo.DEFAULT_CLIFF_ANGLE) if legacy else p.cliff_angle
		append(
			&sp.points,
			geo.make_point(
				{p.pos[0], p.pos[1], p.pos[2]},
				quat_from_array(p.rot),
				width,
				p.cliff_l,
				p.cliff_r,
				span_l,
				span_r,
				taper,
				angle,
				// v1/v2 files have no roughness field, so p.roughness is 0 there —
				// exactly the "no per-node offset" default we want.
				p.roughness,
				p.parent if stage.version >= 6 else i - 1,
			),
		)
		sp.points[len(sp.points)-1].weld = p.weld if stage.version >= 7 else -1
	}

	if veg != nil {
		if stage.version < 4 {
			veg^ = geo.VEG_DEFAULTS // predates the block; start it off, with sane knobs
		} else {
			preset := geo.Veg_Preset(clamp(stage.veg.preset, i32(min(geo.Veg_Preset)), i32(max(geo.Veg_Preset))))
			veg^ = geo.Veg_Params {
				enabled   = stage.veg.enabled,
				preset    = preset,
				density   = stage.veg.density,
				road_bias = stage.veg.road_bias,
				seed      = c.int(stage.veg.seed),
			}
		}
	}
	if timing!=nil {
		if stage.version<5 { timing^=TIMING_DEFAULTS } else {
			timing^={checkpoint_count=c.int(clamp(stage.timing.checkpoint_count,0,20)),buffer_m=clamp(stage.timing.buffer_m,f32(0),f32(500))}
		}
	}
	return fmt.tprintf("loaded %d points from %s", len(sp.points), filepath.base(path)), true
}

// Stage names (no extension) found in maps/, for the Load menu. Temp-allocated.
list_stages :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	dir, ok := ensure_maps_dir()
	if !ok {
		return out[:]
	}
	f, oerr := os.open(dir)
	if oerr != nil {
		return out[:]
	}
	defer os.close(f)

	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, f)
	defer os.read_directory_iterator_destroy(&it)

	for fi in os.read_directory_iterator(&it) {
		if fi.type == .Directory || filepath.ext(fi.name) != STAGE_EXT {
			continue
		}
		// fi.name is only valid until the iterator advances.
		stem := strings.trim_suffix(fi.name, STAGE_EXT)
		append(&out, strings.clone(stem, context.temp_allocator))
	}
	return out[:]
}
