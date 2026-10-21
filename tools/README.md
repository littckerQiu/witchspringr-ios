# tools — porting tools

Usage is in each file's header. Python tools need the packages in `requirements.txt`; workspace paths come from the game profile
(`games/<id>/game.json`, selected with `DM_GAME`, relative to `DM_ROOT`).

## Porting a game

| File | What it does |
|---|---|
| `game_extract.sh` | Your `prod.keys` + game packages (`.nsp` / `.xci`, base game and updates) → ExeFS and the merged RomFS; builds and runs `game_extract/` (C#, LibHac 0.19.0, pinned by content hash in `packages.lock.json`). Reads only the keys common to all consoles; key values are never printed |
| `new_game.py` | Drafts `games/<id>/game.json` and an empty `rules.py` from the dumped ExeFS and RomFS (program ID, build ID, modules, RomFS checks) |
| `build_product.sh` | Rewrites the profile's modules into the product directory (`workspace.product`) with `patch_nso.py` and the game's `rules.py` |
| `patch_nso.py` | The rewriter: changes only the instructions that cannot run unchanged under Apple's kernel (x18, `tpidr_el0`, `tpidrro_el0`, `svc`, timer reads) and applies the game's rules; everything else stays byte-for-byte |
| `gen_game.py` | `game.json` → `host/gen/<id>/game_profile.c`; `--get <key>` prints a field for shell scripts |
| `mac_app.sh` | Packages the Mac host as a double-clickable `.app` for the game |

## Reverse engineering helpers

| File | What it does |
|---|---|
| `fdis.py` | Disassembles a function of an NSO with call / branch targets named (local symbols, PLT imports) |
| `symaddr.py` | Maps module offsets to the nearest preceding dynamic symbol, optionally with disassembly |
| `nso.py` | NSO → memory image (`<module>.orig.bin`) |
| `sdis.py` | Disassembly of a memory image with symbols; symbol / cross-reference / caller / containing-function queries |
| `sampagg.py` | Aggregates the host's guest thread sampling log (`DM_SAMPLE`) into hot functions and wait points |
| `hle_inventory.py` | Lists every host implementation of a system function (`HLE`, `HLE_FORCE`, libc passthrough, svc) as TSV, for auditing |

## Memory tests

| File | What it does |
|---|---|
| `memstat_cycles.py` | One row per load cycle of the host's memory accounting (`DM_MEMSTAT`), for `games/manosaba/reload_loop.sh` |
| `gc_stats.py` | The IL2CPP garbage collector's statistics from a host log (`DM_GUEST_ENV="GC_PRINT_STATS=1" DM_DBG=1`) |

## Long runs and lifecycle

| File | What it does |
|---|---|
| `soak.py` | `run`: the host for M minutes with memory accounting and screenshots through the command channel, then what drifts (memory after the warm-up in MB an hour, frame and GPU time early against late, red lines first seen late); `window`: N runs to a frame and their frame and GPU time over a fixed frame window (the noise an A/B comparison has to beat) |
| `lifecycle_check.py` | One trip to the background and back judged from a host log (a Mac run with `DM_TEST_BG`, or an iPhone's `boot.txt` from `ios/run.sh lifecycle`): suspended while away, no game time lost, audio back, presenting on, no new red line |
