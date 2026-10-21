// Buffer ↔ texture copy pitches (pure function, unit test tests/t_copy_pitch.c), from d2r-mobile 86b1315 (SepheTT, MIT). Both copy directions
// use the strides recorded by SetCopyRowStride / SetCopyImageStride; 0 means tightly packed. A copy whose ranges are invalid or overflow is
// refused before any memory pool is addressed. width / height in texels, depth = layers or slices (0 = 1), bw / bh = block size, bpb = bytes
// per block. Out: row and image strides in bytes and the extent the copy touches in the buffer.
#pragma once
#include <stddef.h>
#include <stdint.h>

static inline int nvn_copy_pitch(int width, int height, int depth, int bw, int bh, int bpb, int64_t row_stride, int64_t image_stride,
                                 size_t *row, size_t *image, size_t *extent) {
    if (width <= 0 || height <= 0 || depth < 0 || bw <= 0 || bh <= 0 || bpb <= 0 || row_stride < 0 || image_stride < 0) return 0;
    size_t blocks = ((size_t)width + bw - 1) / bw, rows = ((size_t)height + bh - 1) / bh;
    if (blocks > SIZE_MAX / (size_t)bpb) return 0;
    size_t tight = blocks * bpb;
    *row = row_stride ? (size_t)row_stride : tight;
    if (*row < tight || *row > SIZE_MAX / rows) return 0;
    *image = image_stride ? (size_t)image_stride : *row * rows;
    if (*image < *row * rows) return 0;
    size_t layers = depth ? (size_t)depth : 1;
    if (*image > SIZE_MAX / layers) return 0;
    *extent = *image * layers;
    return 1;
}
