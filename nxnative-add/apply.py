#!/usr/bin/env python3
"""Put the WitchSpring R profile into a fresh clone of seedds/nxnative and register the one rewriter cut it needs.

The cut shrinks SDK 16's AddressRegionManager node area from 1 GB to 62 MB for this game's sdk build
(docs/agents/03-bringup.md, "First AllocateAddressRegion fails with 0x1803" / the Engage and TotK entries):
without it the game's 3.7 GB StandardAllocator reservation cannot fit in a phone-sized alias region.
"""
import shutil, sys, pathlib

nx = pathlib.Path(sys.argv[1])
prof = pathlib.Path(__file__).resolve().parent / 'games' / '010018401EEA8000' / 'game.tsv'
assert nx.is_dir() and prof.is_file(), 'usage: apply.py <nxnative checkout>'
dst = nx / 'dm' / 'games' / '010018401EEA8000'
dst.mkdir(parents=True, exist_ok=True)
src = prof.parent
n = 0
for f in sorted(src.iterdir()):
    if f.is_file():
        shutil.copy2(f, dst / f.name); n += 1
print(f'profile -> {dst} ({n} files)')

# CUTS entry, keyed by this sdk build id
p = nx / 'dm' / 'tools' / 'patch_nso.py'
s = p.read_text()
entry = """  # WitchSpring R v0 sdk (16 MB system resource -> virtual address memory on): the AddressRegionManager takes
  # 0x3fe00000 (~1 GB) at the start of the alias region as its node area before handing out anything. Cut to 62 MB
  # (the Engage / Tears of the Kingdom cut) so the game's StandardAllocator heap and Unity's pools fit the 5 GB
  # block a phone gives a process. sdk+0x134778 is nn::os::detail::AddressRegionManager::AddressRegionManager.
  'a5cb2175cad2ca2afdd4c13577dbd079': [
    (0x134778, '08fca752', '087ca052', 'AddressRegionManager node area: mov w8,#0x3fe00000 (1 GB) -> #0x3e00000 (62 MB)'),
    # The constructor also registers the node area's LENGTH as an occupied region, with a second mov (w9). Cutting only the
    # start left the manager owning 1 GB that begins 62 MB in: docs/agents/03-bringup.md documents this exact pair (Octopath,
    # Tears of the Kingdom) and a mismatched occupied region is how two live objects end up sharing an address.
    (0x13480c, '09fca752', '097ca052', 'AddressRegionManager node area length: mov w9,#0x3fe00000 (1 GB) -> #0x3e00000 (62 MB)'),
  ],
"""
anchor = "CUTS = {\n"
if 'a5cb2175cad2ca2afdd4c13577dbd079' in s:
    print('CUTS entry already present in', p)
else:
    assert anchor in s
    s = s.replace(anchor, anchor + entry, 1)
    p.write_text(s)
    print('CUTS entry added to', p)

# Give the host a fallback when the Metal device cannot create a residency set. GitHub's headless macOS runners
# (paravirtualised GPU) fail `newResidencySetWithDescriptor`, and the host aborts before it ever presents a frame, so
# the whole graphics bring-up would be untestable in CI. Real devices keep the normal path; DM_MTL_NO_RESIDENCY=1
# skips the set, and a failure to create it degrades instead of aborting.
p = nx / 'dm' / 'gfx' / 'nvn' / 'nvn_mtl.m'
orig = p.read_text()
if 'DM_MTL_NO_RESIDENCY' in orig:
    print('residency fallback already present in', p)
else:
    s = orig
    s = s.replace("""static void res_add_at(id<MTLResource> r, int line) {
    if (!r) return;""", """static void res_add_at(id<MTLResource> r, int line) {
    if (!r || !g_res) return;""", 1)
    s = s.replace("""static void res_remove(id<MTLResource> r) {
    if (!r) return;""", """static void res_remove(id<MTLResource> r) {
    if (!r || !g_res) return;""", 1)
    s = s.replace("""static void res_commit(void) {
    pthread_mutex_lock(&g_res_mu);
    if (g_res_dirty) {""", """static void res_commit(void) {
    pthread_mutex_lock(&g_res_mu);
    if (g_res && g_res_dirty) {""", 1)
    s = s.replace("""    g_res = [g_dev newResidencySetWithDescriptor:rd error:&re];
    if (!g_res) MDIE("failed to create the MTLResidencySet");
    [g_q addResidencySet:g_res];""", """    g_res = getenv("DM_MTL_NO_RESIDENCY") ? nil : [g_dev newResidencySetWithDescriptor:rd error:&re];
    if (!g_res) MLOG("[RED] no MTLResidencySet (%s): running without one (resources become resident implicitly)", getenv("DM_MTL_NO_RESIDENCY") ? "DM_MTL_NO_RESIDENCY" : (re ? re.localizedDescription.UTF8String : "unknown"));
    else [g_q addResidencySet:g_res];""", 1)
    s = s.replace("""    [g_q4 addResidencySet:g_res];""", """    if (g_res) [g_q4 addResidencySet:g_res];""", 1)
    assert s != orig, 'residency patch did not match: dm/gfx/nvn/nvn_mtl.m changed upstream'
    p.write_text(s)
    print('nvn_mtl.m: residency-set fallback applied')

# ---- Software BC decode for GPUs without BC support (iPhone A15/A16 and earlier) -------------------------------
# Upstream targets A17 Pro and later; its README says there is no decompression path, and on this phone the first
# MTLTextureDescriptor with a BC format aborts inside Metal (`invalid pixelFormat (130)` = BC1_RGBA, seen in the device
# log of 2026-10-23). The decoder and the format table come from our own fork (gfx/tex/nvn_bcdec.c, bcdec MIT).
import shutil as _sh
_here = pathlib.Path(__file__).resolve().parent
_src_tex = _here / 'bc'                     # nvn_bcdec.c / nvn_bcdec.h / bcdec.h staged in this repository
if _src_tex.is_dir():
    (_sh.copytree(_src_tex / 'bcdec', nx / 'dm' / 'third_party' / 'bcdec', dirs_exist_ok=True))
    for _f in ('nvn_bcdec.c', 'nvn_bcdec.h'):
        _sh.copy2(_src_tex / _f, nx / 'dm' / 'gfx' / 'tex' / _f)
    print('bc decode: files copied')

p = nx / 'dm' / 'gfx' / 'nvn' / 'nvn_mtl.m'
orig = p.read_text()
if 'nvn_bc_decode' in orig:
    print('bc decode: patch already present in', p)
else:
    s = orig
    # 1) include the decoder next to the other texture headers
    s = s.replace('#include "nvn_mtl.h"', '#include "nvn_mtl.h"\n#include "../tex/nvn_bcdec.h"', 1)
    # 2) capability flag, set next to the other device checks in mtl_init
    s = s.replace('''    if (!g_dev.hasUnifiedMemory) MDIE("needs a unified-memory device (zero-copy memory pools)");''',
'''    if (!g_dev.hasUnifiedMemory) MDIE("needs a unified-memory device (zero-copy memory pools)");
    // GPUs without BC compressed formats (A15/A16 and earlier; Apple silicon Macs and A17 Pro and later have them):
    // BC textures are created as RGBA8 and decoded on the CPU at upload (nvn_bcdec.c). Without this Metal aborts the
    // process in MTLTextureDescriptor validation ("invalid pixelFormat (130)" = BC1_RGBA).
    g_bc_ok = g_dev.supportsBCTextureCompression ? 1 : 0;
    if (!g_bc_ok) MLOG("[nvn-mtl] this GPU has no BC compressed formats: BC textures are decoded to RGBA8 on the CPU");''', 1)
    s = s.replace('static id<MTLResidencySet> g_res;', 'static id<MTLResidencySet> g_res;\nstatic int g_bc_ok = 1;   // set in mtl_init from MTLDevice.supportsBCTextureCompression\nstatic int nvn_fmt_bc(uint32_t f);   // defined further down; used by tex_desc', 1)
    # 3) tex_desc: substitute the pixel format of a BC texture when the device cannot sample BC
    s = s.replace('''    if (!nvn_fmt_to_mtl(t->d.format, &pf, swz) || !pf) { RED_ONCE(0, "texture format %#x has no Metal equivalent (first case)", t->d.format); return nil; }''',
'''    if (!nvn_fmt_to_mtl(t->d.format, &pf, swz) || !pf) { RED_ONCE(0, "texture format %#x has no Metal equivalent (first case)", t->d.format); return nil; }
    if (!g_bc_ok && nvn_fmt_bc(t->d.format)) { uint32_t up; int bpp;   // decode on upload, see pkg_upload_
        if (nvn_bc_unpacked(t->d.format, &up, &bpp)) { static int n; if (n++ < 8) MLOG("[nvn-mtl] BC texture format %#x -> Metal format %#x, decoded on the CPU (%ux%u levels %u)", t->d.format, up, t->d.width, t->d.height, t->d.levels); pf = up; } }''', 1)
    # 4) pkg_upload_: force the CPU path for BC and decode into RGBA8 staging
    s = s.replace('''    int use_gpu = !sparse && g_nvn_deswz_gpu && mtl_addr((uint64_t)t->mem, t->L.size, &mb, &mo);''',
'''    int bcs = !g_bc_ok && nvn_fmt_bc(t->d.format);   // BC without GPU support: decode below (GPU deswizzle keeps the blocks)
    int use_gpu = !bcs && !sparse && g_nvn_deswz_gpu && mtl_addr((uint64_t)t->mem, t->L.size, &mb, &mo);''', 1)
    s = s.replace('''    id<MTLBuffer> stg = [g_dev newBufferWithLength:total ? total : 16 options:MTLResourceStorageModeShared];''',
'''    size_t total_bc = 0;
    if (bcs) for (unsigned l = 0; l < d.mipmapLevelCount; l++) {   // decoded size: w*h*4 per slice/layer
        uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u), z = t->d.target == 2 ? MAX(t->d.depth >> l, 1u) : 1;
        total_bc += (size_t)w * h * z * layers * 4; }
    id<MTLBuffer> stg = [g_dev newBufferWithLength:(bcs ? (total_bc ? total_bc : 16) : (total ? total : 16)) options:MTLResourceStorageModeShared];''', 1)
    s = s.replace('''            if (nvn_deswizzle(&t->d, l, y, src, (uint8_t *)stg.contents + off, pitch)) { RED_ONCE(9, "deswizzle failed format %#x target %d", t->d.format, t->d.target); break; }''',
'''            if (bcs) {   // deswizzle the blocks into a scratch buffer, then decode them into RGBA8 in the staging buffer
                uint8_t *blk = malloc(pitch * rows * z ? pitch * rows * z : 1);
                if (!blk) MDIE("BC scratch buffer for %ux%u failed", w, h);
                if (nvn_deswizzle(&t->d, l, y, src, blk, pitch)) { free(blk); RED_ONCE(9, "deswizzle failed format %#x target %d", t->d.format, t->d.target); break; }
                for (uint32_t zz = 0; zz < z; zz++)
                    nvn_bc_decode(t->d.format, blk + (size_t)zz * pitch * rows, pitch, w, h,
                                  (uint8_t *)stg.contents + off + (size_t)zz * w * 4 * h, (size_t)w * 4);
                free(blk);
                off += (size_t)w * 4 * h * z;
                up_blit_add(stg, off - (size_t)w * 4 * h * z, (size_t)w * 4, (size_t)w * 4 * h, MTLSizeMake(w, h, z), mt, y, l);
                continue;
            }
            if (nvn_deswizzle(&t->d, l, y, src, (uint8_t *)stg.contents + off, pitch)) { RED_ONCE(9, "deswizzle failed format %#x target %d", t->d.format, t->d.target); break; }''', 1)
    assert s != orig, 'bc decode patch did not match: nvn_mtl.m changed upstream'
    p.write_text(s)
    print('bc decode: nvn_mtl.m patched')

# ---- Find the game files wherever the Files app put them -----------------------------------------------
# The app only looked at Documents/romfs and <App>/romfs. The user copied the full RomFS into the app's Documents
# (Files shows it as the app's folder) and the log still said it used the bundle's copy, so the exact folder name under
# Documents is not one of the two. Search every child (and grandchild) of Documents for the profile's marker and log each
# candidate, so the next log says what iOS actually shows.
p = nx / 'dm' / 'ios' / 'Sources' / 'main.m'
orig = p.read_text()
if 'romfs candidate' in orig:
    print('romfs search: patch already present')
else:
    old = '''    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    return nil;'''
    new = '''    // Candidates in order: Documents/romfs, then every child and grandchild of Documents (the Files app shows the app's
    // Documents as the app's folder, so the game files can arrive under any name and any nesting), then the copy inside
    // the app bundle. Each candidate is logged with whether it holds the marker, so a "game files not found" report comes
    // with the list of what was actually there.
    NSMutableArray<NSString *> *cand = [NSMutableArray arrayWithObject:[doc stringByAppendingPathComponent:@"romfs"]];
    for (NSString *e in [fm contentsOfDirectoryAtPath:doc error:nil]) {
        NSString *c = [doc stringByAppendingPathComponent:e];
        BOOL isdir = NO; if (![fm fileExistsAtPath:c isDirectory:&isdir] || !isdir) continue;
        [cand addObject:c];
        for (NSString *e2 in [fm contentsOfDirectoryAtPath:c error:nil])
            [cand addObject:[c stringByAppendingPathComponent:e2]];
    }
    [cand addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]];
    for (NSString *d in cand) {
        BOOL has = [fm fileExistsAtPath:[d stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]];
        fprintf(stderr, "romfs candidate %s: %s\\n", d.fileSystemRepresentation, has ? "OK (has the marker)" : "no");
        if (has) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    }
    return nil;'''
    assert old in orig, 'romfs search patch did not match: main.m changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('romfs search: main.m patched')

# ---- Runtime application-pool override ---------------------------------------------------------------
# APP_POOL is a compile-time constant from the profile. The VAMM path needs it tuned per device (the heap request is
# pool - images, taken as one contiguous address region; every byte it holds is address space Unity's own pools cannot
# get), and rebuilding for each value costs a full CI run. DM_APP_POOL_MB=<megabytes> in Documents/env.txt on the device
# overrides it without a rebuild.
p = nx / 'dm' / 'host' / 'hle_svc.c'
orig = p.read_text()
if 'DM_APP_POOL_MB' in orig:
    print('app pool override: already present')
else:
    old = '#define APP_POOL DM_GAME_APP_POOL   // game profile app_pool (Mario 0xCD500000)'
    new = '''#define APP_POOL DM_GAME_APP_POOL   // game profile app_pool (Mario 0xCD500000)
// Bring-up override: DM_APP_POOL_MB=<megabytes> (Documents/env.txt) changes what GetInfo TotalMemory reports and what
// SetHeapSize and the map accounting accept, without rebuilding. WitchSpring R asks for pool - images as one contiguous
// virtual address region, so this decides how much of the alias region Unity's pools keep.
static uint64_t app_pool_bytes(void) {
    static uint64_t v;
    if (!v) { const char *e = getenv("DM_APP_POOL_MB");
              v = e ? (uint64_t)strtoull(e, NULL, 10) << 20 : DM_GAME_APP_POOL;
              if (e) LOG("DM_APP_POOL_MB: application pool %llu MB (profile %llu MB)", (unsigned long long)(v >> 20), (unsigned long long)((uint64_t)APP_POOL >> 20)); }
    return v;
}
#undef APP_POOL
#define APP_POOL app_pool_bytes()'''
    assert old in orig, 'app pool override patch did not match: hle_svc.c changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('app pool override: hle_svc.c patched')

# ---- DM_NVN_SHDUMP with a relative directory lands in Documents --------------------------------
# Dumping shaders missing from the map is the fastest way to add them (the dump is exactly the control section and code
# area the map records), but the host only accepts an absolute directory and the app's container UUID changes with every
# reinstall. A plain name (DM_NVN_SHDUMP=shump) is resolved under Documents here, so Documents/env.txt never has to carry
# a UUID.
p = nx / 'dm' / 'ios' / 'Sources' / 'main.m'
orig = p.read_text()
if 'DM_NVN_SHDUMP' in orig:
    print('shdump path: already handled')
else:
    old = '    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);'
    new = '''    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    { const char *sd = getenv("DM_NVN_SHDUMP");   // a relative name goes to Documents (the container path changes per install)
      if (sd && sd[0] && sd[0] != '/') setenv("DM_NVN_SHDUMP", [doc stringByAppendingPathComponent:@(sd)].fileSystemRepresentation, 1); }'''
    assert old in orig, 'shdump patch did not match: main.m changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('shdump path: main.m patched')

# ---- DM_ARGS: game arguments from the environment ----------------------------------------------------
# The host passes game arguments ("--" on the command line, else the profile's game_args). On the device the profile is
# compiled in, so testing a different Unity command-line switch (this build uses -job-worker-count for the job-system hang
# at load) would need a rebuild every time. DM_ARGS=... in Documents/env.txt now overrides the profile.
p = nx / 'dm' / 'host' / 'main.c'
orig = p.read_text()
if 'DM_ARGS' in orig:
    print('DM_ARGS: already handled')
else:
    old = '''    else if (*DM_GAME_ARGS) {   // no "--" on the command line (the iOS app, the NSP script's Mac runs): the game profile's game_args, split at spaces
        char *s = strdup(DM_GAME_ARGS);
        for (char *t = strtok(s, " "); t && g_argc < 63; t = strtok(NULL, " ")) g_argv[g_argc++] = t;
        LOG("game arguments from the game profile: %s", DM_GAME_ARGS);
    }'''
    new = '''    else if ((getenv("DM_ARGS") && *getenv("DM_ARGS")) || *DM_GAME_ARGS) {   // no "--" on the command line: DM_ARGS from the environment, else the profile's game_args, split at spaces
        const char *ga = getenv("DM_ARGS"); if (!ga || !*ga) ga = DM_GAME_ARGS;
        char *s = strdup(ga);
        for (char *t = strtok(s, " "); t && g_argc < 63; t = strtok(NULL, " ")) g_argv[g_argc++] = t;
        LOG("game arguments: %s", ga);
    }'''
    assert old in orig, 'DM_ARGS patch did not match: main.c changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('DM_ARGS: main.c patched')

# ---- DM_SIGLOG: count what each condition-variable signal actually woke --------------------------------
# A lost wakeup ("the job queue was signalled, but the signal woke nobody") is invisible in a thread dump: the waiters
# simply stay asleep. DM_SIGLOG=1 logs every svcSignalProcessWideKey with its key and the number of threads it moved,
# capped so a long run cannot flood the log.
p = nx / 'dm' / 'host' / 'hle_thread.c'
orig = p.read_text()
if 'DM_SIGLOG' in orig:
    print('siglog: already present')
else:
    old = '''        int left = 0; for (thr_t *w = g_wait; w; w = w->next) if (w->wkind == 2 && w->wkey == key) { left = 1; break; }
        if (!left) st32(key, 0);'''
    new = '''        int left = 0; for (thr_t *w = g_wait; w; w = w->next) if (w->wkind == 2 && w->wkey == key) { left = 1; break; }
        if (!left) st32(key, 0);
        { static int siglog = -1; static long nlog; if (siglog < 0) siglog = getenv("DM_SIGLOG") != NULL;
          if (siglog && (nlog < 400 || nlog % 2000 == 0)) {
              thr_t *me = cur(); uint64_t lr = me ? me->last_lr : 0; module_t *m = module_of((void *)lr);
              LOG("[sig] key %#llx woke %d, %s, from %s+%#llx", (unsigned long long)key, n, left ? "waiters left" : "none left",
                  m ? m->name : "?", m ? lr - (uint64_t)m->base : lr); }
          nlog++; }'''
    assert old in orig, 'siglog patch did not match: hle_thread.c changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('siglog: hle_thread.c patched')

# ---- DM_CORES: report fewer cores ---------------------------------------------------------------
# Unity sizes its job-worker pool from the core count it is told. The game hangs with 16 workers waiting on a job queue
# nothing feeds (device log 2026-10-24), so a smaller count is a way to make the engine keep the work on the main thread
# without relying on a Unity command-line switch. DM_CORES=1 in Documents/env.txt reports one core.
p = nx / 'dm' / 'host' / 'hle_svc.c'
orig = p.read_text()
if 'DM_CORES' in orig:
    print('cores: already present')
else:
    old = '        case I_CoreMask: v = 7; break;'
    new = '''        case I_CoreMask: { static uint64_t n; if (!n) { const char *e = getenv("DM_CORES"); int c = e ? atoi(e) : 3; if (c < 1 || c > 3) c = 3; n = (1u << c) - 1; if (e) LOG("DM_CORES: reporting %d core(s), mask %#llx", c, (unsigned long long)n); } v = n; break; }   // 3 cores by default (mask 7); DM_CORES=1..3 reports fewer'''
    assert old in orig, 'cores patch did not match: hle_svc.c changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('cores: hle_svc.c patched')

# ---- DM_FUTEX_KICK: a spurious wakeup every few ms ------------------------------------------------
# A condition-variable wakeup may be spurious: the waiter's loop re-checks its condition and sleeps again. So waking
# every condition-variable waiter periodically is semantically free, and it recovers a wakeup the guest never sent.
# WitchSpring R needs it: DM_SIGLOG showed all 16 job workers waiting on one queue condvar that is never signalled,
# while the main thread waits for the job they would run (device log 2026-10-24 21:00).
p = nx / 'dm' / 'host' / 'hle_thread.c'
orig = p.read_text()
if 'DM_FUTEX_KICK' in orig:
    print('futex kick: already present')
else:
    anchor = '''static void lock_acquire_for(thr_t *t, uint64_t addr, uint32_t tag) {'''
    i = orig.index(anchor)
    j = orig.index('\n}\n', i) + 3
    kick = '''
// DM_FUTEX_KICK=<ms>: wake every condition-variable waiter on a timer (see the note where it is started)
static void *kick_thread(void *arg) {
    int ms = (int)(intptr_t)arg;
    for (;;) {
        usleep((useconds_t)ms * 1000);
        pthread_mutex_lock(&G);
        int n = 0;
        for (int guard = 0; guard < 4096; guard++) {
            thr_t *w = NULL;
            for (thr_t *t = g_wait; t; t = t->next) if (t->wkind == 2) { w = t; break; }
            if (!w) break;
            lock_acquire_for(w, w->waddr, w->wtag);   // the same hand-over a real Signal does
            n++;
        }
        pthread_mutex_unlock(&G);
        if (n) { static int c; if (c < 20 || c % 200 == 0) LOG("[kick] woke %d condition-variable waiter(s)", n); c++; }
    }
    return NULL;
}
static void kick_start(void) {
    static int started; const char *e = getenv("DM_FUTEX_KICK");
    if (started || !e) return; started = 1;
    int ms = atoi(e); if (ms < 10) ms = 10; if (ms > 2000) ms = 2000;
    pthread_t th;
    if (!pthread_create(&th, NULL, kick_thread, (void *)(intptr_t)ms)) { pthread_detach(th); LOG("DM_FUTEX_KICK: waking condition-variable waiters every %d ms", ms); }
}
'''
    orig = orig[:j] + kick + orig[j:]
    # start it the first time the guest waits on a condition
    old = '''    case 0x1C: {  // WaitProcessWideKeyAtomic(x0 lock address, x1 condition key, w2 tag, x3 timeout)
        thr_t *t = cur(); uint64_t addr = regs[0], key = regs[1];'''
    new = '''    case 0x1C: {  // WaitProcessWideKeyAtomic(x0 lock address, x1 condition key, w2 tag, x3 timeout)
        kick_start();   // DM_FUTEX_KICK: a timer that wakes condition-variable waiters (defined above this switch)
        thr_t *t = cur(); uint64_t addr = regs[0], key = regs[1];'''
    assert old in orig
    orig = orig.replace(old, new, 1)
    if '#include <unistd.h>' not in orig:   # usleep in the kick thread
        orig = orig.replace('#include "dm.h"', '#include "dm.h"\n#include <unistd.h>', 1)
    p.write_text(orig)
    print('futex kick: hle_thread.c patched')

# ---- Dump more of the object a stalled thread waits on -------------------------------------------------
# 64 bytes is one Unity queue slot; a job queue holds its pending-job count and the worker slots around it, and the
# difference between "the job was never enqueued" and "the job is queued but nobody took it" is inside those bytes.
# DM_DUMP_WAITBIG=1 dumps 256 bytes instead.
p = nx / 'dm' / 'host' / 'hle_thread.c'
orig = p.read_text()
if 'DM_DUMP_WAITBIG' in orig:
    print('big wait dump: already present')
else:
    old = '''        uint8_t raw[64]; vm_size_t g3 = 0;'''
    new = '''        static int bigwait = -1; if (bigwait < 0) bigwait = getenv("DM_DUMP_WAITBIG") != NULL; const int rawsz = bigwait ? 256 : 64;
        uint8_t raw[256]; vm_size_t g3 = 0;'''
    assert old in orig
    orig = orig.replace(old, new, 1)
    orig = orig.replace('''!(vm_read_overwrite(mach_task_self(), t->waddr & ~0xfull, 64, (vm_address_t)raw, &g3))''',
                        '''!(vm_read_overwrite(mach_task_self(), t->waddr & ~0xfull, rawsz, (vm_address_t)raw, &g3))''')
    orig = orig.replace('''        if (have_raw) { char hx[200]; int q = 0; for (int i = 0; i < 64; i += 4) q += snprintf(hx + q, sizeof hx - q, "%08x ", *(uint32_t *)(raw + i));
                        fprintf(stderr, "[dm]   %#x waited-for object, 64 bytes from %#llx: %s\\n", t->handle, t->waddr & ~0xfull, hx); }''',
'''        if (have_raw) { for (int base = 0; base < rawsz; base += 64) { char hx[220]; int q = 0;
                            for (int i = base; i < base + 64 && i < rawsz; i += 4) q += snprintf(hx + q, sizeof hx - q, "%08x ", *(uint32_t *)(raw + i));
                            fprintf(stderr, "[dm]   %#x waited-for object, %d bytes from %#llx: %s\\n", t->handle, rawsz, (t->waddr & ~0xfull) + base, hx); } }''')
    p.write_text(orig)
    print('big wait dump: hle_thread.c patched')

# ---- DM_TRACE_RANGE: name the code on both sides of a synchronisation loop ---------------------------
# The last device run showed the main thread and the graphics worker trading 23k lock/signal/wait syscalls over one
# structure (0x704031c2xx) while the main thread's own completion wait was signalled exactly once and never again. A
# signal-only log cannot say which code is in that loop, so this logs every futex syscall that touches an address range
# together with the guest return address (module+offset), which is what the disassembly needs.
p = nx / 'dm' / 'host' / 'hle_thread.c'
orig = p.read_text()
if 'DM_TRACE_RANGE' in orig:
    print('trace range: already present')
else:
    old = '''    { thr_t *me = pthread_getspecific(g_keythr); if (me) { me->last_svc = num; me->last_lr = regs[30]; me->nsvc++; } }'''
    new = '''    { thr_t *me = pthread_getspecific(g_keythr); if (me) { me->last_svc = num; me->last_lr = regs[30]; me->nsvc++; } }
    { static uint64_t tlo, thi; static int tinit; static long tn;
      if (!tinit) { tinit = 1; const char *e = getenv("DM_TRACE_RANGE"); if (e) sscanf(e, "%lx-%lx", &tlo, &thi); }
      if (thi > tlo && (num == 0x1a || num == 0x1b || num == 0x1c || num == 0x1d) && tn < 400000) {
          int hit = 0; for (int i = 0; i < 4; i++) if (regs[i] >= tlo && regs[i] < thi) hit = 1;
          if (hit) { thr_t *c = pthread_getspecific(g_keythr);
                     // x30 inside an SDK function says nothing about the game, so walk the guest's frame pointer chain
                     // (x29 -> saved x29 / return address) and print the first few addresses that land in a module.
                     char bt[192]; int q = 0; uint64_t fp = regs[29];
                     for (int d = 0; d < 6 && fp && q < (int)sizeof bt - 32; d++) {
                         uint64_t w[2]; vm_size_t g4 = 0;
                         if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof w, (vm_address_t)w, &g4) || g4 != sizeof w) break;
                         module_t *mm = module_of((void *)w[1]);
                         if (mm) q += snprintf(bt + q, sizeof bt - q, " %s+%#llx", mm->name, (unsigned long long)(w[1] - (uint64_t)mm->base));
                         if (w[0] <= fp) break;
                         fp = w[0]; }
                     LOG("[tr] t%#x svc %#x x0=%#llx x1=%#llx x2=%#llx bt:%s", c ? c->handle : 0, num,
                         (unsigned long long)regs[0], (unsigned long long)regs[1], (unsigned long long)regs[2], bt); tn++; } } }'''
    assert old in orig, 'trace-range patch did not match: hle_thread.c changed upstream'
    p.write_text(orig.replace(old, new, 1))
    print('trace range: hle_thread.c patched')
