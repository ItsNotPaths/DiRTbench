<p align="center">
  <img src="assets/dirtbenchlogo.png" alt="dirtbench" width="320">
</p>

<p align="center">Dirt 3 stage/venue creator.</p>

## Build

```
./download-deps.sh      # once: fetches and builds vendor/
./release.sh --local    # -> build/dirtbench
```

## Point it at the game

Put a `dirtbench.conf` next to the binary

```
install_dir = /path/to/DiRT 3 Complete Edition
```

## Make a stage

1. Start `dirtbench`. The project manager lists the game's venues and your own.
2. Make a venue. It holds your stages and borrows its art from a stock venue that you pick.
3. Open the venue. Draw any road network, terrain, trees.
4. Open/Add a stage. place a start and finish, use pins for a specific route.
5. Deploy/Update-in-game. The stage goes into the game, and you can drive it.

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

## Huge thanks

- The [Ego-Engine-Modding](https://github.com/EgoEngineModding/Ego-Engine-Modding)
  team, for the database schema and for years of work on the Ego formats.
- [ssor0](https://github.com/ssor0), for the PSSG/vis/general format knowledge.
- [Deuterium, the Sentient Mattress](https://www.youtube.com/@DeuteriumtheSentientMattress/videos),
  for the co-driver voice.

## License

MIT, see `LICENSE`. Third-party code and data are listed in `credits.txt`.
