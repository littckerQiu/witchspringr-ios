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
