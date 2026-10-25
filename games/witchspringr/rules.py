# Rewriter rules for witchspringr (tools/patch_nso.py --rules games/witchspringr/rules.py),
# keyed by the NSO build ID of each module.
# Format: see the "Game rules" section at the top of patch_nso.py.
#
# Deliberately empty: the generic rewrite (x18, tpidr_el0, tpidrro_el0, svc, timer reads) needs no
# game knowledge. Add a CUT here only after the game runs and the log says so, e.g. Unity's
# "touchscreen" player setting (see engines/unity/README.md) once the constant has been located in
# main 2825729412f0903e (Unity 2020.2.1f1, IL2CPP).

# sdk 16.2.6 (a5cb2175…). The SDK's VAMM manager takes 0x3fe00000 (~1 GB) of the alias region as the node area of its address
# region manager before handing out anything (AddressRegionManager's constructor, sdk+0x134778: mov w8,#0x3fe00000; add x8,x1,x8).
# With a 5.4 GB alias region that leaves too little for the game's ~2.3 GB heap plus Unity's own pools, and the manager's first
# handout fails (0x1803). Cut it to 62 MB -- the same cut seedds/nxnative documents for Engage and Tears of the Kingdom
# (docs/agents/03-bringup.md, "First AllocateAddressRegion fails with 0x1803").
CUTS = {
    'a5cb2175cad2ca2afdd4c13577dbd079': [
        (0x134778, '08fca752', '087ca052', 'AddressRegionManager node area: mov w8,#0x3fe00000 (1 GB) -> #0x3e00000 (62 MB)'),
        # The constructor registers the node area's length as an occupied region with a second mov (w9); cutting only the first
        # left the manager believing it owned 1 GB while the region started 62 MB in, which is exactly the bookkeeping mismatch
        # docs/agents/03-bringup.md warns about (Octopath / TotK cut both).
        (0x13480c, '09fca752', '097ca052', 'AddressRegionManager node area length: mov w9,#0x3fe00000 (1 GB) -> #0x3e00000 (62 MB)'),
    ],
}
OBS = {}
PARAMS = {}
