# Rewriter rules for witchspringr (tools/patch_nso.py --rules games/witchspringr/rules.py),
# keyed by the NSO build ID of each module.
# Format: see the "Game rules" section at the top of patch_nso.py.
#
# Deliberately empty: the generic rewrite (x18, tpidr_el0, tpidrro_el0, svc, timer reads) needs no
# game knowledge. Add a CUT here only after the game runs and the log says so, e.g. Unity's
# "touchscreen" player setting (see engines/unity/README.md) once the constant has been located in
# main 2825729412f0903e (Unity 2020.2.1f1, IL2CPP).

CUTS = {}
OBS = {}
PARAMS = {}
