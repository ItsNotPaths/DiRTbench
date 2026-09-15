package d3

Route_Sample :: struct {
	Centre: [3]f32,
	Left:   [3]f32,
	Right:  [3]f32,
}

Collision_Material :: enum u8 {
	Road,
	Cliff,
	Terrain,
	Road_Sand,
}

Collision_Triangle :: struct {
	Points:   [3][3]f32,
	Material: Collision_Material,
}

Progress_Marker_Kind :: enum u8 {
	Start,
	Checkpoint,
	Finish,
}

Progress_Marker :: struct {
	Kind:     Progress_Marker_Kind,
	Distance: f32,
}

Export_Job :: struct {
	Name:      string,
	// The directory the files land in, made by the caller. Every file goes
	// straight here; the writer adds no subdirectory of its own.
	Out:       string,
	// Writing into an installed game. Each file we are about to overwrite is
	// copied to `<file>.orig` first, once, and never a second time — the same
	// convention tools/d3-test.sh uses, so the two agree about what "stock"
	// means.
	Backup:    bool,
	Route:     []Route_Sample,
	Markers:   []Progress_Marker,
	Collision: []Collision_Triangle,
	// The open venue's shader template, read from its `base/` directory. An
	// export without one is refused: every file that names a shader would
	// otherwise name art from a venue the player may not own.
	Profile:   ^D3_Venue_Profile,
}

// Public entry points used by the editor's headless CLI. The implementation
// stays package-private; these names are the deliberately small package seam.
Dump :: dirt3_dump_headless
Raise :: dirt3_raise_headless
Ramp :: dirt3_ramp_headless
Partition_Strip :: dirt3_partition_strip_headless
Flat :: dirt3_flat_headless
Partition_Strip_On_Stock :: dirt3_partition_strip_on_stock_headless
Ramp_On_Stock :: dirt3_ramp_on_stock_headless
Bridge_Bump :: dirt3_bridge_bump_headless
Rewrite :: dirt3_rewrite_headless
Export :: export_dirt3
Export_Geometry :: export_dirt3_geometry
Atomic_Write :: atomic_write_file
Prepare_Registration :: prepare_registration
Registration_Output_Delete :: registration_output_delete
Database_Bytes_Have_Venue :: database_bytes_have_venue
Routesplit :: dirt3_routesplit_headless
Venue_Profile :: D3_Venue_Profile
Profile_Load :: d3_profile_load
Profile_Dir :: D3_PROFILE_DIR
Pack_Install :: d3_pack_install
Pack_Profile :: d3_pack_profile
