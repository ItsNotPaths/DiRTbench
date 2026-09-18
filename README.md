<p align="center">
  <img src="assets/dirtbenchlogo.png" alt="dirtbench" width="320">
</p>

<p align="center">A stage editor for DiRT 3. Draw a road, shape the ground, drive it.</p>

## Build

```
./download-deps.sh      # once: fetches and builds vendor/
./release.sh --local    # -> build/dirtbench
```

## Point it at the game

Put a `dirtbench.conf` next to the binary, with one line in it:

```
install_dir = /path/to/DiRT 3 Complete Edition
```

## Make a stage

1. Start `build/dirtbench`. The project manager lists the game's venues and your own.
2. Make a venue. It holds your stages and borrows its art from a stock venue that you pick.
3. Open the venue. Draw the road network, then place a stage on it.
4. Open the stage. Shape the ground under the road.
5. Export. The stage goes into the game, and you can drive it.

Stock venues are read-only. On the first export, each game file that dirtbench
replaces is copied to `<file>.orig`. A later export never touches that copy, so
`.orig` is always the stock file.

## Command line

```
dirtbench --venues                          # your venues
dirtbench --venue-new <id> --base <venue> [--name <shown>]
dirtbench --venue-deploy <id> [--apply]
dirtbench --venue-revert <id>
dirtbench --dirt3-venues                    # the game's venues, and the broken entries

dirtbench --export <stage> [--target gltf|dirt3] [--terrain]
                           [--venue <id>] [--route <venue>/<route_n>]
                           [--debug-out]
dirtbench --pacenotes <stage> [--reverse]
```

An export goes into the game by default. `--debug-out` writes to `build/out/`
instead. glTF always goes there, because the game cannot read it.

## Test

```
./test.sh
```

## License

MIT, see `LICENSE`. Co-driver clips have their own credit in `credits.txt`.
