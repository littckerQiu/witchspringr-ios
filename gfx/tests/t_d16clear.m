// nvn_depth_clear.h: a Depth16Unorm load-clear of nvn_depth16_clear_value(d) stores what a fragment writing d stores, on this GPU, through Metal 3
// and (where available) Metal 4, the two APIs the replay is built for; the raw value (the negative control) differs for some depths (Apple GPUs
// truncate the clear and round the fragment).
// Same method as MacNativeGames' probe (3d90e41): the left half of a D16 target drawn by a fragment shader writing the depth, the right half only
// cleared, both read back.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../nvn/nvn_depth_clear.h"
#include <stdio.h>
static int n, fail;
#define EXPECT(name, want, got) do { long long w_ = (want), g_ = (got); n++; printf("%-66s expected %-6lld → got %-6lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); fail += w_ != g_; } while (0)
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2. - 1., .5, 1.); return o; }\n"
        "struct D { float z [[depth(any)]]; };\nfragment D fs(constant float &d [[buffer(0)]]) { return D{d}; }\n" options:nil error:&e];
    if (!lib) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:128 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> rd = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared], par = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q3 = [dev newCommandQueue];
    float v[800]; unsigned nv = 0; const float anchors[] = {.25f, .5f, .75f, nextafterf(.25f, 0), nextafterf(.25f, 1), nextafterf(.5f, 0), nextafterf(.5f, 1)};
    for (unsigned i = 0; i < sizeof anchors / sizeof anchors[0]; i++) v[nv++] = anchors[i];
    for (unsigned i = 0; i < 256; i++) v[nv++] = fmaf((float)i / 255.f, .5f, .5f);
    uint32_t st = 0x51a7d16u; for (unsigned i = 0; i < 512; i++) { st = st * 1664525u + 1013904223u; v[nv++] = (float)(st >> 8) * 0x1p-24f; }
    for (int api = 3; api <= 4; api++) {
        if (api == 4) { if (@available(macOS 26.0, *)) {} else { printf("Metal 4 not available: only Metal 3 checked\n"); break; } }
        unsigned bad[2] = {0, 0};
        for (unsigned i = 0; i < nv; i++) for (int fixed = 0; fixed < 2; fixed++) { @autoreleasepool {
            *(float *)par.contents = v[i]; double clear = fixed ? nvn_depth16_clear_value(v[i]) : (double)v[i];
            if (api == 3) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = clear;
                id<MTLCommandBuffer> cb = [q3 commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:ps]; [re setDepthStencilState:ds]; [re setViewport:(MTLViewport){0, 0, 128, 4, 0, 1}]; [re setScissorRect:(MTLScissorRect){0, 0, 64, 4}];
                [re setFragmentBuffer:par offset:0 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(128, 4, 1) toBuffer:rd destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
                [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; if (cb.status == MTLCommandBufferStatusError) { printf("GPU error\n"); return 1; }
            } else if (@available(macOS 26.0, *)) {
                static id<MTL4CommandQueue> q; static id<MTL4CommandAllocator> al; static id<MTL4CommandBuffer> cb; static id<MTL4ArgumentTable> args;
                if (!q) { q = [dev newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&e]; al = [dev newCommandAllocator]; cb = [dev newCommandBuffer];
                    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1; args = [dev newArgumentTableWithDescriptor:ad error:&e]; [args setAddress:par.gpuAddress atIndex:0];
                    MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new]; id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rsd error:&e];
                    [rs addAllocation:depth]; [rs addAllocation:rd]; [rs addAllocation:par]; [rs commit]; [q addResidencySet:rs]; }
                MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = clear;
                [al reset]; [cb beginCommandBufferWithAllocator:al];
                id<MTL4RenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:ps]; [re setDepthStencilState:ds]; [re setViewport:(MTLViewport){0, 0, 128, 4, 0, 1}]; [re setScissorRect:(MTLScissorRect){0, 0, 64, 4}];
                [re setArgumentTable:args atStages:MTLRenderStageFragment]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
                id<MTL4ComputeCommandEncoder> be = [cb computeCommandEncoder]; [be barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
                [be copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(128, 4, 1) toBuffer:rd destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
                [be endEncoding]; [cb endCommandBuffer];
                dispatch_semaphore_t sem = dispatch_semaphore_create(0); __block int ok = 1; MTL4CommitOptions *o = [MTL4CommitOptions new];
                [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { if (f.error) ok = 0; dispatch_semaphore_signal(sem); }];
                const id<MTL4CommandBuffer> cbs[] = {cb}; [q commit:cbs count:1 options:o];
                if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !ok) { printf("GPU error\n"); return 1; }
            }
            const uint16_t *r = rd.contents; if (r[128 + 16] != r[128 + 96]) bad[fixed]++;
        } }
        char nm[96];
        snprintf(nm, sizeof nm, "Metal %d, raw clear value: some depths store differently", api); EXPECT(nm, 1, bad[0] > 0);
        snprintf(nm, sizeof nm, "Metal %d, nvn_depth16_clear_value: every depth stores as a fragment does", api); EXPECT(nm, 0, bad[1]);
    }
    printf("%u depths\n", nv);
    printf("== %d checks, %d failed ==\n", n, fail); return fail != 0;
} }
