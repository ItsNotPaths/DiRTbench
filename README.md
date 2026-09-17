# dirtbench

DiRT 3 stage/venue modding tool.

```
./download-deps.sh      # once: fetches and builds vendor/
./build.sh              # -> build/dirtbench
./test.sh               # 31 tests across src/d3 and src/app
MODE=debug ./build.sh
```

## Pointing it at the game

`dirtbench.conf` next to the binary, gitignored. One file for the whole tool, not
one per target. Grammar is `key = value`, `#` for a comment, no quoting, and a
value runs to the end of the line:

```
install_dir = /path/to/DiRT 3 Complete Edition
```

dirtbench boots into a small **project manager** window, which lists what the
game holds and what you have made. Opening a venue launches its editor in a
separate process (`dirtbench --editor <venue-id>`). Stock venues are read-only
and nothing here writes into one.

What the game holds comes from `database/database.bin`, not from the directory
listing: the game finds a venue through its `track_model` row, so a directory
nobody registered is invisible and a registration with no files is a broken menu
entry. A stock install has five such half-installed venues, and the screen says
so rather than quietly counting them as real.

## Your venues

A venue of yours is a **derivation**. It owns its stages and borrows its art —
terrain, objects, sky, lighting — from a vanilla base venue you pick when you
make it. Fully custom venues come later.

```
build/venues/<id>/
  venue.json            identity, base venue, display names, stage list
  stages/route_0.json   the road document
```

Nothing in there is a game file. A `.pssg` is an export product, not something
you edit: the stage definition is the document, and every PSSG, XML and collision
file is generated from it on the way out.

## Where an export lands

**Into the game, by default.** Pick a route in the venue browser and export; the
files are written straight into that route directory so the next thing you do is
drive it. Every file it overwrites is copied to `<file>.orig` first, once, and a
later export never touches an existing `.orig` — so `.orig` always means stock.
`tools/d3-test.sh` uses the same convention.

`out/` is the debug detour, not the default: tick **Export targets > Write to
out/ instead**, or pass `--debug-out`. glTF always goes there, since the game
could not open it anyway.

## Headless

```
dirtbench --venues                          # what you have made
dirtbench --venue-new <id> --base <venue> [--name <shown>]
dirtbench --dirt3-venues                    # what the game holds, and the gaps

dirtbench --export <stage> [--target gltf|dirt3] [--terrain]
                           [--venue <id>] [--route <venue>/<route_n>]
                           [--debug-out]
dirtbench --pacenotes <stage> [--reverse]
dirtbench --dirt3-dump <track.jpk|x.vcqtc> [-o out.obj]
```

`--target` defaults to `dirt3`. An installing target needs a destination — a
deployed `--venue`, or a `--route` already in the game — unless `--debug-out` is
given. `<stage>` names a stage in `maps/`, or one of `--venue <id>`'s stages.

`build/` is the working directory: `build/venues/` holds your venues,
`build/maps/` loose stages, `build/out/` the debug exports, and
`build/dirtbench.conf` points at the game. The co-driver
clips are baked into the binary (`#load_directory` over `assets/pacenotes`), so
there is nothing to install beside it.
