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
	// What this route draws and collides. `routesplit.pssg` and `track.jpk` are
	// the same geometry by design: anything drawn locally can be driven on, and
	// anything only the venue LOD draws cannot.
	Collision: []Collision_Triangle,
	// The open venue's shader template, read from its `base/` directory. An
	// export without one is refused: every file that names a shader would
	// otherwise name art from a venue the player may not own.
	Profile:   ^D3_Venue_Profile,
	// The location directory `tracksplit.pssg` lives in, one level above a
	// route. `track.vis` censuses that file together with the route's own
	// routesplit, because the engine numbers venue tiles before route tiles.
	Venue_Dir: string,
	// Which route of its venue this is, the `n` of `route_n`. Camera and
	// cutscene idents are built from it, and the global cutscene files
	// substitute it into names like `start_camera_r[route]`.
	Route_Index: int,
}

// The names the editor calls this package by.
//
// An alias earns its place here for one reason: to strip the `d3_` prefix off a
// name that would otherwise stutter as `d3.d3_ens_parse`. A proc already named
// without that prefix — `prop_lib_open`, `billboard_templates` — is called by its
// own name and gets no entry. Odin exports everything a package does not mark
// `@(private)`, so this list is a convention, not a barrier, and two live names
// for one proc is the thing it exists to prevent.
//
// The probe entry points that scratch.odin backed are not here: that file lives
// in `refs/` and is not compiled. Reinstating one means moving the file back and
// adding its alias here — see refs/README.md, which lists the eleven names.
Export :: export_dirt3
Export_Geometry :: export_dirt3_geometry
Export_Venue_Geometry :: export_dirt3_venue_geometry
Placement_References :: d3_placement_read_references
Ens_Parse :: d3_ens_parse
Ens_Emit :: d3_ens_emit
Ens_Placement_Transform :: d3_ens_placement_transform
Placement_Build :: d3_placement_build
Placement_Read :: d3_placement_read
Placement_Layout :: d3_placement_layout
Placement_Relocate :: d3_placement_relocate
Placement_Xml_Build :: d3_placement_xml_build
Write_Out :: d3_write_out
Stock_Path :: d3_stock_path
Backup_Once :: d3_backup_once
Venue_Profile :: D3_Venue_Profile
Profile_Load :: d3_profile_load
Pack_Stamp :: D3_PACK_STAMP
Pack_Install :: d3_pack_install
Pack_Profile :: d3_pack_profile
