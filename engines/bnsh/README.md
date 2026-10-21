# engines/bnsh — games that ship NVN BNSH shader files

Nintendo's own engines keep their compiled shaders in BNSH files (inside BFSHA archives, SARC packs and effect sets) instead of building them
at run time. Found while porting Tears of the Kingdom 1.4.3; which files to read and the BNSH layout follow
[MacNativeGames](https://github.com/ly05010419/MacNativeGames)' `prepare_shader_seed.py` (MIT), the code is ours.

## Shader extraction

```sh
python3.14 engines/bnsh/shader_extract.py <RomFS> $DM_ROOT/<workspace.shader_capture>
```

Python 3.14 or later (`compression.zstd`), no other packages. It reads `Pack/Bootup.Nin_NX_NVN.pack.zs`, `Lib/**`, `Shader/**` and the effect
sets `Effect/**.esetb.byml.zs` (zstd frames take their dictionary from `Pack/ZsDic.pack.zs` by dictionary ID): BNSH files in BFSHA archives and
effect sets, and the agl / gsys / Terrain / application shader archives (`*.sharcb` inside those packs, magic BAHS, version 9: control sections in
front, every code area in one pool; the layout is described in the script). It writes the capture format of the host's `DM_SHDUMP`
(`<key>.ctl` + `<key>.data`), `bnsh_index.tsv` (key, stage, source) and `pairs.tsv` (the vertex / pixel pair of every BNSH program, which
`dmsh_build.py` pads vertex shaders for; sharcb shaders add none, their pairs come from run-time captures). Pointed at an existing capture
directory it adds only what is missing: shaders already there must be byte-identical, and only new pairs are appended.

On Tears of the Kingdom 1.4.3: 26849 shaders (14485 vertex, 12124 pixel, 240 compute; 2478 more than the BNSH files alone), 19669 pairs, in a
few seconds. 3572 of the 3793 shaders a run of the title and the prologue captured are among them, byte-identical; of the other 221, 32 control
sections are in `main` with their code elsewhere and the rest are not located yet (keep them from run-time captures). Next steps:
[PORTING.md](../../PORTING.md) (stage map, `dmsh_build.py`, `c1_guard.py`).
