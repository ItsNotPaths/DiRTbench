<!-- (swiss :tags (online database nefs cli) :sev (blocker gap polish)) -->

## Workstream O: modded online play

Proven by hand on 2026-10-03 with the opencodies scripts (`~/Projects/opencodies/tools/`,
map in `~/Projects/opencodies/docs/checksums.md`): two installs with different files raced
together once the checksum files were blanked, and a deployed venue showed up in the
multiplayer stage picker once it had `net_race_tracks` rows and a `server_file.xml` entry.

Built 2026-10-03. `src/nefs` reads and edits `win_000.nfs` in Odin, with no NefsLib
at runtime. `--online-checksums-blank` blanks the checksum files. Each deploy and
revert rebuilds `server_file.xml` from the stock archive (`win_000.nfs.orig`).

Decision for the archive edits: same-size edits only, and every changed block gets
its stock CRC16 back. The edit changes bytes that nothing reads (whitespace between
tags, the tails of blanked strings, block padding) until the CRC16 matches the signed
header. The header stays stock, no block CRC16 goes stale, and the exe needs no new
RSA key.

Not built: a revert for the checksum blank. To undo it, copy `win_000.nfs.orig` back.

<!-- (skeleton :tags (online nefs)) -->

_No holes match this query._

<!-- /skeleton -->
