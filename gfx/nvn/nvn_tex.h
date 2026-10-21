// NVN texture storage layout (Tegra X1 block-linear), see nvn_tex.c.
#pragma once
#include <stdint.h>

typedef struct {
    int target, format, flags, samples;   // NVNtextureTarget / NVNformat / NVNtextureFlags / sample count (0 or 1 = single-sampled)
    uint32_t width, height, depth, levels, stride;
    int pkg_block_h;                      // Byte 0 of the packaged texture layout parameters (log2 of block height) + 1; 0 = use the automatic algorithm
    uint8_t swz_set, swz[4];              // Texture swizzle (NVNtextureSwizzle, same numeric values as MTLTextureSwizzle); swz_set = 0 means identity
    uint8_t ds_mode;                      // What a depth-stencil texture samples: 0 depth, 1 stencil (NVNtextureDepthStencilMode)
} nvn_texdesc;

typedef struct {
    uint64_t size, layer_size;            // Total storage bytes, bytes per layer
    uint32_t align, layers, bpb;          // Alignment, layer count, bytes per block
    unsigned tileH, tileD;                // Block height / block depth (log2 of the GOB count)
} nvn_texlayout;

void nvn_tex_layout(const nvn_texdesc *d, nvn_texlayout *o);
uint64_t nvn_tex_level_offset(const nvn_texdesc *d, unsigned level);
int nvn_fmt_bpb(int format, int *bw, int *bh);   // Bytes per block (0 = unknown format), block width and height
// Block height / block depth actually used by level `level` (log2 of the GOB count): the per-level block height shrinks with that level's row count (block rows), and deswizzling uses it level by level
void nvn_tex_level_tiles(const nvn_texdesc *d, unsigned level, unsigned *tileH, unsigned *tileD);
// Whether Metal can create a texture with this description. Limits from Apple's Metal Feature Set Tables (Apple3–Apple9; Apple10 allows 32768 for 1D / 2D / cube,
// so 16384 is the conservative value): 1D / 2D / cube width and height 16384, 3D width / height / depth 2048, array layers 2048 (MTLTextureDescriptor.arrayLength: 1–2048).
// Returns NULL when it fits, otherwise a short reason. Array layers follow tex_desc in nvn_mtl.m: 1D array = height, 2D / multisample / cube array = depth.
const char *nvn_texdesc_metal_check(const nvn_texdesc *d);
