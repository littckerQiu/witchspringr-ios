// Unit tests for buffer ↔ texture copy pitches (nvn_copy_pitch.h): expected values are worked out by hand from the block layout.
// Positive: BC blocks (4×4, 16 bytes) tightly packed and with padded rows / layers, one texel; negative: row stride below one row of blocks, image
// stride below one image, a negative stride, an image stride whose layers overflow size_t.
#include "../nvn/nvn_copy_pitch.h"
#include <stdio.h>

static int fail, total;
static void t(const char *name, int ok) { total++; fail += !ok; printf("%-72s %s\n", name, ok ? "✓" : "✗"); }
int main(void) {
    size_t row = 0, image = 0, extent = 0;
    // 9×5 texels of 4×4 blocks = 3×2 blocks of 16 bytes: a row of blocks is 48 bytes, an image 96, three layers 288
    t("BC 9x5x3, tight: row 48, image 96, extent 288",
      nvn_copy_pitch(9, 5, 3, 4, 4, 16, 0, 0, &row, &image, &extent) && row == 48 && image == 96 && extent == 288);
    t("BC 9x5x3, row stride 64, image stride 256: extent 768",
      nvn_copy_pitch(9, 5, 3, 4, 4, 16, 64, 256, &row, &image, &extent) && row == 64 && image == 256 && extent == 768);
    t("row stride only (64): image = 64 × 2 rows of blocks = 128",
      nvn_copy_pitch(9, 5, 1, 4, 4, 16, 64, 0, &row, &image, &extent) && row == 64 && image == 128 && extent == 128);
    t("one RGBA8 texel, depth 0 (one layer): extent 4", nvn_copy_pitch(1, 1, 0, 1, 1, 4, 0, 0, &row, &image, &extent) && extent == 4);
    t("neg: row stride 16 below one row of blocks (48)", !nvn_copy_pitch(9, 5, 3, 4, 4, 16, 16, 0, &row, &image, &extent));
    t("neg: image stride 64 below 64 × 2 rows", !nvn_copy_pitch(9, 5, 3, 4, 4, 16, 64, 64, &row, &image, &extent));
    t("neg: negative row stride", !nvn_copy_pitch(9, 5, 3, 4, 4, 16, -1, 0, &row, &image, &extent));
    t("neg: image stride INT64_MAX × 3 layers overflows", !nvn_copy_pitch(1, 1, 3, 1, 1, 4, 0, INT64_MAX, &row, &image, &extent));
    t("neg: zero width", !nvn_copy_pitch(0, 1, 1, 1, 1, 4, 0, 0, &row, &image, &extent));
    printf("== %d checks, %d failed ==\n", total, fail);
    return fail != 0;
}
