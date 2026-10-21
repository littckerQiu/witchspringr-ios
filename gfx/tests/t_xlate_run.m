// Runner for t_xlate_ops.py: each line of the list is "<name> TAB <MSL file> TAB <buffer index or -1> TAB <hex words, comma separated>"; the MSL's
// fragment function main0 (a translated test program that loads its inputs from constant bank 3 and writes R0 to colour target 0 as uint) draws one
// pixel into a 1x1 R32Uint target with the words at the start of that bank (64 KiB, the size the translator declares); prints "<name> TAB <hex value>"
// or "<name> TAB error: ...". Compiled with the safe math mode, as dmsh_build.py compiles the game's shaders (-fmetal-math-mode=safe).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kVertex = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VOut { float4 pos [[position]]; };\n"
    "vertex VOut vmain(uint vid [[vertex_id]]) { float2 p = float2(float((vid << 1) & 2), float(vid & 2)); VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: t_xlate_run <list>\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { fprintf(stderr, "no Metal device\n"); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLCompileOptions *opt = [MTLCompileOptions new]; opt.mathMode = MTLMathModeSafe; opt.preserveInvariance = YES;
    NSError *err = nil;
    id<MTLLibrary> vlib = [dev newLibraryWithSource:kVertex options:opt error:&err];
    if (!vlib) { fprintf(stderr, "vertex: %s\n", err.localizedDescription.UTF8String); return 2; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> bank = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    NSString *list = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
    if (!list) { fprintf(stderr, "list: %s\n", err.localizedDescription.UTF8String); return 2; }
    for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"]; if (f.count != 4) continue;
        const char *name = f[0].UTF8String;
        NSString *src = [NSString stringWithContentsOfFile:f[1] encoding:NSUTF8StringEncoding error:&err];
        id<MTLLibrary> lib = src ? [dev newLibraryWithSource:src options:opt error:&err] : nil;
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
        if (!fn) { printf("%s\terror: %s\n", name, err ? err.localizedDescription.UTF8String : "no main0"); err = nil; continue; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [vlib newFunctionWithName:@"vmain"]; pd.fragmentFunction = fn; pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { printf("%s\terror: %s\n", name, err.localizedDescription.UTF8String); err = nil; continue; }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        memset(bank.contents, 0, 65536); uint32_t *w = bank.contents; int nw = 0;
        for (NSString *h in [f[3] componentsSeparatedByString:@","]) if (h.length && nw < 16) w[nw++] = (uint32_t)strtoul(h.UTF8String, NULL, 16);
        [e setRenderPipelineState:ps];
        if (f[2].intValue >= 0) [e setFragmentBuffer:bank offset:0 atIndex:(NSUInteger)f[2].intValue];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        uint32_t v = 0; [rt getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        printf("%s\t%08x\n", name, v);
    }
    return 0;
} }
