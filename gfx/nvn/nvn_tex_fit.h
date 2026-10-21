// The compatible view tex_fit (nvn_mtl.m) binds when a shader declares another texture type than the bound texture has (unit test
// tests/t_tex_fit.m): the number of slices of a view of type want over a texture of type have with `layers` array slices, or 0 when there is
// none. Supported, as in nxnative 42a50ef: 2D array ↔ 2D (one slice: a non-array Maxwell sample of a 2D array reads layer 0), 2D array → cube
// (the first six slices) and → cube array (whole cubes). Objective-C only (MTLTextureType).
#pragma once
#import <Metal/Metal.h>

static inline NSUInteger nvn_tex_fit_slices(MTLTextureType want, MTLTextureType have, NSUInteger layers) {
    if (want == MTLTextureType2D && have == MTLTextureType2DArray) return 1;
    if (want == MTLTextureType2DArray && have == MTLTextureType2D) return 1;
    if (want == MTLTextureTypeCube && have == MTLTextureType2DArray && layers >= 6) return 6;
    if (want == MTLTextureTypeCubeArray && have == MTLTextureType2DArray && layers >= 6) return layers / 6 * 6;
    return 0;
}
// The view itself: the first ns slices of t, all its levels, its format and swizzle, as type want
static inline id<MTLTexture> nvn_tex_fit_view(id<MTLTexture> t, MTLTextureType want, NSUInteger ns) {
    return [t newTextureViewWithPixelFormat:t.pixelFormat textureType:want levels:NSMakeRange(0, t.mipmapLevelCount) slices:NSMakeRange(0, ns) swizzle:t.swizzle];
}
