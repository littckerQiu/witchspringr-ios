# witchspringr — WitchSpring R (Switch, base game v0)

Profile drafted on an Android device from `WitchSpringR.nsp` (a base-game NSP with no update NSP), so several fields are still
defaults; the ones marked **TODO** must be measured on the Mac once the game runs.

## What the dump is

| Field | Value |
|---|---|
| Title ID | `010018401EEA8000` (`OriginalId` `010018401EEA8800`, content type Application) |
| Version | `0` — base game only, no update was dumped |
| Key generation | 18 (`titlekek_11`, `master_key_11`) |
| Program NCA | `7c797087a3ed16d9a7d694b616f31098`, 6,404,341,760 bytes |
| Control NCA | `c4407e475da1230fa06f961d4895d490`, 769,536 bytes (`NintendoLogo.png`, `StartupMovie.gif`) |
| LegalInformation NCA | `4efcae1ad839ec48a18d0f40dc7c46ef`, 174,592 bytes |
| Meta NCA | `4bdd2e64fd3aa2ddfd07e9ccf6b6345e`, 3,584 bytes |
| NCA hashes | every NCA's SHA-256 matches `<Hash>` in the bundled `cnmt.xml` — the dump is intact |

ExeFS (program NCA section 0, 47,382,528 bytes):

| Module | Size | NSO build ID |
|---|---|---|
| `main` | 37,673,303 | `2825729412f0903e406f869e05d4686d` |
| `sdk` | 6,217,521 | `a5cb2175cad2ca2afdd4c13577dbd079` |
| `subsdk0` | 3,436,212 | `220d36873cbb6d5dc39a9a37127ea80d` |
| `rtld` | 7,952 | `1c6daa47389cb7915f054cbe9750a98e` (played by the host, not listed in `modules`) |
| `main.npdm` | 1,604 | — |

RomFS (program NCA section 1, 6,356,844,544 bytes; 5,881 files, 6,343,848,164 bytes of content):

| Kind | Files | Bytes |
|---|---|---|
| `*.bundle` (Addressables) | 5,839 | 4,428.1 MiB |
| `*.resource` (`resources.resource`, `sharedassets1.resource`) | 2 | 846.6 MiB |
| `*.unity3d` | 1 | 682.6 MiB |
| `global-metadata.dat` | 1 | 8,408,296 |
| `*.json`, `*.manifest`, `*.dat`, `*.xml`, `*.config`, extensionless (`unity default resources`, `level0`, `battleicon`, `bgm`, …) | 38 | 69.4 MiB |

Engine: **Unity 2020.2.1f1**, **IL2CPP metadata version 27** (read from `Data/Managed/Metadata/global-metadata.dat`), Addressables
build (`Data/StreamingAssets/aa/...`). The engine version comes from the `UnityFS` header of a bundle (`5.x.x`, `2020.2.1f1`).

Directory names recovered from the RomFS directory table: `Data`, `Data/Managed`, `Data/Managed/Metadata`, `Data/Resources`,
`Data/StreamingAssets`, `Data/StreamingAssets/aa`, `Data/StreamingAssets/aa/Switch`, `Data/StreamingAssets/AddressablesLink`
(plus the RomFS root).

### RomFS layout caveat

This package's RomFS is **not canonical**: the 0x50-byte header at the start of the RomFS section does not begin with `ROMFS`
(the first word reads `0x50`), and the directory/file hash + metadata tables live *after* the file data (at offset
`0x17A201B70`/`0x17A2078C8` inside the section), not right after the header. The file table itself is the normal format
(`0x20 + name` per entry: parent, sibling, offset u64, size u64, hash, name_len), which is how the listing above was produced.
`tools/game_extract.sh` (LibHac) may refuse this section; if it does, the extracted tree in `workspace.romfs` must be produced
another way and this note updated.

## Status

Done on the phone (Linux/aarch64, no macOS):

- ExeFS dumped and `games/witchspringr/game.json` written; `tools/gen_game.py` accepts it.
- `tools/build_product.sh` rewrites all three modules:
  `main` 1,687,896 patch bytes / 22,094 slot refs, `sdk` 555,604 / 13,274 (100 gates), `subsdk0` 390,080 / 9,350.
- `verify/equiv.py` (Unicorn, per rewrite site) passes on all three modules:
  `main` 22,094 sites / 68,377 trials, `sdk` 13,174 / 40,288 (103 gates), `subsdk0` 9,350 / 28,439 — `diff_sites=0` everywhere and
  300/300 injected mutations caught in each. Logs: `witchspringr-work/logs/`.
- Not runnable here: `verify/structck.py` (needs `llvm-objdump`) and the `gatefn` bench (Apple assembler syntax in
  `host/entry.S`, `host/hstack.S`).

Not done (needs an Apple-silicon Mac, see `PORTING.md` / `ios/README.md`):

- `make -C host GAME=witchspringr` and the first run with `DM_NVN_SHMAP` pointing at an empty map, to find the services and NVN
  paths this game needs.
- Shader capture and translation: `engines/unity/shader_extract.py` over `workspace.romfs/Data`, then
  `gfx/tools/shmap_from_capture.py`, `gfx/tools/dmsh_build.py`, `c1_guard.py` (needs .NET + `spirv-cross` + Xcode).
- `ios/run.sh build/install/push-data/launch`.

## TODO in this profile

- `device_api` — left at the default `55.15`; the game's NVN version check must be observed in the first host run.
- `nvn_c2.tex` — the `0x168` layout is the Unity 6 (manosaba) one; a Unity 2020.2 build may use the older `0x20` bank. Wrong
  values show up as "binding without a slot" lines in `dmsh_build.py`'s summary.
- `language` — `en-US` assumed; the game ships Korean/English/Japanese/Chinese, `DM_LANG` overrides.
- `screen` — 1920×1080 assumed.
- `save_sync` — empty until the save paths are known (probably under `Data/…` or a Unity persistent path).
- `romfs.files` — only `Data/Managed/Metadata/global-metadata.dat` (path standard for Unity, size verified) is listed; add the
  real key files from the extracted tree. `romfs.tree` is `.` with the full file count and byte total, which catches a
  half-copied dump without knowing the tree yet.
- `workspace.icon` — 1024×1024 PNG from the game's own art, not generated here.

## 着色器（已在手机上抽完）

`engines/unity/shader_extract.py` 需要适配 Unity 2019/2020 的序列化格式（原版只认 manosaba 的 Unity 6 布局），改动已入库：

- pass 里的 `progVertex`/`progFragment`… 是 `m_SubPrograms` 平铺列表（Unity 6 是 `m_PlayerSubPrograms` 分层）；
- 一个 subprogram 记录里**先像素后顶点**两段控制区首尾相接（subprogram version 201806140），按 `CTL` 魔数逐段取；
- Unity 2020 的 `ComputeShader` 没有 `uniqueVariants`，暂时跳过并计数。

结果（`work/shader_capture/`，`work/shader_map.tsv`）：

```
40703 distinct shaders (vertex 20349, fragment 20353, compute 1)
跳过：compute shader without uniqueVariants ×30，stage -1 ×1
```

来源是 `data.unity3d` 与 `unity default resources`；抽查的 12 个 Addressables bundle 里没有 `Shader` 对象，所以 5,839 个 bundle 不需要逐个扫。
注意这是 manosaba（2,752 个）的约 15 倍，Metal 编译阶段的耗时要在 CI 上分摊。

## Touch input

The WitchSpring series is a mobile-first series, so the shipped Unity player settings may already have the touchscreen enabled.
Check the "touchscreen" constant at the start of `main` (see `engines/unity/README.md`) before adding a `CUTS` rule; `rules.py`
is empty on purpose.
