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
shutil.copy2(prof, dst / 'game.tsv')
print('profile ->', dst)

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
assert anchor in s and 'a5cb2175cad2ca2afdd4c13577dbd079' not in s
s = s.replace(anchor, anchor + entry, 1)
p.write_text(s)
print('CUTS entry added to', p)
