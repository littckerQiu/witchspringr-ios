# third_party — code written by others

Shipped with the repository so nothing has to be downloaded. Each component keeps its original license, in its own directory.

| Directory | What it is | Version and changes | Used by | License |
|---|---|---|---|---|
| `bcdec/` | BC texture decompression, single header `bcdec.h` | 0.985 (upstream commit `80859ed`), unmodified | `gfx/tex/nvn_bcdec.c`: CPU decompression on GPUs without BC support | `bcdec/LICENSE` (MIT or Unlicense) |
| `ryujinx/` | The Ryujinx shader translator: `Ryujinx.Graphics.Shader`, `Ryujinx.Common`, `Spv.Generator` | Ryujinx 1.3.2 with local fixes, see [ryujinx/README.md](ryujinx/README.md) | `gfx/tools/dmsh_xlate`: Switch shaders → SPIR-V | `ryujinx/LICENSE.txt` (MIT); `ryujinx/src/Spv.Generator/LICENSE` |

Third-party code outside this directory: `gfx/nvn/include/nvn.h` (MIT, author in the file header) and the texture layout size algorithm in
`gfx/nvn/nvn_tex.c`, ported from deko3d (zlib license).

Linked, not shipped: libvpx (WebM Project, BSD-3-Clause), from Homebrew (`brew install libvpx`). `host/Makefile` links its static library into the
Mac host when it is installed, for VP8 / VP9 movies (`host/hle_movie.c`); a host built from it carries libvpx's copyright notice and license terms.
