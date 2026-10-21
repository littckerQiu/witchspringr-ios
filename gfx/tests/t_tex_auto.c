// Automatic block height of block-linear textures (nvn_tex.c): NVN truncates height in blocks × 1.5 to whole GOB rows before it picks the power of
// two; deko3d's heuristic, which this followed, rounds up. The 40 sizes and block heights below are the original SDK's CPU queries (storage size
// and block height of every mip) for RGBA8 and BC3 boundary cases, as MacNativeGames recorded them (cd85f5b, MIT; no game data); 16 of them
// differed with the rounded-up choice, among them Tears of the Kingdom's 160×160 BC3 shrine warp pad, half of which read padding (black).
#include "../nvn/nvn_tex.h"
#include "../tex/nvn_deswizzle.h"
#include <stdio.h>
#include <stdint.h>
typedef struct { unsigned format, width, height, levels, h; uint64_t size; } tcase;
static const tcase cases[] = {
    {0x25,40,1,6,0,4608}, {0x25,40,8,6,0,4608}, {0x25,40,9,6,0,6144}, {0x25,40,10,6,0,6144}, {0x25,40,11,6,1,6144}, {0x25,40,16,6,1,6144},
    {0x25,40,17,6,1,9216}, {0x25,40,21,6,1,10240}, {0x25,40,22,6,2,10240}, {0x25,40,32,6,2,10240}, {0x25,40,33,6,2,16384}, {0x25,40,40,6,2,18944},
    {0x25,40,42,6,2,18944}, {0x25,40,43,6,3,18944}, {0x25,40,64,7,3,19456}, {0x25,40,65,7,3,31744}, {0x25,40,85,7,3,37376}, {0x25,40,86,7,4,37376},
    {0x25,40,128,8,4,37888}, {0x25,40,129,8,4,62464},
    {0x48,160,4,8,0,12288}, {0x48,160,32,8,0,12288}, {0x48,160,36,8,0,17408}, {0x48,160,40,8,0,17408}, {0x48,160,44,8,1,17408},
    {0x48,160,64,8,1,17408}, {0x48,160,68,8,1,30208}, {0x48,160,84,8,1,30208}, {0x48,160,88,8,2,30208}, {0x48,160,128,8,2,30208},
    {0x48,160,132,8,2,57344}, {0x48,160,160,8,2,57344}, {0x48,160,168,8,2,57344}, {0x48,160,172,8,3,57344}, {0x48,160,256,9,3,57856},
    {0x48,160,260,9,3,112128}, {0x48,160,340,9,3,113152}, {0x48,160,344,9,4,113152}, {0x48,160,512,10,4,113664}, {0x48,160,516,10,4,222208},
};
static int n, fail;
static void expect(const char *what, unsigned long long want, unsigned long long got) { n++; fail += want != got; if (want != got) printf("%-60s expected %llu → got %llu ✗\n", what, want, got); }
int main(void) {
    int bad = 0;
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        const tcase *c = &cases[i]; char what[96];
        nvn_texdesc d = {.target = 1, .format = (int)c->format, .samples = 1, .width = c->width, .height = c->height, .depth = 1, .levels = c->levels};
        nvn_texlayout l; nvn_tex_layout(&d, &l); int f0 = fail;
        snprintf(what, sizeof what, "format %#x %ux%u, %u levels: block height", c->format, c->width, c->height, c->levels); expect(what, c->h, l.tileH);
        snprintf(what, sizeof what, "format %#x %ux%u, %u levels: size", c->format, c->width, c->height, c->levels); expect(what, c->size, l.size);
        bad += fail != f0;
    }
    printf("SDK layout cases: %d of 40 differ\n", bad);
    nvn_texdesc pad = {.target = 1, .format = 0x48, .samples = 1, .width = 160, .height = 160, .depth = 1, .levels = 8};
    unsigned h, dd; nvn_tex_level_tiles(&pad, 0, &h, &dd);
    expect("160x160 BC3 base level: four-GOB blocks (log2 2)", 2, h);
    expect("its block (80, 0) lies in the second GOB column", 10240, nvn_bl_offset(320, 0, 0, 640, 40, h, dd));
    expect("its last block (156, 39) comes before the padding", 39408, nvn_bl_offset(624, 39, 0, 640, 40, h, dd));
    pad.pkg_block_h = 4; nvn_tex_level_tiles(&pad, 0, &h, &dd);
    expect("a packaged layout's block height (log2 3) still wins", 3, h);
    printf("== %d checks, %d failed ==\n", n, fail);
    return fail != 0;
}
