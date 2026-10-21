// A Depth16Unorm load-clear that matches what a fragment writing the same depth stores. On Apple GPUs the load-clear truncates and a fragment
// write rounds: 0.5 clears to 32767 and is written as 32768, so an EQUAL depth test against a cleared D16 attachment fails on whole tiles
// (Tears of the Kingdom's skill effects classify pixels that way: coloured 64-pixel squares with Ultrahand and Recall). The nearest D16 value is
// taken, then a point inside both its truncation and its rounding bin (a quarter unit up, since the descriptor's double becomes a float).
// From MacNativeGames' nvn_depth_clear.h (3d90e41, MIT); other depth formats and the quad clears drawn by a fragment need nothing (t_d16clear).
#pragma once
#include <math.h>

static inline double nvn_depth16_clear_value(double depth) {
    if (!isfinite(depth) || depth <= 0.0 || depth >= 1.0) return depth;
    double q = round(depth * 65535.0);
    return q >= 65535.0 ? 1.0 : (q + 0.25) / 65535.0;
}
