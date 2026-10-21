# Development notes

Where the work stands and how to pick it up again, on this machine or a new one. The repository holds all code, tools and notes; what it
does not hold (and must not: keys, dumps, anything derived from the game) is listed below with the way to get it back.

## Restoring a working copy

```sh
git clone https://github.com/iceorange-dev/manosaba-ios.git "manosaba ios" && cd "manosaba ios"   # work on main, which tracks origin/main
git remote add upstream https://github.com/jhaizhou-ops/d2r-mobile.git      # fetch only, never push there
```

Then the machine: [PORTING.md § 0](PORTING.md#0-machine-and-workspace) (Xcode, Homebrew packages, the Python venv, the shader translator).
This working copy uses `DM_ROOT=<repo>/work` (git ignores `work/`).

| Not in git | Where it lived | How to get it back |
|---|---|---|
| Console keys | `keys/` | From your own console; keep your own backup |
| Game dump (NSP, ExeFS, RomFS) | `dump/`, `extracted/2.0.4b/` | [PORTING.md § 1](PORTING.md#1-dump-the-game-from-your-console): `tools/game_extract.sh keys/prod.keys <out dir> dump/*.nsp` rebuilds ExeFS and RomFS from the two NSPs. `work/data/switch/manosaba-2.0.4b/RomFS` was a link to `extracted/2.0.4b/RomFS` |
| System fonts | `work/data/switch/sysfont` | PORTING.md § 1 (nxdumptool, system data titles 0100000000000810–814) |
| Console and SD card backups | `sd_backup_*/` | Only your own backup |
| Product (rewritten modules) | `work/build/cache/dm/out/…` | `tools/build_product.sh && verify/regress.sh` |
| Shaders, stage map | `work/build/…` (paths in `games/manosaba/game.json`) | PORTING.md § 5 |
| App icon | `workspace.icon` | Your own 1024×1024 PNG of the game's icon |
| Device saves | Device `Documents/save`; copies in `work/run/ios/*_save_*` | Files app → this app → `save`, or `devicectl device copy from` |
| iOS signing settings | `ios/local.env` | From `ios/local.env.example`. Keep the bundle ID of the installed app (`xcrun devicectl device info apps --device <id>`): another bundle ID is another app with an empty data container |

Keep `keys/`, the dump, the backups and the device saves in a separate private backup (for example an encrypted external disk); they stay
out of git by design.

Check the result: `make -C host/tests run`, `make -C gfx/tests run`, `make -C gfx/tests run-m3`, `make -C gfx/tex/tests run`,
`verify/regress.sh --fuzz`, then a Mac run (README, Getting started) and `ios/run.sh build`.

## Testing

- **Memory over repeated loads on the Mac**: `games/manosaba/reload_loop.sh [--stay] <run dir> <save dir> <cycles> [host binary] [VAR=value …]`
  loads a save's newest autosave every 40 s by tapping through the game's own menus; `tools/memstat_cycles.py <run dir>/mem.tsv` prints one
  row per load. With `DM_GUEST_ENV="GC_PRINT_STATS=1" DM_DBG=1` the IL2CPP collector logs every collection; `tools/gc_stats.py <run dir>/log.txt`
  summarizes it. The managed heap census (`DM_HEAP_CENSUS`, `DM_HEAP_WATCH`, `DM_HEAP_REFS`, …) is in [host/README.md](host/README.md).
- **A memory limit kill on iOS** leaves no crash report as a rule (JetsamEvent reports are rate-limited, the crash is "non-actionable"). With the
  device connected: `sudo /usr/bin/log collect --device-udid <UDID> --start '<yyyy-mm-dd hh:mm:ss>' --output kill.logarchive`, then
  `/usr/bin/log show kill.logarchive | grep -E 'ReportSystemMemory|killed by jetsam'`. `DM_MEMSTAT` (relative paths land in `Documents`) and the
  low-memory watch in `host/memstat.m` show what grew.
- **Pitfalls**: zsh has a `log` builtin (use `/usr/bin/log`); zsh does not split words (`set -- $var` does not do what bash does); make compares
  modification times, so two edits within one second can skip a rebuild; copy a host binary elsewhere before a long test if you will rebuild
  the host meanwhile; Apple's Metal HUD crashes with `CAMetalDisplayLink` on iOS 18.6 (keep it off there).

## Where the work stands (2026-10-16)

What works is in the README's status. Open, roughly by value:

1. **The game's own memory leak.** Every save load builds a new set of Naninovel's `ScriptManager` and `ResourceProviderManager` (exactly one
   more of each per load, `DM_HEAP_WATCH`); the old sets stay referenced with their parsed scripts and UI objects (up to 12 copies of one
   script after 9 reloads). The collector's live data grows about 20 MB per load, the heap about 28 MB; `GC_FREE_SPACE_DIVISOR=8` saves 35–50 MB
   but not the rate. The Switch version is reported to end with errors in long sessions too (2.0.4's notes: "less likely"). The root reference
   was not found: the reference tracer sampled too sparsely, attributing a reference to an object was unreliable at object boundaries, and
   stacks were not scanned. Next: trace all old instances of the two managers (not samples), check each object's extent with its class's
   `instance_size` (`host/hle_svc.c` finds the offset at start), scan the guest stacks too; once the root is known, clear it from a
   `games/manosaba` hook after a load.
2. **Trial loading peak on 8 GB iPads.** Without the increased memory limit entitlement (a free account cannot sign it) an iPad mini 7 lets the
   app use about 3.35–3.4 GB. A signer whose profile has the entitlement (item 3) may lift that; not tried on the iPad mini yet. A trial's start adds about 1.4 GB within 0.2 s (about 116 character render targets, about 0.9 GB of Metal memory, of which the
   D32FS8 depth targets are about 0.44 GB); a fresh session keeps about 725 MB of headroom, a session of about two hours does not (the leak
   above). Render resolution does not help (the game fixes the target sizes). Memoryless depth would save most of the depth memory but the
   depth targets cross render passes that the layer splits at uniform buffer updates, so it needs pass merging first. Refusing guest memory
   does not help either: with the physical memory pool 700 MB smaller the game coped, 1000 MB smaller it broke.
3. **Unsigned IPA** (`ios/run.sh ipa`, `DM_IPA_DATA=1`): signed and installed with an on-device signer (LCSign) on an iPad Pro M4 (iOS 18.5)
   on 2026-10-16; the game data was read from the app bundle, no red lines. LCSign signs with every entitlement of its profile, whatever the
   IPA carries (read from the signature of its output: `increased-memory-limit` and `extended-virtual-addressing` true, `get-task-allow`
   false): the app ran without `get-task-allow` (the code remapping needs no debugger entitlement), and the memory readout showed 7.2 GB of
   headroom at 1 GB resident (how much of that is the entitlement and how much the device is not separated: the iPad mini was never signed
   this way). So an IPA carrying entitlements of its own (mush8's way) matters only for signers that read them (AltStore); not
   tried. Not tested: the iOS 18 build on iOS 26.
4. Smaller: 13 NVN functions the game looks up that the layer does not know (returned as NULL, never called); compute dispatch never seen at
   run time; keyboard, mouse and controller input untested with this game; Metal HUD on iOS 18; generic upstream changes not ported yet
   (Mac occlusion, audio notifier QoS: see "Wider review of 2026-10-19"; present pacing to the screen refresh does not apply, see there).

Devices on 2026-10-16: iPhone 17 Pro (iOS 26.4) runs a build from before 1f54dad (the copy encoder fix), iPad mini 7 (iOS 18.6.2) a build of
68c048b, iPad Pro M4 (iOS 18.5) the unsigned IPA above (build 1792140837) with the iPad mini's save of 2026-10-16 17:10.

## Next game: Tears of the Kingdom (started 2026-10-17)

`games/totk` (1.4.3, program 0100F2C0115B6000, main build 277178b7dba1b6d4949a84778d4abc58), data from your NSPs with
`tools/game_extract.sh` into `work/data/switch/totk-1.4.3`. SDK 20.5.22; its `sdk` and `subsdk0` have the same build IDs as nxnative's Breath of
the Wild 1.9.0, so the system layer is the same binary and most host work could be taken from nxnative.

**Rewrite: done, `verify/regress.sh --fuzz` OK for all three modules** (main: 129 windows, 5 sections in pieces, 6 explicit jump tables with 49
targets, 17 equally spaced tables, 8 `blr x18`; manosaba's equivalence numbers are unchanged). What `tools/patch_nso.py` learned:

- `blr x18` whose x18 was loaded in an earlier block: the K18 slot holds it wherever it was loaded (nxnative's blr rewrite has no such check).
- Jump tables with explicit targets (`adr xA, anchor; ldrsw / ldrh / ldrb xT, [xB, xI, lsl #s]; add xD, xA, xT[, lsl #k]; br xD`): the targets
  are derived over the function's control flow (table base and anchor from every reaching definition, the index bound from a compare + branch
  on every path, other tables' targets as edges, iterated to a fixpoint and re-derived strictly), then a compare chain with landing pads as
  nxnative's `site_br_tab`, comparing with `sub` + `cbz` so NZCV stays as `br` leaves it. An index outside the table stops at `brk #0x18`.
  New `sites.tsv` row `JT`.
- Exclusive sections by control flow (`exclusive_regions`): every instruction on a path from an exclusive load to a store (not through another
  exclusive load, a call or `clrex`), plus the status branch. Contiguous sections entered at their load are windows as before (manosaba's 17
  come out identical); TotK's compiler moves compare-and-swap retries into cold blocks that jump back to the main path's `stxr`, giving sections
  in pieces, copied by `site_region` (row `R`: entry, then `lo-hi@copy` per piece). Any other entry stops the rewrite.
- `mrs xN, ctr_el0` (SIGILL on Apple systems, read by `nn::os::FlushDataCache`) → `movz xN, #4, lsl #16` in place, as nxnative (row `ctr`; 64-byte
  lines, at most the real 128). This also changes two words of manosaba's `sdk`, a latent SIGILL there.
- Verifiers: `structck` ⑪ checks windows, sections and explicit tables word by word against the original and enforces the single entry
  independently, ⑫ the `ctr` constants; `equiv` runs sections in pieces from each piece (the cold retry block is reached only through the status
  branch that `deexcl` removes), draws explicit table targets, and does not compare a trial whose original instruction reads below sp (the rewrite
  blocks' red zone; one such draw in TotK main); `fnfuzz` gives both images the `ctr` constant. Seven deliberately broken products were all
  caught by `structck`, five also by `equiv`.

**First runs on the Mac (headless, empty shader map):** the game runs its main loop at 30 fps, renders and captures shaders (6202 so far), its
audio renders with sound, saves and cache storage work. Host additions on the way, most from nxnative (credited in the code):
oe (`GetPreviousProgramIndex` = -1 per switchbrew, launch parameter, startup logo, `PopNotificationMessage`, volume balance, ARUID), the NVN API
version as a profile field `device_api` (TotK needs 55.15; manosaba keeps 53.311), hid mouse / vibration batch, the in-process audio renderer
(`host/hle_audren.c`, with host guest threads `host/hle_guestthread.c` and `dm_pcmout_*`), the hardware Opus C API on the SDK's software decoder,
fs read priority / access log, indexed cache storage (`$DM_CACHE`, from the SDK reference), another application's save not existing (TotK looks
for BotW's), the user exception context area (svc GetInfo 20), play reports, amiibo (`host/hle_nfp.c`), clock snapshots and the steady / network
clocks (layout and service semantics from Ryujinx), NVN functions (`MapVirtual`, `ProgramSetShadersExt`, `BindTexture`, deferred texture binds,
`GetCommandMemoryUsed`, ...; 13 names added to `gfx/nvn/names.txt`, as nxnative's table), and command memory: a disabled callback or one that
cannot supply enough continues in host segments that grow on demand and are reclaimed when the game gives the recording's memory out again.

**With its shaders (2026-10-18):** the title screen draws as on the console (the lit stone mural, the green wisps, the logo and the menu text;
compared with a console screenshot), and the save selection after "Continue" shows its text over the blurred title, as on the console. Its
background is not drawn live: `TitleMenuBG_00` (layout archive `Title.Product.140`) has a capture pane (`C_Capture_00`, R10G10B10A2,
multi-filter `SystemWindow_00`) that copies the framebuffer once when the screen opens, and `LoadList.module` hides the `Main` layer. The
title's camera loop fades to black for about a second (frames 900–970 in our runs), so pressing A then captures only the logo and the menu
(what `DM_KEYS="A@48"` did; `A@26.5` captures the lit mural). The black thumbnail of the old save was written while the mural still drew
black. What it took, in the order found:

- Core numbers (`host/hle_thread.c`): the job system picks a per-worker output block by `nn::os::GetTlsValue` = current core + 1, and the host
  answered core 0 for every thread, so ModuleSystemWorker0..2 and the main thread filled one block at once (the crash at main+0x84f5c, an
  object pointer overwritten by a neighbour). `SetThreadCoreMask` / `GetThreadCoreMask` / `GetCurrentProcessorNumber` / `CreateThread` now follow
  the Horizon kernel (Atmosphère mesosphere: -1 don't care, -2 the process's ideal core, -3 keep it and it must be in the mask; the running core
  moves into the mask), with the process's ideal core and core mask from main.npdm (core 0, cores 0..2 in both games). Found with a new
  hardware store watchpoint (`DM_WATCHPOINT`, `host/diag.c`) and crash-time memory dumps (`DM_CRASH_MEM`, `host/crash.c`).
- NVN: `DrawArraysInstanced`, timestamps in ns, render enable / rasterizer discard / tiled cache logged or no-ops (nxnative); Metal layer entries
  (`Read|WriteTexels`, `QueueFinish`, `SubmitCommands`, `PresentTexture`) take one recursive lock (TotK writes texels from worker threads).
- Shader build per game: `game.json` `nvn_c2` (where the shaders read texture / sampler / image handles in c[2]: textures at 0x20 for TotK as for
  nxnative's games, 0x168 for manosaba; it reached 2090 shaders with unbound textures) and `depth_mode` (TotK sets `near_is_minus_w`: the
  translator's own z' = z / 2 + w / 2 before every vertex return; without it every full-screen pass at z = -w was clipped). Both travel in the
  translator job, the cache key and the reflection, and the host refuses a reflection built for another layout. manosaba's 2740 shaders come out
  byte-identical (MSL and reflection) under the new chain. `dmsh_build.py` needs `DM_GAME`, and the translator needs `DOTNET_ROOT` when .NET
  comes from Homebrew (`/opt/homebrew/opt/dotnet/libexec`).
- Replay: 8-bit index buffers widened to 16-bit (most of TotK's quads; they had been skipped), vertex format RGB10A2SN, texture view swizzle
  (a set view property replaces the texture's; `view_t` stays 10 bytes, because a 12-byte one overwrote the game's fields after its views),
  views whose format or level / layer range cannot be a Metal view of the texture are sampled as the texture (they had aborted the process),
  compressed render targets are left unattached (BC4 written through an RGBA16UI view, as nxnative found in BotW).

The title picture was wrong for three separate reasons, each found by following the data from the screen back to its source (pass dumps,
snapshots after each pass, then the texture and memory behind the bad value):

- **Red background: the wrong shader code.** Shader keys hashed the 0x880-byte control section only, which holds sizes and resource counts but
  no hash of the code. 807 of the game's 3667 captured shaders share their control section with another one (313 sections); the capture kept
  the first code seen per key and every other shader under that key ran it. The bloom upsampler (`sample × c[3][0x60]`) ran a shader that adds
  `c[3][0x20]`, which held a matrix row (2, 0, 0, 0) of an earlier pass: red. The key is now sha256(control section + code area) in the host,
  the capture and the tools (`shader_key` in `hle_nvn.c`; nxnative had made the same change for Mario, whose control sections collide too).
  Both games were rebuilt: manosaba's 2740 shaders map one to one (MSL byte-identical, only key names change); TotK's captures were renamed and
  recaptured (3706 shaders). The uniform-buffer experiments on the way (per-binding copies instead of memory semantics) only hid this: they
  broke manosaba and were reverted; NVN's documentation and Ryujinx both give memory semantics in command order, which the host keeps.
- **Black mural: assets never uploaded.** The game gives no packaged layout to its asset textures (26 `SetPackagedTextureLayout` against 757
  registered textures); it writes their block-linear data into CPU-cached pools and flushes the ranges. Only packaged textures were uploaded
  from the pool, so the mural's albedo was black in Metal while its storage was 90-99 % filled. As in LASRecomp (a texture is uploaded from
  guest memory until it is rendered into), a texture in a CPU-visible, non-compressible pool that the GPU has not written is uploaded once the
  CPU has filled it (non-zero storage at first use, or dirty pages later), created render-target capable; the first GPU write (render target,
  copy / clear destination, image store) makes that MTLTexture the GPU's (`tex_gpu_write`). Linear textures in CPU-visible pools are made on
  the pool buffer (`tex_linear`, from nxnative): that is the glyph cache (IMAGE | LINEAR), and the menu text appeared with it.
- **Black lighting: every conditional clear ran.** The lighting buffers are cleared once per frame with `SetRenderEnableConditional(not
  equal, X)`, the clear, then `ReportCounter(TIMESTAMP_TOP, X)`. NVN documents that TIMESTAMP and TIMESTAMP_TOP reports write 0 as the
  counter value, so the next conditional clear of the frame compares X+0 = 0 with X+16 = 0 and is skipped, and the second lighting pass adds
  to the first. The host wrote the timestamp into the counter half and did not evaluate conditions at all, so the second pass cleared the
  first pass's light. Counter reports other than samples passed now write their counter half (0) in command order at replay; conditions are
  evaluated at replay from guest memory (rendering stays on while either value is a samples-passed result still on the GPU); the store,
  clear-hoisting, fusion and deferral look-aheads treat a render enable change conservatively.

Also ported on the way: one attachment per texture level / layer attached at several color slots (`rt_dup_slot`, nxnative / tomodachi-native),
inline uniform data copied into a host ring at replay (nxnative), `BindProgram` keeping the program's shaders as recorded, `SetRenderEnable`,
vertex shaders padded for the pixel shaders the game pairs them with (`vs_pad`, pairs written by the host while capturing; link failures
45 → 2).

**The prologue (2026-10-18):** an empty save starts it without input (corridor with Zelda's torch, her dialogue, then the controllable cave
with the HUD; the first autosave at about 88 s carries a correct thumbnail). Zelda was mostly missing (her torch and a flat-shaded head only)
because the run-time capture only had the title's shaders: 87 more were captured in the prologue (3706 → 3793; some appear only in some runs,
so it took two capture runs), and every "not in the shader map" line went away. 7 of them are vertex shaders doing DMUL / DFMA on uniform data,
and Metal has no `double`: `dmsh_xlate` now answers `QueryHostSupportsShaderFloat64` false, so Ryujinx's own `DoubleToFloat` pass runs them
in float with IEEE double ↔ float helpers for the register pairs (chain `ae97fd60e78b`; all 3793 TotK shaders build, manosaba's 2740 and the
other TotK shaders come out byte-identical in MSL and reflection).

**30 fps, the shaders from the RomFS, MacNativeGames' fixes (2026-10-18):**

- **20 fps was the game's own choice.** TotK's frame-rate controller (main 0x2db174, called from 0x2daa20) sets present interval
  clamp(int(max(CPU, GPU) × 60 + bias) + 1, 2, 3). Its GPU time is `nn::os::ConvertToTick(nvnDeviceGetTimestampInNanoseconds(last report))`
  minus the frame's start tick from `nn::os::GetSystemTick` (main 0x2b3cff8, stored at sys+0x128, the larger of the two at sys+0x118). Our
  counter timestamps were `CLOCK_MONOTONIC`, which counts the Mac's sleep; the guest's system tick is `mach_absolute_time`, which does not. After
  25 hours of sleep the "GPU time" was 25 hours and the game stayed at interval 3 with the process idle 99 % of the time (a `sample` of the
  cave). Counter timestamps and `nvnDeviceGetCurrentTimestampInNanoseconds` now run on the guest clock (`guest_ns`, the system tick's source);
  the game keeps interval 2 (frame time p50 33.3 ms) and its GPU time reads 5-14 ms. Found with a backtrace on every present interval change
  (kept in `nvnWindowSetPresentInterval`) and a hardware watchpoint on sys+0x118 (`DM_WATCHPOINT`).
- **Shaders from the RomFS:** `engines/bnsh/shader_extract.py` reads the BNSH files the game ships, as MacNativeGames' prepare_shader_seed.py
  does (`Pack/Bootup`, `Lib/**`, `Shader/**`: 8290 shaders, its count for 1.4.3), plus the effect sets `Effect/**.esetb.byml.zs`, whose VFXB
  carries two BNSH files (GRSN graphics, GRSC compute; not in MacNativeGames' set), and 0x88c-byte control sections taken as their first 0x880
  bytes (`Shader/cave_quadmesh`, which MacNativeGames skips: 30 vertex shader records, 21 distinct, all captured at run time under those bytes): 24371
  shaders and 19669 vertex / pixel pairs. 3451 of the 3793 run-time captures are among them, all byte-identical, and all 2272 run-time pairs of
  those are BNSH program pairs. The other 342 come from agl / gsys / Terrain shader archives (`Lib/**.sharcb`) and from main, whose code areas
  are not next to their control sections (not parsed: they stay run-time captures). The extractor writes into the capture directory
  (`work/build/totk/shader_capture`, 24713 shaders) and adds only what is missing.
- **From MacNativeGames** ([ly05010419/MacNativeGames](https://github.com/ly05010419/MacNativeGames), MIT, reviewed at
  41e1e0caf43d58c4af3c478ca2d1bafd9dba7093; ported by hand, credited in the code):
  - a texture registration without a view clears the slot's old view, and only a registered view changes format / levels / layers / target
    (`tex_by_id` read the old view whenever the texture had a swizzle);
  - clears inside a pass, with a partial channel mask, under a partial scissor or with a partial stencil mask are drawn as one full-target
    triangle (`clear_quad` / `clear_ds_quad`); they had been dropped, and a scissored depth clear or a partial stencil mask had cleared the whole
    plane. The store look-ahead and the clear-pass hoist now count a clear only under a full scissor;
  - BC render targets written through a view of one texel per block (BC4 through RGBA16UI) render into an auxiliary texture loaded with the old
    blocks and copied back through a buffer when the pass ends (`blk_aux`); they had been left out;
  - storage buffers whose address the shader reads from a uniform buffer (21 vertex shaders): `dmsh_build.py` kind `sbuf_ubo` (uniform slot
    = cb slot − 3, byte offset), reflection kind `NVN_RB_SBUFU`, read at bind time with the inline uniform updates recorded so far in the
    submission applied (`pend_read`); argument blocks of those shaders are not reused;
  - the storage buffer write flag is Ryujinx's `BufferUsageFlags.Write` = bit 0 (we tested bit 1, so none was writable).
- **Also found in the prologue:** the BC4 encoder's pixel shader writes an RGBA16UI target, but shaders were built with float outputs (pipeline
  creation failed). When a pipeline fails, the host writes the integer colour attachments the pixel shader writes to `<DM_SHDUMP>/fout.tsv`
  ("key target uint|sint"); `dmsh_build.py` passes them to the translator's fragment output types (Ryujinx answers them from the render target
  formats the same way) and keys the build on them. A draw with no colour and no depth target (1x1 scissor) had been dropped ("none of the
  render targets can create an MTLTexture"): it now gets a Metal pass without attachments, sized by the scissor.
  Chain `530a8546d06c`. Tests: `t_nvn` (timestamps on the guest clock, scissored / masked clears, BC4 render target), `t_refl` (new),
  `t_ub` (`pend_read`), `t_mip_extent` (the scissored clear now writes its two texels; a pass without attachments); each fails with the old
  code.

**Playing it in a window (2026-10-18):** the window front end presented one frame per display tick (60 fps) whatever the game's
interval, and the game's step is per frame, so it ran twice as fast; with game.json `present_interval` "game" the display-link wait takes as many
ticks as the game's interval (30 fps). game.json `window_unfocused` "in_focus" keeps the game in focus while its window is visible but not key
(OutOfFocus is the console's HOME menu: the game stopped whenever the player clicked another window). Frames alternated between two states
(Zelda's cloak and hood, the cave walls, torn models): found with consecutive-frame captures, present already in the morning's build.
- Counter reports wrote their timestamp at replay, before the GPU ran them; the timestamp now appears only at completion (the counter half
  stays in command order for conditional rendering). The large alternations (walls, whole objects) went away (16-frame captures, 14/14 → 0/14
  alternating triples at frames 1500-1515). `t_nvn` checks that the timestamp is not there while the GPU is busy.
- Occlusion counting that starts inside a pass without a visibility buffer splits the pass (it counted nothing; `t_reorder_chain`).
- Virtual cores (game.json `virtual_cores`, host `hle_thread.c`, from MacNativeGames' runtime/threads.c): a guest thread holds one of three
  cores while it runs guest code and gives it up in waits, sleep, yield, exit and blocking NVN calls; TotK keys per-core data by
  GetCurrentProcessorNumber without locks and its main thread shares core 0 with ModuleSystemWorker0. Host-work threads
  (`dm_guest_thread_spawn`, the audio renderer) hold none: the audio renderer kept core 0 and the boot hung.
- What was left, the cloak and the face (every other frame Zelda lost her cloak or her face, or the cloak changed shape): cached command
  handles lost their tails. Tears of the Kingdom records the binds of each draw once per frame parity, with the memory callback off, into a
  512-byte window at slot + GetCommandMemoryUsed of the previous recording, and calls those handles every frame until it records them again.
  Three faults in our command memory combined:
  - its NVN 55 inline wrappers (775 sites in main, gated by the SDK's `nvnPrivate0`, a .bss word that stays 0 here) store a dirty byte at
    command buffer +0x10 before every call, and +0x10 was our `end`: windows ended up to 255 bytes early (…8b0 → …801), so recordings that
    fit went on in host segments (1336 by frame 1300; 4 now);
  - a host segment was reclaimed when the game gave out memory overlapping its recording, but the 512-byte windows reach into the next slots'
    live recordings: a later recording took the segment and its binds became the tail of a cached handle. In even frames Zelda's G-buffer
    draws bound another model's skeleton buffer while the shadow pass bound hers;
  - used did not count the JUMP into a host segment: with only END there, the game's next slot began 8 bytes before the JUMP's end.

  Now `cmd_t` leaves +0x10 to the game (`guest_flags`), a host segment lives as long as the JUMP that links it (in game memory inside a live
  pool, or in a live host segment) and is reused once that JUMP is gone, and the JUMP counts as used. Over a run: 1.28 million CallCommands,
  none to a handle a later recording had written over; 16-frame captures at frames 1290, 1790 and 2090 have no pixels alternating (per pixel
  |N − (N+1)| against |N − (N+2)|; 2.4–6.2 % of the pixels before), and every skinned mesh binds the same skeleton in both passes. Found with
  the pass dump's op trace (`DM_NVN_PASSDUMP_ALL`, `o` lines): the even frames' bind handles jumped into host segments holding another draw's
  binds. The earlier note here that the two frames' draw lists differed was wrong: same draws, different bindings. MacNativeGames avoids the
  same with another design (records in host memory, copies owned by control memory, usage reported as the console encodings would take).
  `t_nvn` 5a checks the dirty byte, the JUMP in used, a host segment surviving an overlapping window and its reuse once its JUMP is
  overwritten; each fails with the old code.

**The first cutscene (2026-10-18):** after the tutorial the game plays its first pre-rendered cutscene, `Event/Movie/DmT_OP_GanonWakeUp_PreRender.webm`,
and crashed: `Extractor::SetDataSource(path)` was not implemented (only the stream-reader source Unity uses), and the game went on to call
`nn::os::LockMutex` on +0x178 of a null object (main+0x2b45c68 → sdk+0x13f5b8). The 28 movies in `Event/Movie` are WebM with one VP9 track (1920x1080, 30 fps,
no sound track: the game plays the cutscene's sound itself). Now:
- `SetDataSource(path)` opens the guest path in place through the fs mount table (`dm_fs_host_file`), and `movie_av.m` hands EBML files to a
  WebM / Matroska demuxer (`host/movie_webm.c`, element layout from RFC 9559 and RFC 8794; every block is indexed when the file is opened and
  read from the mapped file);
- a VP8 / VP9 decoder decodes the bytes the game sends with libvpx, with MacNativeGames' behaviour and pacing (NV12 output described as
  MediaCodec does, the format change with the first frame, at most one frame per game frame on the guest clock, late frames dropped when the game
  runs below the movie's rate so the picture keeps time with the sound). The game ignores both outputs of GetOutputBufferSize (main+0x2b44d68);
  the second is the alignment (SDK docs), 256. Status codes follow the SDK's `movie/Status.h`. libvpx comes from Homebrew and is linked
  statically when installed (`host/Makefile`); the iOS app has no VP9 decoder yet;
- `t_movie` (host tests) encodes VP9 with libvpx, muxes a WebM with a Void element, a BlockGroup with a ReferenceBlock and an unknown-sized
  Cluster, and checks extraction (bytes, times, sync flags, seek), decoding (NV12 values exact, events, end of stream, output format) and pacing
  (one frame per game frame at 30 fps; at 10 fps late frames are dropped and the picture keeps time); each fails with its fault put back.
  `t_movie <file>` probes a real movie: all 6421 frames of the Ganon cutscene decode without an error, 1.0 ms per frame;
- the player draws with an NV12 → RGB shader (`nv12decode`) from agl's `agl_common.sharcb`, which the extractor did not read:
  `engines/bnsh/shader_extract.py` now reads the sharcb archives (12 in TotK: agl, gsys, Terrain, application; layout in the script),
  2478 more shaders, among them 141 that had come only from run-time captures (all byte-identical) and 20 of the 27 that were missing in the
  first play session (all 27 were captured by `DM_SHDUMP` there). The capture holds 27077 shaders and the library was rebuilt from it: 27075
  translate; SPIRV-Cross fails on two of the new ones (a vertex shader of `AglShader.sharcb`, "nullptr", and a compute shader of
  `agl_technique_pfx.sharcb` using subgroup builtins where SPIRV-Cross does not allow them), neither of which has run so far. `c1_guard`: 49
  shaders whose c1 index is not proven bounded (47 before).

**After the movie (2026-10-19):** with the picture there, the game stayed black after the Ganon movie's last frame (30 fps, two draws a frame,
for good). Its player (main+0x2b43xxx) sends every input buffer it can take back with the end-of-stream flag once the extractor is at the end
(main+0x2b45338), and its decoder thread waits with `WaitAny` on holders linked quit, input, output, format (main+0x2b44690). We handed each
end-of-stream input straight back with input available, so input was always signalled, `WaitAny` always returned the input holder and the
output handler (main+0x2b45564), which takes the end-of-stream output and sets the player's end flag (+0x708, read by main+0x2b43ba8), never
ran: a `sample` of the stuck process had 2377 samples in the input handler and none in the output handler. The library's codec does not hand
input back after the end: ACodec's `postFillThisBuffer` (subsdk0 0x2bd214) returns at once while the input port is at end of stream (+0x248, set
in `onInputBufferFilled`). Now the end-of-stream input and every input after it stay in the decoder until Flush / Reset / Configure (MacNativeGames
hands them back as we did). `t_movie` (31 checks): after the end of stream, inputs sent back stay, no input event, Flush gives all four back; the
first fails with the old code. Played: the Ganon movie and the first blood moon movie end and the game goes on.

**60 / 90 fps (2026-10-19):** from MacNativeGames' `game_patches_v143.c` (MIT; their seven controller words and their real-time step method),
in our rules and host:
- `games/totk/rules.py` CUTS: the seven words of the frame-rate controller (main 0x2db174) that lower its minimum interval from 2 to 1. The
  controller still raises the interval to 2 or 3 when frames do not fit.
- Real-time step: the game's step was 60 / (the controller's fps) at its two producers (0x2daa54: ratio, stored at 0x3a22128; 0x3e5638: ticks
  before a 0.5 / 1 selector). New rewriter rule kind `HOSTREFS` (`tools/patch_nso.py`): instructions that address a 16 KiB writable host page
  after the key page (fixups `HOST_PAGE_OFF`, only in modules that use it; the others keep their layout byte for byte), resolved into cuts so
  structck / equiv check them as cuts. The producers now load ratio (+0 = seconds × 30) and ticks (+4 = seconds × 60) from main's page;
  MacNativeGames puts a veneer at 0x3e5658, we do the same in place (x9 free between 0x3e562c and 0x3e5644). `games/totk/frame_step.c` writes the
  mean of the last five present intervals on the guest clock (each 1/120 .. 1/15 s; above 0.25 s or below 1 ms restarts) at every present
  (new game hook `dm_game_present`); `DM_FRAME_STEP_MS` pins it. The loader reads `HOST_PAGE_OFF` (`dm_host_page`).
- `DM_PRESENT_HZ=30..120`: the display link (mode 1) now ticks at the present rate, so one present interval is 1 / that rate.
- `games/totk/check_frame_rate.py <product> <main NSO>` (17 checks): the controller run in Unicorn reaches interval 1 on 10 ms frames, 2 on 25 ms,
  3 on 40 ms and back, sys+0x250 = 60 / interval; the original main never picks 1 (negative control); both producers read the page (the original
  computes 60 / 30 and ignores it); `tests/t_frame_step.c` (the mean, the clamps, the page layout). `verify/regress.sh` OK (main cuts 16).
- The product with these rules is `work/build/totk/product60` (`host/dmhost work/build/totk/product60`; `DM_RENDER_RES=<w>x<h>` sets its scene
  render size, item 52 below; since item 57 its changes are code options, `options.default` turning on all three and `DM_OPTIONS=none` none);
  the default product was left at 30 fps
  while the blood moon crash below is open. A 75 s prologue run: interval 1, frame time p50 16.8 ms.
- RomFS overlay for 60 fps and up (601258f): `work/build/cache/dm/venv/bin/python -I games/totk/romfs_overlay.py work/data/switch/totk-1.4.3/RomFS
  work/build/totk/romfs_overlay` builds it from the game's own RomFS (the quick menus' background was black at 60 fps; the game over menu would
  wait forever on a one-frame wait with the real-time step); the host serves it first when it exists (`games/totk/defaults.c` sets
  `DM_ROMFS_OVERLAY`; empty `DM_ROMFS_OVERLAY=` turns it off). Test: `games/totk/tests/t_romfs_overlay.py <RomFS>`.
- On the Mac Tears of the Kingdom runs with the TBDR rewrites off (`games/totk/defaults.c`, `DM_NVN_TBDR=1` turns them on): on the M5 the dive
  measured GPU p50 8-10 % lower without them at the same submission time, and mid-submission commits and layered passes need them off.

**Flicker in the dive from the Great Sky Island (2026-10-19):** many objects flickered while falling from the first cliff, and some frames were
wrong over the whole screen (rock walls in front of the camera, a flat ground). Repro: a manual save at the cliff edge, the dive scripted with
`DM_KEYS="A@26.5,A@31,A@35,LSU@f1380+240,X@f1400"`, and `DM_NVN_LIVEROWS=<file>` (16 rows of every presented picture; a present that differs
from both neighbours more than they differ from each other is a wrong frame): wrong frames at presents ~1719 / 1893 / 1913 in two of four runs.
- Ruled out by measurement, with probes since removed: occlusion queries (every samples-passed report forced large: still wrong frames; the
  occlusion table that replaced a 256-entry ring stays, it is right but was not the cause), CALLs of re-recorded command memory (each recording's
  hash checked at every CALL: 0 mismatches), sync waits that time out (none), GPU lag across frames (the previous frame had completed at every
  submit), the present waiting for the GPU (wrong frames with it on).
- Cause: `DM_NVN_GPUWATCH=<first>-<last>` copies the uniform ranges a submission binds at its commit and compares them when it completes: in the
  dive 1041 (frame 1814), 662 (1817), 128 (1895) and 197 (1915) ranges changed meanwhile, 0 in the other frames, all vertex stage slot 4, 256
  bytes (the objects' transforms). Once a frame is submitted the game's workers rebuild those per-object constant pools; on the console the GPU
  has read them by then, here the submit replays for 11-17 ms first. MacNativeGames found the same (main+0x87a604 from main+0x874f50, "rock walls
  while jumping"; their `usnap`). (A first, page-granular version of the watch also flagged pages that main+0x8cbbf4 writes next to the ranges.)
- Fix (method from MacNativeGames' usnap, MIT, written anew in `gfx/nvn/nvn_mtl.m` `mtl_sub_snapshot`): when a submission starts, every uniform
  range it binds is copied into its argument arena (ranges up to 256 bytes apart in one pool merged, at most 1 MiB, each at its offset modulo
  256); uniform bindings (graphics and compute) and replay-time reads (`pend_read`, `ubo_float`) use the copy. A GPU write within the submission
  (inline update, buffer copy, texture-to-buffer copy, a writable storage buffer, the storage buffer table c0) drops the copies it reaches from
  then on; a range a GPU write of an earlier submission still running reaches is not copied. `DM_NVN_UBO_SNAPSHOT=0` reads live memory. Cost in
  the dive: ~12,200 bindings in ~1,200 copies, 2.4 MB, 0.9 ms per submission on the submit thread (MacNativeGames copies on helper threads).
- Checks: `gfx/tests/t_usnap.m` (29, also in run-m3): a draw reads the bytes of the submit call although the CPU rewrites them during the replay,
  and the rewritten ones with snapshots off (negative control); after an inline update the draws before it read the copy, those after it the
  update; merging and alignment; a running GPU write keeps its range out. In the game, snapshots off: wrong frames at presents 1719 and 1893, 707
  changed ranges read from memory at frame 1814; three runs with snapshots (one with the present not waiting): no wrong frame, the ranges that
  changed (866 / 529 / 723 at frames 1814 / 1815 / 1817) all read from the copies, none from memory. Frame times unchanged (30 fps, p50 33.3 ms).
- Diagnostics kept: `DM_NVN_GPUWATCH=<first>-<last>` (above), `DM_NVN_LIVEROWS=<file>` (window play: finds single wrong frames without pausing the
  game) and `DM_NVN_LIVESHOT=<first>,<count>:<path with %d>` (those presents in full).
- Lesson: MacNativeGames' `nvn_mtl.m` describes this symptom and its fix in the comment above its `usnap`, and the clone was at hand. Search the
  references for a symptom (its words, the game, the area of code) before building probes; then measure to confirm the cause here.

**Open (2026-10-19):** after skipping the second blood moon movie (`DmT_SY_BloodyMoonDarkZelda`, stopped at frame 233) the game crashed 3 s later in
its resource control thread (0x1006, loop main+0x154bd0, which names `ClearCachesForKeepAllocSize` / `Unload(ForSync)`): main+0xa2ef08 reads the
resource at +0x28 of a binder of type 0xe (+0xc) after waiting for it (`WaitLightEvent` at 0xa2ee2c) and +0x28 is null; registers name
`Obj_TreeWhiteBirch…`. The SDK's `WaitLightEvent` trusts a 0 result of `WaitForAddress`, and our address arbiter only returns 0 from
`SignalToAddress`. Not reproduced yet. The thread dump now marks the thread that writes it, and `DM_CRASH_MEM` takes `*xN` (one dereference).
Also seen: `nn::os::WaitForAddress(long const*, long)` (sdk 0x146fb0) uses arbitration type 3 (64-bit wait if equal), which svc 0x34 treated
as type 0 (fixed in plan batch 1, item 1); main and subsdk0 do not import it. The vertex shader `1eee2726aae7493e` (SPIRV-Cross "nullptr") is now drawn with.

Known gaps: alpha test and depth-stencil (stencil) views are not modelled; an integer render target's partial clear is not drawn (red line); GPUs
without BC (iOS) do not get the BC render target path; iOS needs `DM_CACHE` and the large heap; hid six-axis and vibration are stubs; no 2K
canvas (both in the 2026-10-19 review, not done yet). The two 4x4 textures that were re-uploaded every frame are checked by content now
(small-texture hashing, 06c80bd). Diagnostics added on the way: `DM_NVN_NOCULL`, `DM_NVN_RTCLEAR=<serial>`, `DM_NVN_TEXSNAP` (ordered on the
replay's encoder, `@WxH` and ranges), `DM_NVN_TEXNZ`, `DM_NVN_TEXCLASS`, `DM_NVN_REUPLOG`; the pass dump prints cull / depth range / index type,
the inline uniform data, the first vertices and the counters seen by conditional rendering. Run after
`make -C host GAME=totk`:
`DM_GAME=totk DM_ROOT=$PWD/work DM_SHDUMP=$PWD/work/build/totk/shader_capture DM_SAVE=… DM_TEMP=… DM_CACHE=… DM_WATCH=120 host/dmhost` (the
stage map and library directory come from the profile; rebuild them with `shmap_from_capture.py` and `DM_GAME=totk dmsh_build.py`).

Upstream PR #55 (x18 scan prefilter, n3crosis) is in `tools/patch_nso.py` (76 s → 16 s for manosaba's main).

## Upstream and other ports to draw from

Reviewed 2026-10-17 and again 2026-10-19 (candidates in "Review of 2026-10-19" below, then a wider pass the same day: "Wider review of 2026-10-19"). Fetch them into a scratch repository, read only, never run their code; port by hand with a test per item, check our
code first (several fixes are already here in another form), and credit the source in the commit and the README.

### Upstream: [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)

Reviewed through 21cf97b91823111ead237858ea79929afacf71a5 (2026-10-17), then through 9393b00 (2026-10-19).

- Ported 2026-10-17: buffer ↔ texture copies honour `nvnCommandBufferSetCopyImageStride` (86b1315a84cec67cfef0b3eab125dbc3c4489cc4, SepheTT;
  `gfx/nvn/nvn_copy_pitch.h`, `t_copy_pitch`; manosaba never calls it; d21348c); `UILaunchScreen: {}` instead of an empty `UILaunchStoryboardName`
  (21cf97b91823111ead237858ea79929afacf71a5, BossaMelon; upstream saw iPhones start in the legacy compatibility size, this app already rendered at
  native size on the iPhone 17 Pro with iOS 26 and both iPads; ce466a9).
- Already here in the same form: unresolved weak imports stay NULL (b84657b25735d96a7263a1b4a7402159a17435a5, `host/hle.c`), `DT_RELR`
  (`host/loader.c`). Not applicable: D2R's Mac mouse (098d9f5e24407480da7cf0d21c5d88b871da6949). dc53e7a8eca1f170009b722d390fac7e0d050288
  was reverted by 21cf97b.

### Derivatives of d2r-mobile

All MIT and keep jhaizhou's LICENSE; they use the old `dm/` layout.

- [seedds/nxnative](https://github.com/seedds/nxnative) (main, reviewed through 20cba12c4299d77f05b6bbfd3dfa42d6c6035da4, then through 64b79de on 2026-10-19; seedds/smbw-mobile points at the same commits): NSP → IPA; its
  README at that commit lists Super Mario Bros. Wonder, Fire Emblem Engage, Metroid Dread, 13 Sentinels, Super Mario 3D World + Bowser's
  Fury and Breath of the Wild 1.9.0 as tested on an iPhone and playable (iOS 26); the BotW profile's own header still says "in bring-up".
- [Johnoooob/nx-port](https://github.com/Johnoooob/nx-port) (main, single commit 3e6366b86a510361d451618ffd7c45dea5549492, unchanged).
- [Kamisorara/d2r-mobile](https://github.com/Kamisorara/d2r-mobile) (main: only upstream merges since 95d6caa; branch
  face-buttons-by-printed-glyph).
- [4ppp44/d2r-mobile-ios17](https://github.com/4ppp44/d2r-mobile-ios17) (branch codex/ios17-a16-v1.0.17): an experimental iOS 17 / A16
  Metal 3 build (406028335f5f0fa65c5a421867abcde0987d0a9e, b638a1886b16f9a9d5c10eaa118231fb8544dfb9); its author reports one short manual
  test on an iPhone 14 Pro Max with iOS 17.0. For running on iOS 17 devices.
- TommyLau/botw-mobile: gone from GitHub (404 on 2026-10-17). Its commits listed below can no longer be fetched from there; nxnative now
  carries Breath of the Wild.
- [ly05010419/MacNativeGames](https://github.com/ly05010419/MacNativeGames) (main, reviewed at 41e1e0caf43d58c4af3c478ca2d1bafd9dba7093,
  2026-10-18, and in full at 70729e9 on 2026-10-19): Tears of the Kingdom 1.0.0 / 1.1.2 / 1.4.3 on the Mac, its NVN layer from d2r-mobile's (`games/totk/third_party/d2r_gfx`).
  Ported (see the TotK section): offline BNSH shaders, stale texture views, quad clears, BC render targets, storage buffers addressed from uniform
  buffers, the storage buffer write flag; then the real-time frame step and the 60 fps controller words (dba469f), uniform snapshots (146354a),
  and the 2026-10-19 review items ("Ported 2026-10-19" below). Not yet: the 2K canvas and MetalFX scene / output upscaling, frame interpolation,
  gyro and rumble, BC → ASTC transcoding. With those its 1.4.3 notes give 83.9-110.2 fps averaged over 15
  fixed-camera points on an M4 (docs/v1.4.3-port.md), and about 27-30 fps with the game's own controller.

### Independent: [c22dev/mush8](https://github.com/c22dev/mush8)

main 1b2e9b875f3beb94802624f055e7a041a473ee3c (first commit, 2026-10-16): Mario Kart 8 Deluxe on iOS and macOS with LAN, online
(lan-play) and wireless multiplayer; its own implementation in Rust (`nxpatch` rewriter, `nxhost`, `nxshader` Maxwell → MSL, `nxfs` NSP / NCA
extraction). **GPL-3.0: read it for ideas and behaviour only; no code goes into this MIT repository.** Worth reading: the audio renderer
(`crates/nxhost/src/audio`), touch controls (`gfx/touch.rs`), WebM movies, NSP extraction (`crates/nxfs`), and its IPA, which is ad-hoc
signed with `com.apple.developer.kernel.increased-memory-limit` (`make-ios.sh --ipa`, `ios/Mush8-sideload.entitlements`) for signers that
read the app's own entitlements (AltStore does, see [ios/README.md](ios/README.md)).

### Already ported

Thread exit off the guest stack (014c5b3), crash report stderr trylock (1f1929e), dirty tracking of shared host pages (e4292e1), RomFS name
index (af27ace), save full-disk robustness (eb86cfc, from upstream b94670c), msl_retarget reflections (56fcd40, from upstream 1784563).

On 2026-10-17, from nxnative: address → memory pool lookup by last hit and a sorted index (`gfx/nvn/nvn_pool_find.h`, `t_pool_find`, d6cd8a8…; d48fb4f);
a compatible view when a shader declares another texture type than the bound texture has (`tex_fit`, with the declared type now exact for
multisample textures), 1D textures as one-row 2D, a zero write mask and no blending for colour outputs the fragment shader does not write
(42a50ef…; 621bd6d); `DM_KEYS` timed by presented frames (`A@f3600`, d6cd8a8…; the left stick keys were already here; 9475f85). Each has a unit test with a
broken version that fails it (`t_pool_find`, `t_tex_fit` on the GPU, `t_hid_script`). On the Mac a trial scene loaded with the old and the new
host gave no red lines and equal screenshots after the load; no texture type mismatch happens there, so `tex_fit` has only run in its test.

On 2026-10-17, after nxnative's nx_extract (aa8cc5c…, LibHac 0.19.0): `tools/game_extract` (`prod.keys` + `.nsp` / `.xci` → ExeFS and
the merged RomFS), our own code with XCI input, Horizon split-file folders, only the keys LibHac classes as common, and a check for
personalized tickets added. LibHac's GitHub repository is gone (404); the NuGet package is unlisted but still served, MIT, pinned by content
hash. Checked with manosaba's base and update NSPs: ExeFS and all 667 RomFS files equal to the console's extraction by SHA-256, and
negative controls (base game only differs; a damaged NSP fails the hash check and leaves no output; a ticket marked personalized, a split
folder with a missing part, a key file without the header key and its sources are refused; a split folder of the base NSP gives the same
RomFS; no key value in any output). Not run yet: XCI input (no XCI dump here) and a real personalized ticket.

### Port when a game needs it

- **AudioRenderer** (first-party games): nxnative `dm/host/hle_audren.c` (50a9c65b5f402b796cc7e7f0b011e11b2015f30f, the SDK renderer
  in-process; SDK 20 rendering through the locked path ff74840187d5ca4dda914bb80ffbd86cb0cce96b); nx-port's own PCM16 / DSP-ADPCM mixer
  (3e6366b…); mush8 (ideas only). Ported for Tears of the Kingdom in a267ec1 (`host/hle_audren.c`, the SDK renderer in-process).
- **Deferred texture binds** read when the command executes, not when it is recorded (`nvnCommandBufferBindTexturesDeferred`): nxnative
  d6cd8a812a1047dff8f660f604d0a46033752242. Ported for Tears of the Kingdom in a267ec1 (the readers refresh the handles, `bh_fresh` in
  `nvn_mtl.m`).
- **Graphics**, nxnative: a texture attached at two colour slots is attached once (ported through tomodachi-native's variant, `rt_dup_slot`), cube textures as 6-layer 2D arrays for cube-array views,
  compressed render targets skipped with a red line instead of a Metal abort (d6cd8a812a1047dff8f660f604d0a46033752242; the first touches the
  attachment setup and the pipeline key in several places); a snapshot of
  the attachment for shaders that sample what they write in the same pass, per shader by a profile key, with the device self-check
  `DM_NVN_MAGSCAN` (the `nvn_mtl.m` part of 20cba12c4299d77f05b6bbfd3dfa42d6c6035da4); the submission handed to the GPU every 64 draws for games
  that wait for the GPU every frame (`DM_NVN_CUT`, ff74840…).
- **Small guest stacks**: host work on a per-thread host stack (`HLE_FORCE_BIG`, `hle_bigstack.c`, 42a50effdda418fd03d9e15c569d75a3a466d1d4: a
  save thread with 8 KB; NVN functions other than command recording, d6cd8a8…). Our HLE functions run on the calling guest thread's stack too
  (imports resolve straight to them), and the file system ones keep path buffers on it. Not ported yet: an assembly trampoline that only
  carries register arguments, and it cuts the guest backtrace of crash reports at the switch; wants a game whose small stacks overflow.
  MacNativeGames' version keeps the backtrace: see "Wider review of 2026-10-19". Done in plan item 40 (`host/hstack.S`).
- **Diagnostics**: `DM_NVN_KEYDUMP` (every input of one fragment shader's draws) and sampler / swizzle output in PASSDUMP
  (734a286328d18404fd5a67785a1e05d2149c5986).
- **nn::ro .nro modules**: nx-port `dm/host/hle_ro.c` and loader changes (3e6366b…).
- **VP9 movies** with libvpx: nxnative a9e4f18ed17b17bb5cd8eef422464e94a017654b (decoder hooks), 5e84062fad1f07e95f59c1cc6a94918c463d077e
  (libvpx). Done our own way in a8c3ff1 (`host/movie_webm.c`, libvpx, MacNativeGames' semantics).
- **Shaders** from Nintendo's containers: nxnative `dm/gfx/tools/shader_split.py` (Yaz0 SARCs, BNSH, BAHS in 42a50ef…; ours:
  `engines/bnsh/shader_extract.py`, 70cb843 and 17766ae); older Unity bundles:
  `dm/gfx/tools/unityfs.py` (e3cd2ff8ff0eb84a62280ef70e90c60753e546e6).
- **Tools**: nso_syms.py (aa8cc5c0cd8bd5d09bcacb019f7832df3a164452); nso_fnmap.py, which carries cuts to a new build
  of `main` (b5507f2aac7e1d1f5512de750f5810a550162b04, also for a manosaba update); build_ipa_from_nsp.py
  (0d763ec864344610cc41548a2ad01cd55def3182); DLC packing (e452f52b607bdf6f960eb843f20aeb29b803dec8); the app icon from the game's icon
  (1cd9bfb84b31fad5b413ab20baa977c16600f50a).
- **On-screen gamepad** for games without touch: nxnative `dm/ios/Sources/DmGamepad.m` (dc8a49ad7471d3f0b767032a0b755f87a98c1912,
  d41fdd6ed1643ed7f97099f18ab6fc7360786a1b, 4a0f9acbcf8e5acad01b1d6b5919bfb3e3cd0998; 3D layout with D-pad, right stick and L3 / R3,
  b65c8b2cfe43d0ccbc2dcd24068d849ff4eb6baf).
- **NVN / graphics** from botw-mobile (no longer on GitHub): depth and stencil sampling modes (b795ac15d620f42986df3d594e846bf03f83f1ea),
  mip import before partial texel writes (549fb9d7be4362e9b82138a674a5305a722ab1a5), native sampler defaults
  (767a276615a6c1c1d20a7b98aec17dd170d8e3b3), declining fast-clear hints (0d80bff4eec2668441ff4ddd075796e3ec674099), GPU timestamps
  (9eebd8d746621b851189a7b4679489388911e7b7), dirty tracking with one record per host page (1d69c8ae9cea2e83584314f8044b55c839c95c9e); nxnative
  GPU timestamps on the guest clock (b6b3da202abbd9ca73f45057920c7a9fdfcc0eb6), depth/stencil clear mid-pass
  (7058f43497c6eb26eea351ec4e45db3bf0d417ae), Downsample as a Metal resolve (13ff4f51a10ff6c4207a1e909e430ddd9c0644d3), per-game present
  interval (9745da2061b09fea0ea524c7d5369ad8e1357539), pool finalize dropping texture ID views (799df3c5edd00281c40ae8889a10c55cefe93616, same
  leak class as a593388); nx-port geometry shader point-to-quad, alpha test, newer NVN object sizes (3e6366b…).
- **iOS 17 devices**: 4ppp44/d2r-mobile-ios17 (above).
- Small: an ad-hoc signature for LiveContainer (Kamisorara 95d6caa903bc19e602493bb5a5568650d39f52cf), gamepad face buttons by printed glyph
  (8429dc1727cbca079c60427e3b59258683f1c924; an earlier variant, the fix is 55c6fba / upstream 46cb318, see "Wider review of 2026-10-19").

### Review of 2026-10-19

All references fetched again (blobless, read only). New since the last review: upstream 1 commit, nxnative 33 (9579030..64b79de), MacNativeGames
3 plus a full pass over its TotK code, 4ppp44 1, LASRecomp `main` 17 (README) and its `beta_5` / `multi` branches (300-500 commits: other
games, Vulkan, randomizer), SkyRecomp 9 (PC / Vulkan: NIS scaling, LayeredFS mod manager), mush8 / tomodachi-native / Kamisorara only
small or merges; d2r-mobile/d2r-mobile is a rewritten copy of upstream's history up to 21cf97b with no code of its own. Checked against our
code; "seen" = the symptom is in our logs or shader cache.

Correctness, small (in this order):
- Retired textures and buffers kept alive by autorelease: `mtl_sub_begin` runs `defer_drain` / `fin_drain` / `warm_claim` before it pushes the
  submission's pool, on a guest thread without one (nxnative 0fc0ce4, Metroid Dread's GPU memory grew by gigabytes).
- Driver segment c0 for vertex and compute shaders (nxnative 9579030, MacNativeGames `drv_fillable` / `driver_bank_fill`): `dmsh_build.py`
  `drv_reads` matches `fp_c0` only, so 229 vertex and 146 compute shaders of the TotK library read an all-zero c0 (seen: storage buffer table
  `cp_c0[53]`, dispatch size `c0[32]`, point size limit `c0[97]`). Fill 0x200 (thread groups), 0x210 + 16 r (compute uniform table), 0x610
  (2047.9375) too.
- Automatic block height `(ah + ah / 2) / 8`, ours `+ 7` (`nvn_tex.c`; MacNativeGames cd85f5b, 16 of 40 boundary cases wrong against the SDK;
  check manosaba's screenshots). D16 load clears quantised like fragment depth (MacNativeGames 3d90e41).
- iOS audio session `AVAudioSessionCategoryOptionMixWithOthers` (upstream 9393b00): other apps' sound keeps playing.
- The two shaders that fail to translate (nxnative 771f62f: register texel offsets, four-offset gathers; subgroup ballot lowered as
  MacNativeGames does); seen: `1eee2726aae7493e` fails to load in play.
- `nvnTextureBuilderSetPackagedTextureData`, `nvnCommandBufferSetPrimitiveRestart` (both have them; seen: TotK calls both).

Correctness, medium:
- A registration whose serial was finalized redirected to the texture living at that storage now (MacNativeGames `live_put` /
  `nvn_tex_live_at`); seen: 56 "created again" red lines in play logs.
- Clears on a left-out duplicate attachment slot (nxnative 7dde056 `clear_color_tri`); seen once (red line 75). A growable dirty-range table
  (same commit; TotK peaks at 3067 of 4096).
- One shader rebuild for: `-fpreserve-invariance` (nxnative f1cc6be: depth pre-pass vs G-buffer blocks), vertex outputs starting at (0,0,0,1)
  (e81d66f), precise math for the integer-division idiom MacNativeGames found broken (`MTLMathModeSafe`; costs speed, measure).
- 8-bit indices: restart 0xFF → 0xFFFF, and widening on the GPU when a GPU write earlier in the submission made them.
- GPU results written back to CPU-visible pools on `InvalidateMappedRange` (MacNativeGames: black terrain blocks after travel).
- Textures sharing one storage (MacNativeGames `stor_*`: black geometry, full-frame flashes from NaN depth); large.
- WaitSynchronization order as Horizon (signaled, timeout 0, then cancelled; LASRecomp 1144aea checked against Atmosphère); do not take its
  `value - 2` for SignalToAddress mode 2.
- `nvnQueueFinish` without waiting for queued presents (nxnative 3b72aea, a 78 s → 6 s load on iPhone); recheck our stall note first.

Performance (TotK at 60 fps; MacNativeGames' numbers): acquire sync not fenced to the newest submission, which needs the pending-write table
kept across submissions (theirs 16384 entries, ours 256 reset per submission); GPU keep-alive (GPU p50 12.1 → 9.1 ms, costs power); commits
every 60 / 75 draws (11.66 ms vs 12.50), at odds with our TBDR passes; dirty-tracking cost (pool scan ~14 % and checks 4.5 % of the replay,
small-texture hashes); a render-state filter (~30,000 redundant encoder calls a frame); uniform rename (~80 copy encoders, ~23 split passes a
frame); one compute encoder for consecutive dispatches; an upload staging pool; identical texture registrations skipped; an encoding thread
(replay −18 %); layered / cube-face passes.

Features: the 2K canvas and MetalFX, RomFS overlays for 60 fps (black quick-menu backgrounds), gyro and rumble, BC → ASTC for iOS, a GPU
memory budget and pool range checks (MacNativeGames added them after four macOS kernel panics).

Not to do: a Metal binary archive on macOS 26 without guarding `serializeToURL` (LASRecomp turned it off after crashes).

### Ported 2026-10-19

Every item above but three features (below), each ported by hand with a unit test and a broken version that fails it; gfx tests (Metal 4 and Metal 3) and host
tests pass at the end; Tears of the Kingdom's dive (`fl/trial.sh`, frames 1500-2400) shows no wrong frame; manosaba's four screenshots stay within
run-to-run variance (s600 / s2400 differ about 0.15 % between two runs of the same build, s1500 / s3300 identical). Numbers are from that dive on an
M5 (16 GB, macOS 26), 30 fps product, two runs where stated.

- Shader chain 1e41705de87b (686b81e): driver segment reads per stage, two translator fixes (shader `1eee2726aae7493e` builds), vertex outputs
  start at (0,0,0,1), `-fpreserve-invariance`, `-fmetal-math-mode=safe`, a Metal compile cache (`gfx/tools/dmsh_mtlcache.py`).
- Correctness (06c80bd): autorelease pool (`t_retire`), c0 fills (`t_drvseg`), block height and D16 clears (`t_tex_auto`, `t_d16clear`),
  SetPackagedTextureData / SetPrimitiveRestart and GPU widening of 8-bit indices (`t_restart`), storage follow (`t_live`), duplicate-slot
  clears and the growable dirty table, write-back on invalidate (`t_wb`), QueueFinish (`t_nvn`). WaitSynchronization order in
  4dd984d (`host/tests/t_waitsync.c`). MixWithOthers in 46b63f4 (not yet run on a device). Invariance, vertex output defaults and safe math are part of the chain.
- Textures sharing a storage (06c80bd, `t_stor`): measured first, 139 reads of an aliased texture after its partner was rendered (564x81 R8,
  25x25 pairs, CPU_NO_ACCESS pool). With one MTLTexture per (storage, layout, format) the transient render targets re-initialized every frame
  keep their texture: submission time p50 3.41 / 7.96 / 4.30 / 6.65 → 2.41 / 6.49 / 3.38 / 5.38 ms (frames 1500 / 1800 / 2100 / 2400), GPU
  allocated 2989 → 2300 MB, RSS 4615 → 3921 MB at frame 1500.
- The "created again" red lines: the loading screen samples two finalized BC4 textures (IDs 13963 / 13973) through their descriptors; making them
  again from their storage is what the console reads, so it is an info line now unless the content is lost, and the texture stays 600
  submissions (it was made again every 16).
- Pending writes across submissions + acquire sync (`t_pend`), keep-alive (`t_keepalive`), chunked commits (`t_chunk`) and a cheaper
  uniform snapshot (radix sort, repeated bindings once, copies in parts; 0.34-0.76 → 0.23-0.43 ms a submission; `t_ussort`), render-state
  filter (`t_esfilter`), one compute encoder (`t_drvseg`), upload staging pool (`t_uppool`), identical registrations (`t_live`).
- Dirty-tracking cost (`t_texcheck`, `t_pool_find`): check once per submission, content hash for textures up to 4 KiB, views kept across
  serial-table steps for other serials and (GPU textures) across guest writes, contiguous pool index + address cache. Submission time p50 −12..14 %;
  the title's re-uploads 1605 → 11 and write-protect faults 967 → 2 by frame 900; `DM_NVN_DIRTYCHECK=1` finds no missed change.
- Uniform rename (`t_ubren`): about 100 inline updates a frame no longer end their render pass; GPU p50 7.97 → 6.78 ms, p95 11.31 → 7.92 ms.
  The first version dropped the snapshot when it wrote the updates, after which every update of the range was written before its draw again; the
  private copy is now the snapshot with every update of the submission.
- `fin_drain` 0.69 → 0.04 ms a submission (released copies in due order, released views in one walk; `t_snapreap`, `t_findrain`).
- Encode stage (`gfx/nvn/nvn_render_stream.h`, `t_rstream`): implemented and off (`DM_NVN_RENDER_STREAM=1`): two runs each, submission time
  p50 lower in light stretches (3.1 against 3.4 ms) and 0.3-0.5 ms higher at frames 1800 / 2400 (the replay thread waits for the encode thread before every copy and dispatch).
- Layered passes (`t_layer`): the cube filter's per-layer passes merged through the vertex amplification view mapping (no shader patching;
  a GPU probe showed the offset works without a layer output and without a topology class, which would refuse vertex shaders writing point
  size); about ten merges a frame in the title and menus (GPU p50 −13 % there), none in the dive. MacNativeGames' six-attachment cube groups:
  none in our scenes.
- Found on the way: `pso_predict_rest` restored only the draw state, so the draw that asked for the prediction took the last scissor walked over
  (first draw of new pipelines; `t_ubren` case 0).
- RomFS overlay (601258f), GPU memory budget and pool range checks (06c80bd, `t_poolcheck`; no pool refused in Tears of the Kingdom or
  manosaba).
- Not done: 2K canvas and MetalFX (code patches with a veneer, which the rewriter cannot place yet, plus a HeapDef overlay and a larger
  application pool), gyro and rumble (needs a controller to check), BC → ASTC for iOS (Tears of the Kingdom does not run on iOS yet).

Not worth porting: nxnative's prebuilt .NET DLLs, Android/Vulkan and MoltenVK runtimes (dodola, imink/hades-ios), the upstream D2R-only
parts. Forks of d2r-mobile with their own pushes are mostly branches for pull requests that upstream has merged; on 2026-10-17 the renamed
ones (jeoichu-rgb/switch-mobile, Kelvin-Link/ns-mobile, wysl/-game-d2r-mobile) had no commits of their own.

### Wider review of 2026-10-19 (to do)

Eight reviewers in parallel, one group of references each, read only (nothing of theirs built or run): new commits on every branch, all pull
requests and issues, forks with commits of their own (forks pushed after creation, compared with their parent through the API), and the code as
it stands against ours. Reviewed through: upstream 9393b00 (39 PRs, 47 issues; 1086 forks, 19 ahead, 157 branches compared), nxnative 2b31dbd (4
PRs, 5 issues, 4 forks ahead; then through 19d7a70 the same afternoon, items 73-77), MacNativeGames f5cc151 (13 PRs, 7 issues, 2 forks
ahead), LASRecomp main d23597d, beta_5 7597ec3 and 15 other
branches (131 PRs, 63 issues, 6 forks ahead; hjqcan's fork carries a `multi` branch 205 commits past beta_5), mush8 975040b (GPL-3.0, ideas only;
3 PRs, 2 forks ahead), tomodachi-native 5587d1b, nx-port 3e6366b, Kamisorara 1539d80, 4ppp44 2a7b1c6, SkyRecomp d876287, BotWRecomp 2b84b82, and
25 projects found by search. "Checked here" = the gap was confirmed in our code when the reports were merged; the rest is the reviewer's reading,
to confirm before porting.

Carried over from "Review of 2026-10-19" (not done there):
- The 2K canvas and MetalFX scene / output upscaling (MacNativeGames): code patches with a veneer, which the rewriter cannot place yet, a HeapDef
  overlay and a larger application pool. The scene resolution patch below (PR #19) is a smaller first step.
- Gyro and rumble: needs a controller to check; the references below.
- BC → ASTC for iOS: waits until Tears of the Kingdom runs on iOS (iOS items below).
- Checks not run yet: MixWithOthers on a device (46b63f4); the game over flow with the overlay in play (checked by bytes only,
  `games/totk/tests/t_romfs_overlay.py`); manosaba's iOS app rebuilt with chain bab8d4746968 (Tier 2; before it 1e41705de87b) and run on the
  devices (its metallibs are built in `work/build/ios/dmsh_b/b-bab8d4746968`; the last device builds recorded are from 2026-10-16).
- Open: the blood moon crash ("Open (2026-10-19)" above); svc 0x34 type 3 and the host stack item below bear on it.
- The encode stage stays off (`DM_NVN_RENDER_STREAM=1`); the translation thread below takes its place as the plan.

New references:
- [T5eng/nxnative_totk](https://github.com/T5eng/nxnative_totk) (MIT, 1c22d16): Tears of the Kingdom 1.4.3 on an iPhone Air (iOS 27.0.1) as
  patches on MacNativeGames: boot, saves, play, audio and touch. Its `docs/TECHNICAL.md`: about 6 GiB of address space below 2^39 on iOS 27 (heap
  and alias reserved anywhere, then checked against 2^39), arm64-iphoneos metallibs (MSL compiled on the device gave argument encoders of length
  0), opus and libvpx cross-built for iOS, a translation thread (frame p50 22.9 → 16.67 ms).
- [Nishikori-Yui/lordran-native](https://github.com/Nishikori-Yui/lordran-native) (MIT, from nxnative, Dark Souls Remastered, 8f5b96a): alpha
  test, occlusion counts across submissions, command-buffer FenceSync, sampler reduction, each with GPU tests.
- [atone/nxnative](https://github.com/atone/nxnative) (MIT, 185cfda): Pro Controller motion (HID report 0x30) and HD rumble (report 0x10).
- [GirlNet/d2r-mobile](https://github.com/GirlNet/d2r-mobile) branches `codex/p5r-runtime` and `codex/p5r-shaders-verified` (Persona 5 Royal
  bring-up): sampler LOD bias and reduction, NVN functions we lack.
- [catoncat/d2r-port-radar](https://github.com/catoncat/d2r-port-radar) (MIT): an index of derivative ports refreshed every few hours, with UE4 /
  CRIWARE findings; start the next review there.

Correctness, small:
- **svc 0x34 type 3** (checked here): `host/hle_thread.c` treats every type but 2 as a 32-bit "less than". Atmosphère's address arbiter has type
  3 = wait if equal on a 64-bit value (8-byte aligned) and refuses unknown types for svc 0x34 and 0x35; the SDK's `nn::os::WaitForAddress(long
  const*, long)` (sdk 0x146fb0) uses type 3. With a race test as LASRecomp's `tools/test_condvar.c` (a user-space adder against the kernel's
  updates; a plain store instead of the compare-and-swap must fail it). Bears on the open blood moon crash (`WaitLightEvent` trusts a 0 result).
- **Controller face buttons swapped twice on Nintendo controllers** (checked here): `host/gamepad.m` swaps by position when `is_nintendo`, which
  its own comment says comes from the header convention only. Upstream 46cb318 (issue #57: a Switch Pro on iPadOS 27.0.1 recognised as Nintendo
  and still swapped) maps buttonA..Y straight and has an 18-case `t_padmap.c`; Kamisorara 55c6fba is the same fix (8429dc1 under "Small" above
  was its earlier, wrong variant).
- **Three scans ignore the BindProgram stage mask** (checked here): the Q scan of `defer_try` and steps four and five of `fuse_try` take the
  program as is instead of `prog_bind`; with Unity's two-call binds (manosaba) a deferral can miss a sampled attachment and step five never
  fuses. Upstream PR #70 (open, SepheTT) covers every site with tests.
- **1,568 Tears of the Kingdom shaders missing from the offline extraction** (checked here: all 27,101 of our keys are among nxnative's 28,669):
  BAHS `.sharcb` entries share control sections but point at different code, and `engines/bnsh/shader_extract.py` takes one code area per control
  section. nxnative `dm/gfx/tools/shader_split.py` `bahs_shaders` reads the entry table (`agl_technique_pfx` 777, `agl_technique_shdw` 300,
  `agl_common` 174, `agl_technique_lght` 99, ...), plus the Title layout's `bgsh` and the older control layout of
  `Lib/NintendoSDK/TextureShader.bnsh`. None was missed in our runs so far (title, prologue, dive); later areas and iOS (no capture at run time)
  need them.
- **FMZ multiplies** (checked here: `Fmz` is decoded and used nowhere under `Instructions/`): Maxwell gives 0 for 0 × Inf / NaN with FMZ, IEEE
  math gives NaN, which blurs spread (tomodachi-native a0aa6c2). Shader chain bump.
- **SHF with a clamped or zero shift, I2I.SAT across signedness** in the Ryujinx translator (LASRecomp d4c2ff6, PR #134: 29 hand-worked vectors,
  15 failed on their old translator; ours read, not run). Run their vectors through our chain; scan the TotK library for those forms.
- **Sampler LOD bias and reduction** (checked here: `lod_bias` is stored and printed, never applied): `MTLSamplerDescriptor` `lodBias` /
  `reductionMode` (macOS / iOS 26); TotK calls SetLodBias 861 times. GirlNet 0293081, lordran 0a35532 (292 GPU checks).
- **GPU time per frame is a sum of command-buffer spans** (checked here: `gpu_tag_done` adds GPUEndTime − GPUStartTime): Apple GPUs overlap
  command buffers, so the union is what the frame costs (LASRecomp PR #197: summed 13-17 ms against a union of 6.5-7 ms). The GPU p50 numbers
  above are inflated by an unknown amount; the direction of each change holds.
- **A snapshot copy of an unmapped page ends the process** (checked here: `us_copy_range` is a plain memcpy, also on worker threads):
  MacNativeGames guards the copy with a SIGSEGV / SIGBUS fault guard and drops that copy (a helper died once in about 12 sessions).
- **Overlay directory listings stop at 2048 names** without a word (checked here: `dir_snapshot` in `host/hle_fs.c`, with a quadratic duplicate
  check). TotK has directories of 75,940 / 29,356 / 15,067 entries and the overlay is on by default; whether the game lists them is not known.
- **Silent no-ops** (checked here): SetPatchSize, MultiDraw*IndirectCount, DispatchComputeIndirect and DownsampleTextureView do nothing without a
  line; red on first call (upstream 44a6770), the indirect ones implemented when a game calls them (nxnative's DispatchComputeIndirect /
  DrawElementsIndirect).
- **Occlusion counts across submissions** (lordran 3ef6915: 64 samples, then 32 in the next submission, read 64): our visibility ring and slot
  numbering look the same; not checked whether TotK counts across a submission.
- Smaller: precise SleepThread against macOS timer slack (nxnative a9c56fd: 33 ms sleeps took 36.4 ms); rodata read-only and svc 0x02 honoured so
  a wild write faults at the writer (MacNativeGames `loader.c` `seal` / `check_permissions`); RG8_UI2F / UI2F / I2F vertex formats (jiangjifeng's
  nxnative fork ae9082d); `R_AARCH64_TLSDESC` and symbol precedence for .nro modules (nx-port).

Correctness, medium:
- **Host calls and svcs on a per-thread host stack** (MacNativeGames `games/totk/runtime/gate.S`, `hle_stack.S`, `hle_stack.c`: 4096 static
  thunks and a frame record that links back to the guest caller, so backtraces stay whole; mush8 has the same idea). `host/entry.S` puts 800
  bytes on the guest stack and host functions run there (a RomFS open with the overlay stacks about 5.6 KB of path buffers); their note says
  Tears of the Kingdom makes threads with stacks as small as 4 KiB, and 16 KiB host pages make 4 KiB guard pages writable. A possible cause of
  the blood moon crash (unproven): log the least free stack per thread at gate entry first. Replaces "Small guest stacks" above; manosaba's
  stop-the-world reads host frames on the guest stack and would need the guest sp the switch saves. Done: plan item 40.
- **A draw that samples the attachment it draws into** (tomodachi-native 4dbd30f + da08d11 `fbx_hazard`: every draw, mip aware, copies from a
  pool of 32, views held until completion): we split only merged continuations (`draw_samples_rt`). Count such draws in the dive and in manosaba
  first.
- **Counter timestamps where the report sits on the GPU** (LASRecomp PR #93 splits the command buffer at each ReportCounter): ours give every
  report of a submission one completion time. Check whether TotK subtracts two reports of one submission.

Performance:
- **NVN translation on a thread of its own**, now in four places with numbers: upstream b94670c (+ `t_nvn` case 8; dropped frames per 300 85 → 56
  on an iPhone 17 Pro Max), LASRecomp `runtime/nvn/rqueue.c` (PR #199; game-thread CPU 5.20 → 3.02 ms a frame on an M3 Max), MacNativeGames
  `TOTK_ASYNC_REPLAY` (`hle_nvn.c`, in the 70729e9 tree), T5eng on an iPhone Air (frame p50 22.9 → 16.67 ms). A fence is the submit counter
  ("translated and GPU done"); Finish, texel reads, write-back and destroys drain the queue; presents are queued in order. The uniform snapshot
  stays at the submit call. Large; the way to take replay off the game thread, rather than our encode stage (which lost at frames 1800 / 2400).
- **Busy yields** (nxnative e06a8ec): after 200 µs of back-to-back SleepThread(0) each yield sleeps an eighth of the run (10-250 µs); Three
  Houses: Mac CPU energy 3.5 → 0.5 W at equal frame times; a `power_line` logs TASK_POWER_INFO_V2 every 300 frames. With virtual cores the sleep
  has to release the core.
- **Targeted wakes** (nxnative e06a8ec): an event wakes only the waiters whose handle set holds it (ours wakes every WaitSynchronization waiter);
  semaphores instead of `usleep` polls in `host/hle_audren.c` and three places in `nvn_mtl.m`.
- **Replay lookups without the lock or a walk** (nxnative e06a8ec): a per-thread pool cache with a generation, the dirty range kept on the
  texture (our `find_span` walks about 3,000 ranges), residency adds skipped when nothing changes, page runs unprotected with one `mprotect`;
  dodola 7ccbb3f keeps the newest write per 64-page block.
- **Re-uploaded CPU textures alternate with a kept spare** (nxnative `NvPkg` spare; Link's Awakening 1.64 → 0.37 ms a submission); ours makes a
  new MTLTexture per re-upload. Check cutscenes with `DM_NVN_REUPLOG`.
- **Clears kept on the texture, ClearTexture included** (LASRecomp TexDefer, PRs #96 / #129: passes 42 → 33 and clear-only passes 12 → 3 in one
  scene); ours opens a store-only pass for every ClearTexture. Count them first.
- Smaller: the reflection summary cached per program and attachment events once per pass (upstream 44a6770 / afad65c); `mrs cntpct_el0` read
  inline with a key-page multiplier instead of a gate (mush8 idea; 43 sites in TotK's sdk; count the reads first; the background freeze and
  `DM_DETCLOCK` must keep working); the render area limited to the drawn part (LASRecomp 59a7507); libvpx row multithreading (nxnative
  `VP9D_SET_ROW_MT`).

iOS:
- **A launch check for Metal 4** (upstream b94670c, issue #41): iOS 26 runs on A13, Metal 4 needs A14 / M1, and ours stops with "failed to create
  MTL4CommandQueue". Show a screen instead (and offer the Metal 3 build).
- **Tears of the Kingdom's guest memory on iOS**: nxnative 2b31dbd (a 5 GB reservation without extended addressing, a 2.375 GB alias region, a
  2.125 GB heap region because the game calls SetHeapSize(0x86000000); ours has `guest_heap_mb` 256 → 0xD401 on iOS) and T5eng (iOS 27: about 6
  GiB below 2^39; log our reservation base against 2^39).
- **VP9 on iOS**: nxnative vendors the VP9-decoder part of libvpx v1.17.0 (71 files and the generated config, compiled into the iOS app); T5eng
  cross-builds it.
- **increased-memory-limit with a free account**: BotWRecomp `ios/PORTING.md` (Xcode made a Personal Team profile with it) and mush8
  `make-ios.sh` (FREE=1 keeps it) say yes; `ios/tools/project_free.py` strips it and `ios/README.md` says a free account cannot sign it. One
  signing attempt decides (`embedded.mobileprovision`, `os_proc_available_memory`); it would lift the 3.4 GB limit of item 2 at the top.
- **iOS 17 / Metal 3 devices**: the only unguarded iOS 18 APIs are the residency set (`nvn_mtl.m`) and `hasPerformanceProfile` (`front_ios.m`)
  (4ppp44 compiles the set out; `@available` keeps one binary); deployment target 17.0 in `ios/tools/project_m3.py` and `gfx/tools/ios_metal.py`
  (rebuild the metallibs).
- **Game data excluded from backups** (`NSURLIsExcludedFromBackupKey`, BotWRecomp); TotK's RomFS is 17 GB.
- **On-screen controls with drag-to-look** for TotK (BotWRecomp `runtime/src/host/touch.cpp`, MIT, with a self-test hook); nxnative's
  `DmGamepad.m` is the alternative listed above.
- Smaller: `env.txt` switches on the device (nxnative 5aabb96); the audio notifier thread at USER_INTERACTIVE (upstream afad65c: late wakes 16 →
  0 in 240 s); CoreAudio opened off the calling thread (tomodachi-native d7f52e1, one open took about 40 s there); cold CPU-uploaded textures
  dropped under memory pressure (justr4mzi's mush8 fork aafef22, ideas only); `GCSupportsGameMode` for iOS 18-25; already-compressed files
  stored, not deflated, in the IPA (nxnative `zip_store`); code patches chosen at launch, so one product serves 30 and 60 fps (tomodachi-native
  0428c80 / afd88e9).

Features (Tears of the Kingdom):
- Gyro and rumble, references now: atone/nxnative (Pro Controller IMU and HD rumble, MIT), mush8 (CoreMotion / CoreHaptics mapping, ideas only),
  LASRecomp `docs/rumble.md` (clamping, mixed by maximum, renewal, stop on focus loss), smbw-mobile `front_haptics_mac.m`, SkyRecomp's resting
  six-axis state.
- Scene render resolution on 1.4.3 (MacNativeGames PR #19: four loads at main+0x585e48.. from the host page; a `HOSTREFS` rule can express it).
- Frame pacing between 30 and 60 fps: with our real-time step, the interval pinned to 1 presents frames as they finish (BotWRecomp `fps.cpp`,
  ideas only). Its list of BotW's 30 fps constants and of cutscenes that crash above 30 fps says what to check in TotK, first whether the blood
  moon crash happens with the 30 fps product.
- User mod folders as overlay layers (SkyRecomp `runtime/mods.c`, with the Atmosphère layout).
- Quit waits for a save in progress (MacNativeGames `frontend.m`, up to 15 s); a covered Mac window discards presents (upstream afad65c).
- Alpha test: lordran a63dd76 (8 comparisons in the fragment epilogue, function constants, 54 GPU cases) or nx-port's; TotK never called
  ColorStateSetAlphaTest in our logs, so the known gap above is not hit there.
- For the next game: add-on content mounts (upstream PR #69), command-buffer FenceSync (lordran c6af84b), ClearBuffer / ClearTexturei /
  SetScissors / SetDepthRanges / Downsample as a resolve / depth bounds / rasterizer discard (GirlNet's P5R branches), LDN / lan-play (mush8's
  design), UE4 / CRIWARE notes (d2r-port-radar).

Diagnostics and tooling:
- **A live command channel** (MacNativeGames `input.c`, a polled file: keys, shots, pass dump, graphics flags without a restart, thread dump,
  host-call trace, frame step).
- **One game at a time on the Mac** (MacNativeGames `game_slot.c`, a flock with a queue; two games used 13 of 16 GB and the GPU driver panicked
  the kernel four times there).
- **Continuous integration** now that the repository is public: a macOS runner that builds the host and runs the host tests that need no GPU
  (GirlNet's nxnative fork bfc0376, LASRecomp `ci.yml`; a synthetic NSP as in hitsmaxft/nsp-dawrin, GPL-3.0, would go further).
- Smaller: thread dumps list the handles of a WaitSynchronization (SkyRecomp `kernel.c`); a ring of the last 256 condvar / mutex operations and a
  delay injected into condvar waits (LASRecomp: a 1-in-6 hang reproduced 3 times of 3); sead heap walk and list watch at a crash
  (MacNativeGames); `DM_MEMSNAP` raw guest memory at chosen frames for the manosaba leak (tomodachi-native a71964e); per-pass GPU time with
  MTL4CounterHeap (upstream 44a6770); soak and fixed-camera measurement (MacNativeGames `mac_v143_soak.py` / `mac_v143_smoke.py`); a stamp of the
  rewriter's sources in the product, the rewriter refusing system registers it does not know, the SDK's abort text in the log (mush8 ideas); the
  lifecycle and swipe-away tests back (upstream `Lifecycle.swift`, `lifecycle.sh`, `logred.sh`); upstream's `t_loader_weak`.

Checked, not better or already here: the Opus table leak (we run the SDK's decoder in the game's storage), macOS 27 fixed reservations (ours are
anywhere), a Metal 3 backend (we have one), compiling shaders at launch and skipping draws until ready (not taken: content drawn once would stay
missing), separate texture and sampler descriptor pools (one pool in our games), present pacing to the screen refresh (games that step per frame
would run fast; only TotK's real-time step can use it, through `DM_PRESENT_HZ`), SignalToAddress −2 (Atmosphère corrected it to −1 in 5f2d713;
ours is right), Metal binary archives (LASRecomp PR #145 closed; still "not to do"), nx-port's clamp of fragment outputs to ±65504 (breaks R32F),
lordran's deswizzle change (same offsets as ours), the audio mixers of LASRecomp, SkyRecomp, MacNativeGames and nx-port (our in-process SDK
renderer is closer), saves (ours are transactional), the condvar and WaitSynchronization order (ours is closer to Horizon than theirs).

### Plan: all of the wider review, simple to complex (2026-10-19)

Everything above is to be done, in this order. `[ ]` open, `[x] batch N` done in the commit whose subject starts with "Plan batch N", `[-]` measured and not needed (with the number). Each item gets a
unit test and a broken version that must fail it; each batch ends with the gfx tests (Metal 4 and Metal 3), the host tests, a manosaba and a Tears
of the Kingdom smoke run, then one commit. Sources and evidence per item are in "Wider review of 2026-10-19" above.

Tier 1, small and local. Correctness:
- [x] batch 1 · 1 svc 0x34 type 3 (64-bit wait if equal), unknown types refused by 0x34 / 0x35, an arbiter race test (`host/tests/t_arbiter.c`; the
  race also with kernel increments needing 177,412 retries against 200,000 user-space adds)
- [x] batch 1 · 2 controller face buttons by the printed letter on Nintendo controllers, a pure mapping function and an 18-case table test
  (`host/gamepad_map.h`, `host/tests/t_padmap.c`; the device check is 66)
- [x] batch 1 · 3 the BindProgram stage mask at the three scans (`defer_try` Q scan, `fuse_try` steps four and five; `t_defer_chain` mode 6 covers the
  first: the old code deferred and read stale pixels; no test reaches `fuse_try`, whose two sites take the same call)
- [x] batch 1 · 4 sampler LOD bias and min / max reduction (`gfx/tests/t_samp.m`, on the GPU; macOS / iOS 26, reported once before that)
- [x] batch 1 · 5 GPU time per frame as the union of command-buffer spans (`t_gputime`); `@gpu_ms` is the union from batch 1 on, `@gpu_sum_ms` the old
  sum, so GPU numbers above this plan are sums
- [x] batch 1 · 6 a fault guard around uniform snapshot copies (`t_usnap` section 5, on this thread and on the workers; without it SIGBUS)
- [x] batch 1 · 7 overlay directory listings without the 2048-name cap, duplicates found by hash, kept compact (`t_fs`: 3005 names)
- [x] batch 1 · 8 the silent NVN no-ops red on first call; SetDepthBounds reported when enabled (`t_nvn` 7b)
- [x] batch 1 · 9 precise SleepThread (`host/tests/t_sleep.c`: mean oversleep 0.004 ms, one nanosleep 1.19 / 4.12 ms on 5 / 33.3 ms)
- [x] batch 1 · 10 rodata read-only after relocation (`host/rodata_seal.h`, `DM_RODATA_RW=1` leaves it), svc 0x02 with Horizon's checks; read / none
  reported, not applied: Tears of the Kingdom only asks for read-write (`t_guest_mem` 7, 8)
- [x] batch 1 · 11 the 8 / 16-bit UI2F / I2F vertex formats (`gfx/tests/t_vfmt.m`); Metal converts 8 / 16-bit integers to their value for a float input
  and refuses 32-bit ones (measured), so the 32-bit and 10:10:10:2 kinds stay unmapped
- [x] batch 1 · 12 thread dumps list the handles of a WaitSynchronization with each one's state (`t_waitsync`)

Tier 1, performance:
- [x] batch 2 · 13 busy-yield back-off releasing the virtual core, a power line every 300 frames (`t_sleep`: 20 ms of yields 354 against 81,062
  plain). Off by default, `DM_YIELD_BACKOFF=<µs>` turns it on: in Tears of the Kingdom's prologue on the M5 it cost energy (two runs, 0.27-0.38 W
  against 0.23-0.24 W a 300-frame window; wakeups 2,700-3,800 against about 580 a second; the work moved to performance cores, and frames
  2100-2400 fell to 23.5 / 25.4 fps both times). The power line shows manosaba at about 25,000 wakeups a second, all on performance cores: a
  thing to look at
- [x] batch 2 · 14 targeted wakes (`t_waitsync`); upload waits on a condition variable (`t_upwait`: 0.015 against 1.03 ms after completion); the audio
  renderer blocks on buffer releases (`t_audio` scenario 3)
- [x] batch 2 · 15 replay lookups: per-thread pool cache (`t_poolcache`), dirty range on the texture and `mprotect` over page runs (`t_dirty_slots`),
  residency no-op skip (`t_poolcache`)
- [x] batch 2 · 16 a spare texture for re-uploaded CPU textures, dropped after 120 submissions unused (`t_texcheck` 4b)
- [x] batch 2 · 17 reflection summary per program, attachments walked once per pass (`t_zskip`)
- [x] batch 2 · 18 libvpx row multithreading (`DM_VPX_ROW_MT=0` off): the Ganon movie 1.02-1.03 → 0.95 ms a frame, frames identical

Tier 1, iOS and Mac:
- [x] batch 3 · 19 a Metal 4 launch check with a screen (Metal 3 for the iOS 18 build; `DM_TEST_NO_METAL4=1` shows it anywhere)
- [x] batch 3 · 20 game data excluded from backups (RomFS and sysfont outside the bundle; the boot log reads the value back)
- [x] batch 3 · 21 `GCSupportsGameMode` (iOS 18.0-18.5 read only this one; `LSSupportsGameMode` is from 18.6, Apple's reference)
- [x] batch 3 · 22 `env.txt` switches on the device: the bundle's (`DM_ENV_FILE` at build) then Documents' (`host/envfile.h`, `t_envfile`)
- [x] batch 3 · 23 audio notifier thread at USER_INTERACTIVE (`t_audio`)
- [x] batch 3 · 24 compressed files stored, not deflated, in the IPA (130 MB of `.zs`: 1.66 s deflated into a larger archive, 0.26 s stored;
  `run.sh ipa` reports the count)
- [x] batch 3 · 25 iOS 17 code guards (`@available` around the residency set and `hasPerformanceProfile`): no unguarded API left for an iOS 17
  target (`clang -fsyntax-only -target arm64-apple-ios17.0 -DDM_NVN_M3=1 -Wunguarded-availability`)
- [x] batch 3 · 26 quit waits for a save in progress, 15 s on the Mac, 3 s on iOS (`dm_fs_save_wait`, `t_fs`)
- [x] batch 3 · 27 a covered Mac window discards presents (`DM_OCCL=0` off, `DM_TEST_COVER=<s>,<len>` to check). The window check is still to
  run with the display on: during the 2026-10-19 run the display went to sleep (11:25), the display link stopped and no occlusion change came

Tier 1, tooling and diagnostics:
- [x] batch 4 · 28 one game at a time on the Mac (`host/game_slot.c`: a flock(2) held for the life of the host and a holder file; a run for the
  player, the .app or `DM_SLOT_OWNER=user`, stops an agent's run with SIGTERM, any other run waits; `DM_SLOT=0` off, `DM_SLOT_DIR`; `t_gameslot`)
- [x] batch 4 · 29 a stamp of the rewriter's sources in the product (`# REWRITER` in each fixups header: `tools/rewriter_stamp.py`, patch_nso.py and
  the game's rules.py; the host is compiled with the same value and the loader says when a product differs; `tools/tests/t_rewriter_stamp.py`).
  It found the manosaba product made by an older rewriter (rebuilt: modules identical, stamps added), and it shows that the Tears of the Kingdom
  default product is the 30 fps one kept on purpose since dba469f (its "frame step: main has no host page" red line is expected; `product60`,
  the 60 fps one, now carries the stamp)
- [x] batch 4 · 30 the rewriter stops on a system register outside NZCV, FPCR, FPSR and DCZID_EL0 (`tools/sysreg.py`, `tools/tests/t_sysreg.py`); neither
  game has one
- [x] batch 4 · 31 the SDK's abort text in the log: the last 8 OutputDebugString lines and AbortImpl's return address printed at a Break
  (`t_guest_mem` 9)
- [x] batch 4 · 32 the last 256 lock / condition variable calls in thread dumps, timed waits left out (`DM_KTRACE=0` off); `DM_DEBUG_CV_LATE_WAIT=<µs>`
  starts every condition variable wait that late (`t_ktrace`)
- [x] batch 4 · 33 upstream's `t_loader_weak` (`host/tests/t_loader_weak.c`: absent weak imports stay 0, our loader already did)
- [x] batch 4 · 34 `DM_MEMSNAP=frame[,frame...]:prefix` (`host/memsnap.c`: resident readable pages of the guest block and the modules' data;
  `t_memsnap`) and `tools/memsnap.py` summary / diff / refs (`tools/tests/t_memsnap.py`)
- [x] batch 4 · 35 GitHub Actions (`.github/workflows/ci.yml`, macos-26): the hosts of every game (Metal 4 and Metal 3), the host tests and the tool
  tests. Its steps ran here on a clean copy (all pass; on a copy with a build error, a failing host test and a failing tool test each step
  failed); the first run on GitHub comes with the next push
- Found while checking batch 4: `gfx/tests/t_ussort` failed about one run in ten (600 bindings counted as 607 or 614): a block whose four probes in
  the seen table find no place is collected again at each later binding, as the code says, and the merge drops the repeats; the test now allows
  that (and still fails when nothing is deduplicated). The host build has 34 compiler warnings, the same before batch 1

Tier 1, nxnative after 2b31dbd (reviewed through 19d7a70 on 2026-10-19 afternoon; MIT; batch 5, before Tier 2):
- [x] batch 5 · 73 the host races of nxnative 8530042. MapMemory / UnmapMemory were already serialized here (`g_mapmem_mu`), so of the map fix only
  QueryMemory's unlocked reads were missing: now under the registry lock (`t_guest_mem` 10: 3,000,000 queries of a thread's own stack while two
  threads unmap and map 512 others; unlocked, 32-123 of them wrong in every run). A SystemEvent's binding ends with its write handle, the signal
  looks up and signals under one hold of G (`t_sysevent`: before, the signal went to a decoy on the freed numbers). Audio output backends change
  under one lock with the backend recorded, a second consumer on one output is counted and reported red (`t_audio` scenario 4: before, 14-58
  second consumers or a hang in every run). CloseAudioRenderer joins the render thread, which closes its output (`t_audren`; `dm_pcmout_close`
  frees the AudioOut slot, `t_audio`)
- [x] batch 5 · 74 the yield back-off start, `DM_YIELD_BACKOFF=<cap µs>[:<start µs>]`, default 2 ms (`t_sleep`: a 1.5 ms run does not back off; the old
  200 µs start fails it). Still off by default: in Tears of the Kingdom's prologue (30 fps product, two runs each, 120 s) 0.206-0.209 W with it
  against 0.204-0.212 W without, wakeups 588-603 against 581-583, the same frame times; it barely fires there now (one window of 284 sleeps).
  manosaba's guest threads never yield, so it does nothing there. `DM_YIELD_BACKOFF=250` no longer costs frames in Tears of the Kingdom
- [x] batch 5 · 75 the c1 guard by interval arithmetic over the whole index, every stage (`gfx/tools/c1_guard.py`, `tools/tests/t_c1_guard.py`: the old
  decision fails 9 of 15, both ways: it passed a literal past the data and compute reads, and it listed `_5 & 3u`). Over chain b-1e41705de87b it
  lists the same 49 shaders as the old one (all 277 compute c1 reads proven), so nothing changes at run time
- [x] batch 5 · 76 two more power lines: render-target traffic a frame and guest CPU by Switch priority with the busiest threads (`t_threadcpu`). manosaba's
  guest threads use 53-103 ms/s in all: its 25,000 wakeups a second and full performance-core share come from host threads
- [x] batch 5 · 77 checked: the opening cave's stone blocks and steps beside the torch are lit warm here (prologue frames 1500, 1600 and 2100, 30 fps
  product); not this port's bug

Tier 2, small code, one shader chain rebuild for all four:
- [x] Tier 2 · 36 the BAHS shaders: `engines/bnsh/shader_extract.py` reads every binary entry of a `.sharcb` (after nxnative's `bahs_shaders`),
  not only the one 0x60 bytes before each control section: 28,474 shaders offline instead of 26,849 (`tools/tests/t_shader_extract.py`; the
  old reader finds 1 of its 2), 1,551 of them new to the Tears of the Kingdom capture, which now has 28,652 (all build); 74 that only run-time
  captures had are now found offline, 178 are still capture-only (shaders built into main). Not read yet: the two 0x7d1-byte control sections
  of `Lib/NintendoSDK/TextureShader.bnsh` and the Title layout's `bgsh` (nxnative's extraction has 17 more keys). The per-shader cache key has
  no gap of the kind 8530042 records: the pairs reach it through the vertex shader padding, the profile rows the build reads (`nvn_c2`,
  `depth_mode`, now `alpha_test`) are in it, and the Ryujinx libraries are in the lock file. Checked on the way: compute code areas with the
  0x12345679 header (241) are translated from +0 although their instructions start at +0x100 (nxnative skips to it); harmless here, the header
  is zero past the magic in all of them and their one indirect jump is relative; to skip when a game's header carries data
- [x] Tier 2 · 37 FFMA / FMUL `.FMZ` (a zero factor gives 0, also against infinity and NaN; after tomodachi-native a0aa6c2). Neither game uses it:
  every FFMA / FMUL of both is `.FTZ`
- [x] Tier 2 · 38 SHF wraps or clamps to the width, and a shift of 0 no longer ORs both words (on the GPU it gave 0xffffffff for 0x89abcdef :
  0x76543210); I2I `.SAT` compares in the source's signedness, narrowing keeps the low bits. `gfx/tests/t_xlate_ops.py` runs 47 cases through the
  translator, SPIRV-Cross and the GPU (inputs from a constant bank so nothing folds them; LASRecomp d4c2ff6's vectors plus shifts of 0 and 32):
  23 fail on the old translator, 0 now. manosaba has 18 shaders with a register SHF, Tears of the Kingdom 35; the I2I forms occur in neither
- [x] Tier 2 · 39 the alpha test, as a game profile option (`alpha_test` in game.json; after lordran-native a63dd76): fragment shaders end with the
  comparison under function constants, specialized with ALWAYS at load and per comparison and reference for draws that need it
  (`gfx/tests/t_alpha.m`: 8 comparisons x 3 alphas, the early return, reference changes, a shader without alpha; broken host key, unbraced
  blocks or no rewrite fail it). Off for both games, which never call ColorStateSetAlphaTest: Metal builds no pipeline from an unspecialized
  function, the first specialization costs 2-18 ms per shader on the M5, and reading the values from a buffer would leave a discard in every
  fragment shader (no hidden surface removal)
- Chain 1e41705de87b → bab8d4746968 for 36-39 (lock: the patched translator). Both games build every shader; the c1 list is the same 49;
  Tears of the Kingdom's prologue and manosaba's shots are within run-to-run variance (the prologue's s1300 differs 22-28 % between two runs of
  one build, from the cutscene's timing); both IPAs carry the new libraries

Tier 3, medium:
- [x] batch 6 · 40 host calls and svcs on a per-thread host stack (`host/hstack.S`, `hstack.c`; after MacNativeGames' hle_stack, MIT). Imports,
  takeovers, the NVN functions, the movie vtables, the audio renderer's thread entry and the unimplemented stubs run on the guest thread's own
  pthread stack (1 MiB), svc gates too; the guest stack holds 32 bytes at an svc and none at a host call, where a RomFS open with the overlay kept
  about 5.6 KB of path buffers (read from the code) and a first `localtime_r` 4,504 bytes (measured). Tears of the Kingdom has four threads with 4
  KiB guest stacks (VibrationThread, two DecompThread, gmd::GameDataMgr). A record at the top of the host stack is a frame record back to the guest
  caller (crash, sampler and thread dump walks take the one step between the stacks; `DM_GUEST_RA` for the NVN diagnostics) and gives
  GetThreadContext3 the guest's sp, x19-x28 and the call's arguments: manosaba's 307 GC context fetches in a run all reported an sp on the guest
  stack. `host/tests/t_hstack`: the switch with 64 KiB used on a 16 KiB guest stack, svc registers, nested calls, stubs, three paused contexts, the
  frame walk; `DM_HSTACK=0` faults on the guard page, the context as before fails all three pauses. The libc memory, string and math functions stay
  direct (each at most 144 bytes of stack, measured by the test); no host function the guest calls takes stack arguments (`tools/hle_args.py`, 427
  functions). Thread dumps show each thread's least free guest stack at svc entries (Tears of the Kingdom's prologue: 3,808 of 4,064 bytes left at
  the least), a `[stack]` line below 1 KiB. A wrapped call costs 5.3 ns more on the M5; both games' frame times, energy and shots are unchanged.
  `DM_HSTACK=0` turns it off
- [x] batch 7 · 41 occlusion counts across submissions (after lordran-native 3ef6915, MIT): before a visibility ring buffer is used again, the slots
  of the open samples-passed count in it are added into a CPU subtotal that reports include and a reset clears; before, both slot entries read the
  reused slot (`gfx/tests/t_visibility.m`, 23 checks on the GPU with API validation, Metal 4 and Metal 3: 64 then 32 samples reported 64, not 96;
  without the fold 6 fail). Tears of the Kingdom resets before every report (24-206 a frame in the prologue) but about 39 slots a frame belong to a
  count still open when their buffer comes round again: those counts read overwritten slots before (the prologue's torch glow and a lens flare
  differ between the builds; no console capture to say which is right). manosaba makes no occlusion queries. Found on the way: the overflow buffer
  of a submission with more than 8,192 counting passes was never retired (the check read `g_vis` after it was cleared; the test fails on the old
  line). The power summary has an occlusion line (reports, resets, open slots, folded slots a frame)
- [x] batch 8 · 42 draws that sample what their own pass draws (`DM_NVN_COUNTS=1` counts them): Tears of the Kingdom about 59 a frame in the
  prologue, full-screen passes at 1600x896 / 800x448 / 400x224 sampling the one level and layer they draw (most the first draw of their pass, 6 a
  frame after a texture-invalidating barrier that follows draws of the pass); manosaba none. On the M5 such a draw reads the attachment as it was
  before the Metal pass (the earlier draws are in tile memory, a pending clear is not in memory); measured in `gfx/tests/t_fbx.m`. Copying the
  attachment for every such draw (after tomodachi-native 4dbd30f / da08d11, MIT: earlier draws and clears visible) put two prologue shots outside
  the console's brightness ranges taken from the video of the opening the user found (youtu.be/IyCrvjFhkRE, the shots' frames matched by structure:
  s1800 left third 39.0 against 44.2-54.5, s1300 right 65.9 against 68.2-84.2; GPU p50 +2.4 ms, 112 copies a frame), while the M5's own reads and
  copies only after such a barrier stay inside them in every third. So the replay copies only where NVN defines the read (a draw after a texture
  barrier that follows draws of its pass: the pass ends, the whole texture is copied, the copy is bound in its place, `fbx_prepare` / `fbx_sub`): 2
  draws and 6 copies a frame, within run-to-run timing. `DM_NVN_FBX=all` copies for every such draw, `=0` never. `t_fbx`: 10 checks in each mode on
  the GPU with API validation; with `=0` the barrier cases fail
- [-] batch 8 · 43 checked: Tears of the Kingdom writes 43-80 timestamp reports a frame, one submission a frame holds two or more (a dozen
  TIMESTAMP_TOP to a pool); a load watchpoint on four of them (`DM_NVN_COUNTS_WATCH=<n>`, `DM_WATCHPOINT_LOAD=1`, new) saw no read in 15-30 s, while
  the type 0 report of that submission is read every frame by `nvnDeviceGetTimestampInNanoseconds` (main+0x76920, the frame-rate controller, which
  compares it with the CPU's frame start tick). No two reports of one submission are subtracted: the command buffer is not split at reports
- [-] batch 8 · 44 counted: no ClearTexture in Tears of the Kingdom's prologue or manosaba, and 4 render passes a frame end without a draw in the
  prologue (0 in manosaba): keeping clears on the texture would save at most those
- [-] batch 8 · 45 counted: about 31,000-34,000 system counter reads a second in Tears of the Kingdom (manosaba 4,500-9,800); a gate round trip
  costs 13-25 ns on the M5 (`t_hstack` prints it), so about 1.5 ms of CPU a second in all with the lookup and the clock: not worth an inline read
  that would have to keep the background freeze and `DM_DETCLOCK`
- [-] batch 9 · 46 counted (`DM_NVN_COUNTS=1`: how far each render pass's draws reach right and down, scissor and viewport, clear quads
  included): no pass of Tears of the Kingdom's prologue (90-122 with draws a frame) or of manosaba (2.5-5.5) draws only a top-left part, with or
  without a clear on load, so the render area stays the attachments' size. The console's dynamic resolution (900p, toward 720p while the camera
  moves: Digital Foundry) did not show here; counter timestamps reported 8, 15 or 25 ms late (`DM_NVN_TS_LATE_US=<µs>`, new: the game sees a
  slower GPU) changed the game's present interval between 2 and 3 (3, 5 and 16 times in 120 s against once) and still no pass drew a part.
  `gfx/tests/t_extent.m`: 12 checks on the GPU with API validation (after LASRecomp 59a7507's render area); with the viewport and clear quads
  left out 3 fail
- [x] batch 10 · 47 a live command channel, `DM_CMD=<file>` (`host/cmdchan.c`, after MacNativeGames' `TOTK_INPUT_FILE`): lines appended to
  the file run while the game runs: `key` / `down` / `up` with the DM_KEYS names, `wait <frames>`, `sleep <ms>`, `shot <png>`, `passdump
  <frames>` (now settable while running), `threads`, `memsnap <path>`, `hlecount`, `quit` (the orderly exit, code 0). A line runs once its
  newline is written (a reader stopping at the end of the file, as fgets does, would run half a line). `host/tests/t_cmdchan.c`: 24 checks (a
  table of good and malformed lines; a file a writer appends to); run as far as written, the line written in two parts fails it (4 fail);
  `t_hid_script`: the keys reach GetNpadState (2 fail without them). In Tears of the Kingdom: wait 300, shot, passdump 1 (frame 301 only),
  threads, key A (read by the game at 11.2 s), an unknown line skipped in red, quit: exit 0
- [x] batch 11 · 48 sead heaps and list watch (`host/sead.c`, after MacNativeGames' TOTK_CRASH_HEAPFIND / HEAPWALK / LISTCHECK):
  `DM_CRASH_HEAP=<reg>,...` on a crash and the channel's `heap <addr>` print the heaps holding an address, outermost first, and the block of the
  innermost one it is in; `heaps` lists every heap; `DM_LIST_WATCH=[heap+]<addr>,...` dumps the threads once when a watched list gets a null next.
  MacNativeGames' layout holds in Tears of the Kingdom 1.4.3 (names RootHeap, GraphicsSystem, Resource, Actor read back): at frame 900, 7,508
  heaps found in 1.3 s, in five classes by vtable (the game has no C++ type names): main+0x3900d18 (266) and main+0x39011d0 (53) all with whole
  use lists, main+0x3900e40 (7,178), +0x39013f0 (7) and +0x3945240 (4) with none at +0xc8, so a use list counts as broken only in a class that
  has whole ones (counted naively, 6,127 of 6,450 looked broken). An address in the Actor heap: RootHeap → sead::TaskMgr → ModuleSystem → Actor
  and its block. `host/tests/t_sead.c`: 19 checks on heaps built by hand (a child heap, a class without a use list, three kinds of break, a list
  watch); taking a heap without checking it reaches the address fails 2; `t_crash_stderr`: DM_CRASH_HEAP gets the register's value at a crash
- [x] batch 12 · 49 per-pass GPU time, `DM_NVN_PASSGPU=<tsv>` (after upstream 44a6770, MIT): Metal 4 writes timestamps into an
  MTL4CounterHeap around each render encoder and each dispatch (precise: dispatches share the copy encoder), Metal 3 samples at stage boundaries;
  a heap per submission in a ring of 8, invalidated before reuse (upstream's is not: a slot left unwritten would read an older submission's
  time). One row per pass; every 300 frames a line with the GPU time a frame and the five kinds of pass (size, formats, loads) that took the
  most. Tears of the Kingdom's prologue: 139-147 passes and dispatches a frame, 5.9-6.3 ms of increments against a GPU p50 of 6.8 ms (the union
  of the command buffers, copies included); most: 1600x896 with five colour attachments and depth 0.78 ms (5 a frame), 800x448 with eight 0.72
  ms (2), 1600x896 format 92 0.43 ms (1), 1920x1080 format 92 0.43 ms (2). Summed by a pass's index in the frame, as upstream logs it, the same
  run came to 13 ms (an index is no identity when frames have 100-260 passes). Passes overlap: on Metal 3 a light pass after a heavy one spans 13
  ms (its vertex stage starts during the heavy one's fragments) and adds 0. `gfx/tests/t_passgpu.m`: 8 checks on the GPU with API validation,
  Metal 4 and Metal 3; without the end timestamps no row comes out (both fail)
- [x] batch 13 · 50 soak and fixed-scene measurement, `tools/soak.py` (after MacNativeGames' `mac_v143_soak.py` / `mac_v143_smoke.py`; their
  fixed camera teleports a played save to world coordinates, which a new save cannot): `run` keeps the host going for M minutes with
  `DM_MEMSTAT` and screenshots and a quit through the command channel, then reports the memory slope after the warm-up (a quarter of the run, at
  least 2 minutes), frame and GPU time early against late, and red lines first seen late; `window` runs N times to a frame and gives the frame
  and GPU time over a frame window, with `--clean` emptying the save before each run. Tears of the Kingdom, 20 minutes from a new save:
  footprint −1 MB/h and Metal +0 after the first 5 minutes (124 → 2,648 → 2,638 MB), frame time p50 33.69 → 33.74 ms, GPU 7.18 → 7.12, no late red
  line; manosaba: +4 MB/h, 16.66 ms throughout, no red line. Frames 1800-3300 of the prologue, 3 runs: frame time p50 33.72-33.74 ms, GPU p50
  7.13-7.33 ms (the noise a GPU change there has to beat, about 3 %). `tools/tests/t_soak.py`: 13 checks; counting the warm-up in the slope
  fails 2 (a flat run reads as growth)
- [x] batch 13 · 51 lifecycle and swipe-away tests (upstream `ios/tools/lifecycle.sh` criteria, `logred.sh`): `DM_TEST_BG=<s>,<len>` on the Mac
  too (`host/front_mac.m`, the order and lines of the iPhone's scene events), `tools/lifecycle_check.py` judges a log (suspended while away,
  the guest clock the same back, audio paused and resumed, presenting goes on, no new kind of red line), `ios/run.sh lifecycle` runs it on a
  device with the background simulated in the app. Found on the way: the no-progress watchdog counted the background, so a run with DM_WATCH
  was killed 15 s into it; it now skips while the clock is frozen for the background (`t_watchdog`: 3 cases; counting it fails "away"). Tears of
  the Kingdom and manosaba with `DM_TEST_BG=40,20`: LIFECYCLE OK (the guest clock 217236.755 s at the background and at the return). A save
  killed at any moment (an app swiped away while suspended gets SIGKILL): `host/tests/t_fs_kill.c` kills a process committing saves 60 times
  at random (222 commits, 22 kills after a commit not yet reported): every file one whole version, the last reported or the next; a commit that
  removes the committed save before cloning in its place (`-DDM_TEST_FS_COMMIT_INPLACE`) tears it 14 times of 60. `t_lifecycle_check.py`: 10
  checks; not comparing the guest clock fails 1. The home button and the app switcher themselves need UI automation on a phone (item 70)
- [x] batch 14 · 52 scene render size on 1.4.3, `DM_RENDER_RES=<w>x<h>` with the rules product (after MacNativeGames PR #19, merged
  2026-10-19, MIT): main 0x585da0 reads the size from the graphics parameter into w11 / w10 and stores it as floats at renderer +0xcc4 /
  +0xcc8, from which every scene target is sized. The four words of the PR checked in our main: 0x585e48 `scvtf s0, w11` → `adrp x17, host
  page` (HOSTREFS), 0x585e50 → `ldp s0, s1, [x17, #16]`, 0x585e54 → `str s0, [x19, #0xcc4]`, 0x585e60 → `str s1, [x19, #0xcc8]` (CUTS). x17,
  not the PR's x3: the function (0x585da0-0x586000, 152 instructions) uses neither, and x3 is an argument register of the calls after it. A
  probe at 0x585e4c (now printing x9-x12) read the parameter once at boot: docked 1600x900 with w9 = 1920 output, handheld 1280x720 with 1280;
  `games/totk/frame_step.c` writes that at host page +16 unless `DM_RENDER_RES` is set, so the rules product looks as before (its pass sizes
  in one frame the same as the previous product60's). With 960x540 the scene passes are 960x536, 480x268, 240x134, the UI stays sharp; GPU
  p50 5.93 against 6.30 ms in the window to frame 3600. Without the host's value (an older host) the scene is 0x0 and the passes 8x8 and
  smaller. `games/totk/check_render_size.py <product> <main NSO>`: 8 checks in Unicorn (the page's size stored, w9's output size and x9 kept,
  the argument registers as before; the original stores the parameter's); with x9 as the MacNativeGames 1.0 code has it, the output size is
  overwritten (2 fail). `t_frame_step`: 22 checks with the size choice. `work/build/totk/product60` rebuilt with these rules (main cuts 20,
  sdk and subsdk0 byte for byte the same; the previous one is `product60.prev`); `verify/regress.sh` OK for it and for manosaba, after its
  gate bench got the host stack sources it needs since item 40 (it did not build since batch 6)
- [x] batch 15 · 53 frame pacing between 30 and 60 fps (after MacNativeGames' TOTK_UNCAPPED, MIT; the user pointed out MacNativeGames already has
  the 60 / 90 unlock, which product60 has since dba469f, and its uncapped pacing is the rest of this item): for a game whose step follows the
  measured frame time (`dm_game_realtime_step`, Tears of the Kingdom's rules product), the game no longer waits for the display: our clock paces
  it at up to 120 fps (its present interval × 1/120 s a frame) and the display link shows the newest finished frame at each refresh, which ours
  already did. `gfx/nvn/nvn_pace.h` `nvn_uncapped_hz`: off with `DM_UNCAPPED=0`, with `DM_PRESENT_HZ` and on a display of 120 Hz or more;
  `DM_UNCAPPED_HZ=30..120` or `display` (MacNativeGames' iPhone default, for heat). With the frame's own work made to take 14 ms
  (`DM_TEST_WORK_MS=14`, a new test switch at the frame's first submission, which the controller counts): before, frame time p50 32.7 ms and 64 %
  of the frames at 30-36 ms (the controller flapping between intervals 1 and 2, 543 changes in 120 s); now 17.8 ms, 66 % under 18 ms, 33.5 % at
  18-30, 0.6 % at 30-36, and 6,300 frames in 120 s against 4,200; a shot 75 s after start shows the same game moment in both (the step keeps the
  speed). Unhindered, the prologue runs at about 115 fps. `gfx/tests/t_pace.c`: 13 more checks; uncapping a game that steps per frame
  (`-DDM_TEST_UNCAPPED_ANY_STEP`) fails one. Found on the way: `DM_RENDER_RES` above the output size crashes the game (2560x1440 and 3200x1800,
  main+0x1c2f20, in its first seconds): now refused above 1920x1080 (`t_frame_step`: 26 checks). The 30 fps constants and the cutscenes that
  crash above 30 fps (BotWRecomp's list for BotW: stamina, arrows, shield surfing, Rito bridge...) need play: 71c. A window run (the display
  link path) is part of 71b
- [x] batch 16 · 54 user mod folders, `DM_MODS=<dir>` (`host/mods.c`, after SkyRecomp's `runtime/mods.c`, MIT; MacNativeGames and nxnative have
  none): each entry's RomFS becomes a layer of `DM_ROMFS_OVERLAY` in front of the game's (and of the game's own overlay, as Tears of the
  Kingdom's 60 fps one): `<entry>/romfs`, `<entry>/contents/<program id>/romfs` (an SD card's `atmosphere` folder copied as is),
  `<entry>/atmosphere/contents/<program id>/romfs` (a mod as shipped), or loose files; in name order, the first winning; names starting with
  `.` or `-` off; other games' folders and code (exefs, exefs_patches) left out with a line. The program ID matched without regard to case,
  and paths built with each folder's own spelling (the Mac's file system ignores case, iOS's does not). The log lists each layer, how many of
  the game's files it replaces and the files an earlier mod also has. On iOS `Documents/mods` when it exists. In Tears of the Kingdom a mod
  folder with two of the game's files copied unchanged (one as `01_test/romfs`, one as `atmosphere/contents/0100f2c0115b6000/romfs`): both
  opened from the mods (`DM_FS=1` now prints the host path too), the 60 fps overlay still after them, the prologue as before.
  `host/tests/t_mods.c`: 12 checks on every layout; paths built with the program ID as asked fail one
- [-] batch 17 · 55 measured (tomodachi-native d7f52e1 moved the AudioUnit's creation to a queue after CoreAudio once took about 40 s there):
  on the M5 the open takes 22-26 ms in the games (manosaba on its main thread, Tears of the Kingdom on the audio renderer's), a process's first
  AudioUnit 47 ms in a probe and 0.5-1 ms after; nothing here near a stall, so the open stays where it is and the moving's races with Start / Stop
  / suspend / Close are not taken on. The time and the thread are logged now (red above 1 s), so a device run shows the iPhone's (70).
  `DM_AUDIO_MUTE=1`: the sound card opened and fed, silence out (measuring at night); `t_audio` checks the blocks are still taken while muted
  (muting without taking them fails it)
- [-] batch 18 · 56 measured (the low-memory texture trim of justr4mzi's mush8 fork aafef22, ideas only): `DM_NVN_COUNTS=1` now counts the
  uploaded (CPU-filled) textures by how many submissions ago they were last used, every 300 submissions on the submit thread. Tears of the
  Kingdom's prologue: 364 of them, about 300 MB used in the last 30 submissions and 64 MB not used for more than 1,800 (of 2.0 GB Metal allocated,
  footprint 2.6 GB); manosaba has 40 MB of such textures in all. Dropping the cold ones would free about 3 % at the price of a re-upload when they
  come back: not now; with Tears of the Kingdom on a device (62) the memory-low lines say whether to. `t_uppool`: the census (one texture used
  again in the first bucket, eleven in 301-1800); with a later use not noted 2 fail
- [x] batch 19 · 57 code patches chosen at launch, one product for 30 and 60 fps (after tomodachi-native 0428c80, MIT): rules.py `OPTIONS`
  (`tools/patch_nso.py`: entries as CUTS or as HOSTREFS forms, checked against the original, not written into the image, listed in
  `<module>.options.tsv` with their final bytes; asserted not to overlap a cut and to be left alone by the rewrite), applied by the Mac loader
  before it seals the code to those `DM_OPTIONS` names, or else the product's `options.default` (`host/options.c`: originals checked again, an
  option whole or not at all, unknown names in red, `dm_option_on`). Tears of the Kingdom's changes are now the options `fps60` (the 7
  controller words), `realtime` (the frame step) and `scene` (the scene size); `games/totk/frame_step.c` and the uncapped pacing follow them.
  `work/build/totk/product60` is rebuilt this way with `options.default` = `fps60,realtime,scene`: with all three applied its main is byte for
  byte the previous product60's (sdk and subsdk0 too), `DM_OPTIONS=none` runs the game's code as shipped (frame time p50 33.8 ms, its own step),
  the default 120 fps uncapped (p50 8.3 ms); `check_frame_rate.py` (17) and `check_render_size.py` (8) apply the product's options
  (`verify/nsoimg.py product_image`). The default 30 fps product (`work/build/totk/product`) is left as it is. The manosaba product rebuilt with the
  new rewriter: byte for byte the same images, only the stamp (`.prev57` kept). `host/tests/t_options.c`: 9 checks; written without checking the
  originals, an option is half applied (1 fails). iOS maps the signed executable's code: options there need the changed pages embedded
  (tomodachi-native afd88e9), item 62
- [x] batch 20 · 58 on-screen controls with a drag-to-look camera (BotWRecomp `runtime/src/host/touch.cpp` at 2b84b82, MIT: its layout, feel
  constants, finger rules and input checks, in C): `host/touchpad.c` for a game with game.json `touch` "pad" (Tears of the Kingdom; `DM_TOUCH=pad`
  / `screen` overrides it on iOS): a floating stick on the left half whose base follows a thumb that leaves its ring, the D-pad (sliding changes
  direction), ABXY, L / R / ZL / ZR, - / +, L3 / R3 and the eye that collapses them; the right half outside the buttons is the camera (the finger's
  speed smoothed with τ 45 ms, 420 pt/s for full deflection, at least 0.12 once moving, 0 at rest). Each finger owns its control until lifted; one
  stick and one camera finger at a time; a press shorter than the time between two reads is still seen once; the first read after a pause gives
  the camera no spike; a layout with the same size and safe area keeps the fingers. `hle_hid.c` ORs it into the controller (its stick after the
  front end's, before a game controller's). iOS (`front_ios.m` `DmPadView`): over the whole screen, laid out in the safe area, drawn after each
  touch, off while a controller with an extended profile is connected, the eye's choice in the user defaults (`dm.touch_hidden`).
  `DM_TEST_TOUCHPAD=check:<s>` (any game, the Mac too) runs BotWRecomp's checks against the controller the game read: Tears of the Kingdom 17 of
  17 in the prologue and on the Great Sky Island cliff save; `hide` 2 of 2; `look` only drags a camera finger: shots of frames 1432-1462 show the
  camera turning around Link, who stays where he is, and still from frame 1468 when the finger rests. `t_touchpad`: 33 checks (BotWRecomp's 17
  on a fake clock at 30 reads a second, then ownership, the short tap, the eye, off, the pause, the relayout, every button's centre); a finger
  that takes the button it slides onto (`-DDM_TEST_TP_REHIT`) fails 1. `t_hid_script`: 6 more (the merge, the last state read). How it feels on a
  phone needs Tears of the Kingdom on iOS (62), or manosaba with `DM_TOUCH=pad` on a device (70)
- [-] 59 not done: iOS 17 is not supported (the user's decision, 2026-10-20); the apps stay at iOS 26 (Metal 4) and iOS 18 (Metal 3)
- [-] batch 21 · 60 measured: no game calls an indirect draw or dispatch yet. The red-reporting stub logs every unimplemented NVN function on its
  first call (it is why `SetPrimitiveRestart` shows in 42 logs); in the 396 logs of Tears of the Kingdom and manosaba here, play up to frame
  27,000 among them (the prologue, the Great Sky Island, the dive), not one of DrawArraysIndirect, DrawElementsIndirect, MultiDraw*IndirectCount
  or DispatchComputeIndirect. Implemented when a game calls them (nxnative has DispatchComputeIndirect and DrawElementsIndirect; item 64).
  `t_nvn` 7b now holds all of them to the stub, the two plain indirect draws too (the check was on five functions; one added to the silent
  no-ops fails it)

Tier 4, large:
- [ ] 61 NVN translation on a thread of its own (after 5, 47 and 49, to measure it)
- [ ] 62 Tears of the Kingdom on iOS: guest memory layout, VP9 on iOS, BC → ASTC, a device run (after 19, 25, 59); the cold-texture census of 56 under its memory limit; code options (57) through embedded changed pages (tomodachi-native afd88e9)
- [ ] 63 the 2K canvas and MetalFX (veneers in the rewriter, HeapDef overlay, larger application pool; after 52)
- [ ] 64 for the next game: add-on content, FenceSync, ClearBuffer and the other NVN functions, LDN

Tier 5, needs the user's devices, controller or account:
- [ ] 65 increased-memory-limit with a free account (one signing attempt)
- [ ] 66 a Switch Pro controller check of 2
- [ ] 67 gyro and rumble (implemented here, checked with the controller)
- [ ] 68 MixWithOthers on an iPhone
- [ ] 69 the game over flow with the overlay, in play
- [ ] 70 manosaba's iOS app with chain bab8d4746968 on the devices (was 1e41705de87b), with the host stack of 40 (both IPAs built with it); `ios/run.sh lifecycle` there, and the home button and the app switcher by hand (51); the log's "CoreAudio output opened in" time there (55); the on-screen controls of 58 with `DM_TOUCH=pad` (`DM_TEST_TOUCHPAD=check:30`, then by hand: the stick, the camera drag, the eye, a controller connected)
- [-] 71 not done: iOS 17 is not supported (59)
- [ ] 71b the covered-window check of 27 in a window (`DM_WINDOW=1 DM_TEST_COVER=30,10`, display on); the Metal 4 screen of 19 on a device
  (`DM_TEST_NO_METAL4=1` in Documents/env.txt); the backup exclusion of 20 in Settings → iCloud → Backups; uncapped pacing of 53 in a window (product60, `DM_WINDOW=1`)
- [ ] 71c in play with product60: the systems BotW had on 30 fps constants (stamina regeneration and drain, arrow speed, shield surfing, rune
  aiming, flurry rush) at 30 and at 60 fps, and cutscenes there (none listed for Tears of the Kingdom by MacNativeGames; BotWRecomp's BotW list
  as the guide)

Open:
- [ ] 72 the blood moon crash: after 1, the stack logging of 40 and 47, dump the threads right at the skip
