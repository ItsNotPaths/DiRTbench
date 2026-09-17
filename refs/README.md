# refs/ — reference only, never built

Nothing here is compiled. No build script names these directories, and the
`package` line at the top of each file is the package it belonged to, not a
package that exists here.

These are the DiRT 3 format probes: the destructive experiments and archive
surgery that established the production codecs. They are kept for the method,
not for use. Every one of them writes into a game install or a route directory,
and none of them is safe to run without reading it first.

| file | was | drove |
| --- | --- | --- |
| `d3/scratch.odin` | `src/d3/scratch.odin` | collision synthesis, archive surgery, VIS probes |
| `app/paths_place.odin` | `src/app/paths_place.odin` | `--dirt3-paths-place`, the full custom-level debug emit |
| `app/flat_venue.odin` | `src/app/flat_venue.odin` | `--dirt3-flat-venue`, the synthesized flat venue |
| `app/finland_bisect.odin` | `src/app/finland_bisect.odin` | `--dirt3-bisect-1`, `--dirt3-bisect-1-flat`, `--dirt3-bisect-short` |
| `app/paths_place_test.odin` | `src/app/paths_place_test.odin` | the tests for the two app probes |

## To bring one back

1. Move the file into `src/app/` or `src/d3/`, whichever its `package` line says.
2. **Move `d3/scratch.odin` back too**, unless the file you want is
   `paths_place_test.odin`. All three app probes call into it:

   | probe | needs from `scratch.odin` |
   | --- | --- |
   | `paths_place.odin` | `d3_stock_route_all_visible_vis` |
   | `flat_venue.odin` | `d3_stock_route_all_visible_vis` |
   | `finland_bisect.odin` | `d3_stock_route_all_visible_vis`, `d3_collision_read`, `d3_collision_delete`, `d3_material_of` |

3. Add each symbol the CLI reaches back to `src/d3/api.odin`. The probe aliases
   were removed from it; `src/app/cli.odin` calls `d3.Name`, not the
   package-private name.
4. Restore the command block in `src/app/cli.odin`.

A file compiles as soon as it is back under `src/` — there is no build flag to
unset — but it will not link until steps 2 and 3 are done.

## What did not come here

`d3_ornaments_xml_instance_ids` was in `scratch.odin` and is not a probe. It
reads the `instance_id` of every ornament out of an `ornaments.xml`, which is
the only place that id exists — `ornaments.bin` does not carry it, and the
visibility system needs it. It now lives in `src/d3/placement_files.odin` beside
the `ornaments.bin` codec, with its three tests.
