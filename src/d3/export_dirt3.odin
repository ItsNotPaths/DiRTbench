package d3

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// A replacement is always written as a new inode and renamed over the old
// directory entry. Deployed venues begin as hardlinks to stock art; truncating
// one of those paths would truncate the stock file too.
atomic_write_file :: proc(path: string, data: []u8) -> (msg: string, ok: bool) {
	dir := filepath.dir(path)
	pattern := fmt.tprintf(".%s.dirtbench-*", filepath.base(path))
	file, create_err := os.create_temp_file(dir, pattern)
	if create_err != nil {
		return fmt.tprintf(
			"could not create temporary file for %s: %v",
			path,
			create_err,
		), false
	}
	info, stat_err := os.fstat(file, context.temp_allocator)
	if stat_err != nil {
		_ = os.close(file)
		return fmt.tprintf("could not inspect temporary file for %s: %v", path, stat_err), false
	}
	temporary := info.fullpath
	defer if os.exists(temporary) {
		_ = os.remove(temporary)
	}
	written, write_err := os.write(file, data)
	if write_err == nil && written != len(data) {
		write_err = os.General_Error.Invalid_File
	}
	if write_err == nil {
		write_err = os.sync(file)
	}
	close_err := os.close(file)
	if write_err != nil {
		return fmt.tprintf(
			"could not write temporary file for %s: %v",
			path,
			write_err,
		), false
	}
	if close_err != nil {
		return fmt.tprintf(
			"could not close temporary file for %s: %v",
			path,
			close_err,
		), false
	}
	if rename_err := os.rename(temporary, path); rename_err != nil {
		return fmt.tprintf(
			"could not replace %s atomically: %v",
			path,
			rename_err,
		), false
	}
	return "", true
}

d3_collision_build :: proc(
	collision: []Collision_Triangle,
	profile: ^D3_Venue_Profile,
	allocator := context.allocator,
) -> (
	data: []u8,
	msg: string,
	ok: bool,
) {
	if len(collision) == 0 {
		return nil, "Dirt 3 export needs collision triangles", false
	}
	input := make([]D3_Write_Tri, len(collision), context.temp_allocator)
	for triangle, i in collision {
		input[i] = {
			p = triangle.Points,
			mat = profile.collision[triangle.Surface],
		}
	}
	return d3_track_write(input, allocator)
}

// Every Dirt 3 file lands directly in `job.Out`, which the caller has already
// made. A route directory is the output directory when installing.
d3_out_dir :: proc(job: ^Export_Job) -> (dir: string, msg: string, ok: bool) {
	if job.Out == "" {
		return "", "export has no output directory", false
	}
	if err := os.make_directory_all(job.Out); err != nil && err != os.General_Error.Exist {
		return "", fmt.tprintf("could not create %s: %v", job.Out, err), false
	}
	return job.Out, "", true
}

// Copy `path` to `path.orig` before it is overwritten, once. An existing
// `.orig` is the stock file and is never touched again: a second export would
// otherwise save our previous output as the thing to revert to.
d3_backup_once :: proc(path: string) -> (msg: string, ok: bool) {
	saved := fmt.tprintf("%s.orig", path)
	if !os.exists(path) || os.exists(saved) {
		return "", true
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("could not read %s to back it up: %v", path, read_err), false
	}
	if write_err := os.write_entire_file(saved, data); write_err != nil {
		return fmt.tprintf("could not write %s: %v", saved, write_err), false
	}
	return "", true
}

// The stock form of a file we overwrite: its `.orig` backup once one exists,
// otherwise whatever is still in place, which on a first export is the base
// venue's own. Empty when neither is there.
//
// Every generated file that reads the art it is replacing goes through this:
// a second export must read the donor, never its own previous output.
d3_stock_path :: proc(dir, name: string) -> string {
	live, _ := filepath.join({dir, name}, context.temp_allocator)
	if saved := fmt.tprintf("%s.orig", live); os.exists(saved) {
		return saved
	}
	if os.exists(live) {
		return live
	}
	return ""
}

d3_write_out :: proc(
	job: ^Export_Job,
	name: string,
	data: []u8,
) -> (
	msg: string,
	ok: bool,
) {
	dir, dir_msg, dir_ok := d3_out_dir(job)
	if !dir_ok {
		return dir_msg, false
	}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if job.Backup {
		if backup_msg, backed_up := d3_backup_once(path); !backed_up {
			return backup_msg, false
		}
	}
	return atomic_write_file(path, data)
}

d3_write_collision :: proc(job: ^Export_Job, profile: ^D3_Venue_Profile) -> (msg: string, ok: bool) {
	data, detail, built := d3_collision_build(job.Collision, profile)
	if !built {
		return detail, false
	}
	defer delete(data)
	if write_msg, written := d3_write_out(job, "track.jpk", data); !written {
		return write_msg, false
	}
	return detail, true
}

// A route inside a derived venue starts as a hardlink of the base route's own
// files, including these two off-track quadtrees. Both describe the *old*
// road; `resetlines.cqtc` is the out-of-bounds test, so a stale copy of it
// keyed to the donor's real-world position can reset the car onto ground that
// does not exist here rather than back onto ours — which looks exactly like
// falling through the floor, and is not a collision-archive bug at all. The
// game tolerates both files being absent outright, so omit rather than stub.
D3_OMITTED_ROUTE_FILES :: []string{"resetlines.cqtc", "boundarylines.cqtc"}

d3_omit_stale_route_files :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	dir, dir_msg, dir_ok := d3_out_dir(job)
	if !dir_ok {
		return dir_msg, false
	}
	removed := make([dynamic]string, context.temp_allocator)
	for name in D3_OMITTED_ROUTE_FILES {
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		if !os.exists(path) {
			continue
		}
		if job.Backup {
			if backup_msg, backed_up := d3_backup_once(path); !backed_up {
				return backup_msg, false
			}
		}
		if err := os.remove(path); err != nil {
			return fmt.tprintf("could not omit %s: %v", path, err), false
		}
		append(&removed, name)
	}
	if len(removed) == 0 {
		return "nothing stale to omit", true
	}
	return fmt.tprintf("omitted %s", strings.join(removed[:], ", ", context.temp_allocator)), true
}

// Every file that names a shader needs the venue's own profile. Without one
// there is no honest answer to "whose art is this", so the export refuses
// rather than reaching for a fixture the player does not have.
export_dirt3 :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	if job.Profile == nil {
		return "this export needs a venue, so it knows whose shaders the stage draws with", false
	}
	profile := job.Profile
	track_msg, track_ok := d3_write_track_data(job)
	if !track_ok {
		return track_msg, false
	}
	collision_msg, collision_ok := d3_write_collision(job, profile)
	if !collision_ok {
		return collision_msg, false
	}
	visual_msg, visual_ok := d3_write_routesplit(job, profile)
	if !visual_ok {
		return visual_msg, false
	}
	vis_msg, vis_ok := d3_write_track_vis(job)
	if !vis_ok {
		return vis_msg, false
	}
	grid_msg, grid_ok := d3_write_grids(job, profile)
	if !grid_ok {
		return grid_msg, false
	}
	camera_msg, camera_ok := d3_write_replay_cameras(job)
	if !camera_ok {
		return camera_msg, false
	}
	// Static water carries no vis tag, so this can sit after track.vis without
	// anything to census. It still runs with no water at all: see
	// d3_write_niwater.
	water_msg, water_ok := d3_write_niwater(job)
	if !water_ok {
		return fmt.tprintf("niwater: %s", water_msg), false
	}
	codriver_msg, codriver_ok := d3_write_codriver(job)
	if !codriver_ok {
		return fmt.tprintf("codriver: %s", codriver_msg), false
	}
	omit_msg, omit_ok := d3_omit_stale_route_files(job)
	if !omit_ok {
		return omit_msg, false
	}
	return fmt.tprintf(
		"%s; track.jpk: %s; routesplit.pssg: %s; track.vis: %s; grids.pssg: %s; cameras: %s; niwater: %s; codriver: %s; %s",
		track_msg,
		collision_msg,
		visual_msg,
		vis_msg,
		grid_msg,
		camera_msg,
		water_msg,
		codriver_msg,
		omit_msg,
	), true
}

// Venue-scope geometry only: `tracksplit.pssg` from the whole road network.
// track.vis is not correct at venue scope yet, so a venue export cannot write
// the other five files without producing something undriveable; this is the
// piece that can move first and be inspected on its own.
export_dirt3_geometry :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	if job.Profile == nil {
		return "this export needs a venue, so it knows whose shaders the terrain draws with", false
	}
	return d3_write_tracksplit(job, job.Profile, job.Profile.template, .Route)
}

// Venue installation keeps the base tracksplit's texture payloads while
// replacing its geometry. Route/debug geometry export remains payload-free.
export_dirt3_venue_geometry :: proc(job: ^Export_Job, template: []u8) -> (msg: string, ok: bool) {
	if job.Profile == nil {
		return "this export needs a venue, so it knows whose shaders the terrain draws with", false
	}
	if len(template) == 0 {
		return "venue tracksplit emission needs the base venue's full tracksplit", false
	}
	return d3_write_tracksplit(job, job.Profile, template, .Venue)
}
