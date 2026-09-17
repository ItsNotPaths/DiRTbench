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

Checked 2026-09-17 by doing it: each set below was moved into `src/` in a copy
of the tree and built.

Move the files into `src/app/` or `src/d3/`, whichever each `package` line says.
The set is never one file:

| you want | move back |
| --- | --- |
| `--dirt3-flat-venue` | `app/flat_venue.odin`, `d3/scratch.odin` |
| `--dirt3-paths-place` | the above **plus** `app/paths_place.odin` |
| `--dirt3-bisect-1`, `-1-flat`, `-short` | `app/flat_venue.odin`, `d3/scratch.odin`, `app/finland_bisect.odin` |
| the probe tests | every app probe above plus `app/paths_place_test.odin` |

`flat_venue.odin` is the one the table above kept repeating: `paths_place.odin`
calls `flat_venue_ens_ref` and `finland_bisect.odin` calls
`flat_venue_tiled_plane`, so neither compiles without it. `paths_place_test.odin`
alone does not compile either — it tests procedures in `paths_place.odin`.

What each app probe needs from `scratch.odin`:

| probe | needs |
| --- | --- |
| `paths_place.odin` | `d3_stock_route_all_visible_vis` |
| `flat_venue.odin` | `d3_stock_route_all_visible_vis` |
| `finland_bisect.odin` | `d3_stock_route_all_visible_vis`, `d3_collision_read`, `d3_collision_delete`, `d3_material_of` |

Then restore the command block in `src/app/cli.odin`. It was cut in `57bbfa0`,
so the text is `git show 57bbfa0^:src/app/cli.odin` (the `--dirt3-*` blocks) —
do not check the whole file out, because that commit also split `main.odin`.

**`src/d3/api.odin` only matters for the scratch commands.** `Dump`, `Raise`,
`Ramp`, `Partition_Strip`, `Flat`, `Partition_Strip_On_Stock`, `Ramp_On_Stock`,
`Bridge_Bump`, `Rewrite`, `Routesplit` and `Vis_All_Visible` were the aliases
`cli.odin` called, and they were dropped in the same commit
(`git show 57bbfa0 -- src/d3/api.odin`). The three app probes need none of them:
they call the package names directly (`d3.d3_collision_read`), which compiles
because nothing in `scratch.odin` is marked `@(private)`.

A file compiles as soon as its set is back under `src/` — there is no build flag
to unset.

## What did not come here

`d3_ornaments_xml_instance_ids` was in `scratch.odin` and is not a probe. It
reads the `instance_id` of every ornament out of an `ornaments.xml`, which is
the only place that id exists — `ornaments.bin` does not carry it, and the
visibility system needs it. It now lives in `src/d3/placement_files.odin` beside
the `ornaments.bin` codec, with its three tests.
