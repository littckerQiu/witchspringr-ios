# WitchSpring R bring-up notes (our host; the one that has the software BC decoder an A15 iPhone needs)

Upstream `seedds/nxnative` requires GPU BC texture support (A17 Pro and later, `gfx/tex/README.md`: "there is no
decompression path"), so it cannot run this game on the iPhone SE 3 (A15) this port is for. Our fork keeps
`gfx/tex/nvn_bcdec.c`, so it can; everything learned from upstream is applied here instead.

## Boot stages reached (CI, own host, real data, `DM_APP_POOL_ADD_MB=-900`)

| stage | result |
|---|---|
| `nnosInitialize` / `nninitInitializeSdkModule` / `nninitStartup` | pass (VAMM handout forced, 2282 MB heap) |
| `main: DT_INIT`, 273 `init_array` entries | pass, **only after the allocation fixes below** |
| `nnMain`, Unity runtime, job threads, IL2CPP metadata, `data.unity3d` | pass |
| first `CentralHeap::Free` of a block outside the heap | **current failure**: `nnmem_nlib_debug_break` from `CentralHeap::Free+0x14c` |

## Fixes that mattered (each one verified by a CI run)

1. **Application pool 2385 MB instead of 3797** (`ios/witchspringr.env`, `DM_APP_POOL_ADD_MB=-900`): the game asks
   for `pool - images` as one contiguous virtual address region; 3.69 GB starved the alias region, `operator new`
   returned 0.
2. **Size-based alignment of address regions** (`host/hle_svc.c`): 64 KB under 2 MB, 2 MB under 4 MB, 4 MB under
   32 MB, 32 MB under 1 GB, 1 GB above. Unity's low-level virtual allocator takes the usable size from the distance to
   the next boundary; with plain 2 MB alignment it came out as 0 and Unity printed
   `tlsf_add_pool: Memory size must be between 0x28 and 0x100000000 bytes`, after which `operator new(4)` returned 0
   and a global constructor wrote through it (`main+0x37d174`). **This moved the boot from `init_array` to `nnMain`.**
3. Alias pages are backed on demand (`alias_demand_page`), so writing into a fresh region before mapping it no longer
   faults (SIGBUS at `0x70790fffe0` before).

## Current failure

`CentralHeap::Free` frees `0xbba5581f0` while the heap base is `0xbc0000000` (below the base) and traps in
`nnmem_nlib_debug_break`. The heap takes `pool - images` at the north end of the alias region and later regions land
*below* it, so the heap's `[base, base + size)` range check does not cover them. On the console the SDK's own
`AddressRegionManager` owns the range and keeps the heap's extensions adjacent to it.

Tried and rejected (each measured):
- allocating **upward** from the alias base: init reaches the same place but Unity rejects its first pool again, and a
  1 GB alignment of the heap region wastes up to 1 GB when the alias base is not 1 GB aligned;
- rounding the **alias base up to 1 GB**: the SDK's own manager then runs its bookkeeping and traps at `sdk+0x134fcc`
  (`addr = pool size + 0x20`).

Next, in order:
1. Allocate the first (largest) region at the *bottom* of the alias region and everything after it upward, so the heap
   can extend contiguously above its base; re-check Unity's pool complaint with the alias base aligned by hand (take the
   alignment out of the guest block instead of wasting it).
2. Find what sets the `AddressRegionManager`'s (base, size): the constructor is a PLT import
   (`_ZN2nn2os6detail20AddressRegionManagerC2Emm`, stub `sdk+0xd3ccd0`) and nothing in `sdk` branches to it directly, so
   it comes through a pointer or from `VammManager::InitializeIfEnabled`. Feed it the alias range in the host instead of
   forcing `AllocateAddressRegion` — that is what upstream does (their host never forces it).
3. If the heap/Unity split cannot be made consistent: give the nlibsdk heap a region big enough that it never extends
   (`app_pool` smaller still, e.g. `-1500`) and see whether `CentralHeap::Free` is then never handed an outside pointer.

## Round 4 findings

- The SDK's VAMM range comes from `GetInfo` id 2 (alias base) and id 3 (alias size): `VammManager::VammManager` (sdk+0x134618)
  calls `svcGetInfo` for both and stores them; `InitializeIfEnabled` (sdk+0x13469c) then constructs the
  `AddressRegionManager` with them and bails (disabling VAMM entirely) when either is 0. Our host already answers ids 2/3
  from `g_alias`/`g_alias_cap`, so the manager does initialise.
- With the manager running (our forced `AllocateAddressRegion` disabled) and its 1 GB node area cut to 62 MB
  (`games/witchspringr/rules.py`), the game still reaches `nnMain` and still dies in `CentralHeap::Free`
  (`sdk+0x119190 = nnmem_nlib_debug_break`), now freeing a pointer 11 MB *above* the heap end (`0x40f5581f0` with the heap
  at `0x380000000+0x8ea00000`). The caller is `std::string`'s destructor path (`main+0x312500` → `__1::basic_string::append`),
  so a string buffer that came from another allocator was freed through the nlibsdk heap: allocator metadata has been
  crossed somewhere, not a plain range-check mistake.
- Dropping the `nnmem_nlib_physical_alloc` takeover (to let the SDK map its own heap pages on macOS) is **not** an option:
  the SDK's own path fails on macOS too (`AbortImpl` from sdk+0x95c14, then the heap init at sdk+0x126490). The takeover is
  needed on both platforms.

## Plan for the next rounds (decided in round 4)

Upstream's host already runs this game through `nninitStartup` → `nnMain` → Unity's job threads → NVN device init without
any of the memory hacks above, because it never takes the VAMM APIs over. What it lacks for this phone is exactly one thing:
a **software BC texture decoder** (its `gfx/tex/README.md`: "there is no decompression path"; BC needs A17 Pro or later).

So the endgame is to stop fighting our fork's VAMM and instead:

1. add `third_party/bcdec` (MIT, already in this tree) to the upstream checkout in the `nx-ipa` workflow, and make
   `gfx/tex/nvn_fmt_mtl.c` / `gfx/nvn/nvn_mtl.m` create an RGBA8 texture and decode the blocks on upload when
   `MTLDevice.supportsBCTextureCompression` is false (the same substitution this fork does in `gfx/tex/nvn_bcdec.c`);
2. build the IPA from the upstream tree with our profile (`.github/workflows/nx-ipa.yml` already does tables → iOS
   metallibs → IPA);
3. hand that IPA over, with `Documents/romfs` holding the game files (the upstream app reads `Documents/romfs`).
